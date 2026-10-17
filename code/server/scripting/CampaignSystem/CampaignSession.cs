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
    }
}

namespace CampaignSystem
{
    // One story per server. The host's game runs the quests; this keeps the latest state it
    // reported so every guest - including one that joins late - is brought to the same point.
    internal class CampaignSession
    {
        private const string FactListFile = "campaign_facts.txt";
        private const string DefaultFactList = "CampaignSystem.campaign_facts.txt";
        private const string TemplateMarker = "# The campaign plugin mirrors quest facts from the host to every guest.";

        // Batches are one "key:value,key:value" string; this keeps each RPC far below the
        // 64 KB network buffer (strings are limited to 65535 bytes).
        private const int MaxBatchLength = 16000;

        private readonly Logger logger = new Logger("Campaign");
        private readonly object sync = new();

        private readonly Dictionary<uint, int> journal = new();
        private readonly Dictionary<string, int> facts = new();
        private readonly List<string> watchedFacts;

        private ulong? hostId;

        // Set once the host has sent its whole snapshot. Until then guests are not sent
        // state, because anything missing would be read as "unset" and wipe their facts.
        private bool snapshotReady;

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

                CampaignClient.SetRole(playerId, false);

                if (!snapshotReady)
                {
                    logger.Info($"Player {playerId} joined as a guest, waiting for the host's snapshot");
                    return;
                }

                logger.Info($"Player {playerId} joined as a guest");
                SendState(playerId);
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
                snapshotReady = false;
            }
        }

        private void PromoteToHost(ulong playerId)
        {
            hostId = playerId;
            snapshotReady = false;

            // A new host means a new source of truth: what the previous host reported may
            // not match this save, so start clean and let the snapshot refill it.
            journal.Clear();
            facts.Clear();

            logger.Info($"Player {playerId} is now the campaign host");
            CampaignClient.SetRole(playerId, true);

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

        private IEnumerable<ulong> Guests()
        {
            return Server.PlayerSystem.PlayerIds.Where(id => id != hostId).ToList();
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
