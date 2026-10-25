#include "CoopConnect.h"

#include "ServerHost.h"
#include "SteamApi.h"
#include "SteamTunnel.h"

#include "App/Network/NetworkService.h"
#include "App/Settings.h"

#include <WinSock2.h>
#include <WS2tcpip.h>
#include <iphlpapi.h>

namespace
{
// The port the bundled server listens on (its config/server.json default).
constexpr uint16_t kHostPort = 11778;
// The host's game retries its own server while it starts up.
constexpr auto kHostRetry = std::chrono::seconds(3);
constexpr int kHostAttempts = 20;

// GameRichPresenceJoinRequested_t: k_iSteamFriendsCallbacks (300) + 37, packed to 8.
#pragma pack(push, 8)
struct JoinRequested
{
    uint64_t friendId;
    char connect[256];
};
#pragma pack(pop)
constexpr int kJoinRequestedId = 337;

struct PendingJoin
{
    std::optional<uint64_t> steamHost;
    std::optional<std::string> address;
    std::optional<uint16_t> port;
};

std::mutex s_lock;
std::optional<PendingJoin> s_pending;
bool s_presence{false};
bool s_callbackRegistered{false};

bool s_hosting{false};
bool s_hostConnecting{false};
int s_hostAttempts{0};
std::chrono::steady_clock::time_point s_hostNextAttempt{};
std::string s_hostStatus;

// One "--key=value" out of a connect string (the same arguments the game is launched with).
std::optional<std::string> Argument(const std::string& aConnect, const char* aKey)
{
    const auto at = aConnect.find(aKey);
    if (at == std::string::npos)
        return std::nullopt;
    const auto start = at + std::strlen(aKey);
    const auto end = aConnect.find(' ', start);
    return aConnect.substr(start, end == std::string::npos ? std::string::npos : end - start);
}

void QueueJoin(const std::string& aConnect)
{
    PendingJoin join;
    if (const auto host = Argument(aConnect, "--steamhost="))
        join.steamHost = std::strtoull(host->c_str(), nullptr, 10);
    join.address = Argument(aConnect, "--ip=");
    if (const auto port = Argument(aConnect, "--port="))
        join.port = static_cast<uint16_t>(std::strtoul(port->c_str(), nullptr, 10) & 0xFFFF);

    if (!join.steamHost && !join.address)
        return;

    std::lock_guard _(s_lock);
    s_pending = join;
    spdlog::info("[CoopConnect] join requested: {}", aConnect);
}

class JoinCallback : public SteamApi::CallbackBase
{
public:
    JoinCallback() { m_callback = kJoinRequestedId; }

    void Run(void* apParam) override
    {
        if (const auto* pData = static_cast<JoinRequested*>(apParam))
            QueueJoin(std::string(pData->connect, strnlen(pData->connect, sizeof(pData->connect))));
    }

    void Run(void* apParam, bool, uint64_t) override { Run(apParam); }

