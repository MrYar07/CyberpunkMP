#include "ChoiceInput.h"

#include <RED4ext/Memory/Allocators.hpp>
#include <RED4ext/Scripting/Natives/inkCharacterEvent.hpp>
#include <RED4ext/Scripting/Natives/Generated/EInputKey.hpp>
#include <RED4ext/Scripting/Natives/Generated/cp/Player.hpp>
#include <RED4ext/Scripting/Natives/Generated/game/PlayerManager.hpp>

namespace
{
// Layouts from SharedPunk (github.com/alphanin9/SharedPunk, MIT): Raw/Ink/InkSystem.hpp.
// Patch 2.5 grew each entry by 8 bytes (0x40 -> 0x48): Codeware b054150 "Support patch 2.5",
// src/Red/Input.hpp. The stride matters - this code walks and edits the game's own array.
struct RawInputData
{
    Red::EInputKey key;       // 00
    Red::EInputAction action; // 04
    float value;              // 08
    uint32_t mouseX;          // 0C
    uint32_t mouseY;          // 10
    uint32_t unk14;           // 14
    uint32_t unk18;           // 18 - input processing checks this to be 1
    uint64_t unk20;           // 20
    uint64_t unk28;           // 28
    uint64_t unk30;           // 30
    uint64_t unk38;           // 38
    uint64_t unk40;           // 40 - new in patch 2.5
};
static_assert(sizeof(RawInputData) == 0x48);

// The game's own buffers are only read through this interface.
struct RawInputBuffer
{
    virtual ~RawInputBuffer() = default;                  // 00
    virtual Red::DynArray<RawInputData>& GetInputs() = 0; // 08
};

// Ours, filled with the keys to press. The game may call the rest of the interface; it gets
// harmless answers.
struct SyntheticInputBuffer : RawInputBuffer
{
    SyntheticInputBuffer()
        : inputs(Red::Memory::InputInternalAllocator::Get())
    {
    }

    Red::DynArray<RawInputData>& GetInputs() override { return inputs; }
    virtual void Unk10() {}
    virtual void Unk18() {}
    virtual void Unk20() {}
    virtual void Unk28() {}
    virtual void Unk30() {}
    virtual void Unk38() {}
    virtual void Unk40() {}
    virtual void Unk48() {}
    virtual void Unk50() {}
    virtual void Unk58() {}
    virtual void Unk60() {}
    virtual void Unk68() {}
    virtual void Unk70() {}
    virtual void Unk78() {}
    virtual void Unk80() {}
    virtual void Unk88() {}
    virtual int Unk90() { return 0; }

    Red::DynArray<RawInputData> inputs;
};

void (*RealPlayer_ProcessInput)(Red::cp::Player*, RawInputBuffer&);

constexpr auto Player_ProcessInput = Core::RawFunc<
    /* hash = */ 3535541945UL,
    /* type = */ decltype(RealPlayer_ProcessInput)>();

// PlayerManager's virtual at 0x200 returns the local cpPlayer (SharedPunk, Raw/Player/Player.hpp).
Red::cp::Player* GetLocalPlayer()
{
    auto* pManager = Red::GetGameSystem<Red::game::PlayerManager>();
    if (!pManager)
        return nullptr;

    using GetPlayerObject = Red::cp::Player* (*)(Red::game::PlayerManager*);
    const auto vft = *reinterpret_cast<uintptr_t*>(pManager);
    return (*reinterpret_cast<GetPlayerObject*>(vft + 0x200))(pManager);
}

constexpr auto kDelayBetweenKeys = std::chrono::milliseconds(120);

std::atomic_bool s_locked{false};
std::atomic_int32_t s_blockedConfirms{0};
// Set while our own presses go through the hook, so the lock lets them pass.
std::atomic_bool s_injecting{false};
bool s_attached{false};

std::mutex s_queueLock;
std::deque<Red::EInputKey> s_queue;
std::chrono::steady_clock::time_point s_lastKey{};

// The default DialogConfirm keys (inputUserMappings.xml), and a click on an option.
bool IsConfirm(Red::EInputKey aKey)
{
    return aKey == Red::EInputKey::IK_F || aKey == Red::EInputKey::IK_Enter || aKey == Red::EInputKey::IK_Pad_X_SQUARE ||
           aKey == Red::EInputKey::IK_LeftMouse;
}

void HookPlayer_ProcessInput(Red::cp::Player* apPlayer, RawInputBuffer& aBuffer)
{
    if (s_locked && !s_injecting)
    {
        auto& inputs = aBuffer.GetInputs();
        for (uint32_t i = 0; i < inputs.size();)
        {
            if (IsConfirm(inputs[i].key))
            {
                if (inputs[i].action == Red::EInputAction::IACT_Press)
                    ++s_blockedConfirms;

                inputs.RemoveAt(i);
                continue;
            }
            ++i;
        }
    }

    RealPlayer_ProcessInput(apPlayer, aBuffer);
}

void Press(Red::EInputKey aKey)
{
    auto* pPlayer = GetLocalPlayer();
    if (!pPlayer)
    {
        spdlog::warn("[ChoiceInput] no local player, key {} dropped", static_cast<uint32_t>(aKey));
        return;
    }

    SyntheticInputBuffer buffer;
    RawInputData data{};
    data.key = aKey;
    data.action = Red::EInputAction::IACT_Press;
    data.value = 1.f;
    data.unk18 = 1;
    buffer.inputs.PushBack(data);

    data.action = Red::EInputAction::IACT_Release;
    buffer.inputs.PushBack(data);

    s_injecting = true;
    RealPlayer_ProcessInput(pPlayer, buffer);
    s_injecting = false;
}
} // namespace

void ChoiceInput::Attach()
{
    if (s_attached)
        return;

    s_attached = Hook<Player_ProcessInput>(&HookPlayer_ProcessInput, &RealPlayer_ProcessInput);
    if (!s_attached)
        spdlog::error("[ChoiceInput] could not hook Player::ProcessInput, dialog votes cannot drive the host's game");
}

void ChoiceInput::SetLock(bool aLocked)
{
    s_locked = aLocked && s_attached;
    s_blockedConfirms = 0;
}

int32_t ChoiceInput::TakeBlockedConfirms()
{
    return s_blockedConfirms.exchange(0);
}

bool ChoiceInput::Inject(int32_t aSteps)
{
    if (!s_attached)
        return false;

    std::lock_guard _(s_queueLock);

    const auto key = aSteps < 0 ? Red::EInputKey::IK_Up : Red::EInputKey::IK_Down;
    for (auto i = 0; i < std::abs(aSteps); ++i)
        s_queue.push_back(key);
    s_queue.push_back(Red::EInputKey::IK_F);

    return true;
}

void ChoiceInput::Update()
{
    Red::EInputKey key;
    {
        std::lock_guard _(s_queueLock);
        if (s_queue.empty())
            return;

        const auto now = std::chrono::steady_clock::now();
        if (now - s_lastKey < kDelayBetweenKeys)
            return;

        s_lastKey = now;
        key = s_queue.front();
        s_queue.pop_front();
    }

    // Outside the queue lock: the press goes through our own hook.
    Press(key);
}
