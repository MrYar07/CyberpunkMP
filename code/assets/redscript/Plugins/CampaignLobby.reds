module CyberpunkMP.Plugins

import CyberpunkMP.*
import CyberpunkMP.World.*

// Campaign lobby: players connect at the main menu, the host picks a new campaign or one
// saved on the server, and everyone starts together. A new campaign opens with a vote on
// the lifepath (one prologue for everyone). Then the host starts the story as usual, and
// guests start the quest-free guest world (the Phantom Liberty standalone start, whose
// gamedef the mod replaces) with their own character, restored from the campaign save if
// they have one there.
//
// The server pushes the whole lobby as one string (LobbyState) on every change. This
// service keeps it, because it lives at the main menu as well as in the game - unlike the
// ScriptableSystems, which only exist with a world.

public class CampaignPlayerInfo {
    public let name: String;
    public let ready: Bool;
    public let inWorld: Bool;
}

public class CampaignReportCallback extends DelayCallback {
    public let game: GameInstance;

    public func Call() -> Void {
        CampaignLobby.Get().OnReportTimer(this.game);
    }
}

public class CampaignRestoreCallback extends DelayCallback {
    public let game: GameInstance;

    public func Call() -> Void {
        CampaignLobby.Get().RestoreCharacter(this.game);
    }
}

public class CampaignLobby extends ScriptableService {
    // How often a player's character is saved into the campaign while playing.
    public static func ReportSeconds() -> Float = 120.0

    // Long values (appearance, items) go to the server in pieces of this many characters.
    public static func PartLength() -> Int32 = 15000

    // ---- lobby state, as the server last sent it ----
    private let m_phase: String;
    private let m_mode: Int32;
    private let m_campaign: String;
    private let m_active: String;
    private let m_lifePath: String;
    private let m_host: String;
    private let m_you: String;
    private let m_campaigns: array<String>;
    private let m_players: array<ref<CampaignPlayerInfo>>;
    private let m_connecting: Bool;

    // ---- the running vote ----
    private let m_voteId: Uint32;
    private let m_voteKind: String;
    private let m_voteOptions: array<String>;
    private let m_voteCounts: array<Int32>;
    private let m_voteSeconds: Int32;
    private let m_myVote: Int32;
    private let m_voteOpen: Bool;

    // ---- starting the game ----
    private let m_menu: wref<SingleplayerMenuGameController>;
    private let m_beginPending: Bool;
    private let m_beginMode: Int32;
    private let m_beginIsHost: Bool;
    private let m_creating: Bool;
    private let m_characterKeys: array<String>;
    private let m_characterValues: array<String>;
    private let m_restorePending: Bool;

    // ---- in the world ----
    private let m_inWorld: Bool;
    private let m_worldReported: Bool;
    private let m_reportArmed: Bool;

    public static func Get() -> ref<CampaignLobby> {
        return GameInstance.GetScriptableServiceContainer().GetService(n"CyberpunkMP.Plugins.CampaignLobby") as CampaignLobby;
    }

    public static func IsConnected() -> Bool {
        let network = GameInstance.GetNetworkWorldSystem();
        return IsDefined(network) && network.IsConnected();
    }

    private cb func OnLoad() {
        this.m_myVote = -1;
    }

    // ---- server messages ----

    public func OnState(state: String) -> Void {
        this.m_connecting = false;
        ArrayClear(this.m_campaigns);
        ArrayClear(this.m_players);

        for field in StrSplit(state, ";") {
            let key: String;
            let value: String;
            if StrSplitFirst(field, "=", key, value) {
                switch key {
                    case "phase": this.m_phase = value; break;
                    case "mode": this.m_mode = StringToInt(value); break;
                    case "campaign": this.m_campaign = value; break;
                    case "active": this.m_active = value; break;
                    case "lifepath": this.m_lifePath = value; break;
                    case "host": this.m_host = value; break;
                    case "you": this.m_you = value; break;
                    case "campaigns": this.ParseCampaigns(value); break;
                    case "players": this.ParsePlayers(value); break;
                    default: break;
                }
            }
        }

        // Connected from inside the world (the HUD's server list) rather than the lobby.
        if this.m_inWorld && !this.m_worldReported {
            this.ReportWorld();
        }

        this.RefreshMenu();
    }

