#pragma once

// Campaign co-op: the game's server traffic over Steam, so nobody forwards ports.
//
// The mod's network layer (GameNetworkingSockets over UDP) is left as it is; the tunnel
// carries its datagrams through Steam's peer-to-peer messages (ISteamNetworkingMessages,
// relayed by Valve when a direct route through the routers cannot be made).
// - Guest: a UDP port on 127.0.0.1. The client connects to it as if the server were local;
//   every datagram goes to the host's Steam account, and the answers come back the same way.
// - Host: datagrams from each friend go to the local server (127.0.0.1:<port>) from a UDP
//   socket of their own, so the server sees every friend as a separate client.
struct SteamTunnel
{
    // Guest: returns the local port to connect to, 0 when Steam is not available.
    static uint16_t StartClient(uint64_t aHostSteamId);
    static void StopClient();
    // The host's Steam account this game tunnels to, 0 when none.
    static uint64_t ClientHost();

    // Host: accepts friends' sessions and forwards them to the server on this machine.
    static bool StartHost(uint16_t aServerPort);
    static void StopHost();
    static bool IsHosting();
};
