module CyberpunkMP.Plugins

import CyberpunkMP.*
import CyberpunkMP.World.*

// Campaign co-op, stage 4: dialogs and scenes.
//
// Dialogs: the host's game shows dialog options as usual. When the players are together in
// the world, the host reports them and the server opens a vote ("dialog", CampaignVote.cs).
// Meanwhile the host's confirm key only counts as the host's vote for the highlighted option
// (NetworkWorldSystem.SetChoiceLock); guests get the same options in the game's own dialog
// box. When the vote closes, the host's game picks the winner by itself (InjectChoice: key
// presses, as a player would). Nobody voted: the host picks as usual.
//
// Scenes: the host reports its scene tier (GameplayTier) and position. Guests far away are
// brought over when a scene starts, and held in place while a cinematic one runs.

public class CampaignDialogPoll extends DelayCallback {
    public func Call() -> Void {
        let dialog = CampaignDialog.Get();
        if IsDefined(dialog) {
            dialog.OnPoll();
        }
    }
}

public class CampaignDialog extends ScriptableSystem {
    public static func PollSeconds() -> Float = 0.1
    // A guest further than this from the host when a scene starts is brought over.
    public static func SceneRange() -> Float = 25.0
    // The guest's own dialog box, while it shows a vote.
    public static func GuestHubId() -> Int32 = 77000

    private let m_hubsListener: ref<CallbackHandle>;
    private let m_activeHubListener: ref<CallbackHandle>;

    // ---- host: the dialog last reported ----
    private let m_reportedOptions: String;

    // ---- the running dialog vote ----
    private let m_voteId: Uint32;
    private let m_voteOpen: Bool;
    private let m_options: array<String>;
    private let m_counts: array<Int32>;
    private let m_myVote: Int32;
    private let m_polling: Bool;

    // ---- guest: our own dialog box ----
    private let m_guestSelected: Int32;
    private let m_guestListening: Bool;

    // ---- scenes ----
    private let m_held: Bool;
    private let m_hostTier: Int32;

    public static func Get() -> ref<CampaignDialog> {
        let container = GameInstance.GetScriptableSystemsContainer(GetGameInstance());
        return container.Get(n"CyberpunkMP.Plugins.CampaignDialog") as CampaignDialog;
    }

    private func OnAttach() -> Void {
        this.m_myVote = -1;
        let def = GetAllBlackboardDefs().UIInteractions;
        let blackboard = this.Interactions();
        this.m_hubsListener = blackboard.RegisterListenerVariant(def.DialogChoiceHubs, this, n"OnHubsChanged");
        this.m_activeHubListener = blackboard.RegisterListenerInt(def.ActiveChoiceHubID, this, n"OnActiveHubChanged");
    }

    private func OnDetach() -> Void {
        let def = GetAllBlackboardDefs().UIInteractions;
        let blackboard = this.Interactions();
        blackboard.UnregisterListenerVariant(def.DialogChoiceHubs, this.m_hubsListener);
        blackboard.UnregisterListenerInt(def.ActiveChoiceHubID, this.m_activeHubListener);
        this.EndVote();
        this.Release();
    }

    private func Interactions() -> ref<IBlackboard> {
        return GameInstance.GetBlackboardSystem(this.GetGameInstance()).Get(GetAllBlackboardDefs().UIInteractions);
    }

    private func IsHost() -> Bool {
        let sync = CampaignSync.Get();
        return IsDefined(sync) && sync.IsHost();
    }

    private func Hubs() -> DialogChoiceHubs {
        return FromVariant<DialogChoiceHubs>(this.Interactions().GetVariant(GetAllBlackboardDefs().UIInteractions.DialogChoiceHubs));
    }

    // ---- host: reporting the dialog ----

    protected cb func OnHubsChanged(value: Variant) -> Bool {
        this.CheckHostDialog();
        return false;
    }

    protected cb func OnActiveHubChanged(value: Int32) -> Bool {
        this.CheckHostDialog();
        return false;
    }

