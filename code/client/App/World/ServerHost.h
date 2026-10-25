#pragma once

// Campaign co-op: the host's game runs the server itself.
//
// The server ships with the mod in <game>\CyberpunkCoopServer (Server.Loader.exe and its
// plugins) - not under red4ext\plugins, whose DLLs RED4ext loads into the game. "HOST
// CAMPAIGN" starts it in the background - no window, output to logs\coop-server.log there -
// inside a job object that ends it together with the game. It needs the .NET 8 runtime.
struct ServerHost
{
    // Starts the server unless it already runs. False with Problem() set when it cannot.
    // aLoopbackOnly: friends come in through the Steam tunnel, so the server listens on this
    // computer only and cannot be reached around the tunnel's friends check.
    static bool Start(bool aLoopbackOnly);
    static void Stop();
    static bool IsRunning();
    static Red::CString Problem();
};
