module CyberpunkMP.Plugins

import CyberpunkMP.*
import CyberpunkMP.World.*

// Campaign co-op, stage 4c: the other players as extras in a scene.
//
// Every game plays a scene with its own V (QuestMirror). The other players' characters
// (CyberpunkMP puppets) would stand wherever their own V is, which is the scene's spot for V,
// so while a scene runs this game places them itself and holds them there
// (NetworkWorldSystem.SetPuppetHeld), depending on what the local V does:
// - in a car: on the free seats of that car,
// - sitting: on free seats nearby (world AI spots with a generic sit workspot),
// - standing: on a nearby standing spot with an idle gesture, or in a half circle beside V,
//   facing whoever is speaking.
// When the scene ends they are released and follow their players again.
//
// Stage 6: a scene can have hand-placed poses (CampaignStory, keyed by the scene key every
// game shares): extra number N stands at pose N, relative to the local V where V stood when
// the extras were placed. "/coop move" nudges an extra, "/coop save" stores the poses.
//
// Seats come from the world sectors loaded around the player (Codeware's Resource/Ready
// event); NetworkWorldSystem.FindSceneSpots picks the AI spots whose workspot is a known
// generic sit/stand pose (SceneSpotsData.inl, tools/campaign/extract_workspots.py).

public class CampaignSceneSpot {
    public let node: Uint64;
    public let position: Vector4;
    public let forward: Vector4;
    // 1 = sit, 2 = stand with an idle gesture
    public let kind: Int32;
    public let taken: Bool;
}

public class CampaignExtra {
    public let entity: wref<GameObject>;
    public let id: EntityID;
    // 1 = car seat, 2 = on a spot, 3 = standing beside V, 4 = on a hand-placed pose
    public let place: Int32;
    // Place 4: relative to the anchor (meters right, forward, up; degrees left of V's facing).
    public let right: Float;
    public let forward: Float;
    public let up: Float;
    public let yaw: Float;
    public let slot: Int32;
    public let seat: CName;
    public let command: ref<AIUseWorkspotCommand>;
}

public class CampaignExtras extends ScriptableSystem {
    public static func MaxSectors() -> Int32 = 256
    public static func SeatRange() -> Float = 8.0
    public static func StandSpotRange() -> Float = 5.0
    public static func StandRadius() -> Float = 1.6
    // V's own seat or spot: not offered to anyone else.
    public static func OwnSpotRange() -> Float = 0.6

    private let m_sectors: array<wref<worldStreamingSector>>;
    private let m_extras: array<ref<CampaignExtra>>;
    private let m_spots: array<ref<CampaignSceneSpot>>;
    private let m_active: Bool;
    // What the local V does: 1 = in a car, 2 = sitting, 3 = standing
    private let m_mode: Int32;
    private let m_speaker: wref<GameObject>;
    // Where V stood and faced when the extras were placed: hand-placed poses hang off it.
    private let m_anchor: Vector4;
    private let m_anchorForward: Vector4;
    private let m_anchored: Bool;
    private let m_sceneKey: String;
    // The key the last scene ended with. QuestMirror keeps the last scene that started, so a
    // later scene that did not come through it (sitting down at a bar) would otherwise get
    // that scene's poses.
    private let m_endedKey: String;

    public static func Get() -> ref<CampaignExtras> {
        let container = GameInstance.GetScriptableSystemsContainer(GetGameInstance());
        return container.Get(n"CyberpunkMP.Plugins.CampaignExtras") as CampaignExtras;
    }

    private func OnAttach() -> Void {
        GameInstance.GetCallbackSystem().RegisterCallback(n"Resource/Ready", this, n"OnSectorReady")
            .AddTarget(ResourceTarget.Type(n"worldStreamingSector"));
    }

    private func OnDetach() -> Void {
        this.End();
        GameInstance.GetCallbackSystem().UnregisterCallback(n"Resource/Ready", this);
    }