    // Only a dialog the player is actually in (an active hub) is voted on; options merely in
    // view while walking past someone are not.
    private func CheckHostDialog() -> Void {
        if !this.IsHost() {
            return;
        }

        let blackboard = this.Interactions();
        let activeHub = blackboard.GetInt(GetAllBlackboardDefs().UIInteractions.ActiveChoiceHubID);
        let hubs = this.Hubs();

        if activeHub < 0 || ArraySize(hubs.choiceHubs) == 0 {
            if StrLen(this.m_reportedOptions) > 0 {
                this.m_reportedOptions = "";
                CampaignServer.ReportDialogClosed();
            }
            return;
        }

        let timed = false;
        let options = "";
        for hub in hubs.choiceHubs {
            if IsDefined(hub.timeProvider) {
                timed = true;
            }
            for choice in hub.choices {
                if IsDefined(choice.timeProvider) {
                    timed = true;
                }
                if StrLen(options) > 0 {
                    options += "|";
                }
                if CampaignDialog.IsUnavailable(choice) {
                    options += "~";
                }
                options += StrReplaceAll(choice.localizedName, "|", "/");
            }
        }

        if Equals(options, this.m_reportedOptions) {
            return;
        }
        this.m_reportedOptions = options;
        CampaignServer.ReportDialog(options, timed);
    }

    public static func IsUnavailable(choice: ListChoiceData) -> Bool {
        return ChoiceTypeWrapper.IsType(choice.type, gameinteractionsChoiceType.Inactive)
            || ChoiceTypeWrapper.IsType(choice.type, gameinteractionsChoiceType.CheckFailed);
    }

    // The highlighted option, counted across all hubs (the order the options were reported in).
    private func HostSelection() -> Int32 {
        let def = GetAllBlackboardDefs().UIInteractions;
        let blackboard = this.Interactions();
        let activeHub = blackboard.GetInt(def.ActiveChoiceHubID);
        let selected = blackboard.GetInt(def.SelectedIndex);
        let hubs = this.Hubs();
        let index = 0;
        for hub in hubs.choiceHubs {
            if hub.id == activeHub {
                return index + selected;
            }
            index += ArraySize(hub.choices);
        }
        return -1;
    }

    // ---- the vote (routed here by CampaignLobby) ----

    public func OwnsVote(voteId: Uint32) -> Bool {
        return this.m_voteOpen && this.m_voteId == voteId;
    }

    public func IsVoting() -> Bool = this.m_voteOpen

    public func OnVoteOpened(voteId: Uint32, options: String, seconds: Int32) -> Void {
        this.m_voteId = voteId;
        this.m_voteOpen = true;
        this.m_options = StrSplit(options, "|");
        this.m_myVote = -1;
        ArrayClear(this.m_counts);
        for option in this.m_options {
            ArrayPush(this.m_counts, 0);
        }
        LogChannel(n"DEBUG", s"[Campaign] dialog vote \(voteId): \(ArraySize(this.m_options)) options, \(seconds)s");

        if this.IsHost() {
            GameInstance.GetNetworkWorldSystem().SetChoiceLock(true);
            this.StartPolling();
            this.RefreshHost();
        } else {
            this.m_guestSelected = this.FirstAvailable();
            this.ListenGuestInput(true);
            this.ShowGuestHub();
        }
    }

    public func OnVoteTally(voteId: Uint32, counts: String) -> Void {
        if !this.OwnsVote(voteId) {
            return;
        }
        ArrayClear(this.m_counts);
        for count in StrSplit(counts, ",") {
            ArrayPush(this.m_counts, StringToInt(count));
        }
        if this.IsHost() {
            this.RefreshHost();
        } else {
            this.ShowGuestHub();
        }
    }

    public func OnVoteClosed(voteId: Uint32, winner: Int32) -> Void {
        if !this.OwnsVote(voteId) {
            return;
        }
        let isHost = this.IsHost();
        this.EndVote();

        if !isHost {
            return;
        }
        this.RefreshHost();

        // The dialog may have closed meanwhile; then there is nothing left to pick.
        let current = this.HostSelection();
        if winner < 0 || current < 0 {
            LogChannel(n"DEBUG", s"[Campaign] dialog vote \(voteId) closed without a pick, the host chooses");
            return;
        }
        LogChannel(n"DEBUG", s"[Campaign] dialog vote \(voteId): option \(winner + 1) won, picking it");
        if !GameInstance.GetNetworkWorldSystem().InjectChoice(winner - current) {
            LogChannel(n"DEBUG", "[Campaign] cannot pick dialog options on this game, the host chooses");
        }
    }

    private func EndVote() -> Void {
        if !this.m_voteOpen {
            return;
        }
        this.m_voteOpen = false;
        let network = GameInstance.GetNetworkWorldSystem();
        if IsDefined(network) {
            network.SetChoiceLock(false);
        }
        if this.m_guestListening {
            this.ListenGuestInput(false);
            this.HideGuestHub();
        }
    }

