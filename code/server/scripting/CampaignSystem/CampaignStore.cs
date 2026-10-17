using System.Text.Json;
using System.Text.RegularExpressions;

namespace CampaignSystem
{
    // A campaign save: the host's own game save holds the world and the story, this file holds
    // everything else - the lifepath the players voted for, who hosts, and every player's
    // character (appearance, level, attributes, money, items) keyed by player name.
    internal class CampaignFile
    {
        public string Name { get; set; } = "";
        public string Host { get; set; } = "";
        public string LifePath { get; set; } = "";
        public DateTime Created { get; set; }
        public DateTime Updated { get; set; }

        // Player name -> character data. The keys inside are the client's ("appearance",
        // "level", "items", ...); the server stores them without interpreting them.
        public Dictionary<string, Dictionary<string, string>> Players { get; set; } = new();
    }

    internal class CampaignStore
    {
        private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };
        private static readonly Regex InvalidName = new("[^A-Za-z0-9_-]");

        private readonly string directory = Path.Combine(AppContext.BaseDirectory, "campaigns");

        internal IReadOnlyList<string> List()
        {
            if (!Directory.Exists(directory))
                return Array.Empty<string>();

            return Directory.GetFiles(directory, "*.json")
                .OrderByDescending(File.GetLastWriteTimeUtc)
                .Select(path => Path.GetFileNameWithoutExtension(path))
                .ToList();
        }

        internal CampaignFile? Load(string name)
        {
            var path = PathOf(name);
            if (!File.Exists(path))
                return null;

            return JsonSerializer.Deserialize<CampaignFile>(File.ReadAllText(path));
        }

        internal void Save(CampaignFile campaign)
        {
            Directory.CreateDirectory(directory);
            campaign.Updated = DateTime.UtcNow;

            // Write next to the file and swap, so a crash mid-write never loses a campaign.
            var path = PathOf(campaign.Name);
            var temp = path + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(campaign, Options));
            File.Move(temp, path, true);
        }

        internal static string SafeName(string name)
        {
            var safe = InvalidName.Replace(name, "_");
            return safe.Length > 0 ? safe : "campaign";
        }

        private string PathOf(string name)
        {
            return Path.Combine(directory, SafeName(name) + ".json");
        }
    }
}
