#pragma once

#include "Core/Stl.hpp"
#include "Core/Hooking/HookingAgent.hpp"
#include "RED4ext/Scripting/Natives/Generated/Vector4.hpp"
#include "RED4ext/Scripting/Natives/Generated/Quaternion.hpp"
#include "Network/Client.h"


struct AppearanceSystem : RED4ext::IScriptable
{
    RTTI_IMPL_TYPEINFO(AppearanceSystem);
    RTTI_IMPL_ALLOCATOR();

    AppearanceSystem();

    void OnInitialize(const RED4ext::JobHandle& aJob);

    Red::DynArray<Red::TweakDBID> GetEntityItems(Red::EntityID &);
    void AddEntity(const Red::EntityID entityID, const Red::DynArray<Red::TweakDBID>& items, const Vector<uint8_t> ccstate);

    // Whose character a puppet is: the name over its head and on the scanner. Empty for
    // anything that is not another player.
    void SetEntityName(Red::EntityID entityID, const std::string& acName);
    std::string GetEntityName(Red::EntityID entityID) const;
    Red::CString GetNetworkPlayerName(Red::EntityID aEntityId) const;
    // A character gone (or every one, with the world): its id may later belong to an NPC,
    // which must not show a player's name on the scanner.
    void ForgetEntityName(Red::EntityID entityID);
    void ForgetEntityNames();
    Vector<String> GetPlayerItems(Red::Handle<Red::GameObject> player);
    bool ApplyAppearance(Red::Handle<Red::GameObject> object);

    void OnWorldAttached(RED4ext::world::RuntimeScene* aScene);
    void OnBeforeWorldDetach(RED4ext::world::RuntimeScene* aScene);

private:
    Core::Map<Red::EntityID, Red::DynArray<Red::TweakDBID>> m_playerEquipment;
    Core::Map<Red::EntityID, Vector<uint8_t>> m_playerCcstate;
    Core::Map<Red::EntityID, std::string> m_playerNames;

    // The face/body state ALREADY scheduled onto each entity, by hash.
    //
    // An appearance update carries clothing and customization together, so a jacket
    // change re-ran the whole customization apply - and re-scheduling the engine's
    // synchronized appearance change on a puppet that is already wearing that exact
    // state is what killed observing clients (2026-09-04: 15 applies in 16 minutes,
    // every one with an identical ccstate hash, the last one fatal). Remembering what
    // was scheduled is what lets an unchanged face be left alone.
    Core::Map<Red::EntityID, uint64_t> m_scheduledCcstate;
};

RTTI_DEFINE_CLASS(AppearanceSystem, { 
    RTTI_ALIAS("CyberpunkMP.World.AppearanceSystem");
    RTTI_METHOD(GetEntityItems);
    RTTI_METHOD(ApplyAppearance);
    RTTI_METHOD(GetNetworkPlayerName);
});