using Cyberpunk.Rpc.Client.Plugins;
using CyberpunkSdk;
using CyberpunkSdk.Systems;

namespace Cyberpunk.Rpc.Server.Plugins
{
    public static partial class CampaignServer
    {
        public static partial void ReportHostMode_Impl(ulong playerId, int mode)
        {
            CampaignSystem.Plugin.Instance.Session.Story.ReportHostMode(playerId, mode);
        }

        public static partial void ReportTeleport_Impl(ulong playerId, float fromX, float fromY, float fromZ, float toX, float toY, float toZ)
        {
            CampaignSystem.Plugin.Instance.Session.Story.ReportTeleport(playerId, fromX, fromY, fromZ, toX, toY, toZ);
        }

        public static partial void SaveScenePoses_Impl(ulong playerId, string scene, string poses)
        {
            CampaignSystem.Plugin.Instance.Session.Story.SaveScenePoses(playerId, scene, poses);
        }
    }
}

namespace CampaignSystem
{
    // Stage 6: playing the campaign through.
    //
    // - Host mode: what the host's V is doing that the guests cannot share (a braindance) or
    //   should know about (playing as Johnny). Guests are held during a braindance.
    // - Regroup: the host's V jumped far (fast travel, metro, a quest teleport); guests who
    //   were with the host are brought along.
    // - Scene poses: hand-placed spots for the other players' characters in a given scene,
    //   relative to the local V ("right:forward:up:yaw" per extra, "|" between extras), keyed
    //   by the scene key every game shares (QuestMirror). Defaults ship in the plugin
    //   (campaign_scenes.txt); poses saved in game with "/coop save" go to
    //   config/campaign_scenes.txt and win over the defaults.
    internal class CampaignStory
    {
        private const string ScenesFile = "campaign_scenes.txt";
        private const string DefaultScenes = "CampaignSystem.campaign_scenes.txt";

        private readonly Logger logger = new Logger("Campaign");
        private readonly object sync;
        private readonly Func<ulong?> host;
        private readonly Func<bool> hostInWorld;
        private readonly Func<List<ulong>> inWorld;

        private readonly Dictionary<string, string> poses = new();
        private readonly Dictionary<string, string> localPoses = new();
        private int hostMode;

        internal CampaignStory(object sync, Func<ulong?> host, Func<bool> hostInWorld, Func<List<ulong>> inWorld)
        {
            this.sync = sync;
            this.host = host;
            this.hostInWorld = hostInWorld;
            this.inWorld = inWorld;

            foreach (var (scene, value) in ReadScenes(LoadDefaultScenes()))
                poses[scene] = value;
            foreach (var (scene, value) in ReadScenes(File.Exists(LocalPath) ? File.ReadAllLines(LocalPath) : Array.Empty<string>()))
            {
                localPoses[scene] = value;
                poses[scene] = value;
            }

            if (poses.Count > 0)
                logger.Info($"{poses.Count} scene(s) with hand-placed poses, {localPoses.Count} from {LocalPath}");
        }

        private static string LocalPath => Path.Combine(AppContext.BaseDirectory, "config", ScenesFile);

        // A player's world came up (lock held): the poses, and the host's mode for a guest.
        internal void EnterWorld(ulong playerId)
        {
            foreach (var (scene, value) in poses)
                CampaignClient.ScenePoses(playerId, scene, value);

            if (playerId != host() && hostMode != 0)
                CampaignClient.HostMode(playerId, hostMode);
        }

        // The host left the world or changed (lock held): whatever it was doing is over.
        internal void HostGone()
        {
            SetHostMode(0);
        }

        internal void ReportHostMode(ulong playerId, int mode)
        {
            lock (sync)
            {
                if (playerId == host() && hostInWorld())
                    SetHostMode(mode);
            }
        }

        private void SetHostMode(int mode)
        {
            if (mode == hostMode)
                return;

            hostMode = mode;
            logger.Info($"Host mode {mode}");
            foreach (var id in inWorld().Where(id => id != host()))
                CampaignClient.HostMode(id, mode);
        }

        internal void ReportTeleport(ulong playerId, float fromX, float fromY, float fromZ, float toX, float toY, float toZ)
        {
            lock (sync)
            {
                if (playerId != host() || !hostInWorld())
                    return;

                foreach (var id in inWorld().Where(id => id != playerId))
                    CampaignClient.HostTeleported(id, fromX, fromY, fromZ, toX, toY, toZ);
            }
        }

        // Any player may place poses while testing; an empty list removes the scene's poses.
        internal void SaveScenePoses(ulong playerId, string scene, string value)
        {
            lock (sync)
            {
                if (scene.Length == 0 || scene.Contains('=') || value.Contains('\n'))
                    return;

                if (value.Length == 0)
                {
                    poses.Remove(scene);
                    localPoses.Remove(scene);
                }
                else
                {
                    poses[scene] = value;
                    localPoses[scene] = value;
                }

                logger.Info($"Player {playerId} saved poses for scene {scene}: {(value.Length == 0 ? "removed" : value)}");
                WriteLocal();

                foreach (var id in inWorld())
                    CampaignClient.ScenePoses(id, scene, value);
            }
        }

        private void WriteLocal()
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(LocalPath)!);
                var lines = new List<string>
                {
                    "# Campaign co-op: hand-placed poses of the other players' characters per scene.",
                    "# <scene key>=<right>:<forward>:<up>:<yaw>|... (meters and degrees, relative to the local V).",
                    "# Written by \"/coop save\" in game; copy lines to code/server/scripting/CampaignSystem/campaign_scenes.txt to ship them.",
                };
                lines.AddRange(localPoses.Select(entry => $"{entry.Key}={entry.Value}"));
                File.WriteAllLines(LocalPath, lines);
            }
            catch (Exception e)
            {
                logger.Error($"Could not write {LocalPath}: {e.Message}");
            }
        }

        private string[] LoadDefaultScenes()
        {
            using var stream = typeof(CampaignStory).Assembly.GetManifestResourceStream(DefaultScenes);
            if (stream is null)
                return Array.Empty<string>();

            using var reader = new StreamReader(stream);
            return reader.ReadToEnd().Split('\n');
        }

        private static IEnumerable<(string Scene, string Poses)> ReadScenes(IEnumerable<string> lines)
        {
            foreach (var raw in lines)
            {
                var line = raw.Trim();
                if (line.Length == 0 || line.StartsWith('#'))
                    continue;

                var split = line.IndexOf('=');
                if (split > 0 && split < line.Length - 1)
                    yield return (line[..split], line[(split + 1)..]);
            }
        }
    }
}
