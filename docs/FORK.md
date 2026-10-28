# This fork: campaign-coop on a hardened core

Branch `base`. Built on `campaign-coop` (ziomek123pl4-lang/CyberpunkMP, `f3b4df2`), which is
Night City Online's 2.31 port (`9732c46`, 2026-08-10) plus the story co-op plugin.

Night City Online (`nco` remote, ofmiceandcam98-eng/CyberpunkMP) has ~1000 commits since that
fork, but most of them build its MMO: server-owned characters, a template world with no story,
locked time, server-authoritative combat, Discord gating. Those are the opposite of story co-op,
so `nco/main` is **not** merged. Only core fixes are taken, one by one.

## Taken from Night City Online

Applied as-is (cherry-picked, NCO-internal notes dropped):

| NCO | What |
|---|---|
| `d13c76a` | network vehicles never simulate physics |
| `c346f5a` | appearance-apply use-after-free, silent ccstate corruption |
| `fbb7b33` | stop re-scheduling a face the puppet already wears (the observer crash) |
| `5159dc4` | RPC table sized by count and indexed by id (out-of-bounds write); null handler deref |
| `b6fc19c` | netpack could not generate enum fields |
| `58881c8` | use-after-free in the redscript path setup |

Ported by hand (the files had diverged):

| NCO | What | Here |
|---|---|---|
| `559828f`, `0fa2bb9` | flecs queried from the engine's job threads (flecs_stack_restore_cursor crash) | `ServerIdRegistry.h`, `FlecsThread.h`; OnVehicleEnter and GetEntityIdByServerId read the registry, OnVehicleReady marshals to the main thread |
| `98b12fa` | structural change inside an OnAdd observer | observer removed, InterpolationComponent added at both creation sites |
| `e53b7b8` | repeat vehicle exit fired by a teleport | `s_mounted` in VehicleSystem.cpp |
| `afad4cc` | render time held in a float froze remote players | `InterpolateEntity` works in int64 ticks |
| `a5f60d4` | appearance maps shared across threads without a lock (`fbb7b33` depends on it) | `m_mapLock`, copy-out in `ApplyAppearance` |

## Ported later (2026-10-29)

`dd9c074` (animation thread off a global mutex) cherry-picked, conflicts kept on our 2.5 code.
By hand, onto our integer render ticks, scene spacing and held puppets: `124ce33` + `2ccb708` +
`b2507a2` (segment interpolation, per-remote jitter margin, tick 0 ignored; UpdateRate 10 -> 30),
`1b20a40` (spawn queue until the world is ready, a rejoin replaces the puppet), `5a606f1` (4 s
vehicle-exit grace for the idle-controller hook), `34568c5` (the guard only: launch-argument
parsing degrades to defaults). Not taken: `0be76dc` - it extends a vectored exception handler
this branch does not have. None of these can be exercised without a second player.

## Our own changes

- **Steam tunnel accepts only the host's Steam friends** (`SteamTunnel.cpp`), checked in the
  session callback; the worker forwards only accepted peers.
- **A game-hosted server listens on 127.0.0.1** when friends come through the tunnel
  (`CYBERPUNKMP_BIND_LOOPBACK`, set by `ServerHost`); without Steam it listens on the network.
- **Join password**: `config/server.json` `Password` (or `CYBERPUNKMP_SERVER_PASSWORD`) is now
  enforced; clients pass `--password=<x>`. It is not written to logs, invites or Rich Presence.
- **No server-list announcements from a private server.** Upstream posted every server's name,
  port and player count to cyberpunk.skyrim-together.com every minute with `public=true` hard-coded,
  without certificate checks, and shut the server down on a 403. Now only when `Public` is true.
- **One player per name**: a name already playing, or an empty one, is refused. A player who
  reconnects before the server noticed the old connection drop is refused until it times out.

## Building

`.	ools\Build.ps1` (settings and why in the script). First full build: 2026-10-26, MSVC 14.44.35207,
Windows SDK 10.0.22621.0, xmake 3.1.2, pnpm 9.15.9, .NET 9.0.302.

Server smoke test (no game): starts, listens on 127.0.0.1 with `CYBERPUNKMP_BIND_LOOPBACK=1`, reports
a required join password, loads CampaignSystem (16164 facts), EmoteSystem, JobSystem, and sends nothing
to the server list. The client DLL has not been loaded in a game yet.