    private cb func OnSectorReady(event: ref<ResourceEvent>) {
        let sector = event.GetResource() as worldStreamingSector;
        if !IsDefined(sector) {
            return;
        }
        ArrayPush(this.m_sectors, sector);
        if ArraySize(this.m_sectors) > CampaignExtras.MaxSectors() {
            ArrayErase(this.m_sectors, 0);
        }
    }

    // ---- scene start, updates and end (from CampaignDialog) ----

    public func OnScene(inScene: Bool) -> Void {
        if !inScene {
            this.End();
            return;
        }
        if !this.m_active {
            this.m_active = true;
            GameInstance.GetNetworkWorldSystem().SetVehicleSyncPaused(true);
        }
        this.Update();
    }

    private func End() -> Void {
        if !this.m_active {
            return;
        }
        this.m_active = false;
        // The raw key: a scene that was already stale stays stale for the next one.
        let network = GameInstance.GetNetworkWorldSystem();
        if IsDefined(network) {
            this.m_endedKey = network.GetSceneKey();
        }
        this.m_sceneKey = "";
        this.ReleaseAll();
        this.m_mode = 0;
        this.m_speaker = null;
        this.m_anchored = false;
        ArrayClear(this.m_spots);
        if IsDefined(network) {
            network.SetVehicleSyncPaused(false);
        }
    }

    // About once a second while a scene runs: new players get a place, and everyone moves
    // when V gets into a car, sits down or stands up.
    public func Update() -> Void {
        if !this.m_active {
            return;
        }
        let player = this.Player();
        if !IsDefined(player) {
            return;
        }

        let mode = this.LocalMode(player);
        let sceneKey = GameInstance.GetNetworkWorldSystem().GetSceneKey();
        if Equals(sceneKey, this.m_endedKey) {
            sceneKey = "";
        }
        if mode != this.m_mode || NotEquals(sceneKey, this.m_sceneKey) {
            this.ReleaseAll();
            this.m_mode = mode;
            this.m_sceneKey = sceneKey;
            this.m_anchor = player.GetWorldPosition();
            this.m_anchorForward = Vector4.Normalize2D(player.GetWorldForward());
            this.m_anchored = true;
            this.CollectSpots(player);
        }

        this.ForgetGone();
        for entity in GameInstance.GetDynamicEntitySystem().GetTagged(n"CyberpunkMP.Puppet") {
            let puppet = entity as GameObject;
            if IsDefined(puppet) && !this.Has(puppet.GetEntityID()) {
                this.Place(player, puppet);
            }
        }
    }

    // A new line of dialog: those standing beside V turn to the speaker.
    public func OnSpeaker(speaker: wref<GameObject>) -> Void {
        if !this.m_active || !IsDefined(speaker) || speaker.IsPlayer() || this.Has(speaker.GetEntityID()) {
            return;
        }
        this.m_speaker = speaker;
        let player = this.Player();
        if !IsDefined(player) {
            return;
        }
        for extra in this.m_extras {
            if extra.place == 3 {
                this.StandBeside(player, extra);
            }
        }
    }

    private func Player() -> ref<PlayerPuppet> {
        return GameInstance.GetPlayerSystem(this.GetGameInstance()).GetLocalPlayerMainGameObject() as PlayerPuppet;
    }

    private func LocalMode(player: ref<PlayerPuppet>) -> Int32 {
        if IsDefined(player.GetMountedVehicle()) {
            return 1;
        }
        if GameInstance.GetWorkspotSystem(this.GetGameInstance()).IsActorInWorkspot(player) {
            return 2;
        }
        return 3;
    }

    // ---- placing one player's character ----

    private func Place(player: ref<PlayerPuppet>, puppet: ref<GameObject>) -> Void {
        let extra = new CampaignExtra();
        extra.entity = puppet;
        extra.id = puppet.GetEntityID();
        extra.slot = this.FreeSlot();

        let placed = false;
        if this.m_mode == 1 {
            placed = this.SeatInCar(player, extra);
        }
        if !placed {
            placed = this.UsePose(extra);
        }
        if !placed && this.m_mode == 2 {
            placed = this.UseSpot(player, extra, 1);
        }
        if !placed {
            placed = this.UseSpot(player, extra, 2);
        }
        if !placed {
            this.StandBeside(player, extra);
        }

        GameInstance.GetNetworkWorldSystem().SetPuppetHeld(extra.id, true);
        ArrayPush(this.m_extras, extra);
    }

