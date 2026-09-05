# bot runtime core — execution model (macros, scheduler, delay, storage, context sandbox, Config profiles, event callbacks)

# vBot 4.8 runtime core — behaviour specification for a headless LuaJIT reimplementation

Everything below is the *engine* that `vBot/*.lua`, `cavebot/*.lua`, `targetbot/*.lua` run on top of.
Reimplementing this correctly makes every module script portable almost verbatim.

Source roots cited:
* `B  = D:\Claude\otclient_mehah1530\otclient\mods\game_bot`
* `P  = D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8`
* `S  = D:\Claude\otclient_mehah1530\otclient\src`
* `M  = D:\Claude\otclient_mehah1530\otclient\modules`

---

## 0. Boot / lifecycle (BEHAVIOUR, minus the widgets)

`B\bot.lua:208-296 refresh()` is the whole bring-up. Headless equivalent, in order:

1. `save()` the previous session's storage, then `clear()` (drop executor, cancel the 10 ms tick, cancel every websocket) — `B\bot.lua:110-155`.
2. Enumerate config directories: `g_resources.listDirectoryFiles("/bot", false, false)` (`B\bot.lua:180`). A "config" is a **directory** under the write dir's `bot/`, e.g. `bot/vBot_4.8/`. In this install the write dir is `…\otclient\profiles\` (`--user-dir` override, `S\framework\core\resourcemanager.cpp:385-410`), so the config dir is `…\otclient\profiles\bot\vBot_4.8`.
3. Read which config is active and whether the bot is enabled from the client settings node `bot` keyed `"<CharacterName>_<clientVersion>"` (`B\bot.lua:186-193`, `221-237`). See §4.1 for the real file.
4. If disabled → stop. Otherwise:
5. Load storage: `botStorage = json.decode(read("/bot/<config>/storage/profile_<N>.json"))`, `N = g_settings.getNumber('profile')` (`B\bot.lua:266-282`). A JSON parse error aborts the whole bot start.
6. `executeBot(configName, botStorage, …)` (`B\executor.lua:1`) builds the sandbox and runs the scripts.
7. Start the tick: `check()` → `scheduleEvent(check, 10)` (`B\bot.lua:525-546`).

`online()` (game start) schedules `refresh` **20 ms** after login (`B\bot.lua:339-344`). `offline()` = `save(); clear()` (`B\bot.lua:346-350`).

**Script loading order (`B\executor.lua:3-14, 178-192`)** — critical, and the reason vBot has exactly one top-level file:
* `listDirectoryFiles("/bot/<config>", true, false)` is **non-recursive** and **sorted alphabetically** (`S\framework\core\resourcemanager.cpp` `files.sort()`; header default `recursive = false`).
* All `*.otui` / `*.ui` found there are imported first (UI only, skip headless).
* All top-level `*.lua` are then executed in sorted order, each with `_ENV = context`.
* `P` contains exactly one top-level lua: `_Loader.lua`. It `dofile()`s everything else in a hand-written order (`P\_Loader.lua:18-62`): `main, items, vlib, new_cavebot_lib, configs` first (libraries), then modules, `AttackBot` last of the majors, `Stances` after it.
* `context.dofile(file)` = load `"/bot/<config>/" .. file` with `_ENV = context` (`B\executor.lua:108-116`). `_Loader` calls `dofile("/vBot/main.lua")` etc.
* After each *top-level* file, `context.panel` is reset to the Main tab (`B\executor.lua:191`) — UI detail.

**Reimplementation note:** keep the "one manifest file lists the load order" design. Registration order of macros/callbacks is load order, and that *is* the priority ordering (§1.4).

---

## 1. The macro model

### 1.1 Registration — `context.macro` (`B\functions\main.lua:9-127`)

Overloads (resolved at `main.lua:13-23`):
```
macro(timeout, callback)
macro(timeout, name, callback)
macro(timeout, name, callback, parent)
macro(timeout, name, hotkey, callback)
macro(timeout, name, hotkey, callback, parent)
```
Rules:
* `timeout` must be a number ≥ 1 or it `error()`s (`main.lua:10-12`).
* **`timeout` is clamped up to a minimum of 50 ms** (`main.lua:38-40`), regardless of the requested value. `macro(20, …)` in `P\cavebot\cavebot.lua:76` actually runs at 50 ms.
* `hotkey` is normalised with `retranslateKeyComboDesc` (`main.lua:33-35`) — UI/keyboard, ignore headless but keep the string in the record.
* The record pushed into `context._macros` (`main.lua:42-48`):
```lua
{ enabled = false, name = name, timeout = timeout,
  lastExecution = context.now + math.random(0, 100),   -- jitter, spreads first fire
  hotkey = hotkey }
```
  The `math.random(0,100)` jitter is deliberate: it de-synchronises macros registered in the same frame.
* Methods bolted on: `isOn()`, `isOff()`, `toggle()`, `setOn(val)`, `setOff(val)` (`main.lua:51-89`). `setOn(false)` delegates to `setOff()` and vice versa — so `m.setOn(cond)` works as a setter.
* **Enable state persistence:** `setOn`/`setOff` write `context.storage._macros[name] = true/false` (`main.lua:69, 82`). Keyed by **name string only** → two macros with the same name share one persisted flag.
* If `name:len() > 0`: a switch widget is created (UI) and the stored state is applied — `if context.storage._macros[name] == true then macro.setOn() end` (`main.lua:100-102`). Note: only `== true` restores; anything else leaves it **off**.
* If `name == ""` (unnamed macro): `macro.enabled = true` unconditionally (`main.lua:104`) — **unnamed macros are always on and cannot be disabled from config**. (`vlib.lua:390` `macro(100, function() … end)` is one of these.)
* A caller-site description is captured via `debug.getinfo(2,"Sl")` → `"file:line"`, used only in the slow-macro warning (`main.lua:107-111, 120`).

### 1.2 The execution wrapper (`main.lua:113-125`)

```lua
macro.callback = function(macro)
  if not macro.delay or macro.delay < context.now then
    context._currentExecution = macro
    local start = g_clock.realMillis()
    callback(macro)                       -- user body; its return value is DISCARDED
    if g_clock.realMillis() - start > 100 then
      context.warning("Slow macro ("..dt.."ms): "..macro.name.." - "..desc)
    end
    context._currentExecution = nil
    return true                            -- "I actually ran"
  end
  -- delayed: returns nil
end
```
* The user callback's return value is **ignored**. Only "did the wrapper run the body" propagates.
* `_currentExecution` is what `delay()` targets. Macros/hotkeys clear it to `nil` afterwards; event callbacks save/restore the previous value instead (`B\functions\callbacks.lua:21-29`) — so `delay()` inside a callback fired *from inside a macro* delays the **callback**, not the macro.

### 1.3 The tick loop (`B\bot.lua:525-546` + `B\executor.lua:194-221`)

`bot.lua:check()`:
```lua
removeEvent(checkEvent)
if not botExecutor then return end
checkEvent = scheduleEvent(check, 10)            -- re-arm BEFORE running
local ok, err = pcall(botExecutor.script)
if not ok then botExecutor = nil; return onError(err) end   -- CRITICAL: bot dies
```
So: **fixed 10 ms period**, re-armed before the body runs (period does not drift with body cost, but a slow body just delays the next fire). An error escaping `script()` itself (not from inside a macro/schedule pcall) permanently kills the bot until the user re-enables it.

`executor.lua:script()`:
```lua
context.now  = g_clock.millis()
context.time = g_clock.millis()                  -- same value, both are the frame clock

for i, macro in ipairs(context._macros) do
  if macro.lastExecution + macro.timeout <= context.now and macro.enabled then
    local ok, err = pcall(function()
      if macro.callback(macro) then macro.lastExecution = context.now end
    end)
    if not ok then context.error("Macro: "..macro.name.." execution error: "..err) end
  end
end

while #context._scheduler > 0 and context._scheduler[1].execution <= g_clock.millis() do
  local ok, err = pcall(context._scheduler[1].callback)
  if not ok then context.error("Schedule execution error: "..err) end
  table.remove(context._scheduler, 1)
end
```

Exact consequences to reproduce:
* `context.now` is sampled **once per tick**; every macro in that tick sees the identical `now`. All time comparisons in scripts (`now - x > y`) are quantised to the tick.
* `g_clock.millis()` is the **frame-cached** clock (`S\framework\core\clock.h:34`, updated once per frame in `clock.cpp`), NOT a fresh read. `g_clock.realMillis()` is the live read and is used only for the slow-macro timing. In luaclient, sample `sys.nowMs()` once at tick start into `now` and use that everywhere.
* The period is measured from the **start of the last successful run**, not from its end: `lastExecution + timeout <= now`.
* If the wrapper returned nil (macro was `delay()`ed), `lastExecution` is **not** advanced → the macro is re-evaluated every 10 ms tick and fires the instant `macro.delay < now`, with no further wait for `timeout`.
* If the user body **throws**, `lastExecution` is also not advanced → the macro throws again on the very next tick. Error spam at 100 Hz is the observed failure mode.
* A macro disabled mid-tick by an earlier macro is skipped in the *same* tick (the `macro.enabled` test is inside the loop).
* Macros added during the loop (`macro()` called from inside a callback) are appended to `_macros`; `ipairs` will reach them **in the same tick** if the index is ahead. Registration during the tick is legal.

### 1.4 Ordering guarantees

* Macros run in **`_macros` array order = registration order = script load order** (`executor.lua:199`). vBot relies on this: `_Loader.lua:18-58` puts `vlib` before everything, `AttackBot` after `HealBot`, `Stances` after `AttackBot`.
* The whole macro pass finishes before the scheduler pass in the same tick (`executor.lua:199-220`).
* There is no priority field, no preemption, no yielding. One macro's body runs to completion.
* Cross-macro coordination is done entirely through shared state in the sandbox globals (`vBot.*`, `storage.*`) and through `delay()`.

### 1.5 `delay(duration)` (`B\functions\main.lua:206-211`)

```lua
context.delay = function(duration)
  if not context._currentExecution then return context.error("Invalid usage of delay …") end
  context._currentExecution.delay = context.now + duration
end
```
* Suspends **the currently executing macro / hotkey / event-callback**, not the bot.
* It is a *field write*, not a sleep: the body keeps running to its `return`. Calling `delay()` twice, the last write wins.
* Called outside any callback (e.g. from a `schedule()` body — `_currentExecution` is nil there) it only logs an error.
* Units: `context.now` (frame clock ms).

### 1.6 `schedule(timeout, callback)` (`B\functions\main.lua:196-203`)

```lua
local t = g_clock.millis() + timeout
table.insert(context._scheduler, {execution = t, callback = callback})
table.sort(context._scheduler, function(a,b) return a.execution < b.execution end)
```
* One **global** queue, not per-macro. It is *not* cancelled when a macro is turned off, when the config is switched, or when the callback's owning module is disabled. Every scheduled closure will fire.
* `table.sort` is **not stable** → two entries with the same `execution` may fire in either order.
* Drained head-first each tick, all entries whose time has come in one pass. Because `g_clock.millis()` does not advance inside a tick, a callback that schedules with delay `0` inserts at the head and **will be executed in the same drain loop** — an easy infinite loop.
* Errors are caught per entry and the entry is still removed.
* Only cleared implicitly by `clear()` destroying the whole executor (`B\bot.lua:111`).

### 1.7 Hotkeys (`B\functions\main.lua:132-193`) — mark as UI/input, keep the data model

`hotkey(keys, [name,] callback, [parent], [single])`, `singlehotkey(...)` = `single = true`.
* Stored in `context._hotkeys[normalisedKeyString]`; duplicates rejected with an error (`main.lua:144-146`).
* Same delay/slow-warning wrapper as macros (`main.lua:167-179`).
* Dispatch (`B\executor.lua:223-268`): `onKeyDown` fires `single` hotkeys once and toggles any macro whose `macro.hotkey == keyDesc` via `macro.switch:onClick()`; `onKeyPress` fires non-single hotkeys repeatedly; `onKeyUp` only resets the switch visual.
* Hotkey enable state is **not** persisted (unlike macros).
* Headless: there is no keyboard. Keep `_hotkeys` as a named command registry addressable from the control plane ("run hotkey F5"), and keep the macro↔hotkey binding as "named toggle".

---

## 2. The storage model

### 2.1 `context.storage`

* A plain Lua table injected into the sandbox (`B\executor.lua:26`) and reachable from scripts as the global `storage` (because `_ENV = context`).
* Loaded from `"/bot/<config>/storage/profile_<N>.json"`, `N = g_settings.getNumber('profile')` (`B\bot.lua:268-282`). Here: `P\storage\profile_1.json` (44 975 bytes on disk).
* `context.storage._macros` is force-created as `{}` if missing (`B\executor.lua:26-29`).
* Scripts mutate it freely; there is no schema and no write barrier. Sub-tables are created lazily by each module (`storage.extras`, `storage.playerList`, `storage.combobot`, …).

### 2.2 When it is written (`B\bot.lua:298-321`)

`save()` is called from exactly three places:
* `terminate()` — module unload (`bot.lua:95`),
* `offline()` — game end / logout (`bot.lua:347`),
* `refresh()` — before every reload, i.e. when the user switches config or toggles enable (`bot.lua:210`).

There is **no periodic autosave**. Consequences to reproduce or deliberately fix:
* `save()` returns immediately if `botExecutor == nil` (`bot.lua:299-301`). So if a macro error killed the executor (§1.3), the whole session's storage changes are silently lost.
* `save()` also returns if the settings node for this character does not exist (`bot.lua:305-307`).
* Encoding is `json.encode(botStorage, 2)` (indent 2). Encode failure → error message, nothing written.
* A result over `100 * 1024 * 1024` bytes is refused (`bot.lua:316-318`).
* Write is a whole-file overwrite, no temp-file + rename. A crash mid-write corrupts it, and a corrupt storage file **aborts bot startup** (`bot.lua:275-281`).

**Recommendation for luaclient:** keep the same file path and JSON shape (so existing profiles load unchanged), but write via temp+rename and add a dirty-flag autosave (e.g. every 30 s and on clean shutdown).

### 2.3 The three reserved keys the engine itself owns

| key | written by | shape |
|---|---|---|
| `storage._macros` | `macro.setOn/setOff` (`main.lua:69,82`) | `{ [macroName]=bool }` |
| `storage._configs` | `Config.setup` (`config.lua:137-147,164-169`) | `{ [dir]={enabled=bool, selected=string} }` |
| `storage._icons` | `addIcon` (`icon.lua:27-45,90,140-147`) | `{ [iconId]={x=float,y=float,enabled=bool} }` — x/y are UI-only |

Everything else under `storage.*` is module-defined data (see §4.4).

### 2.4 vBot's *second*, separate config store

`P\vBot\configs.lua` (loaded 5th by `_Loader`) bypasses `storage` entirely for the three biggest modules:
* Creates `"/bot/<config>/vBot_configs/"` and `profile_1 … profile_10` subdirs (`configs.lua:8-18`).
* Loads `HealBotConfig`, `AttackBotConfig`, `SuppliesConfig` from
  `"/bot/<config>/vBot_configs/profile_<N>/{HealBot,AttackBot,Supplies}.json"` (`configs.lua:22-61`).
* `vBotConfigSave("heal"|"atk"|"supply")` (`configs.lua:63-97`) writes the matching global table back with `json.encode(t, 2)`; same 100 MB guard.
* These are **globals in the sandbox**, not under `storage`, and they are saved eagerly by the owning module whenever a setting changes — unlike `storage`.

---

## 3. The `context` API surface (the sandbox)

`context` is the `_ENV` of every bot script (`B\executor.lua:104-116, 184-190`). It does **not** chain to `_G` — anything not listed is `nil` inside bot scripts. That is why `const.lua` restates direction constants (`B\functions\const.lua:12-18`).

Legend: **[A]** pure game action (maps to `proto/sender.lua`), **[H]** helper over game state (maps to `game/state.lua`), **[E]** engine/runtime, **[U]** UI-only — drop or stub headless, **[X]** external I/O.

### 3.1 Engine

| symbol | signature | semantics |
|---|---|---|
| `macro` | `(timeout, [name], [hotkey], callback, [parent]) -> macro` | §1.1 **[E]** |
| `hotkey` / `singlehotkey` | `(keys, [name], callback, [parent], [single])` | §1.7 **[E/U]** |
| `schedule` | `(timeoutMs, fn)` | §1.6 **[E]** |
| `delay` | `(ms)` | §1.5 **[E]** |
| `callback` | `(type, fn) -> {remove=fn}` | §5 **[E]** |
| `storage` | table | §2 **[E]** |
| `now`, `time` | number | frame ms, re-sampled per tick (`executor.lua:196-197`) **[E]** |
| `player` | LocalPlayer | captured **once** at `executeBot` time (`executor.lua:168`) **[E]** |
| `panel`, `tabs`, `mainTab`, `configDir` | — | `configDir = "/bot/<config>"` **[E/U]** |
| `saveConfig`, `reload` | `()` | force storage save / full bot reload (`executor.lua:26-27`; `reload()` used at `P\vBot\ingame_editor.lua:6`) **[E]** |
| `info(s)`, `warn(s)`/`warning(s)`, `error(s)` | | log lines, 5-line ring, 5 s TTL (`bot.lua:503-523`) **[E]** |
| `print`, `pairs`, `ipairs`, `tostring`, `tonumber`, `type`, `pcall`, `assert`, `math`, `table`, `string`, `setmetatable`, `bit`, `bit32`, `gcinfo` | stdlib subset (`executor.lua:83-119`) | **[E]** |
| `os` | `{time, difftime, date, clock}` only (`executor.lua:96-101`) | **[E]** |
| `load`/`loadstring`, `dofile` | compile with `_ENV = context` (`executor.lua:102-117`) | **[E]** |
| `json`, `encode(t,[indent=2])`, `decode(s)` (`tools.lua:3-4`), `base64`, `regexMatch` | | `decode` swallows errors → `{}` **[E]** |
| `getDistanceBetween(p1,p2)` | `max(|dx|,|dy|)` (`executor.lua:124-126`) | Chebyshev, **ignores z** **[H]** |
| `loadScript(path,[cb])`, `loadRemoteScript(url,[cb])` | `script_loader.lua:3-70` | remote scripts are cached into `storage.scriptsCache[url]` and reused when the fetch fails **[X]** |

