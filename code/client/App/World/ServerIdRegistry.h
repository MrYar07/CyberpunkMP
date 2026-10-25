#pragma once

#include <array>
#include <atomic>
#include <cstdint>
#include <mutex>

// Lock-free map between an engine EntityID hash and the server id we know that entity by,
// readable from any thread. Ported from Night City Online (559828f), plus the reverse lookup
// (server id -> EntityID) that the campaign scripts need.
//
// Why: script-callable natives (OnVehicleEnter, GetEntityIdByServerId) used to answer through
// the flecs world. The engine calls them from its job threads, and flecs is single-threaded
// (FlecsThread.h). Night City Online caught FindEntity arriving from 14-16 distinct threads in
// one session; the result was the flecs_stack_restore_cursor crash.
//
// Why lock-free and not a mutex: PuppetRegistry's history - a mutex on a hot read path cost
// frame rate. Reads are a bounded scan of relaxed atomics; writes take a mutex but happen only
// when an entity is spawned or removed, on the main thread.
//
// Beyond kCapacity networked entities the extras simply do not resolve ("not one of ours").
namespace App::ServerIdRegistry
{
inline constexpr size_t kCapacity = 512;

inline std::array<std::atomic<uint64_t>, kCapacity>& GetEntityIds()
{
    static std::array<std::atomic<uint64_t>, kCapacity> s_entityIds{};
    return s_entityIds;
}

inline std::array<std::atomic<uint64_t>, kCapacity>& GetServerIds()
{
    static std::array<std::atomic<uint64_t>, kCapacity> s_serverIds{};
    return s_serverIds;
}

// Writers only. Readers never take this.
inline std::mutex& GetWriteMutex()
{
    static std::mutex s_mutex;
    return s_mutex;
}

// How far a reader has to scan. Never decreases while anything is registered.
inline std::atomic<size_t>& GetHighWater()
{
    static std::atomic<size_t> s_highWater{0};
    return s_highWater;
}

namespace Detail
{
// Caller holds the write mutex.
inline void ClearRow(size_t aIndex)
{
    // Entity id first, so no reader matches the row while the server id is torn down.
    GetEntityIds()[aIndex].store(0, std::memory_order_release);
    GetServerIds()[aIndex].store(0, std::memory_order_release);
}
} // namespace Detail

// One row per server id: re-adding a server id (a vehicle whose spawned copy got a new
// EntityID) replaces the old row instead of leaving it to shadow the new one.
inline void Add(uint64_t aEntityIdHash, uint64_t aServerId)
{
    if (aEntityIdHash == 0 || aServerId == 0)
        return; // zero is the empty marker

    std::lock_guard _(GetWriteMutex());

    auto& entityIds = GetEntityIds();
    auto& serverIds = GetServerIds();

    for (size_t i = 0; i < kCapacity; ++i)
    {
        const auto entity = entityIds[i].load(std::memory_order_relaxed);
        const auto server = serverIds[i].load(std::memory_order_relaxed);
        if (entity == aEntityIdHash && server == aServerId)
            return;
        if (entity != 0 && (entity == aEntityIdHash || server == aServerId))
            Detail::ClearRow(i);
    }

    for (size_t i = 0; i < kCapacity; ++i)
    {
        if (entityIds[i].load(std::memory_order_relaxed) == 0)
        {
            // Server id FIRST, entity id second with release: a reader that sees the entity
            // id is guaranteed to see the server id that goes with it.
            serverIds[i].store(aServerId, std::memory_order_relaxed);
            entityIds[i].store(aEntityIdHash, std::memory_order_release);

            auto& highWater = GetHighWater();
            if (highWater.load(std::memory_order_relaxed) < i + 1)
                highWater.store(i + 1, std::memory_order_release);

            return;
        }
    }
}

inline void RemoveServer(uint64_t aServerId)
{
    if (aServerId == 0)
        return;

    std::lock_guard _(GetWriteMutex());

    auto& serverIds = GetServerIds();
    for (size_t i = 0; i < kCapacity; ++i)
    {
        if (serverIds[i].load(std::memory_order_relaxed) == aServerId)
            Detail::ClearRow(i);
    }
}

// Safe from any thread. 0 = "not one of ours", the common case.
inline uint64_t Find(uint64_t aEntityIdHash)
{
    if (aEntityIdHash == 0)
        return 0;

    const auto high = GetHighWater().load(std::memory_order_acquire);
    auto& entityIds = GetEntityIds();
    auto& serverIds = GetServerIds();

    for (size_t i = 0; i < high; ++i)
    {
        if (entityIds[i].load(std::memory_order_acquire) == aEntityIdHash)
            return serverIds[i].load(std::memory_order_acquire);
    }

    return 0;
}

// Safe from any thread. 0 = unknown server id.
inline uint64_t FindEntity(uint64_t aServerId)
{
    if (aServerId == 0)
        return 0;

    const auto high = GetHighWater().load(std::memory_order_acquire);
    auto& entityIds = GetEntityIds();
    auto& serverIds = GetServerIds();

    for (size_t i = 0; i < high; ++i)
    {
        if (serverIds[i].load(std::memory_order_acquire) == aServerId)
        {
            const auto entity = entityIds[i].load(std::memory_order_acquire);
            // Re-check: the row may have been cleared between the two loads.
            if (entity != 0 && serverIds[i].load(std::memory_order_acquire) == aServerId)
                return entity;
        }
    }

    return 0;
}

inline void Clear()
{
    std::lock_guard _(GetWriteMutex());

    for (size_t i = 0; i < kCapacity; ++i)
        Detail::ClearRow(i);

    GetHighWater().store(0, std::memory_order_release);
}
} // namespace App::ServerIdRegistry
