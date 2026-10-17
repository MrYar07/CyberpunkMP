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

        public static partial void ReportFact_Impl(ulong playerId, string name, int value)
        {
            CampaignSystem.Plugin.Instance.Session.ReportFact(playerId, name, value);
        }
    }
}

namespace CampaignSystem
{
    // One story per server. The host's game runs the quests; this keeps the latest state it
    // reported so every guest - including one that joins late - is brought to the same point.
    internal class CampaignSession
    {
        private const string FactListFile = "campaign_facts.txt";

        private readonly Logger logger = new Logger("Campaign");
        private readonly object sync = new();

        private readonly Dictionary<uint, int> journal = new();
        private readonly Dictionary<string, int> facts = new();
        private readonly List<string> watchedFacts;

        private ulong? hostId;

        internal CampaignSession()
        {
            watchedFacts = LoadFactList();

            Server.PlayerSystem.PlayerJoinEvent += OnPlayerJoin;
            Server.PlayerSystem.PlayerLeftEvent += OnPlayerLeft;

            logger.Info($"Campaign co-op ready, watching {watchedFacts.Count} quest fact(s)");
        }

        private void OnPlayerJoin(ulong playerId)
        {
            lock (sync)
            {
                if (hostId is null)
                {
                    PromoteToHost(playerId);
                    return;
                }

                logger.Info($"Player {playerId} joined as a guest, sending {journal.Count} journal entries and {facts.Count} facts");
                CampaignClient.SetRole(playerId, false);

                foreach (var (hash, state) in journal)
                    CampaignClient.ApplyJournal(playerId, hash, state);

                foreach (var (name, value) in facts)
                    CampaignClient.ApplyFact(playerId, name, value);
            }
        }

        private void OnPlayerLeft(ulong playerId)
        {
            lock (sync)
            {
                if (hostId != playerId)
                    return;

                // Guests keep the story where it stopped; the next host's game becomes the
                // source of truth once it reports its own snapshot.
                logger.Info($"Host {playerId} left, the story is paused until a new host joins");
                hostId = null;
            }
        }

        private void PromoteToHost(ulong playerId)
        {
            hostId = playerId;

            // A new host means a new source of truth: what the previous host reported may
            // not match this save, so start clean and let the snapshot refill it.
            journal.Clear();
            facts.Clear();

            logger.Info($"Player {playerId} is now the campaign host");
            CampaignClient.SetRole(playerId, true);

            foreach (var name in watchedFacts)
                CampaignClient.WatchFact(playerId, name);
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

                foreach (var id in Guests())
                    CampaignClient.ApplyJournal(id, hash, state);
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

                foreach (var id in Guests())
                    CampaignClient.ApplyFact(id, name, value);
            }
        }

        private IEnumerable<ulong> Guests()
        {
            return Server.PlayerSystem.PlayerIds.Where(id => id != hostId).ToList();
        }

        // One fact name per line, '#' starts a comment. Created empty on first start.
        private List<string> LoadFactList()
        {
            var path = Path.Combine(AppContext.BaseDirectory, "config", FactListFile);

            if (!File.Exists(path))
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                File.WriteAllLines(path, new[]
                {
                    "# Quest facts mirrored from the campaign host to every guest.",
                    "# One fact name per line. Lines starting with # are ignored.",
                });
                logger.Info($"Created {path}");
                return new List<string>();
            }

            return File.ReadAllLines(path)
                .Select(line => line.Trim())
                .Where(line => line.Length > 0 && !line.StartsWith('#'))
                .Distinct()
                .ToList();
        }
    }
}