    private func ParseCampaigns(value: String) -> Void {
        for name in StrSplit(value, "/") {
            if StrLen(name) > 0 {
                ArrayPush(this.m_campaigns, name);
            }
        }
    }

    private func ParsePlayers(value: String) -> Void {
        for entry in StrSplit(value, "/") {
            let parts = StrSplit(entry, ":");
            if ArraySize(parts) >= 3 {
                let player = new CampaignPlayerInfo();
                player.name = parts[0];
                player.ready = Equals(parts[1], "1");
                player.inWorld = Equals(parts[2], "1");
                ArrayPush(this.m_players, player);
            }
        }
    }

    public func OnBegin(mode: Int32, lifePath: String, isHost: Bool) -> Void {
        LogChannel(n"DEBUG", s"[Campaign] lobby says go: mode \(mode), lifepath '\(lifePath)', host \(isHost)");
        this.m_lifePath = lifePath;
        this.m_beginMode = mode;
        this.m_beginIsHost = isHost;
        this.m_beginPending = true;
        this.RunPendingBegin();
    }

    public func OnVoteOpened(voteId: Uint32, kind: String, options: String, seconds: Int32) -> Void {
        this.m_voteId = voteId;
        this.m_voteKind = kind;
        this.m_voteOptions = StrSplit(options, "|");
        this.m_voteSeconds = seconds;
        this.m_myVote = -1;
        this.m_voteOpen = true;
        ArrayClear(this.m_voteCounts);
        for option in this.m_voteOptions {
            ArrayPush(this.m_voteCounts, 0);
        }
        this.RefreshMenu();
    }

    public func OnVoteTally(voteId: Uint32, counts: String) -> Void {
        if voteId != this.m_voteId {
            return;
        }
        ArrayClear(this.m_voteCounts);
        for count in StrSplit(counts, ",") {
            ArrayPush(this.m_voteCounts, StringToInt(count));
        }
        this.RefreshMenu();
    }

    public func OnVoteClosed(voteId: Uint32, winner: Int32) -> Void {
        if voteId != this.m_voteId {
            return;
        }
        this.m_voteOpen = false;
        if winner >= 0 && winner < ArraySize(this.m_voteOptions) {
            LogChannel(n"DEBUG", s"[Campaign] vote '\(this.m_voteKind)' won by \(this.m_voteOptions[winner])");
        }
        this.RefreshMenu();
    }

    // Parts with the same key are joined: long values arrive in pieces.
    public func OnCharacterPart(key: String, value: String) -> Void {
        let i = 0;
        while i < ArraySize(this.m_characterKeys) {
            if Equals(this.m_characterKeys[i], key) {
                this.m_characterValues[i] += value;
                return;
            }
            i += 1;
        }
        ArrayPush(this.m_characterKeys, key);
        ArrayPush(this.m_characterValues, value);
    }

    public func OnCharacterDone(found: Bool) -> Void {
        LogChannel(n"DEBUG", s"[Campaign] saved character found: \(found)");
        if IsDefined(this.m_menu) {
            this.m_menu.CampaignStartGuest(found);
        } else {
            LogChannel(n"DEBUG", "[Campaign] no main menu to start the guest game from");
        }
    }

    // ---- main menu ----

    public func SetMenu(menu: ref<SingleplayerMenuGameController>) -> Void {
        this.m_menu = menu;
    }

    private func RefreshMenu() -> Void {
        if IsDefined(this.m_menu) {
            this.m_menu.CampaignRefresh();
        }
    }

    // The begin message can arrive while the main menu is not on screen; it then runs the
    // next time the menu is built.
    public func RunPendingBegin() -> Void {
        if !this.m_beginPending || !IsDefined(this.m_menu) || this.m_inWorld {
            return;
        }
        this.m_beginPending = false;
        ArrayClear(this.m_characterKeys);
        ArrayClear(this.m_characterValues);
        this.m_menu.CampaignBegin(this.m_beginMode, this.m_beginIsHost);
    }

