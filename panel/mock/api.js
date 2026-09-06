/* ==================================================================
   mock/api.js — a complete, self-contained fake of the hub.
   ------------------------------------------------------------------
   Loaded only when index.html is opened with ?mock=1. It installs

     window.HubMock = { fetch(url, init) -> Promise<Response-like>,
                        WebSocket: <constructor>,
                        latencyMs, _db, _tick, _routes() }

   and the panel then builds its ordinary PanelRpc.HttpClient /
   WsClient on top of those two, so mock mode runs the SAME rpc.js,
   api.js and app.js code paths as a live hub: the same methods, the
   same paths, the same CSRF header, the same WebSocket handshake.
   The only thing swapped out is the network.

   That is the point: if a call works here it works against the hub,
   and panel/test/tests.js proves every endpoint in api.js's ENDPOINTS
   table is answered by the router below.

   Every value here is invented. No real credential is present, and
   the mock never echoes a submitted password anywhere.
   ================================================================== */

(function () {
'use strict';

/* ------------------------- tiny helpers ------------------------- */

var seed = 0x1a2b3c4d;
function rnd() {                       // xorshift32, so demos are repeatable
  seed ^= seed << 13; seed >>>= 0;
  seed ^= seed >> 17;
  seed ^= seed << 5;  seed >>>= 0;
  return seed / 4294967296;
}
function ri(a, b) { return a + Math.floor(rnd() * (b - a + 1)); }
function pick(a) { return a[Math.floor(rnd() * a.length)]; }
function now() { return Date.now(); }
function uid(p) { return p + '_' + Math.floor(rnd() * 0xffffff).toString(16); }
function clamp(v, a, b) { return v < a ? a : v > b ? b : v; }
function sha256ish(s) {                 // NOT a hash — a stable-looking id for display only
  var x = 2166136261 >>> 0, out = '';
  for (var i = 0; i < s.length; i++) { x ^= s.charCodeAt(i); x = (x * 16777619) >>> 0; }
  for (var j = 0; j < 8; j++) { x ^= x << 13; x >>>= 0; x ^= x >> 17; x ^= x << 5; x >>>= 0;
    out += ('0000000' + x.toString(16)).slice(-8); }
  return out;
}

/* --------------------------- the data --------------------------- */

var T0 = now();

var DB = {
  users: [
    { id: 'u_admin', name: 'arnold', role: 'admin', createdAt: T0 - 86400000 * 62,
      disabled: false, lastLoginAt: T0 - 3600000 * 3 },
    { id: 'u_sam',   name: 'sam',    role: 'user',  createdAt: T0 - 86400000 * 31,
      disabled: false, canExec: true,  lastLoginAt: T0 - 86400000 * 2 },
    { id: 'u_kim',   name: 'kim',    role: 'user',  createdAt: T0 - 86400000 * 9,
      disabled: true,  canExec: false, lastLoginAt: null }
  ],
  accounts: [
    { id: 'a_main', label: 'main-eu',  login: 'l4g-main',  ownerUserId: 'u_admin', has2fa: true },
    { id: 'a_alt',  label: 'alt-farm', login: 'l4g-alt',   ownerUserId: 'u_admin', has2fa: false },
    { id: 'a_sam',  label: 'sam-01',   login: 'sam-primary', ownerUserId: 'u_sam', has2fa: false }
  ],
  characters: [
    { id: 'c_1', accountId: 'a_main', name: 'Arnoldus',   world: 'Gunzodus', vocation: 'Knight',   lastLevel: 214 },
    { id: 'c_2', accountId: 'a_main', name: 'Ballista',   world: 'Gunzodus', vocation: 'Paladin',  lastLevel: 178 },
    { id: 'c_3', accountId: 'a_alt',  name: 'Mudflower',  world: 'Gunzodus', vocation: 'Druid',    lastLevel: 143 },
    { id: 'c_4', accountId: 'a_alt',  name: 'Emberwick',  world: 'Gunzodus', vocation: 'Sorcerer', lastLevel: 132 },
    { id: 'c_5', accountId: 'a_sam',  name: 'Kettlebell', world: 'Gunzodus', vocation: 'Monk',     lastLevel: 96  },
    { id: 'c_6', accountId: 'a_sam',  name: 'Spareparts', world: 'Gunzodus', vocation: null,       lastLevel: null }
  ],
  proxies: [
    { id: 'p_de', label: 'de-frankfurt', kind: 'http-connect', host: '10.20.0.11', port: 8080, user: 'w1', hasPass: true,  ownerUserId: 'u_admin' },
    { id: 'p_nl', label: 'nl-amsterdam', kind: 'http-connect', host: '10.20.0.12', port: 8080, user: 'w2', hasPass: true,  ownerUserId: 'u_admin' },
    { id: 'p_pl', label: 'pl-warsaw',    kind: 'http-connect', host: '10.20.0.13', port: 3128, user: null, hasPass: false, ownerUserId: 'u_sam' }
  ],
  instances: [],
  scripts: [
    { id: 's_1', name: 'refill_supplies.lua', size: 2417, sha256: sha256ish('refill'),
      ownerUserId: 'u_admin', createdAt: T0 - 86400000 * 12, instanceIds: ['i_1', 'i_3'],
      source: '-- refill_supplies.lua\n-- Buys mana potions when the backpack runs low.\nlocal MIN = 60\n\nmacro(2000, "refill", function()\n  local have = itemAmount(268)\n  if have and have < MIN then\n    info("refill: only " .. have .. " potions left")\n    CaveBot.setOff()\n    CaveBot.gotoLabel("bank")\n  end\nend)\n' },
    { id: 's_2', name: 'party_heal.lua', size: 1180, sha256: sha256ish('party'),
      ownerUserId: 'u_admin', createdAt: T0 - 86400000 * 5, instanceIds: ['i_3'],
      source: '-- party_heal.lua\nmacro(250, "party heal", function()\n  for _, spec in ipairs(getSpectators()) do\n    if spec:isPlayer() and spec:isPartyMember() and spec:getHealthPercent() < 60 then\n      say("exura sio \\"" .. spec:getName())\n      return\n    end\n  end\nend)\n' },
    { id: 's_3', name: 'afk_logout.lua', size: 640, sha256: sha256ish('afk'),
      ownerUserId: 'u_sam', createdAt: T0 - 86400000 * 1, instanceIds: [],
      source: '-- afk_logout.lua\nlocal LIMIT = 15 * 60 * 1000\nlocal lastFight = now\n\nonAttackingCreatureChange(function(c) if c then lastFight = now end end)\nmacro(5000, "afk logout", function()\n  if now - lastFight > LIMIT then g_game.safeLogout() end\nend)\n' }
  ],
  sessions: [
    { id: 'sess_cur', userId: 'u_admin', ip: '127.0.0.1', userAgent: 'Mozilla/5.0 (this browser)',
      createdAt: T0 - 3600000 * 3, lastSeenAt: T0, current: true },
    { id: 'sess_2', userId: 'u_sam', ip: '192.168.7.40',
      userAgent: 'Mozilla/5.0 (X11; Linux x86_64) Firefox/128.0',
      createdAt: T0 - 86400000 * 2, lastSeenAt: T0 - 3600000 * 20, current: false }
  ],
  audit: []
};

var CAVEBOTS  = ['drefia-ghouls.cfg', 'venore-dwarfs.cfg', 'roshamuul-lower.cfg', 'darashia-hydras.cfg', 'oramond-minos.cfg'];
var TARGETBOT = ['knight-default.json', 'paladin-safe.json', 'druid-aoe.json', 'monk-chain.json'];
var PROFILES  = ['profile_1', 'profile_2', 'profile_3'];
var MACROS = [
  { name: 'healbot',        label: 'HealBot' },
  { name: 'attackbot',      label: 'AttackBot' },
  { name: 'eat_food',       label: 'Eat food' },
  { name: 'anti_paralyze',  label: 'Anti-paralyze' },
  { name: 'auto_haste',     label: 'Auto haste' },
  { name: 'equip_manager',  label: 'Equipment manager' },
  { name: 'exeta_res',      label: 'Exeta res on 4+' },
  { name: 'depot_deposit',  label: 'Deposit at depot' }
];
var MONSTERS = ['Ghoul', 'Demon Skeleton', 'Dwarf Guard', 'Hydra', 'Minotaur Archer', 'Frost Dragon',
                'Nightmare', 'Grim Reaper', 'Juggernaut', 'Serpent Spawn'];
var CHATTERS = ['Zibbly', 'Oro Guard', 'Hellhound', 'Vandra', 'Pinchy McBite', 'Loot Goblin'];

function mkInstance(id, charId, proxyId, state, level, cave, targ, ownerUserId) {
  var ch = DB.characters.filter(function (c) { return c.id === charId; })[0];
  var acc = DB.accounts.filter(function (a) { return a.id === ch.accountId; })[0];
  var px = DB.proxies.filter(function (p) { return p.id === proxyId; })[0];
  var maxHp = 900 + level * 12, maxMana = 400 + level * 9;
  return {
    id: id,
    characterId: charId,
    characterName: ch.name,
    accountLabel: acc.label,
    world: ch.world,
    vocation: ch.vocation,
    ownerUserId: ownerUserId,
    proxyId: proxyId,
    proxyLabel: px ? px.label : null,
    botProfile: 'profile_1',
    cavebotConfig: cave,
    targetbotConfig: targ,
    scripts: [],
    autoStart: state !== 'stopped',
    autoRelogin: true,
    state: state,
    botEnabled: state === 'online',
    live: {
      level: level,
      exp: Math.round(Math.pow(level, 3) * 51),
      expPercent: rnd() * 100,
      expPerHour: state === 'online' ? 380000 + rnd() * 900000 : 0,
      moneyPerHour: state === 'online' ? 40000 + rnd() * 120000 : 0,
      lootPerHour: 0, wastePerHour: 0, balancePerHour: 0,
      killsPerHour: state === 'online' ? 90 + rnd() * 120 : 0,
      deaths: ri(0, 3),
      hp: Math.round(maxHp * (0.55 + rnd() * 0.45)), maxHp: maxHp,
      mana: Math.round(maxMana * (0.4 + rnd() * 0.6)), maxMana: maxMana,
      cap: ri(200, 1800), maxCap: 2400 + level * 10,
      soul: ri(0, 200), stamina: ri(2000, 2520),
      pos: { x: 32800 + ri(-140, 140), y: 31900 + ri(-140, 140), z: ri(6, 11) },
      target: null,
      waypoint: null, waypointIndex: 0, waypointCount: ri(28, 84),
      uptimeMs: state === 'stopped' ? 0 : ri(600, 86400) * 1000,
      onlineMs: state === 'stopped' ? 0 : ri(600, 80000) * 1000,
      reconnects: ri(0, 6),
      supplies: [
        { name: 'Mana potion',   itemId: 268,  count: ri(20, 220), min: 60 },
        { name: 'Health potion', itemId: 266,  count: ri(5, 120),  min: 40 },
        { name: 'Rune (SD)',     itemId: 3155, count: ri(0, 90),   min: 25 },
        { name: 'Food',          itemId: 3725, count: ri(0, 40),   min: 10 }
      ]
    }
  };
}

DB.instances = [
  mkInstance('i_1', 'c_1', 'p_de', 'online',  214, CAVEBOTS[3], TARGETBOT[0], 'u_admin'),
  mkInstance('i_2', 'c_2', 'p_nl', 'online',  178, CAVEBOTS[0], TARGETBOT[1], 'u_admin'),
  mkInstance('i_3', 'c_3', 'p_pl', 'online',  143, CAVEBOTS[2], TARGETBOT[2], 'u_admin'),
  mkInstance('i_4', 'c_4', 'p_de', 'error',   132, CAVEBOTS[1], TARGETBOT[2], 'u_admin'),
  mkInstance('i_5', 'c_5', null,   'stopped',  96, CAVEBOTS[4], TARGETBOT[3], 'u_sam')
];
DB.instances[0].scripts = ['s_1'];
DB.instances[2].scripts = ['s_1', 's_2'];

/* A crowd, so the panel is exercised at the size PANEL.md cares about.
   ?mock=1&fleet=40 makes it forty. */
(function bigFleet() {
  var want = 0;
  try {
    var m = /[?&]fleet=(\d+)/.exec(location.search);
    want = m ? Math.min(200, parseInt(m[1], 10)) : 0;
  } catch (e) { want = 0; }
  if (!want || want <= DB.instances.length) return;
  var FIRST = ['Grim', 'Ash', 'Bramble', 'Cinder', 'Dusk', 'Ember', 'Fen', 'Gale', 'Hollow', 'Iron',
               'Jag', 'Kestrel', 'Lark', 'Moss', 'Nettle', 'Onyx', 'Pike', 'Quarry', 'Rook', 'Slate'];
  var LAST = ['bane', 'wick', 'shade', 'thorn', 'ridge', 'fall', 'brand', 'mire', 'crest', 'vale'];
  var states = ['online', 'online', 'online', 'online', 'connecting', 'stopped', 'error'];
  while (DB.instances.length < want) {
    var n = DB.instances.length;
    var acc = DB.accounts[n % DB.accounts.length];
    var ch = { id: 'c_g' + n, accountId: acc.id,
               name: FIRST[n % FIRST.length] + LAST[(n / FIRST.length | 0) % LAST.length] + (n > 29 ? n : ''),
               world: 'Gunzodus', vocation: pick(['Knight', 'Paladin', 'Druid', 'Sorcerer', 'Monk']),
               lastLevel: ri(40, 300) };
    DB.characters.push(ch);
    var inst = mkInstance('i_g' + n, ch.id, pick(DB.proxies).id, states[n % states.length],
                          ch.lastLevel, pick(CAVEBOTS), pick(TARGETBOT), acc.ownerUserId);
    DB.instances.push(inst);
  }
})();

/* macro state per instance */
var macroState = {};
DB.instances.forEach(function (i) {
  macroState[i.id] = MACROS.map(function (m) {
    return { name: m.name, label: m.label, on: rnd() > 0.35, hotkey: null };
  });
});

/* -------------------- bot config (CONFIGAPI.md) ------------------ */
/* One CFG[instanceId] = { healbot, conditions, attackbot, stances, targetbot, cavebot }
   holding the six kinds' `data` shapes verbatim (byte-for-byte what a real
   hub/botconfig.lua would read out of the profile). Built lazily per instance
   so the generated fleet does not need 200 hand-authored configs; i_1..i_5
   below get hand-authored, multi-row examples for the demo. */

var CFG = {};
var CFG_SOURCE = {};   // instanceId -> kind -> 'profile' | 'default'

var STANCES_CATALOG = [
  { id: 132, words: 'utamo tempo',     name: 'Protector',                needTarget: false },
  { id: 133, words: 'utito tempo',     name: 'Blood Rage',               needTarget: false },
  { id: 274, words: 'utori virtu',     name: 'Virtue of Harmony',        needTarget: false },
  { id: 275, words: 'utito virtu',     name: 'Virtue of Justice',        needTarget: false },
  { id: 276, words: 'utura tio',       name: 'Virtue of Sustain',        needTarget: false },
  { id: 304, words: 'uteta flam',      name: 'Master of Flames',         needTarget: false },
  { id: 305, words: 'uteta vis',       name: 'Master of Thunder',        needTarget: false },
  { id: 306, words: 'uteta mort',      name: 'Master of Decay',          needTarget: false },
  { id: 309, words: 'utura sio',       name: 'Shared Conservation',      needTarget: false },
  { id: 311, words: 'exori moe tempo', name: 'Aura of Sapped Strength',  needTarget: false },
  { id: 312, words: 'exori kor tempo', name: 'Aura of Exposed Weakness', needTarget: false },
  { id: 313, words: 'utori con',       name: 'Sharpshooter',             needTarget: true  },
  { id: 314, words: 'utori hur',       name: 'Divine Defiance',          needTarget: true  },
  { id: 319, words: 'utito dru',       name: 'Elemental Synthesis',      needTarget: false }
];

/* bot/configschema.lua's `healbot` kind is `top = 'object'` with EXACTLY
   {itemTable, spellTable} -- an extra top-level key (name/enabled/Visible/...,
   which live on the PROFILE, not this kind) is rejected by the real
   hub/botconfig.lua's getHealbot() projection. Mirror that narrow shape here
   so a panel built against this mock behaves identically against the real
   hub -- hub/api.lua and bot/configschema.lua are already built (work items
   N2/N3) and this mock is kept byte-shape-compatible with them. */
function blankHealbotData() { return { spellTable: [], itemTable: [] }; }
function defaultConditionPanel() {
  /* Real hub/botconfig.lua's getConditions() merges onto this same default,
     then STRIPS curePosion and guarantees curePoison -- never both. */
  return { enabled: false,
           curePoison: false,  poisonCost: 20,
           cureCurse: false,    curseCost: 80,
           cureBleed: false,    bleedCost: 45,
           cureBurn: false,     burnCost: 30,
           cureElectrify: false, electrifyCost: 22,
           cureParalyse: false, paralyseCost: 40, paralyseSpell: 'utani hur',
           holdHaste: false,    hasteCost: 40,    hasteSpell: 'utani hur',
           holdUtamo: false,    utamoCost: 40,
           holdUtana: false,    utanaCost: 440,
           holdUtura: false,    uturaType: '',    uturaCost: 100,
           ignoreInPz: true,    stopHaste: false };
}

function defaultCfgFor(kind) {
  if (kind === 'healbot')   return blankHealbotData();
  if (kind === 'conditions') return defaultConditionPanel();
  /* attackbot is `top = 'array'` -- the kind's data IS the bare attackTable. */
  if (kind === 'attackbot') return [];
  if (kind === 'stances')   return { enabled: false, ignoreInPz: true, entries: [] };
  if (kind === 'targetbot') return { targeting: [], looting: { items: [], containers: [],
                                     everyItem: false, maxDanger: 10, minCapacity: 100 } };
  if (kind === 'cavebot')   return [];
  throw E('bad-request', 'unknown config kind: ' + kind);
}

/* i_1 -- rich, hand-authored, multi-row example data for every kind */
CFG.i_1 = {
  /* {itemTable, spellTable} ONLY -- see blankHealbotData()'s comment. The
     profile-level flags (name/enabled/Visible/Cooldown/...) are not part of
     this kind's data and are never round-tripped through the panel. */
  healbot: {
    spellTable: [
      { index: 2, spell: 'exura gran tio', sign: '<', origin: 'HP%', value: 75, cost: 210, enabled: true },
      { index: 1, spell: 'exura gran',     sign: '<', origin: 'HP%', value: 95, cost: 75,  enabled: true }
    ],
    itemTable: [
      { index: 2, item: 23374, sign: '<', origin: 'HP%', value: 40, enabled: false },
      { index: 3, item: 23374, sign: '<', origin: 'HP%', value: 75, enabled: true },
      { index: 1, item: 23374, sign: '<', origin: 'MP%', value: 75, enabled: true }
    ]
  },
  conditions: (function () {
    var c = defaultConditionPanel();
    c.enabled = true; c.cureParalyse = true; c.paralyseCost = 200; c.paralyseSpell = 'utani gran hur';
    c.holdHaste = true; c.hasteCost = 200; c.hasteSpell = 'utani gran hur';
    return c;
  })(),
  /* bare attackTable array -- see defaultCfgFor('attackbot')'s comment. */
  attackbot: [
    { spell: 'exori mas res', itemId: 0, category: 5, patternCategory: 4, pattern: 19,
      count: 1, orMore: true, minHp: 0, maxHp: 100, mana: 10, cooldown: 1, harmony: 0,
      monsters: ['true frost flower asura'], augmented: false, enabled: true,
      description: '[Balanced Brawl] 1+ true frost flower asura' },
    { spell: 'exori gran mas nia', itemId: 0, category: 5, patternCategory: 4, pattern: 17,
      count: 5, orMore: true, minHp: 0, maxHp: 100, mana: 20, cooldown: 1, harmony: 5,
      monsters: true, augmented: false, enabled: true,
      description: '[Spiritual Outburst] 5+ any creature' },
    { spell: '', itemId: 3200, category: 2, patternCategory: 2, pattern: 3,
      count: 3, orMore: true, minHp: 0, maxHp: 100, mana: 0, cooldown: 2, harmony: 0,
      monsters: true, augmented: false, enabled: true, description: 'GFB rune, 3+' }
  ],
  stances: {
    enabled: true, ignoreInPz: true,
    entries: [
      { spell: 'utamo tempo', spellId: 132, stanceName: 'Protector', needTarget: false,
        monsters: true, minHp: 0, maxHp: 40, minMana: 0, count: 0, range: 5, orMore: true,
        enabled: true, description: 'Protector below 40% hp' },
      { spell: 'utito tempo', spellId: 133, stanceName: 'Blood Rage', needTarget: false,
        monsters: true, minHp: 41, maxHp: 100, minMana: 0, count: 4, range: 5, orMore: true,
        enabled: true, description: 'Blood Rage vs 4+ creatures' }
    ]
  },
  targetbot: {
    targeting: [
      { name: 'Dark Torturer', regex: '^dark torturer$', priority: 4, danger: 1, maxDistance: 8,
        chase: true, keepDistance: false, keepDistanceRange: 1, anchor: false, anchorRange: 3,
        avoidAttacks: false, faceMonster: false, rePosition: true, rePositionAmount: 7,
        lure: false, lureCount: 1, lureCavebot: false, dynamicLure: true, lureMin: 3, lureMax: 9,
        dynamicLureDelay: true, lureDelay: 655, delayFrom: 4, closeLure: true, closeLureAmount: 6,
        dontLoot: false, diamondArrows: true, rpSafe: false },
      { name: '*', regex: '^.*$', priority: 1, danger: 1, maxDistance: 10,
        chase: true, keepDistance: false, keepDistanceRange: 1, anchor: false, anchorRange: 3,
        avoidAttacks: false, faceMonster: false, rePosition: false, rePositionAmount: 5,
        lure: false, lureCount: 1, lureCavebot: false, dynamicLure: false, lureMin: 1, lureMax: 3,
        dynamicLureDelay: false, lureDelay: 250, delayFrom: 2, closeLure: false, closeLureAmount: 3,
        dontLoot: true, diamondArrows: false, rpSafe: false }
    ],
    looting: {
      items: [ { id: 16131, count: 0 }, { id: 9636, count: 0 } ],
      containers: [ { id: 23721, count: 0 } ],
      everyItem: false, maxDanger: 10, minCapacity: 100
    }
  },
  cavebot: [
    { type: 'goto', value: '32359,32226,7' },
    { type: 'label', value: 'hunt' },
    { type: 'use', value: '32321,32211,7' },
    { type: 'delay', value: '500' },
    { type: 'function', value: 'TargetBot.setOn()\n\nreturn true\n' },
    { type: 'supplycheck', value: 'hunt,32894,32356,9' },
    { type: 'gotolabel', value: 'hunt' }
  ]
};
Object.keys(CFG.i_1).forEach(function (k) { (CFG_SOURCE.i_1 = CFG_SOURCE.i_1 || {})[k] = 'profile'; });

function ensureCfg(instId, kind) {
  CFG[instId] = CFG[instId] || {};
  CFG_SOURCE[instId] = CFG_SOURCE[instId] || {};
  if (CFG[instId][kind] === undefined) {
    CFG[instId][kind] = defaultCfgFor(kind);
    CFG_SOURCE[instId][kind] = 'default';
  }
  return CFG[instId][kind];
}
var CFG_KINDS = { healbot: 1, conditions: 1, attackbot: 1, stances: 1, targetbot: 1, cavebot: 1 };

/* Security mirror of hub/api.lua's EXEC_CAPABILITY gate (CONFIGAPI.md "Security"):
   a cavebot PUT needs canExec ONLY when the diff adds or changes a function-type
   waypoint's BODY. Reordering, editing a goto/delay/... value, or removing a
   function waypoint needs only the normal owner-or-admin permission. */
function cavebotDiffNeedsExec(oldArr, newArr) {
  var oldFns = {};
  (oldArr || []).forEach(function (w) {
    if (w && String(w.type).toLowerCase() === 'function') oldFns[w.value] = (oldFns[w.value] || 0) + 1;
  });
  var flagged = false;
  (newArr || []).forEach(function (w) {
    if (w && String(w.type).toLowerCase() === 'function') {
      if (oldFns[w.value] > 0) oldFns[w.value]--; else flagged = true;
    }
  });
  return flagged;
}

/* rolling logs / chat / history */
var LOGS = {}, CHAT = {}, HIST = {};
DB.instances.forEach(function (i) { LOGS[i.id] = []; CHAT[i.id] = []; HIST[i.id] = []; });

/* -------------------- debug snapshot (R3) ------------------------- */
/* Per-instance tick/network/bot/path health plus a structured event ring
   buffer. Mirrors panel/api.js's `instances.debug` comment -- ASSUMED
   shape pending R2 (the hub side, built concurrently); see the R3 work
   item report's crossFileRequests if this needs reconciling. */

var TICK_CONFIGURED_MS = 50;
var TICK_SLOW_MS = 180;
var STALE_THRESHOLD_MS = 8000;
var STUCK_THRESHOLD_MS = 12000;
var DEBUG_EVENT_CAP = 300;
var TICK_RING_CAP = 60;

var DEBUG = {};        // instanceId -> mutable debug state
var macroDebug = {};   // instanceId -> macroName -> {lastRanAt,lastDurationMs,errorCount,lastError}

function blankDebug() {
  return {
    tick: { durations: [], slowCount: 0 },
    network: { pingMs: null, packetsIn: 0, packetsOut: 0, lastError: null, lastPacketAt: now() },
    bot: {
      cavebot: { stuckSince: null },
      targetbot: { candidate: null, target: null, lootingState: 'idle' },
      healbot: { lastAction: null, lastActionAt: null },
      attackbot: { lastAction: null, lastActionAt: null },
      stances: { lastAction: null, lastActionAt: null }
    },
    path: { lastComputedAt: now(), lengthTiles: null, blocked: false },
    events: []
  };
}
function pushDebugEvent(inst, kind, detail, tMs) {
  var d = DEBUG[inst.id]; if (!d) return;
  d.events.push({ tMs: tMs || now(), kind: kind, detail: detail || '' });
  if (d.events.length > DEBUG_EVENT_CAP) d.events.shift();
}
function avgOf(arr) {
  if (!arr || !arr.length) return null;
  var s = 0;
  for (var i = 0; i < arr.length; i++) s += arr[i];
  return s / arr.length;
}
function snapshotFor(i) {
  var d = DEBUG[i.id] || (DEBUG[i.id] = blankDebug());
  var L = i.live;
  var macros = (macroState[i.id] || []).map(function (m) {
    var md = (macroDebug[i.id] || {})[m.name] || {};
    return { name: m.name, label: m.label, on: m.on,
             lastRanAt: md.lastRanAt || null,
             lastDurationMs: md.lastDurationMs !== undefined ? md.lastDurationMs : null,
             errorCount: md.errorCount || 0, lastError: md.lastError || null };
  });
  var connected = i.state === 'online';
  var lastPacketAgeMs = d.network.lastPacketAt != null ? now() - d.network.lastPacketAt : null;
  return {
    id: i.id,
    generatedAt: now(),
    tick: {
      configuredMs: TICK_CONFIGURED_MS,
      lastMs: d.tick.durations.length ? d.tick.durations[d.tick.durations.length - 1] : null,
      avgMs: avgOf(d.tick.durations),
      durationsMs: d.tick.durations.slice(),
      slowThresholdMs: TICK_SLOW_MS,
      slowCount: d.tick.slowCount,
      macros: macros
    },
    network: {
      connected: connected,
      pingMs: connected ? d.network.pingMs : null,
      packetsIn: d.network.packetsIn,
      packetsOut: d.network.packetsOut,
      reconnects: L.reconnects || 0,
      lastError: d.network.lastError,
      lastPacketAt: d.network.lastPacketAt,
      lastPacketAgeMs: lastPacketAgeMs,
      staleThresholdMs: STALE_THRESHOLD_MS
    },
    bot: {
      cavebot: { enabled: i.botEnabled, waypointIndex: L.waypointIndex, waypointCount: L.waypointCount,
                 waypointLabel: L.waypoint, stuckSince: d.bot.cavebot.stuckSince,
                 stuckThresholdMs: STUCK_THRESHOLD_MS },
      targetbot: { enabled: i.botEnabled, candidate: d.bot.targetbot.candidate,
                   target: d.bot.targetbot.target, lootingState: d.bot.targetbot.lootingState },
      healbot: { enabled: i.botEnabled, lastAction: d.bot.healbot.lastAction,
                 lastActionAt: d.bot.healbot.lastActionAt },
      attackbot: { enabled: i.botEnabled, lastAction: d.bot.attackbot.lastAction,
                   lastActionAt: d.bot.attackbot.lastActionAt },
      stances: { enabled: i.botEnabled, lastAction: d.bot.stances.lastAction,
                 lastActionAt: d.bot.stances.lastActionAt }
    },
    path: { lastComputedAt: d.path.lastComputedAt, lengthTiles: d.path.lengthTiles,
            blocked: d.path.blocked, sourcePos: L.pos, targetPos: null },
    events: d.events.slice(-200)
  };
}

DB.instances.forEach(function (i) { DEBUG[i.id] = blankDebug(); macroDebug[i.id] = {}; });

/* seed enough backlog that the Debug tab is not empty on first open, and --
   on the demo instance -- reproduce exactly the scenario this work item's
   own spec names as an example ("3 resyncs, 1 macro error") so the event
   log's count-by-kind summary is not a coincidence. */
(function seedDebug() {
  DB.instances.forEach(function (i) {
    var d = DEBUG[i.id];
    for (var k = 0; k < TICK_RING_CAP; k++) {
      var v = Math.round(TICK_CONFIGURED_MS * (0.7 + rnd() * 0.6));
      if (rnd() < 0.04) { v = TICK_CONFIGURED_MS + ri(TICK_SLOW_MS, TICK_SLOW_MS * 2); d.tick.slowCount++; }
      d.tick.durations.push(v);
    }
    d.network.pingMs = ri(30, 140);
    d.network.packetsIn = ri(2000, 40000);
    d.network.packetsOut = Math.round(d.network.packetsIn * 0.4);
    var online = i.state === 'online';
    d.bot.targetbot.candidate = online ? pick(MONSTERS) : null;
    d.bot.targetbot.target = i.live.target;
    d.bot.targetbot.lootingState = online ? pick(['idle', 'looking', 'opening', 'looting']) : 'idle';
    d.bot.healbot.lastAction = online ? 'exura vita' : null;
    d.bot.healbot.lastActionAt = online ? now() - ri(500, 30000) : null;
    d.bot.attackbot.lastAction = online ? 'exori mas res' : null;
    d.bot.attackbot.lastActionAt = online ? now() - ri(500, 30000) : null;
    d.bot.stances.lastAction = online ? pick(STANCES_CATALOG).words : null;
    d.bot.stances.lastActionAt = online ? now() - ri(2000, 60000) : null;
    d.path.lengthTiles = online ? ri(3, 40) : null;
    d.path.lastComputedAt = now() - ri(200, 4000);
    for (var e = 6; e >= 1; e--) pushDebugEvent(i, 'info', 'cavebot: waypoint advanced', now() - e * 40000);
  });

  var demo = DB.instances[0];
  if (demo) {
    pushDebugEvent(demo, 'reconnect', 'proxy ' + (demo.proxyLabel || 'direct') +
      ': connection reset, reconnecting', now() - 620000);
    pushDebugEvent(demo, 'resync', 'worker resync after reconnect (attempt 1)', now() - 610000);
    pushDebugEvent(demo, 'resync', 'worker resync after reconnect (attempt 2)', now() - 480000);
    pushDebugEvent(demo, 'resync', 'container/creature state resynced after a missed packet', now() - 195000);
    pushDebugEvent(demo, 'macro_error',
      "equip_manager:14: attempt to index a nil value (field 'slot')", now() - 90000);
    macroDebug[demo.id].equip_manager = {
      lastRanAt: now() - 90000, lastDurationMs: 4, errorCount: 3,
      lastError: "equip_manager:14: attempt to index a nil value (field 'slot')"
    };
    (macroState[demo.id] || []).forEach(function (m) { if (m.name === 'equip_manager') m.on = false; });
  }
})();

/* seed 60 minutes of history and a bit of log/chat backlog */
(function seedHistory() {
  DB.instances.forEach(function (i) {
    if (i.state === 'stopped') return;
    var exph = i.live.expPerHour, mph = i.live.moneyPerHour, kph = i.live.killsPerHour;
    for (var k = 120; k >= 0; k--) {
      exph = clamp(exph * (0.97 + rnd() * 0.06), 50000, 2500000);
      mph = clamp(mph * (0.96 + rnd() * 0.08), 5000, 600000);
      kph = clamp(kph * (0.96 + rnd() * 0.08), 10, 400);
      HIST[i.id].push({
        t: T0 - k * 30000,
        expPerHour: Math.round(exph),
        moneyPerHour: Math.round(mph),
        killsPerHour: Math.round(kph * 10) / 10,
        level: i.live.level,
        hpPercent: clamp(45 + rnd() * 55, 5, 100),
        manaPercent: clamp(35 + rnd() * 65, 5, 100)
      });
    }
    for (var l = 0; l < 25; l++) LOGS[i.id].push(mkLogLine(i, T0 - (25 - l) * 12000));
    for (var c = 0; c < 8; c++) CHAT[i.id].push(mkChatLine(i, T0 - (8 - c) * 45000));
  });
})();

function mkLogLine(inst, t) {
  var kinds = [
    ['debug', function () { return 'walker: step ' + pick(['n', 's', 'e', 'w', 'ne', 'sw']) + ' to ' +
        (32800 + ri(-9, 9)) + ',' + (31900 + ri(-9, 9)) + ',' + inst.live.pos.z; }],
    ['info',  function () { return 'cavebot: waypoint ' + ri(1, inst.live.waypointCount) + '/' +
        inst.live.waypointCount + ' (' + pick(['goto', 'label', 'use', 'door', 'stand', 'lure']) + ')'; }],
    ['info',  function () { return 'targetbot: attacking ' + pick(MONSTERS) + ' (' + ri(20, 100) + '%)'; }],
    ['info',  function () { return 'loot: ' + pick(['gold coin x' + ri(20, 100), 'platinum coin x' + ri(1, 9),
        'demonic essence', 'small ruby', 'giant sword', 'assassin star x' + ri(3, 25)]); }],
    ['debug', function () { return 'healbot: exura vita (' + ri(30, 70) + '% hp)'; }],
    ['warn',  function () { return pick(['supplies low: mana potion ' + ri(10, 55),
        'path blocked, retrying', 'stuck for ' + ri(3, 9) + 's, forcing reposition']); }],
    ['error', function () { return pick(['proxy read timeout, reconnecting',
        'server closed connection (code 1006)']); }]
  ];
  var w = rnd();
  var idx = w < 0.30 ? 0 : w < 0.55 ? 1 : w < 0.75 ? 2 : w < 0.86 ? 3 : w < 0.95 ? 4 : w < 0.99 ? 5 : 6;
  return { id: inst.id, t: t, level: kinds[idx][0], text: kinds[idx][1]() };
}

function mkChatLine(inst, t) {
  var kinds = [
    function () { return { channel: 'Local', from: pick(CHATTERS), text: pick([
      'anyone selling a stone skin amulet?', 'nice hunt spot', 'lol', 'team for hydras?',
      'wts crystal coins 1:1', 'is the respawn free?']) }; },
    function () { return { channel: 'Server', from: 'Server', text: 'You advanced to level ' +
      (inst.live.level + 1) + '.' }; },
    function () { return { channel: 'Loot', from: 'Loot', text: 'Loot of a ' + pick(MONSTERS).toLowerCase() +
      ': ' + ri(20, 180) + ' gold coins, ' + pick(['a bone', 'nothing else', 'a small emerald']) }; },
    function () { return { channel: 'Default', from: inst.characterName, text: 'exura vita' }; }
  ];
  var m = pick(kinds)();
  m.id = inst.id; m.t = t;
  return m;
}

/* ------------------------- the audit log ------------------------ */

var AUDIT_ACTIONS = ['login.ok', 'login.fail', 'logout', 'user.create', 'user.delete', 'user.password',
  'account.create', 'account.delete', 'character.create', 'character.delete',
  'instance.create', 'instance.start', 'instance.stop', 'instance.delete', 'instance.config',
  'script.upload', 'script.assign', 'script.delete', 'exec', 'proxy.create', 'proxy.change',
  'session.revoke'];

(function seedAudit() {
  for (var i = 0; i < 160; i++) {
    var act = pick(AUDIT_ACTIONS);
    var who = pick(['arnold', 'arnold', 'sam', 'system']);
    DB.audit.push({
      t: T0 - Math.floor(rnd() * 86400000 * 14),
      actor: who,
      ip: who === 'system' ? '-' : pick(['127.0.0.1', '192.168.7.40', '10.0.0.8']),
      action: act,
      target: pick(['Arnoldus', 'Ballista', 'Mudflower', 'sam', 'refill_supplies.lua', 'de-frankfurt', 'main-eu']),
      outcome: act === 'login.fail' ? 'denied' : (rnd() > 0.94 ? 'error' : 'ok'),
      detail: act === 'exec' ? 'code: return player:getLevel()' : ''
    });
  }
  DB.audit.sort(function (a, b) { return b.t - a.t; });
})();

function audit(action, target, outcome, detail) {
  var rec = {
    t: now(),
    actor: session ? session.name : 'anonymous',
    ip: '127.0.0.1',
    action: action,
    target: target || '',
    outcome: outcome || 'ok',
    detail: detail || ''
  };
  DB.audit.unshift(rec);
  if (DB.audit.length > 4000) DB.audit.length = 4000;
  emit('audit', rec, true);
  return rec;
}

/* --------------------------- session ---------------------------- */

var session = null;      // {id, name, role} of the signed-in mock user
var csrf = '';           // handed out by GET /api/session, required on writes

function newCsrf() { csrf = 'mock-csrf-' + Math.floor(rnd() * 0xffffffff).toString(16); return csrf; }
newCsrf();

function userByName(n) {
  return DB.users.filter(function (u) { return u.name.toLowerCase() === String(n).toLowerCase(); })[0];
}
function userById(id) { return DB.users.filter(function (u) { return u.id === id; })[0]; }
function nameOf(id) { var u = userById(id); return u ? u.name : '?'; }

/* --------------------------- events ----------------------------- */

var sockets = [];        // live FakeWebSocket objects
var timer = null, ticks = 0;

function emit(ev, data, adminOnly) {
  for (var i = 0; i < sockets.length; i++) {
    var s = sockets[i];
    if (!s._ready) continue;
    if (adminOnly && (!session || session.role !== 'admin')) continue;
    s._push(ev, data);
  }
}
function emitTo(streamKey, instId, ev, data) {
  for (var i = 0; i < sockets.length; i++) {
    var s = sockets[i];
    if (s._ready && s._subs[streamKey] === instId) s._push(ev, data);
  }
}

function visible(inst) {
  if (!session) return false;
  return session.role === 'admin' || inst.ownerUserId === session.id;
}

function tick() {
  ticks++;
  DB.instances.forEach(function (i) {
    var L = i.live;

    /* state machine: starting -> online, stopping -> stopped */
    if (i.state === 'starting' && ticks % 3 === 0) {
      i.state = 'connecting';
    } else if (i.state === 'connecting' && ticks % 3 === 0) {
      i.state = 'online'; L.uptimeMs = 0; L.onlineMs = 0;
      emit('gameStart', { id: i.id, t: now() });
      pushLog(i, 'info', 'game start: ' + i.characterName + ' entered ' + i.world);
    } else if (i.state === 'stopping' && ticks % 2 === 0) {
      i.state = 'stopped'; i.botEnabled = false;
      emit('gameEnd', { id: i.id, reason: 'operator stop' });
    }

    if (i.state === 'stopped') { emitStatus(i); return; }

    L.uptimeMs += 1000;
    if (i.state === 'online') L.onlineMs += 1000;

    /* vitals wander */
    if (i.state === 'online' && i.botEnabled) {
      L.hp = clamp(Math.round(L.hp + (rnd() - 0.42) * L.maxHp * 0.06), Math.round(L.maxHp * 0.08), L.maxHp);
      L.mana = clamp(Math.round(L.mana + (rnd() - 0.45) * L.maxMana * 0.09), 0, L.maxMana);
      L.expPercent = (L.expPercent + rnd() * 0.35) % 100;
      L.exp += Math.round(L.expPerHour / 3600);
      L.cap = clamp(L.cap + ri(-8, 6), 0, L.maxCap);

      if (rnd() < 0.30) L.target = pick(MONSTERS);
      else if (rnd() < 0.12) L.target = null;

      if (rnd() < 0.18) {
        L.waypointIndex = (L.waypointIndex % L.waypointCount) + 1;
        L.waypoint = pick(['goto', 'label:start', 'lure', 'stand', 'use rope', 'door', 'depot']) +
                     ' #' + L.waypointIndex;
      }
      L.pos = { x: clamp(L.pos.x + ri(-1, 1), 32000, 33500),
                y: clamp(L.pos.y + ri(-1, 1), 31000, 32500), z: L.pos.z };

      (L.supplies || []).forEach(function (s) { if (rnd() < 0.10 && s.count > 0) s.count--; });

      if (rnd() < 0.0025) {                      /* rare death */
        L.deaths++; L.hp = 1;
        emit('death', { id: i.id, level: L.level, t: now() });
        pushLog(i, 'error', 'you are dead. relogging in 10s');
      }
      if (rnd() < 0.004) {                       /* level up */
        L.level++; L.expPercent = 0;
        L.maxHp += 15; L.maxMana += 10;
        pushLog(i, 'info', 'advanced to level ' + L.level);
      }
    } else if (i.state === 'online') {
      L.mana = clamp(L.mana + Math.round(L.maxMana * 0.02), 0, L.maxMana);
      L.hp = clamp(L.hp + Math.round(L.maxHp * 0.01), 0, L.maxHp);
      L.target = null;
    }

    emitStatus(i);

    /* rates + history every 5 s */
    if (ticks % 5 === 0 && i.state === 'online') {
      L.expPerHour = Math.round(clamp(L.expPerHour * (0.985 + rnd() * 0.032), 60000, 2600000));
      L.moneyPerHour = Math.round(clamp(L.moneyPerHour * (0.98 + rnd() * 0.045), 4000, 700000));
      L.killsPerHour = Math.round(clamp(L.killsPerHour * (0.98 + rnd() * 0.045), 8, 420) * 10) / 10;
      L.lootPerHour = Math.round(L.moneyPerHour * (1.25 + rnd() * 0.5));
      L.wastePerHour = Math.round(L.lootPerHour * (0.35 + rnd() * 0.45));
      L.balancePerHour = L.lootPerHour - L.wastePerHour;

      var st = {
        id: i.id, t: now(),
        expPerHour: L.expPerHour, moneyPerHour: L.moneyPerHour, killsPerHour: L.killsPerHour,
        lootPerHour: L.lootPerHour, wastePerHour: L.wastePerHour, balancePerHour: L.balancePerHour,
        deaths: L.deaths, level: L.level, exp: L.exp, supplies: L.supplies,
        reconnects: L.reconnects
      };
      if (visible(i)) emit('stats', st);

      HIST[i.id].push({
        t: st.t, expPerHour: L.expPerHour, moneyPerHour: L.moneyPerHour,
        killsPerHour: L.killsPerHour, level: L.level,
        hpPercent: (L.hp / L.maxHp) * 100, manaPercent: (L.mana / L.maxMana) * 100
      });
      if (HIST[i.id].length > 400) HIST[i.id].shift();
    }

    /* chatter */
    if (i.state === 'online' && rnd() < 0.22) pushLog(i, null, null);
    if (i.state === 'online' && rnd() < 0.07) {
      var m = mkChatLine(i, now());
      CHAT[i.id].push(m);
      if (CHAT[i.id].length > 500) CHAT[i.id].shift();
      if (visible(i)) emitTo('chat', i.id, 'chat', m);
    }

    /* the broken one flaps */
    if (i.state === 'error' && rnd() < 0.05) {
      L.reconnects++;
      pushLog(i, 'error', 'proxy ' + (i.proxyLabel || 'direct') + ': connect failed (ETIMEDOUT), retry #' + L.reconnects);
      if (visible(i)) emit('error', { id: i.id, message: 'proxy connect failed (ETIMEDOUT)' });
    }

    /* ---- debug snapshot (R3): tick/network/bot/path/events ---- */
    var d = DEBUG[i.id];
    if (d) {
      var v = Math.round(TICK_CONFIGURED_MS * (0.75 + rnd() * 0.5));
      if (i.state === 'online' && rnd() < 0.03) v = TICK_CONFIGURED_MS + ri(TICK_SLOW_MS, TICK_SLOW_MS * 2);
      d.tick.durations.push(v);
      if (d.tick.durations.length > TICK_RING_CAP) d.tick.durations.shift();
      if (v > TICK_SLOW_MS) {
        d.tick.slowCount++;
        pushDebugEvent(i, 'slow_tick', 'tick took ' + v + ' ms (> ' + TICK_SLOW_MS + ' ms threshold)');
      }

      if (i.state === 'online' && rnd() < 0.25) {
        var on = (macroState[i.id] || []).filter(function (m) { return m.on; });
        if (on.length) {
          var mm = pick(on);
          var stats = macroDebug[i.id] || (macroDebug[i.id] = {});
          var ms2 = stats[mm.name] || (stats[mm.name] = { errorCount: 0 });
          ms2.lastRanAt = now();
          ms2.lastDurationMs = ri(1, 12);
          if (rnd() < 0.015) {
            ms2.errorCount = (ms2.errorCount || 0) + 1;
            ms2.lastError = mm.name + ': ' + pick([
              'attempt to call a nil value (method \'process\')',
              "attempt to index a nil value (field 'slot')", 'stack overflow']);
            pushDebugEvent(i, 'macro_error', ms2.lastError);
          }
        }
      }

      d.network.pingMs = clamp(Math.round((d.network.pingMs || 60) + ri(-8, 8)), 15, 400);
      d.network.packetsIn += ri(3, 30);
      d.network.packetsOut += ri(1, 10);
      if (i.state === 'online') d.network.lastPacketAt = now();
      /* an 'error' instance's packets deliberately stop refreshing here, so its
         Debug tab demonstrates the stale/disconnected warning without a click. */
      if (i.state === 'error' && rnd() < 0.15) d.network.lastError = 'read timeout (ETIMEDOUT)';
      if (i.state === 'online' && rnd() < 0.01) pushDebugEvent(i, 'reconnect', 'connection reset, reconnecting');
      if (i.state === 'online' && rnd() < 0.012) pushDebugEvent(i, 'resync', 'worker resync after reconnect');

      if (i.state === 'online' && i.botEnabled) {
        if (!d.bot.cavebot.stuckSince && rnd() < 0.01) {
          d.bot.cavebot.stuckSince = now();
          pushDebugEvent(i, 'stuck', 'cavebot has not advanced its waypoint');
        } else if (d.bot.cavebot.stuckSince && rnd() < 0.15) {
          d.bot.cavebot.stuckSince = null;
        }
        d.bot.targetbot.candidate = L.target || (rnd() < 0.2 ? pick(MONSTERS) : d.bot.targetbot.candidate);
        d.bot.targetbot.target = L.target;
        if (rnd() < 0.1) d.bot.targetbot.lootingState = pick(['idle', 'looking', 'opening', 'looting']);
        if (rnd() < 0.08) { d.bot.healbot.lastAction = pick(['exura vita', 'exura gran', 'mana potion']); d.bot.healbot.lastActionAt = now(); }
        if (rnd() < 0.08 && L.target) { d.bot.attackbot.lastAction = pick(['exori mas res', 'exori gran mas nia', 'GFB rune']); d.bot.attackbot.lastActionAt = now(); }
        if (rnd() < 0.04) { d.bot.stances.lastAction = pick(STANCES_CATALOG).words; d.bot.stances.lastActionAt = now(); }
        d.path.lengthTiles = L.target ? ri(1, 10) : ri(2, 40);
        d.path.blocked = rnd() < 0.03;
        if (d.path.blocked) pushDebugEvent(i, 'path_blocked', 'no walkable tile toward the next waypoint');
        d.path.lastComputedAt = now();
      }

      if (visible(i)) emitTo('debug', i.id, 'debug', snapshotFor(i));
    }
  });
}

function emitStatus(i) {
  if (!visible(i)) return;
  var L = i.live;
  emit('status', {
    id: i.id, state: i.state, botEnabled: i.botEnabled,
    hp: L.hp, maxHp: L.maxHp, mana: L.mana, maxMana: L.maxMana,
    level: L.level, expPercent: L.expPercent,
    target: L.target, waypoint: L.waypoint,
    waypointIndex: L.waypointIndex, waypointCount: L.waypointCount,
    uptimeMs: L.uptimeMs, onlineMs: L.onlineMs, pos: L.pos,
    cap: L.cap, maxCap: L.maxCap, soul: L.soul, stamina: L.stamina
  });
}

function pushLog(inst, level, text) {
  var line = (level && text) ? { id: inst.id, t: now(), level: level, text: text }
                             : mkLogLine(inst, now());
  LOGS[inst.id].push(line);
  if (LOGS[inst.id].length > 800) LOGS[inst.id].shift();
  if (visible(inst)) emitTo('logs', inst.id, 'log', line);
}

/* -------------------------- projections ------------------------- */

function pubInstance(i) {
  return {
    id: i.id, characterId: i.characterId, characterName: i.characterName,
    accountLabel: i.accountLabel, world: i.world, vocation: i.vocation,
    ownerUserId: i.ownerUserId, ownerName: nameOf(i.ownerUserId),
    proxyId: i.proxyId, proxyLabel: i.proxyLabel,
    botProfile: i.botProfile, cavebotConfig: i.cavebotConfig, targetbotConfig: i.targetbotConfig,
    scripts: i.scripts.slice(), autoStart: i.autoStart, autoRelogin: i.autoRelogin,
    state: i.state, botEnabled: i.botEnabled,
    live: JSON.parse(JSON.stringify(i.live))
  };
}
function myInstances() { return DB.instances.filter(visible); }
function findInstance(id) {
  var i = DB.instances.filter(function (x) { return x.id === id; })[0];
  if (!i) throw E('not-found', 'no such instance: ' + id);
  if (!visible(i)) throw E('forbidden', 'not your instance');
  return i;
}

function pubScript(s) {
  return { id: s.id, name: s.name, size: s.size, sha256: s.sha256,
           ownerUserId: s.ownerUserId, ownerName: nameOf(s.ownerUserId),
           createdAt: s.createdAt, instanceIds: s.instanceIds.slice() };
}
function pubAccount(a) {
  return { id: a.id, label: a.label, login: a.login, ownerUserId: a.ownerUserId,
           ownerName: nameOf(a.ownerUserId), has2fa: !!a.has2fa,
           characterCount: DB.characters.filter(function (c) { return c.accountId === a.id; }).length };
}
function pubCharacter(c) {
  var a = DB.accounts.filter(function (x) { return x.id === c.accountId; })[0];
  var inst = DB.instances.filter(function (i) { return i.characterId === c.id; })[0];
  return { id: c.id, accountId: c.accountId, accountLabel: a ? a.label : '?', name: c.name,
           world: c.world, vocation: c.vocation, lastLevel: c.lastLevel,
           instanceId: inst ? inst.id : null };
}
function pubProxy(p) {
  // The pool is shared to USE; only the owner or an admin may change an entry.
  var mine = session && (session.role === 'admin' || p.ownerUserId === session.id);
  var owner = DB.users.filter(function (u) { return u.id === p.ownerUserId; })[0];
  return { id: p.id, label: p.label, kind: p.kind, host: p.host, port: p.port,
           user: p.user, hasPass: !!p.hasPass,
           ownerUserId: p.ownerUserId, ownerName: owner ? owner.name : null,
           canEdit: !!mine,
           inUse: DB.instances.filter(function (i) { return i.proxyId === p.id; }).length };
}
function pubUser(u) {
  // Remote Lua is admin-equivalent: an admin always has it, a user only when granted.
  return { id: u.id, name: u.name, role: u.role, createdAt: u.createdAt,
           disabled: !!u.disabled, canExec: u.role === 'admin' || !!u.canExec,
           lastLoginAt: u.lastLoginAt };
}
function proxyOwnedOrAdmin(p) {
  need(session && (session.role === 'admin' || p.ownerUserId === session.id),
       'not-found', 'no such proxy');
}

/* --------------------------- errors ----------------------------- */

var STATUS = { 'bad-request': 400, 'unauthorized': 401, 'forbidden': 403, 'csrf-invalid': 403,
               'not-found': 404, 'conflict': 409, 'too-large': 413, 'rate-limited': 429,
               'internal': 500 };

function E(code, message) { var e = new Error(message); e.code = code; return e; }
function need(cond, code, msg) { if (!cond) throw E(code, msg); }
function needAuth() { need(session, 'unauthorized', 'not signed in'); }
function needAdmin() { needAuth(); need(session.role === 'admin', 'forbidden', 'administrators only'); }
/* Remote Lua is admin-equivalent -- the code runs unsandboxed under the hub's own
   user account -- so it is administrator-only unless the account was granted the
   canExec capability.  Mirrors hub/api.lua's EXEC_CAPABILITY gate. */
function needExec() {
  needAuth();
  var u = DB.users.filter(function (x) { return x.id === session.id; })[0];
  need(session.role === 'admin' || (u && u.canExec), 'forbidden',
       'running Lua on a worker is administrator-only; an administrator can grant ' +
       'this account the canExec capability');
}

/* Mirrors bot/configschema.lua's per-kind top-level shape (work item N2):
   healbot/conditions/stances/targetbot are `top = 'object'`, STRICT about
   their own top-level keys (an extra one is rejected, not tolerated);
   attackbot is `top = 'array'` -- its `data` IS the bare attackTable. */
var CFG_TOP_KEYS = {
  healbot:    { itemTable: 1, spellTable: 1 },
  conditions: { enabled: 1, curePoison: 1, curePosion: 1, poisonCost: 1, cureCurse: 1, curseCost: 1,
    cureBleed: 1, bleedCost: 1, cureBurn: 1, burnCost: 1, cureElectrify: 1, electrifyCost: 1,
    cureParalyse: 1, paralyseCost: 1, paralyseSpell: 1, holdHaste: 1, hasteCost: 1, hasteSpell: 1,
    holdUtamo: 1, utamoCost: 1, holdUtana: 1, utanaCost: 1, holdUtura: 1, uturaType: 1, uturaCost: 1,
    ignoreInPz: 1, stopHaste: 1 },
  stances:    { enabled: 1, ignoreInPz: 1, entries: 1 },
  targetbot:  { targeting: 1, looting: 1 }
};

/* ---------------------- the route handlers ---------------------- */
/* Keys are '<METHOD> <path template>' and match api.js's ENDPOINTS
   one for one; a handler gets ({params, query, body}).             */

var ROUTES = {

/* ---- session ---- */

'GET /api/session': function () {
  return { user: session ? { id: session.id, name: session.name, role: session.role,
                             canExec: !!session.canExec } : null,
           serverTime: now(), version: 'mock-2.0', bootstrap: false,
           insecure: (typeof location !== 'undefined' && location.protocol !== 'https:'),
           csrfToken: csrf };
},

'POST /api/session': function (c) {
  var a = c.body;
  var u = userByName(a.name);
  // the mock accepts any non-trivial password; it never stores or echoes it
  if (!u || !a.password || String(a.password).length < 3) {
    audit('login.fail', String(a.name || ''), 'denied', '');
    throw E('unauthorized', 'wrong name or password');
  }
  need(!u.disabled, 'forbidden', 'this account is disabled');
  session = { id: u.id, name: u.name, role: u.role,
              canExec: u.role === 'admin' || !!u.canExec };
  u.lastLoginAt = now();
  DB.sessions[0].userId = u.id;
  DB.sessions[0].createdAt = now();
  audit('login.ok', u.name, 'ok', '');
  return { user: { id: u.id, name: u.name, role: u.role, canExec: !!session.canExec },
           csrfToken: newCsrf() };
},

'DELETE /api/session': function () {
  if (session) audit('logout', session.name, 'ok', '');
  session = null;
  closeAllSockets(4401);
  return {};
},

'POST /api/session/password': function (c) {
  needAuth();
  var a = c.body;
  need(a.current && a.next, 'bad-request', 'both passwords are required');
  need(String(a.next).length >= 10, 'bad-request', 'the new password is too short');
  audit('user.password', session.name, 'ok', 'self-service change');
  return {};
},

'POST /api/bootstrap': function (c) {
  var a = c.body;
  need(a.token && String(a.token).length >= 8, 'bad-request', 'bootstrap token looks wrong');
  need(a.name && a.password, 'bad-request', 'name and password are required');
  var u = { id: uid('u'), name: a.name, role: 'admin', createdAt: now(), disabled: false, lastLoginAt: now() };
  DB.users.push(u);
  session = { id: u.id, name: u.name, role: 'admin', canExec: true };
  audit('user.create', u.name, 'ok', 'bootstrap administrator');
  return { user: { id: u.id, name: u.name, role: u.role, canExec: !!session.canExec },
           csrfToken: newCsrf() };
},

/* ---- instances ---- */

'GET /api/instances': function () {
  needAuth();
  return { instances: myInstances().map(pubInstance) };
},

'GET /api/instances/:id': function (c) { needAuth(); return { instance: pubInstance(findInstance(c.params.id)) }; },

'POST /api/instances': function (c) {
  needAuth();
  var a = c.body;
  var ch = DB.characters.filter(function (x) { return x.id === a.characterId; })[0];
  need(ch, 'not-found', 'no such character');
  need(!DB.instances.filter(function (i) { return i.characterId === ch.id; })[0],
       'conflict', 'that character already has an instance');
  var inst = mkInstance(uid('i'), ch.id, a.proxyId || null, 'stopped', ch.lastLevel || 8,
                        CAVEBOTS[0], TARGETBOT[0], session.id);
  inst.botProfile = a.botProfile || 'profile_1';
  inst.autoStart = !!a.autoStart;
  inst.autoRelogin = a.autoRelogin !== false;
  DB.instances.push(inst);
  LOGS[inst.id] = []; CHAT[inst.id] = []; HIST[inst.id] = [];
  DEBUG[inst.id] = blankDebug(); macroDebug[inst.id] = {};
  macroState[inst.id] = MACROS.map(function (m) { return { name: m.name, label: m.label, on: false }; });
  audit('instance.create', ch.name, 'ok', '');
  emit('instance', { id: inst.id, instance: pubInstance(inst) });
  return { instance: pubInstance(inst) };
},

'PATCH /api/instances/:id': function (c) {
  needAuth();
  var i = findInstance(c.params.id), p = c.body || {};
  ['proxyId', 'botProfile', 'cavebotConfig', 'targetbotConfig', 'autoStart', 'autoRelogin'].forEach(function (k) {
    if (p[k] !== undefined) i[k] = p[k];
  });
  if (p.proxyId !== undefined) {
    var px = DB.proxies.filter(function (x) { return x.id === p.proxyId; })[0];
    i.proxyLabel = px ? px.label : null;
  }
  if (p.scripts !== undefined) {
    i.scripts = p.scripts.slice();
    DB.scripts.forEach(function (s) {
      var has = i.scripts.indexOf(s.id) >= 0, at = s.instanceIds.indexOf(i.id);
      if (has && at < 0) s.instanceIds.push(i.id);
      if (!has && at >= 0) s.instanceIds.splice(at, 1);
    });
  }
  audit('instance.config', i.characterName, 'ok', Object.keys(p).join(','));
  emit('instance', { id: i.id, instance: pubInstance(i) });
  return { instance: pubInstance(i) };
},

'DELETE /api/instances/:id': function (c) {
  needAuth();
  var i = findInstance(c.params.id);
  DB.instances = DB.instances.filter(function (x) { return x.id !== i.id; });
  audit('instance.delete', i.characterName, 'ok', '');
  emit('instance', { id: i.id, removed: true });
  return {};
},

'POST /api/instances/actions': function (c) {
  needAuth();
  var a = c.body || {};
  var action = a.action;
  need(['start', 'stop', 'restart', 'botEnable'].indexOf(action) >= 0, 'bad-request',
       'unknown action: ' + action);
  need(a.ids && a.ids.length !== undefined, 'bad-request', 'ids must be a list');
  return { results: a.ids.map(function (id) {
    try {
      var i = findInstance(id);
      if (action === 'start') {
        if (i.state === 'online' || i.state === 'starting' || i.state === 'connecting')
          return { id: id, ok: false, error: 'already running' };
        i.state = 'starting'; i.live.uptimeMs = 0;
        pushLog(i, 'info', 'supervisor: spawning worker for ' + i.characterName +
          ' via ' + (i.proxyLabel || 'direct connection'));
        audit('instance.start', i.characterName, 'ok', '');
      } else if (action === 'stop') {
        if (i.state === 'stopped') return { id: id, ok: false, error: 'already stopped' };
        i.state = 'stopping';
        pushLog(i, 'info', 'supervisor: sending shutdown');
        audit('instance.stop', i.characterName, 'ok', '');
      } else if (action === 'restart') {
        i.state = 'starting'; i.live.uptimeMs = 0; i.live.reconnects++;
        pushLog(i, 'info', 'supervisor: restart requested');
        audit('instance.start', i.characterName, 'ok', 'restart');
      } else {
        if (i.state !== 'online') return { id: id, ok: false, error: 'instance is not online' };
        i.botEnabled = !!a.on;
        pushLog(i, 'info', 'bot ' + (a.on ? 'enabled' : 'disabled') + ' by ' + session.name);
        audit('instance.config', i.characterName, 'ok', 'bot.enable=' + !!a.on);
      }
      emit('instance', { id: i.id, instance: pubInstance(i) });
      return { id: id, ok: true };
    } catch (e) { return { id: id, ok: false, error: e.message }; }
  }) };
},

'GET /api/instances/:id/configs': function (c) {
  needAuth();
  var i = findInstance(c.params.id);
  return {
    cavebot: CAVEBOTS.slice(),
    targetbot: TARGETBOT.slice(),
    profiles: PROFILES.slice(),
    macros: (macroState[i.id] || []).map(function (m) {
      return { name: m.name, label: m.label, on: m.on, hotkey: m.hotkey || null };
    })
  };
},

'PUT /api/instances/:id/macros/:name': function (c) {
  needAuth();
  var i = findInstance(c.params.id);
  var m = (macroState[i.id] || []).filter(function (x) { return x.name === c.params.name; })[0];
  need(m, 'not-found', 'no such macro: ' + c.params.name);
  m.on = !!(c.body || {}).on;
  pushLog(i, 'info', 'macro ' + m.name + ' -> ' + (m.on ? 'on' : 'off'));
  audit('instance.config', i.characterName, 'ok', 'macro ' + m.name + '=' + m.on);
  return { macro: { name: m.name, label: m.label, on: m.on, hotkey: m.hotkey || null } };
},

'POST /api/instances/:id/reload': function (c) {
  needAuth();
  var i = findInstance(c.params.id);
  pushLog(i, 'info', 'bot: reloading profile ' + i.botProfile);
  audit('instance.config', i.characterName, 'ok', 'bot.reload');
  return {};
},

'POST /api/instances/:id/exec': function (c) {
  needExec();
  var i = findInstance(c.params.id);
  var code = (c.body || {}).code;
  need(typeof code === 'string' && code.length, 'bad-request', 'no code given');
  audit('exec', i.characterName, 'ok', 'code: ' + String(code).slice(0, 400));
  var src = String(code).trim();
  var out;
  if (/getLevel|\blevel\b/i.test(src)) out = String(i.live.level);
  else if (/getHealth|\bhp\b/i.test(src)) out = i.live.hp + ' / ' + i.live.maxHp;
  else if (/getPosition|\bpos\b/i.test(src)) out =
    '{x = ' + i.live.pos.x + ', y = ' + i.live.pos.y + ', z = ' + i.live.pos.z + '}';
  else if (/getName/i.test(src)) out = i.characterName;
  else if (/error|assert\(false\)/i.test(src)) throw E('bad-request', 'chunk:1: something went wrong');
  else if (/^\s*(print|info)\s*\(/.test(src)) out = 'nil    (printed to the worker log)';
  else out = 'nil';
  if (/^\s*(print|info)\s*\(/.test(src)) pushLog(i, 'info', 'exec: ' + src);
  return { output: out };
},

'GET /api/instances/:id/history': function (c) {
  needAuth();
  var i = findInstance(c.params.id);
  var since = Number(c.query.since || 0);
  return { points: (HIST[i.id] || []).filter(function (p) { return p.t >= since; }) };
},

'GET /api/instances/:id/logs': function (c) {
  needAuth();
  var i = findInstance(c.params.id);
  var lim = Math.min(Number(c.query.limit) || 200, 800);
  var all = LOGS[i.id] || [];
  return { lines: all.slice(Math.max(0, all.length - lim)) };
},

'GET /api/instances/:id/chat': function (c) {
  needAuth();
  var i = findInstance(c.params.id);
  var lim = Math.min(Number(c.query.limit) || 200, 500);
  var all = CHAT[i.id] || [];
  return { messages: all.slice(Math.max(0, all.length - lim)) };
},

'POST /api/instances/:id/chat': function (c) {
  needAuth();
  var i = findInstance(c.params.id);
  var a = c.body || {};
  need(i.state === 'online', 'conflict', 'the character is not online');
  need(a.text && String(a.text).trim(), 'bad-request', 'empty message');
  var m = { id: i.id, t: now(), channel: a.channel ? 'Ch' + a.channel : 'Default',
            from: i.characterName, text: String(a.text) };
  CHAT[i.id].push(m);
  emitTo('chat', i.id, 'chat', m);
  return {};
},

/* ---- debug (R3) ---- */

'GET /api/instances/:id/debug': function (c) {
  needAuth();
  var i = findInstance(c.params.id);
  return snapshotFor(i);
},

/* ---- bot config (CONFIGAPI.md) ---- */

'GET /api/instances/:id/config/:kind': function (c) {
  needAuth();
  var i = findInstance(c.params.id);
  var kind = c.params.kind;
  need(CFG_KINDS[kind], 'bad-request', 'unknown config kind: ' + kind);
  var data = ensureCfg(i.id, kind);
  return { kind: kind, data: data, source: CFG_SOURCE[i.id][kind], editable: true };
},

'PUT /api/instances/:id/config/:kind': function (c) {
  needAuth();
  var i = findInstance(c.params.id);
  var kind = c.params.kind;
  need(CFG_KINDS[kind], 'bad-request', 'unknown config kind: ' + kind);
  var data = (c.body || {}).data;
  need(data !== undefined && data !== null, 'bad-request', 'missing data');
  if (kind === 'cavebot') {
    need(Array.isArray(data), 'bad-request', 'cavebot data must be an array of {type,value}');
    for (var w = 0; w < data.length; w++) {
      var wp = data[w];
      need(wp && typeof wp.type === 'string' && wp.type.length,
           'bad-request', 'cavebot[' + (w + 1) + ']: type must be a non-empty string');
      need(wp.type === wp.type.toLowerCase(), 'bad-request',
           'cavebot[' + (w + 1) + ']: type "' + wp.type + '" must be lowercase');
      need(typeof wp.value === 'string' && wp.value.length, 'bad-request',
           'cavebot[' + (w + 1) + '] (' + wp.type + '): value must not be empty');
    }
    if (cavebotDiffNeedsExec(ensureCfg(i.id, 'cavebot'), data)) {
      audit('instance.config', i.characterName, 'denied', 'cavebot function-body change refused (canExec required)');
      throw E('forbidden', 'changing a cavebot function waypoint body requires the canExec capability');
    }
  } else if (kind === 'attackbot') {
    need(Array.isArray(data), 'bad-request', 'attackbot data must be an array (the attackTable itself)');
  } else {
    need(typeof data === 'object' && !Array.isArray(data), 'bad-request', kind + ' data must be an object');
    var allowed = CFG_TOP_KEYS[kind];
    for (var k in data) {
      if (Object.prototype.hasOwnProperty.call(data, k) && !allowed[k]) {
        throw E('bad-request', kind + ' has an unknown field "' + k + '"');
      }
    }
    if (kind === 'conditions') {
      need(typeof data.curePoison === 'boolean', 'bad-request', 'conditions.curePoison is required');
    }
  }
  CFG[i.id] = CFG[i.id] || {};
  CFG_SOURCE[i.id] = CFG_SOURCE[i.id] || {};
  CFG[i.id][kind] = data;
  CFG_SOURCE[i.id][kind] = 'profile';
  var detail = kind === 'cavebot' ? kind + ': ' + data.length + ' waypoint(s)' : kind + ' updated';
  audit('instance.config', i.characterName, 'ok', detail);
  pushLog(i, 'info', 'config: ' + kind + ' saved by ' + session.name);
  return { kind: kind, applied: true };
},

'GET /api/instances/:id/config/:kind/list': function (c) {
  needAuth();
  var i = findInstance(c.params.id);
  var kind = c.params.kind;
  need(CFG_KINDS[kind], 'bad-request', 'unknown config kind: ' + kind);
  /* Matches hub/botconfig.lua's listConfigs exactly: numbers for healbot/
     attackbot (their own numbered profiles), file names for cavebot/
     targetbot, and an empty {names:[],active:null} for conditions/stances --
     those two are single-object kinds with no numbered/named alternative. */
  if (kind === 'cavebot') return { names: CAVEBOTS.slice(), active: i.cavebotConfig };
  if (kind === 'targetbot') return { names: TARGETBOT.slice(), active: i.targetbotConfig };
  if (kind === 'healbot' || kind === 'attackbot') return { names: [1, 2, 3, 4, 5], active: 1 };
  return { names: [], active: null };
},

/* ---- game accounts ---- */

'GET /api/accounts': function () {
  needAuth();
  return { accounts: DB.accounts
    .filter(function (a) { return session.role === 'admin' || a.ownerUserId === session.id; })
    .map(pubAccount) };
},

'POST /api/accounts': function (c) {
  needAuth();
  var a = c.body;
  need(a.label && a.login, 'bad-request', 'label and login are required');
  need(a.password, 'bad-request', 'a password is required');
  var acc = { id: uid('a'), label: a.label, login: a.login, ownerUserId: session.id,
              has2fa: !!a.token2fa };
  DB.accounts.push(acc);
  audit('account.create', acc.label, 'ok', '');      // never the password
  return { account: pubAccount(acc) };
},

'PATCH /api/accounts/:id': function (c) {
  needAuth();
  var acc = DB.accounts.filter(function (x) { return x.id === c.params.id; })[0];
  need(acc, 'not-found', 'no such account');
  need(session.role === 'admin' || acc.ownerUserId === session.id, 'forbidden', 'not your account');
  var p = c.body || {};
  if (p.label) acc.label = p.label;
  if (p.login) acc.login = p.login;
  if (p.token2fa !== undefined) acc.has2fa = !!p.token2fa;
  audit('account.create', acc.label, 'ok', 'updated ' + Object.keys(p)
    .filter(function (k) { return k !== 'password' && k !== 'token2fa'; }).join(','));
  return { account: pubAccount(acc) };
},

'DELETE /api/accounts/:id': function (c) {
  needAuth();
  var acc = DB.accounts.filter(function (x) { return x.id === c.params.id; })[0];
  need(acc, 'not-found', 'no such account');
  var chars = DB.characters.filter(function (x) { return x.accountId === acc.id; });
  chars.forEach(function (ch) {
    DB.instances = DB.instances.filter(function (i) {
      if (i.characterId !== ch.id) return true;
      emit('instance', { id: i.id, removed: true });
      return false;
    });
  });
  DB.characters = DB.characters.filter(function (x) { return x.accountId !== acc.id; });
  DB.accounts = DB.accounts.filter(function (x) { return x.id !== acc.id; });
  audit('account.delete', acc.label, 'ok', chars.length + ' characters removed');
  return {};
},

/* ---- characters ---- */

'GET /api/characters': function () {
  needAuth();
  var mine = DB.accounts.filter(function (a) {
    return session.role === 'admin' || a.ownerUserId === session.id;
  }).map(function (a) { return a.id; });
  return { characters: DB.characters
    .filter(function (c) { return mine.indexOf(c.accountId) >= 0; })
    .map(pubCharacter) };
},

'POST /api/characters': function (c) {
  needAuth();
  var a = c.body;
  need(a.accountId && a.name && a.world, 'bad-request', 'accountId, name and world are required');
  need(!DB.characters.filter(function (x) {
    return x.name.toLowerCase() === String(a.name).toLowerCase();
  })[0], 'conflict', 'a character with that name already exists');
  var ch = { id: uid('c'), accountId: a.accountId, name: a.name, world: a.world,
             vocation: a.vocation || null, lastLevel: null };
  DB.characters.push(ch);
  audit('character.create', ch.name, 'ok', '');
  return { character: pubCharacter(ch) };
},

'DELETE /api/characters/:id': function (c) {
  needAuth();
  var ch = DB.characters.filter(function (x) { return x.id === c.params.id; })[0];
  need(ch, 'not-found', 'no such character');
  DB.instances = DB.instances.filter(function (i) {
    if (i.characterId !== ch.id) return true;
    emit('instance', { id: i.id, removed: true });
    return false;
  });
  DB.characters = DB.characters.filter(function (x) { return x.id !== ch.id; });
  audit('character.delete', ch.name, 'ok', '');
  return {};
},

/* ---- proxies ---- */

'GET /api/proxies': function () { needAuth(); return { proxies: DB.proxies.map(pubProxy) }; },

'POST /api/proxies': function (c) {
  needAuth();
  var a = c.body;
  need(a.label && a.host && a.port, 'bad-request', 'label, host and port are required');
  var p = { id: uid('p'), label: a.label, kind: a.kind || 'http-connect', host: a.host,
            port: Number(a.port), user: a.user || null, hasPass: !!a.pass,
            ownerUserId: session && session.id };
  DB.proxies.push(p);
  audit('proxy.create', p.label, 'ok', p.host + ':' + p.port);   // never the password
  return { proxy: pubProxy(p) };
},

'PATCH /api/proxies/:id': function (c) {
  needAuth();
  var p = DB.proxies.filter(function (x) { return x.id === c.params.id; })[0];
  need(p, 'not-found', 'no such proxy');
  proxyOwnedOrAdmin(p);
  var q = c.body || {};
  ['label', 'kind', 'host', 'user'].forEach(function (k) { if (q[k] !== undefined) p[k] = q[k]; });
  if (q.port !== undefined) p.port = Number(q.port);
  if (q.pass) p.hasPass = true;
  DB.instances.forEach(function (i) { if (i.proxyId === p.id) i.proxyLabel = p.label; });
  audit('proxy.change', p.label, 'ok', '');
  return { proxy: pubProxy(p) };
},

'DELETE /api/proxies/:id': function (c) {
  needAuth();
  var p = DB.proxies.filter(function (x) { return x.id === c.params.id; })[0];
  need(p, 'not-found', 'no such proxy');
  proxyOwnedOrAdmin(p);
  need(!DB.instances.filter(function (i) { return i.proxyId === p.id; }).length,
       'conflict', 'the proxy is still assigned to an instance');
  DB.proxies = DB.proxies.filter(function (x) { return x.id !== p.id; });
  audit('proxy.change', p.label, 'ok', 'deleted');
  return {};
},

'POST /api/proxies/:id/test': function (c) {
  needAuth();
  var p = DB.proxies.filter(function (x) { return x.id === c.params.id; })[0];
  need(p, 'not-found', 'no such proxy');
  if (rnd() < 0.2) return { ok: false, latencyMs: 0, error: 'CONNECT refused (HTTP 403)' };
  return { ok: true, latencyMs: ri(18, 240) };
},

/* ---- scripts ---- */

'GET /api/scripts': function () { needAuth(); return { scripts: DB.scripts.map(pubScript) }; },

'GET /api/scripts/:id': function (c) {
  needAuth();
  var s = DB.scripts.filter(function (x) { return x.id === c.params.id; })[0];
  need(s, 'not-found', 'no such script');
  return { script: pubScript(s), source: s.source };
},

'POST /api/scripts': function (c) {
  needExec();
  var a = c.body;
  need(a.name && /^[\w.\- ]{1,64}$/.test(a.name), 'bad-request', 'invalid script name');
  need(typeof a.source === 'string' && a.source.length, 'bad-request', 'empty source');
  need(a.source.length <= 512 * 1024, 'too-large', 'script exceeds 512 KiB');
  var existing = DB.scripts.filter(function (x) { return x.name === a.name; })[0];
  var s = existing || { id: uid('s'), name: a.name, instanceIds: [], ownerUserId: session.id };
  s.source = a.source;
  s.size = a.source.length;
  s.sha256 = sha256ish(a.source);
  s.createdAt = now();
  if (!existing) DB.scripts.push(s);
  audit('script.upload', s.name, 'ok', s.size + ' bytes, sha256 ' + s.sha256.slice(0, 12));
  emit('script', { id: s.id, script: pubScript(s) });
  return { script: pubScript(s) };
},

'DELETE /api/scripts/:id': function (c) {
  needAuth();
  var s = DB.scripts.filter(function (x) { return x.id === c.params.id; })[0];
  need(s, 'not-found', 'no such script');
  DB.instances.forEach(function (i) {
    i.scripts = i.scripts.filter(function (x) { return x !== s.id; });
  });
  DB.scripts = DB.scripts.filter(function (x) { return x.id !== s.id; });
  audit('script.delete', s.name, 'ok', '');
  emit('script', { id: s.id, removed: true });
  return {};
},

'PUT /api/scripts/:id/assignments': function (c) {
  needAuth();
  var s = DB.scripts.filter(function (x) { return x.id === c.params.id; })[0];
  need(s, 'not-found', 'no such script');
  var ids = ((c.body || {}).instanceIds || []).slice();
  s.instanceIds = ids;
  DB.instances.forEach(function (i) {
    var want = ids.indexOf(i.id) >= 0, at = i.scripts.indexOf(s.id);
    if (want && at < 0) i.scripts.push(s.id);
    if (!want && at >= 0) i.scripts.splice(at, 1);
    if (want) pushLog(i, 'info', 'script pushed: ' + s.name);
    emit('instance', { id: i.id, instance: pubInstance(i) });
  });
  audit('script.assign', s.name, 'ok', ids.length + ' instances');
  return { script: pubScript(s) };
},

/* ---- admin ---- */

'GET /api/admin/users': function () { needAdmin(); return { users: DB.users.map(pubUser) }; },

'POST /api/admin/users': function (c) {
  needAdmin();
  var a = c.body;
  need(a.name && /^[\w.\-]{2,32}$/.test(a.name), 'bad-request', 'invalid account name');
  need(!userByName(a.name), 'conflict', 'that name is taken');
  need(a.password && String(a.password).length >= 10, 'bad-request', 'password too short');
  need(a.role === 'admin' || a.role === 'user', 'bad-request', 'role must be admin or user');
  var u = { id: uid('u'), name: a.name, role: a.role, createdAt: now(), disabled: false, lastLoginAt: null };
  DB.users.push(u);
  audit('user.create', u.name, 'ok', 'role=' + u.role);   // never the password
  return { user: pubUser(u) };
},

'PATCH /api/admin/users/:id': function (c) {
  needAdmin();
  var u = userById(c.params.id);
  need(u, 'not-found', 'no such account');
  need(u.id !== session.id, 'forbidden', 'you cannot change your own role or status');
  var p = c.body || {};
  if (p.role) { need(p.role === 'admin' || p.role === 'user', 'bad-request', 'bad role'); u.role = p.role; }
  if (p.disabled !== undefined) u.disabled = !!p.disabled;
  if (p.canExec !== undefined) u.canExec = !!p.canExec;
  audit('user.create', u.name, 'ok', 'updated ' + Object.keys(p).join(','));
  return { user: pubUser(u) };
},

'DELETE /api/admin/users/:id': function (c) {
  needAdmin();
  var u = userById(c.params.id);
  need(u, 'not-found', 'no such account');
  need(u.id !== session.id, 'forbidden', 'you cannot delete your own account');
  DB.users = DB.users.filter(function (x) { return x.id !== u.id; });
  DB.sessions = DB.sessions.filter(function (s) { return s.userId !== u.id; });
  audit('user.delete', u.name, 'ok', '');
  return {};
},

'POST /api/admin/users/:id/password': function (c) {
  needAdmin();
  var u = userById(c.params.id);
  need(u, 'not-found', 'no such account');
  var pw = (c.body || {}).password;
  need(pw && String(pw).length >= 10, 'bad-request', 'password too short');
  DB.sessions = DB.sessions.filter(function (s) { return s.userId !== u.id || s.current; });
  audit('user.password', u.name, 'ok', 'reset by administrator');   // never the password
  return {};
},

'GET /api/admin/sessions': function () {
  needAdmin();
  return { sessions: DB.sessions.map(function (s) {
    return { id: s.id, userId: s.userId, userName: nameOf(s.userId), ip: s.ip,
             userAgent: s.userAgent, createdAt: s.createdAt, lastSeenAt: s.lastSeenAt,
             current: !!s.current };
  }) };
},

'DELETE /api/admin/sessions/:id': function (c) {
  needAdmin();
  var s = DB.sessions.filter(function (x) { return x.id === c.params.id; })[0];
  need(s, 'not-found', 'no such session');
  DB.sessions = DB.sessions.filter(function (x) { return x.id !== c.params.id; });
  audit('session.revoke', nameOf(s.userId), 'ok', s.ip);
  return {};
},

'GET /api/admin/audit': function (c) {
  needAdmin();
  var a = c.query;
  var rows = DB.audit;
  if (a.actor)  rows = rows.filter(function (r) { return r.actor === a.actor; });
  if (a.action) rows = rows.filter(function (r) { return r.action === a.action; });
  if (a.from)   rows = rows.filter(function (r) { return r.t >= Number(a.from); });
  if (a.to)     rows = rows.filter(function (r) { return r.t <= Number(a.to); });
  if (a.q) {
    var q = String(a.q).toLowerCase();
    rows = rows.filter(function (r) {
      return (r.target + ' ' + r.detail + ' ' + r.action).toLowerCase().indexOf(q) >= 0;
    });
  }
  var start = a.cursor ? Number(a.cursor) : 0;
  var lim = Math.min(Number(a.limit) || 100, 500);
  var page = rows.slice(start, start + lim);
  var actors = {}, actions = {};
  DB.audit.forEach(function (r) { actors[r.actor] = 1; actions[r.action] = 1; });
  return {
    rows: page,
    nextCursor: (start + lim) < rows.length ? String(start + lim) : null,
    total: rows.length,
    actors: Object.keys(actors).sort(),
    actions: Object.keys(actions).sort()
  };
}

};

/* --------------------------- the router ------------------------- */

var COMPILED = Object.keys(ROUTES).map(function (key) {
  var sp = key.indexOf(' ');
  var method = key.slice(0, sp), tmpl = key.slice(sp + 1);
  var names = [];
  var rx = tmpl.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
               .replace(/:([A-Za-z_][A-Za-z0-9_]*)/g, function (m, n) { names.push(n); return '([^/]+)'; });
  return { key: key, method: method, tmpl: tmpl, rx: new RegExp('^' + rx + '$'), names: names,
           fn: ROUTES[key] };
});

function match(method, path) {
  for (var i = 0; i < COMPILED.length; i++) {
    var r = COMPILED[i];
    if (r.method !== method) continue;
    var m = r.rx.exec(path);
    if (!m) continue;
    var params = {};
    for (var j = 0; j < r.names.length; j++) params[r.names[j]] = decodeURIComponent(m[j + 1]);
    return { route: r, params: params };
  }
  return null;
}

var SAFE = { GET: true, HEAD: true, OPTIONS: true };

function handle(method, url, init) {
  var qmark = url.indexOf('?');
  var path = qmark < 0 ? url : url.slice(0, qmark);
  var query = {};
  if (qmark >= 0) {
    url.slice(qmark + 1).split('&').forEach(function (pair) {
      if (!pair) return;
      var eq = pair.indexOf('=');
      var k = decodeURIComponent(eq < 0 ? pair : pair.slice(0, eq));
      query[k] = eq < 0 ? '' : decodeURIComponent(pair.slice(eq + 1).replace(/\+/g, ' '));
    });
  }

  var hit = match(method, path);
  if (!hit) return { status: 404, body: { error: { code: 'not-found', message: 'no route: ' + method + ' ' + path } } };

  /* the CSRF check the real hub must also make */
  if (!SAFE[method]) {
    var hdr = (init && init.headers && (init.headers['X-CSRF-Token'] || init.headers['x-csrf-token'])) || '';
    if (hdr !== csrf) {
      return { status: 403, body: { error: { code: 'csrf-invalid', message: 'bad or missing X-CSRF-Token' } } };
    }
  }

  var body = {};
  if (init && init.body) {
    try { body = JSON.parse(init.body); }
    catch (e) { return { status: 400, body: { error: { code: 'bad-request', message: 'malformed JSON body' } } }; }
  }

  try {
    var result = hit.route.fn({ params: hit.params, query: query, body: body });
    return { status: 200, body: result || {} };
  } catch (e) {
    var code = e.code || 'internal';
    return { status: STATUS[code] || 500, body: { error: { code: code, message: e.message || String(e) } } };
  }
}

/* ------------------------- the fake fetch ----------------------- */

function latency(path) {
  if (API.latencyMs !== null) return API.latencyMs;
  if (/\/exec$/.test(path)) return 120 + rnd() * 500;
  if (/\/audit/.test(path)) return 60 + rnd() * 180;
  if (/\/test$/.test(path)) return 300 + rnd() * 1400;
  return 35 + rnd() * 130;
}

function fakeFetch(url, init) {
  init = init || {};
  var method = (init.method || 'GET').toUpperCase();
  var d = latency(url);
  var run = function () {
    var r = handle(method, String(url), init);
    var text = JSON.stringify(r.body);
    return {
      status: r.status,
      ok: r.status >= 200 && r.status < 300,
      headers: { get: function () { return 'application/json'; } },
      text: function () { return Promise.resolve(text); },
      json: function () { return Promise.resolve(JSON.parse(text)); }
    };
  };
  if (!d) return Promise.resolve().then(run);
  return new Promise(function (resolve) { setTimeout(function () { resolve(run()); }, d); });
}

/* ---------------------- the fake WebSocket ---------------------- */

/* Delivery scheduling. With HubMock.latencyMs = 0 (what automated tests set)
   everything runs on microtasks: a hidden or backgrounded browser tab clamps
   setTimeout hard, which made socket tests flaky for no good reason. */
function soon(fn, ms) {
  if (API.latencyMs === 0) { Promise.resolve().then(fn); return 0; }
  return setTimeout(fn, ms);
}

function FakeWebSocket(url) {
  var self = this;
  this.url = url;
  this.readyState = 0;                 // CONNECTING
  this.onopen = this.onmessage = this.onclose = this.onerror = null;
  this._ready = false;
  this._subs = { logs: null, chat: null, debug: null };
  sockets.push(this);
  soon(function () {
    if (self.readyState !== 0) return;
    self.readyState = 1;               // OPEN
    if (self.onopen) self.onopen({});
  }, 20);
}
FakeWebSocket.prototype.send = function (raw) {
  var self = this;
  var f;
  try { f = JSON.parse(raw); } catch (e) { return; }
  if (f.type === 'auth') {
    /* the same rule the hub enforces: a cookie session AND a matching CSRF token */
    if (!session || f.csrf !== csrf) { this.close(4401); return; }
    this._ready = true;
    soon(function () {
      self._push('ready', { version: 'mock-2.0', user: session ? session.name : null, t: now() });
      if (!timer) timer = setInterval(tick, 1000);
    }, 5);
    return;
  }
  if (!this._ready) return;
  if (f.type === 'subscribe') { this._subs.logs = f.logs || null; this._subs.chat = f.chat || null; return; }
  if (f.type === 'subscribeDebug') { this._subs.debug = f.id || null; return; }
  if (f.type === 'ping') { this._push('pong', { t: f.t }); return; }
};
FakeWebSocket.prototype._push = function (ev, data) {
  if (this.readyState !== 1 || !this.onmessage) return;
  var payload = JSON.stringify({ event: ev, data: data });
  var self = this;
  soon(function () { if (self.onmessage) self.onmessage({ data: payload }); }, 0);
};
FakeWebSocket.prototype.close = function (code, reason) {
  var self = this;
  if (this.readyState === 3) return;
  this.readyState = 3;                 // CLOSED
  this._ready = false;
  var at = sockets.indexOf(this);
  if (at >= 0) sockets.splice(at, 1);
  if (!sockets.length && timer) { clearInterval(timer); timer = null; }
  soon(function () { if (self.onclose) self.onclose({ code: code || 1000, reason: reason || '' }); }, 0);
};

function closeAllSockets(code) {
  sockets.slice().forEach(function (s) { s.close(code); });
}

/* --------------------------- exports ---------------------------- */

var API = {
  /* Simulated round-trip time. null = the per-path profile in latency();
     set HubMock.latencyMs = 0 to answer on a microtask instead, which is what
     automated tests want (a hidden browser tab throttles setTimeout hard). */
  latencyMs: null,

  fetch: fakeFetch,
  WebSocket: FakeWebSocket,

  /* handy in the browser console while developing the UI */
  _db: DB,
  _tick: tick,
  _routes: function () { return COMPILED.map(function (r) { return r.key; }); },
  _csrf: function () { return csrf; },
  _session: function () { return session; }
};

window.HubMock = API;

})();
