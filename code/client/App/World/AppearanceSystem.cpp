#include "App/World/AppearanceSystem.h"

#include <memory>

#include "RED4ext/Scripting/Natives/gameIEntityStubSystem.hpp"
#include "RED4ext/Scripting/Natives/gameITransactionSystem.hpp"
#include "RED4ext/Scripting/Natives/gameItemModParams.hpp"
#include "RED4ext/Scripting/Natives/gameAddItemToSlotContext.hpp"
#include "RED4ext/Scripting/Natives/Generated/game/EntityStubComponentPS.hpp"
#include "RED4ext/Scripting/Natives/Generated/game/data/Item_Record.hpp"
#include "RED4ext/NativeTypes.hpp"
#include "RED4ext/ResourceLoader.hpp"


#include "NetworkWorldSystem.h"
#include "Game/Utils.h"
#include "Game/CharacterCustomizationSystem.h"
#include "RED4ext/Scripting/Natives/Generated/game/PuppetPS.hpp"

AppearanceSystem::AppearanceSystem()
{

}

void AppearanceSystem::OnInitialize(const RED4ext::JobHandle& aJob)
{
    spdlog::info("[AppearanceSystem] OnInitialize");
}

void AppearanceSystem::OnWorldAttached(RED4ext::world::RuntimeScene* aScene)
{    
    spdlog::info("[AppearanceSystem] OnWorldAttached");
    Red::CallVirtual(this, "OnWorldAttached");
}

void AppearanceSystem::OnBeforeWorldDetach(RED4ext::world::RuntimeScene* aScene)
{
    spdlog::info("[AppearanceSystem] OnBeforeWorldDetach");
    Red::CallVirtual(this, "OnBeforeWorldDetach");
}

Red::DynArray<Red::TweakDBID> AppearanceSystem::GetEntityItems(Red::EntityID & entityID)
{
    return m_playerEquipment[entityID];
}

Vector<String> AppearanceSystem::GetPlayerItems(Red::Handle<Red::GameObject> player)
{
    auto equipment = Vector<String>();
    Red::DynArray<Red::CString> items;
    Red::CallVirtual(this, "GetPlayerItems", items);
    for (auto item : items)
    {
        spdlog::info("Getting: {}", item.c_str());
        equipment.push_back(item.c_str());
    }
    return equipment;
}

void AppearanceSystem::SetEntityName(Red::EntityID entityID, const std::string& acName)
{
    m_playerNames[entityID] = acName;
}

std::string AppearanceSystem::GetEntityName(Red::EntityID entityID) const
{
    const auto it = m_playerNames.find(entityID);
    return it == m_playerNames.end() ? std::string() : it->second;
}

void AppearanceSystem::ForgetEntityName(Red::EntityID entityID)
{
    m_playerNames.erase(entityID);
}

void AppearanceSystem::ForgetEntityNames()
{
    m_playerNames.clear();
}

// std::string does not cross into script; this does.
Red::CString AppearanceSystem::GetNetworkPlayerName(Red::EntityID aEntityId) const
{
    return Red::CString(GetEntityName(aEntityId).c_str());
}

void AppearanceSystem::AddEntity(const Red::EntityID entityID, const Red::DynArray<Red::TweakDBID>& items, const Vector<uint8_t> ccstate)
{
    spdlog::info("Logging Entity Appearance: {}", entityID.hash);
    m_playerEquipment[entityID] = items;
    m_playerCcstate[entityID] = ccstate;
}

