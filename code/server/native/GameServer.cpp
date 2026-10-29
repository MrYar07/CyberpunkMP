#include "GameServer.h"

#include <Components/PlayerComponent.h>

#include "Core/Filesystem.h"
#include "Game/Level.h"
#include "Scripting/IRpc.h"
#include "Scripting/RpcScriptInstance.h"

#include "PlayerManager.h"


using nlohmann::json;

GameServer* GServer = nullptr;

namespace
{
// The server also builds for Linux (Docker), so no _dupenv_s.
std::string EnvString(const char* acpName)
{
#ifdef _WIN32
    char* pValue = nullptr;
    size_t size = 0;
    if (_dupenv_s(&pValue, &size, acpName) != 0 || !pValue)
        return {};
    std::string value(pValue);
    free(pValue);
    return value;
#else
    const char* pValue = std::getenv(acpName);
    return pValue ? std::string(pValue) : std::string{};
#endif
}

bool EnvFlag(const char* acpName)
{
    const auto value = EnvString(acpName);
    return value == "1" || value == "true";
}

// Same length and same bytes, without stopping at the first difference.
bool SecretEquals(std::string_view acLhs, std::string_view acRhs)
{
    uint8_t diff = acLhs.size() == acRhs.size() ? 0 : 1;
    for (size_t i = 0; i < acLhs.size(); ++i)
        diff |= static_cast<uint8_t>(acLhs[i] ^ (i < acRhs.size() ? acRhs[i] : 0));
    return diff == 0;
}
} // namespace

GameServer::GameServer()
    : Server(client::kIdentifier, server::kIdentifier)
    , m_log(m_path)
    , m_lastUpdate(std::chrono::steady_clock::now())
{
    GServer = this;

    try
    {
        auto serverPath = GetPath();

        std::ifstream config(serverPath / "config" / "server.json");
        if (!config.is_open())
        {
            spdlog::info("No configuration file found, creating config/server.json");
            std::error_code ec;
            create_directory(serverPath / "config", ec);

            std::ofstream of(serverPath / "config" / "server.json");
            json data = m_config;
            data["ConfigVersion"] = 1;
            of << std::setw(4) << data;
        }
        else
        {
            json data = json::parse(config);
            m_config = data.get<Config>();
            config.close();

            // Configs written before UpdateRate's default went from 10 to 30 still carry the
            // old default, which kept remote players on 100 ms samples and a 200 ms delay.
            // Migrated once; the marker keeps a rate the host sets afterwards.
            if (!data.contains("ConfigVersion"))
            {
                if (m_config.UpdateRate == 10)
                {
                    m_config.UpdateRate = 30;
                    spdlog::info("config/server.json: UpdateRate 10 -> 30 (new default)");
                }
                json migrated = m_config;
                migrated["ConfigVersion"] = 1;
                std::ofstream of(serverPath / "config" / "server.json");
                of << std::setw(4) << migrated;
            }
        }
    }
    catch (std::exception& e)
    {
        spdlog::error("Error parsing config.json: {}", e.what());
        m_run = false;
        return;
    }

    // A server the game starts for the Steam tunnel (ServerHost.cpp) is reached only through
    // the tunnel, locally: it listens on loopback so nobody can go around the tunnel's friends
    // check, and it may be handed a join password the same way as the admin account.
    const bool loopbackOnly = EnvFlag("CYBERPUNKMP_BIND_LOOPBACK");
    if (const auto password = EnvString("CYBERPUNKMP_SERVER_PASSWORD"); !password.empty())
        m_config.Password = password;

    uint16_t port = m_config.Port;
    while (!Host(port, m_config.TickRate, true, loopbackOnly))
    {
        spdlog::warn("Port {} is already in use, trying {}", port, port + 1);
        port++;
    }

    m_pWorld = MakeUnique<World>(m_config.GetFlecsConfig());
    m_pWorld->GetScriptInstance()->Initialize();

    RegisterHandler<&GameServer::HandleAuthentication>(this);

    spdlog::info("Server started on port {}{}{}", GetPort(), loopbackOnly ? " (this computer only)" : "",
                 m_config.Password.empty() ? ", no join password" : ", join password required");
}

GameServer::~GameServer()
{
    GServer = nullptr;
}

void GameServer::Kill()
{
    m_run = false;
    Close();
}

void GameServer::Run()
{
    while (m_run && IsListening())
        Update();
}

void GameServer::OnUpdate()
{
    const auto now = std::chrono::steady_clock::now();
    const auto delta = now - m_lastUpdate;
    m_lastUpdate = now;

    m_tasks.Drain();
    m_dispatcher.update();

    m_pWorld->Update(std::chrono::duration_cast<std::chrono::duration<float>>(delta).count());
}

