#pragma once

struct MovementComponent
{
    // Initialised: Tick is only assigned when a movement message arrives, and a player who had
    // not moved yet was replicated with whatever the allocation held. Clients ignore tick 0.
    // Night City Online b2507a2.
    glm::vec3 Position{0.f, 0.f, 0.f};
    glm::vec3 Rotation{0.f, 0.f, 0.f};
    float Velocity{0.f};
    uint64_t Tick{0};

    static void Register(flecs::world& aWorld);
};