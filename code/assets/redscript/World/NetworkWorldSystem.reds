module CyberpunkMP.World

import Codeware.*
import CyberpunkMP.*

public native class NetworkWorldSystem extends IGameSystem {
    public native func Connect() -> Void;
    public native func Disconnect() -> Void;
    public native func IsEnabled() -> Bool;
    public native func SetInGame(inGame: Bool) -> Void;
    public native func IsConnected() -> Bool;
    public native func GetUsername() -> String;
    // Character creator state as base64; empty when no creator state exists.
    public native func ExportCustomizationState() -> String;
    // Into the creator's current state: call InitializeState() before, FinalizeState() after.
    public native func ImportCustomizationState(data: String) -> Bool;
    public native func TweakDBIDFromNumber(value: Uint64) -> TweakDBID;
    // Campaign dialog votes: hold back the host's confirm presses while the players vote,
    // count them, then pick the winner by key presses (steps < 0 = up, then confirm).
    public native func SetChoiceLock(locked: Bool) -> Void;
    public native func TakeBlockedChoiceConfirms() -> Int32;
    public native func InjectChoice(steps: Int32) -> Bool;
    // Campaign scenes: the host records the quest nodes players see or hear (mode 1), guests
    // run the same nodes (mode 2); 0 = off.
    public native func SetQuestMirror(mode: Int32) -> Void;
    public native func TakeQuestNodes() -> String;
    public native func ReplayQuestNodes(entries: String) -> Void;
    // The scene that started last, the same key in every game (campaign scene poses).
    public native func GetSceneKey() -> String;
    // Opens the Steam overlay's invite dialog for this server; returns the address friends
    // get, empty without Steam.
    public native func OpenSteamInvite() -> String;
    // Checks the client's hand-mapped engine layouts against this game ("/coop selfcheck");
    // returns a summary, details go to CyberpunkMP.log.
    public native func RunSelfCheck(player: ref<GameObject>, vehicle: ref<GameObject>) -> String;
    // Starts the bundled server on this computer, connects to it and lets Steam friends in
    // through the Steam tunnel. Disconnect() ends it.
    public native func HostCampaign() -> Bool;
    // "" when not hosting; otherwise how starting the server goes, or what went wrong.
    public native func GetHostStatus() -> String;
    // Other players' characters near the scene spot (anchor, facing forward) stand beside it.
    public native func SetSceneSpacing(enabled: Bool, anchor: Vector4, forward: Vector4) -> Void;
    // A puppet placed by the local scene (seat, chair, spot) stops following its player.
    public native func SetPuppetHeld(entity: EntityID, held: Bool) -> Void;
    // While a scene runs, getting into its car is not sent (every game has its own copy).
    public native func SetVehicleSyncPaused(paused: Bool) -> Void;
    // Free places near a scene in a loaded sector: ';'-separated "node:x:y:z:fx:fy:kind"
    // (kind 1 = sit, 2 = stand with an idle gesture).
    public native func FindSceneSpots(sector: ref<worldStreamingSector>, center: Vector4, radius: Float) -> String;
    public native func NodeRefFromNumber(value: Uint64) -> NodeRef;
    public native func GetEntityIdByServerId(serverId: Uint64) -> EntityID;
    public native func GetAppearanceSystem() -> ref<AppearanceSystem>;
    public native func GetChatSystem() -> ref<ChatSystem>;
    public native func GetInterpolationSystem() -> ref<InterpolationSystem>;
    public native func GetVehicleSystem() -> ref<VehicleSystem>;

    public func OnConnected() -> Void {
        // let evt: ref<ConnectedToServer>;
        // evt.m_connected = true;
        // GameInstance.GetUISystem(GetGameInstance()).QueueEvent(evt);
        
        let blackboardSystem: ref<BlackboardSystem> = GameInstance.GetBlackboardSystem(GetGameInstance());
        let blackboard: ref<IBlackboard> = blackboardSystem.Get(GetAllBlackboardDefs().UIGameData);
        blackboard.SetBool(GetAllBlackboardDefs().UIGameData.UIMultiplayerConnectedToServer, true, true);
    }

    public func OnDisconnected(reason: Uint32) -> Void {
        // let evt: ref<ConnectedToServer>;
        // evt.m_connected = true;
        // GameInstance.GetUISystem(GetGameInstance()).QueueEvent(evt);
        
        let blackboardSystem: ref<BlackboardSystem> = GameInstance.GetBlackboardSystem(GetGameInstance());
        let blackboard: ref<IBlackboard> = blackboardSystem.Get(GetAllBlackboardDefs().UIGameData);
        blackboard.SetBool(GetAllBlackboardDefs().UIGameData.UIMultiplayerConnectedToServer, false, true);
    }

    public func CreatePuppet(position: Vector4, rotation: Quaternion, isMale: Bool) -> EntityID {
        let npcSpec = new DynamicEntitySpec();

        if isMale {
            npcSpec.recordID = t"Character.MaMuppet";
        } else {
            npcSpec.recordID = t"Character.WaMuppet";
            // npcSpec.recordID = t"Character.Panam";
        }
        npcSpec.alwaysSpawned = true;
        npcSpec.position = position;
        npcSpec.orientation = rotation;
        npcSpec.persistState = false;
        npcSpec.persistSpawn = false;
        npcSpec.tags = [n"CyberpunkMP.Puppet"];


        return GameInstance.GetDynamicEntitySystem().CreateEntity(npcSpec);
    }

    public func DeletePuppet(entityId: EntityID) {
        GameInstance.GetDynamicEntitySystem().DeleteEntity(entityId);
    }
}

@addMethod(GameInstance)
public static native func GetNetworkWorldSystem() -> ref<NetworkWorldSystem>