module CyberpunkMP.Plugins

import CyberpunkMP.*
import CyberpunkMP.World.*

// Campaign co-op: the host's game runs the story, every other player mirrors it.
//
// The server decides who the host is (first player in) and tells each client with SetRole.
// The host reports journal entry states and watched quest facts; the server stores them and
// forwards them to the guests, so a late joiner receives the whole snapshot on arrival.
//
// Snapshots hold thousands of entries, so they travel in batches: one String of
// "key:value" pairs separated by commas, kept under CampaignBatch.MaxLength. A String
// keeps the RPC signature simple and well below the 64 KB network buffer.

public native class CampaignServer extends ServerRpc {
    public static native func ReportJournal(hash: Uint32, state: Int32) -> Void;
    public static native func ReportJournalBatch(entries: String) -> Void;
    public static native func ReportFact(name: String, value: Int32) -> Void;
    public static native func ReportFactBatch(entries: String) -> Void;
    public static native func ReportSnapshotDone() -> Void;
    public static native func EnterWorld() -> Void;
    public static native func LeaveWorld() -> Void;
    public static native func LobbySetReady(ready: Bool) -> Void;
    public static native func LobbyChoose(mode: Int32, campaign: String) -> Void;
    public static native func LobbyStart() -> Void;
    public static native func CastVote(voteId: Uint32, option: Int32) -> Void;
    public static native func ReportCharacterPart(key: String, value: String) -> Void;
    public static native func ReportCharacterDone() -> Void;
    public static native func RequestCharacter() -> Void;
}

// ClientRpc functions are invoked without an instance, so they only route to CampaignSync.
public class CampaignClient extends ClientRpc {
    public func SetRole(isHost: Bool) -> Void {
        CampaignSync.Get().SetRole(isHost);
    }

    public func ApplyJournal(hash: Uint32, state: Int32) -> Void {
        CampaignSync.Get().ApplyJournal(hash, state);
    }

    public func ApplyJournalBatch(entries: String) -> Void {
        CampaignSync.Get().ApplyJournalBatch(entries);
    }

    public func ApplyFact(name: String, value: Int32) -> Void {
        CampaignSync.Get().ApplyFact(name, value);
    }

    public func ApplyFactBatch(entries: String) -> Void {
        CampaignSync.Get().ApplyFactBatch(entries);
    }

    // The server sends the watch list in batches; the last one closes the host's snapshot.
    public func WatchFacts(names: String, last: Bool) -> Void {
        CampaignSync.Get().WatchFacts(names, last);
    }

    // The lobby lives at the main menu, where there are no ScriptableSystems: these go to
    // the CampaignLobby service instead.
    public func LobbyState(state: String) -> Void {
        CampaignLobby.Get().OnState(state);
    }

    public func LobbyBegin(mode: Int32, lifePath: String, isHost: Bool) -> Void {
        CampaignLobby.Get().OnBegin(mode, lifePath, isHost);
    }

    public func VoteOpened(voteId: Uint32, kind: String, options: String, seconds: Int32) -> Void {
        CampaignLobby.Get().OnVoteOpened(voteId, kind, options, seconds);
    }

    public func VoteTally(voteId: Uint32, counts: String) -> Void {
        CampaignLobby.Get().OnVoteTally(voteId, counts);
    }

    public func VoteClosed(voteId: Uint32, winner: Int32) -> Void {
        CampaignLobby.Get().OnVoteClosed(voteId, winner);
    }

    public func CharacterPart(key: String, value: String) -> Void {
        CampaignLobby.Get().OnCharacterPart(key, value);
    }

    public func CharacterDone(found: Bool) -> Void {
        CampaignLobby.Get().OnCharacterDone(found);
    }
}

// Collects "key:value" pairs and hands each full batch to the subclass.
public class CampaignBatch {
    public static func MaxLength() -> Int32 = 16000

    private let m_buffer: String;
    private let m_count: Int32;

    public func Add(key: String, value: Int32) -> Void {
        let pair = s"\(key):\(value)";
        if StrLen(this.m_buffer) + StrLen(pair) + 1 > CampaignBatch.MaxLength() {
            this.Flush();
        }
        if StrLen(this.m_buffer) > 0 {
            this.m_buffer += ",";
        }
        this.m_buffer += pair;
        this.m_count += 1;
    }

    public func Flush() -> Void {
        if StrLen(this.m_buffer) == 0 {
            return;
        }
        this.Send(this.m_buffer);
        this.m_buffer = "";
    }

