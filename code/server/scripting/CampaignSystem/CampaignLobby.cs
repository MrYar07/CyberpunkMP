using System.Text;
using Cyberpunk.Rpc.Client.Plugins;
using CyberpunkSdk;
using CyberpunkSdk.Systems;

namespace CampaignSystem
{
    internal enum LobbyPhase
    {
        Lobby,
        Voting,
        Started,
    }

    internal enum LobbyMode
    {
        None = 0,
        NewGame = 1,
        LoadGame = 2,
    }

    internal class LobbyPlayer
    {
        public ulong Id;
        public string Name = "";
        public bool Ready;
        public bool InWorld;
    }

    // Players gather at the main menu before the game starts. The host (first player in)
    // picks a new campaign or one saved on the server and starts when everyone is ready.
    // A new campaign begins with a vote on the lifepath, since the prologue is shared.
    //
    // Once started, players who join later go straight in: guests get their saved character
    // back (or make a new one), and the host's name is remembered so only they can take the
    // story back after leaving - anyone else's game would report a world with no story in it.
    internal class CampaignLobby
    {
        internal static readonly string[] LifePaths = { "LifePaths.Corporate", "LifePaths.Nomad", "LifePaths.StreetKid" };

        private const float VoteSeconds = 15.0f;

        // Character uploads are cut into parts of this size, like quest batches.
        private const int MaxPartLength = 15000;

        private readonly Logger logger = new Logger("Campaign");
        private readonly CampaignStore store = new();
        private readonly List<LobbyPlayer> players = new();
        private readonly Dictionary<ulong, Dictionary<string, StringBuilder>> uploads = new();

        // Players already sent into this campaign's world. Someone coming back resumes it.
        private readonly HashSet<string> begun = new();

        private LobbyPhase phase = LobbyPhase.Lobby;
        private LobbyMode mode = LobbyMode.None;
        private string chosenCampaign = "";
        private CampaignFile? campaign;
        private CampaignVote? vote;

        internal ulong? HostId { get; private set; }

        internal event Action<ulong?>? HostChanged;

        internal CampaignLobby()
        {
            Server.Timer.Add(Tick, 0.25f);
        }

        internal LobbyPlayer? Find(ulong playerId) => players.FirstOrDefault(player => player.Id == playerId);

        internal IEnumerable<ulong> PlayerIds => players.Select(player => player.Id).ToList();

        internal bool Started => phase == LobbyPhase.Started;

        internal void Join(ulong playerId)
        {
            var name = CampaignStore.SafeName(Server.PlayerSystem.GetById(playerId)?.Username ?? $"player{playerId}");

            // Two clients with the same name would share one character; number the newcomer.
            var unique = name;
            for (var i = 2; players.Any(player => player.Name == unique); ++i)
                unique = $"{name}{i}";

            players.Add(new LobbyPlayer { Id = playerId, Name = unique });
            logger.Info($"{unique} joined the lobby ({players.Count} player(s))");

            if (phase != LobbyPhase.Started)
            {
                if (HostId is null)
                    SetHost(playerId);
            }
            else if (campaign is not null && unique == campaign.Host)
            {
                logger.Info($"{unique} is back - they host this campaign");
                SetHost(playerId);
            }

            Broadcast();

            if (phase == LobbyPhase.Voting)
                vote?.OpenFor(playerId);
            else if (phase == LobbyPhase.Started)
                Begin(playerId);
        }

        internal void Leave(ulong playerId)
        {
            var player = Find(playerId);
            if (player is null)
                return;

            players.Remove(player);
            uploads.Remove(playerId);
            vote?.Forget(playerId);
            logger.Info($"{player.Name} left the lobby ({players.Count} player(s))");

            if (players.Count == 0)
            {
                Reset();
                return;
            }

            if (HostId == playerId)
            {
                // Before the start anyone can lead. After it, only the campaign's own host
                // has the story in their save, so it waits for them to come back.
                if (phase == LobbyPhase.Started)
                {
                    logger.Info($"The host left, the story is paused until {player.Name} is back");
                    SetHost(null);
                }
                else
                {
                    SetHost(players[0].Id);
                }
            }

            Broadcast();
        }