void AddItems(Red::Handle<Red::game::Object> & object, Red::DynArray<Red::TweakDBID> const & items, game::ui::CharacterCustomizationState const * state)
{
    auto system = Red::GetGameSystem<Red::game::ITransactionSystem>();
    for (auto item : items)
    {
        auto itemID = Red::ItemID();
        ItemID_Create(&itemID, item, -1);
        if (!itemID.IsValid())
        {
            spdlog::warn("ItemID creation failed");
            continue;
        }

        auto item_record = Red::Handle<Red::game::data::Item_Record>();
        GetItemRecord(&item_record, item);
        if (!item_record)
        {
            spdlog::warn("Item record not found");
            continue;
        }
        
        auto placementSlotHandle = Red::Handle<Red::game::data::AttachmentSlot_Record>();
        GetPlacementSlot(item_record.instance, &placementSlotHandle, 0);
        if (!placementSlotHandle)
        {
            spdlog::warn("Placement slot not found... kinda weird");
            continue;
        }

        auto placementSlot = placementSlotHandle.instance->recordID;

        Red::CString str;
        Red::CallStatic("gamedataTDBIDHelper", "ToStringDEBUG", str, item);
        Red::CString placementStr;
        Red::CallStatic("gamedataTDBIDHelper", "ToStringDEBUG", placementStr, placementSlot);

        auto appearanceName = EvalCName(&item_record.instance->appearanceName);
        std::string appearance = appearanceName.ToString();
        // auto suffixes = EvalArrayTweakDBID(&item_record.instance->appearanceSuffixes);
        // for (auto const suffix : suffixes) {
        //     if (suffix == Red::TweakDBID("itemsFactoryAppearanceSuffix.Gender")) {
        //         if (state->isBodyGenderMale) {
        //             appearance.append("&Male");
        //         } else {
        //             appearance.append("&Female");
        //         }
        //     } else if (suffix == Red::TweakDBID("itemsFactoryAppearanceSuffix.Camera")) {
        //         appearance.append("&TPP");
        //     } else if (suffix == Red::TweakDBID("itemsFactoryAppearanceSuffix.Partial")) {
        //         appearance.append("&Full");
        //     } else if (suffix == Red::TweakDBID("itemsFactoryAppearanceSuffix.HairType")) {
        //         if (state->tags.Contains("Short")) {
        //             appearance.append("&Short");
        //         } else if (state->tags.Contains("Long")) {
        //             appearance.append("&Long");
        //         } else if (state->tags.Contains("Dreads")) {
        //             appearance.append("&Dreads");
        //         } else if (state->tags.Contains("Buzz")) {
        //             appearance.append("&Buzz");
        //         } else {
        //             appearance.append("&Bald");
        //         }
        //     }
        // }
        spdlog::info("Adding {} to {} with \"{}\"", str.c_str(), placementStr.c_str(), appearance);
        Red::CString redAppStr;
        GetItemAppearanceName(&redAppStr, object, object, item_record, itemID);
        spdlog::info("* computed suffix: {}", redAppStr.c_str());
        appearance.append(redAppStr.c_str());

        appearanceName = appearance.c_str();

        auto params = Red::game::ItemModParams();
        params.quantity = 1;
        params.itemID = itemID;

        auto context = Red::game::AddItemToSlotContext();
        context.object = object.instance;
        context.slotID = placementSlot;
        context.itemID = itemID;
        // context.itemID.flags |= 1;
        // context.ignoreRestrictions = 1;
        context.renderingPlane = Red::ERenderingPlane::RPl_Scene;
        // context.renderingPlane = Red::ERenderingPlane::RPl_Weapon;
        context.garmentAppearanceName = appearanceName;

        auto given = system->GiveItem(*object, params);
        if (given)
        {
            auto added = system->AddItemToSlot(context);
            if (!added)
            {
                // Previously logged nothing identifying - every failure looked the same
                // in the log and this line was seen ~106 times in one evening with no way
                // to tell which item/slot/puppet was involved. A dropped equip here leaves
                // the puppet's async garment part-entities attached to a still-assembling
                // entity, a plausible delayed 0xC0000005 source.
                spdlog::warn("[Appearance] AddItemToSlot failed: entity {:x}, item {:016x}, slot {:016x}",
                             object->id.hash, static_cast<uint64_t>(item), static_cast<uint64_t>(placementSlot));
            }
        } else
        {
            spdlog::warn("[Appearance] GiveItem failed: entity {:x}, item {:016x}",
                          object->id.hash, static_cast<uint64_t>(item));
        }
    }
}