    public func Connect() -> Void {
        let network = GameInstance.GetNetworkWorldSystem();
        if !IsDefined(network) || network.IsConnected() {
            return;
        }
        this.m_connecting = true;
        network.Connect();
        this.RefreshMenu();
    }

    public func Leave() -> Void {
        let network = GameInstance.GetNetworkWorldSystem();
        if IsDefined(network) {
            network.Disconnect();
        }
        this.m_phase = "";
        this.m_voteOpen = false;
        this.m_beginPending = false;
        ArrayClear(this.m_players);
        this.RefreshMenu();
    }

    public func ToggleReady() -> Void {
        CampaignServer.LobbySetReady(!this.IsReady());
    }

    public func ChooseNew() -> Void {
        CampaignServer.LobbyChoose(1, "");
    }

    // Each press picks the next saved campaign.
    public func ChooseNextSaved() -> Void {
        let count = ArraySize(this.m_campaigns);
        if count == 0 {
            return;
        }
        let next = 0;
        let i = 0;
        while i < count {
            if this.m_mode == 2 && Equals(this.m_campaigns[i], this.m_campaign) {
                next = (i + 1) % count;
            }
            i += 1;
        }
        CampaignServer.LobbyChoose(2, this.m_campaigns[next]);
    }

    public func Start() -> Void {
        CampaignServer.LobbyStart();
    }

    // Back at the menu during a running campaign: the host loads their save, a guest gets
    // their character back.
    public func Resume() -> Void {
        this.m_beginMode = 2;
        this.m_beginIsHost = this.IsHost();
        this.m_beginPending = true;
        this.RunPendingBegin();
    }

    public func Vote(option: Int32) -> Void {
        if !this.m_voteOpen {
            return;
        }
        this.m_myVote = option;
        CampaignServer.CastVote(this.m_voteId, option);
        this.RefreshMenu();
    }

    // ---- what the menu shows ----

    public func GetPhase() -> String = this.m_phase
    public func GetMode() -> Int32 = this.m_mode
    public func GetChosenCampaign() -> String = this.m_campaign
    public func GetCampaignCount() -> Int32 = ArraySize(this.m_campaigns)
    public func IsVoting() -> Bool = this.m_voteOpen
    public func GetVoteOptionCount() -> Int32 = ArraySize(this.m_voteOptions)
    public func IsConnecting() -> Bool = this.m_connecting

    // The server names each receiver ("you"), already cleaned up and made unique.
    public func IsHost() -> Bool {
        return StrLen(this.m_host) > 0 && Equals(this.m_host, this.m_you);
    }

    public func IsReady() -> Bool {
        for player in this.m_players {
            if Equals(player.name, this.m_you) {
                return player.ready;
            }
        }
        return false;
    }

    public func GetVoteLabel(option: Int32) -> String {
        let label = this.m_voteOptions[option];
        if Equals(this.m_voteKind, "lifepath") {
            label = CampaignLobby.LifePathLabel(label);
        }
        let count = option < ArraySize(this.m_voteCounts) ? this.m_voteCounts[option] : 0;
        let mine = this.m_myVote == option ? "  <" : "";
        return s"VOTE: \(label)  (\(count))\(mine)";
    }

    public static func LifePathLabel(lifePath: String) -> String {
        switch lifePath {
            case "LifePaths.Corporate": return "CORPO";
            case "LifePaths.Nomad": return "NOMAD";
            case "LifePaths.StreetKid": return "STREET KID";
            default: return lifePath;
        }
    }

    public func PanelText() -> String {
        if this.m_connecting {
            return "CO-OP CAMPAIGN\nConnecting...";
        }
        if !CampaignLobby.IsConnected() {
            return "";
        }

        let text = "CO-OP CAMPAIGN";
        if StrLen(this.m_host) > 0 {
            text += s"\nHost: \(this.m_host)";
        } else {
            text += "\nHost: none - the story waits for its host";
        }

        if Equals(this.m_phase, "started") {
            text += s"\nPlaying: \(this.m_active)";
            if StrLen(this.m_lifePath) > 0 {
                text += s" (\(CampaignLobby.LifePathLabel(this.m_lifePath)))";
            }
        } else if this.m_mode == 1 {
            text += "\nNew campaign - lifepath by vote";
        } else if this.m_mode == 2 {
            text += s"\nLoad campaign: \(this.m_campaign)";
        } else {
            text += "\nWaiting for the host to pick a campaign";
        }

        if this.m_voteOpen {
            text += s"\nVote: \(this.m_voteSeconds)s - most votes wins, a tie is drawn";
        }

        text += "\nPlayers:";
        for player in this.m_players {
            let status = player.inWorld ? "in game" : (player.ready ? "ready" : "not ready");
            if Equals(player.name, this.m_host) {
                status = player.inWorld ? "host, in game" : "host";
            }
            text += s"\n  \(player.name) - \(status)";
        }
        return text;
    }

