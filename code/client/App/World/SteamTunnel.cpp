#include "SteamTunnel.h"

#include "SteamApi.h"

#include <WinSock2.h>
#include <WS2tcpip.h>
#include <mstcpip.h>

#include <mutex>
#include <unordered_set>

#ifndef SIO_UDP_CONNRESET
#define SIO_UDP_CONNRESET _WSAIOW(IOC_VENDOR, 12)
#endif

namespace
{
// Steam message channels: guest -> host, host -> guest.
constexpr int kChannelToHost = 0x4350;
constexpr int kChannelToGuest = 0x4351;
// Guests that sent nothing for this long are forgotten (their socket and session closed).
constexpr auto kIdleTimeout = std::chrono::seconds(120);
constexpr int kMaxDatagram = 2048;
// SteamNetworkingMessagesSessionRequest_t: k_iSteamNetworkingMessagesCallbacks (1250) + 1.
constexpr int kSessionRequestId = 1251;
// k_ESteamNetworkingIdentityType_SteamID
constexpr int32_t kIdentitySteamId = 16;

struct Guest
{
    SOCKET socket{INVALID_SOCKET};
    std::chrono::steady_clock::time_point lastSeen;
};

std::mutex s_lock;
// The worker runs detached (a joinable thread would end the game with std::terminate on
// exit); it stops when the generation it was started with is over.
std::atomic_uint32_t s_generation{0};
bool s_running{false};

// Guest side
SOCKET s_clientSocket{INVALID_SOCKET};
uint64_t s_hostSteamId{0};
sockaddr_in s_gameAddress{};
bool s_hasGameAddress{false};

// Host side
bool s_hosting{false};
uint16_t s_serverPort{0};
std::unordered_map<uint64_t, Guest> s_guests;
// Friends whose session request was accepted. Written by the Steam callback (game thread),
// read by the tunnel worker, which must not call ISteamFriends itself (not thread safe).
std::mutex s_acceptedLock;
std::unordered_set<uint64_t> s_accepted;

bool IsAccepted(uint64_t aSteamId)
{
    std::lock_guard _(s_acceptedLock);
    return s_accepted.contains(aSteamId);
}

class SessionRequestCallback : public SteamApi::CallbackBase
{
public:
    SessionRequestCallback() { m_callback = kSessionRequestId; }

    // Only the host's Steam friends get a session. A Steam ID is public, so "knows the host's
    // account" admits anyone; an unaccepted request simply expires and its messages are never
    // delivered.
    void Run(void* apParam) override
    {
        const auto* pIdentity = static_cast<SteamApi::Identity*>(apParam);
        if (!pIdentity || !s_hosting)
            return;

        if (pIdentity->type != kIdentitySteamId || !SteamApi::IsFriend(pIdentity->steamId64))
        {
            spdlog::warn("[SteamTunnel] refused {}: not a Steam friend of the host",
                         pIdentity->type == kIdentitySteamId ? pIdentity->steamId64 : 0);
            return;
        }

        {
            std::lock_guard _(s_acceptedLock);
            s_accepted.insert(pIdentity->steamId64);
        }
        SteamApi::AcceptSession(*pIdentity);
        spdlog::info("[SteamTunnel] accepted friend {}", pIdentity->steamId64);
    }

    void Run(void* apParam, bool, uint64_t) override { Run(apParam); }

    int GetCallbackSizeBytes() override { return sizeof(SteamApi::Identity); }
};

SessionRequestCallback s_sessionCallback;
bool s_callbackRegistered{false};

bool InitSockets()
{
    static const bool s_ok = []
    {
        WSADATA data;
        return WSAStartup(MAKEWORD(2, 2), &data) == 0;
    }();
    return s_ok;
}

sockaddr_in Loopback(uint16_t aPort)
{
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_port = htons(aPort);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    return address;
}

// A non-blocking UDP socket on 127.0.0.1 with a free port.
SOCKET OpenLoopbackSocket()
{
    auto sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sock == INVALID_SOCKET)
        return sock;

