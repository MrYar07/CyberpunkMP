#include "ServerHost.h"

#include <random>

namespace
{
std::mutex s_lock;
HANDLE s_job{nullptr};
HANDLE s_process{nullptr};
std::string s_problem;

// The folder this DLL is in: <game>\red4ext\plugins\<mod>.
std::filesystem::path ModFolder()
{
    HMODULE module = nullptr;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       reinterpret_cast<LPCWSTR>(&ModFolder), &module);
    wchar_t path[MAX_PATH]{};
    GetModuleFileNameW(module, path, MAX_PATH);
    return std::filesystem::path(path).parent_path();
}

// The web admin needs an account; nobody uses it in a game started this way, so it gets a
// random password.
std::wstring RandomPassword()
{
    std::random_device device;
    std::wstring password;
    constexpr wchar_t kDigits[] = L"0123456789abcdef";
    for (int i = 0; i < 24; ++i)
        password.push_back(kDigits[device() % 16]);
    return password;
}

bool IsAlive()
{
    if (!s_process)
        return false;
    DWORD code = 0;
    return GetExitCodeProcess(s_process, &code) && code == STILL_ACTIVE;
}

void CloseHandles()
{
    if (s_process)
        CloseHandle(s_process);
    s_process = nullptr;
}
} // namespace

bool ServerHost::Start()
{
    std::lock_guard _(s_lock);
    if (IsAlive())
        return true;
    CloseHandles();
    s_problem.clear();

    // Outside red4ext\plugins, where RED4ext would take its DLLs for plugins.
    const auto folder = ModFolder().parent_path().parent_path().parent_path() / "CyberpunkCoopServer";
    const auto exe = folder / "Server.Loader.exe";
    if (!std::filesystem::exists(exe))
    {
        s_problem = "The co-op server is not installed (no CyberpunkCoopServer folder in the game folder)";
        spdlog::error("[ServerHost] {} not found", exe.string());
        return false;
    }

    // Ends the server with the game, however the game ends.
    if (!s_job)
    {
        s_job = CreateJobObjectW(nullptr, nullptr);
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (s_job)
            SetInformationJobObject(s_job, JobObjectExtendedLimitInformation, &limits, sizeof(limits));
    }

    std::filesystem::create_directories(folder / "logs");
    SECURITY_ATTRIBUTES inherit{sizeof(inherit), nullptr, TRUE};
    const auto log = CreateFileW((folder / "logs" / "coop-server.log").c_str(), GENERIC_WRITE, FILE_SHARE_READ, &inherit,
                                 CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);

    // The server reads its admin account from the environment; the child inherits ours.
    const auto password = RandomPassword();
    SetEnvironmentVariableW(L"CYBERPUNKMP_ADMIN_USERNAME", L"coop");
    SetEnvironmentVariableW(L"CYBERPUNKMP_ADMIN_PASSWORD", password.c_str());

    STARTUPINFOW startup{sizeof(startup)};
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    startup.hStdOutput = log;
    startup.hStdError = log;

    PROCESS_INFORMATION process{};
    std::wstring commandLine = L"\"" + exe.wstring() + L"\"";
    const auto started = CreateProcessW(exe.c_str(), commandLine.data(), nullptr, nullptr, TRUE,
                                        CREATE_NO_WINDOW | CREATE_SUSPENDED, nullptr, folder.c_str(), &startup, &process);

    SetEnvironmentVariableW(L"CYBERPUNKMP_ADMIN_USERNAME", nullptr);
    SetEnvironmentVariableW(L"CYBERPUNKMP_ADMIN_PASSWORD", nullptr);
    if (log != INVALID_HANDLE_VALUE)
        CloseHandle(log);

    if (!started)
    {
        s_problem = fmt::format("The co-op server could not start (error {})", GetLastError());
        spdlog::error("[ServerHost] {}", s_problem);
        return false;
    }

    if (s_job)
        AssignProcessToJobObject(s_job, process.hProcess);
    ResumeThread(process.hThread);
    CloseHandle(process.hThread);
    s_process = process.hProcess;

    spdlog::info("[ServerHost] server started from {}", folder.string());
    return true;
}

void ServerHost::Stop()
{
    std::lock_guard _(s_lock);
    if (IsAlive())
    {
        TerminateProcess(s_process, 0);
        spdlog::info("[ServerHost] server stopped");
    }
    CloseHandles();
}

bool ServerHost::IsRunning()
{
    std::lock_guard _(s_lock);
    if (s_process && !IsAlive())
    {
        // It quit by itself: most likely no .NET 8 runtime, or the port is taken.
        DWORD code = 0;
        GetExitCodeProcess(s_process, &code);
        s_problem = fmt::format("The co-op server stopped (exit code {}) - see CyberpunkCoopServer\\logs\\coop-server.log; it needs the .NET 8 runtime", code);
        spdlog::error("[ServerHost] {}", s_problem);
        CloseHandles();
    }
    return s_process != nullptr;
}

Red::CString ServerHost::Problem()
{
    std::lock_guard _(s_lock);
    return s_problem.c_str();
}
