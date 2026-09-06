# Bot configuration API — contract for structured, panel-editable vBot config

Extends BOT.md and PANEL.md. Goal (user's words): "attackbot, targeting, cavebot, conditions,
hp/mana healing, stances... should be configurable from the web panel as well." This is a
structured CRUD layer over the config files BOT.md already reads/writes, reachable from the panel
whether the instance is running or stopped, that keeps the files loadable by the real vBot
(`tools/vbot_compat_check.lua` is the acceptance test — nothing here may break it).

## The six config "kinds"

| kind | backing file(s) | shape | native module |
|---|---|---|---|
| `healbot` | `vBot_configs/profile_N/HealBot.json` → the ACTIVE `healbot[i]` profile's `itemTable`/`spellTable` | `{ itemTable: [{enabled,sign,origin,item,index,value}], spellTable: [...] }` (see bot/healbot.lua's `sourceValue`/`sign` for the exact operators: origin ∈ HP%\|HP\|MP%\|MP\|burst, sign ∈ = \| > \| < , both `>` and `<` are INCLUSIVE) | bot/healbot.lua |
| `conditions` | same `HealBot.json` → `ConditionPanel` block | the exact field set in bot/healbot.lua's `defaultConditionPanel()` — reproduce it verbatim, including the misspelled `curePosion` compat (read `curePoison` first, fall back to `curePosion`; WRITE `curePoison`, keep `curePosion` unset unless it was already present, then keep both in sync) | bot/healbot.lua (same module — conditions is a section, not a separate module) |
| `attackbot` | `AttackBot.json` → the ACTIVE profile's entries | array of attack entries; see bot/attackbot.lua for the entry fields (category, pattern, spell/itemId, monsters, count/orMore, minHp/maxHp, minMana, cooldown, enabled, pvpSafe) | bot/attackbot.lua |
| `stances` | `storage/profile_N.json` → `stances` key (NOT a separate file — same as real vBot: `storage.stances = {enabled, ignoreInPz, entries:[{spell,spellId,enabled,minHp,maxHp,minMana,count,orMore,monsters,range,description}]}`) | see `vBot/Stances.lua` in the reference profile for the exact entry shape | **bot/stances.lua (new — build it)** |
| `targetbot` | `targetbot_configs/<name>.json` → `targeting` array + `looting` section | per docs/vbot/targetbot.md | bot/targetbot.lua |
| `cavebot` | `cavebot_configs/<name>.cfg` → the ordered waypoint list + the `config`/`extensions`/`staypositions` lines | array of `{type, value}` in file order, per docs/vbot/config-compat-cavebot.md's grammar (`type` is the vBot action keyword: goto/label/gotolabel/delay/use/usewith/say/npcsay/function/...) | bot/cavebot.lua |

