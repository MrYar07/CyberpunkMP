#pragma once

#include "Core/Hooking/HookingAgent.hpp"

// Dialog choices for campaign co-op votes. The game picks a dialog option natively, from
// player input, with no script API, so:
// - while the players vote, the host's confirm presses are held back and only counted (the
//   script turns them into the host's vote for the highlighted option);
// - once the vote is decided, the winner is picked by feeding the game the same key presses
//   a player would make: Up/Down to it, then F.
// Same technique as Neuro's Cyberpunk integration (github.com/VedalAI/neuro-cyberpunk, via
// SharedPunk's Player::ProcessInput, MIT).
struct ChoiceInput : Core::HookingAgent
{
    static void Attach();

    static void SetLock(bool aLocked);
    static int32_t TakeBlockedConfirms();
    // Moves the highlight by aSteps (negative = up) and confirms.
    static bool Inject(int32_t aSteps);

    // Feeds one queued key per call, spaced out so every press registers on its own.
    static void Update();
};
