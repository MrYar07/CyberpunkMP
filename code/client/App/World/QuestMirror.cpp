#include "QuestMirror.h"
#include "SelfCheck.h"

#include <RED4ext/ResourceLoader.hpp>
#include <RED4ext/Scripting/Natives/CResource.hpp>
#include <RED4ext/SharedSpinLock.hpp>
#include <RED4ext/Scripting/Natives/Generated/quest/QuestsSystem.hpp>
#include <RED4ext/Scripting/Natives/Generated/quest/PhaseInstance.hpp>
#include <RED4ext/Scripting/Natives/Generated/quest/NodeDefinition.hpp>
#include <RED4ext/Scripting/Natives/Generated/quest/PhaseNodeDefinition.hpp>
#include <RED4ext/Scripting/Natives/Generated/quest/QuestPhaseResource.hpp>
#include <RED4ext/Scripting/Natives/Generated/quest/GraphDefinition.hpp>
#include <RED4ext/Scripting/Natives/Generated/graph/GraphResource.hpp>
#include <RED4ext/Scripting/Natives/Generated/graph/GraphDefinition.hpp>

namespace
{
// Engine layouts and functions as Codeware uses them (vendor/Codeware/src/Red/QuestsSystem.hpp,
// App/Quest/QuestPhaseExecutor.hpp; MIT).
using QuestNodeID = uint16_t;
using QuestNodePath = Red::DynArray<QuestNodeID>;

struct QuestPhaseContext
{
    virtual ~QuestPhaseContext() = default;

    uintptr_t game;              // 08
    uintptr_t unk1;              // 10
    uintptr_t unk2;              // 18
    uintptr_t unk3;              // 20
    uintptr_t unk4;              // 28
    void* prefabLoader;          // 30
    uint8_t unk38[0x230 - 0x38]; // 38
};
static_assert(sizeof(QuestPhaseContext) == 0x230);

struct QuestContext
{
    uint8_t unk0[0xF8];                            // 00
    Red::DynArray<Red::quest::PhaseInstance*> phaseStack; // F8
    QuestNodeID nodeID;                            // 108
    QuestPhaseContext phaseContext;                // 110
};
static_assert(sizeof(QuestContext) == 0x340);
static_assert(offsetof(QuestContext, phaseStack) == 0xF8);

struct QuestNodeSocket
{
    QuestNodeSocket(Red::CName aName = {})
        : name(aName)
        , unk08(0)
    {
    }