    private func Vote(option: Int32) -> Void {
        if !this.m_voteOpen || option < 0 || option >= ArraySize(this.m_options) || this.IsOptionUnavailable(option) {
            return;
        }
        this.m_myVote = option;
        CampaignServer.CastVote(this.m_voteId, option);
    }

    private func IsOptionUnavailable(option: Int32) -> Bool {
        return StrBeginsWith(this.m_options[option], "~");
    }

    private func FirstAvailable() -> Int32 {
        let i = 0;
        while i < ArraySize(this.m_options) {
            if !this.IsOptionUnavailable(i) {
                return i;
            }
            i += 1;
        }
        return 0;
    }

    // "  [2]" after an option with votes, "<" after my own.
    public func VoteSuffix(option: Int32) -> String {
        let count = option < ArraySize(this.m_counts) ? this.m_counts[option] : 0;
        let suffix = count > 0 ? s"  [\(count)]" : "";
        if this.m_myVote == option {
            suffix += "  <";
        }
        return suffix;
    }

    // ---- host: own vote and the counts on the game's dialog box ----

    private func StartPolling() -> Void {
        if this.m_polling {
            return;
        }
        this.m_polling = true;
        GameInstance.GetDelaySystem(this.GetGameInstance()).DelayCallback(new CampaignDialogPoll(), CampaignDialog.PollSeconds(), false);
    }

    // The host's confirm presses are held back while voting; each one is a vote for the
    // highlighted option.
    public func OnPoll() -> Void {
        if !this.m_voteOpen || !this.IsHost() {
            this.m_polling = false;
            return;
        }
        if GameInstance.GetNetworkWorldSystem().TakeBlockedChoiceConfirms() > 0 {
            this.Vote(this.HostSelection());
            this.RefreshHost();
        }
        GameInstance.GetDelaySystem(this.GetGameInstance()).DelayCallback(new CampaignDialogPoll(), CampaignDialog.PollSeconds(), false);
    }

    // Sets the same options again so the dialog box redraws with the current counts.
    private func RefreshHost() -> Void {
        let def = GetAllBlackboardDefs().UIInteractions;
        let blackboard = this.Interactions();
        blackboard.SetVariant(def.DialogChoiceHubs, blackboard.GetVariant(def.DialogChoiceHubs), true);
    }

    // The dialog box's data with the vote counts written after each option.
    public func Decorate(data: DialogChoiceHubs) -> DialogChoiceHubs {
        let index = 0;
        let h = 0;
        while h < ArraySize(data.choiceHubs) {
            let hub = data.choiceHubs[h];
            let c = 0;
            while c < ArraySize(hub.choices) {
                let choice = hub.choices[c];
                choice.localizedName += this.VoteSuffix(index);
                hub.choices[c] = choice;
                index += 1;
                c += 1;
            }
            data.choiceHubs[h] = hub;
            h += 1;
        }
        return data;
    }

    // ---- guest: the vote in our own dialog box ----

    private func ShowGuestHub() -> Void {
        let hub: ListChoiceHubData;
        hub.id = CampaignDialog.GuestHubId();
        hub.activityState = EVisualizerActivityState.Active;
        hub.title = "CO-OP VOTE";

        let i = 0;
        while i < ArraySize(this.m_options) {
            let choice: ListChoiceData;
            let text = this.m_options[i];
            if this.IsOptionUnavailable(i) {
                text = StrAfterFirst(text, "~") + "  (host cannot)";
            }
            choice.localizedName = text + this.VoteSuffix(i);
            choice.inputActionName = n"ChoiceApply";
            ArrayPush(hub.choices, choice);
            i += 1;
        }

        let hubs: DialogChoiceHubs;
        ArrayPush(hubs.choiceHubs, hub);

        let def = GetAllBlackboardDefs().UIInteractions;
        let blackboard = this.Interactions();
        blackboard.SetVariant(def.DialogChoiceHubs, ToVariant(hubs), true);
        blackboard.SetInt(def.ActiveChoiceHubID, CampaignDialog.GuestHubId(), true);
        blackboard.SetInt(def.SelectedIndex, this.m_guestSelected, true);
    }

    private func HideGuestHub() -> Void {
        let def = GetAllBlackboardDefs().UIInteractions;
        let blackboard = this.Interactions();
        let hubs: DialogChoiceHubs;
        blackboard.SetVariant(def.DialogChoiceHubs, ToVariant(hubs), true);
        blackboard.SetInt(def.ActiveChoiceHubID, -1, true);
    }