    private func SeatInCar(player: ref<PlayerPuppet>, extra: ref<CampaignExtra>) -> Bool {
        let vehicle = player.GetMountedVehicle();
        if !IsDefined(vehicle) {
            return false;
        }
        let vehicleId = vehicle.GetEntityID();
        let seats = [n"seat_front_right", n"seat_back_left", n"seat_back_right", n"seat_front_left"];
        for seat in seats {
            if !VehicleComponent.IsSlotOccupied(this.GetGameInstance(), vehicleId, seat) && !this.IsSeatTaken(seat) {
                let mountData = new MountEventData();
                mountData.slotName = seat;
                mountData.mountParentEntityId = vehicleId;
                mountData.isInstant = true;
                mountData.ignoreHLS = true;

                let evt = new MountAIEvent();
                evt.name = n"Mount";
                evt.data = mountData;
                extra.entity.QueueEvent(evt);

                extra.place = 1;
                extra.seat = seat;
                return true;
            }
        }
        return false;
    }

    private func IsSeatTaken(seat: CName) -> Bool {
        for extra in this.m_extras {
            if extra.place == 1 && Equals(extra.seat, seat) {
                return true;
            }
        }
        return false;
    }

    // The nearest free spot of the kind: sit while V sits, stand (with a gesture) otherwise.
    private func UseSpot(player: ref<PlayerPuppet>, extra: ref<CampaignExtra>, kind: Int32) -> Bool {
        let center = player.GetWorldPosition();
        let range = kind == 1 ? CampaignExtras.SeatRange() : CampaignExtras.StandSpotRange();
        let best: ref<CampaignSceneSpot>;
        let bestDistance = range;
        for spot in this.m_spots {
            if !spot.taken && spot.kind == kind {
                let distance = Vector4.Distance(spot.position, center);
                if distance <= bestDistance {
                    best = spot;
                    bestDistance = distance;
                }
            }
        }
        if !IsDefined(best) {
            return false;
        }
        best.taken = true;

        GameInstance.GetTeleportationFacility(this.GetGameInstance()).Teleport(extra.entity, best.position, Vector4.ToRotation(best.forward));

        let command = new AIUseWorkspotCommand();
        command.workspotNode = GameInstance.GetNetworkWorldSystem().NodeRefFromNumber(best.node);
        AIComponent.SendCommand(extra.entity as ScriptedPuppet, command);

        extra.command = command;
        extra.place = 2;
        return true;
    }

    // A half circle around V, facing the speaker (or V when nobody has spoken yet).
    private func StandBeside(player: ref<PlayerPuppet>, extra: ref<CampaignExtra>) -> Void {
        let center = player.GetWorldPosition();
        let toward = player.GetWorldForward();
        if IsDefined(this.m_speaker) {
            toward = Vector4.Normalize2D(this.m_speaker.GetWorldPosition() - center);
        }

        let angles = [110.0, -110.0, 150.0, -150.0, 70.0, -70.0];
        let angle = Deg2Rad(angles[extra.slot % ArraySize(angles)]);
        let radius = CampaignExtras.StandRadius() + Cast<Float>(extra.slot / ArraySize(angles)) * 0.8;
        let offset = new Vector4(toward.X * CosF(angle) - toward.Y * SinF(angle), toward.X * SinF(angle) + toward.Y * CosF(angle), 0.0, 0.0);
        let position = center + offset * radius;

        let lookAt = IsDefined(this.m_speaker) ? this.m_speaker.GetWorldPosition() : center;
        GameInstance.GetTeleportationFacility(this.GetGameInstance()).Teleport(extra.entity, position, Vector4.ToRotation(lookAt - position));
        extra.place = 3;
    }

    // ---- hand-placed poses (stage 6) ----

