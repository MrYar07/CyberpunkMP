using System.Text;
using Cyberpunk.Rpc.Client.Plugins;
using CyberpunkSdk;
using CyberpunkSdk.Systems;

namespace Cyberpunk.Rpc.Server.Plugins
{
    public static partial class CampaignServer
    {
        public static partial void ReportJournal_Impl(ulong playerId, uint hash, int state)
        {
            CampaignSystem.Plugin.Instance.Session.ReportJournal(playerId, hash, state);
        }

        public static partial void ReportJournalBatch_Impl(ulong playerId, string entries)
        {
            CampaignSystem.Plugin.Instance.Session.ReportJournalBatch(playerId, entries);
        }

        public static partial void ReportFact_Impl(ulong playerId, string name, int value)
        {
            CampaignSystem.Plugin.Instance.Session.ReportFact(playerId, name, value);
        }

        public static partial void ReportFactBatch_Impl(ulong playerId, string entries)
        {
            CampaignSystem.Plugin.Instance.Session.ReportFactBatch(playerId, entries);
        }

        public static partial void ReportSnapshotDone_Impl(ulong playerId)
        {
            CampaignSystem.Plugin.Instance.Session.ReportSnapshotDone(playerId);
        }

        public static partial void EnterWorld_Impl(ulong playerId)
        {
            CampaignSystem.Plugin.Instance.Session.EnterWorld(playerId);
        }

        public static partial void LeaveWorld_Impl(ulong playerId)
        {
            CampaignSystem.Plugin.Instance.Session.LeaveWorld(playerId);
        }

        public static partial void LobbySetReady_Impl(ulong playerId, bool ready)
        {
            lock (CampaignSystem.CampaignSession.Sync)
                CampaignSystem.Plugin.Instance.Session.Lobby.SetReady(playerId, ready);
        }

        public static partial void LobbyChoose_Impl(ulong playerId, int mode, string campaign)
        {
            lock (CampaignSystem.CampaignSession.Sync)
                CampaignSystem.Plugin.Instance.Session.Lobby.Choose(playerId, mode, campaign);
        }

        public static partial void LobbyStart_Impl(ulong playerId)
        {
            lock (CampaignSystem.CampaignSession.Sync)
                CampaignSystem.Plugin.Instance.Session.Lobby.Start(playerId);
        }

        public static partial void CastVote_Impl(ulong playerId, uint voteId, int option)
        {
            CampaignSystem.Plugin.Instance.Session.CastVote(playerId, voteId, option);
        }

        public static partial void ReportDialog_Impl(ulong playerId, string options, bool timed)
        {
            CampaignSystem.Plugin.Instance.Session.ReportDialog(playerId, options, timed);
        }

        public static partial void ReportDialogClosed_Impl(ulong playerId)
        {
            CampaignSystem.Plugin.Instance.Session.ReportDialogClosed(playerId);
        }

        public static partial void ReportScene_Impl(ulong playerId, int tier, float x, float y, float z)
        {
            CampaignSystem.Plugin.Instance.Session.ReportScene(playerId, tier, x, y, z);
        }

        public static partial void ReportQuestNodes_Impl(ulong playerId, string entries)
        {
            CampaignSystem.Plugin.Instance.Session.ReportQuestNodes(playerId, entries);
        }

        public static partial void ReportTracked_Impl(ulong playerId, uint hash)
        {
            CampaignSystem.Plugin.Instance.Session.ReportTracked(playerId, hash);
        }

        public static partial void ReportCharacterPart_Impl(ulong playerId, string key, string value)
        {
            lock (CampaignSystem.CampaignSession.Sync)
                CampaignSystem.Plugin.Instance.Session.Lobby.ReportCharacterPart(playerId, key, value);
        }

        public static partial void ReportCharacterDone_Impl(ulong playerId)
        {
            lock (CampaignSystem.CampaignSession.Sync)
                CampaignSystem.Plugin.Instance.Session.Lobby.ReportCharacterDone(playerId);
        }