void GameServer::OnConsume(const void* apData, uint32_t aSize, ConnectionId aConnectionId)
{
    // ReSharper disable once CppCStyleCast
    ViewBuffer buffer((uint8_t*)apData, aSize);  // NOLINT(clang-diagnostic-cast-qual)
    Buffer::Reader reader(&buffer);

    if (const auto result = client::Deserializer::Process(reader, aConnectionId, m_dispatcher); !result)
    {
        spdlog::error("Failed to deserialize packet from {}", aConnectionId);
    }
}

void GameServer::OnConnection(ConnectionId aHandle)
{
    spdlog::debug("Connection received {:x}", aHandle);
}

void GameServer::OnDisconnection(ConnectionId aConnectionId, EDisconnectReason aReason)
{
    spdlog::debug("Connection ended {:x}", aConnectionId);

    auto* pPlayerManager = GetWorld()->get_mut<PlayerManager>();

    if (const auto player = pPlayerManager->GetByConnectionId(aConnectionId))
    {
        pPlayerManager->Remove(player);

        if (auto* pPlayerComponent = player.get<PlayerComponent>())
        {
            GetWorld()->get_mut<Level>()->Remove(pPlayerComponent->Puppet);
        }

        player.destruct();

        spdlog::info("{}/{} player(s) online", pPlayerManager->Count(), m_config.MaxPlayer);
    }
}

void GameServer::HandleAuthentication(const PacketEvent<client::AuthenticationRequest>& aRequest)
{
    server::AuthenticationResponse response;

    if (aRequest.get_client_protocol() != client::kIdentifier)
    {
        response.set_success(false);
        response.set_error("Invalid protocol version!");

        spdlog::warn("Connection attempt with client identifier {:x}, expected {:x}", aRequest.get_client_protocol(), client::kIdentifier);
        Send(aRequest.ConnectionId, response);
        Kick(aRequest.ConnectionId);
        return;
    }

    if (aRequest.get_server_protocol() != server::kIdentifier)
    {
        response.set_success(false);
        response.set_error("Invalid protocol version!");

        spdlog::warn("Connection attempt with server identifier {:x}, expected {:x}", aRequest.get_client_protocol(), server::kIdentifier);
        Send(aRequest.ConnectionId, response);
        Kick(aRequest.ConnectionId);
        return;
    }

    // The token carries the join password. It is never logged.
    if (!m_config.Password.empty() && !SecretEquals(m_config.Password, std::string_view(aRequest.get_token().c_str(), aRequest.get_token().size())))
    {
        response.set_success(false);
        response.set_error("Wrong server password");

        spdlog::warn("Refused {} from connection {:x}: wrong server password", aRequest.get_username(), aRequest.ConnectionId);
        Send(aRequest.ConnectionId, response);
        Kick(aRequest.ConnectionId);
        return;
    }

    // A name identifies a player's character in the campaign save, so a second connection may
    // not take a name that is already playing.
    const std::string username(aRequest.get_username().c_str(), aRequest.get_username().size());
    bool nameInUse = username.empty();
    GetWorld()->get_mut<PlayerManager>()->ForEach(
        [&](flecs::entity aPlayer)
        {
            if (const auto* pPlayer = aPlayer.get<PlayerComponent>())
                nameInUse = nameInUse || pPlayer->Username == username;
        });
    if (nameInUse)
    {
        response.set_success(false);
        response.set_error(username.empty() ? "A player name is required" : "This player name is already on the server");

        spdlog::warn("Refused connection {:x}: name \"{}\" is empty or already playing", aRequest.ConnectionId, username);
        Send(aRequest.ConnectionId, response);
        Kick(aRequest.ConnectionId);
        return;
    }

    spdlog::info("Authorize connection from {}", username);
    response.set_success(true);

    server::Settings settings;
    settings.set_update_rate(m_config.UpdateRate);
    response.set_settings(settings);

    server::RpcDefinitions definitions;

    const auto* pRpc = static_cast<RpcScriptInstance*>(IRpc::Get());
    pRpc->Serialize(definitions);

    if (!Send(aRequest.ConnectionId, definitions))
        spdlog::error("Failed to send message to {:x}", aRequest.ConnectionId);

    if (!Send(aRequest.ConnectionId, response))
        spdlog::error("Failed to send message to {:x}", aRequest.ConnectionId);

    // The player was accepted, rpc definitions are ready, we can create the player's handle
    GetWorld()->get_mut<PlayerManager>()->Create(aRequest.ConnectionId, aRequest.get_username());
}

ScratchAllocator& GameServer::GetScratch()
{
    thread_local ScratchAllocator s_allocator{1 << 19};
    return s_allocator;
}