bool AppearanceSystem::ApplyAppearance(Red::Handle<Red::game::Object> object)
{
    if (!object.instance)
    {
        spdlog::error("[Appearance] ApplyAppearance called with a null object - aborting");
        return false;
    }

    if (m_playerCcstate.find(object.instance->id) == m_playerCcstate.end())
    {
        // not our entity
        return false;
    }

    auto bytes = m_playerCcstate[object.instance->id];
    if (bytes.size() == 0)
    {
        spdlog::info("no bytes for {}", object->id.hash);
        return false;
    }

    // The player's name over their character's head (upstream had "Test" here). The muppet
    // records' own names are blanked in the tweaks, or the nameplate would read those first.
    const auto name = GetEntityName(object.instance->id);
    if (!name.empty())
        object.instance->displayName.unk08 = Red::CString(name.c_str());

    spdlog::info("Loaded bytes: {}", bytes.size());

    Red::Handle<game::ui::CharacterCustomizationState> stateHandle;
    CreateHandle_CharacterCustomizationState(&stateHandle);

    if (!stateHandle.instance)
    {
        spdlog::error("[Appearance] CreateHandle_CharacterCustomizationState returned null - aborting");
        return false;
    }

    if (bytes.empty())
    {
        spdlog::warn("[Appearance] no ccstate bytes for this entity - appearance will be default");
    }
    else
    {
        auto reader = CMPReader(bytes);
        CharacterCustomizationState_Serialize(stateHandle.instance, &reader);

        // A short or mis-sized ccstate blob used to deserialize "successfully" into
        // garbage customization arrays (Serialize silently stopped writing once the
        // buffer ran out). Now that a real under-run is reported, refuse to build a
        // puppet's appearance from it - a default appearance is a visible, harmless
        // fallback; garbage customization keys feeding into the appearance job later
        // is a plausible crash input, and worse on the bigger female payloads.
        if (!reader.IsOK() || reader.GetOffset() != bytes.size())
        {
            spdlog::error("[Appearance] ccstate for entity {:x} did not deserialize cleanly "
                           "(consumed {}/{} bytes, ok={}) - aborting apply, appearance stays default",
                           object.instance->id.hash, reader.GetOffset(), bytes.size(), reader.IsOK());
            return false;
        }
    }

    // shouldn't be needed
    // Red::CallVirtual(this, "AddBodyParts", object, stateHandle.instance->isBodyGenderMale);

    auto ps = reinterpret_cast<Red::game::PuppetPS*>(object.instance->persistentState.instance);
    if (!ps)
    {
        spdlog::error("[Appearance] puppet persistentState is null - aborting before writing unk72");
        return false;
    }
    // checked during item adding process for &TPP
    ps->unk72[0] = 1;

    // old method
    // Red::CallVirtual(this, "AddItems", object);

    // c++ method
    auto items = m_playerEquipment[object.instance->id];
    // if (stateHandle.instance->isBodyGenderMale) {
    //     // items.PushBack("Items.PlayerMaTppHead");
    //     items.PushBack("Items.MuppetMaHead");
    // } else {
    //     // items.PushBack("Items.PlayerWaTppHead");
    //     items.PushBack("Items.MuppetWaHead");
    // }
    // items.PushBack("Items.MuppetArms");
    AddItems(object, items, stateHandle.instance);

    // spdlog::info("head groups read:");
    // for (auto &group : stateHandle.instance->unk70) 
    // {
    //     spdlog::info(group.name.ToString());
    // }
    // ma
    //  TPP
    //  FPP
    //  hairs
    //  character_customization
    //  TPP_proxy
    //  FPP_proxy
    //  FPP_hairs
    //  TPP_photomode
    //  beards
    //  face
    //  finalSceneBruises
    // wa
    //  TPP
    //  FPP
    //  hairs
    //  character_customization
    //  TPP_proxy
    //  FPP_proxy
    //  FPP_hairs
    //  TPP_photomode
    //  face
    //  finalSceneBruises

    // spdlog::info("body groups read:");
    // for (auto &group : stateHandle.instance->unk80) 
    // {
    //     spdlog::info(group.name.ToString());
    // }
    // FPP_Body
    // TPP_Body
    // character_creation
    // genitals
    // breast

    // FPP_Body
    // TPP_Body
    // character_creation
    // genitals
    // breast
    // lifted_feet
    // flat_feet

    // spdlog::info("arm groups read:");
    // for (auto &group : stateHandle.instance->unk90) 
    // {
    //     spdlog::info(group.name.ToString());
    // }
    // holstered_default
    // holstered_strong
    // unholstered_strong
    // holstered_nanowire
    // unholstered_nanowire
    // character_customization
    // personal_link_simple
    // personal_link_advanced      
    // holstered_launcher
    // unholstered_launcher
    // holstered_mantis
    // unholstered_mantis
    // nails

    // holstered_default_tpp
    // holstered_default_fpp
    // holstered_strong_tpp
    // holstered_strong_fpp
    // unholstered_strong
    // holstered_nanowire_tpp
    // holstered_nanowire_fpp
    // unholstered_nanowire
    // character_customization
    // personal_link_simple
    // personal_link_advanced
    // holstered_launcher_tpp
    // holstered_launcher_fpp
    // unholstered_launcher
    // holstered_mantis_tpp
    // holstered_mantis_fpp
    // unholstered_mantis
    // nails

    if (stateHandle)
    {
        spdlog::info("Scheduling change");

        Red::DynArray<Red::world::EntityAppearanceChangeParameter::Key> keys;
        stateHandle.instance->GetHeadCustomization("TPP", true, keys);
        stateHandle.instance->GetHeadCustomization("face", true, keys);
        stateHandle.instance->GetHeadCustomization("hairs", true, keys);
        if (stateHandle.instance->isBodyGenderMale) 
        {
            stateHandle.instance->GetHeadCustomization("beards", true, keys);
        }

        // does all of them
        // stateHandle.instance->GetHeadCustomization("character_customization", true, keys);

        stateHandle.instance->GetBodyCustomization("TPP_Body", true, keys);
        // make genitals appear as well
        // stateHandle.instance->GetBodyCustomization("character_creation", true, keys);
        // pops through clothes lol
        // stateHandle.instance->GetBodyCustomization("genitals", true, keys);
        stateHandle.instance->GetBodyCustomization("breast", true, keys);
        stateHandle.instance->GetBodyCustomization("lifted_feet", true, keys);
        stateHandle.instance->GetBodyCustomization("flat_feet", true, keys);

        // stateHandle.instance->GetArmsCustomization("character_customization", true, keys);
        stateHandle.instance->GetArmsCustomization("holstered_default", true, keys);
        stateHandle.instance->GetArmsCustomization("nails", true, keys);

        auto changer = Red::GetRuntimeSystem<Red::world::RuntimeSystemEntityAppearanceChanger>();
        Red::WeakHandle<Red::game::Object> weakHandle = object;
        Span<Red::world::EntityAppearanceChangeParameter::Key> old_keys = {
            .start = nullptr,
            .end = nullptr
        };

        // keys was a stack-lifetime DynArray: this Span pointed into its heap-allocated
        // entries, which is fine ONLY if ScheduleSynchronizedAppearanceChanges reads the
        // span before returning. If it defers reading the spans until the change actually
        // executes (plausible - it takes a completion callback, i.e. it is async), this
        // read freed memory seconds later - a use-after-free that reproduces more on
        // female states (more customization groups -> more keys -> bigger, differently
        // reused allocations), matching the female-biased crash signature. Moving keys
        // onto the heap and keeping it alive in the SAME capture as stateHandle/object
        // (already tied to completion) makes the span's backing memory outlive the
        // engine's read regardless of when that read happens.
        auto keysStorage = std::make_shared<Red::DynArray<Red::world::EntityAppearanceChangeParameter::Key>>(std::move(keys));
        Span<Red::world::EntityAppearanceChangeParameter::Key> new_keys = {
            .start = keysStorage->entries,
            .end = &keysStorage->entries[keysStorage->size]
        };
        const std::function<void (void)> callback = [stateHandle = std::move(stateHandle), object = std::move(object), keysStorage](void)
        {
            // AddItems(object, items, stateHandle.instance);

            // this might not be needed? - JACK
            // also makes wa faces disappear :/

            // spdlog::info("Changed callback");
            // // TransactionSystem::sub_440(object, std::function);
            // // hide some components based on Get*Customization
            // // MorphHead;
            
            // stateHandle.instance->MorphHead("TPP", true, object, true);
            // // stateHandle.instance->MorphHead("face", true, object, true);
            // stateHandle.instance->MorphHead("hairs", true, object, true);
            
            // if (stateHandle.instance->isBodyGenderMale) 
            // {
            //     stateHandle.instance->MorphHead("beards", true, object, true);
            // }

            // stateHandle.instance->MorphBody("TPP_Body", true, object, true);
            // // stateHandle.instance->MorphBody("genitals", true, object, true);
            // // stateHandle.instance->MorphBody("breast", true, object, true);

            // stateHandle.instance->MorphArms("holstered_default", true, object, true);
            // // stateHandle.instance->MorphArms("nails", true, object, true);

            // stateHandle.instance->ApplyHead("TPP", true, object);
            // // stateHandle.instance->ApplyHead("face", true, object);
            // stateHandle.instance->ApplyHead("hairs", true, object);
        
            // if (stateHandle.instance->isBodyGenderMale) 
            // {
            //     stateHandle.instance->ApplyHead("beards", true, object);
            // }

            // stateHandle.instance->ApplyBody("TPP_Body", true, object);
            // // stateHandle.instance->ApplyBody("genitals", true, object);
            // // stateHandle.instance->ApplyBody("breast", true, object);

            // stateHandle.instance->ApplyArms("holstered_default", true, object);
            // // stateHandle.instance->ApplyArms("nails", true, object);
        
            // // auto apprSystem = Red::GetGameSystem<AppearanceSystem>();
            // // Red::CallVirtual(apprSystem, "AddItems", object);
            // // Red::CallVirtual(apprSystem, "AddBodyParts", object, stateHandle.instance->isBodyGenderMale);
            
        };
        ScheduleSynchronizedAppearanceChanges(changer, weakHandle, &old_keys, &new_keys, callback, 0);
    }
    else
    {
        spdlog::warn("CustomizationState was null");
    }

    return true;
}
