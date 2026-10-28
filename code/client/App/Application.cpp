#include "Application.h"

#include "Core/Foundation/LocaleProvider.hpp"
#include "Core/Foundation/RuntimeProvider.hpp"
#include "Network/NetworkService.h"
#include "Network/Rpc/RpcService.h"
#include "Rendering/ImGuiService.h"
#include "Debugging/DebugService.h"
#include "Threading/ThreadService.h"

#include "Support/MinHook/MinHookProvider.hpp"
#include "Support/RedLib/RedLibProvider.hpp"
#include "Support/Renderer/RenderingProvider.hpp"
#include "Support/Spdlog/SpdlogProvider.hpp"


namespace App
{
UniquePtr<Application> GApplication;

Application::Application(RED4ext::v1::PluginHandle aPlugin, const RED4ext::v1::Sdk* aSdk)
    : Core::Application(aPlugin, aSdk)
{
    Register<Core::LocaleProvider>();
    Register<Core::RuntimeProvider>(aPlugin)->SetBaseImagePathDepth(2);

    Register<Support::MinHookProvider>();
    Register<Support::SpdlogProvider>();
    Register<Support::RedLibProvider>();

    // The ImGui overlay only ever drew a developer menu ("Test" > Connect to 127.0.0.1) across
    // the top of the screen, yet it hooks every Present and builds an ImGui frame each game
    // update. Off for players; CYBERPUNKMP_DEBUG_OVERLAY=1 brings it back for development.
    char overlayValue[2]{};
    const bool overlay =
        GetEnvironmentVariableA("CYBERPUNKMP_DEBUG_OVERLAY", overlayValue, sizeof(overlayValue)) == 1 && overlayValue[0] == '1';
    if (overlay)
        Register<Support::RenderingProvider>();

    Register<ThreadService>();
    Register<NetworkService>();
    if (overlay)
    {
        Register<DebugService>();
        Register<ImGuiService>();
    }
    Register<RpcService>(aPlugin, aSdk);
}

void Application::OnStarted()
{
    Core::Application::OnStarted();
}

void Application::OnStopped()
{
    Core::Application::OnStopped();
}
} // namespace App
