module CyberpunkMP.Plugins

import CyberpunkMP.*
import CyberpunkMP.World.*

// Campaign co-op, stage 5: NPCs and combat.
//
// Every game runs its own copy of each enemy (QuestMirror replays the quest nodes that spawn
// them) with its own AI, so each player is fought by their own copy and damage to a player
// stays in that player's game. What has to agree is how hurt each enemy is and whether it is
// dead:
// - the host reports its NPCs that matter (hurt, dead, fighting, hostile): key, record,
//   position, health per mille, state. Guests bind each one to their own copy - the same
//   static EntityID, or the nearest unbound NPC of the same record - and spawn a stand-in
//   for a hostile one they do not have.
// - guests report their hits on bound NPCs (percent of max health, or the kill), the host's
//   game applies them. Health only ever goes down to the host's value on a guest, so the
//   guest's own hit feedback is not undone; a kill anywhere is final.
//
// Players: while someone else is in the world, V cannot die (Immortal). At zero health V is
// downed - crouched, no weapons, invulnerable - until a teammate stands next to them for a
// few seconds; nobody within 45 s and V dies (a guest comes back next to the host). When
// everyone is down the server kills the host's V for real.

public class CampaignNpc {
    public let id: EntityID;
    public let record: TweakDBID;
    // Guest: the host's key this NPC stands for.
    public let key: Uint64;
    public let bound: Bool;
    public let proxy: Bool;
    public let lastSeen: Float;
    public let lastLocalHit: Float;
    public let reportedKill: Bool;
    // Host: what was sent last (-1 = never).
    public let sentHealth: Int32;
    public let sentState: Int32;
    // Guest: hit damage not sent yet, per mille of max health.
    public let pendingHit: Int32;
}

// A stand-in a guest asked for and is still spawning.
public class CampaignNpcProxy {
    public let key: Uint64;
    public let id: EntityID;
}

public class CampaignHealthListener extends ScriptStatPoolsListener {
    public func OnStatPoolValueChanged(oldValue: Float, newValue: Float, percToPoints: Float) -> Void {
        let combat = CampaignCombat.Get();
        if IsDefined(combat) {
            combat.OnPlayerHealth(newValue);
        }
    }
}

public class CampaignCombatPoll extends DelayCallback {
    public func Call() -> Void {
        let combat = CampaignCombat.Get();
        if IsDefined(combat) {
            combat.OnPoll();
        }
    }
}

public class CampaignCombat extends ScriptableSystem {
    public static func PollSeconds() -> Float = 0.5
    // Every few seconds the host resends every NPC that matters near a player.
    public static func FullSeconds() -> Float = 3.0
    public static func NearRange() -> Float = 150.0
    // A guest's NPC of the same record this close counts as the host's.
    public static func MatchRange() -> Float = 12.0
    // A guest spawns a stand-in for a hostile host NPC it lacks within this range.
    public static func ProxyRange() -> Float = 80.0
    // A guest's copy this far from the host's is moved over.
    public static func DriftRange() -> Float = 30.0
    public static func ReviveRange() -> Float = 2.5
    public static func ReviveSeconds() -> Float = 4.0
    // Player health (percent) at which V is downed.
    public static func DownedHealth() -> Float = 1.0
    // A downed player nobody revives dies after this long.
    public static func BleedOutSeconds() -> Float = 45.0

    private let m_npcs: array<ref<CampaignNpc>>;
    private let m_proxies: array<ref<CampaignNpcProxy>>;
    private let m_polling: Bool;
    private let m_lastFull: Float;

    private let m_coopPlayers: Int32;
    private let m_protected: Bool;
    private let m_protectedId: EntityID;
    private let m_healthListener: ref<CampaignHealthListener>;
    private let m_downed: Bool;
    private let m_downedPuppets: array<Uint64>;
    private let m_reviveTarget: Uint64;
    private let m_reviveProgress: Float;
    private let m_bleedOutLeft: Float;
    private let m_bledOut: Bool;

    public static func Get() -> ref<CampaignCombat> {
        let container = GameInstance.GetScriptableSystemsContainer(GetGameInstance());
        return container.Get(n"CyberpunkMP.Plugins.CampaignCombat") as CampaignCombat;
    }

