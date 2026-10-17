#pragma once

// Campaign co-op: how players reach the server.
//
// - HOST CAMPAIGN: this game starts the server (ServerHost), connects to it locally and lets
//   Steam friends in through the Steam tunnel (SteamTunnel) - nobody forwards ports.
// - Joining through Steam: an invite or "Join Game" in the friends list carries the host's
//   Steam account (--steamhost); the client connects through the tunnel.
// - Joining by address (a dedicated server): --ip / --port as before.
//
// Steam invites carry launch arguments that switch the mod on and say where to go:
//   --online --steamhost=<host's Steam id> --coopjoin     (a game hosted through Steam)
//   --online --ip=<address> --port=<port> --coopjoin      (a server reached by address)
// A friend whose game is not running gets it started with them and joins at the main menu
// (--coopjoin); a running game gets GameRichPresenceJoinRequested and joins once it is at
// the main menu. While connected, the same arguments are this player's rich presence
// "connect", so friends can pick "Join Game" in their Steam friends list.
struct CoopConnect
{
    static void Attach();

    // Every tick: rich presence, the host's connection to its own server, pending joins.
    static void Update(bool aConnected, bool aInGame);

    // The lobby's CO-OP CAMPAIGN button: the server from the launch arguments.
    static void ConnectConfigured();
    static bool Host();
    static void Leave();

    // Opens the Steam invite dialog; returns what friends will connect to ("Steam" through
    // the tunnel, or an address), empty without Steam.
    static Red::CString OpenInviteDialog();
    // Hosting state for the lobby panel: "" when not hosting, otherwise progress or a problem.
    static Red::CString HostStatus();
    static bool IsHosting();
    static std::string PersonaName();
};
