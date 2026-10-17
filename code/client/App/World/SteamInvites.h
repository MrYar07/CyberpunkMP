#pragma once

// Campaign co-op: inviting Steam friends.
//
// The game's own steam_api64.dll is used through its flat API (nothing is loaded when the
// game is not the Steam version). An invite carries a connect string - the launch arguments
// that switch the mod on and point it at this server:
//   --online --ip=<address> --port=<port> --coopjoin
// - A friend whose game is not running: Steam starts it with those arguments, and the mod
//   connects to the lobby on its own (--coopjoin).
// - A friend whose game is running (with the mod): Steam sends GameRichPresenceJoinRequested
//   and the mod connects once that game is at the main menu.
// While connected, the same string is this player's rich presence "connect", so friends can
// also pick "Join Game" in their Steam friends list.
struct SteamInvites
{
    static void Attach();

    // Opens the Steam overlay's invite dialog; returns the address the invite carries, or
    // an empty string when Steam is not available.
    static Red::CString OpenInviteDialog();
    // Steam display name, empty without Steam.
    static std::string PersonaName();

    // Called every tick: rich presence follows the connection, and a pending join (from an
    // invite or --coopjoin) connects once the game is not in a world.
    static void Update(bool aConnected, bool aInGame);

private:
    static void UpdateSteam(void* apFriends, bool aConnected);
    static void JoinPending();
};