        public static partial void RequestCharacter_Impl(ulong playerId)
        {
            lock (CampaignSystem.CampaignSession.Sync)
                CampaignSystem.Plugin.Instance.Session.Lobby.RequestCharacter(playerId);
        }
    }
}

namespace CampaignSystem
{
    // One story per server. The host's game runs the quests; this keeps the latest state it
    // reported so every guest - including one that joins late - is brought to the same point.
    //
    // Players connect at the main menu (CampaignLobby), so the story is only synced once a
    // client reports that its world is up (EnterWorld).
    internal class CampaignSession
    {
        private const string FactListFile = "campaign_facts.txt";
        private const string DefaultFactList = "CampaignSystem.campaign_facts.txt";
        private const string TemplateMarker = "# The campaign plugin mirrors quest facts from the host to every guest.";

        // Batches are one "key:value,key:value" string; this keeps each RPC far below the
        // 64 KB network buffer (strings are limited to 65535 bytes).
        private const int MaxBatchLength = 16000;

        // Dialog votes. A timed dialog runs on the host's game clock, so its vote has to end
        // well before the game picks for itself.
        private const float DialogVoteSeconds = 15.0f;
        private const float TimedDialogVoteSeconds = 5.0f;

        // RPC handlers and the lobby timer share this.
        internal static readonly object Sync = new();

        private readonly Logger logger = new Logger("Campaign");
        private readonly object sync = Sync;

        private readonly Dictionary<uint, int> journal = new();
        private readonly Dictionary<string, int> facts = new();

        // The objective the host's game tracks (HUD, map pin, route); 0 = none.
        private uint tracked;
        private readonly List<string> watchedFacts;

        private ulong? hostId;
        private bool hostInWorld;

        internal CampaignLobby Lobby { get; }
        internal CampaignCombat Combat { get; }
        internal CampaignStory Story { get; }

        // Set once the host has sent its whole snapshot. Until then guests are not sent
        // state, because anything missing would be read as "unset" and wipe their facts.
        private bool snapshotReady;

        // The dialog the host's game is showing, while the players vote on it.
        private CampaignVote? dialogVote;
        private string? dialogOptions;

        // The host's scene tier (GameplayTier: 1 = free gameplay ... 5 = cinematic) and where it
        // plays, so guests can be brought over and held while it runs.
        private int sceneTier;
        private float sceneX, sceneY, sceneZ;

        internal CampaignSession()
        {
            watchedFacts = LoadFactList();
            Lobby = new CampaignLobby();
            Lobby.HostChanged += OnHostChanged;
            Combat = new CampaignCombat(sync, () => hostId, () => hostInWorld, Voters);
            Story = new CampaignStory(sync, () => hostId, () => hostInWorld, Voters);

            Server.PlayerSystem.PlayerJoinEvent += OnPlayerJoin;
            Server.PlayerSystem.PlayerLeftEvent += OnPlayerLeft;
            Server.Timer.Add(Tick, 0.25f);

            logger.Info($"Campaign co-op ready, watching {watchedFacts.Count} quest fact(s)");
        }

        private void OnPlayerJoin(ulong playerId)
        {
            lock (sync)
            {
                Lobby.Join(playerId);
            }
        }

        private void OnPlayerLeft(ulong playerId)
        {
            lock (sync)
            {
                Lobby.Leave(playerId);
                dialogVote?.Forget(playerId);
                Combat.WorldChanged();
            }
        }

        private void OnHostChanged(ulong? playerId)
        {
            // Guests keep the story where it stopped; the next host's game becomes the
            // source of truth once it reports its own snapshot.
            if (hostId is not null && playerId is null)
                logger.Info($"Host {hostId} is gone, the story is paused until a host is back");

            hostId = playerId;
            hostInWorld = false;
            snapshotReady = false;
            CancelDialogVote();
            SetScene(0, 0, 0, 0);
            Story.HostGone();

            // The new host may already be in the world (the old host left mid-game).
            if (playerId is { } id && Lobby.Find(id) is { InWorld: true })
                EnterWorldLocked(id);
        }