### 3.2 Player state (all read `context.player`) — `B\functions\player.lua:3-52`, `player_conditions.lua`, `player_inventory.lua` **[H]**

`name() hp() mana() hppercent() manapercent() maxhp() maxmana() hpmax() manamax() cap() freecap() maxcap() capmax() exp() lvl() level() mlev() magic() mlevel() soul() stamina() voc() vocation() bless() blesses() blessings() pos() posx() posy() posz() direction() speed() skull() outfit()`

* `manapercent()` returns **100** when `maxMana <= 1` (`player.lua:8-15`) — avoids div-by-zero for knights.
* `hppercent()` is the server-sent percent, not `hp/maxhp`.

Conditions (`player_conditions.lua:7-33`): `hasCondition(mask)` = `bit.band(player:getStates(), mask) > 0`; then `isPoisioned` (sic) `isBurning isEnergized isDrunk hasManaShield hasNewManaShield isParalyzed hasHaste hasSwords isInFight canLogout isDrowning isFreezing isDazzled isCursed hasPartyBuff hasPzLock/hasPzBlock/isPzLocked/isPzBlocked isInProtectionZone/hasPz/isInPz isBleeding isHungry`. `isInFight` and `canLogout` are aliases of the `Swords` bit. Maps directly onto `st.player.states`.

Inventory (`player_inventory.lua:16-45`): `getInventoryItem(slot)`/`getSlot`, `getHead getNeck getBack getBody getRight getLeft getLeg getFeet getFinger getAmmo getPurse`, `getContainers()`, `getContainer(i)`, `moveToSlot(item, slot, [count])` → `g_game.move(item, {x=65535,y=slot,z=0}, count)` **[A]**.

### 3.3 Pure game actions **[A]** — `B\functions\player.lua:64-211`, `map.lua:223-237`

| context fn | wire behaviour | luaclient mapping |
|---|---|---|
| `walk(dir)` | `modules.game_walk.smartWalk(dir)` — client-side diagonal merge + prewalk. Behaviour that matters: it sends one walk step. | `sender:walk(dir)` |
| `turn(dir)` | `g_game.turn` | `sender:turn(dir)` |
| `say(text,[aimMode],[aimPos])` | tries `tryCastSpellMessage` first (spells ≥15.25 carry an aim byte and the server rejects `aim=none`); falls back to `g_game.talk` = `talkChannel(MessageSay=1, 0, text)` (`S\client\game.cpp Game::talk`) | `sender:talkSpell(text, aimMode, pos)` for known spell words, else `sender:talk(1,0,"",text)` |
| `talk` | alias of `say` | |
| `castSpellAt(text,pos)` | `g_game.talkSpell(text, SpellAimCursor=2, pos)` (`player.lua:101-120`) | `sender:talkSpell(text, 2, pos)` |
| `yell(text)` | `talkChannel(3,0,text)` — `MessageYell` | `sender:talk(3,0,"",text)` |
| `talkChannel(ch,text)` / `sayChannel` | `talkChannel(7, ch, text)` — `MessageChannel` | `sender:talk(7,ch,"",text)` |
| `talkPrivate(to,text)` / `sayPrivate` | `talkPrivate(5, to, text)` — `MessagePrivateTo` | `sender:talk(5,0,to,text)` |
| `talkNpc(text)` (+ aliases `sayNpc sayNPC talkNPC NPC.talk NPC.say`) | version ≥ 810: `talkChannel(11,0,text)` — `MessageNpcTo`; else `say` (`player.lua:128-137`, `npc.lua:5-12`) | `sender:talk(11,0,"",text)` |
| `saySpell(text,[timeout=1000])` | global one-shot rate limit: refuses if `context.lastSpell + timeout > now`, else says and stamps `lastSpell` (`player.lua:139-155`). Returns bool. | pure logic |
| `setSpellTimeout()` | `lastSpell = now` (`player.lua:157-159`) | |
| `use(thing|itemId, [subtype])` | number → `useInventoryItem(id)` = sendUseItem(`{0xFFFF,0,0}`, id, 0, 0); object → `use(thing)` = sendUseItem(pos, id, stackpos, **findEmptyContainerId()**) (`S\client\game.cpp Game::use`) | `sender:use(pos,id,stack,index)` |
| `usewith`/`useWith(thing, target, [subtype])` | number → `useInventoryItemWith`; object → `useWith`. If target is a creature → `sendUseOnCreature`; else `sendUseItemWith` (`S\client\game.cpp`) | `sender:useWith(...)` / `sender:useOnCreature(...)` |
| `useRune(id, target)` | 1000 ms global rate limit via `context.lastRuneUse` (`player.lua:180-193`). **Bug preserved in vBot:** the local `lastRuneTimeout` is read as a global and is always nil→1000. | |
| `attack(c)` `cancelAttack()` `follow(c)` `cancelFollow()` `cancelAttackAndFollow()` | direct `g_game.*` | `sender:attack/follow/cancelAttackAndFollow` |
| `logout()` / `safeLogout()` | `forceLogout` / `safeLogout` | `sender:logout()` |
| `ping()` | `g_game.getPing()` ms | transport stat |
| `setOutfit(outfit)` / `changeOutfit` | `requestOutfit()` then `schedule(100, changeOutfit(outfit))` (`player.lua:54-60`) — the 100 ms gap is required by the protocol handshake | `sender:requestOutfit()` + `sched.after(100, …changeOutfit)` |
| `setSpeed(v)` | client-side only | ignore |
| `autoWalk(dest,[maxDist],[params])` or `autoWalk(dirsList)` | list form → `g_game.autoWalk(dirs, {0,0,0})`; else `findPath` then autoWalk (`map.lua:223-237`) | `sender:autoWalk(dirs)` — **respect the 127-step clamp** documented in API.md |

`NPC.*` trade wrappers (`B\functions\npc.lua:14-131`) **[A/H]**: `isTrading()` (+ aliases `hasTrade hasTradeWindow isTradeOpen`), `getSellItems()`, `getBuyItems()` (both return `{item,id,count,name,subType,weight=w/100,price}`), `getSellQuantity(item)`, `canTradeItem(item)`, `sell(item,[count],[ignoreEquipped=true])` (`count == nil or -1` → sell all, `count == 0` → 1), `buy(item,[count=1],[ignoreCapacity=false],[withBackpack=false])`, `sellAll()`, `closeTrade()` (+ `close finish endTrade finishTrade`). Map to `sender:buyItem/sellItem/closeNpcTrade`; the item lists come from the NPC-trade packet, which the headless client must parse and cache.

### 3.4 Map / spectator helpers **[H]** — `B\functions\map.lua`

* `getSpectators([param1],[param2])` (`map.lua:8-37`). Argument sniffing:
  * `param1` table → used as centre position, `direction = 8` (invalid, so N/E/S/W pattern cells never match), `param1 = param2`.
  * `param1` userdata (creature) → centre = its position, direction = its direction, `param1 = param2`.
  * `param1` string → `g_map.getSpectatorsByPattern(pos, pattern, direction)`.
  * `param1 == true` → multifloor.
  * default → `g_map.getSpectators(pos, multifloor)`.
* Underlying `getSpectators` = rectangle of the **aware range** around the centre (`S\client\map.h:166-170` → `getSpectatorsInRangeEx(centerPos, multiFloor, awareRange.left, .right, .top, .bottom)`); multifloor spans `getFirstAwareFloor()..getLastAwareFloor()`; duplicates removed by creature id (`S\client\map.cpp:651-691`).
* `getSpectatorsByPattern` (`S\client\map.cpp:1475-1543`): the pattern is an ASCII block; `0`/`-` = off, `1`/`+` = on, `N/E/S/W` (case-insensitive) = on only when the reference direction matches. Width and height **must both be odd** or it returns empty and logs. Centre cell = centre position. Single floor only (`centerPos.z`). Ready-made patterns live in `P\vBot\vlib.lua:1151-1297` (`LargeUeArea NormalUeAreaMs NormalUeAreaEd smallUeArea largeRuneArea adjacentArea longBeamArea shortBeamArea newWaveArea bigWaveArea smallWaveArea diamondArrowArea`).
* `getCreatureById(id,[multifloor=false])`, `getCreatureByName(name,[multifloor])`, `getPlayerByName(name,[multifloor])` (`map.lua:39-78`) — all **linear scans over `getSpectators`**, i.e. they only find creatures inside the aware range, not the whole `state.creatures` map. Name compare is lowercased. In luaclient, `st:getCreature(id)` is a hash lookup, but to be behaviour-identical also gate on `st:isAwareOf(pos)`.
* `findAllPaths(start, maxDist, params)` / `findEveryPath` (`map.lua:80-113`) → `g_map.findEveryPath`. Returns a map `"x,y,z" -> {cost, ?, direction, prevPosStr}`. Params (booleans converted to 0/1): `ignoreLastCreature ignoreCreatures ignoreNonPathable ignoreNonWalkable ignoreStairs ignoreCost allowUnseen allowOnlyVisibleTiles maxDistanceFrom destination`.
* `translateAllPathsToPath(paths, destPos)` (`map.lua:116-140`): walk `node[4]` (previous position string) back from the destination, collecting `node[3]` (direction), stop on `node[3] < 0` (the start), then reverse. Straightforward to reimplement on top of your own Dijkstra.
* `findPath(startPos, destPos, [maxDist=100], [params])` (`map.lua:143-219`):
  1. returns nil if `destPos` missing or `startPos.z ~= destPos.z` (**never cross-floor**);
  2. sets `params.destination`;
  3. if `marginMin`/`marginMax` (aliases `minMargin`/`maxMargin`) are both numbers → search the ring `marginMin <= max(|x|,|y|) <= marginMax` around the destination for the cheapest reachable node, and path there;
  4. else if the exact destination is unreachable and `params.precision = p` → expand square radii `1..p`, cheapest node wins;
  5. else nil.
* `canShoot(pos,[distance=5])` → `tile:canShoot(distance)` (`map.lua:249-256`) — line-of-sight.
* `isTrapped([creature=player])` (`map.lua:258-271`): true when **none** of the 8 neighbours is `isWalkable(false)`. Note the sign inversion in the loop (`pos.x - dirs[i][1]`) — it enumerates the same 8 neighbours, just mirrored, so behaviour is unaffected.
* `getMapView/getMapPanel/zoomIn/zoomOut/getTileUnderCursor` **[U]** — drop.

### 3.5 Items / channels **[H]**

* `findItem(itemId, [subType=-1], [tier])` (`player.lua:196-201`) → `g_game.findPlayerItem` (`M\gamelib\game.lua:5-16`): scan inventory slots `InventorySlotFirst=1 .. InventorySlotLast=10` (Head→Ammo, **Purse=11 excluded**) matching id and (`subType == -1` or exact subType); then `g_game.findItemInContainers(id, subType, tier or 0)` = iterate open containers in **container-id order** (`std::map`), and inside each, items in slot order, requiring `item:getTier() == tier` (`S\client\container.cpp Container::findItemById`). Returns the *first* match or nil. **Open containers only** — see the pitfalls.
* `getChannels()` → `{ [id] = name }` (`player.lua:68-71`), `getChannelId(name)`/`getChannel(name)` — case-insensitive reverse lookup (`player.lua:72-80`). Maps onto `st.channels`.

### 3.6 UI **[U]** — enumerate to know what to *drop*

`B\functions\ui.lua`, `ui_elements.lua`, `ui_legacy.lua`, `ui_windows.lua`, `icon.lua`, `sound.lua`, `tools.lua`:
`UI.createWidget UI.createMiniWindow UI.createWindow UI.Button UI.Config UI.Container UI.DualScrollPanel UI.DualScrollItemPanel UI.Label UI.Separator UI.TextEdit UI.TwoItemsAndSlotPanel UI.DualLabel UI.LabelAndTextEdit UI.SwitchAndButton UI.EditorWindow UI.SinglelineEditorWindow UI.MultilineEditorWindow UI.ConfirmationWindow`, and legacy `createWidget setupUI importStyle addTab getTab setDefaultTab addSwitch addButton addLabel addTextEdit addSeparator _addMacroSwitch _addHotkeySwitch`, plus `addIcon` (`icon.lua:5-176`), `displayGeneralBox`, `doScreenshot`/`screenshot`, `getSoundChannel playSound stopSound playAlarm`, `getMapView zoomIn zoomOut getTileUnderCursor`, and the raw `g_ui g_window g_mouse g_keyboard modules` handles (`executor.lua:131-158`).

**Headless strategy:** provide these as no-op stubs that still run the callback plumbing, because module scripts read their *config values* out of widgets. Specifically:
* `UI.Config()` must return an object with `.list` (`clear/addOption/setCurrentIndex/getCurrentOption`), `.switch` (`isOn/setOn/onClick`), `.add/.edit/.remove` — `Config.setup` drives all of them (§4).
* `addSwitch` must return an object with `setOn/isOn/onClick`, because `macro.switch` is used by `setOn/setOff` and by hotkey dispatch.
* `addTextEdit`/`UI.TextEdit`/`UI.Container` etc. must fire their `onTextChange`/`onItemChange` callback once with the initial value, because that is how modules push widget values into `storage`.

The cleanest port is: replace each widget factory with a headless "control" object registered under a path (`tab/name`), backed by the same `storage` key the module already writes, and let the control plane set values by calling the stored callback.

### 3.7 External I/O **[X]**

* `HTTP` (`executor.lua:154`) — `HTTP.get/postJSON/download/WebSocketJSON/cancel`.
* `BotServer` (`B\functions\server.lua:3-206`) — the party relay. Behaviour worth porting verbatim:
  * `BotServer.defaultUrl = "ws://etlac.cryrex.net:8000/natitest"`; overridden per profile by `storage.BotServerUrl` (`server.lua:14-19`).
  * The **room is the channel name** (`storage.BotServerChannel`), not the URL path (`server.lua:11-13`).
  * `init(name, channel)` opens a JSON websocket; the `{type="init", name, channel, lastMessage}` frame **must be sent from `onOpen`**, not right after the constructor — sending earlier races the handshake and is silently dropped (`server.lua:54-68`).
  * `onMessage`: `type=="ping"` → store `message.ping` and echo `{type="ping"}`; `type=="message"` → stamp `_lastMessageId = message.id`, dispatch to `_callbacks[topic]` then `_callbacks["*"]` with `(name, message, topic)` (`server.lua:79-106`).
  * Reconnect: exponential backoff `reconnectDelay(2000) * 2^(min(attempts,5)-1)`, max 10 attempts; a `"resolve error"` sets `stopReconnect` (`server.lua:26-43, 75-77`).
  * `requestReconnect([delayMs=1200])` is generation-debounced so per-keystroke edits do not hammer the relay (`server.lua:176-206`); `terminate()` wipes `_callbacks`, so listeners must be re-registered via `initBotServerListenFunctions()`.
  * `listen(topic, cb)`, `send(topic, msg)`, `isConnected()`, `hasListen(topic)`, `resetReconnect()`.
  * `timeout = 3` (seconds).

---

## 4. The `Config.setup` named-profile system

`B\functions\config.lua`. This is what backs "cavebot_configs" and "targetbot_configs" — a *set of named route/target configs* selectable at runtime, distinct from the bot-config directory of §0.

### 4.1 Where the pieces live on disk (real files)

```
…\otclient\profiles\
  config.otml                                  <- client settings; contains  profile: 1   (line 47)
                                                  and the  bot:  node (line 2572+)
  bot\
    vBot_4.8\                                  <- one "bot config"  (context.configDir = "/bot/vBot_4.8")
      _Loader.lua                              <- the ONLY top-level lua; loads everything else
      storage\profile_1.json                   <- context.storage
      vBot_configs\profile_1..10\{HealBot,AttackBot,Supplies}.json
      cavebot_configs\*.cfg                    <- Config.setup("cavebot_configs", …, "cfg")
      targetbot_configs\*.json                 <- Config.setup("targetbot_configs", …, "json")
      vBot\ cavebot\ targetbot\ navibot\       <- the script trees
```

`profiles\config.otml`, real content:
```otml
profile: 1
…
bot:
  Wfawdsafwfwad_1530:
    enabled: true
    config: vBot_4.8
  Tmk Creew_1530:
    config: EK Main
    enabled: true
```
Key = `"<CharacterName>_<clientVersion>"` (`B\bot.lua:187, 222`). This is the only place "which bot config is active for this character" and "is the bot on" live.

### 4.2 The primitives (`config.lua:11-126`) — file-format agnostic

* `Config.exist(dir)` / `Config.create(dir)` — `<configDir>/<dir>`.
* `Config.list(dir)` — `listDirectoryFiles`, strip `.json`/`.cfg`, **keep only entries whose name changed** (i.e. drop files with any other extension). Sorted alphabetically by the underlying enumerator. Auto-creates the dir.
* `Config.parse(data)` — try `json.decode` first (empty/`<2` chars → `{}`); on failure try `table.decodeStringPairList`; on failure `error`.
* `Config.load(dir, name)` — `<dir>/<name>.json` via json, else `<dir>/<name>.cfg` via `table.decodeStringPairList`, else error.
* `Config.loadRaw(dir, name)` — raw text of whichever exists.
* `Config.save(dir, name, value, forcedExtension)` — if `table.isStringPairList(value)` and `forcedExtension ~= "json"`, or `forcedExtension == "cfg"` → write `<name>.cfg` with `table.encodeStringPairList`; else `<name>.json` with `json.encode(value, 2)`.
* `Config.remove(dir, name)` — deletes both extensions if present.

`table.encodeStringPairList` / `decodeStringPairList` (`M\corelib\table.lua:279-320`): a list of `{keyString, valueString}` pairs, serialised one per line as `key:value\n`; a value containing `\n` becomes `key:[[\n<value>\n]]\n`. Decoding uses the regex `(?:^|\n)([^:^\n]{1,20}):?(.*)(?:$|\n)` — **the key is capped at 20 characters** and may not contain `:` or `\n`.

### 4.3 `Config.setup(dir, widget, configExtension, callback)` (`config.lua:130-269`)