    const auto address = Loopback(0);
    u_long nonBlocking = 1;
    if (bind(sock, reinterpret_cast<const sockaddr*>(&address), sizeof(address)) != 0 || ioctlsocket(sock, FIONBIO, &nonBlocking) != 0)
    {
        closesocket(sock);
        return INVALID_SOCKET;
    }

    // Windows reports an ICMP "port unreachable" (the server not up yet, the game gone) as an
    // error on the next receive; for a relay that is only noise.
    BOOL reportResets = FALSE;
    DWORD returned = 0;
    WSAIoctl(sock, SIO_UDP_CONNRESET, &reportResets, sizeof(reportResets), nullptr, 0, &returned, nullptr, nullptr);
    return sock;
}

uint16_t PortOf(SOCKET aSocket)
{
    sockaddr_in address{};
    int size = sizeof(address);
    if (getsockname(aSocket, reinterpret_cast<sockaddr*>(&address), &size) != 0)
        return 0;
    return ntohs(address.sin_port);
}

void PumpClient(char* apBuffer)
{
    if (s_clientSocket == INVALID_SOCKET)
        return;

    // The game -> the host.
    while (true)
    {
        sockaddr_in from{};
        int fromSize = sizeof(from);
        const auto size = recvfrom(s_clientSocket, apBuffer, kMaxDatagram, 0, reinterpret_cast<sockaddr*>(&from), &fromSize);
        if (size <= 0)
            break;
        s_gameAddress = from;
        s_hasGameAddress = true;
        SteamApi::Send(s_hostSteamId, apBuffer, static_cast<uint32_t>(size), kChannelToHost);
    }

    // The host -> the game.
    SteamApi::Message* messages[32];
    const auto count = SteamApi::Receive(kChannelToGuest, messages, 32);
    for (int i = 0; i < count; ++i)
    {
        auto* pMessage = messages[i];
        if (s_hasGameAddress && pMessage->peer.type == kIdentitySteamId && pMessage->peer.steamId64 == s_hostSteamId)
            sendto(s_clientSocket, static_cast<const char*>(pMessage->data), pMessage->size, 0, reinterpret_cast<const sockaddr*>(&s_gameAddress), sizeof(s_gameAddress));
        SteamApi::ReleaseMessage(pMessage);
    }
}

void PumpHost(char* apBuffer)
{
    if (!s_hosting)
        return;

    const auto now = std::chrono::steady_clock::now();
    const auto server = Loopback(s_serverPort);

    // Guests -> the server, each from a socket of its own.
    SteamApi::Message* messages[64];
    const auto count = SteamApi::Receive(kChannelToHost, messages, 64);
    for (int i = 0; i < count; ++i)
    {
        auto* pMessage = messages[i];
        // Second gate: only peers the session callback accepted as friends reach the server.
        if (pMessage->peer.type == kIdentitySteamId && IsAccepted(pMessage->peer.steamId64))
        {
            auto& guest = s_guests[pMessage->peer.steamId64];
            if (guest.socket == INVALID_SOCKET)
            {
                guest.socket = OpenLoopbackSocket();
                spdlog::info("[SteamTunnel] guest {} connected through Steam", pMessage->peer.steamId64);
            }
            guest.lastSeen = now;
            if (guest.socket != INVALID_SOCKET)
                sendto(guest.socket, static_cast<const char*>(pMessage->data), pMessage->size, 0, reinterpret_cast<const sockaddr*>(&server), sizeof(server));
        }
        SteamApi::ReleaseMessage(pMessage);
    }

    // The server -> each guest.
    for (auto it = s_guests.begin(); it != s_guests.end();)
    {
        auto& [steamId, guest] = *it;
        while (guest.socket != INVALID_SOCKET)
        {
            const auto size = recv(guest.socket, apBuffer, kMaxDatagram, 0);
            if (size <= 0)
                break;
            SteamApi::Send(steamId, apBuffer, static_cast<uint32_t>(size), kChannelToGuest);
        }

        if (now - guest.lastSeen > kIdleTimeout)
        {
            spdlog::info("[SteamTunnel] guest {} went quiet, closing", steamId);
            if (guest.socket != INVALID_SOCKET)
                closesocket(guest.socket);
            SteamApi::CloseSession(steamId);
            it = s_guests.erase(it);
        }
        else
        {
            ++it;
        }
    }
}