        internal void EnterWorld(ulong playerId)
        {
            lock (sync)
            {
                Lobby.SetInWorld(playerId, true);
                EnterWorldLocked(playerId);
                Combat.WorldChanged();
            }
        }

        // The client's world went away: loading a save or quitting to the menu.
        internal void LeaveWorld(ulong playerId)
        {
            lock (sync)
            {
                Lobby.SetInWorld(playerId, false);
                dialogVote?.Forget(playerId);
                Combat.WorldChanged();

                if (playerId == hostId && hostInWorld)
                {
                    logger.Info("The host left the world, the story is paused until they are back");
                    hostInWorld = false;
                    snapshotReady = false;
                    CancelDialogVote();
                    SetScene(0, 0, 0, 0);
                    Story.HostGone();
                }
            }
        }

        private void EnterWorldLocked(ulong playerId)
        {
            if (playerId == hostId)
            {
                PromoteToHost(playerId);
                Story.EnterWorld(playerId);
                return;
            }

            // The role first: a guest's game ignores guest-only messages (the host's mode)
            // until it knows it is a guest.
            CampaignClient.SetRole(playerId, false);
            Story.EnterWorld(playerId);

            if (!snapshotReady)
            {
                logger.Info($"Player {playerId} entered the world as a guest, waiting for the host's snapshot");
                return;
            }

            logger.Info($"Player {playerId} entered the world as a guest");
            SendState(playerId);

            if (sceneTier > 0)
                CampaignClient.SceneState(playerId, sceneTier, sceneX, sceneY, sceneZ);

            // A guest walking into a running dialog vote can still have a say.
            if (dialogVote is { Closed: false })
                dialogVote.OpenFor(playerId);
        }

        private void PromoteToHost(ulong playerId)
        {
            hostInWorld = true;
            snapshotReady = false;

            // A new host (or the host after loading a save) is a new source of truth: what
            // was reported before may not match this save, so start clean and let the
            // snapshot refill it.
            journal.Clear();
            facts.Clear();
            tracked = 0;

            logger.Info($"Player {playerId} is now the campaign host");
            CampaignClient.SetRole(playerId, true);
            Combat.HostEntered();

            // The host answers the last batch with ReportSnapshotDone, so send at least one.
            var batches = Batches(watchedFacts).ToList();
            if (batches.Count == 0)
                batches.Add("");

            for (var i = 0; i < batches.Count; ++i)
                CampaignClient.WatchFacts(playerId, batches[i], i == batches.Count - 1);
        }

        // Full state for one guest. Every watched fact is sent, unset ones as 0, so a guest
        // whose save is further along loses the facts the host does not have.
        private void SendState(ulong playerId)
        {
            foreach (var batch in Batches(journal.Select(entry => $"{entry.Key}:{entry.Value}")))
                CampaignClient.ApplyJournalBatch(playerId, batch);

            var known = watchedFacts.Concat(facts.Keys).Distinct();
            foreach (var batch in Batches(known.Select(name => $"{name}:{facts.GetValueOrDefault(name)}")))
                CampaignClient.ApplyFactBatch(playerId, batch);

            // After the journal: the objective has to exist in the guest's journal to be tracked.
            if (tracked != 0)
                CampaignClient.ApplyTracked(playerId, tracked);
        }

        internal void ReportJournal(ulong playerId, uint hash, int state)
        {
            lock (sync)
            {
                if (playerId != hostId)
                    return;

                if (journal.TryGetValue(hash, out var known) && known == state)
                    return;

                journal[hash] = state;

                if (snapshotReady)
                {
                    foreach (var id in Guests())
                        CampaignClient.ApplyJournal(id, hash, state);
                }
            }
        }

        internal void ReportJournalBatch(ulong playerId, string entries)
        {
            lock (sync)
            {
                if (playerId != hostId)
                    return;

                foreach (var (key, state) in ParseBatch(entries))
                {
                    if (uint.TryParse(key, out var hash))
                        journal[hash] = state;
                }
            }
        }

