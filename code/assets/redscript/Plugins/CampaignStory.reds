module CyberpunkMP.Plugins

import CyberpunkMP.*
import CyberpunkMP.World.*

// Campaign co-op, stage 6: playing the campaign through.
//
// - Host mode: 1 = the host is in a braindance (a solo editor - guests wait, held and
//   unhurt), 2 = the host plays as Johnny (guests play on as his crew; only told).
// - Regroup: the host's V jumped far in one poll (fast travel, metro, a quest teleport);
//   guests who were near where it left are brought to where it landed.
// - Scene poses: hand-placed spots for the other players' characters per scene
//   (CampaignExtras uses them), and the "/coop" chat commands to make them while testing:
//     /coop scene                       the scene key and the extras' poses now
//     /coop move <n> <right> <forward> [up] [yaw]   nudge extra n (meters, degrees left)
//     /coop save                        store the poses for this scene on the server
//     /coop clear                       remove this scene's stored poses
//     /coop hide                        nobody else in this scene (intimate scenes)
//     /coop where                       this V's position (for the mission notes)
//     /coop invite                      invite a Steam friend to this server

public class CampaignScenePoses {
    public let scene: String;
    public let poses: array<String>;
}

public class CampaignStoryPoll extends DelayCallback {
    public func Call() -> Void {
        let story = CampaignStory.Get();
        if IsDefined(story) {
            story.OnPoll();
        }
    }
}

public class CampaignStory extends ScriptableSystem {
    public static func PollSeconds() -> Float = 0.5
    // A jump this long between two polls is a teleport, not driving.
    public static func JumpDistance() -> Float = 150.0
    // Guests this close to where the host left come along.
    public static func FollowRange() -> Float = 150.0

    private let m_polling: Bool;
    private let m_mode: Int32;
    private let m_lastPosition: Vector4;
    private let m_hasLast: Bool;

    private let m_hostMode: Int32;
    private let m_held: Bool;
    private let m_cleared: Bool;

    private let m_scenes: array<ref<CampaignScenePoses>>;

    public static func Get() -> ref<CampaignStory> {
        let container = GameInstance.GetScriptableSystemsContainer(GetGameInstance());
        return container.Get(n"CyberpunkMP.Plugins.CampaignStory") as CampaignStory;
    }

    private func OnAttach() -> Void {
        if !this.m_polling {
            this.m_polling = true;
            GameInstance.GetDelaySystem(this.GetGameInstance()).DelayCallback(new CampaignStoryPoll(), CampaignStory.PollSeconds(), false);
        }
    }

    private func OnDetach() -> Void {
        this.Release();
        this.m_polling = false;
        this.m_hasLast = false;
        this.m_mode = 0;
        this.m_hostMode = 0;
    }

    // No saving while held for the host's braindance (the save would keep the hold).
    private func IsSavingLocked() -> Bool {
        return this.m_held;
    }

    private func Player() -> ref<PlayerPuppet> {
        return GameInstance.GetPlayerSystem(this.GetGameInstance()).GetLocalPlayerMainGameObject() as PlayerPuppet;
    }

    private func IsHost() -> Bool {
        let sync = CampaignSync.Get();
        return IsDefined(sync) && sync.IsHost();
    }

    private func IsGuest() -> Bool {
        let sync = CampaignSync.Get();
        return IsDefined(sync) && sync.IsGuest();
    }

    public func OnPoll() -> Void {
        if !this.m_polling {
            return;
        }
        if !this.m_held {
            this.ClearLeftovers();
        }
        if this.IsHost() {
            this.CheckHost();
        } else {
            this.m_hasLast = false;
        }
        GameInstance.GetDelaySystem(this.GetGameInstance()).DelayCallback(new CampaignStoryPoll(), CampaignStory.PollSeconds(), false);
    }

    // ---- host ----