    // ---- character creation and the guest start ----

    public func MarkCreating() -> Void {
        this.m_creating = true;
    }

    public func IsCreating() -> Bool = this.m_creating
    public func IsBeginHost() -> Bool = this.m_beginIsHost
    public func GetLifePath() -> String = this.m_lifePath

    // The lifepath screen only takes the lifepath the players voted for.
    public func BlocksLifePath(lifePath: String) -> Bool {
        return this.m_creating && StrLen(this.m_lifePath) > 0 && !Equals(this.m_lifePath, lifePath);
    }

    // Guests start the quest-free world (the replaced standalone gamedef), the host the story.
    public func BlocksStart(standalone: Bool) -> Bool {
        return this.m_creating && NotEquals(standalone, !this.m_beginIsHost);
    }

    public func GetCharacterValue(key: String) -> String {
        let i = 0;
        while i < ArraySize(this.m_characterKeys) {
            if Equals(this.m_characterKeys[i], key) {
                return this.m_characterValues[i];
            }
            i += 1;
        }
        return "";
    }

    public func MarkRestorePending() -> Void {
        this.m_restorePending = true;
    }

    // A new character: its look goes into the campaign right away.
    public func ReportAppearance(appearance: String) -> Void {
        if StrLen(appearance) == 0 || !CampaignLobby.IsConnected() {
            return;
        }
        CampaignLobby.SendPart("appearance", appearance);
        CampaignServer.ReportCharacterDone();
    }

    public static func SendPart(key: String, value: String) -> Void {
        let length = StrLen(value);
        let offset = 0;
        while offset < length {
            CampaignServer.ReportCharacterPart(key, StrMid(value, offset, CampaignLobby.PartLength()));
            offset += CampaignLobby.PartLength();
        }
    }

    // ---- in the world ----

    public func OnWorldReady(game: GameInstance) -> Void {
        this.m_inWorld = true;
        this.m_creating = false;
        this.m_menu = null;

        if CampaignLobby.IsConnected() {
            this.ReportWorld();
        }

        if this.m_restorePending {
            let restore = new CampaignRestoreCallback();
            restore.game = game;
            // Give the player's stats a moment to come up before rewriting them.
            GameInstance.GetDelaySystem(game).DelayCallback(restore, 3.0, false);
        }

        if !this.m_reportArmed {
            this.m_reportArmed = true;
            let report = new CampaignReportCallback();
            report.game = game;
            GameInstance.GetDelaySystem(game).DelayCallback(report, CampaignLobby.ReportSeconds(), false);
        }
    }

    public func OnWorldGone() -> Void {
        if this.m_worldReported && CampaignLobby.IsConnected() {
            CampaignServer.LeaveWorld();
        }
        this.m_inWorld = false;
        this.m_worldReported = false;
        this.m_reportArmed = false;
    }

    private func ReportWorld() -> Void {
        this.m_worldReported = true;
        CampaignServer.EnterWorld();
    }

    public func OnReportTimer(game: GameInstance) -> Void {
        if !this.m_inWorld {
            this.m_reportArmed = false;
            return;
        }

        if CampaignLobby.IsConnected() && Equals(this.m_phase, "started") && !this.m_restorePending {
            CampaignCharacter.Report(game);
        }

        let report = new CampaignReportCallback();
        report.game = game;
        GameInstance.GetDelaySystem(game).DelayCallback(report, CampaignLobby.ReportSeconds(), false);
    }

