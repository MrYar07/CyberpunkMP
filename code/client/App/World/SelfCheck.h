#pragma once

#include <RED4ext/Scripting/Natives/Generated/game/Object.hpp>
#include <RED4ext/Scripting/Natives/Generated/game/ui/CharacterCustomizationState.hpp>

// Checks the hand-mapped engine layouts this client relies on against the running game, so a
// layout that moved in a patch shows up in the log of a single-player session instead of as a
// crash in a co-op one. Each check compares a hand-mapped field with something the game itself
// answers (an RTTI function, a type, a pointer back to the owner) and logs "[SelfCheck] OK",
// "FAIL" or "SKIP" with the raw values. Reads that may hit a bad address run under SEH.
//
// Runs once when the local player spawns, and on demand with "/coop selfcheck" (which also
// checks the vehicle V sits in).
namespace SelfCheck
{
enum class Status
{
    Ok,
    Fail,
    Skip
};

struct Result
{
    std::string name;
    Status status;
    std::string detail;
};

// Runs apFn(apContext) under SEH; false if it raised (an access violation from a wrong layout).
// apFn must not own objects with destructors on its own frame.
bool Guarded(void (*apFn)(void*), void* apContext);

void Log(const Result& aResult);

// Body gender: the hand-mapped byte against the game's own IsBodyGenderMale, on the player's
// state and on a copy made from its serialized bytes the way a guest makes it.
void CheckGender(Red::game::ui::CharacterCustomizationState* apState, const Vector<uint8_t>& aBytes,
                 const Red::Handle<Red::GameObject>& aPlayer);

// Everything else; the gender result from the last spawn is included. aVehicle may be null.
// Returns a one-line summary for the chat.
Red::CString Run(const Red::Handle<Red::GameObject>& aPlayer, const Red::Handle<Red::GameObject>& aVehicle);
} // namespace SelfCheck
