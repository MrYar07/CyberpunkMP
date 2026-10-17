#include "SceneSpots.h"

#include <RED4ext/Scripting/Natives/Generated/world/AISpotNode.hpp>
#include <RED4ext/Scripting/Natives/Generated/AI/ActionSpot.hpp>
#include <RED4ext/Scripting/Natives/Generated/Transform.hpp>
#include <RED4ext/Scripting/Natives/Generated/Vector3.hpp>

namespace
{
// Sector node data as Codeware reads it (vendor/Codeware/src/Red/StreamingSector.hpp; MIT).
struct alignas(0x10) CompiledNodeInstanceSetupInfo
{
    Red::Transform transform;            // 00
    Red::Vector3 scale;                  // 20
    Red::Vector3 secondaryRefPointPosition; // 2C
    Red::Vector3 streamingRefPoint;      // 38
    Red::Vector3 unk44;                  // 44
    Red::world::Node* node;              // 50
    uint64_t globalNodeID;               // 58
    uint64_t proxyNodeID;                // 60
    Red::ResourcePath unk68;             // 68
    float secondaryRefPointDistance;     // 70
    float streamingDistance;             // 74
    uint16_t nodeIndex;                  // 78
    uint16_t unk7A;                      // 7A
    uint16_t unk7C;                      // 7C
    uint16_t unk7E;                      // 7E
    uint64_t unk80;                      // 80
    uint64_t unk88;                      // 88
};
static_assert(sizeof(CompiledNodeInstanceSetupInfo) == 0x90);
static_assert(offsetof(CompiledNodeInstanceSetupInfo, node) == 0x50);

using NodeSetups = Core::OffsetPtr<0x40, Red::DataBuffer>;

struct SpotPath
{
    const char* path;
    int32_t kind;
};

constexpr SpotPath kSpots[] = {
#include "SceneSpotsData.inl"
};

const std::unordered_map<uint64_t, int32_t>& Kinds()
{
    static const auto s_kinds = []
    {
        std::unordered_map<uint64_t, int32_t> kinds;
        for (const auto& spot : kSpots)
            kinds[Red::ResourcePath(spot.path).hash] = spot.kind;
        return kinds;
    }();
    return s_kinds;
}

// Rotates (0, 1, 0) - the facing of an entity - by the spot's orientation.
std::pair<float, float> Forward(const Red::Quaternion& q)
{
    const float x = 2.f * (q.i * q.j - q.r * q.k);
    const float y = 1.f - 2.f * (q.i * q.i + q.k * q.k);
    return {x, y};
}
} // namespace

Red::CString SceneSpots::Find(const Red::Handle<Red::world::StreamingSector>& aSector, const Red::Vector4& aCenter, float aRadius)
{
    if (!aSector)
        return {};

    const auto& kinds = Kinds();
    auto* pAISpotNode = Red::GetClass<Red::world::AISpotNode>();
    auto* pActionSpot = Red::GetClass<Red::AI::ActionSpot>();

    const auto& setups = NodeSetups::Ref(aSector.instance);
    const auto* pBegin = static_cast<CompiledNodeInstanceSetupInfo*>(setups.buffer.data);
    const auto count = setups.buffer.size / sizeof(CompiledNodeInstanceSetupInfo);
    const auto radius2 = aRadius * aRadius;

    std::string out;
    for (size_t i = 0; i < count; ++i)
    {
        const auto& setup = pBegin[i];
        const auto& position = setup.transform.position;
        const auto dx = position.X - aCenter.X;
        const auto dy = position.Y - aCenter.Y;
        const auto dz = position.Z - aCenter.Z;
        if (dx * dx + dy * dy + dz * dz > radius2)
            continue;

        if (!setup.node || !setup.node->GetType()->IsA(pAISpotNode))
            continue;

        auto* pNode = static_cast<Red::world::AISpotNode*>(setup.node);
        if (!pNode->spot || !pNode->spot->GetType()->IsA(pActionSpot))
            continue;

        auto* pSpot = static_cast<Red::AI::ActionSpot*>(pNode->spot.instance);
        const auto kind = kinds.find(pSpot->resource.path.hash);
        if (kind == kinds.end())
            continue;

        const auto [fx, fy] = Forward(setup.transform.orientation);
        if (!out.empty())
            out += ";";
        out += fmt::format("{}:{}:{}:{}:{}:{}:{}", setup.globalNodeID, position.X, position.Y, position.Z, fx, fy, kind->second);
    }

    return out.c_str();
}