    private func CheckHost() -> Void {
        let player = this.Player();
        if !IsDefined(player) {
            this.m_hasLast = false;
            return;
        }

        let mode = 0;
        let braindance = GameInstance.GetScriptableSystemsContainer(this.GetGameInstance()).Get(n"BraindanceSystem") as BraindanceSystem;
        if IsDefined(braindance) && braindance.GetIsInBraindance() {
            mode = 1;
        } else {
            if player.IsJohnnyReplacer() {
                mode = 2;
            }
        }
        if mode != this.m_mode {
            this.m_mode = mode;
            CampaignServer.ReportHostMode(mode);
        }

        // In a braindance the camera, not V, moves; in a vehicle (AV flights) V really travels.
        let position = player.GetWorldPosition();
        if this.m_hasLast && mode != 1 && !IsDefined(player.GetMountedVehicle()) && Vector4.Distance(position, this.m_lastPosition) > CampaignStory.JumpDistance() {
            let from = this.m_lastPosition;
            CampaignServer.ReportTeleport(from.X, from.Y, from.Z, position.X, position.Y, position.Z);
            LogChannel(n"DEBUG", s"[Campaign] the host jumped \(RoundF(Vector4.Distance(position, from))) m, guests nearby follow");
        }
        this.m_lastPosition = position;
        this.m_hasLast = true;
    }

    // ---- guest ----

    public func OnHostMode(mode: Int32) -> Void {
        if !this.IsGuest() || mode == this.m_hostMode {
            return;
        }
        this.m_hostMode = mode;
        if mode == 1 {
            this.Hold();
            this.Message("The host is in a braindance - wait for them");
            return;
        }
        this.Release();
        if mode == 2 {
            this.Message("The host plays as Johnny - you are his crew");
        }
    }

    // A world loaded from a save may carry this hold's god mode; cleared before the first use.
    private func ClearLeftovers() -> Void {
        let player = this.Player();
        if this.m_cleared || !IsDefined(player) {
            return;
        }
        this.m_cleared = true;
        GameInstance.GetGodModeSystem(this.GetGameInstance()).RemoveGodMode(player.GetEntityID(), gameGodModeType.Invulnerable, n"CampaignHostMode");
    }

    private func Hold() -> Void {
        this.ClearLeftovers();
        let player = this.Player();
        if this.m_held || !IsDefined(player) {
            return;
        }
        this.m_held = true;
        GameInstance.GetGodModeSystem(this.GetGameInstance()).AddGodMode(player.GetEntityID(), gameGodModeType.Invulnerable, n"CampaignHostMode");
        CampaignHolds.Add(n"HostMode", t"GameplayRestriction.NoMovement");
        CampaignHolds.Add(n"HostMode", t"GameplayRestriction.NoWeapons");
    }

    private func Release() -> Void {
        let player = this.Player();
        if !this.m_held {
            return;
        }
        this.m_held = false;
        CampaignHolds.Remove(n"HostMode", t"GameplayRestriction.NoMovement");
        CampaignHolds.Remove(n"HostMode", t"GameplayRestriction.NoWeapons");
        if IsDefined(player) {
            GameInstance.GetGodModeSystem(this.GetGameInstance()).RemoveGodMode(player.GetEntityID(), gameGodModeType.Invulnerable, n"CampaignHostMode");
        }
    }

    public func OnHostTeleported(from: Vector4, to: Vector4) -> Void {
        let player = this.Player();
        if !this.IsGuest() || !IsDefined(player) {
            return;
        }
        if Vector4.Distance(player.GetWorldPosition(), from) > CampaignStory.FollowRange() {
            return;
        }
        if IsDefined(player.GetMountedVehicle()) {
            this.Message("The host moved far away - get out of the car to follow");
            return;
        }
        // Not on top of the host: a step aside, a different one for each guest.
        let angle = RandRangeF(0.0, 6.28);
        let target = to + new Vector4(CosF(angle) * 2.0, SinF(angle) * 2.0, 0.0, 0.0);
        GameInstance.GetTeleportationFacility(this.GetGameInstance()).Teleport(player, target, player.GetWorldOrientation().ToEulerAngles());
        this.Message("Following the host");
    }

    // ---- scene poses ----

    public func OnScenePoses(scene: String, poses: String) -> Void {
        let i = 0;
        while i < ArraySize(this.m_scenes) {
            if Equals(this.m_scenes[i].scene, scene) {
                ArrayErase(this.m_scenes, i);
            } else {
                i += 1;
            }
        }
        if StrLen(poses) == 0 {
            return;
        }
        let entry = new CampaignScenePoses();
        entry.scene = scene;
        entry.poses = StrSplit(poses, "|");
        ArrayPush(this.m_scenes, entry);
    }

