#pragma once

#include "Core/Hooking/HookingAgent.hpp"

// Campaign co-op: guests see and hear the host's story - scenes, holocalls, phone calls,
// spawned characters, world changes - by running the very same quest nodes in their own game.
//
// Host: every quest node the game executes goes through QuestPhaseInstance::ExecuteNode. For
// node classes that change what players see or hear (not facts, journal or control flow,
// which are mirrored or host-only), the node's address is recorded: the .questphase /
// .quest resource that holds it, the chain of embedded phase nodes down to its graph, its
// id and the input socket. Script sends these to the server.
//
// Guest: loads the same resource, walks to the same node and executes it on the root phase
// with the same input socket, as Codeware's QuestPhaseExecutor does.
//
// Entry format (one per node, entries separated by ','):
//   <resource path hash>/<phase node id>.<phase node id>.../<node id>/<socket CName hash>
struct QuestMirror : Core::HookingAgent
{
    enum class Mode : int32_t
    {
        Off = 0,
        Record = 1, // host
        Replay = 2, // guest
    };

    static void Attach();

    static void SetMode(int32_t aMode);
    // Host: everything recorded since the last call, in execution order.
    static Red::CString TakeRecorded();
    // The scene that started last (host: recorded, guest: replayed); empty before any.
    static Red::CString GetSceneKey();
    // Guest: queues the entries for execution.
    static void Replay(const Red::CString& aEntries);

    // Runs queued nodes whose resources are loaded.
    static void Update();

    // SelfCheck: the root phase (0x68 on the quests system) and the resource (0x30) and graph
    // (0x40) of phases must hold objects of the expected types. Fills aDetail with what was
    // found (empty when there is nothing to check yet). May fault on a wrong layout; SelfCheck
    // runs it under SEH.
    static bool CheckLayout(std::string& aDetail);
};
