#include "SteamInvites.h"

#include "App/Network/NetworkService.h"
#include "App/Settings.h"

#include <WinSock2.h>
#include <WS2tcpip.h>
#include <iphlpapi.h>

namespace
{
// The flat Steamworks API (steam_api_flat.h), resolved from the game's steam_api64.dll.
using SteamFriendsFn = void* (*)();
using InviteDialogFn = void (*)(void*, const char*);
using SetRichPresenceFn = bool (*)(void*, const char*, const char*);
using ClearRichPresenceFn = void (*)(void*);
using PersonaNameFn = const char* (*)(void*);
using RegisterCallbackFn = void (*)(void*, int);

SteamFriendsFn s_steamFriends{nullptr};
InviteDialogFn s_inviteDialog{nullptr};
SetRichPresenceFn s_setRichPresence{nullptr};
ClearRichPresenceFn s_clearRichPresence{nullptr};
PersonaNameFn s_personaName{nullptr};
RegisterCallbackFn s_registerCallback{nullptr};

// Steamworks' CCallbackBase (steam_api_common.h), declared the same way so MSVC lays out the
// same vtable: no virtual destructor, the two Run overloads, then the size.
class CallbackBase
{
public:
    virtual void Run(void* apParam) = 0;
    virtual void Run(void* apParam, bool aIOFailure, uint64_t aCall) = 0;
    virtual int GetCallbackSizeBytes() = 0;

protected:
    uint8_t m_callbackFlags{0};
    int m_callback{0};
};

// GameRichPresenceJoinRequested_t: k_iSteamFriendsCallbacks (300) + 37, packed to 8.
#pragma pack(push, 8)
struct JoinRequested
{
    uint64_t friendId;
    char connect[256];
};
#pragma pack(pop)
constexpr int kJoinRequestedId = 337;

std::mutex s_lock;
std::optional<std::string> s_pendingAddress;
std::optional<uint16_t> s_pendingPort;
bool s_pendingJoin{false};
bool s_presence{false};

// "--ip=" and "--port=" out of a connect string (the same arguments the game is launched with).
void QueueJoin(const std::string& aConnect)
{
    auto value = [&aConnect](const char* aKey) -> std::optional<std::string>
    {
        const auto at = aConnect.find(aKey);
        if (at == std::string::npos)
            return std::nullopt;
        const auto start = at + std::strlen(aKey);
        const auto end = aConnect.find(' ', start);
        return aConnect.substr(start, end == std::string::npos ? std::string::npos : end - start);
    };

    std::lock_guard _(s_lock);
    s_pendingAddress = value("--ip=");
    if (const auto port = value("--port="))
        s_pendingPort = static_cast<uint16_t>(std::strtoul(port->c_str(), nullptr, 10) & 0xFFFF);
    s_pendingJoin = s_pendingAddress.has_value();
    spdlog::info("[SteamInvites] join requested: {}", aConnect);
}

class JoinCallback : public CallbackBase
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
bool s_callbackRegistered{false};

void* Friends()
{
    return s_steamFriends ? s_steamFriends() : nullptr;
}

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
    if (GetAdaptersAddresses(AF_INET, flags, nullptr, pAddresses, &size) == ERROR_BUFFER_OVERFLOW)
    {
        buffer.resize(size);
        pAddresses = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
        if (GetAdaptersAddresses(AF_INET, flags, nullptr, pAddresses, &size) != NO_ERROR)
            return {};
    }

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

// The address a friend should connect to: --publicip when given; the server's address when
// it is elsewhere; this machine's best address when the server runs here.
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
    const auto address = InviteAddress();
    if (address.empty())
        return {};
    return fmt::format("--online --ip={} --port={} --coopjoin", address, Settings::Get().port);
}
} // namespace