    int GetCallbackSizeBytes() override { return sizeof(JoinRequested); }
};

JoinCallback s_joinCallback;

bool IsLoopback(const std::string& aAddress)
{
    return aAddress.starts_with("127.") || aAddress == "localhost" || aAddress == "::1";
}

// How useful an address of this machine is to a friend: a public one works over the internet;
// Hamachi (25.x), Radmin VPN (26.x) and CGNAT-range VPNs such as Tailscale (100.64/10) work
// for friends on the same VPN; a private LAN address only in the same home network.
int Rank(uint32_t aHostOrder)
{
    const auto a = aHostOrder >> 24;
    const auto b = (aHostOrder >> 16) & 0xFF;
    if (a == 25 || a == 26 || (a == 100 && b >= 64 && b < 128))
        return 2;
    if (a == 10 || (a == 172 && b >= 16 && b < 32) || (a == 192 && b == 168) || (a == 169 && b == 254))
        return 1;
    if (a == 127 || a == 0)
        return 0;
    return 3;
}

std::string BestLocalAddress()
{
    ULONG size = 16 * 1024;
    std::vector<uint8_t> buffer(size);
    auto* pAddresses = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
    constexpr ULONG flags = GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER;
    auto result = GetAdaptersAddresses(AF_INET, flags, nullptr, pAddresses, &size);
    if (result == ERROR_BUFFER_OVERFLOW)
    {
        buffer.resize(size);
        pAddresses = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
        result = GetAdaptersAddresses(AF_INET, flags, nullptr, pAddresses, &size);
    }
    if (result != NO_ERROR)
        return {};

    std::string best;
    int bestRank = 0;
    for (auto* pAdapter = pAddresses; pAdapter; pAdapter = pAdapter->Next)
    {
        if (pAdapter->OperStatus != IfOperStatusUp)
            continue;
        for (auto* pUnicast = pAdapter->FirstUnicastAddress; pUnicast; pUnicast = pUnicast->Next)
        {
            const auto* pIn = reinterpret_cast<sockaddr_in*>(pUnicast->Address.lpSockaddr);
            const auto rank = Rank(ntohl(pIn->sin_addr.s_addr));
            if (rank > bestRank)
            {
                char text[INET_ADDRSTRLEN]{};
                inet_ntop(AF_INET, &pIn->sin_addr, text, sizeof(text));
                best = text;
                bestRank = rank;
            }
        }
    }
    return best;
}

// The Steam account friends reach this server through: our own when hosting, the host's
// when we came in through the tunnel ourselves.
uint64_t TunnelHost()
{
    if (SteamTunnel::IsHosting())
        return SteamApi::LocalSteamId();
    return SteamTunnel::ClientHost();
}

// A server reached by address: --publicip when given; the server's own address when it is
// elsewhere; this machine's best address when it runs here.
std::string InviteAddress()
{
    const auto& settings = Settings::Get();
    if (!settings.publicIp.empty())
        return settings.publicIp.c_str();

    std::string ip = settings.ip.c_str();
    if (!IsLoopback(ip))
        return ip;

    return BestLocalAddress();
}

std::string ConnectString()
{
    if (const auto host = TunnelHost())
        return fmt::format("--online --steamhost={} --coopjoin", host);

    const auto address = InviteAddress();
    if (address.empty())
        return {};
    return fmt::format("--online --ip={} --port={} --coopjoin", address, Settings::Get().port);
}

// Points the client at a server and connects. Through the tunnel the client connects to the
// tunnel's local port.
void ConnectTo(const PendingJoin& aJoin)
{
    const auto service = Core::Container::Get<NetworkService>();
    if (!service)
        return;

    auto& settings = Settings::Get();
    std::string address;
    uint16_t port;

    // Joining elsewhere: an old hosting problem is no longer news.
    if (!s_hosting)
        s_hostStatus.clear();

    if (aJoin.steamHost && *aJoin.steamHost != 0)
    {
        if (service->IsConnected() && SteamTunnel::ClientHost() == *aJoin.steamHost)
            return;

        port = SteamTunnel::StartClient(*aJoin.steamHost);
        if (port == 0)
        {
            spdlog::error("[CoopConnect] cannot join through Steam: Steam is not available");
            return;
        }
        address = "127.0.0.1";
        settings.steamHost = *aJoin.steamHost;
    }
    else
    {
        address = aJoin.address.value_or(settings.ip.c_str());
        port = aJoin.port.value_or(settings.port);
        if (service->IsConnected() && address == settings.ip.c_str() && port == settings.port)
            return;
        SteamTunnel::StopClient();
        settings.ip = address.c_str();
        settings.port = port;
        settings.steamHost = 0;
    }

    // A different server than the one we are on: leave it first.
    if (service->IsConnected())
        service->Close();

    spdlog::info("[CoopConnect] connecting to {}:{}", address, port);
    service->Connect(fmt::format("{}:{}", address, port));
}

void UpdatePresence(bool aConnected)
{
    if (aConnected == s_presence)
        return;
    s_presence = aConnected;

    if (!aConnected)
    {
        SteamApi::ClearRichPresence();
        return;
    }
    const auto connect = ConnectString();
    if (!connect.empty())
    {
        SteamApi::SetRichPresence("connect", connect.c_str());
        SteamApi::SetRichPresence("status", "Cyberpunk 2077 co-op campaign");
    }
}

// The host's game reaches its own server once it is up (it takes a few seconds to start).
void UpdateHosting(bool aConnected)
{
    // The server this game started went down while in use (crash, killed): say so.
    if (s_hosting && !s_hostConnecting)
    {
        static auto s_nextCheck = std::chrono::steady_clock::time_point{};
        const auto now = std::chrono::steady_clock::now();
        if (now >= s_nextCheck)
        {
            s_nextCheck = now + std::chrono::seconds(1);
            if (!ServerHost::IsRunning() && s_hostStatus.find("stopped") == std::string::npos)
                s_hostStatus = ServerHost::Problem().c_str();
        }
        return;
    }

    if (!s_hostConnecting)
        return;

    if (aConnected)
    {
        s_hostConnecting = false;
        s_hostStatus = SteamTunnel::IsHosting() ? "Hosting - invite Steam friends, no ports to open" : "Hosting - friends need this computer's address and port 11778";
        // The presence was set before the tunnel host was known to matter: set it again.
        s_presence = false;
        return;
    }

    if (!ServerHost::IsRunning())
    {
        s_hostConnecting = false;
        s_hostStatus = ServerHost::Problem().c_str();
        return;
    }

    const auto now = std::chrono::steady_clock::now();
    if (now < s_hostNextAttempt)
        return;

    const auto service = Core::Container::Get<NetworkService>();
    if (!service)
        return;

    const auto state = service->GetConnectionStatus().m_eState;
    if (state == k_ESteamNetworkingConnectionState_Connecting || state == k_ESteamNetworkingConnectionState_FindingRoute)
        return;

    if (++s_hostAttempts > kHostAttempts)
    {
        s_hostConnecting = false;
        s_hostStatus = "The co-op server started but does not answer - see CyberpunkCoopServer\\logs\\coop-server.log";
        return;
    }

    s_hostNextAttempt = now + kHostRetry;
    service->Connect(fmt::format("127.0.0.1:{}", kHostPort));
}
} // namespace

