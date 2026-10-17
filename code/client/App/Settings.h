#pragma once

namespace fs = std::filesystem;

struct Settings
{
    static Settings& Get()
    {
        static Settings instance;
        return instance;
    }
    static bool IsDisabled()
    {
        return !Get().enabled;
    }
    static void Load();

    fs::path exePath{};
    fs::path gamePath{};
    String Version{};
    String ip = "127.0.0.1";
    uint16_t port = 11778;
    String username = "Player";
    // --username was given; otherwise the Steam name is used when there is one.
    bool usernameGiven = false;
    // Steam invites: the address friends get (--publicip), and connect on start (--coopjoin,
    // set by an invite's launch arguments).
    String publicIp{};
    bool autoJoin = false;
    Vector<fs::path> mods = {};
    bool enabled = false;
    bool RpcOnly = false;
    fs::path RpcPath{};

private:
    Settings() = default;
};