void SteamInvites::Attach()
{
    // Launched from an invite (or with --coopjoin): connect as soon as the main menu is up.
    if (Settings::Get().autoJoin)
    {
        std::lock_guard _(s_lock);
        s_pendingJoin = true;
    }

    if (s_steamFriends)
        return;

    const auto module = GetModuleHandleW(L"steam_api64.dll");
    if (!module)
    {
        spdlog::info("[SteamInvites] no steam_api64.dll in the game, Steam invites are off");
        return;
    }

    s_steamFriends = reinterpret_cast<SteamFriendsFn>(GetProcAddress(module, "SteamAPI_SteamFriends_v017"));
    s_inviteDialog = reinterpret_cast<InviteDialogFn>(GetProcAddress(module, "SteamAPI_ISteamFriends_ActivateGameOverlayInviteDialogConnectString"));
    s_setRichPresence = reinterpret_cast<SetRichPresenceFn>(GetProcAddress(module, "SteamAPI_ISteamFriends_SetRichPresence"));
    s_clearRichPresence = reinterpret_cast<ClearRichPresenceFn>(GetProcAddress(module, "SteamAPI_ISteamFriends_ClearRichPresence"));
    s_personaName = reinterpret_cast<PersonaNameFn>(GetProcAddress(module, "SteamAPI_ISteamFriends_GetPersonaName"));
    s_registerCallback = reinterpret_cast<RegisterCallbackFn>(GetProcAddress(module, "SteamAPI_RegisterCallback"));

    if (!s_steamFriends || !s_inviteDialog || !s_setRichPresence || !s_clearRichPresence || !s_personaName || !s_registerCallback)
    {
        spdlog::warn("[SteamInvites] steam_api64.dll lacks the friends API this needs, Steam invites are off");
        s_steamFriends = nullptr;
        return;
    }
}

Red::CString SteamInvites::OpenInviteDialog()
{
    auto* pFriends = Friends();
    if (!pFriends)
        return "";

    const auto connect = ConnectString();
    if (connect.empty())
    {
        spdlog::warn("[SteamInvites] no address to invite friends to");
        return "";
    }

    s_inviteDialog(pFriends, connect.c_str());
    spdlog::info("[SteamInvites] invite dialog opened: {}", connect);
    return InviteAddress().c_str();
}

std::string SteamInvites::PersonaName()
{
    auto* pFriends = Friends();
    if (!pFriends)
        return {};
    const auto* pName = s_personaName(pFriends);
    return pName ? pName : "";
}

void SteamInvites::Update(bool aConnected, bool aInGame)
{
    if (auto* pFriends = Friends())
        UpdateSteam(pFriends, aConnected);

    if (!aInGame)
        JoinPending();
}

void SteamInvites::UpdateSteam(void* apFriends, bool aConnected)
{
    auto* pFriends = apFriends;

    // Steam is up by the time the game ticks; registered once, dispatched by the game's own
    // SteamAPI_RunCallbacks.
    if (!s_callbackRegistered)
    {
        s_registerCallback(&s_joinCallback, kJoinRequestedId);
        s_callbackRegistered = true;
    }

    if (aConnected != s_presence)
    {
        s_presence = aConnected;
        if (aConnected)
        {
            const auto connect = ConnectString();
            if (!connect.empty())
            {
                s_setRichPresence(pFriends, "connect", connect.c_str());
                s_setRichPresence(pFriends, "status", "Cyberpunk 2077 co-op campaign");
            }
        }
        else
        {
            s_clearRichPresence(pFriends);
        }
    }
}

void SteamInvites::JoinPending()
{
    std::optional<std::string> address;
    std::optional<uint16_t> port;
    {
        std::lock_guard _(s_lock);
        if (!s_pendingJoin)
            return;
        s_pendingJoin = false;
        address = std::move(s_pendingAddress);
        port = s_pendingPort;
        s_pendingAddress.reset();
        s_pendingPort.reset();
    }

    const auto service = Core::Container::Get<NetworkService>();
    if (!service)
        return;

    auto& settings = Settings::Get();
    const bool sameServer = (!address || *address == settings.ip.c_str()) && (!port || *port == settings.port);
    if (service->IsConnected() && sameServer)
        return;

    if (address)
        settings.ip = address->c_str();
    if (port)
        settings.port = *port;

    // A different server than the one we are on: leave it first.
    if (service->IsConnected())
        service->Close();

    spdlog::info("[SteamInvites] joining {}:{}", settings.ip.c_str(), settings.port);
    service->Connect(fmt::format("{}:{}", settings.ip, settings.port));
}