    public func RestoreCharacter(game: GameInstance) -> Void {
        if !this.m_restorePending {
            return;
        }
        this.m_restorePending = false;
        CampaignCharacter.Restore(game, this);
    }
}

// What of a character goes into the campaign save, and how it comes back. Appearance is
// handled by the creator (ExportCustomizationState / ImportCustomizationState); this is
// the rest: level, street cred, attributes, perks, unspent points, money and items.
// Not yet: which items are equipped, item mods and quality, cyberware slots.
public abstract class CampaignCharacter {
    public static func Attributes() -> array<gamedataStatType> {
        return [gamedataStatType.Strength, gamedataStatType.Reflexes, gamedataStatType.TechnicalAbility, gamedataStatType.Intelligence, gamedataStatType.Cool];
    }

    public static func PointTypes() -> array<gamedataDevelopmentPointType> {
        return [gamedataDevelopmentPointType.Attribute, gamedataDevelopmentPointType.Primary, gamedataDevelopmentPointType.Espionage];
    }

    public static func Report(game: GameInstance) -> Void {
        let player = GameInstance.GetPlayerSystem(game).GetLocalPlayerMainGameObject() as PlayerPuppet;
        if !IsDefined(player) {
            return;
        }
        let dev = PlayerDevelopmentSystem.GetData(player);
        let transactions = GameInstance.GetTransactionSystem(game);
        if !IsDefined(dev) || !IsDefined(transactions) {
            return;
        }

        CampaignServer.ReportCharacterPart("level", IntToString(dev.GetProficiencyLevel(gamedataProficiencyType.Level)));
        CampaignServer.ReportCharacterPart("streetcred", IntToString(dev.GetProficiencyLevel(gamedataProficiencyType.StreetCred)));

        let attributes = "";
        for type in CampaignCharacter.Attributes() {
            attributes += s"\(EnumInt(type)):\(Cast<Int32>(dev.GetAttributeValue(type))),";
        }
        CampaignServer.ReportCharacterPart("attributes", attributes);

        let points = "";
        for type in CampaignCharacter.PointTypes() {
            points += s"\(EnumInt(type)):\(dev.GetDevPoints(type)),";
        }
        CampaignServer.ReportCharacterPart("points", points);

        let perks = "";
        let count = EnumInt(gamedataNewPerkType.Count);
        let i = 0;
        while i < count {
            let level = dev.IsNewPerkBought(IntEnum<gamedataNewPerkType>(Cast<Int64>(i)));
            if level > 0 {
                perks += s"\(i):\(level),";
            }
            i += 1;
        }
        CampaignServer.ReportCharacterPart("perks", perks);

        let money = MarketSystem.Money();
        CampaignServer.ReportCharacterPart("money", IntToString(transactions.GetItemQuantity(player, money)));

        // Item record ids as numbers: TweakDB names are not available outside debug builds.
        let items = "";
        let list: array<wref<gameItemData>>;
        transactions.GetItemList(player, list);
        for data in list {
            if IsDefined(data) && !data.HasTag(n"Quest") && NotEquals(data.GetID(), money) {
                items += s"\(TDBID.ToNumber(ItemID.GetTDBID(data.GetID()))):\(data.GetQuantity()),";
            }
        }
        CampaignLobby.SendPart("items", items);

        CampaignServer.ReportCharacterDone();
    }

