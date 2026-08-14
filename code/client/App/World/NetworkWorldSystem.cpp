#include <RED4ext/Scripting/Natives/entIPlacedComponent.hpp>
#include "NetworkWorldSystem.h"

#include <App/Settings.h>

#include "App/Network/NetworkService.h"
#include "RED4ext/Scripting/Natives/Generated/game/Puppet.hpp"
#include "RED4ext/Scripting/Natives/Generated/vehicle/BaseObject.hpp"
#include "RED4ext/Scripting/Natives/gameIEntityStubSystem.hpp"
#include "RED4ext/Scripting/Natives/Generated/game/EntityStubComponentPS.hpp"
#include <RED4ext/Scripting/Natives/Generated/game/mounting/MountingFacility.hpp>
#include <RED4ext/Scripting/Natives/Generated/game/mounting/MountingInfo.hpp>
#include <RED4ext/Scripting/Natives/Generated/vehicle/MoveSystem.hpp>

#include "App/Components/EntityComponent.h"
#include "App/Components/SpawningComponent.h"
#include "App/Components/InterpolationComponent.h"
#include "App/World/FlecsThread.h"
#include "App/World/PuppetRegistry.h"
#include "App/World/ServerIdRegistry.h"
#include "Game/Utils.h"
#include "Game/CharacterCustomizationSystem.h"

#include "ChatSystem.h"
#include "ChoiceInput.h"
#include "QuestMirror.h"
#include "CoopConnect.h"
#include "SelfCheck.h"

static uint64_t GTick = 0;

uint64_t NetworkWorldSystem::GetTick()
{
    return GTick;
}

NetworkWorldSystem::NetworkWorldSystem()
{
    set_entity_range(10'000'000, 20'000'000);
}

bool NetworkWorldSystem::Spawn(uint64_t aServerId, const Red::Vector4& aPosition, const Red::Quaternion& aRotation, const Red::DynArray<Red::TweakDBID>& aEquipment, const Vector<uint8_t> aCcstate, const std::string& acUsername)
{
    if (!m_ready)
        return false;

    const auto handle = Red::GetGameSystem<NetworkWorldSystem>();
    Red::EntityID id;
    Red::ScriptGameInstance game;

    spdlog::info("[Spawn] remote id {} - ccstate {} bytes, {} equipment item(s)", aServerId, aCcstate.size(),
                 aEquipment.size());

    if (!m_pCreatePuppet)
    {
        spdlog::error("[Spawn] CreatePuppet script function was never resolved - aborting");
        return false;
    }

    Red::Handle<game::ui::CharacterCustomizationState> stateHandle;
    CreateHandle_CharacterCustomizationState(&stateHandle);

    if (!stateHandle.instance)
    {
        spdlog::error("[Spawn] CreateHandle_CharacterCustomizationState returned a null instance - aborting");
        return false;
    }

    // Default to male if we have no appearance data. An empty buffer leaves the
    // customization state uninitialized, and reading it would be undefined.
    bool isBodyGenderMale = true;

    if (!aCcstate.empty())
    {
        auto reader = CMPReader(aCcstate);
        CharacterCustomizationState_Serialize(stateHandle.instance, &reader);
        isBodyGenderMale = Game::IsBodyGenderMale(stateHandle.instance);
        spdlog::info("[Spawn] body from ccstate: {}", isBodyGenderMale ? "male" : "female");
    }
    else
    {
        spdlog::warn("[Spawn] remote player sent no ccstate - spawning with default appearance");
    }

    if (!Red::Detail::CallFunctionWithArgs(m_pCreatePuppet, handle, id, aPosition, aRotation, isBodyGenderMale))
    {
        spdlog::error("[Spawn] CreatePuppet call failed for remote id {}", aServerId);
        return false;
    }

    auto apprSystem = Red::GetGameSystem<NetworkWorldSystem>()->GetAppearanceSystem();
    apprSystem->AddEntity(id, aEquipment, aCcstate);
    // Before ApplyAppearance, which reads it for the nameplate.
    apprSystem->SetEntityName(id, acUsername);

    if (!id.IsDynamic())
    {
        spdlog::warn("[Spawn] entity id is not dynamic - bailing out for remote id {}", aServerId);
        return false;
    }

    // Register BEFORE the entity finishes assembling. The animation-thread hook
    // identifies our puppets through this registry instead of reading the entity's
    // tag array off-thread, which was racing against the main thread's setup.
    App::PuppetRegistry::Add(id.hash);
    App::ServerIdRegistry::Add(id.hash, aServerId);

    make_alive(aServerId).emplace<SpawningComponent>(id);

    return true;
}

