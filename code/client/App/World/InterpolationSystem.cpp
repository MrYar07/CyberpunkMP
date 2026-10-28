#include "InterpolationSystem.h"

#include <unordered_set>

#include <App/Components/AttachedComponent.h>
#include <App/Threading/ThreadService.h>
#include <App/World/PuppetRegistry.h>

#include "App/Network/NetworkService.h"
#include "RED4ext/Scripting/Natives/Generated/game/EntityStubComponentPS.hpp"
#include "RED4ext/Scripting/Natives/Generated/move/Component.hpp"
#include "RED4ext/Scripting/Natives/Generated/ent/AnimationControllerComponent.hpp"
#include <RED4ext/Scripting/Natives/Generated/vehicle/MoveSystem.hpp>
#include "RED4ext/Scripting/Natives/Generated/vehicle/BaseObject.hpp"
#include "RED4ext/Scripting/Natives/Generated/WorldPosition.hpp"
#include "RED4ext/Scripting/Natives/Vector3.hpp"

#include "Core/Hooking/HookingAgent.hpp"
#include "NetworkWorldSystem.h"
#include "App/Components/EntityComponent.h"
#include "Math/Math.h"
#include "App/Components/InterpolationComponent.h"
#include "App/Components/SpawningComponent.h"
#include "Game/Utils.h"
#include "Game/Movement.h"
#include "Game/Animation/AnimationData.h"
#include "Game/Animation/MultiMovementController.h"

#include <Math/Spline.h>

namespace
{
constexpr float kSceneReach = 1.5f;
constexpr float kSceneGap = 1.2f;

std::atomic_bool s_sceneSpacing{false};
std::mutex s_heldLock;
std::unordered_set<uint64_t> s_held;

bool IsHeld(uint64_t aEntityHash)
{
    std::lock_guard _(s_heldLock);
    return s_held.contains(aEntityHash);
}
glm::vec3 s_sceneAnchor{};
float s_sceneYaw{0.f};

glm::vec3 SpaceFromScene(const glm::vec3& aPosition, uint64_t aEntityHash)
{
    if (!s_sceneSpacing || glm::distance(aPosition, s_sceneAnchor) > kSceneReach)
        return aPosition;

    // Right of the spot's facing for one player, left for the next, further out after that.
    const auto slot = static_cast<float>(aEntityHash % 3 + 1);
    const auto side = aEntityHash % 2 == 0 ? 1.f : -1.f;
    const glm::vec3 right{std::cos(s_sceneYaw), std::sin(s_sceneYaw), 0.f};
    return s_sceneAnchor + right * (side * slot * kSceneGap);
}
} // namespace


inline void ResetWithNewTransform(Red::vehicle::BaseObject* self, const Red::WorldTransform& transform)
{
    reinterpret_cast<void (*)(Red::vehicle::BaseObject*, const Red::WorldTransform&)>(*(uintptr_t*)(*(uintptr_t*)self + 0x280))(self, transform);
}

inline void SetSimpleMovement(Red::vehicle::IMoveSystem* apMoveSystem, const Red::EntityID& aEntityId, bool enabled)
{
    reinterpret_cast<void (*)(Red::vehicle::IMoveSystem*, const Red::EntityID&, bool)>(*(uintptr_t*)(*(uintptr_t*)apMoveSystem + 0x1F0))(apMoveSystem, aEntityId, enabled);
}