    private func UsePose(extra: ref<CampaignExtra>) -> Bool {
        let story = CampaignStory.Get();
        if !IsDefined(story) || !this.m_anchored {
            return false;
        }
        let poses = story.GetPoses(this.m_sceneKey);
        // "hide": nobody else in this scene (intimate scenes) - out of sight behind V.
        if ArraySize(poses) > 0 && Equals(poses[0], "hide") {
            extra.right = 0.0;
            extra.forward = -25.0;
            extra.up = 0.0;
            extra.yaw = 0.0;
            this.ApplyPose(extra);
            return true;
        }
        if extra.slot >= ArraySize(poses) {
            return false;
        }
        let f = StrSplit(poses[extra.slot], ":");
        if ArraySize(f) < 4 {
            return false;
        }
        extra.right = StringToFloat(f[0]);
        extra.forward = StringToFloat(f[1]);
        extra.up = StringToFloat(f[2]);
        extra.yaw = StringToFloat(f[3]);
        this.ApplyPose(extra);
        return true;
    }

    private func RightOf(forward: Vector4) -> Vector4 {
        return new Vector4(forward.Y, -forward.X, 0.0, 0.0);
    }

    private func ApplyPose(extra: ref<CampaignExtra>) -> Void {
        let forward = this.m_anchorForward;
        let position = this.m_anchor + this.RightOf(forward) * extra.right + forward * extra.forward + new Vector4(0.0, 0.0, extra.up, 0.0);
        let angle = Deg2Rad(extra.yaw);
        let facing = new Vector4(forward.X * CosF(angle) - forward.Y * SinF(angle), forward.X * SinF(angle) + forward.Y * CosF(angle), 0.0, 0.0);
        GameInstance.GetTeleportationFacility(this.GetGameInstance()).Teleport(extra.entity, position, Vector4.ToRotation(facing));
        extra.place = 4;
    }

    // Where an extra is now, relative to the anchor - whatever placed it.
    private func Measure(extra: ref<CampaignExtra>) -> Void {
        if extra.place == 4 || !IsDefined(extra.entity) {
            return;
        }
        let forward = this.m_anchorForward;
        let offset = extra.entity.GetWorldPosition() - this.m_anchor;
        extra.right = Vector4.Dot(offset, this.RightOf(forward));
        extra.forward = Vector4.Dot(offset, forward);
        extra.up = offset.Z;
        let facing = Vector4.Normalize2D(extra.entity.GetWorldForward());
        extra.yaw = Rad2Deg(AtanF(forward.X * facing.Y - forward.Y * facing.X, Vector4.Dot(forward, facing)));
    }

    public func IsActive() -> Bool = this.m_active
    public func SceneKey() -> String = this.m_sceneKey

    // "/coop move": nudges extra number slot (from 0) in V's frame.
    public func Nudge(slot: Int32, right: Float, forward: Float, up: Float, yaw: Float) -> Bool {
        if !this.m_active || !this.m_anchored {
            return false;
        }
        for extra in this.m_extras {
            if extra.slot == slot && extra.place != 1 && IsDefined(extra.entity) {
                this.Measure(extra);
                if extra.place == 2 {
                    AIComponent.CancelCommand(extra.entity as ScriptedPuppet, extra.command);
                    GameInstance.GetWorkspotSystem(this.GetGameInstance()).StopNpcInWorkspot(extra.entity);
                }
                extra.right += right;
                extra.forward += forward;
                extra.up += up;
                extra.yaw += yaw;
                this.ApplyPose(extra);
                return true;
            }
        }
        return false;
    }

    // Every extra's pose relative to V, in slot order, as CampaignStory stores them.
    // A slot nobody holds right now (a player left) is "-": no pose, placed automatically.
    public func DescribePoses() -> String {
        let last = -1;
        for extra in this.m_extras {
            last = Max(last, extra.slot);
        }
        let out = "";
        let slot = 0;
        while slot <= last {
            let pose = "-";
            for extra in this.m_extras {
                if extra.slot == slot {
                    this.Measure(extra);
                    pose = s"\(FloatToStringPrec(extra.right, 2)):\(FloatToStringPrec(extra.forward, 2)):\(FloatToStringPrec(extra.up, 2)):\(FloatToStringPrec(extra.yaw, 0))";
                }
            }
            if slot > 0 {
                out += "|";
            }
            out += pose;
            slot += 1;
        }
        return out;
    }