void NetworkWorldSystem::DeSpawn(uint64_t aServerId) const
{
    const auto entity = GetEntityByServerId(aServerId);

    if (!entity)
        return;

    if (auto* pEntity = entity.get<EntityComponent>())
    {
        App::PuppetRegistry::Remove(pEntity->Id.hash);
        m_appearanceSystem->ForgetEntityName(pEntity->Id);
        const auto handle = Red::GetGameSystem<NetworkWorldSystem>();
        Red::Detail::CallFunctionWithArgs(m_pDeletePuppet, handle, pEntity->Id);
    }
    else if (auto* pEntity = entity.get<SpawningComponent>())
    {
        App::PuppetRegistry::Remove(pEntity->Id.hash);
        m_appearanceSystem->ForgetEntityName(pEntity->Id);
        const auto handle = Red::GetGameSystem<NetworkWorldSystem>();
        Red::Detail::CallFunctionWithArgs(m_pDeletePuppet, handle, pEntity->Id);
    }

    App::ServerIdRegistry::RemoveServer(aServerId);
    entity.destruct();
}

Red::Handle<Red::Entity> NetworkWorldSystem::GetEntity(Red::EntityID aId) const
{
    Red::Handle<Red::IGameSystem> dynamicEntitySystem;
    if (!Red::CallStatic("ScriptGameInstance", "GetDynamicEntitySystem", dynamicEntitySystem))
        return nullptr;

    Red::Handle<Red::Entity> entity;
    if (!Red::CallVirtual(dynamicEntitySystem, "GetEntity", entity, aId))
        return nullptr;

    return entity;
}

flecs::entity NetworkWorldSystem::GetEntityByServerId(uint64_t aServerId) const
{
    return flecs::entity(*this, aServerId);
}

Red::EntityID NetworkWorldSystem::GetEntityIdByServerId(uint64_t aServerId) const
{
    // Script-callable, so it can arrive on any of the engine's job threads; the registry is
    // the only answer that is safe there (FlecsThread.h).
    if (const auto hash = App::ServerIdRegistry::FindEntity(aServerId))
        return hash;

    if (!App::FlecsThread::IsCurrent())
        return 0;

    const auto entity = GetEntityByServerId(aServerId);
    if (!entity)
        return 0;

    if (auto* pEntity = entity.get<EntityComponent>())
        return pEntity->Id;

    if (auto* pEntity = entity.get<SpawningComponent>())
        return pEntity->Id;

    return 0;
}

flecs::entity NetworkWorldSystem::FindEntity(Red::EntityID aId) const
{
    App::FlecsThread::Assert("NetworkWorldSystem::FindEntity");

    auto entity = query<EntityComponent>().find(
        [aId](const EntityComponent& component)
        {
            return component.Id == aId;
        });

    if (!entity)
    {
        entity = query<SpawningComponent>().find(
            [aId](const SpawningComponent& component)
            {
                return component.Id == aId;
            });
    }

    return entity;
}

void NetworkWorldSystem::Update(uint64_t aTick)
{
    GTick = aTick;

    const auto delta = std::min(aTick - m_lastTick, 1000ull);
    m_lastTick = aTick;

    ChoiceInput::Update();
    QuestMirror::Update();
    CoopConnect::Update(IsConnected(), m_inGame);

    const auto service = Core::Container::Get<NetworkService>();
    if (service && service->IsConnected())
    {
        App::FlecsThread::MarkCurrent();
        progress(static_cast<float>(delta) / 1000.f);
    }
}

void NetworkWorldSystem::OnWorldAttached(RED4ext::world::RuntimeScene* aScene)
{
    if (Settings::IsDisabled())
    {
        return;
    }
    spdlog::info("[NetworkWorldSystem] OnWorldAttached");
    IGameSystem::OnWorldAttached(aScene);

    m_chatSystem->OnWorldAttached(aScene);
    m_appearanceSystem->OnWorldAttached(aScene);
    m_interpolationSystem->OnWorldAttached(aScene);
    m_vehicleSystem->OnWorldAttached(aScene);

    m_ready = true;
}

