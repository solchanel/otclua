# luaclient bot layer — module contract (authoritative for implementers)

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
bot/init.lua       runtime: macro registry, tick, storage, arbitration, start/stop
bot/api.lua        the vBot-compatible script surface (say/use/usewith/findItem/…)
bot/world.lua      queries over game state (spectators, distances, sight, monster counting)
bot/path.lua       A* pathfinding over the tile store
bot/walker.lua     stepping, confirmation, retries, floor changes, anti-lost
bot/healbot.lua    bot/attackbot.lua  bot/cavebot.lua  bot/targetbot.lua
bot/loot.lua       corpse discovery + looting state machine (used by targetbot)
bot/supplies.lua   supply check / refill / deposit
bot/config.lua     loading + saving the vBot config files above
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
b.modules                      -- { healbot=, attackbot=, cavebot=, targetbot= } instances
b:status()                     -- a plain table for the future web panel (see below)
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

A* per `docs/vbot/pathfinding.md`: same step costs, diagonal handling, `maxDistance`/`maxComplexity`
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