    Red::CName name;
    uint8_t unk08;
};

using QuestsMutex = Core::OffsetPtr<0x60, Red::SharedSpinLock>;
using RootPhase = Core::OffsetPtr<0x68, Red::Handle<Red::quest::PhaseInstance>>;

using PhaseResource = Core::OffsetPtr<0x30, Red::Handle<Red::quest::QuestPhaseResource>>;
using PhaseGraph = Core::OffsetPtr<0x40, Red::Handle<Red::quest::GraphDefinition>>;

// SelfCheck of PhaseResource/PhaseGraph on the first phase the game runs a node in that has a
// graph (the root phase has neither). Written once from the hook, read by CheckLayout.
std::mutex s_phaseCheckLock;
std::atomic<bool> s_phaseCheckDone = false;
bool s_phaseCheckOk = false;
std::string s_phaseCheck;

struct PhaseCheck
{
    Red::quest::PhaseInstance* pPhase;
    bool found;
    bool ok;
    std::string detail;
};

void CheckPhase(void* apContext)
{
    auto& check = *static_cast<PhaseCheck*>(apContext);
    const auto& graph = PhaseGraph::Ref(check.pPhase);
    if (!graph)
        return;

    const auto& resource = PhaseResource::Ref(check.pPhase);
    const auto graphOk = graph->GetType()->IsA(Red::GetClass<Red::quest::GraphDefinition>());
    const auto resourceOk = !resource || resource->GetType()->IsA(Red::GetClass<Red::CResource>());
    check.found = true;
    check.ok = graphOk && resourceOk;
    check.detail = std::format("a running phase ({}): resource (0x30) {}, graph (0x40) {}",
                               check.pPhase->GetType()->GetName().ToString(),
                               resource ? resource->GetType()->GetName().ToString() : "null",
                               graph->GetType()->GetName().ToString());
}

constexpr auto CreateContext = Core::RawFunc<
    /* hash = */ 3144298192UL,
    /* type = */ void* (*)(Red::quest::QuestsSystem*, QuestContext*, int32_t, int8_t, int32_t, int32_t)>();

uint8_t (*RealExecuteNode)(Red::quest::PhaseInstance*, Red::quest::NodeDefinition*, QuestContext&,
                           const QuestNodeSocket&, Red::DynArray<QuestNodeSocket>&);

constexpr auto PhaseInstance_ExecuteNode = Core::RawFunc<
    /* hash = */ 3227858325UL,
    /* type = */ decltype(RealExecuteNode)>();

// What players see or hear. Facts and the journal are mirrored on their own; control flow,
// conditions, phases and checkpoints stay with the host's game, which runs the story.
constexpr const char* kMirroredNodes[] = {
    "questSceneNodeDefinition",
    "questSceneManagerNodeDefinition",
    "questPhoneManagerNodeDefinition",
    "questAudioNodeDefinition",
    "questAudioCharacterManagerNodeDefinition",
    "questVoicesetManagerNodeDefinition",
    "questSpawnManagerNodeDefinition",
    "questDynamicSpawnSystemNodeDefinition",
    "questEntityManagerNodeDefinition",
    "questCharacterManagerNodeDefinition",
    "questCrowdManagerNodeDefinition",
    "questPopulactionControllerNodeDefinition",
    "questWorldDataManagerNodeDefinition",
    "questEnvironmentManagerNodeDefinition",
    "questTimeManagerNodeDefinition",
    "questFXManagerNodeDefinition",
    "questRenderFxManagerNodeDefinition",
    "questInteractiveObjectManagerNodeDefinition",
    "questTeleportPuppetNodeDefinition",
    "questMovePuppetNodeDefinition",
    "questRotateToNodeDefinition",
    "questUseWorkspotNodeDefinition",
    "questPuppetAIManagerNodeDefinition",
    "questForcedBehaviourNodeDefinition",
    "questClearForcedBehavioursNodeDefinition",
    "questBehaviourManagerNodeDefinition",
    "questSendAICommandNodeDefinition",
    "questVehicleNodeDefinition",
    "questTeleportVehicleNodeDefinition",
    "questMappinManagerNodeDefinition",
    "questRewardManagerNodeDefinition",
};

// Scenes and calls are woken again by the engine while they run; only their start is news.
constexpr const char* kStartOnlyNodes[] = {
    "questSceneNodeDefinition",
    "questPhoneManagerNodeDefinition",
};
constexpr auto kStartOnlyWindow = std::chrono::minutes(5);
constexpr auto kRepeatWindow = std::chrono::seconds(2);

std::atomic_int32_t s_mode{static_cast<int32_t>(QuestMirror::Mode::Off)};
thread_local bool s_replaying{false};
bool s_attached{false};

std::mutex s_lock;
// The scene that started last: "<resource hash>/<phase node ids>/<node id>", the same in
// every game (campaign scene poses are keyed by it).
std::string s_sceneKey;
std::vector<Red::CClass*> s_mirrored;
std::vector<Red::CClass*> s_startOnly;
std::string s_recorded;
std::unordered_map<std::string, std::chrono::steady_clock::time_point> s_lastSeen;

struct PendingNode
{
    uint64_t resource;
    std::vector<QuestNodeID> phases;
    QuestNodeID node;
    uint64_t socket;
    Red::SharedPtr<Red::ResourceToken<Red::graph::GraphResource>> token;
    std::chrono::steady_clock::time_point queued;
};
std::deque<PendingNode> s_pending;
// A resource that neither loads nor fails within this time is given up on: the queue runs in
// order, and one stuck entry would hold back every scene after it.
constexpr auto kLoadTimeout = std::chrono::seconds(30);

void ResolveClasses()
{
    if (!s_mirrored.empty())
        return;

    for (const auto* name : kMirroredNodes)
    {
        if (auto* pClass = Red::CRTTISystem::Get()->GetClass(name))
            s_mirrored.push_back(pClass);
        else
            spdlog::warn("[QuestMirror] unknown node class {}", name);
    }
    for (const auto* name : kStartOnlyNodes)
    {
        if (auto* pClass = Red::CRTTISystem::Get()->GetClass(name))
            s_startOnly.push_back(pClass);
    }
}

bool IsSceneNode(Red::CClass* aClass)
{
    static auto* pScene = Red::CRTTISystem::Get()->GetClass("questSceneNodeDefinition");
    return pScene && aClass == pScene;
}

template<typename T>
T* As(Red::ISerializable* apObject)
{
    if (!apObject)
        return nullptr;
    return apObject->GetType()->IsA(Red::GetClass<T>()) ? static_cast<T*>(apObject) : nullptr;
}

bool IsOneOf(const std::vector<Red::CClass*>& aClasses, Red::CClass* aClass)
{
    return std::find(aClasses.begin(), aClasses.end(), aClass) != aClasses.end();
}

Red::quest::NodeDefinition* FindNode(const Red::Handle<Red::graph::GraphDefinition>& aGraph, QuestNodeID aId)
{
    if (!aGraph)
        return nullptr;

    for (const auto& node : aGraph->nodes)
    {
        auto* pNode = As<Red::quest::NodeDefinition>(node.instance);
        if (pNode && pNode->id == aId)
            return pNode;
    }
    return nullptr;
}

// The chain of embedded phase nodes from aRoot down to aTarget, depth first.
bool FindGraphPath(const Red::Handle<Red::graph::GraphDefinition>& aRoot, const Red::graph::GraphDefinition* aTarget,
                   std::vector<QuestNodeID>& aPath)
{
    if (!aRoot)
        return false;
    if (aRoot.instance == aTarget)
        return true;

    for (const auto& node : aRoot->nodes)
    {
        auto* pPhase = As<Red::quest::PhaseNodeDefinition>(node.instance);
        if (!pPhase || !pPhase->phaseGraph)
            continue;

        aPath.push_back(pPhase->id);
        if (FindGraphPath(Red::Handle<Red::graph::GraphDefinition>(pPhase->phaseGraph), aTarget, aPath))
            return true;
        aPath.pop_back();
    }
    return false;
}

// Host side: where this node lives, as an entry for the guests.
void Record(Red::quest::PhaseInstance* apPhase, Red::quest::NodeDefinition* apNode, QuestContext& aContext,
            const QuestNodeSocket& aSocket)
{
    auto* pClass = apNode->GetType();
    if (!IsOneOf(s_mirrored, pClass))
        return;

    const auto& graph = PhaseGraph::Ref(apPhase);
    if (!graph)
        return;

    // The phase itself, or the nearest phase above it, holds the resource the graph came from.
    Red::Handle<Red::quest::QuestPhaseResource> resource = PhaseResource::Ref(apPhase);
    for (auto i = static_cast<int32_t>(aContext.phaseStack.size()) - 1; !resource && i >= 0; --i)
    {
        if (auto* pParent = aContext.phaseStack[i])
            resource = PhaseResource::Ref(pParent);
    }
    if (!resource)
        return;

    std::vector<QuestNodeID> phases;
    if (!FindGraphPath(resource->graph, graph.instance, phases))
        return;

    std::string entry = std::to_string(resource->path.hash) + "/";
    for (size_t i = 0; i < phases.size(); ++i)
    {
        if (i > 0)
            entry += ".";
        entry += std::to_string(phases[i]);
    }
    entry += "/" + std::to_string(apNode->id);
    const auto key = entry;
    entry += "/" + std::to_string(static_cast<uint64_t>(aSocket.name));

    const auto now = std::chrono::steady_clock::now();
    const auto window = IsOneOf(s_startOnly, pClass) ? std::chrono::duration_cast<std::chrono::steady_clock::duration>(kStartOnlyWindow)
                                                      : std::chrono::duration_cast<std::chrono::steady_clock::duration>(kRepeatWindow);
    if (auto it = s_lastSeen.find(entry); it != s_lastSeen.end() && now - it->second < window)
        return;
    s_lastSeen[entry] = now;

    if (IsSceneNode(pClass))
        s_sceneKey = key;

    if (!s_recorded.empty())
        s_recorded += ",";
    s_recorded += entry;
}

uint8_t HookExecuteNode(Red::quest::PhaseInstance* apPhase, Red::quest::NodeDefinition* apNode, QuestContext& aContext,
                        const QuestNodeSocket& aSocket, Red::DynArray<QuestNodeSocket>& aOutputSockets)
{
    if (!s_phaseCheckDone && apPhase)
    {
        std::lock_guard _(s_phaseCheckLock);
        if (!s_phaseCheckDone)
        {
            PhaseCheck check{apPhase};
            if (!SelfCheck::Guarded(&CheckPhase, &check))
            {
                s_phaseCheckDone = true;
                s_phaseCheck = "reading a running phase raised an exception";
            }
            else if (check.found)
            {
                s_phaseCheckDone = true;
                s_phaseCheckOk = check.ok;
                s_phaseCheck = check.detail;
                SelfCheck::Log({"quest phases", check.ok ? SelfCheck::Status::Ok : SelfCheck::Status::Fail, check.detail});
            }
        }
    }

    if (s_mode == static_cast<int32_t>(QuestMirror::Mode::Record) && !s_replaying && apPhase && apNode)
    {
        std::lock_guard _(s_lock);
        Record(apPhase, apNode, aContext, aSocket);
    }

    return RealExecuteNode(apPhase, apNode, aContext, aSocket, aOutputSockets);
}

bool ParseEntry(const std::string& aEntry, PendingNode& aOut)
{
    std::vector<std::string> parts;
    size_t start = 0;
    while (true)
    {
        const auto end = aEntry.find('/', start);
        parts.push_back(aEntry.substr(start, end - start));
        if (end == std::string::npos)
            break;
        start = end + 1;
    }
    if (parts.size() != 4)
        return false;

    try
    {
        aOut.resource = std::stoull(parts[0]);
        size_t from = 0;
        while (from < parts[1].size())
        {
            const auto dot = parts[1].find('.', from);
            aOut.phases.push_back(static_cast<QuestNodeID>(std::stoul(parts[1].substr(from, dot - from))));
            if (dot == std::string::npos)
                break;
            from = dot + 1;
        }
        aOut.node = static_cast<QuestNodeID>(std::stoul(parts[2]));
        aOut.socket = std::stoull(parts[3]);
    }
    catch (const std::exception&)
    {
        return false;
    }
    return true;
}

// Guest side: the node the entry points at, once its resource is loaded.
Red::quest::NodeDefinition* Resolve(const PendingNode& aPending)
{
    auto graph = aPending.token->Get()->graph;
    for (const auto id : aPending.phases)
    {
        auto* pPhase = As<Red::quest::PhaseNodeDefinition>(FindNode(graph, id));
        if (!pPhase || !pPhase->phaseGraph)
            return nullptr;
        graph = Red::Handle<Red::graph::GraphDefinition>(pPhase->phaseGraph);
    }
    return FindNode(graph, aPending.node);
}

void Execute(Red::quest::NodeDefinition* apNode, Red::CName aSocket)
{
    auto* pQuests = Red::GetGameSystem<Red::quest::QuestsSystem>();
    if (!pQuests)
        return;

    auto& rootPhase = RootPhase::Ref(pQuests);
    if (!rootPhase)
        return;

    std::unique_lock _(QuestsMutex::Ref(pQuests));

    QuestContext context{};
    CreateContext(pQuests, &context, 1, 0, -1, -1);
    context.phaseStack.PushBack(rootPhase.instance);

    QuestNodeSocket inputSocket(aSocket);
    Red::DynArray<QuestNodeSocket> outputSockets;

    s_replaying = true;
    RealExecuteNode(rootPhase.instance, apNode, context, inputSocket, outputSockets);
    s_replaying = false;

    context.phaseStack.Clear();
}
} // namespace