void NetworkWorldSystem::OnAfterWorldDetach()
{
    if (Settings::IsDisabled())
    {
        return;
    }
    spdlog::info("[NetworkWorldSystem] OnAfterWorldDetach");
    m_ready = false;
    m_inGame = false;

    m_interpolationSystem->OnAfterWorldDetach();
    m_chatSystem->OnAfterWorldDetach();
    m_vehicleSystem->OnAfterWorldDetach();

    m_remotePlayerId = std::nullopt;

    // The puppets went down with the world. Forget them without calling DeletePuppet; the
    // server sends every character again when we spawn into the next world.
    each([](flecs::entity entity, EntityComponent&) { entity.destruct(); });
    each([](flecs::entity entity, SpawningComponent&) { entity.destruct(); });
    App::PuppetRegistry::Clear();
    App::ServerIdRegistry::Clear();
    m_appearanceSystem->ForgetEntityNames();

    if (const auto pNetworkService = Core::Container::Get<NetworkService>())
        pNetworkService->ResetSpawn();

    IGameSystem::OnAfterWorldDetach();
}

void NetworkWorldSystem::OnBeforeWorldDetach(RED4ext::world::RuntimeScene* aScene)
{
    if (Settings::IsDisabled())
    {
        return;
    }
    IGameSystem::OnBeforeWorldDetach(aScene);

    m_appearanceSystem->OnBeforeWorldDetach(aScene);
}

void NetworkWorldSystem::HandleCharacterLoad(const PacketEvent<server::NotifyCharacterLoad>& aMessage)
{
    auto& pos = aMessage.get_position();
    auto& rot = aMessage.get_rotation();

    const Red::Vector4 position{pos.get_x(), pos.get_y(), pos.get_z(), 1.f};
    const auto eulerAngles = glm::vec3(0.f, 0.f, rot);
    const auto quat = glm::quat(eulerAngles);

    const Red::Quaternion rotation{quat.x, quat.y, quat.z, quat.w};

    auto equipment = Red::DynArray<Red::TweakDBID>(this->GetAllocator());
    for (auto item : aMessage.get_equipment())
    {
        equipment.EmplaceBack(item);
    }

    auto ccstate = aMessage.get_ccstate();

    Spawn(aMessage.get_id(), position, rotation, equipment, ccstate, aMessage.get_username().c_str());
}

void NetworkWorldSystem::HandleEntityUnload(const PacketEvent<server::NotifyEntityUnload>& aMessage)
{
    DeSpawn(aMessage.get_id());
}

void NetworkWorldSystem::HandleSpawnCharacterResponse(const PacketEvent<server::SpawnCharacterResponse>& aMessage)
{
    if (!aMessage.has_id())
    {
        spdlog::error("Failed to spawn our character on the server...");
        return;
    }

    SetRemotePlayerId(aMessage.get_id());
}

static Core::RawFunc<
    1160782872UL,
    bool (*)(Red::game::mounting::MountingFacility *, const Red::ent::Entity &, const Red::game::mounting::MountingSlotId &, bool)>
    IsMountedToObject;
static Core::RawFunc<
    3120376212UL,
    bool (*)(Red::game::mounting::MountingFacility *, const Red::ent::Entity &, const Red::game::mounting::MountingSlotId &, Red::game::mounting::MountingInfo &)>
    GetMountingInfo;