    public func GetPoses(scene: String) -> array<String> {
        let none: array<String>;
        if StrLen(scene) == 0 {
            return none;
        }
        for entry in this.m_scenes {
            if Equals(entry.scene, scene) {
                return entry.poses;
            }
        }
        return none;
    }

    // ---- "/coop" chat commands ----

    // ChatController hands every "/..." line to this system.
    private func OnChatCommandRequest(request: ref<ChatCommandRequest>) -> Void {
        if StrBeginsWith(request.text, "/coop") {
            this.Command(request.text);
        }
    }

    public func Command(text: String) -> Void {
        let words: array<String>;
        for word in StrSplit(text, " ") {
            if StrLen(word) > 0 {
                ArrayPush(words, word);
            }
        }
        let verb = ArraySize(words) > 1 ? words[1] : "help";
        let extras = CampaignExtras.Get();

        if Equals(verb, "invite") {
            this.Reply(CampaignLobby.InviteNote(GameInstance.GetNetworkWorldSystem().OpenSteamInvite()));
            return;
        }

        if Equals(verb, "where") {
            let player = this.Player();
            if IsDefined(player) {
                let p = player.GetWorldPosition();
                this.Reply(s"V at \(FloatToStringPrec(p.X, 1)) \(FloatToStringPrec(p.Y, 1)) \(FloatToStringPrec(p.Z, 1)), scene \(GameInstance.GetNetworkWorldSystem().GetSceneKey())");
            }
            return;
        }

        if !IsDefined(extras) || !extras.IsActive() {
            this.Reply("No scene is running here - poses are made while one plays");
            return;
        }
        let scene = extras.SceneKey();
        if StrLen(scene) == 0 {
            this.Reply("This scene has no key (it did not come through the quest mirror)");
            return;
        }

        if Equals(verb, "scene") {
            this.Reply(s"scene \(scene): \(extras.DescribePoses())");
            return;
        }
        if Equals(verb, "move") && ArraySize(words) >= 5 {
            let up = ArraySize(words) >= 6 ? StringToFloat(words[5]) : 0.0;
            let yaw = ArraySize(words) >= 7 ? StringToFloat(words[6]) : 0.0;
            if extras.Nudge(StringToInt(words[2]), StringToFloat(words[3]), StringToFloat(words[4]), up, yaw) {
                this.Reply(extras.DescribePoses());
            } else {
                this.Reply("No such extra (numbers start at 0; extras in a car cannot be moved)");
            }
            return;
        }
        if Equals(verb, "save") {
            let poses = extras.DescribePoses();
            CampaignServer.SaveScenePoses(scene, poses);
            this.Reply(s"saved for \(scene): \(poses)");
            return;
        }
        if Equals(verb, "hide") {
            CampaignServer.SaveScenePoses(scene, "hide");
            this.Reply(s"other players hidden in \(scene)");
            return;
        }
        if Equals(verb, "clear") {
            CampaignServer.SaveScenePoses(scene, "");
            this.Reply(s"poses removed for \(scene)");
            return;
        }
        this.Reply("/coop scene | move <n> <right> <forward> [up] [yaw] | save | clear | hide | where | invite");
    }

    // Shown in this player's chat only.
    private func Reply(text: String) -> Void {
        let evt = new ChatMessageUIEvent();
        evt.author = "coop";
        evt.message = text;
        GameInstance.GetUISystem(this.GetGameInstance()).QueueEvent(evt);
        LogChannel(n"DEBUG", s"[Campaign] /coop: \(text)");
    }

    private func Message(text: String) -> Void {
        let message: SimpleScreenMessage;
        message.isShown = true;
        message.duration = 4.0;
        message.message = text;
        message.isInstant = true;
        let notifications = GetAllBlackboardDefs().UI_Notifications;
        GameInstance.GetBlackboardSystem(this.GetGameInstance()).Get(notifications).SetVariant(notifications.OnscreenMessage, ToVariant(message), true);
    }
}