    public static func Restore(game: GameInstance, lobby: ref<CampaignLobby>) -> Void {
        let player = GameInstance.GetPlayerSystem(game).GetLocalPlayerMainGameObject() as PlayerPuppet;
        let network = GameInstance.GetNetworkWorldSystem();
        if !IsDefined(player) || !IsDefined(network) {
            return;
        }
        let dev = PlayerDevelopmentSystem.GetData(player);
        let transactions = GameInstance.GetTransactionSystem(game);
        if !IsDefined(dev) || !IsDefined(transactions) {
            return;
        }

        let level = StringToInt(lobby.GetCharacterValue("level"));
        if level > 0 {
            dev.SetLevel(gamedataProficiencyType.Level, level, telemetryLevelGainReason.Ignore, true);
        }
        let streetCred = StringToInt(lobby.GetCharacterValue("streetcred"));
        if streetCred > 0 {
            dev.SetLevel(gamedataProficiencyType.StreetCred, streetCred, telemetryLevelGainReason.Ignore, true);
        }

        let keys: array<String>;
        let values: array<Int32>;

        // Attributes are bought point by point, the way the game raises them.
        CampaignBatch.Parse(lobby.GetCharacterValue("attributes"), keys, values);
        let i = 0;
        while i < ArraySize(keys) {
            let type = IntEnum<gamedataStatType>(Cast<Int64>(StringToInt(keys[i])));
            let missing = values[i] - Cast<Int32>(dev.GetAttributeValue(type));
            if missing > 0 {
                dev.AddDevelopmentPoints(missing, gamedataDevelopmentPointType.Attribute);
                let n = 0;
                while n < missing {
                    dev.BuyAttribute(type);
                    n += 1;
                }
            }
            i += 1;
        }

        ArrayClear(keys);
        ArrayClear(values);
        CampaignBatch.Parse(lobby.GetCharacterValue("perks"), keys, values);
        i = 0;
        while i < ArraySize(keys) {
            let perk = IntEnum<gamedataNewPerkType>(Cast<Int64>(StringToInt(keys[i])));
            let missing = values[i] - dev.IsNewPerkBought(perk);
            let n = 0;
            while n < missing {
                dev.BuyNewPerk(perk, true);
                n += 1;
            }
            i += 1;
        }

        // Unspent points last, so whatever the purchases above cost, the totals match.
        ArrayClear(keys);
        ArrayClear(values);
        CampaignBatch.Parse(lobby.GetCharacterValue("points"), keys, values);
        i = 0;
        while i < ArraySize(keys) {
            let type = IntEnum<gamedataDevelopmentPointType>(Cast<Int64>(StringToInt(keys[i])));
            let difference = values[i] - dev.GetDevPoints(type);
            if difference != 0 {
                dev.AddDevelopmentPoints(difference, type);
            }
            i += 1;
        }

        let money = MarketSystem.Money();
        let missingMoney = StringToInt(lobby.GetCharacterValue("money")) - transactions.GetItemQuantity(player, money);
        if missingMoney > 0 {
            transactions.GiveItem(player, money, missingMoney);
        }

        // Items are given on top of the fresh guest start's few starting items.
        let given = 0;
        for pair in StrSplit(lobby.GetCharacterValue("items"), ",") {
            let id: String;
            let quantity: String;
            if StrSplitFirst(pair, ":", id, quantity) && StrLen(id) > 0 {
                let record = network.TweakDBIDFromNumber(StringToUint64(id));
                if TDBID.IsValid(record) {
                    transactions.GiveItem(player, ItemID.FromTDBID(record), Max(1, StringToInt(quantity)));
                    given += 1;
                }
            }
        }

        LogChannel(n"DEBUG", s"[Campaign] character restored: level \(level), \(given) item stack(s)");
    }
}

// ---- main menu ----

@addField(SingleplayerMenuGameController)
let m_campaignPanel: wref<inkText>;

@addMethod(SingleplayerMenuGameController)
public func CampaignRefresh() -> Void {
    this.ShowActionsList();
}

@addMethod(SingleplayerMenuGameController)
private func CampaignUpdatePanel(lobby: ref<CampaignLobby>) -> Void {
    if !IsDefined(this.m_campaignPanel) {
        let root = this.GetRootCompoundWidget();
        if !IsDefined(root) {
            return;
        }
        let text = new inkText();
        text.SetName(n"campaign_lobby_panel");
        text.SetAnchor(inkEAnchor.TopRight);
        text.SetAnchorPoint(1.0, 0.0);
        text.SetMargin(new inkMargin(0.0, 260.0, 90.0, 0.0));
        text.SetFitToContent(true);
        text.SetFontFamily("base\\gameplay\\gui\\fonts\\raj\\raj.inkfontfamily");
        text.SetFontStyle(n"Regular");
        text.SetFontSize(32);
        text.SetHorizontalAlignment(textHorizontalAlignment.Right);
        text.SetTintColor(new HDRColor(2.0, 1.75, 0.25, 1.0));
        text.Reparent(root);
        this.m_campaignPanel = text;
    }
    this.m_campaignPanel.SetText(lobby.PanelText());
}