For `attackbot`/`healbot`/`targetbot` there can be several named profiles/configs per instance
(vBot's numbered profiles for heal/attack, named `.json`/`.cfg` files for cavebot/targetbot). The
API always operates on **the currently selected one** (what `bot.listConfigs`/the instance's
`cavebotConfig`/`targetbotConfig`/`vprofile` fields already name); switching which one is active is
the existing `bot.setCavebot`/`bot.setTargetbot`/vprofile mechanism, unchanged by this contract.

## Security — decide this once, get it right everywhere

`cavebot`'s `function` waypoint type carries a **raw Lua chunk** that the bot executes verbatim
(BOT.md, docs/vbot/config-compat-cavebot.md). Writing one is equivalent to `exec`. Every other
field in every kind is DATA (numbers, item ids, spell words as plain strings, monster name
patterns) — none of it is ever passed to `load()`/`loadstring()`.

Rule: `config.set` for `cavebot` is gated exactly like `instance.exec` (hub/api.lua's
`EXEC_CAPABILITY` set — admin, or a user with `canExec`) **only when the diff adds or changes a
`function`-type waypoint's body**; every other cavebot edit (reordering, editing a `goto`/`delay`/
`use`/... value) needs only the normal instance-owner permission. `config.set` for the other five
kinds never needs `canExec`. Every `cavebot` write is audited; a write containing a `function` body
change is audited with the full new body (same treatment as `exec`'s audit record).

## control/commands.lua (worker side) — new commands

```
config.get  { kind }                    -> { kind, data, source }   -- source: 'profile'|'default'
config.set  { kind, data, reload=true } -> { kind, applied=true }   -- validates, writes, reload()s
config.list { kind }                    -> { names=[...], active=name }  -- attackbot/healbot profile
                                                                     -- numbers or cavebot/targetbot names
```
`config.set` validates `data` against the kind's schema (right field names and types; reject,
don't coerce, on a structural mismatch — a bad request must not corrupt the file) and calls the
owning module's existing `:reload(cfg)` so the change applies to the running bot immediately,
without restarting the worker or losing its walk/target state.

## hub side

`hub/botconfig.lua` (new) — pure functions over a resolved profile directory, built on
`bot/config.lua`'s `config.new(dir)` `Profile` object (already pure, no `LC` dependency — verified:
its only inputs are paths and strings). One function pair per kind: `getX(profile, ...)` /
`setX(profile, ..., data)`, used when the instance is **stopped**. Must produce byte-for-byte the
same file shape `bot/config.lua`'s own save path does (reuse its `encodeCfg`/`jsonEncode`/
`writeFileAtomic` — do not hand-roll a second encoder).

`hub/api.lua` — new routes, instance-scoped, owner-or-admin like every other instance route:
```
GET  /api/instances/:id/config/:kind        -> { kind, data, source, editable }
PUT  /api/instances/:id/config/:kind        (body: {data})  -> { kind, applied }
GET  /api/instances/:id/config/:kind/list   -> { names, active }   (attackbot/healbot profile #s,
                                                                     cavebot/targetbot file names)
```
Routing: if the instance is **running**, forward to the worker's `config.get`/`config.set` over the
control socket (so the change hot-applies and the in-memory bot state stays authoritative); if
**stopped**, read/write the files directly via `hub/botconfig.lua` (no worker needed to edit config
before first start). Both paths funnel through the SAME validation (control/commands.lua's schema
checks are mirrored — not reimplemented — in hub/botconfig.lua; factor the schema tables into a
file both sides can load, e.g. `bot/configschema.lua`, required by both `control/commands.lua` and
`hub/botconfig.lua`).

Every `PUT` writes an audit record (`instance.config`, target = instanceId, detail = kind + a short
diff summary; full body when it is a cavebot `function` change, per the Security section).

## panel/

A new **Bot Config** area on the instance view, one card per kind (Healing, Conditions, Attack,
Stances, Targeting, CaveBot), each a table editor:
* add / duplicate / remove row, up/down (or drag) reorder for ordered kinds (attackbot entries,
  stances entries — first-match-wins order matters; cavebot waypoints — execution order matters)
* inline fields matching the schema (a select for `sign`/`origin`/`category`, a number input for
  thresholds, a checkbox for `enabled`/`orMore`, a text input for spell words / monster patterns)
* a CaveBot waypoint row's `function` type shows a code textarea with a visible "this runs as Lua
  inside the bot" warning, and is only editable by an admin or a `canExec` user — mirror the
  Console tab's existing capability check, don't invent a new one
* a single **Save** button per card that PUTs the whole kind's data (simplicity over partial PATCH;
  the files are small); a **Revert** button re-fetches
* load the current data on tab open via GET; show `source: 'default'` distinctly (an empty/new
  profile) from `source: 'profile'` (loaded from a real file)
* never block the rest of the instance view — these load lazily when the card is opened

## Compatibility acceptance test

For every kind, round-trip: hub/panel writes a config → the real vBot (via
`tools/vbot_compat_check.lua`, extended to cover `storage.stances` and the `HealBot.json`
`ConditionPanel`/`itemTable` shapes if not already) still parses the file → values compare equal
(ints stay ints, arrays stay arrays, unknown fields the panel didn't touch survive unchanged).