void NetworkWorldSystem::UpdatePlayerLocation() const
{
    const auto system = Red::GetGameSystem<Game::PlayerSystem>();
    Red::Handle<Red::GameObject> player;
    system->GetLocalPlayerControlledGameObject(player);

    if (!player || !GetRemotePlayerId())
        return;

    auto puppet = Red::Cast<Red::game::Puppet>(player);

    // const auto mountingFacility = Red::GetGameSystem<Red::game::mounting::MountingFacility>();
    // Red::game::mounting::MountingInfo mountingInfo;
    // if (GetMountingInfo(mountingFacility, *puppet.instance, Red::CName("seat_front_left"), mountingInfo)) {
    if (auto vehicle_id = GetVehicleSystem()->GetVehicleGameId())
    {
        // auto vehicle = Red::Cast<Red::vehicle::BaseObject>(GetEntity(mountingInfo.parentId));
        auto vehicle = Red::Cast<Red::vehicle::BaseObject>(GetEntity(*vehicle_id));
        if (!vehicle)
        {
            spdlog::info("Couldn't find vehicle: {}", (*vehicle_id).hash);
            return;
        }
        if (auto remote_id = GetVehicleSystem()->GetVehicleRemoteId(); remote_id != std::nullopt)
        {
            // The vehicle's placed component, not its rigid body: the hand-mapped rigidBody pointer
            // (0x2D0) predates patch 2.31, and the fields around it have moved since (burnout
            // 0x2BC -> 0x2C4, archetype 0x3A0 -> 0x3B0 in 2.5). The entity's transform component
            // is at an offset the upstream SDK asserts, and the old note below says it reads the
            // same.
            if (!vehicle->transformComponent)
                return;
            const auto transform = vehicle->transformComponent->worldTransform;

            // const auto cEntityRotation = eulerAngles(Game::ToGlm(vehicle->transformComponent->worldTransform.Orientation));

            // about the same
            // transform = vehicle->worldTransform;

            // about the same
            // transform = vehicle->runtimeData->transform;

            // try to get transform from move system
            // seems to return 0 :/
            // auto transform = Red::WorldTransform();
            // const auto moveSystem = Red::GetGameSystem<Red::vehicle::MoveSystem>();
            // // GetCurrentTransform
            // reinterpret_cast<void (*)(const Red::vehicle::MoveSystem *, const Red::EntityID &, Red::WorldTransform*)>(*(uintptr_t*)(*(uintptr_t*)moveSystem + 0x250))(moveSystem, vehicle->id, &transform);

            const auto cEntityPosition = transform.Position;
            const auto cEntityRotation = eulerAngles(Game::ToGlm(transform.Orientation));
            // Speed from the distance covered since the last report of this vehicle.
            static uint64_t s_lastVehicle = 0;
            static glm::vec3 s_lastPosition{};
            static uint64_t s_lastTick = 0;
            const glm::vec3 position{cEntityPosition.x, cEntityPosition.y, cEntityPosition.z};
            const auto tick = GetTick();
            float speed = 0.f;
            if (s_lastVehicle == *remote_id && tick > s_lastTick)
                speed = glm::distance(position, s_lastPosition) / (static_cast<float>(tick - s_lastTick) / 1000.f);
            s_lastVehicle = *remote_id;
            s_lastPosition = position;
            s_lastTick = tick;

            common::Vector3 pos;
            pos.set_x(cEntityPosition.x);
            pos.set_y(cEntityPosition.y);
            pos.set_z(cEntityPosition.z);

            common::Vector3 rot;
            rot.set_x(cEntityRotation.x);
            rot.set_y(cEntityRotation.y);
            rot.set_z(cEntityRotation.z);

            client::MoveEntityRequest request;
            request.set_position(pos);
            request.set_full_rotation(rot);
            request.set_id(*remote_id);
            request.set_speed(speed);
            request.set_tick(GetTick());

            const auto pNetworkService = Core::Container::Get<NetworkService>();
            pNetworkService->Send(request);

            client::MoveEntityRequest characterRequest;
            characterRequest.set_position(pos);
            characterRequest.set_rotation(cEntityRotation.z);
            characterRequest.set_id(*GetRemotePlayerId());
            characterRequest.set_speed(speed);
            characterRequest.set_tick(GetTick());

            pNetworkService->Send(characterRequest);
        }
    }
    else
    {
        // localTransform is not updated as the player walks (V moves via the character
        // controller), so it stays frozen at its spawn value. Rotation already reads
        // worldTransform on the next line - use it for position too.
        const auto cEntityPosition = puppet->transformComponent->worldTransform.Position;
        const auto cEntityRotation = eulerAngles(Game::ToGlm(puppet->transformComponent->worldTransform.Orientation));

        // Speed is measured from how far V moved (from NCO): moveComponent->speed sits at a
        // hand-mapped offset that moved on 2.31 and read about 3e8, which pinned every remote
        // player past the walk (3 m/s) and run (5 m/s) thresholds of their animations.
        const glm::vec3 here{cEntityPosition.x, cEntityPosition.y, cEntityPosition.z};
        const auto now = std::chrono::steady_clock::now();
        float speed = 0.f;
        if (m_hasLastPosition)
        {
            const float elapsed = std::chrono::duration<float>(now - m_lastPositionAt).count();
            if (elapsed > 0.001f)
            {
                speed = glm::distance(here, m_lastPosition) / elapsed;
                // A teleport or a loading screen is not a sprint.
                constexpr float kFastestPlausible = 20.f;
                if (speed > kFastestPlausible)
                    speed = 0.f;
            }
        }
        m_lastPosition = here;
        m_lastPositionAt = now;
        m_hasLastPosition = true;

        common::Vector3 pos;
        pos.set_x(cEntityPosition.x);
        pos.set_y(cEntityPosition.y);
        pos.set_z(cEntityPosition.z);

        client::MoveEntityRequest request;
        request.set_position(pos);
        request.set_rotation(cEntityRotation.z);
        request.set_id(*GetRemotePlayerId());
        request.set_speed(speed);
        request.set_tick(GetTick());

        const auto pNetworkService = Core::Container::Get<NetworkService>();
        pNetworkService->Send(request);
    }

    // if (GetEntityByServerId(*GetRemotePlayerId()).get_mut<InterpolationComponent>()->Attached)
    // {
    //     auto vehicle_id = GetVehicleSystem()->GetVehicle(player->id);
    //     if (!vehicle_id)
    //     {
    //         spdlog::warn("No vehicle for player({})", player->id.hash);
    //         return;
    //     }
    //     auto entity = GetEntity(vehicle_id);
    //     if (!entity)
    //     {
    //         spdlog::warn("No entity for vehicle({})", vehicle_id.hash);
    //         return;
    //     }
    //     auto vehicle = Red::Cast<Red::vehicle::BaseObject>(entity);
    //     if (!vehicle)
    //     {
    //         spdlog::warn("Entity is not vehicle");
    //         return;
    //     }
    //     else
    //     {
    //         // if (vehicle->transformComponent) {
    //             // entityPosition = vehicle->transformComponent->localTransform.Position;
    //         // } else {
    //             // entityPosition = vehicle->worldTransform.Position;
    //             entityPosition = vehicle->rigidBody->worldPosition;
    //         // }
    //     }
    // }
}