void InterpolateEntity(flecs::entity aEntity, const EntityComponent& aEntityComponent, InterpolationComponent& aInterpolation, float aSimulationDelay, Red::vehicle::IMoveSystem* apMoveSystem)
{
    // Render time stays in the integer domain the ticks live in. Ticks are server milliseconds
    // since the epoch (~1.8e12); a float's 24-bit mantissa spaces representable values 131072
    // apart there, so `float tick = GetTick() - delay` ignored the delay, drained the whole
    // buffer every frame and froze remote players on their spawn point. Only differences -
    // milliseconds - may become float. Night City Online afad4cc.
    //
    // A jittery remote gets a wider buffer than the session-wide delay, bounded, so the worst
    // link no longer starves its own buffer into dead reckoning. Night City Online 2ccb708.
    constexpr float kJitterMargin = 2.f;
    constexpr float kMaxJitterMargin = 200.f;
    const float jitterExtra = std::clamp(kJitterMargin * aInterpolation.ArrivalJitter, 0.f, kMaxJitterMargin);
    const int64_t renderTick = static_cast<int64_t>(NetworkWorldSystem::GetTick()) -
                               static_cast<int64_t>(aSimulationDelay + jitterExtra);

    // Everything now behind render time becomes the anchor we interpolate FROM; the first
    // sample still ahead is what we interpolate TO. Night City Online 124ce33.
    while (!aInterpolation.TimePoints.empty() &&
           static_cast<int64_t>(aInterpolation.TimePoints.front().Tick) <= renderTick)
    {
        aInterpolation.PreviousFrame = aInterpolation.TimePoints.front();
        aInterpolation.HasPrevious = true;
        aInterpolation.TimePoints.pop_front();
    }

    // Nothing to work from yet - the puppet has spawned but no movement has arrived.
    if (!aInterpolation.HasPrevious)
        return;

    const auto pEntityStubSystem = Red::GetGameSystem<Red::game::IEntityStubSystem>();
    const auto* pStub = pEntityStubSystem->FindStub(aEntityComponent.Id);
    if (!pStub)
        return;

    if (aEntity.has<AttachedComponent>())
        return;

    if (IsHeld(aEntityComponent.Id.hash))
        return;

    const auto& first = aInterpolation.PreviousFrame;

    // Buffer starvation: a late packet leaves nothing ahead of render time. Carry on along
    // the last heading for a short while rather than stutter; past that, stand still.
    if (aInterpolation.TimePoints.empty())
    {
        constexpr int64_t kMaxExtrapolationMs = 250;

        const auto ahead = renderTick - static_cast<int64_t>(first.Tick);
        if (ahead <= 0 || ahead > kMaxExtrapolationMs || aEntityComponent.IsVehicle || !aEntityComponent.Controller)
            return;

        // Velocity is metres per second and the tick is milliseconds.
        const glm::vec3 heading{-std::sin(first.Rotation.z), std::cos(first.Rotation.z), 0.f};
        const glm::vec3 guessed = first.Position + heading * (first.Velocity * static_cast<float>(ahead) * 0.001f);

        const auto spaced = SpaceFromScene(guessed, aEntityComponent.Id.hash);
        aEntityComponent.Controller->SetTransform(Red::Vector4{spaced.x, spaced.y, spaced.z, 0.f}, first.Rotation.z,
                                                  first.Velocity);
        aInterpolation.LastRenderTick = renderTick;
        return;
    }

    const auto& second = aInterpolation.TimePoints.front();

    // Where render time sits between the two samples, 0..1.
    auto ratio = 0.f;
    const auto tickDelta = static_cast<float>(static_cast<int64_t>(second.Tick) - static_cast<int64_t>(first.Tick));
    if (tickDelta > 0.f)
        ratio = std::clamp(static_cast<float>(renderTick - static_cast<int64_t>(first.Tick)) / tickDelta, 0.f, 1.f);

    const glm::vec3 position{Lerp(first.Position, second.Position, ratio)};

    if (aEntityComponent.IsVehicle)
    {
        const auto pSystem = Red::GetGameSystem<NetworkWorldSystem>();
        const auto vehicle = Red::Cast<Red::vehicle::BaseObject>(pSystem->GetEntity(aEntityComponent.Id));
        if (vehicle)
        {
            const auto deltaAngleX{DeltaAngle(first.Rotation.x, second.Rotation.x, true) * ratio};
            const auto directionX = Mod(first.Rotation.x + deltaAngleX, 2.f * static_cast<float>(Pi));

            const auto deltaAngleY{DeltaAngle(first.Rotation.y, second.Rotation.y, true) * ratio};
            const auto directionY = Mod(first.Rotation.y + deltaAngleY, 2.f * static_cast<float>(Pi));

            const auto deltaAngleZ{DeltaAngle(first.Rotation.z, second.Rotation.z, true) * ratio};
            const auto directionZ = Mod(first.Rotation.z + deltaAngleZ, 2.f * static_cast<float>(Pi));

            const auto rot = glm::vec3(directionX, directionY, directionZ);

            auto transform = Red::WorldTransform();
            transform.Position = Red::WorldPosition(Red::Vector4{position.x, position.y, position.z, 0.f});
            transform.Orientation = Game::ToRed(glm::quat(rot));

            static Core::RawFunc<2933986803UL, void (*)(Red::vehicle::BaseObject*, const Red::WorldTransform&, float)> ForceMoveTo;
            static Core::RawFunc<457775029UL, void (*)(Red::vehicle::BaseObject*, const Red::WorldTransform&, bool)> ForceTransform;
            static Core::RawFunc<2592348558UL, void (*)(Red::vehicle::BaseObject*, uint32_t, bool)> EnablePhysics;

            SetSimpleMovement(apMoveSystem, aEntityComponent.Id, true);

            // modeled after DriveToPoint::OnUpdate_Internal, 3713079867
            using PhysicsState = Core::OffsetPtr<InterpolationSystem::kVehiclePhysicsState, uint32_t>;
            if ((PhysicsState::Ref(vehicle) & 0x100) == 0)
            {
                EnablePhysics(vehicle, 0x100, false);
            }

            // How long this move should take: the time since we last drew.
            const auto frameDelta = aInterpolation.LastRenderTick > 0
                                        ? static_cast<float>(std::max<int64_t>(renderTick - aInterpolation.LastRenderTick, 0))
                                        : 16.f;
            ForceMoveTo(vehicle, transform, frameDelta);
            //ForceTransform(vehicle, transform, true);
        }
    }
    else
    {
        if (aEntityComponent.Controller)
        {
            const auto speed{Lerp(first.Velocity, second.Velocity, ratio)};
            const auto deltaAngle{DeltaAngle(first.Rotation.z, second.Rotation.z, true) * ratio};
            const auto direction = Mod(first.Rotation.z + deltaAngle, 2.f * static_cast<float>(Pi));

            const auto spaced = SpaceFromScene(position, aEntityComponent.Id.hash);
            const auto pos = Red::Vector4{spaced.x, spaced.y, spaced.z, 0.f};
            aEntityComponent.Controller->SetTransform(pos, direction, speed);
        }
    }

    aInterpolation.LastRenderTick = renderTick;
}