    private func OnAttach() -> Void {
        if !this.m_polling {
            this.m_polling = true;
            GameInstance.GetDelaySystem(this.GetGameInstance()).DelayCallback(new CampaignCombatPoll(), CampaignCombat.PollSeconds(), false);
        }
    }

    private func OnDetach() -> Void {
        this.Unprotect();
        ArrayClear(this.m_npcs);
        ArrayClear(this.m_proxies);
        ArrayClear(this.m_downedPuppets);
        this.m_downed = false;
        this.m_polling = false;
    }

    private func Now() -> Float {
        return EngineTime.ToFloat(GameInstance.GetSimTime(this.GetGameInstance()));
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

    // ---- NPC registry (every attached NPC that is not crowd or another player) ----

    public func Track(npc: ref<NPCPuppet>) -> Void {
        if !IsDefined(npc) || npc.IsCrowd() {
            return;
        }
        let id = npc.GetEntityID();
        let entities = GameInstance.GetDynamicEntitySystem();
        if entities.IsManaged(id) && entities.IsTagged(id, n"CyberpunkMP.Puppet") {
            return;
        }
        if IsDefined(this.Find(id)) {
            return;
        }
        let entry = new CampaignNpc();
        entry.id = id;
        entry.record = npc.GetRecord().GetID();
        entry.sentHealth = -1;
        entry.sentState = -1;
        entry.proxy = entities.IsManaged(id) && entities.IsTagged(id, n"CampaignCoop.Proxy");
        ArrayPush(this.m_npcs, entry);
    }

    public func Untrack(id: EntityID) -> Void {
        let i = 0;
        while i < ArraySize(this.m_npcs) {
            if this.m_npcs[i].id == id {
                ArrayErase(this.m_npcs, i);
                return;
            }
            i += 1;
        }
    }

    private func Find(id: EntityID) -> ref<CampaignNpc> {
        for entry in this.m_npcs {
            if entry.id == id {
                return entry;
            }
        }
        return null;
    }

    private func FindBound(key: Uint64) -> ref<CampaignNpc> {
        for entry in this.m_npcs {
            if entry.bound && Equals(entry.key, key) {
                return entry;
            }
        }
        return null;
    }

    private func Puppet(id: EntityID) -> ref<NPCPuppet> {
        return GameInstance.FindEntityByID(this.GetGameInstance(), id) as NPCPuppet;
    }

    // 0 alive, 1 dead, 2 defeated.
    private static func StateOf(npc: ref<NPCPuppet>) -> Int32 {
        if npc.IsDead() {
            return 1;
        }
        if ScriptedPuppet.IsDefeated(npc) {
            return 2;
        }
        return 0;
    }

    private func HealthOf(id: EntityID) -> Int32 {
        return RoundF(GameInstance.GetStatPoolsSystem(this.GetGameInstance()).GetStatPoolValue(Cast<StatsObjectID>(id), gamedataStatPoolType.Health, true) * 10.0);
    }

    // ---- poll ----

    public func OnPoll() -> Void {
        if !this.m_polling {
            return;
        }
        if this.IsHost() {
            this.ReportNpcs();
        } else {
            if this.IsGuest() {
                this.ReportHits();
                this.CleanUpProxies();
            }
        }
        this.UpdateProtection();
        this.UpdateBleedOut();
        this.UpdateRevive();
        GameInstance.GetDelaySystem(this.GetGameInstance()).DelayCallback(new CampaignCombatPoll(), CampaignCombat.PollSeconds(), false);
    }

    // ---- host: report NPCs ----

    private func ReportNpcs() -> Void {
        let player = this.Player();
        if !IsDefined(player) {
            return;
        }
        let now = this.Now();
        let full = now - this.m_lastFull >= CampaignCombat.FullSeconds();
        if full {
            this.m_lastFull = now;
        }

        // Where players are: the host and every other player's character.
        let centers: array<Vector4>;
        ArrayPush(centers, player.GetWorldPosition());
        for puppet in GameInstance.GetDynamicEntitySystem().GetTagged(n"CyberpunkMP.Puppet") {
            ArrayPush(centers, puppet.GetWorldPosition());
        }

        let batch = "";
        for entry in this.m_npcs {
            let npc = this.Puppet(entry.id);
            if IsDefined(npc) {
                let state = CampaignCombat.StateOf(npc);
                let health = state > 0 ? 0 : this.HealthOf(entry.id);
                let hostile = Equals(GameObject.GetAttitudeTowards(npc, player), EAIAttitude.AIA_Hostile);
                let matters = state > 0 || health < 1000 || hostile || npc.IsPuppetInCombat();
                let changed = health != entry.sentHealth || state != entry.sentState;
                if matters && (changed || (full && CampaignCombat.IsNear(npc.GetWorldPosition(), centers))) {
                    entry.sentHealth = health;
                    entry.sentState = state;
                    let item = CampaignCombat.Entry(npc, entry, health, state, hostile);
                    if StrLen(batch) + StrLen(item) + 1 > CampaignBatch.MaxLength() {
                        CampaignServer.ReportNpcs(batch);
                        batch = "";
                    }
                    if StrLen(batch) > 0 {
                        batch += ",";
                    }
                    batch += item;
                }
            }
        }
        if StrLen(batch) > 0 {
            CampaignServer.ReportNpcs(batch);
        }
    }

    private static func IsNear(position: Vector4, centers: array<Vector4>) -> Bool {
        for center in centers {
            if Vector4.Distance(position, center) <= CampaignCombat.NearRange() {
                return true;
            }
        }
        return false;
    }

    // key;static;record;x;y;z;health;state;hostile
    private static func Entry(npc: ref<NPCPuppet>, entry: ref<CampaignNpc>, health: Int32, state: Int32, hostile: Bool) -> String {
        let id = entry.id;
        let position = npc.GetWorldPosition();
        return s"\(EntityID.ToHash(id));\(EntityID.IsStatic(id) ? 1 : 0);\(TDBID.ToNumber(entry.record));"
            + s"\(FloatToStringPrec(position.X, 1));\(FloatToStringPrec(position.Y, 1));\(FloatToStringPrec(position.Z, 1));"
            + s"\(health);\(state);\(hostile ? 1 : 0)";
    }

    // ---- host: apply guests' hits ----

    // key:damage per mille:killed
    public func ApplyNpcHits(entries: String) -> Void {
        if !this.IsHost() {
            return;
        }
        let player = this.Player();
        let pools = GameInstance.GetStatPoolsSystem(this.GetGameInstance());
        for item in StrSplit(entries, ",") {
            let fields = StrSplit(item, ":");
            if ArraySize(fields) >= 3 {
                let id = EntityID.FromHash(StringToUint64(fields[0]));
                let npc = this.Puppet(id);
                if IsDefined(npc) && CampaignCombat.StateOf(npc) == 0 {
                    if StringToInt(fields[2]) != 0 {
                        npc.Kill(player);
                    } else {
                        let damage = Cast<Float>(StringToInt(fields[1])) / 10.0;
                        pools.RequestChangingStatPoolValue(Cast<StatsObjectID>(id), gamedataStatPoolType.Health, -damage, player, false, true);
                    }
                }
            }
        }
    }

    // ---- guest: apply the host's NPCs ----

    public func ApplyNpcs(entries: String) -> Void {
        if !this.IsGuest() {
            return;
        }
        let player = this.Player();
        if !IsDefined(player) {
            return;
        }
        let now = this.Now();
        for item in StrSplit(entries, ",") {
            let f = StrSplit(item, ";");
            if ArraySize(f) >= 9 {
                let key = StringToUint64(f[0]);
                let isStatic = StringToInt(f[1]) != 0;
                let record = GameInstance.GetNetworkWorldSystem().TweakDBIDFromNumber(StringToUint64(f[2]));
                let position = new Vector4(StringToFloat(f[3]), StringToFloat(f[4]), StringToFloat(f[5]), 1.0);
                let health = StringToInt(f[6]);
                let state = StringToInt(f[7]);
                let hostile = StringToInt(f[8]) != 0;

                let entry = this.Bind(key, isStatic, record, position);
                if IsDefined(entry) {
                    entry.lastSeen = now;
                    this.ApplyNpc(player, entry, position, health, state, now);
                } else {
                    if hostile && state == 0 && Vector4.Distance(position, player.GetWorldPosition()) <= CampaignCombat.ProxyRange() {
                        this.SpawnProxy(key, record, position);
                    }
                }
            }
        }
    }

    private func Bind(key: Uint64, isStatic: Bool, record: TweakDBID, position: Vector4) -> ref<CampaignNpc> {
        let entry = this.FindBound(key);
        if IsDefined(entry) {
            return entry;
        }

        // Placed and community NPCs have the same EntityID in every game.
        if isStatic {
            entry = this.Find(EntityID.FromHash(key));
        }

        // A stand-in this guest spawned for the key.
        if !IsDefined(entry) {
            for proxy in this.m_proxies {
                if Equals(proxy.key, key) {
                    entry = this.Find(proxy.id);
                }
            }
        }

        // The same character spawned by the mirrored quest node, close to where the host has it.
        if !IsDefined(entry) {
            let best = CampaignCombat.MatchRange();
            for candidate in this.m_npcs {
                if !candidate.bound && !candidate.proxy && candidate.record == record {
                    let npc = this.Puppet(candidate.id);
                    if IsDefined(npc) && CampaignCombat.StateOf(npc) == 0 {
                        let distance = Vector4.Distance(npc.GetWorldPosition(), position);
                        if distance <= best {
                            best = distance;
                            entry = candidate;
                        }
                    }
                }
            }
        }

        if IsDefined(entry) {
            entry.key = key;
            entry.bound = true;
        }
        return entry;
    }

    private func ApplyNpc(player: ref<PlayerPuppet>, entry: ref<CampaignNpc>, position: Vector4, health: Int32, state: Int32, now: Float) -> Void {
        let npc = this.Puppet(entry.id);
        if !IsDefined(npc) || CampaignCombat.StateOf(npc) != 0 {
            return;
        }

        if state != 0 {
            // Killing a hostile with the local V as instigator shares the kill (XP, loot) in
            // every game; anyone else dies without one, so no crime is reported.
            let instigator: ref<GameObject>;
            if Equals(GameObject.GetAttitudeTowards(npc, player), EAIAttitude.AIA_Hostile) {
                instigator = player;
            }
            if state == 2 {
                npc.SoftKill(instigator);
            } else {
                npc.Kill(instigator);
            }
            return;
        }

        // Down to the host's health at once; back up (healing) only once this game's own hits
        // have had time to reach the host.
        let local = this.HealthOf(entry.id);
        if health < local - 10 || (health > local + 50 && now - entry.lastLocalHit > 3.0) {
            GameInstance.GetStatPoolsSystem(this.GetGameInstance()).RequestSettingStatPoolValue(Cast<StatsObjectID>(entry.id), gamedataStatPoolType.Health, Cast<Float>(health) / 10.0, null, true);
        }

        // A copy that wandered off (different path, fell behind a door) is put back.
        if Vector4.Distance(npc.GetWorldPosition(), position) > CampaignCombat.DriftRange() {
            GameInstance.GetTeleportationFacility(this.GetGameInstance()).Teleport(npc, position, npc.GetWorldOrientation().ToEulerAngles());
        }
    }

    private func SpawnProxy(key: Uint64, record: TweakDBID, position: Vector4) -> Void {
        for proxy in this.m_proxies {
            if Equals(proxy.key, key) {
                return;
            }
        }
        let spec = new DynamicEntitySpec();
        spec.recordID = record;
        spec.position = position;
        spec.persistState = false;
        spec.persistSpawn = false;
        spec.alwaysSpawned = true;
        spec.tags = [n"CampaignCoop.Proxy"];

        let proxy = new CampaignNpcProxy();
        proxy.key = key;
        proxy.id = GameInstance.GetDynamicEntitySystem().CreateEntity(spec);
        ArrayPush(this.m_proxies, proxy);
        LogChannel(n"DEBUG", s"[Campaign] stand-in for the host's NPC \(key) (\(TDBID.ToStringDEBUG(record)))");
    }

    // Stand-ins the host stopped reporting (streamed out, gone) and long-dead ones go away.
    private func CleanUpProxies() -> Void {
        let now = this.Now();
        let entities = GameInstance.GetDynamicEntitySystem();
        let i = 0;
        while i < ArraySize(this.m_proxies) {
            let proxy = this.m_proxies[i];
            let entry = this.Find(proxy.id);
            let stale = false;
            if IsDefined(entry) {
                stale = now - entry.lastSeen > 15.0;
            } else {
                stale = !entities.IsSpawning(proxy.id) && !entities.IsSpawned(proxy.id);
            }
            if stale {
                entities.DeleteEntity(proxy.id);
                ArrayErase(this.m_proxies, i);
            } else {
                i += 1;
            }
        }
    }

    // ---- guest: report hits ----

    public func OnNpcHit(npc: ref<NPCPuppet>, evt: ref<gameHitEvent>) -> Void {
        if !this.IsGuest() || !IsDefined(evt) || !IsDefined(evt.attackData) {
            return;
        }
        let entry = this.Find(npc.GetEntityID());
        if !IsDefined(entry) || !entry.bound {
            return;
        }
        let player = this.Player();
        let instigator = evt.attackData.GetInstigator();
        if !IsDefined(player) || !IsDefined(instigator) || instigator.GetEntityID() != player.GetEntityID() {
            return;
        }
        entry.lastLocalHit = this.Now();
        if !IsDefined(evt.attackComputed) {
            return;
        }
        let pools = GameInstance.GetStatPoolsSystem(this.GetGameInstance());
        let max = pools.GetStatPoolMaxPointValue(Cast<StatsObjectID>(entry.id), gamedataStatPoolType.Health);
        if max > 0.0 {
            let damage = evt.attackComputed.GetTotalAttackValue(gamedataStatPoolType.Health);
            entry.pendingHit += RoundF(damage / max * 1000.0);
        }
    }

    private func ReportHits() -> Void {
        let now = this.Now();
        let batch = "";
        for entry in this.m_npcs {
            if entry.bound {
                let npc = this.Puppet(entry.id);
                let killed = false;
                if IsDefined(npc) && !entry.reportedKill && CampaignCombat.StateOf(npc) != 0 && now - entry.lastLocalHit < 3.0 {
                    killed = true;
                    entry.reportedKill = true;
                }
                if killed || entry.pendingHit > 0 {
                    let item = s"\(entry.key):\(entry.pendingHit):\(killed ? 1 : 0)";
                    entry.pendingHit = 0;
                    if StrLen(batch) + StrLen(item) + 1 > CampaignBatch.MaxLength() {
                        CampaignServer.ReportNpcHits(batch);
                        batch = "";
                    }
                    if StrLen(batch) > 0 {
                        batch += ",";
                    }
                    batch += item;
                }
            }
        }
        if StrLen(batch) > 0 {
            CampaignServer.ReportNpcHits(batch);
        }
    }

    // ---- players: downed and revived ----

    public func SetCoopPlayers(count: Int32) -> Void {
        this.m_coopPlayers = count;
        this.UpdateProtection();
    }

    // Immortal while someone else is in the world; the health listener notices zero health.
    private func UpdateProtection() -> Void {
        let player = this.Player();
        let wanted = this.m_coopPlayers >= 2 && IsDefined(player) && !player.IsDead();
        if wanted && this.m_protected && this.m_protectedId != player.GetEntityID() {
            this.Unprotect();
        }
        if Equals(wanted, this.m_protected) {
            return;
        }
        if !wanted {
            this.Unprotect();
            return;
        }
        let id = player.GetEntityID();
        GameInstance.GetGodModeSystem(this.GetGameInstance()).AddGodMode(id, gameGodModeType.Immortal, n"CampaignCoop");
        this.m_healthListener = new CampaignHealthListener();
        GameInstance.GetStatPoolsSystem(this.GetGameInstance()).RequestRegisteringListener(Cast<StatsObjectID>(id), gamedataStatPoolType.Health, this.m_healthListener);
        this.m_protected = true;
        this.m_protectedId = id;
    }

    private func Unprotect() -> Void {
        if !this.m_protected {
            return;
        }
        let id = this.m_protectedId;
        GameInstance.GetGodModeSystem(this.GetGameInstance()).RemoveGodMode(id, gameGodModeType.Immortal, n"CampaignCoop");
        if IsDefined(this.m_healthListener) {
            GameInstance.GetStatPoolsSystem(this.GetGameInstance()).RequestUnregisteringListener(Cast<StatsObjectID>(id), gamedataStatPoolType.Health, this.m_healthListener);
        }
        this.m_healthListener = null;
        this.m_protected = false;
        // Alone again while down: the server revives, this only lifts the restrictions.
        if this.m_downed {
            this.GetUp();
        }
    }

    public func OnPlayerHealth(percent: Float) -> Void {
        if this.m_protected && !this.m_downed && percent <= CampaignCombat.DownedHealth() {
            this.GoDown();
        }
    }

    private func GoDown() -> Void {
        let player = this.Player();
        if !IsDefined(player) {
            return;
        }
        this.m_downed = true;
        this.m_bledOut = false;
        this.m_bleedOutLeft = CampaignCombat.BleedOutSeconds();
        GameInstance.GetGodModeSystem(this.GetGameInstance()).AddGodMode(player.GetEntityID(), gameGodModeType.Invulnerable, n"CampaignDowned");
        StatusEffectHelper.ApplyStatusEffect(player, t"GameplayRestriction.NoWeapons");
        StatusEffectHelper.ApplyStatusEffect(player, t"GameplayRestriction.ForceCrouch");
        StatusEffectHelper.ApplyStatusEffect(player, t"GameplayRestriction.NoJump");
        StatusEffectHelper.ApplyStatusEffect(player, t"GameplayRestriction.NoMovement");
        CampaignServer.ReportDowned(true);
        this.Message(s"You are down - a teammate can revive you (\(RoundF(this.m_bleedOutLeft)) s)");
        LogChannel(n"DEBUG", "[Campaign] downed");
    }

    // Nobody came in time: the host's V dies for real (death screen, the story reloads), a
    // guest's game would load its own save and leave the story, so a guest is brought back
    // next to the host instead (Respawn).
    private func UpdateBleedOut() -> Void {
        if !this.m_downed || this.m_bledOut {
            return;
        }
        this.m_bleedOutLeft -= CampaignCombat.PollSeconds();
        if this.m_bleedOutLeft > 0.0 {
            this.Message(s"You are down - a teammate can revive you (\(RoundF(this.m_bleedOutLeft)) s)");
            return;
        }
        this.m_bledOut = true;
        CampaignServer.ReportBledOut();
        if this.IsHost() {
            this.Die();
        } else {
            this.Message("You bled out");
        }
    }

    private func GetUp() -> Void {
        let player = this.Player();
        this.m_downed = false;
        this.m_bledOut = false;
        if !IsDefined(player) {
            return;
        }
        GameInstance.GetGodModeSystem(this.GetGameInstance()).RemoveGodMode(player.GetEntityID(), gameGodModeType.Invulnerable, n"CampaignDowned");
        StatusEffectHelper.RemoveStatusEffect(player, t"GameplayRestriction.NoWeapons");
        StatusEffectHelper.RemoveStatusEffect(player, t"GameplayRestriction.ForceCrouch");
        StatusEffectHelper.RemoveStatusEffect(player, t"GameplayRestriction.NoJump");
        StatusEffectHelper.RemoveStatusEffect(player, t"GameplayRestriction.NoMovement");
    }

    // A guest who bled out comes back next to the host.
    public func OnRespawn(x: Float, y: Float, z: Float, health: Float) -> Void {
        let player = this.Player();
        this.GetUp();
        if !IsDefined(player) {
            return;
        }
        GameInstance.GetStatPoolsSystem(this.GetGameInstance()).RequestSettingStatPoolValue(Cast<StatsObjectID>(player.GetEntityID()), gamedataStatPoolType.Health, health, null, true);
        GameInstance.GetTeleportationFacility(this.GetGameInstance()).Teleport(player, new Vector4(x + 1.5, y, z, 1.0), player.GetWorldOrientation().ToEulerAngles());
        this.Message("You died - back next to the host");
    }

    public func OnRevived(health: Float) -> Void {
        let player = this.Player();
        let wasDowned = this.m_downed;
        this.GetUp();
        if IsDefined(player) {
            GameInstance.GetStatPoolsSystem(this.GetGameInstance()).RequestSettingStatPoolValue(Cast<StatsObjectID>(player.GetEntityID()), gamedataStatPoolType.Health, health, null, true);
        }
        if wasDowned {
            this.Message("You are back on your feet");
        }
    }

    // Everyone is down: this (the host's) V dies for real and the game reloads.
    public func OnWipe() -> Void {
        LogChannel(n"DEBUG", "[Campaign] everyone is down - V dies");
        this.Die();
    }

    private func Die() -> Void {
        let player = this.Player();
        this.Unprotect();
        this.GetUp();
        if IsDefined(player) {
            GameInstance.GetStatPoolsSystem(this.GetGameInstance()).RequestSettingStatPoolMinValue(Cast<StatsObjectID>(player.GetEntityID()), gamedataStatPoolType.Health, player);
        }
    }

    // A downed teammate's character falls the way companions (Jackie, Panam) do and waits for
    // help; interpolation leaves it where it fell.
    public func OnPlayerDowned(puppetId: Uint64, downed: Bool) -> Void {
        ArrayRemove(this.m_downedPuppets, puppetId);
        if downed {
            ArrayPush(this.m_downedPuppets, puppetId);
            this.Message("A teammate is down - stand next to them to help");
        }
        let network = GameInstance.GetNetworkWorldSystem();
        let id = network.GetEntityIdByServerId(puppetId);
        let puppet = GameInstance.FindEntityByID(this.GetGameInstance(), id) as ScriptedPuppet;
        if !IsDefined(puppet) {
            return;
        }
        network.SetPuppetHeld(id, downed);
        if downed {
            StatusEffectHelper.ApplyStatusEffect(puppet, t"BaseStatusEffect.FollowerDefeatedStory");
        } else {
            StatusEffectHelper.RemoveStatusEffectsWithTag(puppet, n"FollowerDefeated");
        }
    }

    // Standing next to a downed teammate for a few seconds gets them up.
    private func UpdateRevive() -> Void {
        let player = this.Player();
        if this.m_downed || !IsDefined(player) || ArraySize(this.m_downedPuppets) == 0 {
            this.m_reviveProgress = 0.0;
            return;
        }
        let network = GameInstance.GetNetworkWorldSystem();
        let target = 0ul;
        for puppetId in this.m_downedPuppets {
            let puppet = GameInstance.FindEntityByID(this.GetGameInstance(), network.GetEntityIdByServerId(puppetId)) as GameObject;
            if IsDefined(puppet) && Vector4.Distance(puppet.GetWorldPosition(), player.GetWorldPosition()) <= CampaignCombat.ReviveRange() {
                target = puppetId;
            }
        }
        if Equals(target, 0ul) {
            this.m_reviveProgress = 0.0;
            return;
        }
        if NotEquals(target, this.m_reviveTarget) {
            this.m_reviveTarget = target;
            this.m_reviveProgress = 0.0;
        }
        this.m_reviveProgress += CampaignCombat.PollSeconds();
        if this.m_reviveProgress >= CampaignCombat.ReviveSeconds() {
            CampaignServer.ReportRevive(target);
            this.m_reviveProgress = 0.0;
            this.Message("Teammate revived");
        } else {
            this.Message(s"Reviving... \(RoundF(this.m_reviveProgress / CampaignCombat.ReviveSeconds() * 100.0))%");
        }
    }

    private func Message(text: String) -> Void {
        let message: SimpleScreenMessage;
        message.isShown = true;
        message.duration = 3.0;
        message.message = text;
        message.isInstant = true;
        let notifications = GetAllBlackboardDefs().UI_Notifications;
        GameInstance.GetBlackboardSystem(this.GetGameInstance()).Get(notifications).SetVariant(notifications.OnscreenMessage, ToVariant(message), true);
    }
}

@wrapMethod(NPCPuppet)
protected cb func OnGameAttached() -> Bool {
    let result = wrappedMethod();
    let combat = CampaignCombat.Get();
    if IsDefined(combat) {
        combat.Track(this);
    }
    return result;
}

@wrapMethod(NPCPuppet)
protected cb func OnDetach() -> Bool {
    let combat = CampaignCombat.Get();
    if IsDefined(combat) {
        combat.Untrack(this.GetEntityID());
    }
    return wrappedMethod();
}

@wrapMethod(NPCPuppet)
protected cb func OnHit(evt: ref<gameHitEvent>) -> Bool {
    let combat = CampaignCombat.Get();
    if IsDefined(combat) {
        combat.OnNpcHit(this, evt);
    }
    return wrappedMethod(evt);
}