void CoopConnect::Attach()
{
    SteamApi::Load();

    // Launched from an invite (or with --coopjoin): join as soon as the main menu is up.
    const auto& settings = Settings::Get();
    if (settings.autoJoin)
    {
        PendingJoin join;
        if (settings.steamHost != 0)
            join.steamHost = settings.steamHost;
        std::lock_guard _(s_lock);
        s_pending = join;
    }
}

void CoopConnect::Update(bool aConnected, bool aInGame)
{
    if (SteamApi::Available())
    {
        // Registered once Steam is up; dispatched by the game's own SteamAPI_RunCallbacks.
        if (!s_callbackRegistered)
        {
            SteamApi::RegisterCallback(&s_joinCallback, kJoinRequestedId);
            s_callbackRegistered = true;
        }
        UpdatePresence(aConnected);
    }

    UpdateHosting(aConnected);

    if (aInGame)
        return;

    std::optional<PendingJoin> join;
    {
        std::lock_guard _(s_lock);
        join.swap(s_pending);
    }
    if (!join)
        return;

    // Hosting and then accepting someone else's invite: theirs wins.
    if (s_hosting)
        Leave();
    ConnectTo(*join);
}

void CoopConnect::ConnectConfigured()
{
    PendingJoin join;
    if (Settings::Get().steamHost != 0)
        join.steamHost = Settings::Get().steamHost;
    ConnectTo(join);
}

bool CoopConnect::Host()
{
    if (s_hosting)
        return true;

    // With Steam, friends join through the tunnel and the server stays local; without it
    // (GOG, Epic) they need the address, so the server listens on the network.
    const bool steam = SteamApi::Available();
    if (!ServerHost::Start(steam))
    {
        s_hostStatus = ServerHost::Problem().c_str();
        return false;
    }

    const auto service = Core::Container::Get<NetworkService>();
    if (service && service->IsConnected())
        service->Close();
    SteamTunnel::StopClient();

    auto& settings = Settings::Get();
    settings.ip = "127.0.0.1";
    settings.port = kHostPort;
    settings.steamHost = 0;

    s_hosting = true;
    s_hostConnecting = true;
    s_hostAttempts = 0;
    // The first attempt after the server had a moment to start.
    s_hostNextAttempt = std::chrono::steady_clock::now() + kHostRetry;

    const bool tunnel = SteamTunnel::StartHost(kHostPort);
    if (steam && !tunnel)
        s_hostStatus = "The Steam tunnel did not start, so friends cannot join - LEAVE and host again";
    else
        s_hostStatus = tunnel ? "Starting the co-op server..." : "Starting the co-op server (no Steam: friends need your address)...";
    return true;
}

void CoopConnect::Leave()
{
    const auto service = Core::Container::Get<NetworkService>();
    if (service)
        service->Close();

    SteamTunnel::StopClient();
    if (s_hosting)
    {
        SteamTunnel::StopHost();
        ServerHost::Stop();
    }
    s_hosting = false;
    s_hostConnecting = false;
    s_hostStatus.clear();
    // The Steam host stays: JOIN SERVER goes back to the same game.
}

Red::CString CoopConnect::OpenInviteDialog()
{
    if (!SteamApi::Available())
        return "";

    const auto connect = ConnectString();
    if (connect.empty())
    {
        spdlog::warn("[CoopConnect] nothing to invite friends to");
        return "";
    }

    SteamApi::InviteDialog(connect.c_str());
    spdlog::info("[CoopConnect] invite dialog opened: {}", connect);
    if (TunnelHost())
        return "Steam";
    return InviteAddress().c_str();
}

Red::CString CoopConnect::HostStatus()
{
    return s_hostStatus.c_str();
}

bool CoopConnect::IsHosting()
{
    return s_hosting;
}

std::string CoopConnect::PersonaName()
{
    return SteamApi::PersonaName();
}
