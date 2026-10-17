using Cyberpunk.Rpc.Client.Plugins;

namespace CampaignSystem
{
    // One vote among the connected players: every player has one vote and can change it until
    // the time runs out. Most votes wins; a tie is drawn at random among the tied options.
    // With no votes at all, the fallback decides (the host's own choice, or a random option).
    internal class CampaignVote
    {
        private static uint nextId = 1;

        private readonly Dictionary<ulong, int> votes = new();
        private readonly Func<int> fallback;
        private readonly Action<int> onClosed;
        private float remaining;

        internal uint Id { get; }
        internal string Kind { get; }
        internal IReadOnlyList<string> Options { get; }
        internal bool Closed { get; private set; }

        internal CampaignVote(string kind, IReadOnlyList<string> options, float seconds, Func<int> fallback, Action<int> onClosed)
        {
            Id = nextId++;
            Kind = kind;
            Options = options;
            remaining = seconds;
            this.fallback = fallback;
            this.onClosed = onClosed;
        }

        internal void Open(IEnumerable<ulong> players)
        {
            var options = string.Join("|", Options);
            foreach (var id in players)
                CampaignClient.VoteOpened(id, Id, Kind, options, (int)MathF.Ceiling(remaining));
        }

        // Late joiners see the vote too, with the time that is left.
        internal void OpenFor(ulong playerId)
        {
            CampaignClient.VoteOpened(playerId, Id, Kind, string.Join("|", Options), (int)MathF.Ceiling(remaining));
            CampaignClient.VoteTally(playerId, Id, Tally());
        }

        internal bool Cast(ulong playerId, int option, IEnumerable<ulong> players)
        {
            if (Closed || option < 0 || option >= Options.Count)
                return false;

            votes[playerId] = option;

            var tally = Tally();
            foreach (var id in players)
                CampaignClient.VoteTally(id, Id, tally);

            return true;
        }

        internal void Forget(ulong playerId)
        {
            votes.Remove(playerId);
        }

        // Everyone has voted: no reason to wait for the clock.
        internal bool Everyone(IEnumerable<ulong> players)
        {
            return players.All(votes.ContainsKey);
        }

        internal void Tick(float delta, IEnumerable<ulong> players)
        {
            if (Closed)
                return;

            remaining -= delta;
            if (remaining <= 0 || Everyone(players))
                Close(players);
        }

        internal void Close(IEnumerable<ulong> players)
        {
            if (Closed)
                return;

            Closed = true;
            var winner = Winner();

            foreach (var id in players)
                CampaignClient.VoteClosed(id, Id, winner);

            onClosed(winner);
        }

        private int Winner()
        {
            if (votes.Count == 0)
                return Math.Clamp(fallback(), 0, Options.Count - 1);

            var counts = Counts();
            var best = counts.Max();
            var tied = Enumerable.Range(0, counts.Length).Where(i => counts[i] == best).ToList();

            return tied[Random.Shared.Next(tied.Count)];
        }

        private int[] Counts()
        {
            var counts = new int[Options.Count];
            foreach (var option in votes.Values)
                counts[option]++;
            return counts;
        }

        // "2,0,1": votes per option, in option order.
        private string Tally()
        {
            return string.Join(",", Counts());
        }
    }
}
