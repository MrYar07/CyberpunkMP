#include "Core/Stl.hpp"
#include <RED4ext/Scripting/Natives/Generated/ink/TextInputWidget.hpp>

// The text input's own data, as mapped by hand for patch 2.1x (hasFocus 00, caret highlight 01,
// caretPosition 04, highlight counter 08, maxLength 0C, three callbacks 10-3F): 0x40 bytes after
// the ink::TextWidget base. Patch 2.5 grew the base by 0x30 (own data now at 0x460, still 0x40
// long), so the caret is read relative to the block, not at the old absolute 0x434.
// Assumes the order inside the block is unchanged - not yet checked in game.
struct TextInputExtension : RED4ext::ink::TextInputWidget
{
    static constexpr size_t kCaretPosition = 0x04;

    void MoveCaret(int32_t position) { *reinterpret_cast<int32_t*>(this->unk460 + kCaretPosition) = position; }
};

RTTI_EXPAND_CLASS(RED4ext::ink::TextInputWidget, { RTTI_METHOD_FQN(TextInputExtension::MoveCaret); });