void NetworkWorldSystem::OnInitialize(const RED4ext::JobHandle& aJob)
{
    spdlog::info("[OnInitialize]");

    IGameSystem::OnInitialize(aJob);

    if (Settings::IsDisabled())
        return;

    const auto pNetworkService = Core::Container::Get<NetworkService>();
    pNetworkService->RegisterHandler<&NetworkWorldSystem::HandleCharacterLoad>(this);
    pNetworkService->RegisterHandler<&NetworkWorldSystem::HandleEntityUnload>(this);
    pNetworkService->RegisterHandler<&NetworkWorldSystem::HandleSpawnCharacterResponse>(this);

    m_remotePlayerId = std::nullopt;

    m_pCreatePuppet = Red::Detail::GetFunction(GetType(), "CreatePuppet");
    m_pDeletePuppet = Red::Detail::GetFunction(GetType(), "DeletePuppet");

    m_interpolationSystem = RED4ext::MakeHandle<InterpolationSystem>();
    m_interpolationSystem->OnInitialize(aJob);

    m_appearanceSystem = RED4ext::MakeHandle<AppearanceSystem>();
    m_appearanceSystem->OnInitialize(aJob);

    m_chatSystem = RED4ext::MakeHandle<ChatSystem>();
    m_chatSystem->OnInitialize(aJob);

    m_vehicleSystem = RED4ext::MakeHandle<VehicleSystem>();
    m_vehicleSystem->OnInitialize(aJob);

    ChoiceInput::Attach();
    QuestMirror::Attach();
    CoopConnect::Attach();
}

// The server from the launch arguments: by address, or through the Steam tunnel.
void NetworkWorldSystem::Connect()
{
    CoopConnect::ConnectConfigured();
}

// Also ends hosting (the server this game started) and the Steam tunnel.
void NetworkWorldSystem::Disconnect()
{
    CoopConnect::Leave();
}

bool NetworkWorldSystem::IsEnabled() const
{
    return !Settings::IsDisabled();
}

// Saved characters store item ids as numbers; script has no way back from one.
Red::TweakDBID NetworkWorldSystem::TweakDBIDFromNumber(uint64_t aValue) const
{
    return Red::TweakDBID(aValue);
}

void NetworkWorldSystem::SetChoiceLock(bool aLocked)
{
    ChoiceInput::SetLock(aLocked);
}