void QuestMirror::Attach()
{
    if (s_attached)
        return;

    s_attached = Hook<PhaseInstance_ExecuteNode>(&HookExecuteNode, &RealExecuteNode);
    if (!s_attached)
        spdlog::error("[QuestMirror] could not hook QuestPhaseInstance::ExecuteNode, guests will not see the host's scenes");
}

void QuestMirror::SetMode(int32_t aMode)
{
    std::lock_guard _(s_lock);
    ResolveClasses();
    s_mode = aMode;
    s_recorded.clear();
    s_lastSeen.clear();
    s_pending.clear();
}

bool QuestMirror::CheckLayout(std::string& aDetail)
{
    auto* pQuests = Red::GetGameSystem<Red::quest::QuestsSystem>();
    if (!pQuests)
        return false;

    const auto& root = RootPhase::Ref(pQuests);
    if (!root)
        return false;

    const auto typeName = [](Red::ISerializable* apObject) -> std::string
    { return apObject ? apObject->GetType()->GetName().ToString() : "null"; };

    const auto& resource = PhaseResource::Ref(root.instance);
    const auto& graph = PhaseGraph::Ref(root.instance);
    const auto rootOk = root->GetType()->IsA(Red::GetClass<Red::quest::PhaseInstance>());
    // Null is a valid value for both; only an object of another type means a wrong offset.
    const auto resourceOk = !resource || resource->GetType()->IsA(Red::GetClass<Red::CResource>());
    const auto graphOk = !graph || graph->GetType()->IsA(Red::GetClass<Red::quest::GraphDefinition>());

    aDetail = std::format("root phase (0x68): {}; its resource (0x30): {}; its graph (0x40): {}", typeName(root.instance),
                          typeName(resource.instance), typeName(graph.instance));

    std::lock_guard _(s_phaseCheckLock);
    aDetail += "; " + (s_phaseCheckDone ? s_phaseCheck : std::string("no phase with a graph has run a node yet"));
    return rootOk && resourceOk && graphOk && (!s_phaseCheckDone || s_phaseCheckOk);
}

