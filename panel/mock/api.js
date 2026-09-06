/* ==================================================================
   mock/api.js — a complete, self-contained fake of the hub API.
   ------------------------------------------------------------------
   Loaded only when index.html is opened with ?mock=1. It installs
   window.HubMock = { rpc(cmd, args) -> Promise<envelope>,
                      subscribe(fn), unsubscribe() }
   and drives a simulated worker fleet so the panel is fully clickable
   with no hub, straight off the filesystem.

   The envelope is exactly what the real hub must return over
   POST /api/rpc:
       { id, ok:true,  result: <object> }
       { id, ok:false, error: { code, message } }
   and the event frames are exactly what it must push over
   WS /api/events:
       { event: <name>, data: <object> }

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
      disabled: false, lastLoginAt: T0 - 86400000 * 2 },
    { id: 'u_kim',   name: 'kim',    role: 'user',  createdAt: T0 - 86400000 * 9,
      disabled: true,  lastLoginAt: null }
  ],
  accounts: [
    { id: 'a_main', label: 'main-eu',  login: 'l4g-main',  ownerUserId: 'u_admin', has2fa: true,  token2fa: true },
    { id: 'a_alt',  label: 'alt-farm', login: 'l4g-alt',   ownerUserId: 'u_admin', has2fa: false, token2fa: false },
    { id: 'a_sam',  label: 'sam-01',   login: 'sam-primary', ownerUserId: 'u_sam', has2fa: false, token2fa: false }
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
    { id: 'p_de', label: 'de-frankfurt', kind: 'http-connect', host: '10.20.0.11', port: 8080, user: 'w1', hasPass: true },
    { id: 'p_nl', label: 'nl-amsterdam', kind: 'http-connect', host: '10.20.0.12', port: 8080, user: 'w2', hasPass: true },
    { id: 'p_pl', label: 'pl-warsaw',    kind: 'http-connect', host: '10.20.0.13', port: 3128, user: null, hasPass: false }
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

/* macro state per instance */
var macroState = {};
DB.instances.forEach(function (i) {
  macroState[i.id] = MACROS.map(function (m) {
    return { name: m.name, label: m.label, on: rnd() > 0.35, hotkey: null };
  });
});

/* rolling logs / chat / history */
var LOGS = {}, CHAT = {}, HIST = {};
DB.instances.forEach(function (i) { LOGS[i.id] = []; CHAT[i.id] = []; HIST[i.id] = []; });

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

function userByName(n) {
  return DB.users.filter(function (u) { return u.name.toLowerCase() === String(n).toLowerCase(); })[0];
}
function userById(id) { return DB.users.filter(function (u) { return u.id === id; })[0]; }
function nameOf(id) { var u = userById(id); return u ? u.name : '?'; }

/* --------------------------- events ----------------------------- */

var listener = null, timer = null, ticks = 0;

function emit(ev, data, adminOnly) {
  if (!listener) return;
  if (adminOnly && (!session || session.role !== 'admin')) return;
  try { listener(ev, data); } catch (e) { /* the panel logs its own handler errors */ }
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
      if (visible(i)) emit('chat', m);
    }

    /* the broken one flaps */
    if (i.state === 'error' && rnd() < 0.05) {
      L.reconnects++;
      pushLog(i, 'error', 'proxy ' + (i.proxyLabel || 'direct') + ': connect failed (ETIMEDOUT), retry #' + L.reconnects);
      if (visible(i)) emit('error', { id: i.id, message: 'proxy connect failed (ETIMEDOUT)' });
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
  if (visible(inst)) emit('log', line);
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
  return { id: p.id, label: p.label, kind: p.kind, host: p.host, port: p.port,
           user: p.user, hasPass: !!p.hasPass,
           inUse: DB.instances.filter(function (i) { return i.proxyId === p.id; }).length };
}
function pubUser(u) {
  return { id: u.id, name: u.name, role: u.role, createdAt: u.createdAt,
           disabled: !!u.disabled, lastLoginAt: u.lastLoginAt };
}

/* --------------------------- errors ----------------------------- */

function E(code, message) { var e = new Error(message); e.code = code; return e; }
function need(cond, code, msg) { if (!cond) throw E(code, msg); }
function needAuth() { need(session, 'unauthorized', 'not signed in'); }
function needAdmin() { needAuth(); need(session.role === 'admin', 'forbidden', 'administrators only'); }