void InterpolationSystem::SetSceneSpacing(bool aEnabled, const glm::vec3& aAnchor, float aYaw)
{
    s_sceneAnchor = aAnchor;
    s_sceneYaw = aYaw;
    s_sceneSpacing = aEnabled;
}

void InterpolationSystem::SetHeld(uint64_t aEntityHash, bool aHeld)
{
    std::lock_guard _(s_heldLock);
    if (aHeld)
        s_held.insert(aEntityHash);
    else
        s_held.erase(aEntityHash);
}

void InterpolationSystem::OnWorldAttached(RED4ext::world::RuntimeScene* aScene)
{
    spdlog::info("[InterpolationSystem] OnWorldAttached");

    // No OnAdd<EntityComponent> observer here any more: its callback added
    // InterpolationComponent DURING observer dispatch, a structural change mid-notify, and one
    // trigger (VehicleSystem's emplace) runs undeferred, so flecs dispatched it inline. Both
    // sites that create EntityComponent now add InterpolationComponent themselves.
    // Night City Online 98b12fa, from its flecs_stack_restore_cursor crash hunt.

    m_ready = true;
}

void InterpolationSystem::OnAfterWorldDetach()
{
    spdlog::info("[InterpolationSystem] OnAfterWorldDetach");

    m_ready = false;

    // A scene cut short by loading or quitting leaves nothing behind for the next world.
    s_sceneSpacing = false;
    {
        std::lock_guard _(s_heldLock);
        s_held.clear();
    }
}

void InterpolationSystem::OnConnected()
{
    const auto pNetworkService = Core::Container::Get<NetworkService>();

    const float cSimulationDelay = 50.f + (1500.f / pNetworkService->GetServerSettings().get_update_rate());

    const auto pSystem = Red::GetGameSystem<NetworkWorldSystem>();
    const auto pMoveSystem = Red::GetGameSystem<RED4ext::vehicle::IMoveSystem>();

    m_interpolator = pSystem->system<const EntityComponent, InterpolationComponent>().each(
        [cSimulationDelay, pMoveSystem](flecs::entity aEntity, const EntityComponent& aEntityComponent, InterpolationComponent& aInterpolation)
        {
            InterpolateEntity(aEntity, aEntityComponent, aInterpolation, cSimulationDelay, pMoveSystem);
        });
}

void InterpolationSystem::OnDisconnected()
{
    if (m_interpolator)
        m_interpolator.destruct();
}

