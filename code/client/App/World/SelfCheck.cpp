#include "SelfCheck.h"

#include <mutex>
#include <optional>

#include <RED4ext/Scripting/Natives/entEntity.hpp>
#include <RED4ext/Scripting/Natives/moveComponent.hpp>
#include <RED4ext/Scripting/Natives/Generated/vehicle/BaseObject.hpp>

#include "Game/Entity.h"
#include "Game/Utils.h"
#include "Game/Animation/MultiMovementController.h"
#include "InterpolationSystem.h"
#include "QuestMirror.h"
// Last: it opens namespace Red globally, which makes UniquePtr ambiguous in the headers above.
#include "Game/CharacterCustomizationSystem.h"

namespace
{
std::mutex s_lock;
std::optional<SelfCheck::Result> s_gender;

SelfCheck::Result Make(const char* acName, SelfCheck::Status aStatus, std::string aDetail)
{
    return {acName, aStatus, std::move(aDetail)};
}

// ---- movement component: representation block at 0x138, owner entity at 0x90 ----
struct MovementContext
{
    Red::move::Component* pComponent;
    Red::Entity* pEntity;
    bool representationOk;
    std::string representation;
    Red::Entity* pOwner;
};

SelfCheck::Result CheckMovement(const Red::Handle<Red::GameObject>& aPlayer)
{
    const auto component = Game::FindComponent<Red::move::Component>(aPlayer.instance);
    if (!component)
        return Make("movement", SelfCheck::Status::Skip, "the player has no move::Component");

    MovementContext context{component.instance, aPlayer.instance};
    const auto ran = SelfCheck::Guarded(
        [](void* apContext)
        {
            auto& ctx = *static_cast<MovementContext*>(apContext);
            ctx.representationOk = MultiMovementController::CheckRepresentation(ctx.pComponent, ctx.representation);
            ctx.pOwner = Game::EntityPtr(ctx.pComponent).GetValuePtr();
        },
        &context);

    if (!ran)
        return Make("movement", SelfCheck::Status::Fail, "reading the component raised an exception");

    const auto ownerOk = context.pOwner == context.pEntity;
    const auto detail = std::format("representation (0x138): {}; owner (0x90): {} (player {})", context.representation,
                                    static_cast<void*>(context.pOwner), static_cast<void*>(context.pEntity));
    return Make("movement", context.representationOk && ownerOk ? SelfCheck::Status::Ok : SelfCheck::Status::Fail, detail);
}

// ---- vehicle: isOnGround 0x25C, physicsState 0x260, acceleration 0x264 ----
struct VehicleContext
{
    Red::vehicle::BaseObject* pVehicle;
    uint8_t onGround;
    uint32_t physicsState;
    float acceleration;
    float deceleration;
};

SelfCheck::Result CheckVehicle(const Red::Handle<Red::GameObject>& aVehicle)
{
    if (!aVehicle)
        return Make("vehicle", SelfCheck::Status::Skip, "not in a vehicle (sit in one and run /coop selfcheck)");

    auto* pVehicle = Red::Cast<Red::vehicle::BaseObject>(aVehicle.instance);
    if (!pVehicle)
        return Make("vehicle", SelfCheck::Status::Skip, "the mounted object is not a vehicle");

    VehicleContext context{pVehicle};
    const auto ran = SelfCheck::Guarded(
        [](void* apContext)
        {
            auto& ctx = *static_cast<VehicleContext*>(apContext);
            const auto* pBytes = reinterpret_cast<const uint8_t*>(ctx.pVehicle);
            ctx.onGround = pBytes[offsetof(Red::vehicle::BaseObject, isOnGround)];
            ctx.physicsState = *reinterpret_cast<const uint32_t*>(pBytes + InterpolationSystem::kVehiclePhysicsState);
            ctx.acceleration = ctx.pVehicle->acceleration;
            ctx.deceleration = ctx.pVehicle->deceleration;
        },
        &context);

    if (!ran)
        return Make("vehicle", SelfCheck::Status::Fail, "reading the vehicle raised an exception");

    // No game function reports these, so this is a plausibility check: a bool that is 0 or 1,
    // flags that fit the bits the interpolation uses, and two sane floats.
    const auto plausible = context.onGround <= 1 && context.physicsState < 0x10000 && std::isfinite(context.acceleration) &&
                           std::isfinite(context.deceleration) && std::abs(context.acceleration) < 1e5f &&
                           std::abs(context.deceleration) < 1e5f;
    const auto detail = std::format("{}: isOnGround {}, physicsState {:#x}, acceleration {}, deceleration {}",
                                    pVehicle->GetType()->GetName().ToString(), context.onGround, context.physicsState,
                                    context.acceleration, context.deceleration);
    return Make("vehicle", plausible ? SelfCheck::Status::Ok : SelfCheck::Status::Fail, detail);
}

// ---- quests: root phase 0x68 on the quests system, resource 0x30 and graph 0x40 on a phase ----
struct QuestsContext
{
    bool ok;
    std::string detail;
};

SelfCheck::Result CheckQuests()
{
    QuestsContext context{};
    const auto ran = SelfCheck::Guarded(
        [](void* apContext)
        {
            auto& ctx = *static_cast<QuestsContext*>(apContext);
            ctx.ok = QuestMirror::CheckLayout(ctx.detail);
        },
        &context);

    if (!ran)
        return Make("quests", SelfCheck::Status::Fail, "reading the quests system raised an exception");
    if (context.detail.empty())
        return Make("quests", SelfCheck::Status::Skip, "no quests system or root phase yet");
    return Make("quests", context.ok ? SelfCheck::Status::Ok : SelfCheck::Status::Fail, context.detail);
}
} // namespace