## Patch 2.5 (2026-10-27)

The game moved to 2.5 on Steam; this branch now targets it (2.31 is reachable through the
`2_31_old` Steam branch, but nothing here is kept compatible with it).

**Toolchain and libraries**
- `vendor/RED4ext.SDK`: official SDK (2.5 types, `5246e659d`) merged into the CyberpunkMP fork on a
  local branch `cpmp-2.5`. Layout conflicts resolved toward upstream; core library files reset to
  upstream where the merge had mixed versions. Published at
  https://github.com/MrYar07/RED4ext.SDK (branch `cpmp-2.5`); `.gitmodules` points there.
- `code/client/Red`: Codeware 1.21.1's RedLib (already contains the 2.31 type-name fix).
- `Core/RedLibCompat.hpp`: the two RedLib calls whose shape changed.

**Engine layouts checked for 2.5**
- All 42 hooked function hashes exist in 2.5's `cyberpunk2077_addresses.json`.
- Quest structures (QuestMirror): Codeware's quest headers did not change between its 2.31 and 2.5
  releases.
- Sector node setups (SceneSpots): the fields read (transform, node, globalNodeID) and the node
  buffer offset are unchanged; the repacked tail is left opaque.
- `RawInputData` (dialog vote injection): 0x40 -> 0x48, per Codeware's 2.5 support commit.

**Assumed, to verify in game** (each one is commented where it is used)
- body gender at 0x44 of the character customization state (logged at spawn);
- movement representation at 0x138 of `move::Component`;
- vehicle `physicsState` at 0x260;
- chat caret at +4 of the text input's own block;
- `PlayerManager` vtable 0x200 (SharedPunk keeps it for 2.5).

**Turned off**: the engine-on vtable call for remote cars (slot 0x328, unverified).

**Not yet redone for 2.5**: `campaign_facts.txt` and `zz_CampaignCoop_GuestStart.archive` were made
from 2.31 game files (WolvenKit CLI); `CyberpunkMP.tweak` records are checked only by TweakXL at
runtime.

**Checked**: client and server build; `tools/CheckScripts.ps1` compiles all mod scripts against the
2.5 game scripts with no errors or warnings.

**In game on 2.5 (2026-10-27)**: with the 2.5 frameworks the mod loads, generates its 5 server RPC
classes (40 functions), passes script validation and reaches the main menu with CO-OP: HOST
CAMPAIGN and CO-OP: JOIN SERVER; Steam features are on. Fixed on the way: script bundle layouts,
ScriptFunction flags at 0xF8 (measured), RedLib script-name takeover, the Present hook (now
`GpuApi::GetDeviceData()`), SteamUser_v023. Not yet exercised: connecting, hosting, a world.

**Player package (2026-10-28)**: `tools/friend-package/Build-FriendPackage.ps1` builds
`CyberpunkCoop-2.5-<date>-<commit>.zip` (frameworks for 2.5, the mod and server, Russian
instructions, uninstall with backups, log collection) plus a `-symbols` folder with the matching
PDBs. Tested install, reinstall and uninstall on a scratch game folder. The older
`tools/campaign/BuildInstaller.ps1` and `installer/` target 2.31 and are superseded.

**Self-check of hand-mapped layouts (2026-10-29)**: `App/World/SelfCheck.{h,cpp}` compares each
hand-mapped field with something the running game answers, under SEH, once per spawn and on
`/coop selfcheck`. Body gender now comes from the game's own `IsBodyGenderMale` through RTTI
(the 0x44 byte is only a fallback). Solo host on 2.5, Nomad start, female V: gender (game function,
rebuilt copy and puppet agree; byte 0x44 agrees too), movement representation 0x138 (points back at
its component) and owner 0x90 (the player), quest root phase 0x68 (questRootInstance) and a running
phase's resource 0x30 (questQuestResource) and graph 0x40 (questGraphDefinition) - all OK. Not yet
run: the vehicle check (isOnGround 0x25C, physicsState 0x260, acceleration 0x264), which needs V in a
car. `Game::FindComponent` was fixed for the 2.5 entity layout (`components` at 0xA0). The caret
offset in `inkTextInputWidget.cpp` is unused: no script calls `MoveCaret`.