    public func Count() -> Int32 {
        return this.m_count;
    }

    protected func Send(entries: String) -> Void {}

    // Splits a batch back into pairs; malformed pairs are skipped.
    public static func Parse(entries: String, out keys: array<String>, out values: array<Int32>) -> Void {
        for pair in StrSplit(entries, ",") {
            let key: String;
            let value: String;
            if StrSplitFirst(pair, ":", key, value) && StrLen(key) > 0 {
                ArrayPush(keys, key);
                ArrayPush(values, StringToInt(value));
            }
        }
    }
}

public class CampaignJournalBatch extends CampaignBatch {
    protected func Send(entries: String) -> Void {
        CampaignServer.ReportJournalBatch(entries);
    }
}

public class CampaignFactBatch extends CampaignBatch {
    protected func Send(entries: String) -> Void {
        CampaignServer.ReportFactBatch(entries);
    }
}

// One per watched fact - QuestsSystem listeners receive the value but not the fact name.
public class CampaignFactWatcher extends IScriptable {
    public let m_name: String;
    public let m_listenerId: Uint32;

    public func OnFactChanged(value: Int32) -> Void {
        CampaignSync.Get().OnHostFactChanged(this.m_name, value);
    }
}

public class CampaignSync extends ScriptableSystem {
    private let m_inWorld: Bool;
    private let m_isHost: Bool;
    private let m_hasRole: Bool;
    private let m_journalListening: Bool;
    private let m_watchers: array<ref<CampaignFactWatcher>>;
    private let m_factSnapshot: ref<CampaignFactBatch>;

    public static func Get() -> ref<CampaignSync> {
        let container = GameInstance.GetScriptableSystemsContainer(GetGameInstance());
        return container.Get(n"CyberpunkMP.Plugins.CampaignSync") as CampaignSync;
    }

    private func OnDetach() -> Void {
        this.StopJournalListening();
        this.ClearWatchers();
        this.m_hasRole = false;

        if this.m_inWorld {
            this.m_inWorld = false;
            CampaignLobby.Get().OnWorldGone();
        }
    }

    // The story is only synced once the world is up; the server waits for this.
    private func OnPlayerAttach(request: ref<PlayerAttachRequest>) -> Void {
        this.m_inWorld = true;
        CampaignLobby.Get().OnWorldReady(this.GetGameInstance());
    }

    public func IsInWorld() -> Bool {
        return this.m_inWorld;
    }

    public func IsHost() -> Bool {
        return this.m_hasRole && this.m_isHost;
    }

    public func SetRole(isHost: Bool) -> Void {
        this.m_hasRole = true;
        this.m_isHost = isHost;
        this.ClearWatchers();
        this.m_factSnapshot = null;

        if isHost {
            LogChannel(n"DEBUG", "[Campaign] this game is the HOST - the story runs here");
            this.StartJournalListening();
            this.ReportJournalSnapshot();
        } else {
            LogChannel(n"DEBUG", "[Campaign] this game is a GUEST - mirroring the host");
            this.StopJournalListening();
        }
    }

    // ---- host side ----

    private func StartJournalListening() -> Void {
        if this.m_journalListening {
            return;
        }
        GameInstance.GetJournalManager(this.GetGameInstance()).RegisterScriptCallback(this, n"OnJournalEntryStateChanged", gameJournalListenerType.State);
        this.m_journalListening = true;
    }

    private func StopJournalListening() -> Void {
        if !this.m_journalListening {
            return;
        }
        GameInstance.GetJournalManager(this.GetGameInstance()).UnregisterScriptCallback(this, n"OnJournalEntryStateChanged");
        this.m_journalListening = false;
    }

    protected cb func OnJournalEntryStateChanged(entryHash: Uint32, className: CName, notifyOption: JournalNotifyOption, changeType: JournalChangeType) -> Bool {
        if !this.IsHost() {
            return false;
        }
        let journal = GameInstance.GetJournalManager(this.GetGameInstance());
        let entry = journal.GetEntry(entryHash);
        if !IsDefined(entry) {
            return false;
        }
        CampaignServer.ReportJournal(entryHash, EnumInt(journal.GetEntryState(entry)));
        return false;
    }