int32_t NetworkWorldSystem::TakeBlockedChoiceConfirms()
{
    return ChoiceInput::TakeBlockedConfirms();
}

bool NetworkWorldSystem::InjectChoice(int32_t aSteps)
{
    return ChoiceInput::Inject(aSteps);
}

void NetworkWorldSystem::SetQuestMirror(int32_t aMode)
{
    QuestMirror::SetMode(aMode);
}

Red::CString NetworkWorldSystem::OpenSteamInvite()
{
    return CoopConnect::OpenInviteDialog();
}

Red::CString NetworkWorldSystem::RunSelfCheck(const Red::Handle<Red::GameObject>& aPlayer, const Red::Handle<Red::GameObject>& aVehicle)
{
    return SelfCheck::Run(aPlayer, aVehicle);
}

bool NetworkWorldSystem::HostCampaign()
{
    return CoopConnect::Host();
}

Red::CString NetworkWorldSystem::GetHostStatus()
{
    return CoopConnect::HostStatus();
}

Red::CString NetworkWorldSystem::GetSceneKey()
{
    return QuestMirror::GetSceneKey();
}

Red::CString NetworkWorldSystem::TakeQuestNodes()
{
    return QuestMirror::TakeRecorded();
}

void NetworkWorldSystem::ReplayQuestNodes(const Red::CString& aEntries)
{
    QuestMirror::Replay(aEntries);
}

void NetworkWorldSystem::SetSceneSpacing(bool aEnabled, const Red::Vector4& aAnchor, const Red::Vector4& aForward)
{
    // The yaw whose (cos, sin) is the spot's right: (forward.y, -forward.x) with Z up.
    const auto yaw = std::atan2(-aForward.X, aForward.Y);
    InterpolationSystem::SetSceneSpacing(aEnabled, glm::vec3{aAnchor.X, aAnchor.Y, aAnchor.Z}, yaw);
}

void NetworkWorldSystem::SetPuppetHeld(Red::EntityID aEntity, bool aHeld)
{
    InterpolationSystem::SetHeld(aEntity.hash, aHeld);
}

void NetworkWorldSystem::SetVehicleSyncPaused(bool aPaused)
{
    VehicleSystem::SetScenePaused(aPaused);
}

Red::CString NetworkWorldSystem::FindSceneSpots(const Red::Handle<Red::world::StreamingSector>& aSector, const Red::Vector4& aCenter, float aRadius)
{
    return SceneSpots::Find(aSector, aCenter, aRadius);
}

Red::NodeRef NetworkWorldSystem::NodeRefFromNumber(uint64_t aValue) const
{
    return Red::NodeRef(aValue);
}

bool NetworkWorldSystem::IsConnected() const
{
    const auto pNetworkService = Core::Container::Get<NetworkService>();
    return pNetworkService && pNetworkService->IsConnected() && pNetworkService->IsAuthenticated();
}

Red::CString NetworkWorldSystem::GetUsername() const
{
    return Settings::Get().username.c_str();
}

namespace
{
constexpr char kBase64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

std::string EncodeBase64(const Vector<uint8_t>& aBytes)
{
    std::string out;
    out.reserve((aBytes.size() + 2) / 3 * 4);

    for (size_t i = 0; i < aBytes.size(); i += 3)
    {
        uint32_t chunk = aBytes[i] << 16;
        if (i + 1 < aBytes.size())
            chunk |= aBytes[i + 1] << 8;
        if (i + 2 < aBytes.size())
            chunk |= aBytes[i + 2];

        out.push_back(kBase64[(chunk >> 18) & 63]);
        out.push_back(kBase64[(chunk >> 12) & 63]);
        out.push_back(i + 1 < aBytes.size() ? kBase64[(chunk >> 6) & 63] : '=');
        out.push_back(i + 2 < aBytes.size() ? kBase64[chunk & 63] : '=');
    }

    return out;
}

bool DecodeBase64(std::string_view aText, Vector<uint8_t>& aBytes)
{
    uint32_t chunk = 0;
    int bits = 0;

    for (const char c : aText)
    {
        if (c == '=')
            break;

        const char* pos = std::strchr(kBase64, c);
        if (!pos || c == 0)
            return false;

        chunk = (chunk << 6) | static_cast<uint32_t>(pos - kBase64);
        bits += 6;

        if (bits >= 8)
        {
            bits -= 8;
            aBytes.push_back(static_cast<uint8_t>((chunk >> bits) & 0xFF));
        }
    }

    return true;
}
}

