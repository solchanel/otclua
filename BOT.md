# luaclient bot layer — module contract (authoritative for implementers)

> **STATUS: BUILT.** Every module below exists and is exercised offline by
> `test/botsuite.lua`, which `--selftest` runs on Windows and Debian (2120 bot assertions,
> 2521 in total, 0 failed as of 2026-09-06). Where the as-built code had to deviate from the
> contract, the deviation is recorded in **[As built — contract changes](#as-built--contract-changes)**
> at the end of this file. That section is normative for anyone writing new bot code.

Goal: reproduce vBot 4.8's *behaviour* in the standalone Lua client — HealBot, AttackBot, CaveBot,
TargetBot with looting and supplies — with **no UI**, driven by the client's event bus and scheduler.

Behaviour truth lives in `docs/vbot/*.md` (bot-core, healbot, attackbot, cavebot, targetbot,
pathfinding, gaps). **In every one of those files the `## VERIFIER (Corrections)` section overrides
the spec body above it.** Client-side truth lives in `API.md` and `docs/*.md`. Never invent a
threshold or an ordering: it is documented, with file:line into the real vBot.

## Config compatibility (a hard requirement)

The bot reads the **user's existing vBot files unchanged**. Reference profile on this machine:
`D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\`

```
vBot_configs/profile_<N>/HealBot.json      healing rules + ConditionPanel
vBot_configs/profile_<N>/AttackBot.json    attack entries
vBot_configs/profile_<N>/Supplies.json     supply thresholds
cavebot_configs/<name>.cfg                 waypoint list, one "type:value" per line
targetbot_configs/<name>.json              { targeting = [...], looting = {...} }
storage/profile_<N>.json                   persisted runtime storage (macro on/off, etc.)
```

`--bot-profile=<dir>` points at such a directory; `--bot-vprofile=N` selects `profile_<N>`
(default 1); `--cavebot=<name>` and `--targetbot=<name>` select config files by base name.
Unknown fields must be preserved on save, never dropped.

## Layout

```
bot/init.lua       runtime: macro registry, tick, storage, arbitration, start/stop, wireModules
bot/shared.lua     the ONE use-cooldown slot + spell-cooldown cache HealBot and AttackBot share
bot/api.lua        the vBot-compatible script surface (say/use/usewith/findItem/…)
bot/world.lua      queries over game state (spectators, distances, sight, monster counting)
bot/path.lua       A* pathfinding over the tile store
bot/walker.lua     stepping, confirmation, retries, floor changes, anti-lost
bot/healbot.lua    bot/attackbot.lua  bot/cavebot.lua  bot/targetbot.lua
bot/loot.lua       corpse discovery + looting state machine (used by targetbot)
bot/supplies.lua   supply check / refill / deposit
bot/config.lua     loading + saving the vBot config files above
data/spells1530.lua        SpellInfo['Default'], extracted from the real vBot sources
data/attackpatterns1530.lua spellPatterns / monkDirPatterns / the quadrant grids
tools/extract_vbot_data.lua the generator for both (anchor-based, fails loudly on a version bump)
```

Everything is instance-based: `bot.new(client)` where `client = _G.LC` (log, sched, state, sender,
events, items). No globals. All bot code runs on the single scheduler thread.

## bot/init.lua

```lua
local b = bot.new(LC, { profileDir=, vprofile=1, cavebot=, targetbot=, autostart=true })
b:start()  b:stop()  b:isOn()
b.storage                      -- persisted table, saved on stop and every 60 s
b:macro(timeoutMs, name, fn)   -- vBot semantics: minimum period 50 ms, random 0..100 ms initial
                               -- jitter, per-name enable state persisted in storage._macros,
                               -- an unnamed macro is always enabled
b:schedule(delayMs, fn)        -- one-shot, ordered queue drained after macros each tick
b:delay(ms)                    -- suspend the CURRENTLY EXECUTING macro/callback
b:isDelayed()
b.modules                      -- { healbot=, attackbot=, cavebot=, targetbot=, supplies= }
b:status()                     -- a plain table for the future web panel (see below)
b:wireModules(opts)            -- build the shared world/path/walker + the four modules, in
                               -- registration order; idempotent.  This is what main.lua calls.
b:unwireModules()              -- drop the walker's and TargetBot's event hooks
```
Tick: every 10 ms — set `b.now`, run due macros in registration order (each in pcall; an error is
logged as `Macro <name> execution error` and does not kill the bot), then drain due scheduled
callbacks. A macro whose body throws must not stop other macros. Registration order is priority
order, so the modules register in this order: healbot, attackbot, targetbot, cavebot.

**Arbitration** (docs/vbot/cavebot.md + targetbot.md): TargetBot suspends CaveBot while it has a
target or is looting; CaveBot yields by not advancing its waypoint. Healing never yields.
Expose `b:isActionAllowed(who)` implementing the documented precedence rather than ad-hoc checks.

## bot/api.lua — the script surface

Mirror vBot's `context` API so user snippets port over. Implement at least (exact names):
`say yell talkNpc talkPrivate use useWith useOnCreature usePos moveItem findItem findItemCount
itemAmount getSpectators getCreatureById getPlayer pos hp hpPercent mana manaPercent level cap
storage now delay schedule macro walk turn stopWalk attack follow cancelAttack
canCast castSpell isInPz isDead isWalking distanceFromPlayer getMonsters getPlayers getNpcs
openContainer closeContainer getContainers getBackpacks depositItems withdrawItems`
Each returns plain Lua values from `LC.state` or sends via `LC.sender`. Document any vBot function
you deliberately do not implement.

## bot/world.lua

```lua
world.spectators(pos, multifloor)     -- creatures around a position, from state.creatures
world.monsters(pos, range)            -- filtered by creature type
world.players(pos, range)
world.distance(a, b)                  -- max(|dx|,|dy|), the game's distance
world.isSightClear(from, to)          -- Bresenham over blockProjectile flags (docs/vbot/pathfinding)
world.countInArea(centerPos, pattern, dir)  -- monsters inside a spell pattern
world.tileWalkable(pos, opts)         -- the documented predicate (flags + creatures + fields)
```

## bot/path.lua

> **As built:** it is *not* A\*. `Map::findEveryPath` is a pure Dijkstra flood with no
> heuristic, and reproducing vBot's route choice requires reproducing that exactly (the
> neighbour scan order and the first-wins tie-break are observable). See the deviations section.

Per `docs/vbot/pathfinding.md`: same step costs, diagonal handling, `maxDistance`/`maxComplexity`
limits and the flags (allow unseen / allow creatures / allow non-pathable / ignore last-tile
creature) that vBot passes. Use a binary heap. Returns a list of directions (0..7) or nil plus a
reason. Must handle a 40×40 aware area in well under 10 ms; report the measured time.

## bot/walker.lua

```lua
walker:walkTo(pos, opts)   -- returns 'arrived'|'walking'|'blocked'|'nopath'
walker:step(dir)           -- one step with the documented confirmation/retry rules
walker:stop()
walker.onWalkCancel        -- hooked to the client's walkCancel event
```
Implements the walk state machine from `docs/vbot/cavebot.md`: prewalk expectations, the walk
delay, retry limits, what to do when a creature blocks the next tile, and floor changes
(stairs/ladders/ropes/holes/teleports) including the anti-lost recovery rules.

## Modules

Each module: `M.new(bot, config)` with `:enable()`, `:disable()`, `:isOn()`, `:tick()` registered as
a macro at the documented period, `:status()`, and `:reload(config)`.

* **healbot.lua** — rule list from `HealBot.json` (trigger HP%/mana%/both/condition, operator,
  threshold, action = spell words or item id, per-rule delay, priority, enabled) plus the
  `ConditionPanel` cures (haste/antidote/utamo/…) with their cost and hold flags. One action per
  tick, highest-priority satisfied rule wins; respects mana, spell cooldowns, item exhaust, PZ and
  death guards.
* **attackbot.lua** — entries from `AttackBot.json`: spell or rune, category/pattern, minimum
  monster count, HP%/mana% conditions, creature filters, PvP guards, per-entry cooldown. Counts
  monsters in the pattern via `world.countInArea` and picks the best direction/tile for waves and
  areas. The five spell optimizers are OPTIONAL — implement only if time remains, behind a flag.
* **cavebot.lua** — parses `.cfg` waypoints (`goto`, `label`, `gotolabel`, `delay`, `use`,
  `usewith`, `say`, `npcsay`, `function`, `stand`, `walkdelay`, `turn`, plus the documented extras)
  and executes them with `walker`. Implements supply check → refill → return-to-hunt via
  `supplies.lua`, and the anti-lost behaviour. Unknown waypoint types must log once and skip, never
  abort the route.
* **targetbot.lua** — creature entries from `targetbot_configs/<name>.json` (`targeting` array:
  name/regex, priority, danger, maxDistance, chase, keepDistance(+range), lure settings,
  rePosition, avoidAttacks, dontLoot…). Implements the documented candidate gathering, scoring,
  hysteresis, attack/chase/keep-distance movement, the danger aggregate CaveBot consults, and
  delegates corpses to `loot.lua` using the `looting` section of the same file.

## Status object (for the future web panel)

```lua
{ on=, player={hp,maxHp,mana,maxMana,level,cap,pos,states},
  healbot={on,profile,lastAction}, attackbot={on,profile,lastSpell},
  cavebot={on,config,waypointIndex,waypointCount,currentAction,status},
  targetbot={on,config,target={id,name,hpPercent,distance},danger,looting},
  macros={{name,enabled}}, supplies={{item,count,threshold}} }
```

## Testing (mandatory)

Offline only — there is no live account. Extend `test/` with:
* `test/botsuite.lua`: unit tests per module against a **synthetic world**: build `LC.state`
  directly (player, creatures, tiles from a small ASCII map), run ticks, assert the exact packets
  the bot would send by capturing `LC.sender`'s transport.
* pathfinding tests on ASCII maps with walls, diagonals, creatures and unseen tiles, including a
  no-path case and a maxComplexity cutoff.
* a HealBot table driven by the user's real `HealBot.json`, asserting which rule fires for a matrix
  of hp/mana values.
* a CaveBot test that walks a synthetic route end to end, including a blocked tile and a label jump.
* a TargetBot test: two candidate monsters, assert selection, chase stepping and the looting
  sequence against a scripted container.
All of it must run in `--selftest` on **both Windows and Debian**, exit non-zero on failure, and
never require a network.

---

## As built — contract changes

Everything in this section is what the shipped code actually does where it differs from the
contract above. It was written by the integration work item after wiring all the modules
together; `test/botsuite.lua` pins every item in it.

### 1. Constructor signatures

The contract says `M.new(bot, config)`. As built, each module takes a third `opts` table, and
the three engines take the **client** (`_G.LC`), not the bot:

```lua
world.new(client, opts)            -- opts.known = a persistent minimap store (optional)
path.new(client, world)
walker.new(client, opts)           -- opts.world, opts.path, opts.now, opts.config
healbot.new(bot, cfgTree, opts)    -- cfgTree nil => loaded through bot.config
attackbot.new(bot, cfgTree, opts)
targetbot.new(bot, config, opts)   -- config may be a table OR a config base name
cavebot.new(bot, route, opts)      -- route may be a table, a route name, or nil (storage)
supplies.new(bot, config)
loot.new(ctx)                      -- a plain context table; TargetBot builds it
```

`world.distance(a, b)` works both as a module function and as `w:distance(a, b)`.

**Use `bot:wireModules{...}` instead of calling these yourself.** It builds ONE world, ONE
pathfinder and ONE walker, hands them to every module, and registers the modules in BOT.md's
order. Doing it by hand is how you get two walkers and a double-stepping character.

### 2. Macro registration is split between the constructor and `:attach()`

`healbot` and `attackbot` register their macros in their constructors (four and one
respectively). `targetbot` and `cavebot` register theirs in `:attach()`, which
`bot:wireModules` calls after all four exist and which `onBotStart` calls as a fallback.
`cavebot:attach()` was split out of `cavebot:enable()` for exactly this reason: the macro
order has to be settled independently of which modules happen to start enabled.

The resulting macro list, in order, is the contract:

| # | module | period | name |
|---|---|---|---|
| 1 | healbot conditions (slow) | 500 ms | *(unnamed)* |
| 2 | healbot conditions (fast) | 50 ms | *(unnamed)* |
| 3 | healbot spells | 50 ms | *(unnamed)* |
| 4 | healbot items | 100 ms | *(unnamed)* |
| 5 | attackbot | 50 ms | *(unnamed)* |
| 6 | targetbot | 100 ms | *(unnamed)* |
| 7 | cavebot | 50 ms | `CaveBot` |
| 8 | cavebot anti-lost | 200 ms | `CaveBot AntiLost` |

### 3. CaveBot and TargetBot share ONE walker

Not stated in the contract, and load-bearing. The walker owns the step ledger, the
confirmation retry and the `walkCancel` back-off. Two instances would each answer "not
walking" and the character would be told to step twice per server beat. Sharing it makes
`TB:walk`'s `if self:isWalking() then return end` the mutual exclusion between the two walking
modules, and lets CaveBot's delay rebinding charge a TargetBot step to the CaveBot macro.

### 4. `bot._attacking` is the target handshake

`bot/attackbot.lua` is a pure passenger on `bot._attacking` — it never selects a target.
`bot/targetbot.lua` is the module that issues `sender:attack`, so **every write of
`attackingId` mirrors into `bot._attacking`** through `TB:_setAttacking(id)`. Without that
bridge AttackBot never fires a single spell. `bot/api.lua`'s `ctx.attack` writes the same
field. `attackCancel` and `creatureDisappear` clear it.

### 5. TargetBot's public predicates

Three methods other modules call, all now present:

```lua
tb:isActive()                 -- lastAction + 300 > now      (CaveBot freezes on this)
tb:isCaveBotActionAllowed()   -- cavebotAllowance > now       (the 150 ms lure grant)
tb:isLooting()                -- isOn() and #Looting.getStatus() > 0   (HealBot's throttle)
```

### 6. `bot/shared.lua` — a module the contract's Layout did not list

`docs/vbot/attackbot.md`'s Pitfalls requires it: the use-cooldown slot,
`AttackBotFiringUntil` / `AttackBotRuneReadyUntil`, the 0xA4/0xA5 cooldown cache and
`canCast`/`cast`/`say` must be **one object owned by neither** HealBot nor AttackBot, or a
rune and a potion collide. `shared.attach(bot)` builds the singleton on `bot._shared`.

### 7. `function` waypoints get dot-callable module proxies

vBot scripts call `TargetBot.setOn()` and `CaveBot.delay(500)` with a **dot**, because
upstream those are plain tables of functions. Ours are OO instances, so the sandbox wraps
both in a proxy that binds the receiver and still tolerates a colon call. The user's own
routes contain eight such call sites.

### 8. `opts.readOnlyProfile`

`bot.new(client, { readOnlyProfile = true })` makes `saveStorage()` a no-op returning
`false, 'read-only profile'`. `--dry-run --bot` uses it, and so does the whole offline test
suite, so neither can modify the user's real vBot profile.

### 9. Client-side fields the bot layer depends on

Added to the client for the bot, all of them read defensively (the bot still runs without
them):

| field | source | used by |
|---|---|---|
| `LC.items` | `main.lua` | `bot/world.lua` (falls back to `require('proto.items')`) |
| `state.serverBeat` | `proto/parser.lua` 0x17 | `walker:stepDuration` rounding |
| `state.ping` | `main.lua`, from the 0x1E pong of our own keepalive | walker pacing, cooldown ping compensation, `PingDelay` |
| `state.npcTrade` | `proto/parser.lua` 0x7A / 0x7C | CaveBot `buysupplies` / `sellall` |
| `state.inventoryCounts` | `proto/parser.lua` 0xC0 | `supplies:itemAmount` (counts CLOSED backpacks) |

### 10. Status object — implemented as a superset

Every field the contract lists is present with the documented name. Each module's block
carries extra diagnostics on the same table (`cavebot.retries/noPath/recovering/walker/stats`,
`targetbot.active/cavebotAllowed/luring/looting/stats`, `supplies.rounds/pouchPages/stats`,
plus `bot.stats`, `bot.schedules`, `bot.profileDir`, `bot.vprofile`). It is acyclic and
`bot/config.jsonEncode`s cleanly — `test/botsuite.lua` asserts that, since the web panel will
serialise it.

### 11. `maxComplexity` is an addition

`Map::findEveryPath` has no node cap in C++. BOT.md requires one, so `bot/path.lua` implements
it as a budget on *classified cells* (default 50000). On overrun the field is flagged
`truncated` and `getPath` returns `nil, 'max-complexity'` — unless the destination had already
been settled, in which case the path found is still returned.

### 12. Waypoint types that are registered but skip

`stowdeposit` (the stash half), `forge`, `imbuing`, `tasker`, `rushlure`, `withdraw`,
`dpwithdraw` and `inwithdraw` log **once**, naming the missing `proto/sender.lua` builder, and
return `false` — i.e. they are skipped like a failed waypoint, not warned about like an unknown
type. They need protocol builders the client does not have yet.

### 13. Testing, as built

`test/botsuite.lua` is the file the contract asks for, and it also **embeds the six per-module
suites** so `--selftest` gates all of them on both OSes:

```
test/botsuite.lua        the whole stack through bot:tick() against a synthetic world
  test/f1_metadata.lua     item metadata + tile flags        (BOT_F1_NO_EXIT)
  test/bot_f2_path.lua     pathfinder + walker               (BOT_F2_NO_EXIT)
  test/bot_f3.lua          bot core + bot/api.lua            (BOT_F3_NO_EXIT)
  test/bot_m1.lua          healbot + attackbot               (BOT_M1_NO_EXIT)
  test/bot_m2_cavebot.lua  cavebot + supplies                (BOT_M2_NO_EXIT)
  test/bot_m3_target.lua   targetbot + loot                  (BOT_M3_NO_EXIT)
```

Each suite is runnable standalone and returns `{ pass, fail, failures }` instead of exiting
when its `BOT_*_NO_EXIT` global is set. `test/botsuite.lua` itself honours
`BOTSUITE_NO_EXIT` and `BOTSUITE_ONLY_INTEGRATION`. Nothing in the path touches the network,
and nothing writes to the user's vBot profile.

### 14. CLI

```
--bot                     enable the bot layer once the game has started
--bot-profile=DIR         the vBot profile directory (default: the vBot_4.8 profile next to
                          this checkout when it exists, else ./profiles; LUACLIENT_BOT_PROFILE
                          overrides)
--bot-vprofile=N          vBot_configs/profile_<N> + storage/profile_<N>.json   (default 1)
--cavebot=NAME            select cavebot_configs/<NAME>.cfg AND enable CaveBot   (implies --bot)
--targetbot=NAME          select targetbot_configs/<NAME>.json AND enable it     (implies --bot)
--bot-status-interval=MS  one-line info status, default 5000, 0 = off
```

The bot starts on the `gameStart` / `login` event, stops on every shutdown path (which is
where its storage is persisted), and `--dry-run --bot` builds, wires, ticks and stops it
offline against a read-only profile.

### 15. Review fixes (2026-09-06) — where they changed the contract

A bot-layer review found and this pass fixed a set of behaviour divergences from vBot.
Most are internal, but these five change something a caller can see. Every one of them is
pinned by the `REVIEW: …` sections of `test/botsuite.lua`, which fail against the pre-fix
code and pass against the current one.

1. **`getMonsters` / `getPlayers` / `getNpcs` return a COUNT, not a list.** That is what
   vBot does (`vlib.lua:652-760`) and what every real call site compares against
   (`config.closeLureAmount <= getMonsters(1)`), so a ported snippet used through a
   `function:` waypoint no longer throws. `getMonsters` excludes summons, `getPlayers`
   excludes the local player, party members and `emblem == 1`, and `multifloor` is honoured.
   The old list forms live on as **`getMonsterList` / `getPlayerList` / `getNpcList`**.
2. **`ctx.cap()` is now an alias of `ctx.freecap()`**, and both read
   `state.player.freeCapacity` (0xA0). `state.player.capacity` is TOTAL capacity from the
   0xA1 skill-stats block, and is only the fallback when 0xA0 has not arrived.
   `bot/supplies.lua`'s `S:freeCap()` follows the same rule. `maxcap`/`capmax` are unchanged.
3. **`ctx.cancelAttack()` sends 0xA1 `attack(0)` and `ctx.cancelFollow()` sends 0xA2
   `follow(0)`**, as `g_game.cancelAttack` / `cancelFollow` do. 0xBE, which also drops the
   other target and stops the server-side auto-walk, is reachable only through
   `ctx.cancelAttackAndFollow()`.
4. **`bot/api.lua` no longer keeps its own cooldown cache.** `getSpellData`,
   `getSpellCoolDown`, `canCast`, `isCooldownIconActive` and `isGroupCooldownIconActive`
   all read `bot/shared.lua`, so the sandbox, HealBot and AttackBot share one view and the
   static `data/spells1530.lua` table is consulted first (vlib.lua:333-360). `ctx.storage`
   is served through the ctx metatable, and `Bot:reloadStorage()` now mutates the storage
   table in place, so no captured reference is ever orphaned.
5. **`Bot:stop()` calls `Bot:unwireModules()`**, so a fatal tick error really does leave a
   stopped bot with no live event hooks. `main.lua`'s explicit call is still harmless.

New deviation switch: `healbot.new(..., { vbotBurstInfinity = true })` reproduces vBot's
division by zero in `burstDamageValue()` (`math.ceil(d / 0)` → `inf` when two damage
messages land in the same tick). The default fails closed and returns 0.

New public helpers other modules may use: `A:facing()` / `A:setFacing(dir)` /
`A:quadrantGrids()`, `TB:facing()` / `TB:avoidTileIds()`, `CB:isInPz()` /
`CB:onNotEnoughRoom(msg)`. **Never read `state.player.direction` directly** — the wire only
writes the player's facing onto `state.creatures[<playerId>]`.

Not reproduced (documented omission): vBot's `isFriend` also treats
`vBot.BotServerMembers` as friends. luaclient has no BotServer roster, so `TB:isFriend`
covers the friend list, the local player and — with `storage.playerList.groupMembers` set —
party members, and nothing else.