    private func ListenGuestInput(listen: Bool) -> Void {
        let player = GameInstance.GetPlayerSystem(this.GetGameInstance()).GetLocalPlayerMainGameObject();
        if !IsDefined(player) {
            return;
        }
        if listen {
            player.RegisterInputListener(this, n"ChoiceScrollUp");
            player.RegisterInputListener(this, n"ChoiceScrollDown");
            player.RegisterInputListener(this, n"ChoiceApply");
        } else {
            player.UnregisterInputListener(this);
        }
        this.m_guestListening = listen;
    }

    protected cb func OnAction(action: ListenerAction, consumer: ListenerActionConsumer) -> Bool {
        if !this.m_voteOpen || this.IsHost() || !Equals(ListenerAction.GetType(action), gameinputActionType.BUTTON_PRESSED) {
            return false;
        }
        let name = ListenerAction.GetName(action);
        let count = ArraySize(this.m_options);
        if Equals(name, n"ChoiceScrollUp") {
            this.m_guestSelected = (this.m_guestSelected + count - 1) % count;
            this.ShowGuestHub();
        } else {
            if Equals(name, n"ChoiceScrollDown") {
                this.m_guestSelected = (this.m_guestSelected + 1) % count;
                this.ShowGuestHub();
            } else {
                if Equals(name, n"ChoiceApply") {
                    this.Vote(this.m_guestSelected);
                    this.ShowGuestHub();
                }
            }
        }
        return false;
    }

    // ---- scenes ----

    public func OnHostSceneTier(tier: Int32) -> Void {
        if !this.IsHost() || tier == this.m_hostTier {
            return;
        }
        this.m_hostTier = tier;
        let player = GameInstance.GetPlayerSystem(this.GetGameInstance()).GetLocalPlayerMainGameObject();
        if !IsDefined(player) {
            return;
        }
        let position = player.GetWorldPosition();
        CampaignServer.ReportScene(tier, position.X, position.Y, position.Z);
    }

    // Tier 3 (limited gameplay) and up is a scene: a guest far away is brought over. From
    // tier 4 (cinematic) the guest is held in place until it ends.
    public func OnSceneState(tier: Int32, x: Float, y: Float, z: Float) -> Void {
        if this.IsHost() {
            return;
        }
        let player = GameInstance.GetPlayerSystem(this.GetGameInstance()).GetLocalPlayerMainGameObject();
        if !IsDefined(player) {
            return;
        }

        if tier >= EnumInt(GameplayTier.Tier3_LimitedGameplay) {
            let host = new Vector4(x, y, z, 1.0);
            if Vector4.Distance(player.GetWorldPosition(), host) > CampaignDialog.SceneRange() {
                LogChannel(n"DEBUG", "[Campaign] the host's scene started, joining them");
                let target = new Vector4(x + 1.5, y, z, 1.0);
                GameInstance.GetTeleportationFacility(this.GetGameInstance()).Teleport(player, target, player.GetWorldOrientation().ToEulerAngles());
            }
        }

        if tier >= EnumInt(GameplayTier.Tier4_FPPCinematic) {
            if !this.m_held {
                this.m_held = true;
                StatusEffectHelper.ApplyStatusEffect(player, t"GameplayRestriction.NoMovement");
            }
        } else {
            this.Release();
        }
    }

    private func Release() -> Void {
        if !this.m_held {
            return;
        }
        this.m_held = false;
        let player = GameInstance.GetPlayerSystem(this.GetGameInstance()).GetLocalPlayerMainGameObject();
        if IsDefined(player) {
            StatusEffectHelper.RemoveStatusEffect(player, t"GameplayRestriction.NoMovement");
        }
    }
}

// Vote counts on the dialog box (the host's real one, and the guests' vote box).
@wrapMethod(dialogWidgetGameController)
protected func UpdateDialogsData(const data: script_ref<DialogChoiceHubs>) -> Void {
    let dialog = CampaignDialog.Get();
    if IsDefined(dialog) && dialog.IsVoting() && CampaignSync.Get().IsHost() {
        let decorated = dialog.Decorate(Deref(data));
        wrappedMethod(decorated);
        return;
    }
    wrappedMethod(data);
}

@wrapMethod(PlayerPuppet)
protected cb func OnSceneTierChange(newState: Int32) -> Bool {
    let result = wrappedMethod(newState);
    let dialog = CampaignDialog.Get();
    if IsDefined(dialog) {
        dialog.OnHostSceneTier(newState);
    }
    return result;
}
