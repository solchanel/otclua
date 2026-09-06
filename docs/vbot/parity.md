# Feature parity — CaveBot / AttackBot / TargetBot+Looting vs real vBot 4.8

Consolidated by the integration work item on 2026-09-06, reconciling four parallel work items
(Q1 = `bot/cavebot.lua`, Q2 = `bot/attackbot.lua`, Q3 = `bot/targetbot.lua`+`bot/loot.lua`,
Q4 = `shim/` compat-layer behaviour tests) after all four landed. This is the honest answer to
"is it a mirror copy now": **every documented action type, spell category, targeting field and
looting rule is implemented or explicitly, deliberately not implemented for a stated reason** —
there is no undocumented gap left in the three engines. Two narrow wire-level gaps remain and are
listed in full at the bottom (§4); both require a proto/parser.lua or proto/sender.lua builder
that is outside every current work item's file ownership.

Legend: **✅ implemented** (behaviour-tested against the real vBot source) · **◐ partial**
(works, with a stated simplification) · **✖ not implemented** (stated reason + blocker).
Every row cites the real vBot source file the behaviour was verified against; the fuller spec for
each is in the companion doc named in the "spec" column — that spec's own `## VERIFIER
(Corrections)` section is authoritative over its body.

---

## 1. CaveBot — waypoint action types

Source: `vBot/cavebot.lua` action table. Spec: `docs/vbot/cavebot.md` (§1.6 for the action-value
grammar). Test: `test/botsuite.lua` M2 section (220 assertions).

| action | status | real source | note |
|---|---|---|---|
| `goto` | ✅ | `actions.lua` | |
| `label` / `gotoLabel` | ✅ | `cavebot.lua` | |
| `function` | ✅ | `cavebot.lua` | arbitrary Lua snippet through `bot/api.lua`'s sandbox |
| `delay` | ✅ | `cavebot.lua` | |
| `walkdelay` | ✅ | `route_tools.lua` | |
| `exanihur` / `turn` | ✅ | `route_tools.lua` | |
| `forge` | ✖ not implemented | `route_tools.lua` | needs `g_game.forgeRequest` (`Otc::ForgeAction_t`); no `proto/sender.lua` builder exists. **§4.1** |
| `doors` / `opendoors` | ✅ | `doors.lua` | |
| `cleartile` | ✅ | `clear_tile.lua` | |
| `poscheck` | ✅ | `pos_check.lua` | |
| `bank` (`deposit`\|`withdraw`\|`transfer`) | ✅ | `bank.lua` | all three sub-modes |
| `travel` | ✅ | `travel.lua` | |
| `buysupplies` | ✅ | `buy_supplies.lua` | |
| `sellall` | ✅ | `sell_all.lua` | |
| `depositor` (plain) | ✅ | `depositor.lua` | |
| `depositor` (`stow=true` / `stowdeposit`) | ◐ partial | `depositor.lua` | real algorithm is a two-pass stash-then-depot with a per-item 3-try `stowAttempts`/`stowFallback` cache and a "yes" reopen-loot-containers mode, driven by `g_game.stashStowItem`. That sender builder does not exist, so this action currently falls back to a plain depositor pass instead. **§4.2** |
| `withdraw` | ✅ | `withdraw.lua` | depot-box-index or inbox (non-numeric source ⇒ inbox, matching upstream's `tonumber()` nil quirk) |
| `dpwithdraw` | ✅ | `d_withdraw.lua` | cap-limit bailout, sub-container-when-full, stash-empty detection; the real script's second, unreachable `containerIsFull` branch (dead code — references an undefined local) is deliberately not reproduced |
| `inwithdraw` | ✅ | `inbox_withdraw.lua` | |
| `imbuing` (`config` only) | ✅ | `imbuing.lua` | full shrine → select → clear → apply → close state machine; only the human-facing per-item slot-picker GUI window has no headless equivalent (see §3) |
| `rushlure` | ✅ | `stand_lure.lua` | distance/hasEnough gates, blocking-monster clear+chase, `enable` flag applied same-tick instead of deferred to a GUI `onChildFocusChange` event (net effect identical one tick earlier) |
| `tasker` | ✅ | `tasker.lua` | markers 1/2/3, NPC-in-range gates, `Loot of …` kill counter; deliberately reproduces the real script's own bug where an invalid marker's `dataValidationFailed()` does not actually stop execution |

**CaveBot total: 22/23 action types implemented (1 partial, 1 blocked).** The blocked one
(`forge`) and the partial one (`stowdeposit`'s stash half) both need a new `proto/sender.lua`
builder — see §4.

Config-executing non-action files (`minimap.lua`, `recorder.lua`, `editor.lua`,
`extension_template.lua`) carry **zero waypoint-execution logic** — they are GUI-only (right-click
menu, manual-walk recorder, the waypoint-list editor panel, a developer template never loaded by
`cavebot.lua`). Confirmed N/A for a config-executing headless client, not a gap.

---

## 2. AttackBot — spell categories, patterns and optimizers

Source: `vBot/AttackBot.lua`. Spec: `docs/vbot/attackbot.md` + `docs/vbot/attackbot-full.md`
(§6–7 for the optimizers). Test: `test/botsuite.lua` M1 section (294 assertions) + `test/bot_m1.lua`
(294 assertions standalone).

| feature | status | real source | note |
|---|---|---|---|
| category 1 (targeted spell) | ✅ | AB:2921-2930 | |
| category 2 (area rune) | ✅ | AB:3072-3090 | best-tile scan, rune-delay gate, "hold the tick" rule |
| category 3 (targeted rune) | ✅ | AB:2921-2930 | |
| category 4 (Empowerment) | ✅ | AB:2915-2919 | no BlackList/Kills guard, matches spec |
| category 5 direction spells (monk patterns, `getMonkBestDir`) | ✅ | AB:2932-3070 | |
| category 5 Thousand Fist Blows (pattern 15, target-centred) | ✅ | AB:2932-3070 | |
| category 5 chain spells, optimizer OFF (patterns 17/18, ≤3 sqm) | ✅ | AB:2978-3006 | |
| category 5 waves/beams (`getWaveBestDir`) | ✅ | AB:3007-3061 | pattern 8 (Large Beam) keeps vBot's own bug — quadrant-`bestSide`-only, no turning — verbatim, by design |
| category 5 self-centred areas | ✅ | AB:3062-3068 | |
| wave augmentation (`augmented` + `WAVE_AUGMENTS`) | ✅ | AB:1296-1301 | now routed through `bot/data/optimizers.lua`'s `OPT.augmentedPattern`, which also fixed a missing `:trim()` the prior inline lookup had |
| **Optimizer 1 — Chained Penance** (hop chain) | ✅ | AB:1431-1455 | hops from the LAST hit, highest-hp preference |
| **Optimizer 2 — Spiritual Outburst** (hop chain, re-target) | ✅ | AB:1431-1455, 1488-1512 | exact seed tie-break order: counted → total → isCurrent |
| **Optimizer 3 — Forked Thorns** (star fork) | ✅ | AB:1458-1473 | star measured from the SEED, not the player |
| **Optimizer 4 — Forked Glacier** (star fork) | ✅ | AB:1458-1473 | same star simulation as Forked Thorns |
| **Optimizer 5 — Thousand Fist Blows tile scan** | ✅ | AB:1525-1551 | own-tile-first, tie-break nearest-to-player, casts via `sh:sayAt` (SpellAimCursor=2) |
| `opts.optimizers` gate + `opts.optimizerHook` test override | ✅ | AB:1380-1631 doc | algorithm is the DEFAULT/fallback; the hook only overrides for tests, per the work item's explicit requirement |
| rune delay / shared 1 s slot / group cooldown | ✅ | AB:3093-3101 | |
| PvP mode short-circuit + PvpSafe grid veto | ✅ | AB:2896-2907 | |
| mana%/harmony/cooldown gates | ✅ | A7 test section | |
| Auto Turn + `autoTurnAndFire` | ✅ | | |
| TFB `castAtPos` SpellCastTable dedup bookkeeping | ◐ partial | AB:1556-1569 | real `castAtPos` mirrors `cast()`'s dedup/delay bookkeeping; `bot/shared.lua`'s `S:sayAt` (which the TFB path calls) is a plain passthrough with none. Only observably different in CustomCooldown mode with `entry.cooldown >= 100` on a TFB entry — ServerCooldown (the common case, `executeCooldown=30`) never reaches the affected branch. **§4.3** |

**AttackBot total: 17/18 rows fully implemented, 1 narrow partial** (a bookkeeping edge case
confined to one uncommon cooldown-mode combination).

---

## 3. TargetBot + Looting

Source: `targetbot/target.lua`, `creature.lua`, `creature_priority.lua`, `creature_attack.lua`,
`looting.lua`. Spec: `docs/vbot/targetbot.md`. Test: `test/botsuite.lua` M3 section (259
assertions).

| feature | status | real source | note |
|---|---|---|---|
| 100 ms macro period, 13x13→7x7 crowd shrink at >10 monsters | ✅ | target.lua:49-62 | |
| candidate gathering (path computed before the type/monster test) | ✅ | target.lua:70-71 | |
| priority scoring: hysteresis, range gate, `rpSafe` cancel | ✅ | creature_priority.lua:7-19 | |
| diamond-arrows `+4`/mob self-count floor | ✅ | creature_priority.lua:33-45 | |
| low-HP `if/elseif` chase-dependent bonus chain | ✅ | creature_priority.lua:48-58 | |
| `calculateParams` strict `>`, danger on the winning config only | ✅ | creature.lua:74-93 | |
| name → regex matching, cache, all-matches-kept | ✅ (documented deviation) | creature.lua:21-29,53-72 | Lua-pattern translation instead of true regex (Lua has no alternation) |
| attack-only-on-change, dead attack-spell/rune branches | ✅ | creature_attack.lua:50-112 | |
| trapped-detection over 8 neighbours | ✅ | creature_attack.lua:119-127 | |
| dynamic-lure latch scoping (VERIFIER-corrected) | ✅ | creature_attack.lua:130-145 | |
| `killUnder` two-call-site disagreement | ✅ (documented deviation) | creature_attack.lua:151,171,174 | real vBot raises and aborts the tick on an absent key; we substitute a safe no-op + one-time log (never fires against the real profile, which always sets the key) |
| luring block, `#currentDistance==1` special case | ✅ | creature_attack.lua:151-173 | |
| rePosition: 500 ms throttle, walkable-tile count, CaveBot.GoTo bridge | ✅ | creature_attack.lua:22-48 | |
| chase rule | ✅ | creature_attack.lua:174-177 | |
| `keepDistance`: re-anchor + exact `{range,range+1}` dead band | ✅ | creature_attack.lua:178-189 | |
| `avoidAttacks`/`faceMonster` mutual exclusivity | ✅ | creature_attack.lua:192-232 | |
| stepper: nil-dest reset, Chebyshev distance, ONE step per call | ✅ | walking.lua:21-50 | |
| looting: full 13-step `process()` gate order | ✅ | looting.lua:107-183 | |
| looting: `lootLast` picks nearest corpse (`list[#list]`) | ✅ | looting.lua:121 et al | |
| looting: `getLootContainers` nested-spare-bag scan (keeps LAST match) | ✅ | looting.lua:186-235 | |
| looting: `lootContainer` — a listed container item falls through to be looted, not opened | ✅ (VERIFIER-corrected) | looting.lua:237-274 | |
| looting: `lootItem` two-pass gold (append-1-unit, then merge-remainder) | ✅ | looting.lua:284-301 | verified NOT a bug — verbatim upstream behaviour |
| looting: `onCreatureDisappear` discovery, 20-cap queue | ✅ | looting.lua:310-341 | deterministic insertion-order sort replaces vBot's comparator-mutation UB (documented deviation) |
| looting: `onContainerOpen` matched by container ITEM id | ✅ | looting.lua:303-308 | |
| looting: an un-acked corpse open has no timeout; `tries>30` is the only give-up path | ✅ (reproduced verbatim) | looting.lua (MAX_WALK_TRIES) | |
| `isFriend` / BotServer roster | ✖ not implemented | vBot.isFriend | luaclient has no self-hosted BotServer roster; `TB:isFriend` covers friend list, local player, and party members via `storage.playerList.groupMembers` — everything except a BotServer-shared roster, which does not exist in this client |