        internal void SetReady(ulong playerId, bool ready)
        {
            var player = Find(playerId);
            if (player is null || phase != LobbyPhase.Lobby)
                return;

            player.Ready = ready;
            Broadcast();
        }

        internal void Choose(ulong playerId, int requestedMode, string campaignName)
        {
            if (playerId != HostId || phase != LobbyPhase.Lobby)
                return;

            var newMode = (LobbyMode)requestedMode;
            if (newMode == LobbyMode.LoadGame && !store.List().Contains(campaignName))
            {
                logger.Warn($"Host chose campaign '{campaignName}', which is not on this server");
                return;
            }

            mode = Enum.IsDefined(newMode) ? newMode : LobbyMode.None;
            chosenCampaign = mode == LobbyMode.LoadGame ? campaignName : "";
            Broadcast();
        }

        internal void Start(ulong playerId)
        {
            if (playerId != HostId || phase != LobbyPhase.Lobby)
                return;

            var waiting = players.Where(player => player.Id != HostId && !player.Ready).Select(player => player.Name).ToList();
            if (waiting.Count > 0)
            {
                logger.Info($"Cannot start, waiting for: {string.Join(", ", waiting)}");
                return;
            }

            switch (mode)
            {
                case LobbyMode.NewGame:
                    StartLifePathVote();
                    break;
                case LobbyMode.LoadGame:
                    campaign = store.Load(chosenCampaign);
                    if (campaign is null)
                    {
                        logger.Error($"Campaign '{chosenCampaign}' could not be read");
                        return;
                    }

                    // Whoever loads it hosts it from now on.
                    campaign.Host = Find(playerId)!.Name;
                    store.Save(campaign);
                    BeginAll();
                    break;
                default:
                    logger.Info("Cannot start before the host picks a new or a saved campaign");
                    break;
            }
        }

        internal void CastVote(ulong playerId, uint voteId, int option)
        {
            if (vote is null || vote.Id != voteId)
                return;

            vote.Cast(playerId, option, PlayerIds);
        }

        // ---- characters ----

        // Parts with the same key are joined, so a long value can arrive in pieces.
        internal void ReportCharacterPart(ulong playerId, string key, string value)
        {
            if (Find(playerId) is null || key.Length == 0)
                return;

            if (!uploads.TryGetValue(playerId, out var upload))
                uploads[playerId] = upload = new();

            if (!upload.TryGetValue(key, out var builder))
                upload[key] = builder = new StringBuilder();

            builder.Append(value);
        }

        internal void ReportCharacterDone(ulong playerId)
        {
            var player = Find(playerId);
            if (player is null || !uploads.Remove(playerId, out var upload))
                return;

            if (campaign is null)
            {
                logger.Warn($"{player.Name} sent a character, but no campaign is running");
                return;
            }

            if (!campaign.Players.TryGetValue(player.Name, out var character))
                campaign.Players[player.Name] = character = new();

            foreach (var (key, builder) in upload)
                character[key] = builder.ToString();

            store.Save(campaign);
            logger.Info($"Saved {player.Name}'s character to campaign '{campaign.Name}' ({upload.Count} field(s))");
        }

        internal void RequestCharacter(ulong playerId)
        {
            var player = Find(playerId);
            if (player is null)
                return;

            if (campaign is null || !campaign.Players.TryGetValue(player.Name, out var character))
            {
                CampaignClient.CharacterDone(playerId, false);
                return;
            }

            foreach (var (key, value) in character)
            {
                for (var offset = 0; offset < value.Length; offset += MaxPartLength)
                    CampaignClient.CharacterPart(playerId, key, value.Substring(offset, Math.Min(MaxPartLength, value.Length - offset)));
            }

            CampaignClient.CharacterDone(playerId, true);
        }

