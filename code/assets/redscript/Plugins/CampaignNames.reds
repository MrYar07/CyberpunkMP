module CyberpunkMP.Plugins

import CyberpunkMP.*
import CyberpunkMP.World.*

// Scanning another player shows their name (from NCO, code/assets/redscript/Scanner.reds).
//
// The scanner builds its name from GameObject.GetDisplayName(), a native import that cannot
// be wrapped; for a puppet with a blanked record name it would invent a random NPC name,
// different on every machine. CompileScannerChunks() can be wrapped: the game builds its
// chunks as usual and the name chunk is replaced afterwards, for other players' characters
// only. Real NPCs are untouched.
@wrapMethod(GameObject)
public const func CompileScannerChunks() -> Bool {
    let result = wrappedMethod();

    let network = GameInstance.GetNetworkWorldSystem();
    if !IsDefined(network) {
        return result;
    }
    let appearance = network.GetAppearanceSystem();
    if !IsDefined(appearance) {
        return result;
    }

    // Empty for anything that is not another player's character.
    let name = appearance.GetNetworkPlayerName(this.GetEntityID());
    if Equals(name, "") {
        return result;
    }

    // After wrappedMethod: the game has written its own name by now, this replaces it.
    let chunk = new ScannerName();
    chunk.Set(name);
    GameInstance.GetBlackboardSystem(GetGameInstance())
        .Get(GetAllBlackboardDefs().UI_ScannerModules)
        .SetVariant(GetAllBlackboardDefs().UI_ScannerModules.ScannerName, chunk, true);

    return result;
}