@wrapMethod(SingleplayerMenuGameController)
private func PopulateMenuItemList() -> Void {
    let network = GameInstance.GetNetworkWorldSystem();
    let lobby = CampaignLobby.Get();

    if !IsDefined(network) || !IsDefined(lobby) || !network.IsEnabled() {
        wrappedMethod();
        return;
    }

    lobby.SetMenu(this);
    this.CampaignUpdatePanel(lobby);

    if !network.IsConnected() {
        wrappedMethod();
        if !lobby.IsConnecting() {
            this.AddMenuItem("CO-OP CAMPAIGN", n"OnCampaignConnect");
        }
        this.m_menuListController.Refresh();
        return;
    }

    // In the lobby the game is started by the lobby, so Continue / New Game / Load Game
    // are not offered: they would start a game nobody else is in.
    let phase = lobby.GetPhase();
    if lobby.IsVoting() {
        let i = 0;
        while i < lobby.GetVoteOptionCount() {
            this.AddMenuItem(lobby.GetVoteLabel(i), StringToName(s"OnCampaignVote\(i)"));
            i += 1;
        }
    } else if Equals(phase, "started") {
        this.AddMenuItem("CO-OP: JOIN THE CAMPAIGN", n"OnCampaignResume");
    } else if lobby.IsHost() {
        this.AddMenuItem(lobby.GetMode() == 1 ? "CO-OP: NEW CAMPAIGN  <" : "CO-OP: NEW CAMPAIGN", n"OnCampaignNew");
        if lobby.GetCampaignCount() > 0 {
            let label = lobby.GetMode() == 2 ? s"CO-OP: LOAD \(lobby.GetChosenCampaign())  <" : "CO-OP: LOAD SAVED CAMPAIGN";
            this.AddMenuItem(label, n"OnCampaignLoad");
        }
        if lobby.GetMode() != 0 {
            this.AddMenuItem("CO-OP: START", n"OnCampaignStart");
        }
    } else {
        this.AddMenuItem(lobby.IsReady() ? "CO-OP: NOT READY" : "CO-OP: READY", n"OnCampaignReady");
    }

    this.AddMenuItem("CO-OP: LEAVE", n"OnCampaignLeave");
    this.AddMenuItem(GetLocalizedText("UI-Labels-Settings"), n"OnSwitchToSettings");
    this.AddMenuItem(GetLocalizedText("UI-Labels-Credits"), n"OnCreditsPicker");
    this.m_menuListController.Refresh();

    lobby.RunPendingBegin();
}

// ref<> is required here: the game's .script declares the parameter without it, but
// redscript needs class types behind ref or wref.
@wrapMethod(SingleplayerMenuGameController)
protected func HandleMenuItemActivate(data: ref<PauseMenuListItemData>) -> Bool {
    let lobby = CampaignLobby.Get();
    if !IsDefined(lobby) {
        return wrappedMethod(data);
    }

    switch data.eventName {
        case n"OnCampaignConnect": lobby.Connect(); return true;
        case n"OnCampaignLeave": lobby.Leave(); return true;
        case n"OnCampaignReady": lobby.ToggleReady(); return true;
        case n"OnCampaignNew": lobby.ChooseNew(); return true;
        case n"OnCampaignLoad": lobby.ChooseNextSaved(); return true;
        case n"OnCampaignStart": lobby.Start(); return true;
        case n"OnCampaignVote0": lobby.Vote(0); return true;
        case n"OnCampaignVote1": lobby.Vote(1); return true;
        case n"OnCampaignVote2": lobby.Vote(2); return true;
        case n"OnCampaignVote3": lobby.Vote(3); return true;
        case n"OnCampaignResume": lobby.Resume(); return true;
        default: break;
    }
    return wrappedMethod(data);
}