        internal void SetInWorld(ulong playerId, bool inWorld)
        {
            var player = Find(playerId);
            if (player is null || player.InWorld == inWorld)
                return;

            player.InWorld = inWorld;

            // Counted as started only once actually in the game, not when told to start.
            if (inWorld && phase == LobbyPhase.Started)
                begun.Add(player.Name);

            Broadcast();
        }

        // ---- internals ----

        private void StartLifePathVote()
        {
            phase = LobbyPhase.Voting;

            // Nobody voted: the host's game would have to pick anyway, so pick for it.
            vote = new CampaignVote("lifepath", LifePaths, VoteSeconds,
                () => Random.Shared.Next(LifePaths.Length),
                winner =>
                {
                    var host = HostId is { } id ? Find(id)?.Name ?? "" : "";
                    campaign = new CampaignFile
                    {
                        Name = CampaignStore.SafeName($"{host}-{DateTime.Now:yyyyMMdd-HHmm}"),
                        Host = host,
                        LifePath = LifePaths[winner],
                        Created = DateTime.UtcNow,
                    };
                    store.Save(campaign);

                    logger.Info($"Lifepath vote: {LifePaths[winner]}, new campaign '{campaign.Name}'");
                    vote = null;
                    BeginAll();
                });

            Broadcast();
            vote.Open(PlayerIds);
        }

        private void BeginAll()
        {
            phase = LobbyPhase.Started;
            Broadcast();

            foreach (var id in PlayerIds)
                Begin(id);
        }

        // Tells one client to leave the menu: the host starts or loads the story, guests make
        // (or get back) their character and start the quest-free guest world.
        private void Begin(ulong playerId)
        {
            var player = Find(playerId);
            if (campaign is null || player is null)
                return;

            // A host coming back loads their save; a new campaign's host starts the prologue.
            // Guests ask for their saved character either way and make one if there is none.
            var startMode = mode == LobbyMode.NewGame && !begun.Contains(player.Name) ? LobbyMode.NewGame : LobbyMode.LoadGame;

            CampaignClient.LobbyBegin(playerId, (int)startMode, campaign.LifePath, playerId == HostId);
        }

        private void Tick(float delta)
        {
            lock (CampaignSession.Sync)
            {
                vote?.Tick(delta, PlayerIds);
            }
        }

        private void SetHost(ulong? playerId)
        {
            if (HostId == playerId)
                return;

            HostId = playerId;
            if (playerId is { } id && Find(id) is { } player)
                player.Ready = true;

            HostChanged?.Invoke(playerId);
        }

        private void Reset()
        {
            logger.Info("Lobby empty, back to waiting for players");
            phase = LobbyPhase.Lobby;
            mode = LobbyMode.None;
            chosenCampaign = "";
            campaign = null;
            vote = null;
            begun.Clear();
            SetHost(null);
        }

        // The whole lobby in one string, sent to everyone on every change (it is small):
        // phase=lobby;mode=1;campaign=name;active=name;lifepath=...;host=name;
        // campaigns=a/b;players=name:ready:inWorld/...;you=name (the receiving player)
        private void Broadcast()
        {
            var host = HostId is { } id ? Find(id)?.Name ?? "" : "";
            var state = new StringBuilder()
                .Append($"phase={phase.ToString().ToLowerInvariant()}")
                .Append($";mode={(int)mode}")
                .Append($";campaign={chosenCampaign}")
                .Append($";active={campaign?.Name ?? ""}")
                .Append($";lifepath={campaign?.LifePath ?? ""}")
                .Append($";host={host}")
                .Append($";campaigns={string.Join("/", store.List().Take(20))}")
                .Append($";players={string.Join("/", players.Select(p => $"{p.Name}:{(p.Ready ? 1 : 0)}:{(p.InWorld ? 1 : 0)}"))}")
                .ToString();

            foreach (var player in players)
                CampaignClient.LobbyState(player.Id, $"{state};you={player.Name}");
        }
    }
}
