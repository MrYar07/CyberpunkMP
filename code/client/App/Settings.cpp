#include "Settings.h"
#include <RED4ext/LaunchParameters.hpp>

void Settings::Load()
{
    Settings& settings = Get();

    auto& launchParameters = RED4ext::GetLaunchParameters();

    if (launchParameters.Contains(RED4ext::CString("-online")))
        settings.enabled = true;

    if (const auto ip = launchParameters.Get("-ip"); ip)
    {
        if (ip->size > 0)
            settings.ip = (*ip)[0].c_str();
    }

    if (const auto port = launchParameters.Get("-port"); port)
    {
        if (port->size > 0)
            settings.port = std::strtoul((*port)[0].c_str(), nullptr, 10) & 0xFFFF;
    }

    // Players are told apart by name: the campaign plugin keys each guest's character by it.
    if (const auto username = launchParameters.Get("-username"); username)
    {
        if (username->size > 0)
        {
            std::string name = (*username)[0].c_str();
            // Quoted arguments come with the same stray backslashes as -rpcdir.
            while (!name.empty() && (name.front() == '\\' || name.front() == '"'))
                name.erase(name.begin());
            while (!name.empty() && (name.back() == '\\' || name.back() == '"'))
                name.pop_back();

            if (!name.empty())
                settings.username = name.c_str();
        }
    }

    if (const auto mods = launchParameters.Get("-mod"); mods)
    {
        for (const auto& mod : *mods)
            settings.mods.push_back(mod.c_str());
    }

    if (launchParameters.Contains("-rpc"))
    {
        settings.RpcOnly = true;
    }

    if (const auto rpcDir = launchParameters.Get("-rpcdir"); rpcDir)
    {
        if (rpcDir->size > 0)
        {
            // For some reason cyberpunk adds a \ at the start and end of the path...
            std::string path = std::string((*rpcDir)[0].c_str());
            path = path.substr(1, path.length() - 2);

            settings.RpcPath = path;
        }
    }
}