    // ---- spots and releasing ----

    private func CollectSpots(player: ref<PlayerPuppet>) -> Void {
        ArrayClear(this.m_spots);
        let network = GameInstance.GetNetworkWorldSystem();
        let center = player.GetWorldPosition();
        for sector in this.m_sectors {
            if IsDefined(sector) {
                let found = network.FindSceneSpots(sector, center, CampaignExtras.SeatRange());
                if StrLen(found) > 0 {
                    for entry in StrSplit(found, ";") {
                        this.AddSpot(entry, center);
                    }
                }
            }
        }
        LogChannel(n"DEBUG", s"[Campaign] scene extras: \(ArraySize(this.m_spots)) free spots near V");
    }

    private func AddSpot(entry: String, center: Vector4) -> Void {
        let parts = StrSplit(entry, ":");
        if ArraySize(parts) != 7 {
            return;
        }
        let spot = new CampaignSceneSpot();
        spot.node = StringToUint64(parts[0]);
        spot.position = new Vector4(StringToFloat(parts[1]), StringToFloat(parts[2]), StringToFloat(parts[3]), 1.0);
        spot.forward = new Vector4(StringToFloat(parts[4]), StringToFloat(parts[5]), 0.0, 0.0);
        spot.kind = StringToInt(parts[6]);
        spot.taken = Vector4.Distance(spot.position, center) < CampaignExtras.OwnSpotRange();
        ArrayPush(this.m_spots, spot);
    }

    // The lowest number no extra has: someone leaving does not shift the others' poses.
    private func FreeSlot() -> Int32 {
        let slot = 0;
        while this.HasSlot(slot) {
            slot += 1;
        }
        return slot;
    }

    private func HasSlot(slot: Int32) -> Bool {
        for extra in this.m_extras {
            if extra.slot == slot {
                return true;
            }
        }
        return false;
    }

    private func Has(id: EntityID) -> Bool {
        for extra in this.m_extras {
            if extra.id == id {
                return true;
            }
        }
        return false;
    }

    // Players who left: their character is gone.
    private func ForgetGone() -> Void {
        let i = ArraySize(this.m_extras) - 1;
        while i >= 0 {
            if !IsDefined(this.m_extras[i].entity) {
                GameInstance.GetNetworkWorldSystem().SetPuppetHeld(this.m_extras[i].id, false);
                ArrayErase(this.m_extras, i);
            }
            i -= 1;
        }
    }

    private func ReleaseAll() -> Void {
        let network = GameInstance.GetNetworkWorldSystem();
        for extra in this.m_extras {
            let puppet = extra.entity;
            if IsDefined(puppet) {
                if extra.place == 1 {
                    let exitEvent = new AIEvent();
                    exitEvent.name = n"ExitVehicle";
                    puppet.QueueEvent(exitEvent);
                }
                if extra.place == 2 {
                    AIComponent.CancelCommand(puppet as ScriptedPuppet, extra.command);
                    GameInstance.GetWorkspotSystem(this.GetGameInstance()).StopNpcInWorkspot(puppet);
                }
            }
            if IsDefined(network) {
                network.SetPuppetHeld(extra.id, false);
            }
        }
        ArrayClear(this.m_extras);
        for spot in this.m_spots {
            spot.taken = false;
        }
    }
}

// Who is speaking: extras standing beside V turn to them.
@wrapMethod(BaseSubtitlesGameController)
private final func SpawnDialogLine(const lineData: script_ref<scnDialogLineData>) -> Void {
    let extras = CampaignExtras.Get();
    if IsDefined(extras) {
        extras.OnSpeaker(Deref(lineData).speaker);
    }
    wrappedMethod(lineData);
}