    // Everything the host's journal knows, so guests (and the server) start from the truth
    // rather than from whatever changes happen after the host connected.
    private func ReportJournalSnapshot() -> Void {
        let journal = GameInstance.GetJournalManager(this.GetGameInstance());
        let filter: JournalRequestStateFilter;
        filter.inactive = false;
        filter.active = true;
        filter.succeeded = true;
        filter.failed = true;
        let context: JournalRequestContext;
        context.stateFilter = filter;

        let quests: array<wref<JournalEntry>>;
        journal.GetQuests(context, quests);

        let batch = new CampaignJournalBatch();
        for quest in quests {
            this.ReportEntryTree(journal, quest, filter, batch);
        }
        batch.Flush();
        LogChannel(n"DEBUG", s"[Campaign] journal snapshot sent: \(batch.Count()) entries from \(ArraySize(quests)) quests");
    }

    private func ReportEntryTree(journal: ref<JournalManager>, entry: wref<JournalEntry>, filter: JournalRequestStateFilter, batch: ref<CampaignBatch>) -> Void {
        if !IsDefined(entry) {
            return;
        }
        let hash = Cast<Uint32>(journal.GetEntryHash(entry));
        batch.Add(s"\(hash)", EnumInt(journal.GetEntryState(entry)));

        let children: array<wref<JournalEntry>>;
        journal.GetChildren(entry, filter, children);
        for child in children {
            this.ReportEntryTree(journal, child, filter, batch);
        }
    }

    public func WatchFacts(names: String, last: Bool) -> Void {
        if !this.IsHost() {
            return;
        }
        if !IsDefined(this.m_factSnapshot) {
            this.m_factSnapshot = new CampaignFactBatch();
        }

        let quests = GameInstance.GetQuestsSystem(this.GetGameInstance());
        for name in StrSplit(names, ",") {
            if StrLen(name) > 0 {
                let watcher = new CampaignFactWatcher();
                watcher.m_name = name;
                watcher.m_listenerId = quests.RegisterListener(StringToName(name), watcher, n"OnFactChanged");
                ArrayPush(this.m_watchers, watcher);

                // Unset facts read as 0 and the server assumes 0 for anything not reported,
                // so the snapshot only carries the facts this save has actually set.
                let value = quests.GetFactStr(name);
                if value != 0 {
                    this.m_factSnapshot.Add(name, value);
                }
            }
        }

        if last {
            this.m_factSnapshot.Flush();
            LogChannel(n"DEBUG", s"[Campaign] watching \(ArraySize(this.m_watchers)) facts, \(this.m_factSnapshot.Count()) set in this save");
            this.m_factSnapshot = null;
            CampaignServer.ReportSnapshotDone();
        }
    }

    public func OnHostFactChanged(name: String, value: Int32) -> Void {
        if this.IsHost() {
            CampaignServer.ReportFact(name, value);
        }
    }

    private func ClearWatchers() -> Void {
        let quests = GameInstance.GetQuestsSystem(this.GetGameInstance());
        for watcher in this.m_watchers {
            quests.UnregisterListener(StringToName(watcher.m_name), watcher.m_listenerId);
        }
        ArrayClear(this.m_watchers);
    }

    // ---- guest side ----

    public func ApplyJournal(hash: Uint32, state: Int32) -> Void {
        if this.IsHost() {
            return;
        }
        let journal = GameInstance.GetJournalManager(this.GetGameInstance());
        let entry = journal.GetEntry(hash);
        if !IsDefined(entry) {
            LogChannel(n"DEBUG", s"[Campaign] unknown journal entry \(hash), skipped");
            return;
        }
        let target = IntEnum<gameJournalEntryState>(Cast<Int64>(state));
        if Equals(journal.GetEntryState(entry), target) {
            return;
        }
        journal.ChangeEntryStateByHash(hash, target, JournalNotifyOption.Notify);
    }

    public func ApplyJournalBatch(entries: String) -> Void {
        let hashes: array<String>;
        let states: array<Int32>;
        CampaignBatch.Parse(entries, hashes, states);
        let i = 0;
        while i < ArraySize(hashes) {
            this.ApplyJournal(Cast<Uint32>(StringToUint64(hashes[i])), states[i]);
            i += 1;
        }
    }

    public func ApplyFact(name: String, value: Int32) -> Void {
        if this.IsHost() {
            return;
        }
        let quests = GameInstance.GetQuestsSystem(this.GetGameInstance());
        if quests.GetFactStr(name) == value {
            return;
        }
        quests.SetFactStr(name, value);
    }

    public func ApplyFactBatch(entries: String) -> Void {
        let names: array<String>;
        let values: array<Int32>;
        CampaignBatch.Parse(entries, names, values);
        let i = 0;
        while i < ArraySize(names) {
            this.ApplyFact(names[i], values[i]);
            i += 1;
        }
    }
}
