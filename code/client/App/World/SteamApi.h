#pragma once

// The game's own steam_api64.dll, through its flat API (steam_api_flat.h). Nothing is loaded
// when the game is not the Steam version: Available() is false and the rest does nothing.
namespace SteamApi
{
// Steamworks' CCallbackBase (steam_api_common.h), declared the same way so MSVC lays out the
// same vtable: no virtual destructor, the two Run overloads, then the size.
class CallbackBase
{
public:
    virtual void Run(void* apParam) = 0;
    virtual void Run(void* apParam, bool aIOFailure, uint64_t aCall) = 0;
    virtual int GetCallbackSizeBytes() = 0;

protected:
    uint8_t m_callbackFlags{0};
    int m_callback{0};
};

// SteamNetworkingIdentity (steamnetworkingtypes.h, packed to 8): type, size, then a union.
#pragma pack(push, 8)
struct Identity
{
    int32_t type;
    int32_t size;
    union
    {
        uint64_t steamId64;
        char raw[128];
    };
};
static_assert(sizeof(Identity) == 136);

// The start of SteamNetworkingMessage_t: what the tunnel reads. Released with ReleaseMessage.
struct Message
{
    void* data;            // 00
    int32_t size;          // 08
    uint32_t connection;   // 0C
    Identity peer;         // 10
};
static_assert(offsetof(Message, peer) == 0x10);
#pragma pack(pop)

// Loads the flat API from the game's steam_api64.dll (once).
bool Load();
// Steam is loaded and initialized by the game.
bool Available();

void* Friends();
void* Messages();
uint64_t LocalSteamId();

void RegisterCallback(CallbackBase* apCallback, int aId);

// ISteamFriends
void InviteDialog(const char* apConnect);
void SetRichPresence(const char* apKey, const char* apValue);
void ClearRichPresence();
std::string PersonaName();
// The local user and aSteamId are Steam friends (k_EFriendRelationshipFriend). False when it
// cannot be told, so callers that gate on it fail closed.
bool IsFriend(uint64_t aSteamId);

// ISteamNetworkingMessages (thread safe)
Identity SteamIdentity(uint64_t aSteamId);
bool Send(uint64_t aSteamId, const void* apData, uint32_t aSize, int aChannel);
int Receive(int aChannel, Message** apMessages, int aMax);
void ReleaseMessage(Message* apMessage);
bool AcceptSession(const Identity& aIdentity);
void CloseSession(uint64_t aSteamId);
// Starts setting up access to Valve's relays early, so the first connection is quicker.
void InitRelayNetwork();
} // namespace SteamApi