**TargetBot+Looting total: every documented rule implemented**, with four explicitly-labelled
deliberate deviations (regex→Lua-pattern, killUnder no-op substitution, deterministic sort,
no BotServer roster) that each reproduce the real *observable behaviour* without needing the
exact mechanism (a raised Lua error, a BotServer socket) that produces it upstream.

---

## 4. Remaining wire-level gaps (blocked on files outside every current work item)

These three items are the only genuine behavioural gaps left across all three engines, and every
one is blocked on the same kind of thing: a `proto/sender.lua` (or `proto/parser.lua`) builder
that does not exist yet, needed by a file none of Q1–Q4 owns.

1. **`forge` waypoint action** (§1) — needs a `sender:forgeRequest(actionType)` builder for
   `g_game.forgeRequest` / `Otc::ForgeAction_t`. The waypoint logic itself is trivial (send
   actionType 2 convert-dust or 4 increase-limit, 800 ms delay, retry until a configured send
   count) once the builder exists.
2. **`stowdeposit`'s stash half** (§1) — needs a `sender:stashStowItem(pos, itemId, subType,
   stackpos, action)` builder for `g_game.stashStowItem` (opcode 0x28 per `docs/shim/api-game.md`
   gap G10). Until then the action takes a plain depositor pass instead of the real two-pass
   stash-then-depot algorithm.
3. **TFB `castAtPos` dedup bookkeeping** (§2) — needs `bot/shared.lua`'s `S:sayAt` to gain the
   same `SpellCastTable`-style dedup/delay bookkeeping `S:cast` already has. Only observable in
   CustomCooldown mode with a ≥100 ms cooldown on a Thousand Fist Blows entry specifically.

None of these three are reachable from inside `bot/cavebot.lua`, `bot/attackbot.lua`,
`bot/targetbot.lua` or `bot/loot.lua` alone — they need a change to `proto/sender.lua` or
`bot/shared.lua`, which is why they were routed to `crossFileRequests` rather than fixed in
place. They do not block "mirror copy" status for any waypoint/spell/rule a typical profile
actually uses; `forge` and `stowdeposit`'s stash mode are both off by default and absent from the
user's own real cavebot routes checked by `tools/vbot_compat_check.lua`.

---

## 5. Cross-engine reconciliation notes (this integration pass)

Q1 (CaveBot) and Q3 (TargetBot) both touch the CaveBot↔TargetBot bridge (`bot._attacking`,
`CaveBot.GoTo`/`cb:goTo` casing, the dynamic-lure 150 ms pull window) but through disjoint code
paths — `bot/cavebot.lua`'s `rushlure` action sets `TargetBot.setOn()/setOff()` directly, while
`bot/targetbot.lua`'s `rePosition()` calls back into CaveBot's `GoTo`. Both were re-read together
during this pass; no double-handling or conflicting assumption was found (`rushlure` never runs
concurrently with a dynamic lure — they are gated by different waypoint/priority conditions), so
no code changes were needed there.

The one genuine conflict found and fixed in this pass was environmental, not a Q1/Q2/Q3 code
conflict: `test/bot_m1.lua` and `test/botsuite.lua`'s "TargetBot picks the monster..." test both
construct `bot/attackbot.lua` against the user's real, live, read-only
`vBot_configs/profile_1/AttackBot.json`, whose top-level `enabled` flag (and attackTable[1]'s own
`enabled` flag) mirror the user's actual in-game toggles and have drifted to `false` during this
session (the user turned AttackBot off, and rule 1, in their live client while these four work
items ran in parallel). This produced a hard crash in `test/bot_m1.lua` (indexing a nil
`ab.lastSpell` after a tick that no longer fired) and a silent-failure assertion in
`test/botsuite.lua`. Fixed by forcing the profile (and every entry) on through
`bot/attackbot.lua`'s own `A:profile()`/`A:enable()` accessors in the in-memory decoded copy only
— the same pattern Q4 had already used in `test/shim_behaviour_suite.lua` for the identical drift
— never touching the file on disk. See `test/bot_m1.lua`'s `loadAttackBotJsonOn()` helper and the
comment block in `test/botsuite.lua`'s "TargetBot picks the monster..." section.
