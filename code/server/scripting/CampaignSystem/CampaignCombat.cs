using Cyberpunk.Rpc.Client.Plugins;
using CyberpunkSdk;
using CyberpunkSdk.Systems;

namespace Cyberpunk.Rpc.Server.Plugins
{
    public static partial class CampaignServer
    {
        public static partial void ReportNpcs_Impl(ulong playerId, string entries)
        {
            CampaignSystem.Plugin.Instance.Session.Combat.ReportNpcs(playerId, entries);
        }

        public static partial void ReportNpcHits_Impl(ulong playerId, string entries)
        {
            CampaignSystem.Plugin.Instance.Session.Combat.ReportNpcHits(playerId, entries);
        }

        public static partial void ReportDowned_Impl(ulong playerId, bool downed)
        {
            CampaignSystem.Plugin.Instance.Session.Combat.ReportDowned(playerId, downed);
        }

        public static partial void ReportRevive_Impl(ulong playerId, ulong puppetId)
        {
            CampaignSystem.Plugin.Instance.Session.Combat.ReportRevive(playerId, puppetId);
        }

        public static partial void ReportBledOut_Impl(ulong playerId)
        {
            CampaignSystem.Plugin.Instance.Session.Combat.ReportBledOut(playerId);
        }
    }
}

namespace CampaignSystem
{
    // Stage 5: NPCs and combat.
    //
    // Every game runs its own copy of each enemy (the quest nodes that spawn them are mirrored)
    // with its own AI, so each player is fought by their own copy and damage to a player stays
    // in that player's game. What has to agree is how hurt each enemy is and whether it is
    // dead: the host's game is the authority and reports its NPCs; guests report their hits,
    // which the host's game applies.
    //
    // Players are not killed while someone else can help: at zero health they are downed, a
    // teammate standing next to them revives them. Nobody comes within the bleed-out time
    // (client side, 45 s): the host's V dies for real, a guest is brought back next to the
    // host (its own death would load its own save). When everyone in the world is down, the
    // host's V dies for real (the game's own death screen and reload) and the guests get up
    // once the host is back in the world.
    internal class CampaignCombat
    {
        // Health (percent) a revived player gets back.
        private const float ReviveHealth = 35.0f;

        private readonly Logger logger = new Logger("Campaign");
        private readonly object sync;
        private readonly Func<ulong?> host;
        private readonly Func<bool> hostInWorld;
        private readonly Func<List<ulong>> inWorld;

        private readonly HashSet<ulong> downed = new();
        private int lastCount = -1;
        private bool wiped;

        internal CampaignCombat(object sync, Func<ulong?> host, Func<bool> hostInWorld, Func<List<ulong>> inWorld)
        {
            this.sync = sync;
            this.host = host;
            this.hostInWorld = hostInWorld;
            this.inWorld = inWorld;
        }

        // ---- NPCs ----

        internal void ReportNpcs(ulong playerId, string entries)
        {
            lock (sync)
            {
                if (playerId != host() || !hostInWorld() || entries.Length == 0)
                    return;

                foreach (var id in inWorld().Where(id => id != playerId))
                    CampaignClient.ApplyNpcs(id, entries);
            }
        }

        internal void ReportNpcHits(ulong playerId, string entries)
        {
            lock (sync)
            {
                if (host() is not { } hostId || playerId == hostId || !hostInWorld() || entries.Length == 0)
                    return;

                if (!inWorld().Contains(playerId))
                    return;

                CampaignClient.ApplyNpcHits(hostId, entries);
            }
        }

        // ---- players: downed, revived, wiped ----

        // Called by the session whenever someone enters or leaves the world (lock held).
        internal void WorldChanged()
        {
            var players = inWorld();

            // Downed players who left the world are not down any more.
            foreach (var id in downed.Where(id => !players.Contains(id)).ToList())
                SetDowned(id, false, players);

            if (players.Count != lastCount)
            {
                lastCount = players.Count;
                foreach (var id in players)
                    CampaignClient.CoopPlayers(id, players.Count);
            }

            // Nobody left to help: whoever is down gets up.
            if (players.Count < 2)
                ReviveAll(players, 100.0f);
        }

        // The host entered the world, after a wipe too: everyone still down gets up.
        internal void HostEntered()
        {
            var players = inWorld();
            if (wiped)
                logger.Info("The host is back after a wipe, downed players get up");

            wiped = false;
            ReviveAll(players, 100.0f);

            // A loaded host save starts with full health, the count is resent so its V is
            // protected again.
            lastCount = -1;
            WorldChanged();
        }

        internal void PlayerLeft(ulong playerId)
        {
            downed.Remove(playerId);
        }

        internal void ReportDowned(ulong playerId, bool isDowned)
        {
            lock (sync)
            {
                var players = inWorld();
                if (!players.Contains(playerId))
                    return;

                SetDowned(playerId, isDowned, players);

                if (!isDowned || wiped || players.Count < 2 || !players.All(downed.Contains))
                    return;

                // Everyone is down. The host's game runs the story, so its V dies and the game
                // reloads; the guests wait on the floor until the host is back.
                wiped = true;
                logger.Info("Everyone is down - the host's V dies, guests get up when the host is back");
                if (host() is { } hostId && players.Contains(hostId))
                {
                    downed.Remove(hostId);
                    CampaignClient.CoopWipe(hostId, 1);
                }
            }
        }

        internal void ReportRevive(ulong playerId, ulong puppetId)
        {
            lock (sync)
            {
                var players = inWorld();
                if (!players.Contains(playerId) || downed.Contains(playerId))
                    return;

                var target = downed.FirstOrDefault(id => Server.PlayerSystem.GetById(id)?.PuppetId == puppetId);
                if (target == 0 || target == playerId)
                    return;

                logger.Info($"Player {playerId} revived player {target}");
                CampaignClient.Revived(target, ReviveHealth);
                SetDowned(target, false, players);
            }
        }

        internal void ReportBledOut(ulong playerId)
        {
            lock (sync)
            {
                var players = inWorld();
                if (!downed.Contains(playerId))
                    return;

                SetDowned(playerId, false, players);
                if (host() is not { } hostId || playerId == hostId)
                {
                    // The host's game kills its V itself; guests get up when it is back.
                    logger.Info($"Player {playerId} bled out");
                    return;
                }

                logger.Info($"Player {playerId} bled out, back next to the host");
                if (hostInWorld() && Server.PlayerSystem.GetById(hostId) is { } hostPlayer)
                {
                    var position = hostPlayer.MovementComponent.Position;
                    CampaignClient.Respawn(playerId, position.X, position.Y, position.Z);
                }
                else
                {
                    CampaignClient.Revived(playerId, ReviveHealth);
                }
            }
        }

        private void ReviveAll(List<ulong> players, float health)
        {
            foreach (var id in downed.ToList())
            {
                if (players.Contains(id))
                    CampaignClient.Revived(id, health);
                SetDowned(id, false, players);
            }
        }

        private void SetDowned(ulong playerId, bool isDowned, List<ulong> players)
        {
            if (isDowned ? !downed.Add(playerId) : !downed.Remove(playerId))
                return;

            if (isDowned)
                logger.Info($"Player {playerId} is down");

            // Everyone else sees the downed character and can walk up to it.
            var puppetId = Server.PlayerSystem.GetById(playerId)?.PuppetId ?? 0;
            if (puppetId == 0)
                return;

            foreach (var id in players.Where(id => id != playerId))
                CampaignClient.PlayerDowned(id, puppetId, isDowned);
        }
    }
}
