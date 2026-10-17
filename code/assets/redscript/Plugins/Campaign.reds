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
    public static native func ReportDialog(options: String, timed: Bool) -> Void;
    public static native func ReportDialogClosed() -> Void;
    public static native func ReportScene(tier: Int32, x: Float, y: Float, z: Float) -> Void;
    public static native func ReportQuestNodes(entries: String) -> Void;
    public static native func ReportTracked(hash: Uint32) -> Void;
    public static native func ReportNpcs(entries: String) -> Void;
    public static native func ReportNpcHits(entries: String) -> Void;
    public static native func ReportDowned(downed: Bool) -> Void;
    public static native func ReportRevive(puppetId: Uint64) -> Void;
    public static native func ReportBledOut() -> Void;
    public static native func ReportHostMode(mode: Int32) -> Void;
    public static native func ReportTeleport(fromX: Float, fromY: Float, fromZ: Float, toX: Float, toY: Float, toZ: Float) -> Void;
    public static native func SaveScenePoses(scene: String, poses: String) -> Void;
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

    public func ApplyTracked(hash: Uint32) -> Void {
        CampaignSync.Get().ApplyTracked(hash);
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

    public func ReplayQuestNodes(entries: String) -> Void {
        let network = GameInstance.GetNetworkWorldSystem();
        if IsDefined(network) && !CampaignSync.Get().IsHost() {
            network.ReplayQuestNodes(entries);
        }
    }

    public func SceneState(tier: Int32, x: Float, y: Float, z: Float) -> Void {
        let dialog = CampaignDialog.Get();
        if IsDefined(dialog) {
            dialog.OnSceneState(tier, x, y, z);
        }
    }

    // Stage 5: NPCs and combat (CampaignCombat).
    public func ApplyNpcs(entries: String) -> Void {
        let combat = CampaignCombat.Get();
        if IsDefined(combat) {
            combat.ApplyNpcs(entries);
        }
    }

    public func ApplyNpcHits(entries: String) -> Void {
        let combat = CampaignCombat.Get();
        if IsDefined(combat) {
            combat.ApplyNpcHits(entries);
        }
    }

    public func CoopPlayers(count: Int32) -> Void {
        let combat = CampaignCombat.Get();
        if IsDefined(combat) {
            combat.SetCoopPlayers(count);
        }
    }

    public func PlayerDowned(puppetId: Uint64, downed: Bool) -> Void {
        let combat = CampaignCombat.Get();
        if IsDefined(combat) {
            combat.OnPlayerDowned(puppetId, downed);
        }
    }

    public func Revived(health: Float) -> Void {
        let combat = CampaignCombat.Get();
        if IsDefined(combat) {
            combat.OnRevived(health);
        }
    }

    public func Respawn(x: Float, y: Float, z: Float) -> Void {
        let combat = CampaignCombat.Get();
        if IsDefined(combat) {
            combat.OnRespawn(x, y, z, 50.0);
        }
    }

    // Stage 6: playing the campaign through (CampaignStory).
    public func HostMode(mode: Int32) -> Void {
        let story = CampaignStory.Get();
        if IsDefined(story) {
            story.OnHostMode(mode);
        }
    }

    public func HostTeleported(fromX: Float, fromY: Float, fromZ: Float, toX: Float, toY: Float, toZ: Float) -> Void {
        let story = CampaignStory.Get();
        if IsDefined(story) {
            story.OnHostTeleported(new Vector4(fromX, fromY, fromZ, 1.0), new Vector4(toX, toY, toZ, 1.0));
        }
    }

    public func ScenePoses(scene: String, poses: String) -> Void {
        let story = CampaignStory.Get();
        if IsDefined(story) {
            story.OnScenePoses(scene, poses);
        }
    }

    public func CoopWipe(reason: Int32) -> Void {
        let combat = CampaignCombat.Get();
        if IsDefined(combat) {
            combat.OnWipe();
        }
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

// Sends the quest nodes the host's game ran (QuestMirror) a few times a second.
public class CampaignQuestNodesPoll extends DelayCallback {
    public func Call() -> Void {
        let sync = CampaignSync.Get();
        if IsDefined(sync) {
            sync.OnQuestNodesPoll();
        }
    }
}

public class CampaignSync extends ScriptableSystem {
    public static func QuestNodesSeconds() -> Float = 0.25

    private let m_isHost: Bool;
    private let m_hasRole: Bool;
    private let m_journalListening: Bool;
    private let m_watchers: array<ref<CampaignFactWatcher>>;
    private let m_factSnapshot: ref<CampaignFactBatch>;
    private let m_questNodesPolling: Bool;
    // Host: the objective last reported as tracked. Guest: the host's, until it can be tracked
    // here (its journal entry may arrive after it).
    private let m_trackedHash: Uint32;
    private let m_trackedPending: Bool;

    public static func Get() -> ref<CampaignSync> {
        let container = GameInstance.GetScriptableSystemsContainer(GetGameInstance());
        return container.Get(n"CyberpunkMP.Plugins.CampaignSync") as CampaignSync;
    }

    private func OnDetach() -> Void {
        this.StopJournalListening();
        this.ClearWatchers();
        this.m_hasRole = false;
        let network = GameInstance.GetNetworkWorldSystem();
        if IsDefined(network) {
            network.SetQuestMirror(0);
        }
    }

    public func IsHost() -> Bool {
        return this.m_hasRole && this.m_isHost;
    }

    public func IsGuest() -> Bool {
        return this.m_hasRole && !this.m_isHost;
    }

    public func SetRole(isHost: Bool) -> Void {
        this.m_hasRole = true;
        this.m_isHost = isHost;
        this.ClearWatchers();
        this.m_factSnapshot = null;
        this.m_trackedHash = 0u;
        this.m_trackedPending = false;

        // The host records the scenes, calls and world changes its quests run; guests run them.
        GameInstance.GetNetworkWorldSystem().SetQuestMirror(isHost ? 1 : 2);
        if isHost {
            this.StartQuestNodesPolling();
        }

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

    private func StartQuestNodesPolling() -> Void {
        if this.m_questNodesPolling {
            return;
        }
        this.m_questNodesPolling = true;
        GameInstance.GetDelaySystem(this.GetGameInstance()).DelayCallback(new CampaignQuestNodesPoll(), CampaignSync.QuestNodesSeconds(), false);
    }

    public func OnQuestNodesPoll() -> Void {
        if !this.IsHost() {
            this.m_questNodesPolling = false;
            return;
        }
        let entries = GameInstance.GetNetworkWorldSystem().TakeQuestNodes();
        if StrLen(entries) > 0 {
            CampaignSync.SendQuestNodes(entries);
        }
        this.CheckTracked();
        GameInstance.GetDelaySystem(this.GetGameInstance()).DelayCallback(new CampaignQuestNodesPoll(), CampaignSync.QuestNodesSeconds(), false);
    }

    // The objective on the HUD (and its map pin and route) follows the host's: the host's
    // game picks it as the story moves on, the guests' games track the same one.
    private func CheckTracked() -> Void {
        let journal = GameInstance.GetJournalManager(this.GetGameInstance());
        let entry = journal.GetTrackedEntry();
        let hash = IsDefined(entry) ? Cast<Uint32>(journal.GetEntryHash(entry)) : 0u;
        if hash != this.m_trackedHash {
            this.m_trackedHash = hash;
            CampaignServer.ReportTracked(hash);
        }
    }

    // Split at entry boundaries into pieces under the batch limit.
    private static func SendQuestNodes(entries: String) -> Void {
        let piece = "";
        for entry in StrSplit(entries, ",") {
            if StrLen(piece) + StrLen(entry) + 1 > CampaignBatch.MaxLength() {
                CampaignServer.ReportQuestNodes(piece);
                piece = "";
            }
            if StrLen(piece) > 0 {
                piece += ",";
            }
            piece += entry;
        }
        if StrLen(piece) > 0 {
            CampaignServer.ReportQuestNodes(piece);
        }
    }

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
        this.TryTrack();
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

    // 0 = the host tracks nothing: whatever the guest tracks stays.
    public func ApplyTracked(hash: Uint32) -> Void {
        if this.IsHost() || hash == 0u {
            return;
        }
        this.m_trackedHash = hash;
        this.m_trackedPending = true;
        this.TryTrack();
    }

    private func TryTrack() -> Void {
        if !this.m_trackedPending {
            return;
        }
        let journal = GameInstance.GetJournalManager(this.GetGameInstance());
        let entry = journal.GetEntry(this.m_trackedHash);
        if !IsDefined(entry) || !Equals(journal.GetEntryState(entry), gameJournalEntryState.Active) {
            return;
        }
        this.m_trackedPending = false;
        if !journal.IsEntryTracked(entry) {
            journal.TrackEntry(entry);
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

// Restrictions (status effects such as GameplayRestriction.NoMovement) that several campaign
// systems put on the local V for reasons of their own - a scene hold, being downed, waiting
// out the host's braindance. An effect is lifted only once no reason wants it any more, so
// one system ending its hold never frees V from another's.
public class CampaignHolds extends ScriptableSystem {
    private let m_reasons: array<CName>;
    private let m_effects: array<TweakDBID>;

    public static func Get() -> ref<CampaignHolds> {
        let container = GameInstance.GetScriptableSystemsContainer(GetGameInstance());
        return container.Get(n"CyberpunkMP.Plugins.CampaignHolds") as CampaignHolds;
    }

    public static func Add(reason: CName, effect: TweakDBID) -> Void {
        let holds = CampaignHolds.Get();
        if IsDefined(holds) {
            holds.AddHold(reason, effect);
        }
    }

    public static func Remove(reason: CName, effect: TweakDBID) -> Void {
        let holds = CampaignHolds.Get();
        if IsDefined(holds) {
            holds.RemoveHold(reason, effect);
        }
    }

    private func Player() -> ref<GameObject> {
        return GameInstance.GetPlayerSystem(this.GetGameInstance()).GetLocalPlayerMainGameObject();
    }

    private func IndexOf(reason: CName, effect: TweakDBID) -> Int32 {
        let i = 0;
        while i < ArraySize(this.m_reasons) {
            if Equals(this.m_reasons[i], reason) && this.m_effects[i] == effect {
                return i;
            }
            i += 1;
        }
        return -1;
    }

    private func Wanted(effect: TweakDBID) -> Bool {
        for wanted in this.m_effects {
            if wanted == effect {
                return true;
            }
        }
        return false;
    }

    public func AddHold(reason: CName, effect: TweakDBID) -> Void {
        if this.IndexOf(reason, effect) >= 0 {
            return;
        }
        let first = !this.Wanted(effect);
        ArrayPush(this.m_reasons, reason);
        ArrayPush(this.m_effects, effect);
        let player = this.Player();
        if first && IsDefined(player) {
            StatusEffectHelper.ApplyStatusEffect(player, effect);
        }
    }

    public func RemoveHold(reason: CName, effect: TweakDBID) -> Void {
        let i = this.IndexOf(reason, effect);
        if i < 0 {
            return;
        }
        ArrayErase(this.m_reasons, i);
        ArrayErase(this.m_effects, i);
        let player = this.Player();
        if !this.Wanted(effect) && IsDefined(player) {
            StatusEffectHelper.RemoveStatusEffect(player, effect);
        }
    }
}