State (persisted): `storage._configs[dir] = { enabled = bool, selected = string }` — created as `{enabled=false, selected=""}` on first use (`config.lua:137-144`); on subsequent runs the switch is restored from `enabled` (`config.lua:146`).

`refresh()` (`config.lua:150-172`) is the single state machine, and it is called immediately at setup (`config.lua:229`), on selection change, and on switch toggle:
```
configs = Config.list(dir)
rebuild the option list; configIndex = index of storage._configs[dir].selected, default 1
if #configs > 0:
    select configIndex
    storage._configs[dir].selected = <selected option text>
    data = Config.load(dir, configs[configIndex])
else:
    storage._configs[dir].selected = nil ; data = nil
storage._configs[dir].enabled = <switch state>
callback(selected, enabled, data)          -- data may be nil
```
An `isRefreshing` re-entrancy guard prevents the option-change handler from recursing (`config.lua:149, 174-179`).

Returned handle (`config.lua:231-268`), which is what modules keep:
`isOn() isOff() setOn(val) setOff(val) save(data) refresh() reload() getActiveConfigName()`.
`setOn/setOff` work by *simulating a click* on the switch (which calls `refresh()` → the callback), so **switching a config on re-loads and re-applies it**. `save(data)` = `Config.save(dir, selected, data, configExtension)`.

