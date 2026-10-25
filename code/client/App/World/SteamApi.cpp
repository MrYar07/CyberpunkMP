#include "SteamApi.h"

namespace
{
template<typename T>
T Resolve(HMODULE aModule, const char* apName, bool& aOk)
{
    const auto address = reinterpret_cast<T>(GetProcAddress(aModule, apName));
    if (!address)
    {
        spdlog::warn("[SteamApi] {} is missing from steam_api64.dll", apName);
        aOk = false;
    }
    return address;
}

bool s_loaded{false};
bool s_ok{false};

void* (*s_steamFriends)(){nullptr};
void* (*s_steamMessages)(){nullptr};
void* (*s_steamUser)(){nullptr};
void* (*s_steamUtils)(){nullptr};
uint64_t (*s_getSteamId)(void*){nullptr};
void (*s_registerCallback)(void*, int){nullptr};
void (*s_inviteDialog)(void*, const char*){nullptr};
bool (*s_setRichPresence)(void*, const char*, const char*){nullptr};
void (*s_clearRichPresence)(void*){nullptr};
const char* (*s_personaName)(void*){nullptr};
int (*s_friendRelationship)(void*, uint64_t){nullptr};
void (*s_setSteamId64)(SteamApi::Identity*, uint64_t){nullptr};
int (*s_sendToUser)(void*, const SteamApi::Identity&, const void*, uint32_t, int, int){nullptr};
int (*s_receive)(void*, int, SteamApi::Message**, int){nullptr};
void (*s_release)(SteamApi::Message*){nullptr};
bool (*s_accept)(void*, const SteamApi::Identity&){nullptr};
bool (*s_close)(void*, const SteamApi::Identity&){nullptr};
void (*s_initRelay)(void*){nullptr};

// k_nSteamNetworkingSend_UnreliableNoNagle | k_nSteamNetworkingSend_AutoRestartBrokenSession:
// the tunnel carries UDP datagrams, which the game's own network layer keeps reliable.
constexpr int kSendFlags = 1 | 32;
} // namespace

bool SteamApi::Load()
{
    if (s_loaded)
        return s_ok;
    s_loaded = true;

    const auto module = GetModuleHandleW(L"steam_api64.dll");
    if (!module)
    {
        spdlog::info("[SteamApi] no steam_api64.dll in the game, Steam features are off");
        return false;
    }

    bool ok = true;
    s_steamFriends = Resolve<decltype(s_steamFriends)>(module, "SteamAPI_SteamFriends_v017", ok);
    s_steamMessages = Resolve<decltype(s_steamMessages)>(module, "SteamAPI_SteamNetworkingMessages_SteamAPI_v002", ok);
    s_steamUser = Resolve<decltype(s_steamUser)>(module, "SteamAPI_SteamUser_v021", ok);
    s_steamUtils = Resolve<decltype(s_steamUtils)>(module, "SteamAPI_SteamNetworkingUtils_SteamAPI_v004", ok);
    s_getSteamId = Resolve<decltype(s_getSteamId)>(module, "SteamAPI_ISteamUser_GetSteamID", ok);
    s_registerCallback = Resolve<decltype(s_registerCallback)>(module, "SteamAPI_RegisterCallback", ok);
    s_inviteDialog = Resolve<decltype(s_inviteDialog)>(module, "SteamAPI_ISteamFriends_ActivateGameOverlayInviteDialogConnectString", ok);
    s_setRichPresence = Resolve<decltype(s_setRichPresence)>(module, "SteamAPI_ISteamFriends_SetRichPresence", ok);
    s_clearRichPresence = Resolve<decltype(s_clearRichPresence)>(module, "SteamAPI_ISteamFriends_ClearRichPresence", ok);
    s_personaName = Resolve<decltype(s_personaName)>(module, "SteamAPI_ISteamFriends_GetPersonaName", ok);
    s_setSteamId64 = Resolve<decltype(s_setSteamId64)>(module, "SteamAPI_SteamNetworkingIdentity_SetSteamID64", ok);
    s_sendToUser = Resolve<decltype(s_sendToUser)>(module, "SteamAPI_ISteamNetworkingMessages_SendMessageToUser", ok);
    s_receive = Resolve<decltype(s_receive)>(module, "SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel", ok);
    s_release = Resolve<decltype(s_release)>(module, "SteamAPI_SteamNetworkingMessage_t_Release", ok);
    s_accept = Resolve<decltype(s_accept)>(module, "SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser", ok);
    s_close = Resolve<decltype(s_close)>(module, "SteamAPI_ISteamNetworkingMessages_CloseSessionWithUser", ok);
    s_initRelay = Resolve<decltype(s_initRelay)>(module, "SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess", ok);
    // Not required for the rest: without it the tunnel accepts nobody (IsFriend is false).
    bool friendsOk = true;
    s_friendRelationship = Resolve<decltype(s_friendRelationship)>(module, "SteamAPI_ISteamFriends_GetFriendRelationship", friendsOk);

    s_ok = ok;
    if (!ok)
        spdlog::warn("[SteamApi] steam_api64.dll lacks what the co-op needs, Steam features are off");
    return s_ok;
}