        internal void ReportFact(ulong playerId, string name, int value)
        {
            lock (sync)
            {
                if (playerId != hostId)
                    return;

                if (facts.TryGetValue(name, out var known) && known == value)
                    return;

                facts[name] = value;

                if (snapshotReady)
                {
                    foreach (var id in Guests())
                        CampaignClient.ApplyFact(id, name, value);
                }
            }
        }

        internal void ReportFactBatch(ulong playerId, string entries)
        {
            lock (sync)
            {
                if (playerId != hostId)
                    return;

                foreach (var (name, value) in ParseBatch(entries))
                    facts[name] = value;
            }
        }

        internal void ReportSnapshotDone(ulong playerId)
        {
            lock (sync)
            {
                if (playerId != hostId)
                    return;

                snapshotReady = true;
                var guests = Guests().ToList();
                logger.Info($"Host snapshot: {journal.Count} journal entries, {facts.Count(fact => fact.Value != 0)} facts set, sending to {guests.Count} guest(s)");

                foreach (var id in guests)
                    SendState(id);
            }
        }

        // ---- votes, dialogs and scenes ----

        internal void CastVote(ulong playerId, uint voteId, int option)
        {
            lock (sync)
            {
                if (dialogVote is not null && dialogVote.Id == voteId)
                {
                    if (Lobby.Find(playerId) is { InWorld: true })
                        dialogVote.Cast(playerId, option, Voters());
                    return;
                }

                Lobby.CastVote(playerId, voteId, option);
            }
        }

        // The host's game shows dialog options ("|"-separated, "~" in front of one the host's
        // character cannot pick). Everyone in the world votes; the host's game applies the
        // winner. Alone in the world, the host just plays.
        internal void ReportDialog(ulong playerId, string options, bool timed)
        {
            lock (sync)
            {
                if (playerId != hostId || !hostInWorld)
                    return;

                if (dialogVote is { Closed: false } && dialogOptions == options)
                    return;

                CancelDialogVote();

                var voters = Voters();
                if (voters.Count < 2)
                    return;

                var list = options.Split('|');
                dialogOptions = options;
                dialogVote = new CampaignVote("dialog", list, timed ? TimedDialogVoteSeconds : DialogVoteSeconds,
                    () => -1,
                    winner => logger.Info(winner < 0
                        ? "Dialog vote: no votes, the host picks"
                        : $"Dialog vote: option {winner + 1} of {list.Length}"));
                dialogVote.Open(voters);
            }
        }

        internal void ReportDialogClosed(ulong playerId)
        {
            lock (sync)
            {
                if (playerId == hostId)
                    CancelDialogVote();
            }
        }

        private void CancelDialogVote()
        {
            if (dialogVote is { Closed: false })
                dialogVote.Cancel(Voters());

            dialogVote = null;
            dialogOptions = null;
        }

        internal void ReportScene(ulong playerId, int tier, float x, float y, float z)
        {
            lock (sync)
            {
                if (playerId == hostId && hostInWorld)
                    SetScene(tier, x, y, z);
            }
        }

        internal void ReportTracked(ulong playerId, uint hash)
        {
            lock (sync)
            {
                if (playerId != hostId || tracked == hash)
                    return;

                tracked = hash;
                if (snapshotReady && hash != 0)
                {
                    foreach (var id in Guests())
                        CampaignClient.ApplyTracked(id, hash);
                }
            }
        }

        // Quest nodes the host's game ran that change what players see or hear (scenes, calls,
        // spawns, world changes); guests run the same nodes (QuestMirror in the client). Only
        // guests in the world get them: an old scene must not start for someone joining later.
        internal void ReportQuestNodes(ulong playerId, string entries)
        {
            lock (sync)
            {
                if (playerId != hostId || !hostInWorld || entries.Length == 0)
                    return;

                foreach (var id in Guests())
                    CampaignClient.ReplayQuestNodes(id, entries);
            }
        }