Add/edit/remove (`config.lua:186-227`) are UI flows: `add` validates the name (whitespace→`_`, non-empty, `<30` chars, no `/` or `\`), refuses an existing file, seeds `{}` for json / `""` for cfg, then turns the switch **off** and refreshes. `remove` also turns the switch off. Headless: expose these as control-plane commands with the same validation.

**Consumers, verbatim:**
* `P\cavebot\cavebot.lua:207` — `Config.setup("cavebot_configs", configWidget, "cfg", function(name, enabled, data) … end)`
* `P\targetbot\target.lua:131` — `Config.setup("targetbot_configs", configWidget, "json", function(name, enabled, data) … end)`

### 4.4 The two config file shapes, with real files

**`cavebot_configs/*.cfg`** — a string-pair list; every action is one `action:value` line, in route order, followed by three reserved trailing pairs written by `CaveBot.save()` (`P\cavebot\cavebot.lua:578-610`): `config` (JSON of the CaveBot settings), `extensions` (JSON keyed by extension name), `staypositions` (JSON `{"<1-based action index>": {x,y,z}}`).

Real file `P\cavebot_configs\test.cfg` (complete, 6 lines):
```
goto:33218,32434,7,0
exanihur:up,north
exanihur:down,south
config:{"ignoreFields":false,"skipBlocked":false,"antiLostLadderIds":"1948,1968,5542,…","ping":100,"antiLostRopeToolId":9596,"stayPathEnabled":true,"waypointHud":false,"walkDelay":10,"avoidTileIds":"","avoidFloorChange":true,"mapClickDelay":100,"useDelay":400,"wptDistance":5,"antiLostTeleportIds":"1949,1950,1951,1952","mapClick":false,"smoothWalk":false,"antiLostRopeIds":"386,7762,12935,12936,13381,33051","antiLostEnabled":true}
extensions:[]
staypositions:{"3":{"x":33218,"y":32433,"z":6},"2":{"x":33218,"y":32434,"z":7}}
```

**`targetbot_configs/*.json`** — a plain JSON object `{targeting=[…], looting={…}}` (`P\targetbot\target.lua:238-245`). Real file `P\targetbot_configs\def_target.json` (complete):
```json
{"targeting":[{"name":"*","rpSafe":false,"anchor":false,"lureCount":1,"closeLure":false,
"anchorRange":3,"regex":"^.*$","priority":1,"dynamicLureDelay":false,"lureMax":3,
"avoidAttacks":false,"delayFrom":3,"dynamicLure":true,"lureDelay":625,"rePosition":false,
"closeLureAmount":3,"lureCavebot":false,"lure":false,"danger":1,"maxDistance":10,
"dontLoot":true,"rePositionAmount":5,"keepDistance":false,"keepDistanceRange":1,
"chase":true,"lureMin":1,"faceMonster":false,"diamondArrows":false}],
"looting":{"everyItem":false,"maxDanger":10,"minCapacity":100,
"containers":[{"count":0,"id":2854}],"items":[{"count":0,"id":9084}]}}
```

**`storage/profile_1.json`** — real top-level keys in this profile:
`AutoImbueManager AutoTrainingWeapon BOTserver BotServerChannel BotServerUrl EquipperPanel _configs _icons _macros alarms analyzers autoEquip autoImbue autoTradeMessage bestHeal bestHit caveBot caveBotTasker cavebotSell cavebotSellMigrated combobot dropper extras foodItems ingame_hotkeys moneyItems navibot newHealer playerList pushmax renameContainers specialDeposit stances`

with the engine-owned parts exactly as:
```json
"_configs": { "targetbot_configs": {"enabled": false, "selected": "true_asura"},
              "cavebot_configs":   {"enabled": false, "selected": "true_asura_mk"} },
"_macros":  { "": false, "AntiRS & Msg": false, "Exchange money": true,
              "Exeta when low hp": false, "Hold Target": true,
              "Auto Equip 35901": true, "ripper spectre switch": false },
"_icons":   { "looter": {"y":0.25,"enabled":false,"x":0.01},
              "might_auto": {"y":0.12320916905444,"enabled":false,"x":0.010135135135135},
              "ssa_auto": {"y":0.45,"enabled":false,"x":0.01} }
```
(The `"": false` entry is the unnamed macro whose `setOff()` was called; see §1.1.)

---

## 5. Event callbacks

### 5.1 Registration (`B\functions\callbacks.lua:4-46`)

```lua
context.callback(callbackType, fn) -> { remove = function() … end }
```
* Unknown `callbackType` → hard `error`.
* Registering `onAddThing`/`onRemoveThing` turns on `g_game.enableTileThingLuaCallback(true)` — a global perf switch, off by default and reset in `clear()` (`bot.lua:117`). Behavioural meaning: **tile add/remove events are only delivered if at least one script asked for them.** Worth mirroring (they are the highest-volume events by far).
* The stored function is a wrapper with the same delay gate and >100 ms slow warning as macros, but it **saves and restores** `_currentExecution` (`callbacks.lua:20-30`) so nesting works.
* **`remove()` is broken as written** (`callbacks.lua:33-45`): it compares the whole callback *list* (`cb`) against each element instead of comparing the wrapper. It never matches, so nothing is removed. Reimplement properly (return the wrapper and remove by identity) — no vBot script depends on the broken behaviour.

### 5.2 Full callback list and payloads

The engine allocates one list per type (`B\executor.lua:39-80`), the bot module subscribes to the client (`B\bot.lua:549-614`), each client signal calls the executor's dispatcher inside `safeBotCall` (a pcall that reports the error and keeps the bot alive — `bot.lua:677-682`), and each dispatcher iterates its list in registration order (`B\executor.lua:222-444`).

| context registrar | payload | luaclient event (API.md `LC.events`) | what the bot/vBot does with it |
|---|---|---|---|
| `onKeyDown(fn)` | `(keyDesc)` | — **[U]** | also toggles macros bound to that hotkey and fires `single` hotkeys (`executor.lua:223-244`) |
| `onKeyUp(fn)` | `(keyDesc)` | — **[U]** | resets hotkey switch |
| `onKeyPress(fn)` | `(keyDesc, autoRepeatTicks)` | — **[U]** | fires non-single hotkeys |
| `onTalk(fn)` | `(name, level, mode, text, channelId, pos)` | `talk` | **heavily used.** `vlib.lua:233-241`: own name + `mode == 34` (`MessageBarkLow`) + `text == "Aaaah..."` → `vBot.isUsingPotion = true` for 950 ms. `vlib.lua:249-254`: own name → stamp `SpellCastTable[text:lower()].t = now` (the "was the spell actually cast" oracle). `vlib.lua:302-307`: own name → `lastPhrase = text:lower()`, used to attribute the next cooldown packet to a spell. |
| `onTextMessage(fn)` | `(mode, text)` | `textMessage` | `vlib.lua:49-64`: parse `"you lose N … due to"` into a 3-second sliding damage window (`burstDamageValue()`), pruned at 3000 ms with a 3050 ms `schedule` sweep. |
| `onLoginAdvice(fn)` | `(message)` | `loginAdvice` | |
| `onAddThing(fn)` / `onRemoveThing(fn)` | `(tile, thing)` | `tileUpdate` / thing-level | gated by `enableTileThingLuaCallback` |
| `onCreatureAppear(fn)` / `onCreatureDisappear(fn)` | `(creature)` | `creatureAppear` / `creatureDisappear` | targeting, alarms |
| `onCreaturePositionChange(fn)` | `(creature, newPos, oldPos)` | `creatureMove` / `positionChange` | `onPlayerPositionChange` sugar filters `creature == context.player` (`callbacks.lua:256-262`); `vlib.lua:21-27` uses it for `standTime()` |
| `onCreatureHealthPercentChange(fn)` | `(creature, healthPercent)` | `creatureHealth` | `onPlayerHealthChange` sugar (`callbacks.lua:265-271`) |
| `onUse(fn)` | `(pos, itemId, stackPos, subType)` | (local echo) | `vlib.lua:393-403`: an adjacent, non-container use sets `isUsingTime = now + 1000`, driving `vBot.isUsing` (a 100 ms unnamed macro at `vlib.lua:390-392`) so scripts back off while the human is acting |
| `onUseWith(fn)` | `(pos, itemId, target, subType)` | (local echo) | same, when `pos.x < 65000` (`vlib.lua:404-406`) |
| `onContainerOpen(fn)` | `(container, previousContainer)` | `containerOpen` | |
| `onContainerClose(fn)` | `(container)` | `containerClose` | |
| `onContainerUpdateItem(fn)` | `(container, slot, item, oldItem)` | `containerUpdateItem` | |
| `onAddItem(fn)` | `(container, slot, item, oldItem)` | `containerAddItem` | looting |
| `onRemoveItem(fn)` | `(container, slot, item)` | `containerRemoveItem` | |
| `onMissle(fn)` | `(missle)` | `distanceEffect` | |
| `onAnimatedText(fn)` | `(thing, text)` | `animatedText` | damage analysers |
| `onStaticText(fn)` | `(thing, text)` | `staticText` | |
| `onChannelList(fn)` | `(channels)` | `channelList` | |
| `onOpenChannel(fn)` | `(channelId, name)` | `openChannel` | |
| `onCloseChannel(fn)` | `(channelId)` | `closeChannel` | |
| `onChannelEvent(fn)` | `(channelId, name, event)` | — | |
| `onTurn(fn)` | `(creature, direction)` | — | |
| `onWalk(fn)` | `(creature, oldPos, newPos)` | `creatureMove` | |
| `onImbuementWindow(fn)` | `(itemId, slots, activeSlots, imbuements, needItems)` | — | `P\cavebot\imbuing.lua` |
| `onModalDialog(fn)` | `(id, title, message, buttons, enterButton, escapeButton, choices, priority)` | `modalDialog` | priority is unused (`callbacks.lua:183`) |
| `onAttackingCreatureChange(fn)` | `(creature, oldCreature)` | (derive from `attack`/`attackCancel`) | |
| `onManaChange(fn)` | `(player, mana, maxMana, oldMana, oldMaxMana)` | `manaChange` | LocalPlayer only |
| `onStatesChange(fn)` | `(player, states, oldStates)` | (states in `healthChange`/status packet) | condition-driven modules |
| `onInventoryChange(fn)` | `(player, slot, item, oldItem)` | `inventoryChange` | `onPlayerInventoryChange` sugar (`callbacks.lua:274-280`) |
| `onGameEditText(fn)` | `(id, itemId, maxLength, text, writer, time)` | — | |
| `onSpellCooldown(fn)` | `(iconId, duration)` | `spellCooldown` | see §5.3 |
| `onGroupSpellCooldown(fn)` | `(iconId, duration)` | `spellGroupCooldown` | see §5.3 |
| `onInventoryItemsUpdate(fn)` | `()` (registers under `"updateInventoryItems"`) | inventory-list packet **0xF5** | fired whenever any carried item's amount changes, **including inside closed containers** (`callbacks.lua:233-240`, `bot.lua:872-879`) |

Derived sugar (`callbacks.lua:245-280`):
* `listen(name, fn)` → `onTalk` filtered by `name:lower() == speaker:lower()`, callback gets `(text, channelId, pos)`.
* `onPlayerPositionChange(fn)` → `(newPos, oldPos)`.
* `onPlayerHealthChange(fn)` → `(healthPercent)`.
* `onPlayerInventoryChange(fn)` → `(slot, item, oldItem)`.

**Note on `LocalPlayer` subscriptions** (`bot.lua:591-599`): only LocalPlayer-*exclusive* signals are connected there (`onManaChange`, `onStatesChange`, `onInventoryChange`). Re-listing a `Creature` signal on `LocalPlayer` would double-dispatch every local-player emit because `connect()` resolves through the metatable chain. In a headless client with one flat event bus this hazard disappears, but the *semantics* must be preserved: `onCreaturePositionChange` etc. fire for the local player too.

### 5.3 The spell-cooldown model (behaviour, and a UI trap)

vBot builds its own cooldown table because the client's spell list does not know custom-server spells (`P\vBot\vlib.lua:309-384`):
* On `onTalk` with own name, `lastPhrase = text:lower()` (`vlib.lua:302-307`).
* On `onSpellCooldown(iconId, duration)` → `schedule(1, …)` then `vBot.customCooldowns[lastPhrase] = {id = iconId}` if not already known (`vlib.lua:310-316`).
* On `onGroupSpellCooldown(iconId, duration)` → `schedule(2, …)` then attach `group = {[iconId] = duration}` to that entry (`vlib.lua:318-324`).
  The 1 ms / 2 ms schedules exist purely to order these two after the `onTalk` that set `lastPhrase`.
* `getSpellData(words)` (`vlib.lua:333-359`): look up `modules.gamelib.SpellInfo['Default']` by `v.words == spell` → `{id, words, exhaustion, premium, type, icon, mana, level, soul, group, vocations}`; otherwise fall back to `vBot.customCooldowns[spell]` → `{id, mana=1, level=1, group}`; otherwise `false`.
* `getSpellCoolDown(words)` (`vlib.lua:363-384`) = `isCooldownIconActive(data.id)` **or** any `isGroupCooldownIconActive(groupId)` over `data.group or {}` (the `or {}` is load-bearing: custom entries have no group).
* `canCast(spell, ignoreRL, ignoreCd)` (`vlib.lua:279-300`) — the base of AttackBot and HealBot:
  1. if `SpellCastTable[spell]` exists (a `cast()`-managed spell) → `now - t > d or ignoreCd`;
  2. else if `getSpellData(spell)` → `(ignoreCd or not getSpellCoolDown(spell)) and (ignoreRL or (level() >= data.level and mana() >= data.mana))`;
  3. else **true** (unknown spell ⇒ assume castable).
* `cast(text, delay)` (`vlib.lua:258-271`): `delay` nil or `< 100` → plain `say`. Otherwise register/refresh `SpellCastTable[text] = {t = now - delay, d = delay}` (so the first cast fires immediately) and `say`; on later calls only say when `now - t > d`. `t` is corrected by the `onTalk` echo (`vlib.lua:249-254`), i.e. the cooldown is measured from *server-confirmed* utterance, not from the send.

**UI trap to fix, not port:** `modules.game_cooldown.onSpellCooldown` returns early when the cooldown window is not visible (`M\game_cooldown\cooldown.lua:539-544`) and `onSpellGroupCooldown` requires the group icon widget to exist (`cooldown.lua:562-573`), so `isCooldownIconActive` is only correct while that window is open. `isCooldownIconActive(iconId)` itself is `type(cooldown[iconId]) == 'number' and g_clock.millis() < cooldown[iconId]` on tier-upgrade clients, else a boolean (`cooldown.lua:521-537`). In luaclient, feed `spellCooldown`/`spellGroupCooldown` straight into two tables `cooldownUntil[iconId] = now + duration` / `groupCooldownUntil[groupId] = now + duration` with no widget gating — same API, strictly more correct.

---

## 6. What is behaviour vs. what is a widget detail — summary

**Behaviour (must port):** the 10 ms tick, the 50 ms macro floor, `lastExecution + timeout <= now`, the initial `random(0,100)` jitter, per-macro/per-callback `delay`, the global sorted scheduler, registration-order execution, per-macro pcall isolation vs. fatal `script()` errors, the sandboxed `_ENV` with a fixed global set, `storage` and its three reserved keys, the save-on-{terminate,offline,refresh} policy, `Config.setup`'s `{enabled, selected}` state machine and its "switch on ⇒ reload+reapply" semantics, the `.cfg`/`.json` formats, the callback registry with its exact payload shapes, and the cooldown/`canCast` model.

**Widget detail (drop or stub):** tabs and panels, switches/buttons/labels/text-edits/item-containers, `addIcon` positioning (`storage._icons[id].x/.y`), sound, screenshots, `getTileUnderCursor`, the config upload/download to `http://otclient.ovh/configs.php` (`bot.lua:20, 406-500`), the message ring buffer, `panels/*` (explicitly deprecated: `B\panels\DONT_USE_PANELS.txt`).

**Where widget values are persisted** (the mapping a headless client needs): every widget in vBot writes its value into `storage.<moduleKey>` in its own `onTextChange`/`onClick`/`onValueChange` handler (see the `UI.*` factories in `B\functions\ui_elements.lua`), except macro toggles (`storage._macros[name]`), config selection (`storage._configs[dir]`), icons (`storage._icons[id]`), and HealBot/AttackBot/Supplies which live in `vBot_configs/profile_<N>/*.json` via `vBotConfigSave` (`P\vBot\configs.lua:63-97`). A headless client should read those files/keys directly and expose them for editing; it never needs a widget.

## Configuration format

Five distinct persisted stores. All paths are relative to the client write dir, which for this install is `D:\Claude\otclient_mehah1530\otclient\profiles\` (set via `--user-dir`; see S\framework\core\resourcemanager.cpp:385-410).

--------------------------------------------------------------------
(1) WHICH BOT CONFIG IS ACTIVE + IS THE BOT ON
    file: profiles\config.otml   (OTML, the client settings tree)
    read/written by: B\bot.lua:186-193, 221-251 via g_settings.getNode('bot') / setNode+save
    key: "<CharacterName>_<clientVersion>"
    also at profiles\config.otml:47 -> `profile: 1`  == g_settings.getNumber('profile')

REAL EXCERPT (profiles\config.otml:47 and :2572+):
    profile: 1
    ...
    bot:
      Wfawdsafwfwad_1530:
        enabled: true
        config: vBot_4.8
      Mocarzbgc_1530:
        config: vBot_4.8
        enabled: false
      Tmk Creew_1530:
        config: EK Main
        enabled: true

Headless equivalent: a small JSON/INI, e.g.
    { "profile": 1,
      "bot": { "Wfawdsafwfwad_1530": { "enabled": true, "config": "vBot_4.8" } } }

--------------------------------------------------------------------
(2) SCRIPT STORAGE  (context.storage)
    file: bot\<config>\storage\profile_<N>.json      N = the `profile` number above
    real:  profiles\bot\vBot_4.8\storage\profile_1.json   (44,975 bytes)
    written by B\bot.lua:298-321 as json.encode(storage, 2); refused above 100 MB.

REAL TOP-LEVEL KEYS in that file:
  AutoImbueManager AutoTrainingWeapon BOTserver BotServerChannel BotServerUrl
  EquipperPanel _configs _icons _macros alarms analyzers autoEquip autoImbue
  autoTradeMessage bestHeal bestHit caveBot caveBotTasker cavebotSell
  cavebotSellMigrated combobot dropper extras foodItems ingame_hotkeys
  moneyItems navibot newHealer playerList pushmax renameContainers
  specialDeposit stances

REAL CONTENT of the three engine-owned keys (verbatim):
  "_configs": {
    "targetbot_configs": { "enabled": false, "selected": "true_asura" },
    "cavebot_configs":   { "enabled": false, "selected": "true_asura_mk" }
  },
  "_macros": {
    "": false,
    "AntiRS & Msg": false,
    "Exchange money": true,
    "Exeta when low hp": false,
    "Hold Target": true,
    "Auto Equip 35901": true,
    "ripper spectre switch": false
  },
  "_icons": {
    "looter":     { "y": 0.25,             "enabled": false, "x": 0.01 },
    "might_auto": { "y": 0.12320916905444, "enabled": false, "x": 0.010135135135135 },
    "ssa_auto":   { "y": 0.45,             "enabled": false, "x": 0.01 }
  }
Also real, and relevant to the relay:
  "BotServerChannel": "test",
  "BotServerUrl": "ws://etlac.cryrex.net:8000/"

Schemas:
  _macros[<macro name string>] = boolean            (only `== true` restores ON; B\functions\main.lua:100)
  _configs[<dir>]              = { enabled: bool, selected: string|null }
  _icons[<iconId>]             = { x: 0..1, y: 0..1, enabled: bool }   -- x/y are UI-only

--------------------------------------------------------------------
(3) vBot MODULE CONFIGS (separate from storage)
    dir : bot\<config>\vBot_configs\profile_<N>\
    files: HealBot.json, AttackBot.json, Supplies.json
    loaded into the sandbox globals HealBotConfig / AttackBotConfig / SuppliesConfig
    (P\vBot\configs.lua:22-61); saved eagerly by vBotConfigSave("heal"|"atk"|"supply")
    (P\vBot\configs.lua:63-97) with json.encode(t, 2).
    profile_1 .. profile_10 are pre-created (P\vBot\configs.lua:13-18).

--------------------------------------------------------------------
(4) Config.setup NAMED SETS - cavebot routes  (.cfg, string-pair list)
    dir : bot\<config>\cavebot_configs\
    registered: P\cavebot\cavebot.lua:207
        Config.setup("cavebot_configs", configWidget, "cfg", cb)
    encoding: table.encodeStringPairList (M\corelib\table.lua:279-289):
        one "key:value\n" per pair; a value containing \n becomes "key:[[\n<value>\n]]\n".
        Decoder regex caps the KEY at 20 chars and forbids ':' and '\n' in it
        (M\corelib\table.lua:291).
    layout: N action pairs in route order, then exactly three reserved trailing pairs
        appended by CaveBot.save() (P\cavebot\cavebot.lua:590-609):
        "config"        -> json.encode(CaveBot.Config.save())
        "extensions"    -> json.encode({ [extensionName]=extData }, 2)
        "staypositions" -> json.encode({ ["<1-based action index>"]={x,y,z} })

REAL FILE, complete: profiles\bot\vBot_4.8\cavebot_configs\test.cfg
    goto:33218,32434,7,0
    exanihur:up,north
    exanihur:down,south
    config:{"ignoreFields":false,"skipBlocked":false,"antiLostLadderIds":"1948,1968,5542,7771,9116,20474,20475,21365,28656,31129,31130,31262,33770,34243,35908,43374,48493,48494,50122,50123,50564,50565,435,7750,21221,21298","ping":100,"antiLostRopeToolId":9596,"stayPathEnabled":true,"waypointHud":false,"walkDelay":10,"avoidTileIds":"","avoidFloorChange":true,"mapClickDelay":100,"useDelay":400,"wptDistance":5,"antiLostTeleportIds":"1949,1950,1951,1952","mapClick":false,"smoothWalk":false,"antiLostRopeIds":"386,7762,12935,12936,13381,33051","antiLostEnabled":true}
    extensions:[]
    staypositions:{"3":{"x":33218,"y":32433,"z":6},"2":{"x":33218,"y":32434,"z":7}}

--------------------------------------------------------------------
(5) Config.setup NAMED SETS - targetbot  (.json)
    dir : bot\<config>\targetbot_configs\
    registered: P\targetbot\target.lua:131
        Config.setup("targetbot_configs", configWidget, "json", cb)
    written by TargetBot.save() (P\targetbot\target.lua:238-245) as
        { targeting = [ <creature config>, ... ], looting = { ... } }
      via Config.save -> json.encode(value, 2).

REAL FILE, complete: profiles\bot\vBot_4.8\targetbot_configs\def_target.json
{"targeting":[{"name":"*","rpSafe":false,"anchor":false,"lureCount":1,"closeLure":false,"anchorRange":3,"regex":"^.*$","priority":1,"dynamicLureDelay":false,"lureMax":3,"avoidAttacks":false,"delayFrom":3,"dynamicLure":true,"lureDelay":625,"rePosition":false,"closeLureAmount":3,"lureCavebot":false,"lure":false,"danger":1,"maxDistance":10,"dontLoot":true,"rePositionAmount":5,"keepDistance":false,"keepDistanceRange":1,"chase":true,"lureMin":1,"faceMonster":false,"diamondArrows":false}],"looting":{"everyItem":false,"maxDanger":10,"minCapacity":100,"containers":[{"count":0,"id":2854}],"items":[{"count":0,"id":9084}]}}

--------------------------------------------------------------------
FILE-FORMAT SNIFFING RULES (B\functions\config.lua)
  Config.list(dir)   : listDirectoryFiles, strip ".json"/".cfg"; entries whose name
                       did NOT change (no such extension) are DROPPED (config.lua:28-33).
  Config.load(d,n)   : try "<d>/<n>.json" via json.decode (content < 2 chars -> {}),
                       else "<d>/<n>.cfg" via table.decodeStringPairList, else error.
  Config.parse(str)  : json.decode first, then table.decodeStringPairList, else error.
  Config.save(d,n,v,ext):
       if table.isStringPairList(v) and ext ~= "json"  -> write "<n>.cfg"
       elseif ext == "cfg"                             -> write "<n>.cfg"
       else                                            -> write "<n>.json", indent 2
  Config.remove(d,n) : deletes both "<n>.json" and "<n>.cfg" if present.
  New-config name validation (config.lua:188-191): whitespace -> "_", length in
  [1,29], no "/" and no "\", must not already exist.

## Pseudocode

-- bot/runtime.lua : the vBot execution core ported onto luaclient
-- Depends on: LC.sched, LC.events, LC.state, LC.sender, LC.log, lib/json, lib/sys.
-- Reproduces mods/game_bot/executor.lua + functions/{main,callbacks,config}.lua exactly,
-- with the three known bugs fixed (marked FIX).

local json  = require('lib.json')
local sys   = require('lib.sys')

--==========================================================================
-- 1. CONTEXT / SANDBOX  (executor.lua:21-192)
--==========================================================================
local Runtime = {}

function Runtime.new(opts)          -- opts = {configDir=, storagePath=, sender=, state=, events=}
  local ctx = {}

  ctx.configDir   = opts.configDir            -- e.g. "bot/vBot_4.8"
  ctx._macros     = {}                        -- ARRAY: order == registration order == priority
  ctx._hotkeys    = {}                        -- keyed by normalised key string (headless: command name)
  ctx._scheduler  = {}                        -- ARRAY sorted ascending by .execution
  ctx._callbacks  = {}                        -- [type] = { wrapperFn, ... }
  ctx._currentExecution = nil
  ctx._websockets = {}

  for _, t in ipairs(CALLBACK_TYPES) do ctx._callbacks[t] = {} end   -- see §5.2 table

  -- storage (bot.lua:266-282, executor.lua:26-29)
  ctx.storage = loadJsonOr(opts.storagePath, {})    -- a parse error must ABORT bot start
  if type(ctx.storage._macros) ~= 'table' then ctx.storage._macros = {} end

  ctx.now, ctx.time = sys.nowMs(), sys.nowMs()
  ctx.player = opts.state.player                    -- captured once, like executor.lua:168

  -- log sinks (executor.lua:160-163)
  ctx.info    = function(s) LC.log.info ("[BOT] %s", tostring(s)) end
  ctx.warn    = function(s) LC.log.warn ("[BOT] %s", tostring(s)) end
  ctx.warning = ctx.warn
  ctx.error   = function(s) LC.log.error("[BOT] %s", tostring(s)) end

  -- stdlib subset the sandbox gets (executor.lua:83-158). NOTHING else: no _G chaining.
  ctx.print, ctx.pairs, ctx.ipairs, ctx.tostring, ctx.tonumber = print, pairs, ipairs, tostring, tonumber
  ctx.type, ctx.pcall, ctx.assert, ctx.setmetatable            = type, pcall, assert, setmetatable
  ctx.math, ctx.table, ctx.string, ctx.bit                     = math, table, string, require('bit')
  ctx.os   = { time = os.time, difftime = os.difftime, date = os.date, clock = os.clock }
  ctx.json = json
  ctx.encode = function(t, i) return json.encode(t, i or 2) end
  ctx.decode = function(s) local ok, r = pcall(json.decode, s); return ok and r or {} end
  ctx.getDistanceBetween = function(a,b) return math.max(math.abs(a.x-b.x), math.abs(a.y-b.y)) end  -- ignores z

  -- loaders: every script gets _ENV = ctx  (executor.lua:104-116)
  ctx.load = function(src, name)
    local f = assert(loadstring(src, name)); setfenv(f, ctx); return f       -- LuaJIT / 5.1
  end
  ctx.loadstring = ctx.load
  ctx.dofile = function(rel) ctx.load(readFile(ctx.configDir .. "/" .. rel), rel)() end

  installGameApi(ctx, opts.sender, opts.state)   -- §3.2-3.5, below
  installMacroApi(ctx)                           -- §1, §5
  installConfigApi(ctx)                          -- §4
  return ctx
end

--==========================================================================
-- 2. MACROS / HOTKEYS / SCHEDULE / DELAY  (functions/main.lua)
--==========================================================================
function installMacroApi(ctx)

  -- macro(timeout, [name], [hotkey], callback, [parent])
  ctx.macro = function(timeout, name, hotkey, callback, parent)
    if type(timeout) ~= 'number' or timeout < 1 then error("Invalid timeout for macro: "..tostring(timeout)) end
    if     type(name)   == 'function' then callback, name, hotkey = name, "", ""
    elseif type(hotkey) == 'function' then parent, callback, hotkey = callback, hotkey, ""
    elseif type(callback) ~= 'function' then error("Invalid callback for macro") end
    hotkey = hotkey or ""
    if type(name) ~= 'string' or type(hotkey) ~= 'string' then error("Invalid name or hotkey for macro") end
    if timeout < 50 then timeout = 50 end                            -- HARD FLOOR (main.lua:38-40)

    local m = {
      enabled       = false,
      name          = name,
      timeout       = timeout,
      lastExecution = ctx.now + math.random(0, 100),                 -- de-sync jitter (main.lua:46)
      hotkey        = hotkey,
    }
    ctx._macros[#ctx._macros + 1] = m

    m.isOn   = function() return m.enabled end
    m.isOff  = function() return not m.enabled end
    m.setOn  = function(v) if v == false then return m.setOff() end
                           m.enabled = true;  ctx.storage._macros[name] = true  end
    m.setOff = function(v) if v == false then return m.setOn()  end
                           m.enabled = false; ctx.storage._macros[name] = false end
    m.toggle = function() if m.enabled then m.setOff() else m.setOn() end end

    if #name > 0 then
      if ctx.storage._macros[name] == true then m.setOn() end        -- ONLY `== true` restores
    else
      m.enabled = true                                               -- unnamed macros always run
    end

    local where = debugSite(2)                                       -- "file:line", for the slow warning
    m.callback = function(self)
      if self.delay and self.delay >= ctx.now then return end        -- still suspended -> report "did not run"
      ctx._currentExecution = self
      local t0 = sys.nowMs()                                          -- REAL clock, not ctx.now
      callback(self)                                                  -- user return value is DISCARDED
      local dt = sys.nowMs() - t0
      if dt > 100 then ctx.warning(("Slow macro (%dms): %s - %s"):format(dt, self.name, where)) end
      ctx._currentExecution = nil
      return true
    end
    return m
  end

  -- delay(ms): suspends the CURRENT macro / hotkey / event-callback (main.lua:206-211)
  ctx.delay = function(ms)
    if not ctx._currentExecution then return ctx.error("Invalid usage of delay function") end
    ctx._currentExecution.delay = ctx.now + ms
  end

  -- schedule(ms, fn): ONE global queue, never cancelled by disabling a macro (main.lua:196-203)
  ctx.schedule = function(ms, fn)
    ctx._scheduler[#ctx._scheduler + 1] = { execution = sys.nowMs() + ms, callback = fn }
    table.sort(ctx._scheduler, function(a, b) return a.execution < b.execution end)  -- NOT stable
  end

  -- hotkey(): headless = a named, externally invocable command. Same delay/slow wrapper.
  ctx.hotkey = function(keys, name, callback, parent, single)
    if type(name) == 'function' then callback, name = name, "" end
    if ctx._hotkeys[keys] then return ctx.error("Duplicated hotkey: "..keys) end
    local h = { name = name, lastExecution = ctx.now, single = single }
    local where = debugSite(2)
    h.callback = function()
      if h.delay and h.delay >= ctx.now then return end
      local prev = ctx._currentExecution; ctx._currentExecution = h
      local t0 = sys.nowMs(); callback(); local dt = sys.nowMs() - t0
      if dt > 100 then ctx.warning(("Slow hotkey (%dms): %s - %s"):format(dt, h.name, where)) end
      ctx._currentExecution = prev
      return true
    end
    ctx._hotkeys[keys] = h
    return h
  end
  ctx.singlehotkey = function(k, n, c, p) if type(n)=='function' then c,n = n,"" end
                                          return ctx.hotkey(k, n, c, p, true) end
end

--==========================================================================
-- 3. THE TICK  (bot.lua:525-546 + executor.lua:194-221)
--==========================================================================
function Runtime.start(ctx)
  ctx._tickId = LC.sched.every(10, function()                        -- FIXED 10 ms period
    local ok, err = pcall(Runtime.tick, ctx)
    if not ok then
      -- executor-level failure kills the bot, exactly like bot.lua:537-539
      Runtime.stop(ctx); ctx.error("FATAL: " .. tostring(err))
    end
  end)
end

function Runtime.tick(ctx)
  ctx.now  = sys.nowMs()                        -- ONE sample; every macro this tick sees the same value
  ctx.time = ctx.now

  -- 3a. macros, in registration order
  for _, m in ipairs(ctx._macros) do
    if m.enabled and m.lastExecution + m.timeout <= ctx.now then
      local ok, err = pcall(function()
        if m.callback(m) then m.lastExecution = ctx.now end          -- only advance on a real run
      end)
      if not ok then ctx.error("Macro: "..m.name.." execution error: "..tostring(err)) end
      -- NOTE: on error (and when delayed) lastExecution is NOT advanced -> retried next tick.
    end
  end

  -- 3b. scheduler drain, head-first
  local guard = 0
  while #ctx._scheduler > 0 and ctx._scheduler[1].execution <= ctx.now do
    guard = guard + 1
    if guard > 1000 then ctx.error("scheduler runaway; aborting drain"); break end   -- FIX: 0-delay loop
    local e = table.remove(ctx._scheduler, 1)
    local ok, err = pcall(e.callback)
    if not ok then ctx.error("Schedule execution error: "..tostring(err)) end
  end
end

function Runtime.stop(ctx)
  LC.sched.cancel(ctx._tickId)
  for id in pairs(ctx._websockets) do closeWebsocket(id) end
  ctx._macros, ctx._scheduler, ctx._hotkeys = {}, {}, {}
end

--==========================================================================
-- 4. STORAGE  (bot.lua:266-321)
--==========================================================================
-- Save points in vBot: terminate, game-offline, and every refresh (config switch /
-- enable toggle). NO autosave, and save() is skipped entirely when the executor died.
-- FIX: keep those three, add a dirty-flag autosave and temp+rename.
function Runtime.saveStorage(ctx, path)
  local ok, text = pcall(json.encode, ctx.storage, 2)
  if not ok then return ctx.error("Error while saving bot storage: "..tostring(text)) end
  if #text > 100 * 1024 * 1024 then return ctx.error("Storage file is too big, above 100MB") end
  writeFileAtomic(path, text)                                         -- FIX: was a raw overwrite
end

--==========================================================================
-- 5. EVENT CALLBACKS  (functions/callbacks.lua + bot.lua:549-879 + executor.lua:222-444)
--==========================================================================
function installCallbackApi(ctx, events)
  ctx.callback = function(kind, fn)
    local list = ctx._callbacks[kind]
    if not list then error("Wrong callback type: "..tostring(kind)) end
    if kind == "onAddThing" or kind == "onRemoveThing" then
      ctx._tileThingCallbacksWanted = true          -- gate the highest-volume events (bot.lua:117)
    end
    local where, data = debugSite(2), {}
    local wrapper = function(...)
      if data.delay and data.delay >= ctx.now then return end
      local prev = ctx._currentExecution; ctx._currentExecution = data   -- SAVE/RESTORE (nesting!)
      local t0 = sys.nowMs(); fn(...); local dt = sys.nowMs() - t0
      if dt > 100 then ctx.warning(("Slow %s (%dms): %s"):format(kind, dt, where)) end
      ctx._currentExecution = prev
    end
    list[#list + 1] = wrapper
    return { remove = function()                                        -- FIX: original compared the
        for i, w in ipairs(list) do                                     -- whole list and never matched
          if w == wrapper then table.remove(list, i); return true end
        end
      end }
  end

  -- one registrar per type: onTalk, onTextMessage, onCreatureAppear, ... (callbacks.lua:49-240)
  for _, kind in ipairs(CALLBACK_TYPES) do
    ctx[kind] = function(fn) return ctx.callback(kind, fn) end
  end
  ctx.onInventoryItemsUpdate = function(fn) return ctx.callback("updateInventoryItems", fn) end

  -- derived sugar (callbacks.lua:245-280)
  ctx.listen = function(who, fn)
    who = who:lower()
    return ctx.onTalk(function(n, lvl, mode, text, chan, pos)
      if who == n:lower() then fn(text, chan, pos) end end)
  end
  ctx.onPlayerPositionChange = function(fn)
    return ctx.onCreaturePositionChange(function(c, np, op) if c == ctx.player then fn(np, op) end end)
  end
  ctx.onPlayerHealthChange = function(fn)
    return ctx.onCreatureHealthPercentChange(function(c, p) if c == ctx.player then fn(p) end end)
  end
  ctx.onPlayerInventoryChange = function(fn)
    return ctx.onInventoryChange(function(pl, slot, it, old) if pl == ctx.player then fn(slot, it, old) end end)
  end

  -- BRIDGE: LC.events -> the bot's callback lists. Each dispatch is individually pcall'd
  -- so one bad script callback cannot kill the bot (bot.lua:677-682 safeBotCall).
  local function dispatch(kind, ...)
    for _, w in ipairs(ctx._callbacks[kind]) do
      local ok, err = pcall(w, ...)
      if not ok then ctx.error(tostring(err)) end
    end
  end
  events.on('talk',        function(d) dispatch('onTalk', d.name, d.level, d.mode, d.text, d.channelId, d.pos) end)
  events.on('textMessage', function(d) dispatch('onTextMessage', d.mode, d.text) end)
  events.on('creatureAppear',    function(d) dispatch('onCreatureAppear', d.creature) end)
  events.on('creatureDisappear', function(d) dispatch('onCreatureDisappear', d.creature) end)
  events.on('creatureMove',      function(d) dispatch('onCreaturePositionChange', d.creature, d.newPos, d.oldPos)
                                             dispatch('onWalk', d.creature, d.oldPos, d.newPos) end)
  events.on('creatureHealth',    function(d) dispatch('onCreatureHealthPercentChange', d.creature, d.healthPercent) end)
  events.on('manaChange',        function(d) dispatch('onManaChange', ctx.player, d.mana, d.maxMana, d.oldMana, d.oldMaxMana) end)
  events.on('inventoryChange',   function(d) dispatch('onInventoryChange', ctx.player, d.slot, d.item, d.oldItem) end)
  events.on('containerOpen',     function(d) dispatch('onContainerOpen', d.container, d.previous) end)
  events.on('containerClose',    function(d) dispatch('onContainerClose', d.container) end)
  events.on('containerAddItem',    function(d) dispatch('onAddItem', d.container, d.slot, d.item) end)
  events.on('containerRemoveItem', function(d) dispatch('onRemoveItem', d.container, d.slot, d.item) end)
  events.on('containerUpdateItem', function(d) dispatch('onContainerUpdateItem', d.container, d.slot, d.item, d.oldItem) end)
  events.on('modalDialog',   function(d) dispatch('onModalDialog', d.id, d.title, d.message, d.buttons,
                                                  d.enterButton, d.escapeButton, d.choices, 0) end)
  events.on('distanceEffect',function(d) dispatch('onMissle', d) end)
  events.on('animatedText',  function(d) dispatch('onAnimatedText', d.thing, d.text) end)
  events.on('staticText',    function(d) dispatch('onStaticText', d.thing, d.text) end)
  events.on('channelList',   function(d) dispatch('onChannelList', d.channels) end)
  events.on('openChannel',   function(d) dispatch('onOpenChannel', d.id, d.name) end)
  events.on('closeChannel',  function(d) dispatch('onCloseChannel', d.id) end)
  events.on('loginAdvice',   function(d) dispatch('onLoginAdvice', d.message) end)
  events.on('tileUpdate',    function(d) if ctx._tileThingCallbacksWanted then
                                           dispatch('onAddThing', d.tile, d.thing) end end)
  -- 0xF5 inventory list: fires on ANY carried-item amount change, closed containers included
  events.on('inventoryItems', function()  dispatch('updateInventoryItems') end)

  -- Cooldowns: feed the tables DIRECTLY, with no widget gating (see pitfalls).
  ctx._cooldownUntil, ctx._groupCooldownUntil = {}, {}
  events.on('spellCooldown', function(d)
    ctx._cooldownUntil[d.iconId] = sys.nowMs() + d.duration
    dispatch('onSpellCooldown', d.iconId, d.duration) end)
  events.on('spellGroupCooldown', function(d)
    ctx._groupCooldownUntil[d.groupId] = sys.nowMs() + d.duration
    dispatch('onGroupSpellCooldown', d.groupId, d.duration) end)
  ctx.isCooldownIconActive      = function(id) local t = ctx._cooldownUntil[id];      return t ~= nil and sys.nowMs() < t end
  ctx.isGroupCooldownIconActive = function(id) local t = ctx._groupCooldownUntil[id]; return t ~= nil and sys.nowMs() < t end
end

--==========================================================================
-- 6. Config.setup  (functions/config.lua:130-269)
--==========================================================================
function installConfigApi(ctx)
  local C = {}; ctx.Config = C
  local function dirPath(d) return ctx.configDir .. "/" .. d end

  C.exist  = function(d) return dirExists(dirPath(d)) end
  C.create = function(d) makeDir(dirPath(d)); return C.exist(d) end

  C.list = function(d)                                   -- strip .json/.cfg, DROP anything else
    if not C.exist(d) then C.create(d) end
    local out = {}
    for _, f in ipairs(sortedListDir(dirPath(d))) do
      local base = f:gsub("%.json$", ""):gsub("%.cfg$", "")
      if base ~= f then out[#out+1] = base end
    end
    return out
  end

  C.parse = function(s)
    local ok, r = pcall(json.decode, s); if ok and type(r) == 'table' then return r end
    ok, r = pcall(decodeStringPairList, s); if ok and type(r) == 'table' then return r end
    return ctx.error("Invalid config format")
  end

  C.load = function(d, n)
    local j = dirPath(d).."/"..n..".json"
    if fileExists(j) then local s = readFile(j); if #s < 2 then return {} end return json.decode(s) end
    local c = dirPath(d).."/"..n..".cfg"
    if fileExists(c) then return decodeStringPairList(readFile(c)) end
    return ctx.error("Config "..c.." doesn't exist")
  end
  C.loadRaw = function(d, n) ... end                     -- same probe order, returns raw text
  C.save = function(d, n, v, ext)
    if type(v) ~= 'table' then return ctx.error("Invalid config value type") end
    if not C.exist(d) then C.create(d) end
    if (isStringPairList(v) and ext ~= "json") or ext == "cfg" then
      writeFileAtomic(dirPath(d).."/"..n..".cfg", encodeStringPairList(v))
    else
      writeFileAtomic(dirPath(d).."/"..n..".json", json.encode(v, 2))
    end
    return true
  end
  C.remove = function(d, n) ... end                      -- delete both extensions

  -- Headless Config.setup: `widget` is replaced by a plain state object the control
  -- plane manipulates. The state machine below is byte-for-byte the original refresh().
  C.setup = function(d, ctl, ext, cb)                    -- ctl = {enabled=bool, options={}, index=}
    if type(d) ~= 'string' or #d == 0 then return ctx.error("Invalid config dir") end
    if not C.exist(d) and not C.create(d) then return ctx.error("Can't create config dir: "..d) end
    ctx.storage._configs = ctx.storage._configs or {}
    local S = ctx.storage._configs[d]
    if type(S) ~= 'table' then
      S = { enabled = false, selected = "" }; ctx.storage._configs[d] = S
    else
      ctl.enabled = S.enabled                            -- restore the switch from storage
    end

    local refreshing = false
    local function refresh()
      refreshing = true
      local list, idx = C.list(d), 1
      ctl.options = list
      for i, name in ipairs(list) do if name == S.selected then idx = i end end
      local data
      if #list > 0 then
        ctl.index  = idx
        S.selected = list[idx]
        data       = C.load(d, list[idx])
      else
        S.selected = nil
      end
      S.enabled = ctl.enabled
      refreshing = false
      cb(S.selected, ctl.enabled, data)                  -- data may be nil -> module must turn itself off
    end

    ctl.select = function(name) if not refreshing then S.selected = name; refresh() end end
    ctl.toggle = function() ctl.enabled = not ctl.enabled; refresh() end   -- toggling RELOADS + REAPPLIES

    refresh()                                            -- callback fires immediately at setup
    return {
      isOn  = function() return ctl.enabled end,
      isOff = function() return not ctl.enabled end,
      setOn  = function(v) if v == false then return (ctl.enabled  and ctl.toggle()) end
                           if not ctl.enabled then ctl.toggle() end end,
      setOff = function(v) if v == false then return (not ctl.enabled and ctl.toggle()) end
                           if ctl.enabled then ctl.toggle() end end,
      save   = function(data) C.save(d, S.selected, data, ext) end,
      refresh = refresh, reload = refresh,
      getActiveConfigName = function() return S.selected end,
    }
  end
end

--==========================================================================
-- 7. GAME API (functions/player.lua, map.lua, npc.lua) -> sender/state
--==========================================================================
function installGameApi(ctx, sender, st)
  local P = st.player
  ctx.hp, ctx.mana = function() return P.health end, function() return P.mana end
  ctx.maxhp, ctx.maxmana = function() return P.maxHealth end, function() return P.maxMana end
  ctx.hppercent  = function() return P.healthPercent end
  ctx.manapercent= function() if P.maxMana <= 1 then return 100 end
                              return math.floor(P.mana * 100 / P.maxMana) end          -- guard, player.lua:8-15
  ctx.pos = function() return P.pos end
  ctx.posx, ctx.posy, ctx.posz = function() return P.pos.x end, function() return P.pos.y end, function() return P.pos.z end
  ctx.hasCondition = function(mask) return bit.band(P.states, mask) > 0 end
  ctx.isInFight = function() return ctx.hasCondition(PlayerStates.Swords) end
  ctx.canLogout = function() return not ctx.isInFight() end
  -- ... the rest of §3.2 verbatim

  ctx.walk = function(dir) return sender:walk(dir) end
  ctx.turn = function(dir) return sender:turn(dir) end
  ctx.say  = function(text, aim, aimPos)
    if isKnownSpellWord(text) then return sender:talkSpell(text, aim or SpellAimTarget, aimPos) end
    return sender:talk(1, 0, "", text)                                    -- MessageSay = 1
  end
  ctx.talk         = ctx.say
  ctx.yell         = function(t) return sender:talk(3, 0, "", t) end      -- MessageYell = 3
  ctx.talkChannel  = function(ch, t) return sender:talk(7, ch, "", t) end -- MessageChannel = 7
  ctx.talkPrivate  = function(to, t) return sender:talk(5, 0, to, t) end  -- MessagePrivateTo = 5
  ctx.talkNpc      = function(t) return sender:talk(11, 0, "", t) end     -- MessageNpcTo = 11
  ctx.castSpellAt  = function(t, p) return sender:talkSpell(t, 2, p) end  -- SpellAimCursor = 2

  ctx.saySpell = function(text, timeout)                                  -- player.lua:139-155
    if not text or #text < 1 then return end
    timeout = timeout or 1000
    ctx.lastSpell = ctx.lastSpell or 0
    if ctx.lastSpell + timeout > ctx.now then return false end
    ctx.say(text); ctx.lastSpell = ctx.now; return true
  end

  ctx.use = function(thing, sub)
    if type(thing) == 'number' then return sender:use({x=0xFFFF,y=0,z=0}, thing, 0, 0) end
    return sender:use(thing.pos, thing.id, thing.stackpos, findEmptyContainerId(st))
  end
  ctx.usewith = function(thing, target, sub)
    if not thing then return end
    local fromPos, fromId, fromStack
    if type(thing) == 'number' then fromPos, fromId, fromStack = {x=0xFFFF,y=0,z=0}, thing, 0
    else fromPos, fromId, fromStack = thing.pos, thing.id, thing.stackpos end
    if target.creatureId then return sender:useOnCreature(fromPos, fromId, fromStack, target.creatureId) end
    return sender:useWith(fromPos, fromId, fromStack, target.pos, target.id, target.stackpos)
  end
  ctx.useWith = ctx.usewith

  ctx.attack = function(c) return sender:attack(c and c.id or 0) end
  ctx.follow = function(c) return sender:follow(c and c.id or 0) end
  ctx.cancelAttackAndFollow = function() return sender:cancelAttackAndFollow() end

  ctx.setOutfit = function(o)                                            -- player.lua:54-60
    sender:requestOutfit(); ctx.schedule(100, function() sender:changeOutfit(o) end)
  end

  -- findItem: slots 1..10 (Purse=11 EXCLUDED), then open containers by ascending id,
  -- items in slot order; tier must match exactly (default 0).  gamelib/game.lua:5-16
  ctx.findItem = function(id, subType, tier)
    subType, tier = subType or -1, tier or 0
    for slot = 1, 10 do
      local it = st.player.inventory[slot]
      if it and it.id == id and (subType == -1 or it.subType == subType) then return it end
    end
    for _, cid in ipairs(sortedKeys(st.containers)) do
      for _, it in ipairs(st.containers[cid].items) do
        if it.id == id and (subType == -1 or it.subType == subType) and (it.tier or 0) == tier then return it end
      end
    end
  end

  -- getSpectators([posOrCreatureOrBoolOrPattern], [param2]) : map.lua:8-37
  ctx.getSpectators = function(p1, p2)
    local pos, dir = st.player.pos, st.player.direction
    if type(p1) == 'table' and p1.x then pos, dir, p1 = p1, 8, p2                      -- dir 8 = invalid
    elseif type(p1) == 'table' and p1.id then pos, dir, p1 = p1.pos, p1.direction, p2 end
    if type(p1) == 'string' then return spectatorsByPattern(st, pos, p1, dir) end
    return spectatorsInAwareRange(st, pos, p1 == true)
  end
  -- spectatorsByPattern: '0'/'-' off, '1'/'+' on, N/E/S/W on only when dir matches;
  -- width AND height must be ODD or return {}; single floor (pos.z); dedupe by creature id.
  -- spectatorsInAwareRange: rectangle of st.world.awareRange around pos; multifloor spans
  -- firstAwareFloor..lastAwareFloor; dedupe by creature id.

  ctx.getCreatureById = function(id, mf)
    for _, c in ipairs(ctx.getSpectators(mf == true)) do if c.id == id then return c end end
  end
  ctx.getCreatureByName = function(n, mf)
    n = n:lower()
    for _, c in ipairs(ctx.getSpectators(mf == true)) do if c.name:lower() == n then return c end end
  end

  -- findPath(start, dest, maxDist=100, params) : map.lua:143-219
  ctx.findPath = function(a, b, maxDist, params)
    if not b or a.z ~= b.z then return nil end                  -- NEVER crosses floors
    maxDist, params = maxDist or 100, params or {}
    params.destination = key(b)
    local paths = ctx.findAllPaths(a, maxDist, params)
    local mn, mx = params.marginMin or params.minMargin, params.marginMax or params.maxMargin
    if type(mn) == 'number' and type(mx) == 'number' then
      local best, bestKey
      for x = -mx, mx do for y = -mx, mx do
        if math.abs(x) >= mn or math.abs(y) >= mn then
          local k = key{x=b.x+x, y=b.y+y, z=b.z}; local n = paths[k]
          if n and (not best or best[1] > n[1]) then best, bestKey = n, k end
        end end end
      return best and translate(paths, bestKey) or nil
    end
    if not paths[key(b)] then
      local prec = params.precision
      if type(prec) == 'number' then
        for p = 1, prec do
          local best, bestKey
          for x = -p, p do for y = -p, p do
            local k = key{x=b.x+x, y=b.y+y, z=b.z}; local n = paths[k]
            if n and (not best or best[1] > n[1]) then best, bestKey = n, k end
          end end
          if best then return translate(paths, bestKey) end
        end
      end
      return nil
    end
    return translate(paths, key(b))
  end
  -- translate(paths, destKey): follow node[4] (prev key) back, collect node[3] (direction),
  -- stop when node[3] < 0, then REVERSE.  map.lua:116-140

  ctx.autoWalk = function(dest, maxDist, params)
    if type(dest) == 'table' and isList(dest) and not maxDist and not params then
      return sendAutoWalkClamped(sender, dest)                   -- 127-step wire clamp, see API.md
    end
    local path = ctx.findPath(st.player.pos, dest, maxDist, params)
    if not path then return false end
    sendAutoWalkClamped(sender, path)
    return true
  end
end

--==========================================================================
-- 8. BOOT ORDER  (mirrors bot.lua:208-296 / executor.lua:3-192)
--==========================================================================
-- 1. read settings -> { enabled, config } for "<CharName>_<clientVersion>"; bail if disabled
-- 2. ctx = Runtime.new{ configDir = "bot/"..config,
--                       storagePath = "bot/"..config.."/storage/profile_"..profileNum..".json" }
-- 3. installCallbackApi(ctx, LC.events)
-- 4. load every TOP-LEVEL *.lua of the config dir in ALPHABETICAL order with _ENV = ctx
--    (vBot has exactly one: _Loader.lua, which dofile()s the rest in its own explicit order)
-- 5. Runtime.start(ctx)
-- 6. on shutdown / logout / config switch: Runtime.saveStorage(ctx, path); Runtime.stop(ctx)

## Evidence
- D:\Claude\otclient_mehah1530\otclient\mods\game_bot\bot.lua:525-546 — the tick: removeEvent(checkEvent); if not botExecutor then return end; checkEvent = scheduleEvent(check, 10) (re-armed BEFORE the body); pcall(botExecutor.script); on failure botExecutor = nil (bot dies permanently) + onError.
- D:\Claude\otclient_mehah1530\otclient\mods\game_bot\executor.lua:194-221 — script(): context.now = context.time = g_clock.millis() sampled once; for i,macro in ipairs(context._macros) do if macro.lastExecution + macro.timeout <= context.now and macro.enabled then pcall(... if macro.callback(macro) then macro.lastExecution = context.now end) ... end end; then while #context._scheduler > 0 and context._scheduler[1].execution <= g_clock.millis() do pcall(...); table.remove(_scheduler,1) end.
- D:\Claude\otclient_mehah1530\otclient\mods\game_bot\functions\main.lua:38-48 — `if timeout < 50 then timeout = 50 end` (hard floor) and the record {enabled=false, name, timeout, lastExecution = context.now + math.random(0,100), hotkey}.
- D:\Claude\otclient_mehah1530\otclient\mods\game_bot\functions\main.lua:64-105 — setOn/setOff write context.storage._macros[name]; named macros restore only on `== true` (line 100-102); unnamed macros get `macro.enabled = true` unconditionally (line 104).
- D:\Claude\otclient_mehah1530\otclient\mods\game_bot\functions\main.lua:113-125 — the wrapper: delay gate `if not macro.delay or macro.delay < context.now`, _currentExecution set/cleared, >100 ms slow warning using g_clock.realMillis(), and `return true` regardless of the user callback's own return value.
- D:\Claude\otclient_mehah1530\otclient\mods\game_bot\functions\main.lua:196-211 — schedule(): one global array, table.sort on every insert (not stable); delay(): sets context._currentExecution.delay = context.now + duration, errors when _currentExecution is nil.
- D:\Claude\otclient_mehah1530\otclient\mods\game_bot\bot.lua:266-296 — storage load: path "/bot/"..configName.."/storage/", botStorageFile = path.."profile_"..g_settings.getNumber('profile')..".json", json.decode inside pcall, then executeBot(configName, botStorage, botTabs, message, save, refresh, botWebSockets) and check().
- D:\Claude\otclient_mehah1530\otclient\mods\game_bot\bot.lua:298-321 — save(): returns immediately when botExecutor is nil (line 299-301) or when settings[index] is nil (305-307); json.encode(botStorage, 2); refuses > 100 MB (316); whole-file writeFileContents (320). Called only from terminate (95), refresh (210), offline (347).
- D:\Claude\otclient_mehah1530\otclient\mods\game_bot\bot.lua:186-193 and 221-251 — active config + enable flag live in g_settings node 'bot', keyed g_game.getCharacterName().."_"..g_game.getClientVersion(), value {enabled=bool, config=string}; changes call g_settings.setNode('bot', settings); g_settings.save(); refresh().
- D:\Claude\otclient_mehah1530\otclient\profiles\config.otml:47 and :2572-2580 — real persisted values: `profile: 1`, and the bot node e.g. `Wfawdsafwfwad_1530: {enabled: true, config: vBot_4.8}`, `Tmk Creew_1530: {config: EK Main, enabled: true}`.
- D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\storage\profile_1.json — real _macros {"": false, "AntiRS & Msg": false, "Exchange money": true, "Exeta when low hp": false, "Hold Target": true, "Auto Equip 35901": true, "ripper spectre switch": false}; real _configs {"targetbot_configs":{"enabled":false,"selected":"true_asura"},"cavebot_configs":{"enabled":false,"selected":"true_asura_mk"}}; real _icons {"looter":{"y":0.25,"enabled":false,"x":0.01}, ...}; BotServerUrl/BotServerChannel present at top level.
- D:\Claude\otclient_mehah1530\otclient\mods\game_bot\executor.lua:21-80 — context table construction, storage._macros default, and the exhaustive _callbacks type list (38 entries incl. updateInventoryItems).
- D:\Claude\otclient_mehah1530\otclient\mods\game_bot\executor.lua:102-116, 184-192 — every script is compiled with the context table as its environment (setfenv on 5.1/no-jit, load(...,context) otherwise); dofile resolves "/bot/"..config.."/"..file; context.panel is reset to mainTab after each top-level file.
- D:\Claude\otclient_mehah1530\otclient\mods\game_bot\executor.lua:3-14 + D:\Claude\otclient_mehah1530\otclient\src\framework\core\resourcemanager.cpp (listDirectoryFiles ... files.sort(); header default recursive=false) — only TOP-LEVEL .lua/.otui of the config dir are auto-loaded, alphabetically; hence P\_Loader.lua being the sole top-level script.
- D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\_Loader.lua:18-58 — the explicit load order: main, items, vlib, new_cavebot_lib, configs (libraries, 'do not change this and above'), then extras, cavebot, playerlist, BotServer, ..., HealBot, new_healer, AttackBot ('last of major modules'), Stances ('after AttackBot: reuses its trySetSpellIcon helper'), ... navibot.
- D:\Claude\otclient_mehah1530\otclient\mods\game_bot\functions\config.lua:130-172 — Config.setup: storage._configs[dir] defaulted to {enabled=false, selected=""}; refresh() rebuilds the list, resolves selected -> index (default 1), loads data, mirrors the switch into storage, then calls callback(selected, enabled, data) with data possibly nil; isRefreshing re-entrancy guard.
- D:\Claude\otclient_mehah1530\otclient\mods\game_bot\functions\config.lua:95-111 — Config.save picks .cfg (table.encodeStringPairList) when table.isStringPairList(value) and forcedExtension ~= "json", or when forcedExtension == "cfg"; otherwise .json via json.encode(value, 2).
- D:\Claude\otclient_mehah1530\otclient\mods\game_bot\functions\config.lua:20-35 — Config.list strips ".json"/".cfg" and DROPS any entry whose name did not change (i.e. other extensions are invisible to the selector).
- D:\Claude\otclient_mehah1530\otclient\modules\corelib\table.lua:279-320 — encodeStringPairList writes "key:value\n" and "key:[[\n<value>\n]]\n" for multiline values; decodeStringPairList uses regex "(?:^|\\n)([^:^\n]{1,20}):?(.*)(?:$|\\n)" — the key is capped at 20 characters.
- D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\cavebot\cavebot.lua:207 — Config.setup("cavebot_configs", configWidget, "cfg", ...) and :578-610 CaveBot.save() appending the reserved pairs {"config", json}, {"extensions", json}, {"staypositions", json} after the action pairs.
- D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\targetbot\target.lua:131 — Config.setup("targetbot_configs", configWidget, "json", ...) and :238-245 TargetBot.save() writing {targeting=[...], looting={...}}.
- D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\cavebot_configs\test.cfg — complete real 6-line config: goto/exanihur/exanihur action pairs plus config:{...}, extensions:[], staypositions:{"3":{...},"2":{...}}.
- D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\targetbot_configs\def_target.json — complete real config with a single "*" targeting entry (regex ^.*$, priority 1, danger 1, maxDistance 10, dynamicLure true, lureDelay 625, chase true) and looting {everyItem:false, maxDanger:10, minCapacity:100, containers:[{id:2854}], items:[{id:9084}]}.
- D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\vBot\configs.lua:22-97 — HealBotConfig/AttackBotConfig/SuppliesConfig loaded from /bot/<config>/vBot_configs/profile_<N>/{HealBot,AttackBot,Supplies}.json and written by vBotConfigSave("heal"|"atk"|"supply") with json.encode(t,2); profile_1..profile_10 dirs pre-created at lines 13-18.
- D:\Claude\otclient_mehah1530\otclient\mods\game_bot\functions\callbacks.lua:4-46 — context.callback(): unknown type errors; onAddThing/onRemoveThing flip g_game.enableTileThingLuaCallback(true); the wrapper saves and restores context._currentExecution (unlike macros); the returned remove() compares the LIST against each element and therefore never removes anything.
- D:\Claude\otclient_mehah1530\otclient\mods\game_bot\bot.lua:549-614 — the exact client signals the bot subscribes to (g_game, Tile, Creature, LocalPlayer, Container, g_map), with the comment at 591-599 explaining that only LocalPlayer-exclusive signals may be listed there or every local-player emit dispatches twice.
- D:\Claude\otclient_mehah1530\otclient\mods\game_bot\bot.lua:677-682 — safeBotCall wraps every callback dispatch in pcall + onError, so a throwing script callback does NOT kill the bot (unlike an error escaping script()).
- D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\vBot\vlib.lua:233-241 — potion exhaust detection: onTalk with own name and mode == 34 (MessageBarkLow) and text == "Aaaah..." sets vBot.isUsingPotion = true, cleared by schedule(950, ...).
- D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\vBot\vlib.lua:249-300 — SpellCastTable stamped from the onTalk echo; cast(text, delay) (delay < 100 -> plain say, else seeds {t = now - delay, d = delay}); canCast(spell, ignoreRL, ignoreCd) three-branch logic ending in `return true` for unknown spells.
- D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\vBot\vlib.lua:302-384 — lastPhrase captured from own onTalk; onSpellCooldown/onGroupSpellCooldown deferred by schedule(1)/schedule(2) to build vBot.customCooldowns[lastPhrase] = {id=, group={[iconId]=duration}}; getSpellData falls back from gamelib SpellInfo['Default'] to customCooldowns; getSpellCoolDown ORs isCooldownIconActive(data.id) with any isGroupCooldownIconActive over `data.group or {}`.
- D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\vBot\vlib.lua:389-406 — the unnamed macro(100, ...) that maintains vBot.isUsing from isUsingTime, plus the onUse/onUseWith callbacks that set isUsingTime = now + 1000 (onUse only for adjacent non-container tiles, onUseWith only when pos.x < 65000).
- D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\vBot\vlib.lua:796-886 — itemAmount(id, tier) = max(player:getItemsCount(id) [equipped + OPEN containers], player:getInventoryCount(id, tier or 0) [server 0xF5 list, covers CLOSED containers, excludes depot/inbox/corpses]); hasItemAvailable(id, tier) = itemAmount > 0.
- D:\Claude\otclient_mehah1530\otclient\mods\game_bot\functions\callbacks.lua:233-240 + bot.lua:872-879 — onInventoryItemsUpdate registers under "updateInventoryItems" and is fired by the client after parsing opcode 0xF5, i.e. whenever any carried item amount changes including inside unopened containers.
- D:\Claude\otclient_mehah1530\otclient\mods\game_bot\functions\map.lua:8-37 — getSpectators argument sniffing: table -> centre pos with direction 8 (invalid, so N/E/S/W cells never match); userdata -> creature pos+direction; string -> getSpectatorsByPattern; true -> multifloor.
- D:\Claude\otclient_mehah1530\otclient\src\client\map.cpp:1475-1543 — getSpectatorsByPattern grammar ('0'/'-' off, '1'/'+' on, N/E/W/S direction-gated), the odd-width/odd-height requirement, single-floor iteration over centerPos.z, and duplicate removal by creature id.
- D:\Claude\otclient_mehah1530\otclient\src\client\map.cpp:651-691 and map.h:166-178 — getSpectators = getSpectatorsInRangeEx over the aware-range rectangle; multiFloor spans getFirstAwareFloor()..getLastAwareFloor(); creatures deduped by id.
- D:\Claude\otclient_mehah1530\otclient\mods\game_bot\functions\map.lua:143-219 — findPath: nil when destPos missing or startPos.z ~= destPos.z; marginMin/marginMax ring search; precision expanding-square fallback; otherwise exact node or nil.
- D:\Claude\otclient_mehah1530\otclient\modules\gamelib\game.lua:5-16 — g_game.findPlayerItem walks InventorySlotFirst(1)..InventorySlotLast(10) then g_game.findItemInContainers(id, subType, tier or 0); Purse (11) is excluded. Container::findItemById (src\client\container.cpp) requires item:getTier() == tier exactly.
- D:\Claude\otclient_mehah1530\otclient\src\client\game.cpp — Game::talk -> talkChannel(MessageSay=1, 0, msg); Game::use sends sendUseItem(pos, id, stackpos, findEmptyContainerId()); Game::useInventoryItem sends pos {0xFFFF,0,0}, index 0; useWith/useInventoryItemWith route to sendUseOnCreature when the target is a creature. src\client\const.h:301-345 gives MessageSay=1, Yell=3, PrivateTo=5, Channel=7, NpcTo=11, BarkLow=34.
- D:\Claude\otclient_mehah1530\otclient\modules\game_cooldown\cooldown.lua:521-537 (isCooldownIconActive / isGroupCooldownIconActive read cooldown[iconId] as an absolute ms deadline on tier-upgrade clients, else a boolean) and :539-544 / :562-573 (onSpellCooldown returns early when the cooldown window is not visible; onSpellGroupCooldown needs the group icon widget) — the UI dependency that must NOT be ported.
- D:\Claude\otclient_mehah1530\otclient\mods\game_bot\functions\server.lua:11-19, 45-129, 176-206 — BotServer: default ws://etlac.cryrex.net:8000/natitest overridden by storage.BotServerUrl; room = storage.BotServerChannel, not the URL path; the {type="init",name,channel,lastMessage} frame must be sent from onOpen; ping echo; topic dispatch to _callbacks[topic] then _callbacks["*"]; exponential reconnect 2000 * 2^(min(attempts,5)-1) capped at 10 attempts; generation-debounced requestReconnect(1200 ms) that re-runs initBotServerListenFunctions() because terminate() wipes _callbacks.
- D:\Claude\otclient_mehah1530\otclient\mods\game_bot\functions\icon.lua:27-45, 90, 140-147 — addIcon persists {x, y, enabled} under storage._icons[id]; default placement x = 0.01 + floor(n/5)/10, y = 0.05 + (n%5)/5 for icons without an explicit position.
- D:\Claude\otclient_mehah1530\otclient\mods\game_bot\functions\script_loader.lua:30-69 — loadRemoteScript caches each fetched script into storage.scriptsCache[url] and falls back to that cache when the HTTP GET fails.
- D:\Claude\otclient_mehah1530\otclient\mods\game_bot\panels\DONT_USE_PANELS.txt — "DONT USE PANELS / THEY ONLY HERE FOR BACKWARD COMPATIBILITY / MAY BE REMOVED IN THE FUTURE"; likewise functions\ui_legacy.lua:3-4.

## Pitfalls
- The 50 ms macro floor is silent. `macro(20, ...)` in cavebot.lua:76 actually runs at 50 ms (functions\main.lua:38-40). If you honour the requested 20 ms you will make CaveBot 2.5x more aggressive than the original and change its walking behaviour.
- `context.now` is sampled ONCE per tick and is the FRAME-cached clock (src\framework\core\clock.h:34), not a live read. Scripts compare `now - x > y` everywhere. If you call sys.nowMs() fresh inside each macro, timing that vBot tuned against a quantised clock shifts. Sample once at tick start; use a real clock only for the >100 ms slow-macro warning, exactly as main.lua:117-120 does.
- `lastExecution` is advanced only when the wrapper actually ran the body. A delayed macro AND a macro whose body throws both leave it unchanged, so both are re-evaluated every single 10 ms tick. A throwing macro therefore spams the error log at 100 Hz, and a delayed macro fires the instant its delay expires with no further `timeout` wait (functions\main.lua:113-125 + executor.lua:200-204).
- An error escaping `botExecutor.script()` itself (not from inside the per-macro or per-schedule pcall) sets `botExecutor = nil` and kills the bot permanently until the user re-toggles it (bot.lua:533-540). Worse: `save()` then returns immediately because `botExecutor` is nil (bot.lua:299-301), so the whole session's storage is silently discarded. Do not reproduce this coupling — save storage on a dirty flag independently of executor health.
- There is no periodic storage autosave. `save()` runs only on terminate, game-offline and refresh (bot.lua:95, 210, 347), and it is a whole-file overwrite with no temp+rename (bot.lua:320). A crash loses every macro toggle and every module setting since the last config switch, and a half-written file makes the NEXT bot start abort outright (bot.lua:275-281).
- `storage._macros` is keyed by macro NAME only. Two macros sharing a name share one persisted flag, and restore is `== true`-only, so any non-boolean-true value (including the string "true") leaves the macro OFF (functions\main.lua:69, 82, 100-102). The real profile even contains a `"": false` entry from an unnamed macro whose setOff() was called.
- Unnamed macros (`macro(100, function() ... end)`) are force-enabled at registration and have no switch, so they can never be turned off from config (functions\main.lua:104). vlib.lua:390 relies on this. Any headless 'disable all macros' command must not assume every macro is addressable by name.
- `schedule()` is a single GLOBAL queue that is never cancelled when a macro is turned off, when the config is switched, or when the owning module is disabled. Every closure ever scheduled will fire (functions\main.lua:196-203, cleared only by clear() destroying the executor). Modules must re-check their own enable state inside the scheduled body.
- The scheduler drain re-reads g_clock.millis() each iteration, but that clock does not advance within a tick. A callback that calls `schedule(0, ...)` inserts at the head and is executed in the SAME drain loop -> infinite loop inside one tick. Add an iteration guard (the original has none).
- `table.sort` on every schedule() insert is not stable, so two callbacks queued for the same millisecond can fire in either order (functions\main.lua:202). Do not rely on schedule() ordering; vlib.lua:310-324 works around this by using distinct 1 ms and 2 ms delays to force ordering after an onTalk.
- `delay()` targets `_currentExecution`, which macros and hotkeys clear to nil but event callbacks save/restore (functions\callbacks.lua:20-29 vs main.lua:113-125). So `delay()` called from an event callback that fired synchronously inside a macro delays the CALLBACK, not the macro. Calling delay() from a schedule() body only logs an error (main.lua:207).
- The `callback().remove()` returned by functions\callbacks.lua:33-45 is broken: it compares the whole callback LIST against each element, so it never matches and never removes. Nothing in vBot depends on the broken behaviour, but if you fix it, any script that called remove() expecting a no-op will now actually unregister.
- `onAddThing`/`onRemoveThing` are only delivered after some script called `g_game.enableTileThingLuaCallback(true)` (functions\callbacks.lua:8-10), and the flag is reset in clear() (bot.lua:117). These are by far the highest-volume events; keep them opt-in or a headless client will burn its budget on tile churn.
- Cooldown state is read through game_cooldown, which drops the packet entirely when the cooldown window is not visible (modules\game_cooldown\cooldown.lua:539-544) and needs a group icon widget to exist (562-573). `canCast()` therefore silently degrades to 'always true' for group cooldowns in a headless port unless you track `spellCooldown`/`spellGroupCooldown` directly into deadline tables. Do NOT port the widget gating.
- `context.player` is captured once at executeBot time (executor.lua:168) and never refreshed. Everything in functions\player.lua closes over it. If your state object replaces the player table on relog rather than mutating it in place, every player accessor silently reads a dead object.
- `findItem()` only sees equipped slots 1..10 and OPEN containers (modules\gamelib\game.lua:5-16). It answers 'can I see it', not 'do I have it'. vBot explicitly documents this trap in vlib.lua:853-870: gating potions/runes on findItem made a full closed backpack count as zero. Use itemAmount()/hasItemAvailable() (max of the 0xF5 server count and the visible scan) for availability, and findItem only when you need the concrete object for a move.
- `getCreatureById`/`getCreatureByName` are linear scans over getSpectators (functions\map.lua:39-78), i.e. they only find creatures inside the AWARE RANGE, and default to single-floor. A hash lookup over the full creature map is not equivalent — it will return creatures the original could not see, changing targeting behaviour.
- `getSpectatorsByPattern` silently returns an EMPTY list (plus a log line) when the pattern's width or height is even (src\client\map.cpp:1516-1520). All of vlib.lua's ready-made areas are odd-sized; a hand-written pattern that is not will make an AoE check quietly always-false.
- When a position table is passed to getSpectators, direction is forced to 8 (an invalid direction), so N/E/S/W pattern cells never match (functions\map.lua:17-21). Directional beam/wave patterns evaluated at a remote tile therefore only ever count the '1' cells.
- `findPath` returns nil whenever start.z ~= dest.z (functions\map.lua:159-161). It cannot cross floors at all — floor changes are entirely the caller's problem (anti-lost, ladders, ropes). Do not 'improve' this without auditing CaveBot, which depends on the nil.
- `getDistanceBetween` is Chebyshev distance that IGNORES z (executor.lua:124-126). Two creatures directly above one another read as distance 0. Every range check in vBot inherits this.
- `Config.list` drops any file whose extension is not .json/.cfg (functions\config.lua:28-33), so backup files like `AttackBot.lua.bak-itemavail` are invisible — but a stray `.json` in cavebot_configs WOULD show up as a selectable route and then be parsed with the wrong loader.
- The .cfg key is capped at 20 characters and cannot contain ':' or newline (modules\corelib\table.lua:291 regex `[^:^\n]{1,20}`). Any longer action name silently fails to round-trip through a cavebot config.
- `Config.setup`'s setOn/setOff work by simulating a switch click, which calls refresh(), which RELOADS the file and re-invokes the module callback (functions\config.lua:236-259 + 181-184). Turning a config on is therefore a full reload, not a cheap flag flip — modules must be idempotent under it.
- The `Config.setup` callback is invoked immediately at setup time with `data` possibly nil (functions\config.lua:229, 171). Both consumers handle nil by turning their macro off (cavebot.lua:216, target.lua:132-135). A headless port that skips the initial invocation will leave both bots in an undefined enabled state.
- Only TOP-LEVEL .lua files of the config dir are auto-loaded, alphabetically and non-recursively (executor.lua:3-14 + resourcemanager.cpp files.sort()). Dropping an extra .lua into the config root changes load order and therefore macro priority. The entire load order — and thus the execution order of every macro — is defined by _Loader.lua:18-58; preserve it exactly.
- The sandbox does NOT chain to _G (executor.lua:83-158). Anything not explicitly injected is nil inside bot scripts; that is why const.lua restates the direction and slot constants. If your port makes the sandbox inherit globals, scripts that test `if onSpellCooldown then` (vlib.lua:309) or `type(jit) ~= 'table'` will take different branches.
- vBot keeps a SECOND config store outside `storage`: HealBotConfig / AttackBotConfig / SuppliesConfig live in vBot_configs\profile_<N>\*.json and are saved eagerly by vBotConfigSave (vBot\configs.lua:63-97). A headless client that only reads storage/profile_1.json will miss the entire healing and attack configuration.
- BotServer's room is `storage.BotServerChannel`, NOT the URL path — the relay ignores the path (functions\server.lua:11-13). A profile with the right URL and a mismatched channel connects successfully and shows zero members, which looks identical to a broken relay. Also, the init frame must be sent from onOpen, not immediately after the constructor, or it is silently dropped (server.lua:54-68).

## Open questions
- `context.walk(dir)` delegates to `modules.game_walk.smartWalk` (functions\player.lua:64), which merges two simultaneously-held directions into a diagonal and does client-side prewalk. I did not read game_walk fully. A headless port needs the exact rule set for: whether the bot's own walk() should ever produce a diagonal, and whether prewalk / walk-cancel handling belongs in the runtime core or in the walking modules (cavebot\walking.lua). Recommend reading modules\game_walk\walk.lua:1-210 before finalising sender:walk semantics.
- `g_map.findEveryPath` is a C++ Dijkstra whose cost function and the exact meaning of each param flag (ignoreLastCreature, ignoreCost, allowUnseen, allowOnlyVisibleTiles, maxDistanceFrom) I documented only by name from functions\map.lua:80-113. The node tuple {cost, ?, direction, prevKey} has an unidentified second element. src\client\map.cpp findEveryPath must be read before reimplementing pathing; every walking module depends on its tie-breaking.
- `modules.gamelib.SpellInfo['Default']` supplies {id, words, exhaustion, premium, type, icon, mana, level, soul, group, vocations} for canCast (vlib.lua:278, 333-359). This table is client data, not server data. For Gunzodus (a custom server) most spells will only ever appear via the vBot.customCooldowns learn-by-observation path. Open question: should luaclient ship a static spell table, learn entirely from onSpellCooldown, or read the server's spell list packet if one exists at 1530?
- The bot's `check()` runs on the client's frame-driven scheduleEvent, so the effective tick rate is bounded by the render frame rate (backgroundFrameRate: 144 in config.otml). A headless client on a 10 ms timer will tick at a *steadier* rate than the original. Whether any module implicitly relies on tick jitter or on being throttled when the client is minimised is unverified.
- `context.saveConfig` (the executor's handle to bot.lua's save()) is never called anywhere in the vBot profile. Either it is dead API or it is used by private scripts not present in this profile. Worth exposing anyway, but I could not confirm intended semantics beyond 'flush storage now'.
- `onStatesChange` is connected on LocalPlayer only (bot.lua:595-599) and its payload is (player, states, oldStates). API.md does not list a corresponding luaclient event; states arrive inside the player-status packet. The exact bit layout of PlayerStates for 1530 (which vBot's player_conditions.lua indexes by name) needs confirming against the parser before the condition helpers can be ported.
- Whether a headless control plane should expose hotkeys at all is a design call. They carry no persisted state (unlike macros) and their only runtime effect is toggling macros and firing one-shot commands. I modelled them as named commands; if the web panel already has a command channel, `_hotkeys` could simply be dropped and `macro.hotkey` kept as a label.

## VERIFIER (confidence 0.88)

### Corrections (AUTHORITATIVE)
- **Claim**: §1.3 / pseudocode drains the scheduler as `local e = table.remove(ctx._scheduler, 1); pcall(e.callback)` — i.e. pop first, then run.
  - **Correction**: The original runs FIRST and removes AFTERWARDS: `pcall(function() context._scheduler[1].callback() end)` … `table.remove(context._scheduler,1)`. If the callback itself calls schedule() with a delay that sorts the new entry to index 1 (delay 0 when the head's execution == now, since table.sort is unstable on ties), the remove deletes the NEWLY INSERTED entry and the just-executed one stays at the head and re-runs. So the spec's stated failure mode ("a callback that schedules with delay 0 … will be executed in the same drain loop — an easy infinite loop") has the wrong mechanism: the delay-0 callback can be silently dropped while the ORIGINAL callback loops. Pop-then-run is a real behaviour change.
  - Evidence: D:/Claude/otclient_mehah1530/otclient/mods/game_bot/executor.lua:212-220
- **Claim**: §5 pseudocode: `local function dispatch(kind, ...) for _, w in ipairs(...) do local ok,err = pcall(w, ...) … end end` — "Each dispatch is individually pcall'd so one bad script callback cannot kill the bot (bot.lua:677-682 safeBotCall)".
  - **Correction**: safeBotCall wraps the ENTIRE dispatcher call, not each callback. `safeBotCall(function() botExecutor.callbacks.onTalk(...) end)` → one pcall around the whole `for i, callback in ipairs(context._callbacks.onTalk) do callback(...) end` loop. So in real vBot, if callback #1 throws, callbacks #2..N are NOT run for that event. Per-callback pcall makes later listeners run where they previously did not.
  - Evidence: bot.lua:677-682 (safeBotCall) and its call sites e.g. bot.lua:687; executor.lua:269-273 shows the un-pcall'd inner loop
- **Claim**: §5 pseudocode installs `ctx.isCooldownIconActive` / `ctx.isGroupCooldownIconActive` as sandbox globals fed by `ctx._cooldownUntil` / `ctx._groupCooldownUntil`.
  - **Correction**: Neither name is ever assigned into `context`. functions/player.lua:213-214 are two stray top-level EXPRESSION statements (`modules.game_cooldown.isGroupCooldownIconActive(id)` with an undefined global `id`), not assignments. Every real call site reaches them through the `modules` handle: `modules.game_cooldown.isCooldownIconActive(...)` / `isGroupCooldownIconActive(...)`. A port that only defines `ctx.*` breaks vlib.lua:368/374, Conditions.lua:239, exeta.lua:11, Sio.lua:219, AttackBot.lua:2840 — the port must expose a `modules.game_cooldown` table with those two names.
  - Evidence: mods/game_bot/functions/player.lua:213-214; profiles/bot/vBot_4.8/vBot/vlib.lua:368,374; Conditions.lua:239; exeta.lua:11; Sio.lua:219; AttackBot.lua:2840
- **Claim**: §5 bridge maps `events.on('creatureMove', function(d) dispatch('onCreaturePositionChange', d.creature, d.newPos, d.oldPos) …)`, `spellCooldown` → `d.iconId`/`d.duration`, `spellGroupCooldown` → `d.duration`, `tileUpdate` → `d.thing`, `containerAddItem` → `d.container`, `manaChange` → `d.oldMana`/`d.oldMaxMana`, `channelList` → `d.channels`, `creatureAppear`/`creatureDisappear`/`containerOpen`/`containerClose` → `d.creature`/`d.container`.
  - **Correction**: Almost every field name is wrong against the actual luaclient parser payloads: creatureMove emits `{creature, from, to}` (not newPos/oldPos); spellCooldown emits `{spellId, delay}`; spellGroupCooldown emits `{groupId, delay}`; tileUpdate emits `{pos, tile, added|changed}` (no `thing`, and it also fires on removals/changes, so mapping it unconditionally to onAddThing dispatches with a nil thing); containerAddItem/UpdateItem emit `{containerId, slot, item}` and containerRemoveItem `{containerId, slot, lastItem}` (no `container`, no `oldItem`, no `item` on remove); manaChange emits `{mana, maxMana, old}`; inventoryChange emits `{slot, item}` (no oldItem); channelList emits a bare list; creatureAppear/creatureDisappear emit the creature table directly; containerOpen/containerClose emit the container table directly (and there is no `previous`).
  - Evidence: luaclient/proto/parser.lua:1093, 1871, 1874, 1029, 1388, 1403, 1406-1408, 1783, 1320, 1961, 615, 411, 1362, 1375
- **Claim**: §5 bridge registers `events.on('animatedText', …)`, `events.on('staticText', …)` and `events.on('inventoryItems', …)`.
  - **Correction**: None of these three events exist in luaclient. The full emit set contains no `animatedText`, no `staticText`, and no `inventoryItems`; opcode 0xF5 (parser.lua:1429-1447) only fills `state.inventoryCounts` and emits nothing. As written, `onAnimatedText`, `onStaticText` and `onInventoryItemsUpdate` would never fire — the last one is exactly the callback callbacks.lua:233-240 documents as "fires on ANY carried-item amount change".
  - Evidence: luaclient/proto/parser.lua:1429-1447; full emit-name enumeration over luaclient/proto + luaclient/game
- **Claim**: §5 derived sugar: `ctx.onPlayerHealthChange = function(fn) return ctx.onCreatureHealthPercentChange(function(c, p) if c == ctx.player then fn(p) end end) end` (same pattern for onPlayerPositionChange, onPlayerInventoryChange).
  - **Correction**: In luaclient `st.player` and `st.creatures[playerId]` are two distinct tables — state.lua:503-504 copies the position across precisely because they are not the same object. The identity test `c == ctx.player` therefore never succeeds and every derived player-* callback is dead. Compare on `c.id == ctx.player.id` instead.
  - Evidence: luaclient/game/state.lua:139, 503-504; mods/game_bot/functions/callbacks.lua:256-271
- **Claim**: §5 bridge (the full `events.on(...)` list) is presented as the mapping of the callback set.
  - **Correction**: Four callback types that vBot actually registers are missing from the bridge entirely: `onUse` (2 uses, incl. vlib.lua:393 which drives `vBot.isUsing`), `onUseWith` (4), `onRemoveThing` (2), `onAttackingCreatureChange` (3). Also unmapped: onChannelEvent, onTurn, onStatesChange, onGameEditText, onImbuementWindow — of which `statesChange` and `channelEvent` DO exist as luaclient events. Note onUse/onUseWith are client-side self-echoes (Game::use calls `g_lua.callGlobalField("g_game","onUse",…)`), so the port must emit them from its own sender, not from the parser.
  - Evidence: grep over profiles/bot/vBot_4.8/{vBot,cavebot,targetbot,navibot}; src/client/game.cpp:852, 880; executor.lua:39-80
- **Claim**: §3.2: "`isInFight` and `canLogout` are aliases of the `Swords` bit."
  - **Correction**: `isInFight` is the Swords bit, but `canLogout` is its NEGATION: `return not context.hasCondition(PlayerStates.Swords)`. Implementing it as an alias inverts the meaning at every call site.
  - Evidence: mods/game_bot/functions/player_conditions.lua:18-19
- **Claim**: §4.2 / pseudocode: `Config.list` strips the extension with anchored patterns — `f:gsub("%.json$",""):gsub("%.cfg$","")`.
  - **Correction**: The original uses UNANCHORED Lua patterns with `.` as the any-char wildcard and no occurrence limit: `v:gsub(".json", ""):gsub(".cfg", "")`. So `"backup.json.bak"` becomes `"backup.bak"` (≠ v → kept, and listed under a mangled name), `"a.cfgx"` becomes `"ax"`, and any filename containing the 5-char sequence `<any>json` or `<any>cfg` anywhere is accepted and renamed. Anchoring changes which files appear in the config list and under what names.
  - Evidence: mods/game_bot/functions/config.lua:28-33
- **Claim**: §4.2 and the pseudocode `C.load`: "`Config.load(dir, name)` — `<dir>/<name>.json` via json, else `<dir>/<name>.cfg` via table.decodeStringPairList, else error"; pseudocode calls `json.decode(s)` bare.
  - **Correction**: Both branches are pcall'd and a parse failure LOGS and returns `{}`, it does not raise. A corrupt targetbot_configs/*.json therefore silently yields `{}`, which propagates into Config.setup's `data` (non-nil, so target.lua:132 does NOT turn the macro off) and TargetBot loads an empty targeting/looting set. A raising reimplementation behaves very differently. Only a missing file both-extensions reaches the `context.error("Config … doesn't exist")` path.
  - Evidence: mods/game_bot/functions/config.lua:55-81; profiles/bot/vBot_4.8/targetbot/target.lua:131-135
- **Claim**: CONFIG FORMAT: "Decoder regex caps the KEY at 20 chars and forbids ':' and '\n' in it."
  - **Correction**: Two omissions. (a) The character class is `[^:^\n]` — it also forbids `^` in a key. (b) decodeStringPairList DROPS any pair whose value is empty (`elseif v[2]:len() > 0 and v[3]:len() > 0`), and any pair whose key is empty. A cavebot action line with no value (e.g. `stand:`) written by encodeStringPairList does not survive the round trip. A reimplementation that keeps empty-valued pairs will load routes the real client silently truncates.
  - Evidence: modules/corelib/table.lua:291-293, 322-324
- **Claim**: §1.2/§1.5: `_currentExecution` is set to the macro and cleared to nil after the body; event callbacks save/restore.
  - **Correction**: Correct on the happy path, but the reset is INSIDE the wrapper and after `callback(...)`, while the pcall lives outside in executor.lua. If the user body throws, `context._currentExecution` is never reset and keeps pointing at the throwing macro (same for the hotkey wrapper, and the callback wrapper never restores `prevExecution`). A later `delay()` called from a schedule() body — which the spec says only logs an error because `_currentExecution` is nil — will instead silently delay that stale macro. Worth reproducing or explicitly fixing, but it must be a stated decision.
  - Evidence: mods/game_bot/functions/main.lua:113-125, 167-179; functions/callbacks.lua:19-31; executor.lua:201-208
- **Claim**: §0: "`online()` (game start) schedules `refresh` **20 ms** after login (`B\bot.lua:339-344`)."
  - **Correction**: The 20 ms is right but the guard is omitted: `if not (modules.client_profiles and modules.client_profiles.ChangedProfile) then scheduleEvent(refresh, 20) end`. When the login was the result of a profile switch, refresh is NOT scheduled at all and the bot does not start on that login.
  - Evidence: mods/game_bot/bot.lua:339-344
- **Claim**: §0 step 3-4: "Read which config is active and whether the bot is enabled … If disabled → stop."
  - **Correction**: Omits a state mutation that runs before the enable check: after `configList:setCurrentOption(settings[index].config)`, if the resulting current option's text differs from the stored config name, refresh() OVERWRITES `settings[index].config` with the list's current option AND force-sets `settings[index].enabled = false`. So a stored config name that is no longer a directory under /bot silently disables the bot and rewrites the settings node.
  - Evidence: mods/game_bot/bot.lua:349-355 (the `if currentOpt and currentOpt.text ~= settings[index].config` block)
- **Claim**: §1.3: "Macros added during the loop … `ipairs` will reach them **in the same tick** if the index is ahead."
  - **Correction**: They are reached but can never FIRE in that tick: a fresh macro's `lastExecution = context.now + math.random(0,100)`, which is ≥ now, so `lastExecution + timeout <= now` is false for every timeout ≥ 50. The observable statement is "registration mid-tick is legal and the new macro first fires on a later tick".
  - Evidence: mods/game_bot/functions/main.lua:42-48; executor.lua:200
- **Claim**: §1.3: "**fixed 10 ms period**, re-armed before the body runs (period does not drift with body cost)."
  - **Correction**: `scheduleEvent(check, 10)` posts into the client event dispatcher, which is drained once per frame after `g_clock.update()` (application.cpp:165/186, graphicalapplication.cpp:317). The effective period is therefore `max(10 ms, frame time)` — ~16.6 ms at 60 FPS — not 10 ms. A headless port with a true 10 ms timer runs every macro ~1.6× more often than the real client, which changes every `now - x > y` threshold tuned against it.
  - Evidence: mods/game_bot/bot.lua:525-546; src/framework/core/clock.h:31-35; src/framework/core/application.cpp:165,186
- **Claim**: §3.4 `findAllPaths` params: "Params (booleans converted to 0/1): ignoreLastCreature ignoreCreatures ignoreNonPathable ignoreNonWalkable ignoreStairs ignoreCost allowUnseen allowOnlyVisibleTiles maxDistanceFrom destination".
  - **Correction**: Two problems. (a) `destination` is not a findAllPaths param — it is injected by findPath (map.lua:169) and is a STRING "x,y,z", so the boolean→0/1 pass must not touch it. (b) The spec omits the `maxDistanceFrom` normalisation: a table of length 2 is encoded as `"<p.x>,<p.y>,<p.z>,<n>"` and a table of length 4 as `"a,b,c,d"` before being handed to g_map.findEveryPath. Without that, `maxDistanceFrom` silently does nothing.
  - Evidence: mods/game_bot/functions/map.lua:96-112, 168-170
- **Claim**: §3.5 `findItem`: "scan inventory slots InventorySlotFirst=1 .. InventorySlotLast=10 … then g_game.findItemInContainers(id, subType, tier or 0) … requiring `item:getTier() == tier`."
  - **Correction**: Correct for the container half, but the asymmetry is not stated: the equipped-slot scan matches on id and subType ONLY and ignores `tier` entirely, while the container scan hard-requires `getTier() == tier` with tier defaulting to 0. So `findItem(id)` returns a tiered equipped item but will never return a tiered item out of a container.
  - Evidence: modules/gamelib/game.lua:5-17; src/client/container.cpp:69-75; src/client/game.cpp:922-933
- **Claim**: §3.1 lists the sandbox as chaining nothing to _G and enumerates the stdlib subset; §3 notes const.lua "restates direction constants (`B\functions\const.lua:12-18`)".
  - **Correction**: Wrong line range: the direction constants are const.lua:3-10. Lines 12-18 are the SpellAim* constants (SpellAimNone=0, SpellAimCrosshair=1, SpellAimCursor=2, SpellAimTarget=3), and const.lua also restates every InventorySlot* constant at 20-33. Both blocks matter — `castSpellAt` reads `context.SpellAimCursor` and player_inventory.lua reads InventorySlot* — so a port that only restates directions leaves those nil.
  - Evidence: mods/game_bot/functions/const.lua:3-10, 12-18, 20-33; functions/player.lua:114; functions/player_inventory.lua:3-14
- **Claim**: §1.1: "`macro(20, …)` in `P\cavebot\cavebot.lua:76` actually runs at 50 ms."
  - **Correction**: The clamp claim is right; the citation is wrong. `cavebotMacro = macro(20, function() …` is at cavebot.lua:80, not :76.
  - Evidence: profiles/bot/vBot_4.8/cavebot/cavebot.lua:80
- **Claim**: §5.1: "Registering onAddThing/onRemoveThing turns on g_game.enableTileThingLuaCallback(true) — a global perf switch, off by default and reset in `clear()` (`bot.lua:117`)."
  - **Correction**: The behaviour is right; the reset is at bot.lua:115, not 117.
  - Evidence: mods/game_bot/bot.lua:115
- **Claim**: §3.4: "`getSpectators([param1],[param2])` … `param1` table → centre position …; `param1` userdata (creature) → centre = its position …" presented as alternative dispatch branches.
  - **Correction**: They are two SEQUENTIAL `if` blocks, not `elseif`. The table branch reassigns `param1 = param2` and then the userdata test runs against the NEW param1, so `getSpectators(somePos, someCreature)` overwrites the explicit centre with the creature's position and direction. A port using exclusive branches diverges on that call shape.
  - Evidence: mods/game_bot/functions/map.lua:17-26
- **Claim**: §4.3: "`setOn/setOff` work by *simulating a click* on the switch … so **switching a config on re-loads and re-applies it**."
  - **Correction**: Only when the state actually changes. `setOn(true)` on an already-on switch takes the `if not widget.switch:isOn()` branch and does nothing — no click, no refresh(), no callback. Only a real transition re-loads and re-applies the config.
  - Evidence: mods/game_bot/functions/config.lua:238-259
- **Claim**: §1.5: "`delay(duration)` … Suspends the currently executing macro / hotkey / event-callback" — presented as the only way a macro gets delayed.
  - **Correction**: Modules also write the field directly from outside any execution context: `TargetBot.delay = function(value) targetbotMacro.delay = now + value end`. The macro record returned by `macro()` must therefore expose a plain, externally-writable `delay` field (and `enabled`, `timeout`, `lastExecution`), not just the delay() entry point.
  - Evidence: profiles/bot/vBot_4.8/targetbot/target.lua:234-236
- **Claim**: CONFIG FORMAT (4): cavebot .cfg = "N action pairs in route order, then exactly three reserved trailing pairs appended by CaveBot.save()".
  - **Correction**: The `config` pair is conditional: `if CaveBot.Config then table.insert(data, {"config", …}) end`. `extensions` and `staypositions` are unconditional. A loader must tolerate two trailing pairs. Also note the three use different indents — `config` and `staypositions` are json.encode(t) with no indent argument, `extensions` is json.encode(t, 2) — which is what makes a non-empty extensions blob take the `[[\n…\n]]` multiline form.
  - Evidence: profiles/bot/vBot_4.8/cavebot/cavebot.lua:590-609
- **Claim**: §2.4: "Loads HealBotConfig, AttackBotConfig, SuppliesConfig … (`configs.lua:22-61`)" with no failure semantics stated.
  - **Correction**: On a json.decode failure each block does `return onError(...)`, but `onError` is NOT in the sandbox (`context` has info/warn/warning/error only). So a corrupt HealBot.json raises "attempt to call a nil value (global 'onError')", which aborts configs.lua, aborts _Loader's dofile chain, and aborts the whole executeBot pcall — the bot fails to start with a misleading error rather than logging one. Reproduce or explicitly fix, but do not model it as a clean logged failure.
  - Evidence: profiles/bot/vBot_4.8/vBot/configs.lua:31-61; executor.lua:160-163
- **Claim**: §3.2 conditions: "`hasCondition(mask)` = `bit.band(player:getStates(), mask) > 0`".
  - **Correction**: The source calls `Bit.band` (the corelib Bit helper table), not the LuaJIT `bit` module. Functionally the same result, but note that `bit`/`bit32` in the sandbox are separate handles (executor.lua:84-85) and the conditions file runs in the module env, not the sandbox — so a port must not assume the sandbox `bit` is what backs hasCondition.
  - Evidence: mods/game_bot/functions/player_conditions.lua:7; executor.lua:84-85
- **Claim**: §3.2 inventory: "`moveToSlot(item, slot, [count])` → `g_game.move(item, {x=65535,y=slot,z=0}, count)`".
  - **Correction**: Two behaviours omitted: a numeric `item` is first resolved via `context.findItem(item)` (and the call is a no-op if that returns nil), and `count == nil` defaults to `item:getCount()` — the full stack — it is not passed through as nil.
  - Evidence: mods/game_bot/functions/player_inventory.lua:34-45
- **Claim**: §3.3: "`buy(item,[count=1],[ignoreCapacity=false],[withBackpack=false])`".
  - **Correction**: The default is `count == nil or count <= 0 → 1`, so 0 and negatives clamp to 1 as well (unlike `sell`, where `count == 0 → 1` but `count == -1` means "all"). Also both `sell` and `buy` resolve a numeric item id by scanning getSellItems()/getBuyItems() first and only fall back to `Item.create(id)`.
  - Evidence: mods/game_bot/functions/npc.lua:71-117
- **Claim**: §3.4: "`canShoot(pos,[distance=5])` → `tile:canShoot(distance)`".
  - **Correction**: Omits the guard: `local tile = g_map.getTile(pos, distance); if tile then return tile:canShoot(distance) end; return false`. An unknown/unloaded tile returns false, not nil and not an error — which matters because vBot treats "no tile" and "no line of sight" identically here.
  - Evidence: mods/game_bot/functions/map.lua:249-256
- **Claim**: §3.3: "`autoWalk(dest,[maxDist],[params])` or `autoWalk(dirsList)` — list form → `g_game.autoWalk(dirs, {0,0,0})`".
  - **Correction**: The list form is only taken when `type(destination)=='table' and table.isList(destination) and not maxDist and not params`. Passing a direction list together with any second/third argument falls through to the findPath branch, which then indexes `destination.z` on a list and errors.
  - Evidence: mods/game_bot/functions/map.lua:223-237
- **Claim**: §1.7: "Stored in `context._hotkeys[normalisedKeyString]`; duplicates rejected with an error (`main.lua:144-146`)."
  - **Correction**: It is `return context.error(...)` — a logged message returning nil, not a raised error; the caller gets nil back instead of a hotkey handle. There is also a prior guard the spec omits: `keys = retranslateKeyComboDesc(keys); if not keys or #keys == 0 then return context.error("Invalid hotkey keys "..name) end`. The headless command registry needs the same "returns nil on rejection" contract or scripts that index the result will break differently.
  - Evidence: mods/game_bot/functions/main.lua:140-146
- **Claim**: §5.2 table header implies each luaclient event maps to one bot callback; the bridge merges creatureMove into both onCreaturePositionChange and onWalk.
  - **Correction**: In the real client these are two distinct signals with different firing rules: `Creature.onPositionChange` (bot.lua:585 → onCreaturePositionChange) fires on any position-field change including teleports, while `Creature.onWalk` (bot.lua:588 → onWalk) fires on walk animation start with (creature, oldPos, newPos). Collapsing both onto one `creatureMove` emit makes every teleport also look like a walk to onWalk listeners.
  - Evidence: mods/game_bot/bot.lua:582-589; executor.lua:309-313, 384-388
- **Claim**: §3.7 BotServer: "`terminate()` wipes `_callbacks`, so listeners must be re-registered"; "`isConnected()`".
  - **Correction**: `terminate()` only wipes `_callbacks` when `_websocket` is non-nil — the assignment is inside the `if` — so terminate() on an already-dead socket leaves stale listeners. And `isConnected()` is `_wasConnected and _websocket ~= nil`, with `_wasConnected` initialised to `true` (server.lua:24), so it reports connected from the moment init() returns, before any handshake or first message.
  - Evidence: mods/game_bot/functions/server.lua:24, 131-137, 156-158

### Additions
- VERIFIED CORRECT (no change needed): the 50 ms macro-timeout floor (main.lua:38-40); the `lastExecution = now + math.random(0,100)` jitter (main.lua:46); the wrapper returning true / user return value discarded (main.lua:113-125); `lastExecution` not advanced on delay or on throw (executor.lua:200-208); `now`/`time` sampled once per tick from the frame-cached clock and `realMillis()` used only for the slow-macro timer (executor.lua:196-197, clock.h:31-35, clock.cpp:27-35); macro order == registration order == load order; enable-state persistence keyed by name string only with `== true` as the only restoring value (main.lua:69,82,100-102); unnamed macros forced on (main.lua:104); the macro pass finishing before the scheduler pass; the broken `remove()` in callbacks.lua comparing the list against its elements (callbacks.lua:32-45); enableTileThingLuaCallback gating; save() bailing on a nil executor and on a missing settings node, json.encode indent 2, the 100 MB refusal, and the whole-file overwrite (bot.lua:298-321); bot death on an error escaping script() (bot.lua:536-539); the 5-message ring with a 5000 ms TTL (bot.lua:503-523,541-545).
- VERIFIED CORRECT: every on-disk fact in the CONFIG FORMAT section. profiles/config.otml:47 is `profile: 1`; the `bot:` node starts at line 2572 with exactly the quoted `Wfawdsafwfwad_1530` / `Tmk Creew_1530` entries and the `<CharacterName>_<clientVersion>` key shape. storage/profile_1.json is 44,975 bytes with exactly the 33 listed top-level keys, and `_configs`/`_macros`/`_icons`/`BotServerChannel`("test")/`BotServerUrl`("ws://etlac.cryrex.net:8000/") match verbatim including the `"": false` unnamed-macro entry. cavebot_configs/test.cfg and targetbot_configs/def_target.json are byte-identical to the quoted text. vBot_configs/profile_1..10 exist with HealBot.json / AttackBot.json / Supplies.json. `_Loader.lua` is the only top-level .lua and there are no top-level .otui files, and its load list matches lines 18-58 including the `AttackBot` last-of-majors / `Stances` after it comments.
- VERIFIED CORRECT: listDirectoryFiles's `(path, fullPath=true, raw=false, recursive=false)` signature and its `files.sort()` alphabetical guarantee (resourcemanager.h:82, resourcemanager.cpp:770-799); the --user-dir write-dir override (resourcemanager.cpp:384-410); getSpectators = aware-range rectangle via getSpectatorsInRangeEx with id dedupe (map.h:166-169, map.cpp:651-691); getSpectatorsByPattern's 0/-/1/+/NESW alphabet, odd-width-and-height requirement, single-floor scan and direction=8 sentinel (map.cpp:1475-1541, map.lua:19); all twelve area patterns exist at vlib.lua:1151-1297 including NormalUeAreaMs (1167) and NormalUeAreaEd (1181); `macro(100, ...)` at vlib.lua:390; findPath's cross-floor refusal and the marginMin<=max(|x|,|y|)<=marginMax ring (map.lua:159-192); isTrapped's harmless sign mirroring (map.lua:258-271); Chebyshev getDistanceBetween ignoring z (executor.lua:124-126); slots 1..10 with Purse=11 excluded (player.lua:595-599); Game::talk → talkChannel(MessageSay=1,0,text) (game.cpp:1036-1042); use/useWith/useInventoryItem/useOnCreature wire mapping incl. findEmptyContainerId (game.cpp:839-905); `manapercent()` returning 100 when maxMana<=1 and `hppercent()` being the server-sent percent (player.lua:8-15; LocalPlayer::setHealth at localplayer.cpp:351-367 never touches m_healthPercent); saySpell's 1000 ms default and the useRune `lastRuneTimeout` global-leak bug (player.lua:139-193); setOutfit's requestOutfit + schedule(100, changeOutfit) (player.lua:54-60); NPC sell's `count==0→1` before `nil/-1→all` ordering and the weight/100 field shape (npc.lua:21-93); loadRemoteScript's storage.scriptsCache fallback (script_loader.lua:30-69); Config.setup's storage._configs shape, isRefreshing guard, refresh() state machine, immediate callback at setup, and the add-name validation (whitespace→'_', length 1..29, no / or \, must not exist) (config.lua:130-229); the whole BotServer contract — defaultUrl, channel-as-room, init frame from onOpen, ping echo, topic-then-'*' dispatch with (name,message,topic), 2000ms*2^(min(attempts,5)-1) backoff capped at 10 attempts, "resolve error"→stopReconnect, generation-debounced requestReconnect(1200), timeout=3 (server.lua:14-206); reload() at ingame_editor.lua:6; Config.setup call sites at cavebot.lua:207 and target.lua:131.
- PORTING HAZARD the spec does not mention: both `_Loader.lua:2` and `vBot/configs.lua:5` obtain the config name from a UI widget — `modules.game_bot.contentsPanel.config:getCurrentOption().text`. Neither file can run headless as-is. The port must inject the active config name (and `g_settings.getNumber('profile')`) into the sandbox before those files execute, otherwise the very first two lines of vBot's manifest and its second config store both fail.
- PITFALL the spec identifies correctly but under-specifies: modules/game_cooldown/cooldown.lua's `onSpellCooldown` and `onSpellGroupCooldown` both `return` early when `cooldownWindow:isVisible()` is false, so with the panel closed the tables are never populated and `isCooldownIconActive` always returns false. Beyond that, `isCooldownIconActive`/`isGroupCooldownIconActive` have TWO branches: with the tier-upgrade feature the stored value is an absolute `g_clock.millis() + duration` compared against now (which is what the spec models), but without it the stored value is the boolean `true`, cleared only by the progress-rect finish event. `onSpellGroupCooldown` also drops any groupId not present in `SpellGroups`. Pick the numeric model deliberately and say so.
- One more engine detail worth stating explicitly for the port: `context.dofile(file)` prefixes `"/bot/" .. config .. "/"`, so `_Loader`'s `dofile("/vBot/main.lua")` resolves to `/bot/vBot_4.8//vBot/main.lua` (double slash, tolerated by PhysFS). Also `context.loadScript(path)` for a LOCAL path loads with `_ENV = context` too — the spec's §3.1 row only describes the remote-caching half.
