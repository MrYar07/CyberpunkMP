#pragma once

#include <atomic>
#include <cstdint>
#include <mutex>
#include <set>
#include <string>

#include <Windows.h>
#include <spdlog/spdlog.h>

// Which thread is allowed to touch the flecs world, and a tripwire for whoever does it from
// somewhere else. Ported from Night City Online (0fa2bb9).
//
// The flecs world is single-threaded by flecs's design: building a query takes a cursor from
// the stage's iterator stack, an allocator with no locking. Two threads in it at once corrupt
// the cursor chain - Night City Online's crash of 27 August 2026 (two threads faulting in
// flecs_stack_restore_cursor in the same millisecond).
//
// Being called from redscript says nothing about which thread arrives: the engine dispatches
// script work through its job system. Anything script-callable that touches the world either
// marshals to this thread or reads a lock-free registry instead (ServerIdRegistry.h).
namespace App::FlecsThread
{
inline std::atomic<uint32_t>& Get()
{
    static std::atomic<uint32_t> s_thread{0};
    return s_thread;
}

// Called right before progress(). Whichever thread drives the world owns it.
inline void MarkCurrent()
{
    Get().store(GetCurrentThreadId(), std::memory_order_relaxed);
}

inline bool IsCurrent()
{
    const auto owner = Get().load(std::memory_order_relaxed);
    return owner == 0 || GetCurrentThreadId() == owner;
}

// Logs once per (call site, thread) pair, so a second offending site on the same thread is
// not swallowed by the first.
inline void Assert(const char* acpSite)
{
    if (IsCurrent())
        return;

    const auto tid = GetCurrentThreadId();

    static std::mutex s_lock;
    static std::set<std::string> s_seen;

    const auto key = std::string(acpSite) + "@" + std::to_string(tid);

    std::lock_guard guard(s_lock);
    if (s_seen.insert(key).second)
    {
        spdlog::error("[Thread] {} touched flecs OFF the flecs thread: {} (flecs thread is {})", acpSite, tid,
                      Get().load(std::memory_order_relaxed));
    }
}
} // namespace App::FlecsThread