bool SelfCheck::Guarded(void (*apFn)(void*), void* apContext)
{
    __try
    {
        apFn(apContext);
        return true;
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
        return false;
    }
}

void SelfCheck::Log(const Result& aResult)
{
    switch (aResult.status)
    {
    case Status::Ok: spdlog::info("[SelfCheck] OK   {}: {}", aResult.name, aResult.detail); break;
    case Status::Fail: spdlog::error("[SelfCheck] FAIL {}: {}", aResult.name, aResult.detail); break;
    case Status::Skip: spdlog::info("[SelfCheck] SKIP {}: {}", aResult.name, aResult.detail); break;
    }
}

namespace
{
struct GenderContext
{
    Red::game::ui::CharacterCustomizationState* pState;
    uint8_t raw;
};
} // namespace

void SelfCheck::CheckGender(Red::game::ui::CharacterCustomizationState* apState, const Vector<uint8_t>& aBytes,
                            const Red::Handle<Red::GameObject>& aPlayer)
{
    Result result;
    result.name = "gender";

    // What the game says about the player's own state, and about a copy rebuilt from the bytes
    // the server forwards - the copy is what a guest spawns this player from.
    bool stateMale = false;
    const auto stateKnown = Red::CallVirtual(apState, "IsBodyGenderMale", stateMale);

    Red::Handle<Red::game::ui::CharacterCustomizationState> copy;
    CreateHandle_CharacterCustomizationState(&copy);
    bool copyMale = false;
    bool copyKnown = false;
    GenderContext context{copy.instance};
    if (copy.instance && !aBytes.empty())
    {
        auto reader = CMPReader(aBytes);
        CharacterCustomizationState_Serialize(copy.instance, &reader);
        copyKnown = Red::CallVirtual(copy.instance, "IsBodyGenderMale", copyMale);
        Guarded([](void* apContext)
                {
                    auto& ctx = *static_cast<GenderContext*>(apContext);
                    ctx.raw = reinterpret_cast<const uint8_t*>(ctx.pState)[Game::kIsBodyGenderMaleOffset];
                },
                &context);
    }

    Red::CName resolved;
    Red::CallVirtual(aPlayer.instance, "GetResolvedGenderName", resolved);

    result.detail = std::format("game function: state {}, rebuilt copy {}; byte 0x{:X} on the copy: {}; puppet: {}",
                                stateKnown ? (stateMale ? "male" : "female") : "n/a",
                                copyKnown ? (copyMale ? "male" : "female") : "n/a", Game::kIsBodyGenderMaleOffset,
                                context.raw, resolved ? resolved.ToString() : "n/a");

    if (!stateKnown || !copyKnown)
        result.status = Status::Skip;
    else
        // The spawn path uses the game function; the byte is only its fallback, so a wrong byte is
        // logged but does not fail the check.
        result.status = stateMale == copyMale ? Status::Ok : Status::Fail;

    if (context.raw != static_cast<uint8_t>(copyMale) && copyKnown)
        result.detail += " (the fallback byte disagrees - harmless while the game function exists)";

    // Logged with the rest by Run, which the spawn calls next.
    std::lock_guard _(s_lock);
    s_gender = result;
}

void SelfCheck::SkipGender(const char* acReason)
{
    std::lock_guard _(s_lock);
    s_gender = Make("gender", Status::Skip, acReason);
}

Red::CString SelfCheck::Run(const Red::Handle<Red::GameObject>& aPlayer, const Red::Handle<Red::GameObject>& aVehicle)
{
    if (!aPlayer)
        return "selfcheck: no player";

    std::vector<Result> results;
    {
        std::lock_guard _(s_lock);
        results.push_back(s_gender ? *s_gender
                                   : Make("gender", Status::Skip, "checked when the player spawns on a server"));
    }
    results.push_back(CheckMovement(aPlayer));
    results.push_back(CheckVehicle(aVehicle));
    results.push_back(CheckQuests());

    int ok = 0, fail = 0, skip = 0;
    std::string failed, skipped;
    for (const auto& result : results)
    {
        Log(result);
        switch (result.status)
        {
        case Status::Ok: ++ok; break;
        case Status::Fail: ++fail; failed += " " + result.name; break;
        case Status::Skip: ++skip; skipped += " " + result.name; break;
        }
    }

    auto summary = std::format("selfcheck: {} OK, {} FAIL, {} skipped", ok, fail, skip);
    if (fail)
        summary += " - failed:" + failed;
    if (skip)
        summary += " - skipped:" + skipped;
    summary += " (details in CyberpunkMP.log)";
    spdlog::info("[SelfCheck] {}", summary);
    return summary.c_str();
}