bool SteamApi::Available()
{
    return Load() && Friends() != nullptr;
}

void* SteamApi::Friends()
{
    return s_ok ? s_steamFriends() : nullptr;
}

void* SteamApi::Messages()
{
    return s_ok ? s_steamMessages() : nullptr;
}

uint64_t SteamApi::LocalSteamId()
{
    auto* pUser = s_ok ? s_steamUser() : nullptr;
    return pUser ? s_getSteamId(pUser) : 0;
}

void SteamApi::RegisterCallback(CallbackBase* apCallback, int aId)
{
    if (s_ok)
        s_registerCallback(apCallback, aId);
}

void SteamApi::InviteDialog(const char* apConnect)
{
    if (auto* pFriends = Friends())
        s_inviteDialog(pFriends, apConnect);
}

void SteamApi::SetRichPresence(const char* apKey, const char* apValue)
{
    if (auto* pFriends = Friends())
        s_setRichPresence(pFriends, apKey, apValue);
}

void SteamApi::ClearRichPresence()
{
    if (auto* pFriends = Friends())
        s_clearRichPresence(pFriends);
}

std::string SteamApi::PersonaName()
{
    auto* pFriends = Friends();
    if (!pFriends)
        return {};
    const auto* pName = s_personaName(pFriends);
    return pName ? pName : "";
}

bool SteamApi::IsFriend(uint64_t aSteamId)
{
    // EFriendRelationship: k_EFriendRelationshipFriend = 3.
    constexpr int kFriend = 3;
    auto* pFriends = Friends();
    return pFriends && s_friendRelationship && aSteamId != 0 && s_friendRelationship(pFriends, aSteamId) == kFriend;
}

SteamApi::Identity SteamApi::SteamIdentity(uint64_t aSteamId)
{
    Identity identity{};
    if (s_ok)
        s_setSteamId64(&identity, aSteamId);
    return identity;
}

bool SteamApi::Send(uint64_t aSteamId, const void* apData, uint32_t aSize, int aChannel)
{
    auto* pMessages = Messages();
    if (!pMessages)
        return false;
    const auto identity = SteamIdentity(aSteamId);
    // EResult 1 = k_EResultOK
    return s_sendToUser(pMessages, identity, apData, aSize, kSendFlags, aChannel) == 1;
}

int SteamApi::Receive(int aChannel, Message** apMessages, int aMax)
{
    auto* pMessages = Messages();
    return pMessages ? s_receive(pMessages, aChannel, apMessages, aMax) : 0;
}

void SteamApi::ReleaseMessage(Message* apMessage)
{
    if (apMessage)
        s_release(apMessage);
}

bool SteamApi::AcceptSession(const Identity& aIdentity)
{
    auto* pMessages = Messages();
    return pMessages && s_accept(pMessages, aIdentity);
}

void SteamApi::CloseSession(uint64_t aSteamId)
{
    if (auto* pMessages = Messages())
        s_close(pMessages, SteamIdentity(aSteamId));
}

void SteamApi::InitRelayNetwork()
{
    auto* pUtils = s_ok ? s_steamUtils() : nullptr;
    if (pUtils)
        s_initRelay(pUtils);
}