Red::CString QuestMirror::GetSceneKey()
{
    std::lock_guard _(s_lock);
    return Red::CString(s_sceneKey.c_str());
}

Red::CString QuestMirror::TakeRecorded()
{
    std::lock_guard _(s_lock);
    Red::CString out(s_recorded.c_str());
    s_recorded.clear();
    return out;
}

void QuestMirror::Replay(const Red::CString& aEntries)
{
    if (s_mode != static_cast<int32_t>(Mode::Replay) || !s_attached)
        return;

    std::lock_guard _(s_lock);

    const std::string entries = aEntries.c_str();
    size_t start = 0;
    while (start < entries.size())
    {
        auto end = entries.find(',', start);
        if (end == std::string::npos)
            end = entries.size();

        PendingNode pending{};
        if (ParseEntry(entries.substr(start, end - start), pending))
        {
            pending.token = Red::ResourceLoader::Get()->LoadAsync<Red::graph::GraphResource>(Red::ResourcePath(pending.resource));
            pending.queued = std::chrono::steady_clock::now();
            s_pending.push_back(std::move(pending));
        }
        else
        {
            spdlog::warn("[QuestMirror] bad entry {}", entries.substr(start, end - start));
        }
        start = end + 1;
    }
}

void QuestMirror::Update()
{
    if (s_mode != static_cast<int32_t>(Mode::Replay))
        return;

    // In order: a node may rely on an earlier one (a spawn before the scene that uses it).
    while (true)
    {
        PendingNode pending;
        {
            std::lock_guard _(s_lock);
            if (s_pending.empty())
                return;

            auto& front = s_pending.front();
            if (!front.token || front.token->IsFailed())
            {
                spdlog::warn("[QuestMirror] resource {} could not be loaded, node {} skipped", front.resource, front.node);
                s_pending.pop_front();
                continue;
            }
            if (!front.token->IsLoaded())
            {
                if (std::chrono::steady_clock::now() - front.queued < kLoadTimeout)
                    return;
                spdlog::warn("[QuestMirror] resource {} did not load in time, node {} skipped", front.resource, front.node);
                s_pending.pop_front();
                continue;
            }

            pending = std::move(front);
            s_pending.pop_front();
        }

        // Outside the lock: the node runs through our own hook.
        if (auto* pNode = Resolve(pending))
        {
            if (IsSceneNode(pNode->GetType()))
            {
                std::string key = std::to_string(pending.resource) + "/";
                for (size_t i = 0; i < pending.phases.size(); ++i)
                {
                    if (i > 0)
                        key += ".";
                    key += std::to_string(pending.phases[i]);
                }
                key += "/" + std::to_string(pending.node);
                std::lock_guard _(s_lock);
                s_sceneKey = key;
            }
            Execute(pNode, Red::CName(pending.socket));
        }
        else
            spdlog::warn("[QuestMirror] node {} not found in resource {}", pending.node, pending.resource);
    }
}