void InterpolationSystem::HandleNotifyEntityMove(const PacketEvent<server::NotifyEntityMove>& aMessage)
{
    const auto pSystem = Red::GetGameSystem<NetworkWorldSystem>();
    const auto entity = pSystem->GetEntityByServerId(aMessage.get_id());

    const glm::vec3 position{aMessage.get_position().get_x(), aMessage.get_position().get_y(), aMessage.get_position().get_z()};
    glm::vec3 rotation{0.f, 0.f, 0.f};

    if (aMessage.has_full_rotation())
        rotation = {aMessage.get_full_rotation().get_x(), aMessage.get_full_rotation().get_y(), aMessage.get_full_rotation().get_z()};
    else
        rotation = {0.f, 0.f, aMessage.get_rotation()};

    if (!entity)
        return;

    // Tick 0 means "has not moved yet", not a timestamp fifty-odd years ago: as an anchor it
    // froze the remote player on their spawn point. Night City Online b2507a2.
    if (aMessage.get_tick() == 0)
        return;

    // Null until the entity's InterpolationComponent exists; a player's first movement can
    // arrive before that.
    auto* pInterpolation = entity.get_mut<InterpolationComponent>();
    if (!pInterpolation)
        return;

    // Out-of-order samples are dropped - including ones older than the anchor once the
    // buffer has drained, which would otherwise drag the puppet backwards.
    if (!pInterpolation->TimePoints.empty())
    {
        if (pInterpolation->TimePoints.back().Tick > aMessage.get_tick())
            return;
    }
    else if (pInterpolation->HasPrevious && pInterpolation->PreviousFrame.Tick > aMessage.get_tick())
    {
        return;
    }

    // Arrival jitter for this remote's interpolation margin (InterpolationComponent).
    const int64_t transit = static_cast<int64_t>(NetworkWorldSystem::GetTick()) - static_cast<int64_t>(aMessage.get_tick());
    if (pInterpolation->HasTransit)
    {
        const auto change = std::abs(transit - pInterpolation->LastTransit);
        pInterpolation->ArrivalJitter += (static_cast<float>(change) - pInterpolation->ArrivalJitter) / 16.f;
    }
    pInterpolation->LastTransit = transit;
    pInterpolation->HasTransit = true;

    pInterpolation->TimePoints.push_back(InterpolationComponent::Timepoint{position, rotation, aMessage.get_speed(), aMessage.get_tick()});
}

static Core::RawFunc<4018412273UL, float (*)(Red::move::Component*, MultiMovementController*)> AttachController;

void (*RealIdleController_SetAnimation)(Game::Controller*, AnimationData&);
void HookIdleController_SetAnimation(Game::Controller* apController, AnimationData& data)
{
    auto* pMoveComponent = apController->MoveComponent;
    Game::EntityPtr entity(pMoveComponent);
    if (const auto pOwner = Red::Cast<Red::GameObject>(entity.GetValuePtr()))
    {
        // This hook runs on the game's ANIMATION thread. Reading pOwner->tags here
        // walks a heap DynArray on an entity the main thread may still be building,
        // which raced and crashed the game shortly after a remote player spawned.
        // PuppetRegistry only touches the entity's 64-bit id.
        if (App::PuppetRegistry::Contains(pOwner->entityID.hash))
        {
            if (apController->m_type == MultiMovementController::kMulti)
                return;

            ThreadService::RunInMainThread([id = pOwner->entityID, pMoveComponent, apController]
            {
                const auto pSystem = Red::GetGameSystem<NetworkWorldSystem>();
                const auto entityQuery = pSystem->query<const EntityComponent>();
                auto flecsEntity = entityQuery.find([id](const EntityComponent& component) { return component.Id == id; });

                auto* pController = Red::Memory::New<MultiMovementController>();
                AttachController(pMoveComponent, pController);

                if (flecsEntity)
                {
                    flecsEntity.get_mut<EntityComponent>()->Controller = pController;
                }
                else
                {
                    const auto spawnQuery = pSystem->query<const SpawningComponent>();
                    flecsEntity = spawnQuery.find([id](const SpawningComponent& component) { return component.Id == id; });
                    if (flecsEntity)
                    {
                        flecsEntity.get_mut<SpawningComponent>()->Controller = pController;
                    }
                }                
            });

            return;
        }
    }

    RealIdleController_SetAnimation(apController, data);
}


void InterpolationSystem::OnInitialize(const RED4ext::JobHandle& aJob)
{
    Hook<Game::IdleController_SetAnimation>(&HookIdleController_SetAnimation, &RealIdleController_SetAnimation);

    const auto pNetworkService = Core::Container::Get<NetworkService>();
    pNetworkService->RegisterHandler<&InterpolationSystem::HandleNotifyEntityMove>(this);
}
