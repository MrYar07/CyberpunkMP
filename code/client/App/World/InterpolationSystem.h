#pragma once

#include "Core/Hooking/HookingAgent.hpp"
#include "RED4ext/Scripting/Natives/gameIEntityStubSystem.hpp"


struct InterpolationSystem : RED4ext::IScriptable, Core::HookingAgent
{
    RTTI_IMPL_TYPEINFO(InterpolationSystem)
    RTTI_IMPL_ALLOCATOR();

    void OnInitialize(const RED4ext::JobHandle& aJob);
    void OnWorldAttached(RED4ext::world::RuntimeScene* aScene);
    void OnAfterWorldDetach();

    void OnConnected();
    void OnDisconnected();

    // During a scene every game shows its own V on the scene's spot, so other players'
    // characters arrive there too. While enabled, those within reach of the spot stand
    // beside it instead, alternating sides.
    static void SetSceneSpacing(bool aEnabled, const glm::vec3& aAnchor, float aYaw);
    // A character the local scene has placed (car seat, chair, a spot beside V) is left
    // where it is until released.
    static void SetHeld(uint64_t aEntityHash, bool aHeld);

protected:

    void HandleNotifyEntityMove(const PacketEvent<server::NotifyEntityMove>& aMessage);

private:
    bool m_ready{false};
    flecs::system m_interpolator;
    flecs::observer m_entityObserver;
};

RTTI_DEFINE_CLASS(InterpolationSystem, { 
    RTTI_ALIAS("CyberpunkMP.World.InterpolationSystem");
});