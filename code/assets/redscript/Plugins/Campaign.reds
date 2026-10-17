module CyberpunkMP.Plugins

import CyberpunkMP.*
import CyberpunkMP.World.*

// Campaign co-op: the host's game runs the story, every other player mirrors it.
//
// The server decides who the host is (first player in) and tells each client with SetRole.
// The host reports journal entry states and watched quest facts; the server stores them and
// forwards them to the guests, so a late joiner receives the whole snapshot on arrival.

public native class CampaignServer extends ServerRpc {
    public static native func ReportJournal(hash: Uint32, state: Int32) -> Void;
    public static native func ReportFact(name: String, value: Int32) -> Void;
}

// ClientRpc functions are invoked without an instance, so they only route to CampaignSync.
public class CampaignClient extends ClientRpc {
    public func SetRole(isHost: Bool) -> Void {
        CampaignSync.Get().SetRole(isHost);
    }

    public func ApplyJournal(hash: Uint32, state: Int32) -> Void {
        CampaignSync.Get().ApplyJournal(hash, state);
    }

    public func ApplyFact(name: String, value: Int32) -> Void {
        CampaignSync.Get().ApplyFact(name, value);
    }

    public func WatchFact(name: String) -> Void {
        CampaignSync.Get().WatchFact(name);
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
    private let m_isHost: Bool;
    private let m_hasRole: Bool;
    private let m_journalListening: Bool;
    private let m_watchers: array<ref<CampaignFactWatcher>>;

    public static func Get() -> ref<CampaignSync> {
        let container = GameInstance.GetScriptableSystemsContainer(GetGameInstance());
        return container.Get(n"CyberpunkMP.Plugins.CampaignSync") as CampaignSync;
    }

    private func OnDetach() -> Void {
        this.StopJournalListening();
        this.ClearWatchers();
    }

    public func IsHost() -> Bool {
        return this.m_hasRole && this.m_isHost;
    }

    public func SetRole(isHost: Bool) -> Void {
        this.m_hasRole = true;
        this.m_isHost = isHost;
        this.ClearWatchers();

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

        let count = 0;
        for quest in quests {
            count += this.ReportEntryTree(journal, quest, filter);
        }
        LogChannel(n"DEBUG", s"[Campaign] journal snapshot sent: \(count) entries from \(ArraySize(quests)) quests");
    }

    private func ReportEntryTree(journal: ref<JournalManager>, entry: wref<JournalEntry>, filter: JournalRequestStateFilter) -> Int32 {
        if !IsDefined(entry) {
            return 0;
        }
        let hash = Cast<Uint32>(journal.GetEntryHash(entry));
        CampaignServer.ReportJournal(hash, EnumInt(journal.GetEntryState(entry)));

        let count = 1;
        let children: array<wref<JournalEntry>>;
        journal.GetChildren(entry, filter, children);
        for child in children {
            count += this.ReportEntryTree(journal, child, filter);
        }
        return count;
    }

    public func WatchFact(name: String) -> Void {
        if !this.IsHost() {
            return;
        }
        let quests = GameInstance.GetQuestsSystem(this.GetGameInstance());
        let watcher = new CampaignFactWatcher();
        watcher.m_name = name;
        watcher.m_listenerId = quests.RegisterListener(StringToName(name), watcher, n"OnFactChanged");
        ArrayPush(this.m_watchers, watcher);

        // The current value is part of the snapshot, not only later changes.
        CampaignServer.ReportFact(name, quests.GetFactStr(name));
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
}