/* -------------------------- the handlers ------------------------ */

var H = {

/* ---- auth ---- */

'auth.session': function () {
  return { user: session ? { id: session.id, name: session.name, role: session.role } : null,
           serverTime: now(), version: 'mock-1.0', bootstrap: false, insecure: location.protocol !== 'https:' };
},

'auth.login': function (a) {
  var u = userByName(a.name);
  // the mock accepts any non-trivial password; it never stores or echoes it
  if (!u || !a.password || String(a.password).length < 3) {
    audit('login.fail', String(a.name || ''), 'denied', '');
    throw E('unauthorized', 'wrong name or password');
  }
  need(!u.disabled, 'forbidden', 'this account is disabled');
  session = { id: u.id, name: u.name, role: u.role };
  u.lastLoginAt = now();
  DB.sessions[0].userId = u.id;
  DB.sessions[0].createdAt = now();
  audit('login.ok', u.name, 'ok', '');
  return { user: { id: u.id, name: u.name, role: u.role } };
},

'auth.bootstrap': function (a) {
  need(a.token && String(a.token).length >= 8, 'bad-request', 'bootstrap token looks wrong');
  var u = { id: uid('u'), name: a.name, role: 'admin', createdAt: now(), disabled: false, lastLoginAt: now() };
  DB.users.push(u);
  session = { id: u.id, name: u.name, role: 'admin' };
  audit('user.create', u.name, 'ok', 'bootstrap administrator');
  return { user: { id: u.id, name: u.name, role: u.role } };
},

'auth.logout': function () {
  if (session) audit('logout', session.name, 'ok', '');
  session = null;
  return {};
},

'auth.changePassword': function (a) {
  needAuth();
  need(a.current && a.next, 'bad-request', 'both passwords are required');
  need(String(a.next).length >= 10, 'bad-request', 'the new password is too short');
  audit('user.password', session.name, 'ok', 'self-service change');
  return {};
},

/* ---- instances ---- */

'instance.list': function () {
  needAuth();
  return { instances: myInstances().map(pubInstance) };
},

'instance.get': function (a) { needAuth(); return { instance: pubInstance(findInstance(a.id)) }; },

'instance.create': function (a) {
  needAuth();
  var ch = DB.characters.filter(function (c) { return c.id === a.characterId; })[0];
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
  macroState[inst.id] = MACROS.map(function (m) { return { name: m.name, label: m.label, on: false }; });
  audit('instance.create', ch.name, 'ok', '');
  emit('instance', { id: inst.id, instance: pubInstance(inst) });
  return { instance: pubInstance(inst) };
},

'instance.update': function (a) {
  needAuth();
  var i = findInstance(a.id), p = a.patch || {};
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

'instance.delete': function (a) {
  needAuth();
  var i = findInstance(a.id);
  DB.instances = DB.instances.filter(function (x) { return x.id !== i.id; });
  audit('instance.delete', i.characterName, 'ok', '');
  emit('instance', { id: i.id, removed: true });
  return {};
},

'instance.start': function (a) {
  needAuth();
  return { results: (a.ids || []).map(function (id) {
    try {
      var i = findInstance(id);
      if (i.state === 'online' || i.state === 'starting' || i.state === 'connecting')
        return { id: id, ok: false, error: 'already running' };
      i.state = 'starting'; i.live.uptimeMs = 0;
      pushLog(i, 'info', 'supervisor: spawning worker for ' + i.characterName +
        ' via ' + (i.proxyLabel || 'direct connection'));
      audit('instance.start', i.characterName, 'ok', '');
      return { id: id, ok: true };
    } catch (e) { return { id: id, ok: false, error: e.message }; }
  }) };
},

'instance.stop': function (a) {
  needAuth();
  return { results: (a.ids || []).map(function (id) {
    try {
      var i = findInstance(id);
      if (i.state === 'stopped') return { id: id, ok: false, error: 'already stopped' };
      i.state = 'stopping';
      pushLog(i, 'info', 'supervisor: sending shutdown');
      audit('instance.stop', i.characterName, 'ok', '');
      return { id: id, ok: true };
    } catch (e) { return { id: id, ok: false, error: e.message }; }
  }) };
},

'instance.restart': function (a) {
  needAuth();
  return { results: (a.ids || []).map(function (id) {
    try {
      var i = findInstance(id);
      i.state = 'starting'; i.live.uptimeMs = 0; i.live.reconnects++;
      pushLog(i, 'info', 'supervisor: restart requested');
      audit('instance.start', i.characterName, 'ok', 'restart');
      return { id: id, ok: true };
    } catch (e) { return { id: id, ok: false, error: e.message }; }
  }) };
},

'instance.botEnable': function (a) {
  needAuth();
  return { results: (a.ids || []).map(function (id) {
    try {
      var i = findInstance(id);
      if (i.state !== 'online') return { id: id, ok: false, error: 'instance is not online' };
      i.botEnabled = !!a.on;
      pushLog(i, 'info', 'bot ' + (a.on ? 'enabled' : 'disabled') + ' by ' + session.name);
      audit('instance.config', i.characterName, 'ok', 'bot.enable=' + !!a.on);
      return { id: id, ok: true };
    } catch (e) { return { id: id, ok: false, error: e.message }; }
  }) };
},

'instance.configs': function (a) {
  needAuth();
  var i = findInstance(a.id);
  return {
    cavebot: CAVEBOTS.slice(),
    targetbot: TARGETBOT.slice(),
    profiles: PROFILES.slice(),
    macros: (macroState[i.id] || []).map(function (m) {
      return { name: m.name, label: m.label, on: m.on, hotkey: m.hotkey || null };
    })
  };
},

'instance.setMacro': function (a) {
  needAuth();
  var i = findInstance(a.id);
  var m = (macroState[i.id] || []).filter(function (x) { return x.name === a.name; })[0];
  need(m, 'not-found', 'no such macro: ' + a.name);
  m.on = !!a.on;
  pushLog(i, 'info', 'macro ' + m.name + ' -> ' + (m.on ? 'on' : 'off'));
  audit('instance.config', i.characterName, 'ok', 'macro ' + m.name + '=' + m.on);
  return {};
},

'instance.reload': function (a) {
  needAuth();
  var i = findInstance(a.id);
  pushLog(i, 'info', 'bot: reloading profile ' + i.botProfile);
  audit('instance.config', i.characterName, 'ok', 'bot.reload');
  return {};
},

'instance.exec': function (a) {
  needAuth();
  var i = findInstance(a.id);
  need(typeof a.code === 'string' && a.code.length, 'bad-request', 'no code given');
  audit('exec', i.characterName, 'ok', 'code: ' + String(a.code).slice(0, 400));
  var src = String(a.code).trim();
  var out;
  if (/getLevel|\blevel\b/i.test(src)) out = String(i.live.level);
  else if (/getHealth|\bhp\b/i.test(src)) out = i.live.hp + ' / ' + i.live.maxHp;
  else if (/getPosition|\bpos\b/i.test(src)) out =
    '{x = ' + i.live.pos.x + ', y = ' + i.live.pos.y + ', z = ' + i.live.pos.z + '}';
  else if (/getName/i.test(src)) out = i.characterName;
  else if (/error|assert\(false\)/i.test(src)) throw E('exec-error', 'chunk:1: something went wrong');
  else if (/^\s*(print|info)\s*\(/.test(src)) out = 'nil    (printed to the worker log)';
  else out = 'nil';
  if (/^\s*(print|info)\s*\(/.test(src)) pushLog(i, 'info', 'exec: ' + src);
  return { output: out };
},

'instance.history': function (a) {
  needAuth();
  var i = findInstance(a.id);
  var since = a.since || 0;
  return { points: (HIST[i.id] || []).filter(function (p) { return p.t >= since; }) };
},

'instance.logs': function (a) {
  needAuth();
  var i = findInstance(a.id);
  var lim = Math.min(a.limit || 200, 800);
  var all = LOGS[i.id] || [];
  return { lines: all.slice(Math.max(0, all.length - lim)) };
},

'instance.chat': function (a) {
  needAuth();
  var i = findInstance(a.id);
  var lim = Math.min(a.limit || 200, 500);
  var all = CHAT[i.id] || [];
  return { messages: all.slice(Math.max(0, all.length - lim)) };
},

'instance.say': function (a) {
  needAuth();
  var i = findInstance(a.id);
  need(i.state === 'online', 'conflict', 'the character is not online');
  need(a.text && String(a.text).trim(), 'bad-request', 'empty message');
  var m = { id: i.id, t: now(), channel: a.channel ? 'Ch' + a.channel : 'Default',
            from: i.characterName, text: String(a.text) };
  CHAT[i.id].push(m);
  emit('chat', m);
  return {};
},

/* ---- game accounts ---- */

'account.list': function () {
  needAuth();
  return { accounts: DB.accounts
    .filter(function (a) { return session.role === 'admin' || a.ownerUserId === session.id; })
    .map(pubAccount) };
},

'account.create': function (a) {
  needAuth();
  need(a.label && a.login, 'bad-request', 'label and login are required');
  need(a.password, 'bad-request', 'a password is required');
  var acc = { id: uid('a'), label: a.label, login: a.login, ownerUserId: session.id,
              has2fa: !!a.token2fa, token2fa: !!a.token2fa };
  DB.accounts.push(acc);
  audit('account.create', acc.label, 'ok', '');      // never the password
  return { account: pubAccount(acc) };
},

'account.update': function (a) {
  needAuth();
  var acc = DB.accounts.filter(function (x) { return x.id === a.id; })[0];
  need(acc, 'not-found', 'no such account');
  need(session.role === 'admin' || acc.ownerUserId === session.id, 'forbidden', 'not your account');
  var p = a.patch || {};
  if (p.label) acc.label = p.label;
  if (p.login) acc.login = p.login;
  if (p.token2fa !== undefined) acc.has2fa = !!p.token2fa;
  audit('account.create', acc.label, 'ok', 'updated ' + Object.keys(p)
    .filter(function (k) { return k !== 'password' && k !== 'token2fa'; }).join(','));
  return { account: pubAccount(acc) };
},

'account.delete': function (a) {
  needAuth();
  var acc = DB.accounts.filter(function (x) { return x.id === a.id; })[0];
  need(acc, 'not-found', 'no such account');
  var chars = DB.characters.filter(function (c) { return c.accountId === acc.id; });
  chars.forEach(function (c) {
    DB.instances = DB.instances.filter(function (i) {
      if (i.characterId !== c.id) return true;
      emit('instance', { id: i.id, removed: true });
      return false;
    });
  });
  DB.characters = DB.characters.filter(function (c) { return c.accountId !== acc.id; });
  DB.accounts = DB.accounts.filter(function (x) { return x.id !== acc.id; });
  audit('account.delete', acc.label, 'ok', chars.length + ' characters removed');
  return {};
},

/* ---- characters ---- */

'character.list': function () {
  needAuth();
  var mine = DB.accounts.filter(function (a) {
    return session.role === 'admin' || a.ownerUserId === session.id;
  }).map(function (a) { return a.id; });
  return { characters: DB.characters
    .filter(function (c) { return mine.indexOf(c.accountId) >= 0; })
    .map(pubCharacter) };
},

'character.create': function (a) {
  needAuth();
  need(a.accountId && a.name && a.world, 'bad-request', 'accountId, name and world are required');
  need(!DB.characters.filter(function (c) {
    return c.name.toLowerCase() === String(a.name).toLowerCase();
  })[0], 'conflict', 'a character with that name already exists');
  var c = { id: uid('c'), accountId: a.accountId, name: a.name, world: a.world,
            vocation: a.vocation || null, lastLevel: null };
  DB.characters.push(c);
  audit('character.create', c.name, 'ok', '');
  return { character: pubCharacter(c) };
},

'character.delete': function (a) {
  needAuth();
  var c = DB.characters.filter(function (x) { return x.id === a.id; })[0];
  need(c, 'not-found', 'no such character');
  DB.instances = DB.instances.filter(function (i) {
    if (i.characterId !== c.id) return true;
    emit('instance', { id: i.id, removed: true });
    return false;
  });
  DB.characters = DB.characters.filter(function (x) { return x.id !== c.id; });
  audit('character.delete', c.name, 'ok', '');
  return {};
},

/* ---- proxies ---- */

'proxy.list': function () { needAuth(); return { proxies: DB.proxies.map(pubProxy) }; },

'proxy.create': function (a) {
  needAuth();
  need(a.label && a.host && a.port, 'bad-request', 'label, host and port are required');
  var p = { id: uid('p'), label: a.label, kind: a.kind || 'http-connect', host: a.host,
            port: Number(a.port), user: a.user || null, hasPass: !!a.pass };
  DB.proxies.push(p);
  audit('proxy.create', p.label, 'ok', p.host + ':' + p.port);
  return { proxy: pubProxy(p) };
},

'proxy.update': function (a) {
  needAuth();
  var p = DB.proxies.filter(function (x) { return x.id === a.id; })[0];
  need(p, 'not-found', 'no such proxy');
  var q = a.patch || {};
  ['label', 'kind', 'host', 'user'].forEach(function (k) { if (q[k] !== undefined) p[k] = q[k]; });
  if (q.port !== undefined) p.port = Number(q.port);
  if (q.pass) p.hasPass = true;
  DB.instances.forEach(function (i) { if (i.proxyId === p.id) i.proxyLabel = p.label; });
  audit('proxy.change', p.label, 'ok', '');
  return { proxy: pubProxy(p) };
},

'proxy.delete': function (a) {
  needAuth();
  var p = DB.proxies.filter(function (x) { return x.id === a.id; })[0];
  need(p, 'not-found', 'no such proxy');
  need(!DB.instances.filter(function (i) { return i.proxyId === p.id; }).length,
       'conflict', 'the proxy is still assigned to an instance');
  DB.proxies = DB.proxies.filter(function (x) { return x.id !== p.id; });
  audit('proxy.change', p.label, 'ok', 'deleted');
  return {};
},

'proxy.test': function (a) {
  needAuth();
  var p = DB.proxies.filter(function (x) { return x.id === a.id; })[0];
  need(p, 'not-found', 'no such proxy');
  if (rnd() < 0.2) return { ok: false, latencyMs: 0, error: 'CONNECT refused (HTTP 403)' };
  return { ok: true, latencyMs: ri(18, 240) };
},

/* ---- scripts ---- */

'script.list': function () { needAuth(); return { scripts: DB.scripts.map(pubScript) }; },

'script.get': function (a) {
  needAuth();
  var s = DB.scripts.filter(function (x) { return x.id === a.id; })[0];
  need(s, 'not-found', 'no such script');
  return { script: pubScript(s), source: s.source };
},

'script.upload': function (a) {
  needAuth();
  need(a.name && /^[\w.\- ]{1,64}$/.test(a.name), 'bad-request', 'invalid script name');
  need(typeof a.source === 'string' && a.source.length, 'bad-request', 'empty source');
  need(a.source.length <= 512 * 1024, 'bad-request', 'script exceeds 512 KiB');
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

'script.delete': function (a) {
  needAuth();
  var s = DB.scripts.filter(function (x) { return x.id === a.id; })[0];
  need(s, 'not-found', 'no such script');
  DB.instances.forEach(function (i) {
    i.scripts = i.scripts.filter(function (x) { return x !== s.id; });
  });
  DB.scripts = DB.scripts.filter(function (x) { return x.id !== s.id; });
  audit('script.delete', s.name, 'ok', '');
  emit('script', { id: s.id, removed: true });
  return {};
},

'script.assign': function (a) {
  needAuth();
  var s = DB.scripts.filter(function (x) { return x.id === a.id; })[0];
  need(s, 'not-found', 'no such script');
  var ids = (a.instanceIds || []).slice();
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

'admin.users': function () { needAdmin(); return { users: DB.users.map(pubUser) }; },

'admin.userCreate': function (a) {
  needAdmin();
  need(a.name && /^[\w.\-]{2,32}$/.test(a.name), 'bad-request', 'invalid account name');
  need(!userByName(a.name), 'conflict', 'that name is taken');
  need(a.password && String(a.password).length >= 10, 'bad-request', 'password too short');
  need(a.role === 'admin' || a.role === 'user', 'bad-request', 'role must be admin or user');
  var u = { id: uid('u'), name: a.name, role: a.role, createdAt: now(), disabled: false, lastLoginAt: null };
  DB.users.push(u);
  audit('user.create', u.name, 'ok', 'role=' + u.role);   // never the password
  return { user: pubUser(u) };
},

'admin.userUpdate': function (a) {
  needAdmin();
  var u = userById(a.id);
  need(u, 'not-found', 'no such account');
  need(u.id !== session.id, 'forbidden', 'you cannot change your own role or status');
  var p = a.patch || {};
  if (p.role) { need(p.role === 'admin' || p.role === 'user', 'bad-request', 'bad role'); u.role = p.role; }
  if (p.disabled !== undefined) u.disabled = !!p.disabled;
  audit('user.create', u.name, 'ok', 'updated ' + Object.keys(p).join(','));
  return { user: pubUser(u) };
},

'admin.userDelete': function (a) {
  needAdmin();
  var u = userById(a.id);
  need(u, 'not-found', 'no such account');
  need(u.id !== session.id, 'forbidden', 'you cannot delete your own account');
  DB.users = DB.users.filter(function (x) { return x.id !== u.id; });
  DB.sessions = DB.sessions.filter(function (s) { return s.userId !== u.id; });
  audit('user.delete', u.name, 'ok', '');
  return {};
},

'admin.userResetPassword': function (a) {
  needAdmin();
  var u = userById(a.id);
  need(u, 'not-found', 'no such account');
  need(a.password && String(a.password).length >= 10, 'bad-request', 'password too short');
  DB.sessions = DB.sessions.filter(function (s) { return s.userId !== u.id || s.current; });
  audit('user.password', u.name, 'ok', 'reset by administrator');   // never the password
  return {};
},

'admin.sessions': function () {
  needAdmin();
  return { sessions: DB.sessions.map(function (s) {
    return { id: s.id, userId: s.userId, userName: nameOf(s.userId), ip: s.ip,
             userAgent: s.userAgent, createdAt: s.createdAt, lastSeenAt: s.lastSeenAt,
             current: !!s.current };
  }) };
},

'admin.sessionRevoke': function (a) {
  needAdmin();
  var s = DB.sessions.filter(function (x) { return x.id === a.id; })[0];
  need(s, 'not-found', 'no such session');
  DB.sessions = DB.sessions.filter(function (x) { return x.id !== a.id; });
  audit('session.revoke', nameOf(s.userId), 'ok', s.ip);
  return {};
},

'admin.audit': function (a) {
  needAdmin();
  var rows = DB.audit;
  if (a.actor)  rows = rows.filter(function (r) { return r.actor === a.actor; });
  if (a.action) rows = rows.filter(function (r) { return r.action === a.action; });
  if (a.from)   rows = rows.filter(function (r) { return r.t >= a.from; });
  if (a.to)     rows = rows.filter(function (r) { return r.t <= a.to; });
  if (a.q) {
    var q = String(a.q).toLowerCase();
    rows = rows.filter(function (r) {
      return (r.target + ' ' + r.detail + ' ' + r.action).toLowerCase().indexOf(q) >= 0;
    });
  }
  var start = a.cursor ? Number(a.cursor) : 0;
  var lim = Math.min(a.limit || 100, 500);
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

/* ------------------------- the transport ------------------------ */

function latency(cmd) {
  if (API.latencyMs !== null) return API.latencyMs;
  if (cmd === 'instance.exec') return 120 + rnd() * 500;
  if (cmd.indexOf('admin.audit') === 0) return 60 + rnd() * 180;
  if (cmd === 'proxy.test') return 300 + rnd() * 1400;
  return 35 + rnd() * 130;
}

function dispatch(cmd, args) {
  var fn = H[cmd];
  if (!fn) return { ok: false, error: { code: 'unknown-command', message: 'no such command: ' + cmd } };
  try { return { ok: true, result: fn(args || {}) }; }
  catch (e) { return { ok: false, error: { code: e.code || 'internal', message: e.message || String(e) } }; }
}

var API = {
  /* Simulated round-trip time. null = the per-command profile in latency();
     set HubMock.latencyMs = 0 to answer on a microtask instead, which is what
     automated tests want (a hidden browser tab throttles setTimeout hard). */
  latencyMs: null,

  rpc: function (cmd, args) {
    var d = latency(cmd);
    if (!d) return Promise.resolve().then(function () { return dispatch(cmd, args); });
    return new Promise(function (resolve) {
      setTimeout(function () { resolve(dispatch(cmd, args)); }, d);
    });
  },

  subscribe: function (fn) {
    listener = fn;
    if (!timer) timer = setInterval(tick, 1000);
    setTimeout(function () { if (listener) listener('hello', { version: 'mock-1.0', t: now() }); }, 50);
  },

  unsubscribe: function () {
    listener = null;
    if (timer) { clearInterval(timer); timer = null; }
  },

  /* handy in the browser console while developing the UI */
  _db: DB,
  _tick: tick
};

window.HubMock = API;

})();