void Work(uint32_t aGeneration)
{
    std::vector<char> buffer(kMaxDatagram);
    while (s_generation == aGeneration)
    {
        {
            std::lock_guard _(s_lock);
            PumpClient(buffer.data());
            PumpHost(buffer.data());
        }
        // About a thousand times a second: well under the game's own tick for latency, and
        // nothing to do most of the time.
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
}

// Call with s_lock held.
void EnsureWorker()
{
    if (s_running)
        return;
    s_running = true;
    std::thread(&Work, ++s_generation).detach();
}

// Stops the worker once neither side needs it (call with s_lock held).
void StopWorkerIfIdle()
{
    if (!s_running || s_clientSocket != INVALID_SOCKET || s_hosting)
        return;
    s_running = false;
    ++s_generation;
}
} // namespace

uint16_t SteamTunnel::StartClient(uint64_t aHostSteamId)
{
    if (!SteamApi::Available() || !InitSockets() || aHostSteamId == 0)
        return 0;

    StopClient();

    std::lock_guard _(s_lock);
    s_clientSocket = OpenLoopbackSocket();
    if (s_clientSocket == INVALID_SOCKET)
    {
        spdlog::error("[SteamTunnel] could not open a local socket");
        return 0;
    }
    s_hostSteamId = aHostSteamId;
    s_hasGameAddress = false;
    SteamApi::InitRelayNetwork();
    EnsureWorker();

    const auto port = PortOf(s_clientSocket);
    spdlog::info("[SteamTunnel] tunnel to host {} on 127.0.0.1:{}", aHostSteamId, port);
    return port;
}

void SteamTunnel::StopClient()
{
    {
        std::lock_guard _(s_lock);
        if (s_clientSocket == INVALID_SOCKET)
            return;
        closesocket(s_clientSocket);
        s_clientSocket = INVALID_SOCKET;
        if (s_hostSteamId)
            SteamApi::CloseSession(s_hostSteamId);
        s_hostSteamId = 0;
        s_hasGameAddress = false;
        StopWorkerIfIdle();
    }
}

uint64_t SteamTunnel::ClientHost()
{
    std::lock_guard _(s_lock);
    return s_clientSocket != INVALID_SOCKET ? s_hostSteamId : 0;
}

bool SteamTunnel::StartHost(uint16_t aServerPort)
{
    if (!SteamApi::Available() || !InitSockets())
        return false;

    // Session requests arrive through the game's own SteamAPI_RunCallbacks (main thread).
    if (!s_callbackRegistered)
    {
        SteamApi::RegisterCallback(&s_sessionCallback, kSessionRequestId);
        s_callbackRegistered = true;
    }

    std::lock_guard _(s_lock);
    s_hosting = true;
    s_serverPort = aServerPort;
    SteamApi::InitRelayNetwork();
    EnsureWorker();
    spdlog::info("[SteamTunnel] hosting: friends reach 127.0.0.1:{} through Steam", aServerPort);
    return true;
}

void SteamTunnel::StopHost()
{
    {
        std::lock_guard _(s_lock);
        if (!s_hosting)
            return;
        s_hosting = false;
        for (auto& [steamId, guest] : s_guests)
        {
            if (guest.socket != INVALID_SOCKET)
                closesocket(guest.socket);
            SteamApi::CloseSession(steamId);
        }
        s_guests.clear();
        {
            std::lock_guard accepted(s_acceptedLock);
            s_accepted.clear();
        }
        StopWorkerIfIdle();
    }
}

bool SteamTunnel::IsHosting()
{
    std::lock_guard _(s_lock);
    return s_hosting;
}