@addMethod(SingleplayerMenuGameController)
public func CampaignBegin(mode: Int32, isHost: Bool) -> Void {
    let lobby = CampaignLobby.Get();
    if isHost {
        if mode == 1 {
            // A new campaign: the host makes a character and plays the voted prologue.
            lobby.MarkCreating();
            this.m_menuEventDispatcher.SpawnEvent(n"OnNewGame");
        } else {
            // The host's own save is the story; they pick it in the game's Load Game menu.
            this.m_menuEventDispatcher.SpawnEvent(n"OnLoadGame");
        }
        return;
    }

    // Guests ask for their saved character first and make one if there is none.
    CampaignServer.RequestCharacter();
}

@addMethod(SingleplayerMenuGameController)
public func CampaignStartGuest(found: Bool) -> Void {
    let lobby = CampaignLobby.Get();
    let network = GameInstance.GetNetworkWorldSystem();
    let appearance = lobby.GetCharacterValue("appearance");

    if !found || StrLen(appearance) == 0 {
        lobby.MarkCreating();
        this.m_menuEventDispatcher.SpawnEvent(n"OnNewGame");
        return;
    }

    let system = GameInstance.GetCharacterCustomizationSystem(GetGameInstance());
    system.InitializeState();
    if !network.ImportCustomizationState(appearance) {
        LogChannel(n"DEBUG", "[Campaign] saved look could not be loaded, making a new character");
        lobby.MarkCreating();
        this.m_menuEventDispatcher.SpawnEvent(n"OnNewGame");
        return;
    }

    let state = system.GetState();
    if StrLen(lobby.GetLifePath()) > 0 {
        state.SetLifePath(TDBID.Create(lobby.GetLifePath()));
    }
    // The guest world: the mod's standalone gamedef starts no quests.
    state.SetIsExpansionStandalone(true);
    system.FinalizeState();

    lobby.MarkRestorePending();
    LogChannel(n"DEBUG", "[Campaign] starting the guest world with the saved character");
    this.GetSystemRequestsHandler().StartNewGame(state);
}

// ---- character creation ----

@wrapMethod(CharacterCreationBackstorySelectionMenu)
protected cb func OnReleaseNomad(e: ref<inkPointerEvent>) -> Bool {
    if CampaignLobby.Get().BlocksLifePath("LifePaths.Nomad") {
        return false;
    }
    return wrappedMethod(e);
}

@wrapMethod(CharacterCreationBackstorySelectionMenu)
protected cb func OnReleaseStreet(e: ref<inkPointerEvent>) -> Bool {
    if CampaignLobby.Get().BlocksLifePath("LifePaths.StreetKid") {
        return false;
    }
    return wrappedMethod(e);
}

@wrapMethod(CharacterCreationBackstorySelectionMenu)
protected cb func OnReleaseCorpo(e: ref<inkPointerEvent>) -> Bool {
    if CampaignLobby.Get().BlocksLifePath("LifePaths.Corporate") {
        return false;
    }
    return wrappedMethod(e);
}

@wrapMethod(ExpansionNewGame)
protected cb func OnPressBaseGame(evt: ref<inkPointerEvent>) -> Bool {
    if CampaignLobby.Get().BlocksStart(false) {
        return false;
    }
    return wrappedMethod(evt);
}

@wrapMethod(ExpansionNewGame)
protected cb func OnPressExpansion(evt: ref<inkPointerEvent>) -> Bool {
    if CampaignLobby.Get().BlocksStart(true) {
        return false;
    }
    return wrappedMethod(evt);
}

// The last word before the game starts: whatever was clicked on the way, the campaign's
// lifepath and the right start (story for the host, guest world for guests) are set here.
@wrapMethod(characterCreationSummaryMenu)
protected cb func OnOutroComplete(anim: ref<inkAnimProxy>) -> Bool {
    let lobby = CampaignLobby.Get();
    if IsDefined(lobby) && lobby.IsCreating() {
        if StrLen(lobby.GetLifePath()) > 0 {
            this.m_characterCustomizationState.SetLifePath(TDBID.Create(lobby.GetLifePath()));
        }
        this.m_characterCustomizationState.SetIsExpansionStandalone(!lobby.IsBeginHost());

        if !lobby.IsBeginHost() {
            lobby.ReportAppearance(GameInstance.GetNetworkWorldSystem().ExportCustomizationState());
        }
    }
    return wrappedMethod(anim);
}
