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

## Not taken yet (conflicts; port after the first build and measurement)

`dd9c074` (animation thread off a global mutex - frame rate), `a5f60d4` (appearance map locks),
`124ce33`, `2ccb708`, `b2507a2` (interpolation), `5a606f1` (controller attach during exit),
`1b20a40` (spawn queue until the world is ready), `34568c5` (bad launch argument must not crash),
`0be76dc` (stack for the first C++ exceptions).

## Our own changes

- **Steam tunnel accepts only the host's Steam friends** (`SteamTunnel.cpp`), checked in the
  session callback; the worker forwards only accepted peers.
- **A game-hosted server listens on 127.0.0.1** when friends come through the tunnel
  (`CYBERPUNKMP_BIND_LOOPBACK`, set by `ServerHost`); without Steam it listens on the network.
- **Join password**: `config/server.json` `Password` (or `CYBERPUNKMP_SERVER_PASSWORD`) is now
  enforced; clients pass `--password=<x>`. It is not written to logs, invites or Rich Presence.
- **One player per name**: a name already playing, or an empty one, is refused. A player who
  reconnects before the server noticed the old connection drop is refused until it times out.

Nothing here has been compiled yet. Build steps: `docs/CAMPAIGN.md`, "Budowanie".