// The character creator's state, as the same bytes SpawnCharacterRequest carries. Only
// available while a creator state exists (main menu, character creation) - empty otherwise.
Red::CString NetworkWorldSystem::ExportCustomizationState() const
{
    auto ccSystem = Red::GetGameSystem<Red::game::ui::CharacterCustomizationSystem>();
    if (!ccSystem)
        return "";

    auto stateHandle = GetCustomizationState(ccSystem);
    if (!stateHandle || !stateHandle->instance)
        return "";

    auto writer = CMPWriter();
    CharacterCustomizationState_Serialize(stateHandle->instance, &writer);

    return EncodeBase64(writer.bytes).c_str();
}

// Loads exported bytes into the creator's current state. The caller has to have called
// InitializeState() first, and FinalizeState() afterwards.
bool NetworkWorldSystem::ImportCustomizationState(const Red::CString& aData) const
{
    Vector<uint8_t> bytes;
    if (!DecodeBase64(aData.c_str(), bytes) || bytes.empty())
    {
        spdlog::error("[Campaign] customization state is not valid base64");
        return false;
    }

    auto ccSystem = Red::GetGameSystem<Red::game::ui::CharacterCustomizationSystem>();
    if (!ccSystem)
        return false;

    auto stateHandle = GetCustomizationState(ccSystem);
    if (!stateHandle || !stateHandle->instance)
    {
        spdlog::error("[Campaign] no customization state to import into");
        return false;
    }

    auto reader = CMPReader(bytes);
    CharacterCustomizationState_Serialize(stateHandle->instance, &reader);

    spdlog::info("[Campaign] imported {} bytes of customization state", bytes.size());
    return true;
}

void NetworkWorldSystem::OnConnected()
{
    RED4ext::StackArgs_t args;
    ExecuteFunction(this, this->GetNativeType()->GetFunction("OnConnected"), nullptr, args);

    const auto pNetworkService = Core::Container::Get<NetworkService>();

    m_updatePlayerLocation = system("Update player location")
        .kind(flecs::OnUpdate)
        .interval(1.f / pNetworkService->GetServerSettings().get_update_rate())
        .run([this](flecs::iter& it)
        {
            UpdatePlayerLocation();
        });

    m_updateSpawningEntities = system<SpawningComponent>("Spawning entity process")
        .interval(0.2f)
        .write<EntityComponent>()
        .write<SpawningComponent>()
        .each([this](flecs::entity aEntity, SpawningComponent& aSpawning)
        {
            const auto pEntity = GetEntity(aSpawning.Id);

            if (!pEntity)
                return;

            if (const auto pOwner = Red::Cast<Red::GameObject>(pEntity))
            {
                if (pOwner->tags.Contains(Red::CName("CyberpunkMP.Vehicle")))
                    return;

                 aEntity.emplace<EntityComponent>(aSpawning.Id, false, aSpawning.Controller);
                 aEntity.add<InterpolationComponent>();
                 aEntity.remove<SpawningComponent>();
                 pOwner->tags.Add(Red::CName("CyberpunkMP.Puppet"));
            }
        });

    m_interpolationSystem->OnConnected();
}

void NetworkWorldSystem::OnDisconnected(Client::EDisconnectReason aReason)
{
    each([this](flecs::entity entity, EntityComponent&)
        {
            DeSpawn(entity.raw_id());
            entity.destruct();
        });

    each([this](flecs::entity entity, SpawningComponent&)
        {
            DeSpawn(entity.raw_id());
            entity.destruct();
        });

    App::PuppetRegistry::Clear();
    App::ServerIdRegistry::Clear();

    if (m_updatePlayerLocation)
        m_updatePlayerLocation.destruct();

    if (m_updateSpawningEntities)
        m_updateSpawningEntities.destruct();

    m_interpolationSystem->OnDisconnected();
    m_vehicleSystem->OnDisconnected();

    RED4ext::StackArgs_t args;
    auto reason = (uint32_t)aReason;
    args.emplace_back(RED4ext::CRTTISystem::Get()->GetType("Uint32"), &reason);
    ExecuteFunction(this, this->GetNativeType()->GetFunction("OnDisconnected"), nullptr, args);
}