        private void SetScene(int tier, float x, float y, float z)
        {
            var changed = tier != sceneTier;
            sceneTier = tier;
            (sceneX, sceneY, sceneZ) = (x, y, z);

            if (changed)
                logger.Info($"Host scene tier {tier}");

            foreach (var id in Guests())
                CampaignClient.SceneState(id, tier, x, y, z);
        }

        private void Tick(float delta)
        {
            lock (sync)
            {
                if (dialogVote is { Closed: false })
                    dialogVote.Tick(delta, Voters());
            }
        }

        // Everyone whose world is up, host included.
        private List<ulong> Voters()
        {
            return Lobby.PlayerIds.Where(id => Lobby.Find(id) is { InWorld: true }).ToList();
        }

        // Guests whose world is up; the rest get the full state when they enter it.
        private IEnumerable<ulong> Guests()
        {
            return Lobby.PlayerIds.Where(id => id != hostId && Lobby.Find(id) is { InWorld: true }).ToList();
        }

        private static IEnumerable<string> Batches(IEnumerable<string> items)
        {
            var batch = new StringBuilder();
            foreach (var item in items)
            {
                if (batch.Length > 0 && batch.Length + item.Length + 1 > MaxBatchLength)
                {
                    yield return batch.ToString();
                    batch.Clear();
                }

                if (batch.Length > 0)
                    batch.Append(',');
                batch.Append(item);
            }

            if (batch.Length > 0)
                yield return batch.ToString();
        }

        private static IEnumerable<(string Key, int Value)> ParseBatch(string entries)
        {
            foreach (var pair in entries.Split(',', StringSplitOptions.RemoveEmptyEntries))
            {
                var separator = pair.IndexOf(':');
                if (separator > 0 && int.TryParse(pair.AsSpan(separator + 1), out var value))
                    yield return (pair[..separator], value);
            }
        }

        // The default list is built into the plugin (tools/campaign/extract_facts.py) and is
        // updated with it. config/campaign_facts.txt only holds local changes: a name adds a
        // fact, "-name" removes one, '#' starts a comment.
        private List<string> LoadFactList()
        {
            var watched = new HashSet<string>(ReadFactLines(LoadDefaultFactList()));
            var defaults = watched.Count;

            var path = Path.Combine(AppContext.BaseDirectory, "config", FactListFile);
            var lines = File.Exists(path) ? File.ReadAllLines(path) : Array.Empty<string>();
            var changes = ReadFactLines(lines).ToList();

            // Also replaces the stage 1 file, which only held comments.
            if (changes.Count == 0 && !lines.Contains(TemplateMarker))
                WriteOverrideTemplate(path);

            foreach (var line in changes)
            {
                if (line.StartsWith('-'))
                    watched.Remove(line[1..].Trim());
                else
                    watched.Add(line);
            }

            if (changes.Count > 0)
                logger.Info($"{defaults} default facts, {changes.Count} local change(s) from {path}");

            return watched.ToList();
        }

        private string[] LoadDefaultFactList()
        {
            using var stream = typeof(CampaignSession).Assembly.GetManifestResourceStream(DefaultFactList);
            if (stream is null)
            {
                logger.Error($"{DefaultFactList} is missing from the plugin, no facts are mirrored by default");
                return Array.Empty<string>();
            }

            using var reader = new StreamReader(stream);
            return reader.ReadToEnd().Split('\n');
        }

        private static IEnumerable<string> ReadFactLines(IEnumerable<string> lines)
        {
            return lines
                .Select(line => line.Trim())
                .Where(line => line.Length > 0 && !line.StartsWith('#'));
        }

        private void WriteOverrideTemplate(string path)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllLines(path, new[]
            {
                TemplateMarker,
                "# That list is built into the plugin. Changes go here, one per line:",
                "#   some_fact_name     also mirror this fact",
                "#   -some_fact_name    stop mirroring this fact",
                "# Lines starting with # are ignored.",
            });
            logger.Info($"Created {path}");
        }
    }
}
