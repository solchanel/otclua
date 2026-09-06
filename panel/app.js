/* ==================================================================
   luaclient hub — panel front-end
   ------------------------------------------------------------------
   Vanilla ES5-dialect JS. No framework, no bundler, no CDN. Served as
   a static file by the hub; also runs against panel/mock/api.js with
   ?mock=1 (same code paths, only the network is faked).

   Loads after panel/rpc.js (transport) and panel/api.js (the endpoint
   table, which is the contract the hub must match).

   Security notes that are load-bearing, not decoration:
     * Every piece of server data reaches the DOM through
       document.createTextNode / .textContent. `innerHTML` is never
       assigned anywhere in this file. Search for it: zero hits.
     * The session lives in an HttpOnly cookie set by the hub. No
       password, token or session id is ever put in a URL, in
       localStorage/sessionStorage, or logged to the console. The CSRF
       token lives in memory inside the HttpClient for the life of the
       page.
     * localStorage is used for exactly two cosmetic keys:
       `panel.tab.<instanceId>` and `panel.rail`.
     * Every destructive action goes through Modal.confirm.
   ================================================================== */

(function () {
'use strict';

/* ============================ 0. env ============================= */

var RPC = window.PanelRpc;
var APIDEF = window.PanelApi;

var QS       = new URLSearchParams(location.search);
var MOCK     = !!window.HubMock && QS.get('mock') === '1';
var BASE     = QS.get('api') || '';           // optional hub origin override
var IS_HTTPS = location.protocol === 'https:';

/* ========================= 1. DOM helpers ======================== */

/**
 * h('div.card#id', {props}, child, child, ...)
 * Children may be nodes, strings, numbers, null/undefined (skipped) or
 * arrays thereof. Strings always become text nodes.
 */
function h(sel, props) {
  var parts = String(sel).split(/(?=[.#])/);
  var el = document.createElement(parts[0] || 'div');
  for (var i = 1; i < parts.length; i++) {
    var p = parts[i];
    if (p.charAt(0) === '.') el.classList.add(p.slice(1));
    else if (p.charAt(0) === '#') el.id = p.slice(1);
  }
  if (props) {
    for (var k in props) {
      if (!Object.prototype.hasOwnProperty.call(props, k)) continue;
      var v = props[k];
      if (v === null || v === undefined) continue;
      if (k === 'text') el.textContent = String(v);
      else if (k === 'html') throw new Error('h(): html prop is forbidden');
      else if (k === 'style' && typeof v === 'object') { for (var s in v) el.style[s] = v[s]; }
      else if (k === 'dataset') { for (var d in v) el.dataset[d] = v[d]; }
      else if (k.slice(0, 2) === 'on' && typeof v === 'function') el.addEventListener(k.slice(2), v);
      else if (k === 'value' || k === 'checked' || k === 'disabled' || k === 'selected') el[k] = v;
      else el.setAttribute(k, v === true ? '' : String(v));
    }
  }
  for (var a = 2; a < arguments.length; a++) append(el, arguments[a]);
  return el;
}

function append(el, kid) {
  if (kid === null || kid === undefined || kid === false) return;
  if (Array.isArray(kid)) { kid.forEach(function (k) { append(el, k); }); return; }
  el.appendChild(kid instanceof Node ? kid : document.createTextNode(String(kid)));
}

function clear(el) { while (el.firstChild) el.removeChild(el.firstChild); }
function txt(s) { return document.createTextNode(s === null || s === undefined ? '' : String(s)); }
function setText(node, s) {                       // cheap: skip identical writes
  var v = (s === null || s === undefined) ? '' : String(s);
  if (node.textContent !== v) node.textContent = v;
}

/* ========================= 2. formatting ========================= */

function num(n) {
  if (n === null || n === undefined || isNaN(n)) return '-';
  return Math.round(n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
}
function short(n) {
  if (n === null || n === undefined || isNaN(n)) return '-';
  var a = Math.abs(n), sign = n < 0 ? '-' : '';
  if (a >= 1e9) return sign + (a / 1e9).toFixed(2) + 'G';
  if (a >= 1e6) return sign + (a / 1e6).toFixed(2) + 'M';
  if (a >= 1e4) return sign + (a / 1e3).toFixed(1) + 'k';
  return sign + Math.round(a);
}
function rate(n) { return n === null || n === undefined ? '-' : short(n) + '/h'; }
function dur(ms) {
  if (!ms || ms < 0) return '-';
  var s = Math.floor(ms / 1000);
  var d = Math.floor(s / 86400); s -= d * 86400;
  var hh = Math.floor(s / 3600); s -= hh * 3600;
  var mm = Math.floor(s / 60); s -= mm * 60;
  var p2 = function (x) { return (x < 10 ? '0' : '') + x; };
  return (d ? d + 'd ' : '') + p2(hh) + ':' + p2(mm) + ':' + p2(s);
}
function clockOf(t) {
  var d = new Date(t);
  var p2 = function (x) { return (x < 10 ? '0' : '') + x; };
  return p2(d.getHours()) + ':' + p2(d.getMinutes()) + ':' + p2(d.getSeconds());
}
function stamp(t) {
  if (!t) return '-';
  var d = new Date(t);
  var p2 = function (x) { return (x < 10 ? '0' : '') + x; };
  return d.getFullYear() + '-' + p2(d.getMonth() + 1) + '-' + p2(d.getDate()) + ' ' + clockOf(t);
}
function pct(a, b) { return !b ? 0 : Math.max(0, Math.min(100, (a / b) * 100)); }
function posStr(p) { return p ? p.x + ',' + p.y + ',' + p.z : '-'; }

/* =========================== 3. toasts =========================== */

var Toast = {
  el: document.getElementById('toasts'),
  show: function (kind, title, detail, ms) {
    var node = h('div.toast.' + kind, { role: 'alert' },
      h('div.tx', null,
        h('div.tt', { text: title }),
        detail ? h('div.td', { text: detail }) : null),
      h('button.btn.ghost.sm', {
        'aria-label': 'Dismiss', text: '×',
        onclick: function () { drop(); }
      })
    );
    Toast.el.appendChild(node);
    var timer = setTimeout(drop, ms || (kind === 'err' ? 9000 : 4500));
    function drop() { clearTimeout(timer); if (node.parentNode) node.parentNode.removeChild(node); }
    return drop;
  },
  ok:   function (t, d) { return Toast.show('ok', t, d); },
  err:  function (t, d) { return Toast.show('err', t, d); },
  warn: function (t, d) { return Toast.show('warn', t, d); },
  info: function (t, d) { return Toast.show('info', t, d); }
};

/**
 * The single place a failed call becomes visible. Shows the stable error
 * code and, for anything the operator may need to report, which endpoint
 * it was — a 404 on /api/instances/x is a different bug from a 404 on
 * /api/scripts/y and the toast should not hide that.
 */
function failed(what, e) {
  var msg = (e && e.message) ? e.message : String(e);
  var code = (e && e.code) ? ' [' + e.code + ']' : '';
  var where = (e && e.method && e.path) ? e.method + ' ' + e.path : '';
  Toast.err(what + ' failed' + code, where ? msg + '  (' + where + ')' : msg);
}

/* =========================== 4. modal ============================ */

var Modal = (function () {
  var back = document.getElementById('modal-back');
  var lastFocus = null, current = null;

  back.addEventListener('mousedown', function (e) { if (e.target === back) close(); });
  document.addEventListener('keydown', function (e) {
    if (!current) return;
    if (e.key === 'Escape') { e.preventDefault(); close(); }
    else if (e.key === 'Tab') trap(e);
  });

  function focusables() {
    return Array.prototype.filter.call(
      back.querySelectorAll('a[href],button:not([disabled]),input:not([disabled]),select,textarea,[tabindex]:not([tabindex="-1"])'),
      function (n) { return n.offsetParent !== null; });
  }
  function trap(e) {
    var f = focusables();
    if (!f.length) return;
    var first = f[0], last = f[f.length - 1];
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
  }

  /**
   * open({title, body:Node, actions:[{label,kind,onclick(close)}], onsubmit})
   * If onsubmit is given the body is wrapped in a <form> so Enter submits.
   */
  function open(o) {
    close();
    lastFocus = document.activeElement;
    var body = h('div.mbody', null, o.body);
    var foot = h('div.mfoot');
    (o.actions || []).forEach(function (a) {
      foot.appendChild(h('button.btn' + (a.kind ? '.' + a.kind : ''), {
        type: a.submit ? 'submit' : 'button',
        text: a.label,
        onclick: a.submit ? null : function () { a.onclick ? a.onclick(close) : close(); }
      }));
    });
    var inner = o.onsubmit
      ? h('form', { onsubmit: function (e) { e.preventDefault(); o.onsubmit(close, e); } }, body, foot)
      : h('div', null, body, foot);
    var box = h('div.modal', { role: 'dialog', 'aria-modal': 'true', 'aria-label': o.title },
      h('h2', { text: o.title }), inner);
    clear(back); back.appendChild(box); back.hidden = false;
    current = box;
    var f = focusables();
    if (f.length) f[0].focus();
    return close;
  }

  function close() {
    if (!current) return;
    current = null; back.hidden = true; clear(back);
    if (lastFocus && lastFocus.focus) { try { lastFocus.focus(); } catch (e) {} }
  }

  /** Every destructive action in this file goes through here. */
  function confirm(title, message, onYes, yesLabel) {
    open({
      title: title,
      body: h('div', null, h('div', { text: message })),
      actions: [
        { label: 'Cancel' },
        { label: yesLabel || 'Confirm', kind: 'danger', onclick: function (c) { c(); onYes(); } }
      ]
    });
  }

  return { open: open, close: close, confirm: confirm };
})();

/* ====================== 5. transport wiring ====================== */

var http = new RPC.HttpClient({
  base: BASE,
  timeoutMs: 15000,
  fetch: MOCK ? window.HubMock.fetch : null,
  onUnauthorized: function () { onUnauthorized(); },
  refreshCsrf: function () {
    /* the token went stale: ask for a new one, without recursing */
    return http.request('GET', '/api/session', null, { noCsrfRetry: true, retries: 0 })
      .then(function () {}, function () {});
  }
});

var ws = new RPC.WsClient({
  base: BASE,
  path: APIDEF.WS.path,
  getCsrf: function () { return http.csrf; },
  WebSocket: MOCK ? window.HubMock.WebSocket : null
});

var api = new APIDEF.Api(http);

/* ============================ 6. store =========================== */

var S = {
  me: null,
  serverVersion: '',
  instances: [],
  byId: Object.create(null),
  accounts: [], characters: [], proxies: [], scripts: [],
  users: [], sessions: [],
  logs: Object.create(null),      // instanceId -> [{t,level,text}]
  chats: Object.create(null),     // instanceId -> [{t,channel,from,text}]
  history: Object.create(null),   // instanceId -> [point]
  configs: Object.create(null),   // instanceId -> {cavebot,targetbot,macros,profiles}
  selection: Object.create(null)  // instanceId -> true (dashboard bulk selection)
};

function isAdmin() { return !!S.me && S.me.role === 'admin'; }

function indexInstances() {
  S.byId = Object.create(null);
  S.instances.forEach(function (i) { S.byId[i.id] = i; });
}

function pushCapped(arr, item, cap) {
  arr.push(item);
  if (arr.length > cap) arr.splice(0, arr.length - cap);
  return arr;
}

/* ---- paint scheduling -------------------------------------------
   With 20+ instances the hub pushes 20+ status frames a second. Doing a
   full re-render per frame is O(instances^2) work per second and the tab
   stops being interactive. Instead every frame marks its instance dirty
   and one requestAnimationFrame flush repaints only those rows.        */

var DIRTY = Object.create(null);
var dirtyAll = false;
var frame = null;

function markDirty(id) {
  if (id) DIRTY[id] = true; else dirtyAll = true;
  if (frame !== null) return;
  frame = -1;                      // "scheduling": see the guard below
  var handle = (window.requestAnimationFrame || function (fn) { return setTimeout(fn, 40); })(flush);
  /* If the scheduler ran flush() synchronously (a test harness, a polyfill),
     flush already cleared `frame`; storing the handle here would wedge the
     queue for good. Only record it when we are still the pending frame. */
  if (frame === -1) frame = handle;
}

function flush() {
  frame = null;
  var ids = dirtyAll ? null : Object.keys(DIRTY);
  DIRTY = Object.create(null);
  dirtyAll = false;
  try { renderRail(ids); } catch (e) { console.error(e); }
  if (currentView && currentView.update) { try { currentView.update(ids); } catch (e) { console.error(e); } }
}

/** Structural change (list membership, roles, route): repaint everything. */
function refresh() { markDirty(null); }

/* ============================ 7. charts ========================== */

/**
 * Minimal time-series renderer on a 2d canvas. No library.
 *  points: [{t:<ms>, ...}], key: field name, opts: {color, fill, min, max, fmt}
 */
function drawSeries(canvas, points, key, opts) {
  opts = opts || {};
  var dpr = window.devicePixelRatio || 1;
  var w = canvas.clientWidth || 260, hgt = canvas.clientHeight || 92;
  if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(hgt * dpr)) {
    canvas.width = Math.round(w * dpr); canvas.height = Math.round(hgt * dpr);
  }
  var g = canvas.getContext('2d');
  if (!g) return;
  g.setTransform(dpr, 0, 0, dpr, 0, 0);
  g.clearRect(0, 0, w, hgt);

  var pad = { l: 2, r: 2, t: 6, b: 10 };
  var iw = Math.max(1, w - pad.l - pad.r), ih = Math.max(1, hgt - pad.t - pad.b);

  // grid
  g.strokeStyle = '#1c2732'; g.lineWidth = 1;
  for (var gy = 0; gy <= 3; gy++) {
    var y = pad.t + (ih * gy) / 3 + 0.5;
    g.beginPath(); g.moveTo(pad.l, y); g.lineTo(pad.l + iw, y); g.stroke();
  }

  var vals = [];
  for (var i = 0; i < points.length; i++) {
    var v = points[i][key];
    vals.push(typeof v === 'number' && isFinite(v) ? v : null);
  }
  var has = vals.filter(function (v) { return v !== null; });
  if (has.length < 2) {
    g.fillStyle = '#5a6a7c'; g.font = '11px ui-monospace, monospace'; g.textAlign = 'center';
    g.fillText('collecting…', w / 2, hgt / 2 + 3);
    return;
  }

  var mn = opts.min !== undefined ? opts.min : Math.min.apply(null, has);
  var mx = opts.max !== undefined ? opts.max : Math.max.apply(null, has);
  if (mx - mn < 1e-9) { mx = mn + 1; mn = mn - 1; }
  var span = mx - mn;
  var X = function (i) { return pad.l + (iw * i) / (vals.length - 1); };
  var Y = function (v) { return pad.t + ih - ((v - mn) / span) * ih; };

  var color = opts.color || '#4c9aff';

  // area
  g.beginPath();
  var started = false, firstX = 0, lastX = 0;
  for (var a = 0; a < vals.length; a++) {
    if (vals[a] === null) continue;
    if (!started) { g.moveTo(X(a), Y(vals[a])); firstX = X(a); started = true; }
    else g.lineTo(X(a), Y(vals[a]));
    lastX = X(a);
  }
  g.lineTo(lastX, pad.t + ih);
  g.lineTo(firstX, pad.t + ih);
  g.closePath();
  var grad = g.createLinearGradient(0, pad.t, 0, pad.t + ih);
  grad.addColorStop(0, hexA(color, 0.30));
  grad.addColorStop(1, hexA(color, 0.02));
  g.fillStyle = grad; g.fill();

  // line
  g.beginPath(); started = false;
  for (var b = 0; b < vals.length; b++) {
    if (vals[b] === null) continue;
    if (!started) { g.moveTo(X(b), Y(vals[b])); started = true; }
    else g.lineTo(X(b), Y(vals[b]));
  }
  g.strokeStyle = color; g.lineWidth = 1.6; g.lineJoin = 'round'; g.stroke();

  // last point
  var lastI = vals.length - 1;
  while (lastI >= 0 && vals[lastI] === null) lastI--;
  if (lastI >= 0) {
    g.beginPath(); g.arc(X(lastI), Y(vals[lastI]), 2.6, 0, Math.PI * 2);
    g.fillStyle = color; g.fill();
  }

  // min / max labels
  var fmt = opts.fmt || short;
  g.font = '10px ui-monospace, monospace'; g.textAlign = 'left';
  g.fillStyle = '#5a6a7c';
  g.fillText(fmt(mx), pad.l + 2, pad.t + 8);
  g.fillText(fmt(mn), pad.l + 2, pad.t + ih - 1);

  // time span
  g.textAlign = 'right';
  var mins = Math.round((points[points.length - 1].t - points[0].t) / 60000);
  g.fillText('last ' + (mins || '<1') + ' min', pad.l + iw - 2, hgt - 1);
}

function hexA(hex, a) {
  var m = /^#?([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(hex);
  if (!m) return 'rgba(76,154,255,' + a + ')';
  return 'rgba(' + parseInt(m[1], 16) + ',' + parseInt(m[2], 16) + ',' + parseInt(m[3], 16) + ',' + a + ')';
}

function chartBox(label, color, key, opts) {
  var big = h('b', { text: '-' });
  var cv = h('canvas.chart', { 'aria-label': label + ' chart' });
  var box = h('div.chartbox', null,
    h('div.chead', null, h('span', { text: label }), big), cv);
  box.update = function (points, latest, fmt) {
    setText(big, fmt ? fmt(latest) : short(latest));
    drawSeries(cv, points, key, opts || { color: color });
  };
  return box;
}

/* ======================= 8. shared widgets ======================= */

function statePill(state) {
  return h('span.pill.' + state, null, h('i.dot'), txt(state));
}
function botPill(on) {
  return h('span.pill.' + (on ? 'on' : 'off'), null, h('i.dot'), txt(on ? 'bot on' : 'bot off'));
}
function barCell(kind, cur, max, label) {
  var fill = h('i', { style: { width: pct(cur, max).toFixed(1) + '%' } });
  var cap = h('span.cap', { text: label || (num(cur) + ' / ' + num(max)) });
  var wrap = h('div.barwrap', null,
    h('div.bar.' + kind, { role: 'progressbar', 'aria-valuenow': Math.round(pct(cur, max)),
                           'aria-valuemin': '0', 'aria-valuemax': '100' }, fill), cap);
  wrap.set = function (c, m, l) {
    var w = pct(c, m).toFixed(1) + '%';
    if (fill.style.width !== w) fill.style.width = w;
    setText(cap, l || (num(c) + ' / ' + num(m)));
  };
  return wrap;
}
function field(label, input, hint) {
  return h('label.field', null, h('span.lbl', { text: label }), input,
           hint ? h('div.hint', { text: hint }) : null);
}
function selectOf(items, value, mapper) {
  var sel = h('select');
  items.forEach(function (it) {
    var o = mapper ? mapper(it) : { value: it, label: String(it) };
    sel.appendChild(h('option', { value: o.value, text: o.label, selected: String(o.value) === String(value) }));
  });
  return sel;
}
function emptyBox(msg) { return h('div.empty', { text: msg }); }

/* ============================ 9. views =========================== */
/* Every view returns {el, update?(dirtyIds), onEvent?, destroy?}.      */

/* ---------- 9.1 dashboard ---------- */

function ViewDashboard() {
  var rows = Object.create(null);
  var tbody = h('tbody');
  var selAll = h('input', { type: 'checkbox', 'aria-label': 'Select all instances' });
  var countLbl = h('span.hint', { text: '' });

  selAll.addEventListener('change', function () {
    S.instances.forEach(function (i) {
      if (selAll.checked) S.selection[i.id] = true; else delete S.selection[i.id];
    });
    syncSelection();
  });

  function selected() { return Object.keys(S.selection).filter(function (id) { return S.byId[id]; }); }

  function syncSelection() {
    Object.keys(rows).forEach(function (id) {
      var r = rows[id];
      r.cb.checked = !!S.selection[id];
      r.tr.classList.toggle('sel', !!S.selection[id]);
    });
    var n = selected().length;
    setText(countLbl, n ? n + ' selected' : '');
    bulkBtns.forEach(function (b) { b.disabled = n === 0; });
    selAll.checked = n > 0 && n === S.instances.length;
    selAll.indeterminate = n > 0 && n < S.instances.length;
  }

  function bulk(label, kind, fn) {
    return h('button.btn.sm' + (kind ? '.' + kind : ''), { text: label, disabled: true,
      onclick: function () { fn(selected()); } });
  }

  var bulkBtns = [
    bulk('Start', 'primary', function (ids) { doStart(ids); }),
    bulk('Stop', null, function (ids) { confirmBulk('Stop', ids, function () { doStop(ids); }); }),
    bulk('Restart', null, function (ids) { confirmBulk('Restart', ids, function () { doRestart(ids); }); }),
    bulk('Bot on', null, function (ids) { doBot(ids, true); }),
    bulk('Bot off', null, function (ids) { doBot(ids, false); })
  ];

  var table = h('table.grid-table', null,
    h('thead', null, h('tr', null,
      h('th', { style: { width: '28px' } }, selAll),
      h('th', { text: 'Character' }),
      h('th', { text: 'State' }),
      h('th.right', { text: 'Lvl' }),
      h('th.right', { text: 'Exp/h' }),
      h('th.right', { text: 'Money/h' }),
      h('th', { text: 'HP' }),
      h('th', { text: 'Mana' }),
      h('th', { text: 'Target' }),
      h('th', { text: 'Waypoint' }),
      h('th.right', { text: 'Uptime' }),
      h('th', { text: '' })
    )), tbody);

  var el = h('div', null,
    h('div.view-head', null,
      h('h1', { text: 'Dashboard' }),
      h('span.spacer'),
      countLbl,
      h('div.row', null, bulkBtns),
      h('button.btn.sm', { text: 'Refresh', onclick: function () { loadInstances().then(function () { rebuild(); }); } })
    ),
    h('div.tablewrap', null, table),
    h('div.hint', { style: { marginTop: '8px' },
      text: 'Tip: click a character name to open its instance view. Bulk actions apply to the checked rows.' })
  );

  function makeRow(inst) {
    var cb = h('input', { type: 'checkbox', 'aria-label': 'Select ' + inst.characterName });
    cb.addEventListener('change', function () {
      if (cb.checked) S.selection[inst.id] = true; else delete S.selection[inst.id];
      syncSelection();
    });
    var nameBtn = h('button.linkish', { text: inst.characterName,
      onclick: function () { go('#/i/' + encodeURIComponent(inst.id) + '/overview'); } });
    var sub = h('div.hint', { text: '' });
    var stateTd = h('td');
    var lvl = h('td.num'), exph = h('td.num'), money = h('td.num');
    var hp = barCell('hp', 0, 1), mp = barCell('mana', 0, 1);
    var target = h('td', { text: '-' }), wp = h('td', { text: '-' }), up = h('td.num', { text: '-' });
    var act = h('td.nowrap');
    var tr = h('tr', null,
      h('td', null, cb),
      h('td', null, nameBtn, sub),
      stateTd, lvl, exph, money,
      h('td', null, hp), h('td', null, mp),
      target, wp, up, act);
    var r = { tr: tr, cb: cb, sub: sub, stateTd: stateTd, lvl: lvl, exph: exph, money: money,
              hp: hp, mp: mp, target: target, wp: wp, up: up, act: act, nameBtn: nameBtn,
              stateKey: '', actKey: '' };
    fillRow(r, inst);
    return r;
  }

  function fillRow(r, inst) {
    var L = inst.live || {};
    setText(r.nameBtn, inst.characterName);
    setText(r.sub, inst.world + (inst.proxyLabel ? ' · ' + inst.proxyLabel : ' · direct'));

    var key = inst.state + '/' + (inst.botEnabled ? '1' : '0');
    if (r.stateKey !== key) {                   // pills only rebuild when they change
      r.stateKey = key;
      clear(r.stateTd);
      r.stateTd.appendChild(statePill(inst.state));
      r.stateTd.appendChild(txt(' '));
      r.stateTd.appendChild(botPill(inst.botEnabled));
    }
    setText(r.lvl, L.level ? String(L.level) : '-');
    setText(r.exph, rate(L.expPerHour));
    setText(r.money, rate(L.moneyPerHour));
    r.hp.set(L.hp || 0, L.maxHp || 1, (L.hp || 0) + ' / ' + (L.maxHp || 0));
    r.mp.set(L.mana || 0, L.maxMana || 1, (L.mana || 0) + ' / ' + (L.maxMana || 0));
    setText(r.target, L.target || '-');
    setText(r.wp, L.waypoint
      ? L.waypoint + (L.waypointCount ? ' (' + L.waypointIndex + '/' + L.waypointCount + ')' : '')
      : '-');
    setText(r.up, inst.state === 'stopped' ? '-' : dur(L.uptimeMs));

    var running = inst.state !== 'stopped' && inst.state !== 'error';
    var actKey = running ? 'stop' : 'start';
    if (r.actKey !== actKey) {
      r.actKey = actKey;
      clear(r.act);
      r.act.appendChild(h('button.btn.sm', {
        text: running ? 'Stop' : 'Start',
        onclick: function () {
          if (running) confirmBulk('Stop', [inst.id], function () { doStop([inst.id]); });
          else doStart([inst.id]);
        }
      }));
    }
  }

  var emptyRow = null;

  /** full pass: membership + order + values */
  function rebuild() {
    if (emptyRow) { if (emptyRow.parentNode) tbody.removeChild(emptyRow); emptyRow = null; }
    var seen = Object.create(null);
    S.instances.forEach(function (inst, idx) {
      seen[inst.id] = true;
      var r = rows[inst.id];
      if (!r) r = rows[inst.id] = makeRow(inst);
      else fillRow(r, inst);
      var at = tbody.children[idx];
      if (at !== r.tr) tbody.insertBefore(r.tr, at || null);
    });
    Object.keys(rows).forEach(function (id) {
      if (!seen[id]) { if (rows[id].tr.parentNode) tbody.removeChild(rows[id].tr); delete rows[id]; }
    });
    if (!S.instances.length) {
      emptyRow = h('tr', null, h('td', { colspan: '12' },
        emptyBox('No instances yet. Create one from Characters & Accounts.')));
      tbody.appendChild(emptyRow);
    }
    syncSelection();
  }

  rebuild();
  return {
    el: el,
    /** dirtyIds === null means "something structural changed" */
    update: function (dirtyIds) {
      if (!dirtyIds) { rebuild(); return; }
      for (var i = 0; i < dirtyIds.length; i++) {
        var inst = S.byId[dirtyIds[i]], r = rows[dirtyIds[i]];
        if (inst && r) fillRow(r, inst);
        else { rebuild(); return; }
      }
    }
  };
}

function confirmBulk(what, ids, run) {
  if (ids.length <= 1) {
    var i = S.byId[ids[0]];
    Modal.confirm(what + ' instance', what + ' ' + (i ? i.characterName : ids[0]) + '?', run, what);
    return;
  }
  Modal.confirm(what + ' ' + ids.length + ' instances',
    what + ' all ' + ids.length + ' selected instances? Their characters go offline.', run, what + ' all');
}

/* ---------- 9.2 instance ---------- */

function ViewInstance(params) {
  var id = params.id;
  var inst = S.byId[id];
  if (!inst) {
    return { el: h('div', null, h('div.view-head', null, h('h1', { text: 'Instance' })),
                   emptyBox('No instance with id ' + id + ' (or you cannot see it).')) };
  }

  var tabName = params.tab || readTab(id) || 'overview';
  var TABS = [['overview', 'Overview'], ['bot', 'Bot'], ['config', 'Bot Config'],
              ['console', 'Console'], ['chat', 'Chat']];
  var pane = h('div');
  var sub = null;

  var titleState = h('span'), titleBot = h('span');
  var head = h('div.view-head', null,
    h('h1', { text: inst.characterName }),
    h('h2', { text: inst.world + ' · ' + (inst.accountLabel || '?') +
                    ' · ' + (inst.proxyLabel || 'direct') }),
    titleState, titleBot,
    h('span.spacer'),
    h('button.btn.sm.primary', { text: 'Start', onclick: function () { doStart([id]); } }),
    h('button.btn.sm', { text: 'Stop', onclick: function () {
      confirmBulk('Stop', [id], function () { doStop([id]); }); } }),
    h('button.btn.sm', { text: 'Restart', onclick: function () {
      confirmBulk('Restart', [id], function () { doRestart([id]); }); } }),
    h('button.btn.sm', { text: 'Toggle bot', onclick: function () { doBot([id], !S.byId[id].botEnabled); } }),
    h('button.btn.sm.danger', { text: 'Delete', onclick: function () {
      var i = S.byId[id] || inst;
      Modal.confirm('Delete instance',
        'Delete the instance for ' + i.characterName + '? The worker is stopped and its ' +
        'configuration is removed from the hub. The character itself is kept.',
        function () {
          api.call('instances.delete', { id: id })
            .then(function () { Toast.ok('Instance deleted'); return loadInstances(); })
            .then(function () { go('#/dashboard'); refresh(); })
            .catch(function (e) { failed('Delete instance', e); });
        }, 'Delete');
    } })
  );

  var tabbar = h('div.tabs', { role: 'tablist' });
  TABS.forEach(function (t) {
    tabbar.appendChild(h('button', {
      role: 'tab', id: 'tab-' + t[0], text: t[1],
      'aria-selected': String(t[0] === tabName),
      onclick: function () { go('#/i/' + encodeURIComponent(id) + '/' + t[0]); }
    }));
  });

  var stateKey = '';
  function setTitle() {
    var i = S.byId[id] || inst;
    var key = i.state + '/' + (i.botEnabled ? '1' : '0');
    if (key === stateKey) return;
    stateKey = key;
    clear(titleState); titleState.appendChild(statePill(i.state));
    clear(titleBot); titleBot.appendChild(botPill(i.botEnabled));
  }
  setTitle();

  /* only the open tab needs the log / chat firehose */
  ws.subscribe(tabName === 'console' ? id : null, tabName === 'chat' ? id : null);

  if (tabName === 'bot') sub = TabBot(id);
  else if (tabName === 'config') sub = TabBotConfig(id);
  else if (tabName === 'console') sub = TabConsole(id);
  else if (tabName === 'chat') sub = TabChat(id);
  else sub = TabOverview(id);
  pane.appendChild(sub.el);
  writeTab(id, tabName);

  return {
    el: h('div', null, head, tabbar, pane),
    update: function (dirty) { setTitle(); if (sub.update) sub.update(dirty); },
    onEvent: function (ev, data) { setTitle(); if (sub.onEvent) sub.onEvent(ev, data); },
    destroy: function () { ws.subscribe(null, null); if (sub.destroy) sub.destroy(); }
  };
}

function readTab(id) { try { return localStorage.getItem('panel.tab.' + id); } catch (e) { return null; } }
function writeTab(id, t) { try { localStorage.setItem('panel.tab.' + id, t); } catch (e) {} }

/* --- Overview --- */

function TabOverview(id) {
  var stats = {};
  function stat(key, label, cls) {
    var v = h('div.v' + (cls ? '.' + cls : ''), { text: '-' });
    stats[key] = v;
    return h('div.stat', null, h('div.k', { text: label }), v);
  }

  var hp = barCell('hp', 0, 1), mp = barCell('mana', 0, 1), xp = barCell('exp', 0, 100);

  var chExp   = chartBox('exp / h', '#a371f7', 'expPerHour', { color: '#a371f7' });
  var chMoney = chartBox('money / h', '#d29922', 'moneyPerHour', { color: '#d29922' });
  var chHp    = chartBox('hp %', '#e05561', 'hpPercent', { color: '#e05561', min: 0, max: 100 });
  var chKills = chartBox('kills / h', '#39c5cf', 'killsPerHour', { color: '#39c5cf' });

  var kv = h('dl.kv');
  var supplies = h('div');

  var el = h('div', null,
    h('div.card', null, h('h3', { text: 'Live' }),
      h('div.statgrid', null,
        stat('level', 'Level'),
        stat('exph', 'Exp / h'),
        stat('moneyh', 'Money / h'),
        stat('looth', 'Loot / h'),
        stat('wasteh', 'Waste / h'),
        stat('balance', 'Balance / h'),
        stat('killsh', 'Kills / h'),
        stat('deaths', 'Deaths'))),
    h('div.grid.c3', null,
      h('div.card', null, h('h3', { text: 'Vitals' }),
        h('div.row', { style: { gap: '16px' } }, hp, mp, xp)),
      h('div.card', null, h('h3', { text: 'Session' }), kv),
      h('div.card', null, h('h3', { text: 'Supplies' }), supplies)),
    h('div.grid.c2', null,
      h('div.card', null, chExp),
      h('div.card', null, chMoney),
      h('div.card', null, chHp),
      h('div.card', null, chKills))
  );

  var loaded = false;
  api.call('instances.history', { id: id }).then(function (r) {
    S.history[id] = r.points || [];
    loaded = true; update();
  }).catch(function (e) { failed('History', e); });

  /* the charts are the expensive part: repaint them at most twice a second */
  var lastChart = 0;

  function update() {
    var i = S.byId[id]; if (!i) return;
    var L = i.live || {};
    setText(stats.level, L.level ? String(L.level) : '-');
    setText(stats.exph, rate(L.expPerHour));
    setText(stats.moneyh, rate(L.moneyPerHour));
    setText(stats.looth, rate(L.lootPerHour));
    setText(stats.wasteh, rate(L.wastePerHour));
    setText(stats.balance, rate(L.balancePerHour));
    stats.balance.className = 'v ' + ((L.balancePerHour || 0) >= 0 ? 'pos' : 'neg');
    setText(stats.killsh, L.killsPerHour === undefined ? '-' : (Math.round(L.killsPerHour * 10) / 10));
    setText(stats.deaths, L.deaths === undefined ? '-' : String(L.deaths));

    hp.set(L.hp || 0, L.maxHp || 1, (L.hp || 0) + ' / ' + (L.maxHp || 0) + ' hp');
    mp.set(L.mana || 0, L.maxMana || 1, (L.mana || 0) + ' / ' + (L.maxMana || 0) + ' mana');
    xp.set(L.expPercent || 0, 100, 'lvl ' + (L.level || '?') + ' · ' + (L.expPercent || 0).toFixed(1) + '%');

    clear(kv);
    [['State', i.state],
     ['Bot', i.botEnabled ? 'enabled' : 'disabled'],
     ['Uptime', dur(L.uptimeMs)],
     ['Online', dur(L.onlineMs)],
     ['Reconnects', String(L.reconnects === undefined ? '-' : L.reconnects)],
     ['Position', posStr(L.pos)],
     ['Target', L.target || '-'],
     ['Waypoint', L.waypoint ? L.waypoint + ' (' + L.waypointIndex + '/' + L.waypointCount + ')' : '-'],
     ['Experience', num(L.exp)],
     ['Capacity', L.cap === undefined ? '-' : num(L.cap) + ' / ' + num(L.maxCap)],
     ['Soul / stam', (L.soul === undefined ? '-' : L.soul) + ' / ' + (L.stamina === undefined ? '-' : Math.floor(L.stamina / 60) + 'h')],
     ['Cavebot', i.cavebotConfig || '-'],
     ['Targetbot', i.targetbotConfig || '-']
    ].forEach(function (p) { kv.appendChild(h('dt', { text: p[0] })); kv.appendChild(h('dd', { text: p[1] })); });

    clear(supplies);
    /* Defensive: a worker that reports supplies in some other shape must make the
       column say "no supply data", never take the whole Overview down with it. */
    var sup = Array.isArray(L.supplies) ? L.supplies : [];
    if (!sup.length) supplies.appendChild(h('div.hint', { text: 'no supply data' }));
    sup.forEach(function (s) {
      var low = s.count < s.min;
      supplies.appendChild(h('div', { style: { marginBottom: '7px' } },
        h('div.row', null, h('span.grow', { text: s.name }),
          h('span.mono', { text: s.count + ' / ' + s.min })),
        h('div.bar.sup' + (low ? '.low' : ''), null,
          h('i', { style: { width: pct(s.count, Math.max(s.min * 2, s.count, 1)).toFixed(0) + '%' } }))));
    });

    var t = Date.now();
    if (loaded && t - lastChart > 500) {
      lastChart = t;
      var pts = S.history[id] || [];
      chExp.update(pts, L.expPerHour);
      chMoney.update(pts, L.moneyPerHour);
      chHp.update(pts, pct(L.hp, L.maxHp), function (v) { return Math.round(v) + '%'; });
      chKills.update(pts, L.killsPerHour, function (v) { return (Math.round(v * 10) / 10) + ''; });
    }
  }

  update();
  return { el: el, update: update };
}

/* --- Bot --- */

function TabBot(id) {
  var inst = S.byId[id];
  var body = h('div', null, h('div.hint', { text: 'Loading bot configuration…' }));
  var el = h('div', null, body);

  function load() {
    api.call('instances.configs', { id: id }).then(function (cfg) {
      S.configs[id] = cfg;
      render(cfg);
    }).catch(function (e) {
      clear(body);
      body.appendChild(emptyBox('Could not read the bot configuration: ' + e.message));
      failed('Bot configuration', e);
    });
  }

  function render(cfg) {
    var i = S.byId[id] || inst;
    clear(body);

    var cave = selectOf([''].concat(cfg.cavebot || []), i.cavebotConfig,
      function (n) { return { value: n, label: n || '(none)' }; });
    var targ = selectOf([''].concat(cfg.targetbot || []), i.targetbotConfig,
      function (n) { return { value: n, label: n || '(none)' }; });
    var prof = selectOf(cfg.profiles || [i.botProfile], i.botProfile,
      function (n) { return { value: n, label: n }; });

    cave.addEventListener('change', function () {
      optimistic(i, { cavebotConfig: cave.value },
        'instances.update', { id: id, cavebotConfig: cave.value }, 'Cavebot config');
    });
    targ.addEventListener('change', function () {
      optimistic(i, { targetbotConfig: targ.value },
        'instances.update', { id: id, targetbotConfig: targ.value }, 'Targetbot config');
    });
    prof.addEventListener('change', function () {
      optimistic(i, { botProfile: prof.value },
        'instances.update', { id: id, botProfile: prof.value }, 'Bot profile');
    });

    var macros = h('div');
    (cfg.macros || []).forEach(function (m) {
      var cb = h('input', { type: 'checkbox', checked: !!m.on });
      cb.addEventListener('change', function () {
        var want = cb.checked;
        cb.disabled = true;
        api.call('instances.macro', { id: id, name: m.name, on: want })
          .then(function () { m.on = want; })
          .catch(function (e) { cb.checked = !want; failed('Macro ' + m.name, e); })
          .then(function () { cb.disabled = false; });
      });
      macros.appendChild(h('div', { style: { marginBottom: '5px' } },
        h('label.check', null, cb, txt(m.label || m.name),
          m.hotkey ? h('span.tag', { text: m.hotkey }) : null)));
    });
    if (!(cfg.macros || []).length) macros.appendChild(h('div.hint', { text: 'no macros reported' }));

    var assigned = h('div');
    function renderAssigned() {
      clear(assigned);
      var ids = (S.byId[id] || i).scripts || [];
      if (!ids.length) assigned.appendChild(h('div.hint', { text: 'no scripts assigned' }));
      ids.forEach(function (sid) {
        var sc = S.scripts.filter(function (x) { return x.id === sid; })[0];
        assigned.appendChild(h('div.row', { style: { marginBottom: '4px' } },
          h('span.grow.mono', { text: sc ? sc.name : sid }),
          h('button.btn.sm', { text: 'Unassign', onclick: function () {
            Modal.confirm('Unassign script',
              'Stop running ' + (sc ? sc.name : sid) + ' on ' + i.characterName + '?', function () {
                var next = ids.filter(function (x) { return x !== sid; });
                optimistic(S.byId[id], { scripts: next }, 'instances.update',
                  { id: id, scripts: next }, 'Unassign script')
                  .then(renderAssigned);
              }, 'Unassign');
          } })));
      });
    }
    renderAssigned();

    var autoStart = h('input', { type: 'checkbox', checked: !!i.autoStart });
    var autoRelog = h('input', { type: 'checkbox', checked: !!i.autoRelogin });
    autoStart.addEventListener('change', function () {
      optimistic(i, { autoStart: autoStart.checked }, 'instances.update',
        { id: id, autoStart: autoStart.checked }, 'Auto-start');
    });
    autoRelog.addEventListener('change', function () {
      optimistic(i, { autoRelogin: autoRelog.checked }, 'instances.update',
        { id: id, autoRelogin: autoRelog.checked }, 'Auto-relogin');
    });

    body.appendChild(h('div.grid.c2', null,
      h('div.card', null, h('h3', { text: 'Configuration' }),
        field('Bot profile', prof),
        field('Cavebot config', cave, 'Files from cavebot_configs/ on the worker.'),
        field('Targetbot config', targ, 'Files from targetbot_configs/.'),
        h('div.row', null,
          h('label.check', null, autoStart, txt('Auto-start with the hub')),
          h('label.check', null, autoRelog, txt('Auto-relogin on disconnect'))),
        h('div.row', { style: { marginTop: '12px' } },
          h('button.btn.sm', { text: 'Reload bot', onclick: function () {
            api.call('instances.reload', { id: id })
              .then(function () { Toast.ok('Bot reloaded'); load(); })
              .catch(function (e) { failed('Reload', e); });
          } }),
          h('button.btn.sm', { text: 'Reread configs', onclick: load }))),
      h('div.card', null, h('h3', { text: 'Macros' }), macros),
      h('div.card', null, h('h3', { text: 'Assigned scripts' }), assigned,
        h('div.row', { style: { marginTop: '10px' } },
          h('button.btn.sm', { text: 'Assign a script…', onclick: function () { assignDialog(id, renderAssigned); } }),
          h('button.btn.sm.ghost', { text: 'Manage scripts', onclick: function () { go('#/scripts'); } })),
        h('div.warnbox', { style: { marginTop: '10px' },
          text: 'Uploaded scripts are arbitrary Lua running inside the worker with full bot privileges. ' +
                'They are not sandboxed. Every upload and execution is written to the audit log.' }))
    ));
  }

  load();
  return { el: el };
}

function assignDialog(instanceId, done) {
  var boxes = [];
  var list = h('div');
  var current = (S.byId[instanceId] || {}).scripts || [];
  if (!S.scripts.length) list.appendChild(h('div.hint', { text: 'No scripts uploaded yet.' }));
  S.scripts.forEach(function (sc) {
    var cb = h('input', { type: 'checkbox', checked: current.indexOf(sc.id) >= 0 });
    boxes.push({ cb: cb, id: sc.id });
    list.appendChild(h('div', null, h('label.check', null, cb, txt(sc.name),
      h('span.tag', { text: sc.size + ' B' }))));
  });
  Modal.open({
    title: 'Assign scripts',
    body: list,
    onsubmit: function (close) {
      var next = boxes.filter(function (b) { return b.cb.checked; }).map(function (b) { return b.id; });
      api.call('instances.update', { id: instanceId, scripts: next })
        .then(function (r) { mergeInstance(r.instance); close(); if (done) done(); Toast.ok('Scripts assigned'); })
        .catch(function (e) { failed('Assign', e); });
    },
    actions: [{ label: 'Cancel' }, { label: 'Save', kind: 'primary', submit: true }]
  });
}

/* --- Console --- */

function TabConsole(id) {
  var box = h('div.logbox', { tabindex: '0', role: 'log', 'aria-label': 'Worker log' });
  var follow = h('input', { type: 'checkbox', checked: true });
  var filter = h('input', { type: 'search', placeholder: 'filter…' });
  var level = selectOf(['debug', 'info', 'warn', 'error'], 'debug',
    function (v) { return { value: v, label: '≥ ' + v }; });
  var code = h('textarea', { rows: '3', spellcheck: 'false',
    placeholder: 'return player:getLevel()      -- Ctrl+Enter to run' });
  var runBtn = h('button.btn.primary', { text: 'Run' });

  var LEVELS = { debug: 0, info: 1, warn: 2, error: 3 };

  function lineNode(l) {
    return h('div.ln', null,
      h('span.t', { text: clockOf(l.t) }),
      h('span.lv.' + (l.level || 'info'), { text: l.level || 'info' }),
      h('span.msg' + (l.kind ? '.' + l.kind : ''), { text: l.text }));
  }
  function visible(l) {
    if (LEVELS[l.level || 'info'] < LEVELS[level.value]) return false;
    var q = filter.value.trim().toLowerCase();
    return !q || String(l.text).toLowerCase().indexOf(q) >= 0;
  }
  function redraw() {
    clear(box);
    (S.logs[id] || []).filter(visible).forEach(function (l) { box.appendChild(lineNode(l)); });
    if (follow.checked) box.scrollTop = box.scrollHeight;
  }
  filter.addEventListener('input', redraw);
  level.addEventListener('change', redraw);

  api.call('instances.logs', { id: id, limit: 400 }).then(function (r) {
    S.logs[id] = r.lines || [];
    redraw();
  }).catch(function (e) { failed('Log fetch', e); });

  function run() {
    var src = code.value;
    if (!src.trim()) return;
    runBtn.disabled = true;
    pushCapped(S.logs[id] || (S.logs[id] = []),
      { t: Date.now(), level: 'info', kind: 'echo', text: '> ' + src.replace(/\n/g, '\n  ') }, 2000);
    redraw();
    api.call('instances.exec', { id: id, code: src }, { timeoutMs: 30000 }).then(function (r) {
      pushCapped(S.logs[id], { t: Date.now(), level: 'info', kind: 'ret',
        text: r.output === undefined || r.output === null ? '(no value)' : String(r.output) }, 2000);
      code.value = '';
    }).catch(function (e) {
      pushCapped(S.logs[id], { t: Date.now(), level: 'error', text: e.message }, 2000);
      failed('exec', e);
    }).then(function () { runBtn.disabled = false; redraw(); });
  }
  runBtn.addEventListener('click', run);
  code.addEventListener('keydown', function (e) {
    if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) { e.preventDefault(); run(); }
  });

  var el = h('div', null,
    h('div.card', null,
      h('div.row', { style: { marginBottom: '8px' } },
        h('h3', { text: 'Worker log', style: { margin: '0' } }),
        h('span.spacer'),
        h('div', { style: { width: '110px', flex: '0 0 auto' } }, level),
        h('div', { style: { width: '180px', flex: '0 0 auto' } }, filter),
        h('label.check', null, follow, txt('follow')),
        h('button.btn.sm', { text: 'Clear', onclick: function () { S.logs[id] = []; redraw(); } })),
      box),
    (S.me && S.me.canExec === false)
      ? h('div.card', null, h('h3', { text: 'Execute Lua in the worker' }),
          h('div.warnbox', { text: 'Running Lua in a worker is administrator-only on this hub. ' +
            'The code would run unsandboxed under the hub’s own user account, so an ' +
            'administrator has to grant this account the remote-Lua capability first.' }))
      : h('div.card', null, h('h3', { text: 'Execute Lua in the worker' }),
      h('div.warnbox', { text: 'This runs with the bot’s full privileges inside the worker process — ' +
        'unsandboxed, under the hub’s own user account. ' +
        'The code, the actor and the result are recorded in the admin audit log.' }),
      code,
      h('div.row', { style: { marginTop: '8px' } }, runBtn,
        h('span.hint', { text: 'Ctrl+Enter runs.' })))
  );

  return {
    el: el,
    onEvent: function (ev, data) {
      if (ev === 'log' && data && data.id === id) {
        pushCapped(S.logs[id] || (S.logs[id] = []), data, 2000);
        if (visible(data)) { box.appendChild(lineNode(data)); if (follow.checked) box.scrollTop = box.scrollHeight; }
      }
    }
  };
}

/* --- Chat --- */

function TabChat(id) {
  var box = h('div.logbox', { tabindex: '0', role: 'log', 'aria-label': 'Game chat' });
  var input = h('input', { type: 'text', placeholder: 'say something…', maxlength: '255' });
  var chan = selectOf(
    [{ id: 0, name: 'Default' }, { id: 3, name: 'Local Chat' }, { id: 5, name: 'Advertising' },
     { id: 65535, name: 'Party' }],
    0, function (c) { return { value: c.id, label: c.name }; });

  function lineNode(m) {
    return h('div.ln', null,
      h('span.t', { text: clockOf(m.t) }),
      h('span.lv', { text: m.channel || '' }),
      h('span.msg', null, h('span.who', { text: (m.from || '?') + ': ' }), txt(m.text)));
  }
  function redraw() {
    clear(box);
    (S.chats[id] || []).forEach(function (m) { box.appendChild(lineNode(m)); });
    box.scrollTop = box.scrollHeight;
  }

  api.call('instances.chat', { id: id, limit: 300 }).then(function (r) {
    S.chats[id] = r.messages || []; redraw();
  }).catch(function (e) { failed('Chat fetch', e); });

  function send() {
    var t = input.value.trim();
    if (!t) return;
    input.value = '';
    api.call('instances.say', { id: id, channel: Number(chan.value), text: t })
      .catch(function (e) { failed('Say', e); input.value = t; });
  }
  input.addEventListener('keydown', function (e) { if (e.key === 'Enter') { e.preventDefault(); send(); } });

  var el = h('div.card', null,
    h('h3', { text: 'Chat' }), box,
    h('div.row', { style: { marginTop: '8px' } },
      h('div', { style: { width: '150px' } }, chan),
      h('div.grow', null, input),
      h('button.btn.primary', { text: 'Send', onclick: send })));

  return {
    el: el,
    onEvent: function (ev, data) {
      if (ev === 'chat' && data && data.id === id) {
        pushCapped(S.chats[id] || (S.chats[id] = []), data, 500);
        box.appendChild(lineNode(data)); box.scrollTop = box.scrollHeight;
      }
    }
  };
}

/* ==================================================================
   9.2b Bot Config (CONFIGAPI.md)
   ------------------------------------------------------------------
   Six card editors -- Healing (itemTable/spellTable), Conditions,
   Attack (attackTable), Stances, Targeting (+ looting), CaveBot
   (waypoints). Each card GETs its kind on tab open, edits an in-memory
   copy of `data`, Saves by PUTting the whole kind, and Reverts by
   re-fetching. A row keeps every key the server sent -- only the
   fields a control is bound to are ever touched -- so a field this
   editor does not know about still round-trips unchanged, per
   CONFIGAPI.md's compatibility acceptance rule.
   ================================================================== */

/** Mirrors the Console/Scripts tabs' own check, verbatim -- one
 *  capability flag, never a second one. */
function hasExec() { return !(S.me && S.me.canExec === false); }

function nf(value, w) {
  return h('input', { type: 'number', step: 'any',
    value: (value === undefined || value === null) ? '' : value, style: { width: (w || '64px') } });
}
function cf(checked) { return h('input', { type: 'checkbox', checked: !!checked }); }
function tf(value, w, placeholder) {
  return h('input', { type: 'text', value: (value === undefined || value === null) ? '' : value,
    placeholder: placeholder || '', style: { width: (w || '140px') } });
}
function taInput(value, rows, w) {
  return h('textarea', { rows: String(rows || 3), spellcheck: 'false',
    style: { width: (w || '100%'), fontSize: '12px' }, value: value === undefined ? '' : value });
}
function bindChk(el, obj, key) { el.addEventListener('change', function () { obj[key] = el.checked; }); return el; }

function numF(row, key, label, w) {
  var el = nf(row[key], w);
  el.addEventListener('change', function () {
    var v = el.value === '' ? 0 : Number(el.value);
    row[key] = isNaN(v) ? 0 : v;
  });
  return field(label, el);
}
function chkF(row, key, label, onToggle) {
  var el = cf(row[key]);
  el.addEventListener('change', function () { row[key] = el.checked; if (onToggle) onToggle(el.checked); });
  return h('label.check', { style: { marginBottom: '8px' } }, el, txt(label));
}
function txtF(row, key, label, w, placeholder) {
  var el = tf(row[key], w, placeholder);
  el.addEventListener('change', function () { row[key] = el.value; });
  return field(label, el);
}
/** options: [{value, label}] with `value` already the right TYPE (number or string) --
 *  a <select>'s own .value is always a string, so the change handler looks the
 *  original option back up rather than trusting sel.value directly. */
function enumF(row, key, label, options) {
  var sel = selectOf(options, row[key], function (o) { return o; });
  sel.addEventListener('change', function () {
    var hit = options.filter(function (o) { return String(o.value) === sel.value; })[0];
    row[key] = hit ? hit.value : sel.value;
  });
  return field(label, sel);
}

/** The `true | [names...]` monster filter shared by attackbot entries and
 *  stance entries: a checkbox for "any creature" plus a comma-separated
 *  names box that is only live when it is unchecked. */
function monsterFilterF(row, key) {
  var isAny = row[key] === true;
  var any = cf(isAny);
  var names = tf(Array.isArray(row[key]) ? row[key].join(', ') : '', '220px', 'comma-separated names');
  names.disabled = isAny;
  function fromText() {
    return names.value.split(',').map(function (s) { return s.trim().toLowerCase(); }).filter(Boolean);
  }
  any.addEventListener('change', function () {
    names.disabled = any.checked;
    row[key] = any.checked ? true : fromText();
  });
  names.addEventListener('change', function () { if (!any.checked) row[key] = fromText(); });
  return h('div', { style: { marginBottom: '8px' } },
    h('label.check', { style: { marginBottom: '4px' } }, any, txt('any creature')),
    field('Monster names', names));
}

/**
 * Generic list-of-entries editor over `rows`, mutated in place.
 * opts: { makeRow(row,i,redraw)->Node, newRow()->row, reorder:bool, orderNote,
 *         addLabel, rowTitle(row,i)->string, emptyText, canDuplicate(row)->bool }
 */
function listEditor(rows, opts) {
  var list = h('div.cfglist');
  function redraw() {
    clear(list);
    if (!rows.length) list.appendChild(h('div.hint', { text: opts.emptyText || 'No entries yet.' }));
    rows.forEach(function (row, i) {
      var canDup = !opts.canDuplicate || opts.canDuplicate(row);
      var up = h('button.btn.sm', { text: '↑', title: 'Move up', disabled: i === 0,
        onclick: function () { var t = rows[i - 1]; rows[i - 1] = rows[i]; rows[i] = t; redraw(); } });
      var down = h('button.btn.sm', { text: '↓', title: 'Move down', disabled: i === rows.length - 1,
        onclick: function () { var t = rows[i + 1]; rows[i + 1] = rows[i]; rows[i] = t; redraw(); } });
      var dup = h('button.btn.sm', { text: 'Duplicate', disabled: !canDup,
        onclick: function () { rows.splice(i + 1, 0, JSON.parse(JSON.stringify(row))); redraw(); } });
      var del = h('button.btn.sm.danger', { text: 'Remove',
        onclick: function () { rows.splice(i, 1); redraw(); } });
      var head = h('div.row', { style: { marginBottom: '6px' } },
        h('span.cfghead', { text: opts.rowTitle ? opts.rowTitle(row, i) : ('#' + (i + 1)) }),
        h('span.spacer'),
        opts.reorder ? up : null, opts.reorder ? down : null, dup, del);
      list.appendChild(h('div.cfgrow', null, head, opts.makeRow(row, i, redraw)));
    });
  }
  redraw();
  var addBtn = h('button.btn.sm', { text: opts.addLabel || '+ Add row',
    onclick: function () { rows.push(opts.newRow()); redraw(); } });
  return {
    el: h('div', null,
      opts.orderNote ? h('div.hint', { style: { marginBottom: '8px' }, text: opts.orderNote }) : null,
      list,
      h('div.row', { style: { marginTop: '8px' } }, addBtn)),
    redraw: redraw
  };
}

/** One card: header (title, source badge, active-profile hint, Revert, Save),
 *  a lazily-GETted body built by `buildEditor(data, ctx) -> {el, getData()}`,
 *  and a 400 -> inline warnbox + toast on Save. Independent of every other
 *  card: its own load() promise, never awaited by the tab that hosts it. */
function configCard(id, kind, title, buildEditor) {
  var sourceTag = h('span.tag', { text: '' });
  var listHint = h('span.hint');
  var saveBtn = h('button.btn.sm.primary', { text: 'Save' });
  var revertBtn = h('button.btn.sm', { text: 'Revert' });
  var errBox = h('div');
  var body = h('div', null, h('div.hint', { text: 'Loading ' + title + '…' }));
  var card = h('div.card', null,
    h('div.cfgcard-foot', null,
      h('h3', { text: title, style: { margin: '0' } }), sourceTag, listHint, h('span.spacer'),
      revertBtn, saveBtn),
    errBox, body);

  var editor = null, lastEditable = true;

  api.call('config.list', { id: id, kind: kind }).then(function (r) {
    var names = r.names || [];
    listHint.textContent = names.length ? ('active: ' + r.active + ' (' + names.length + ' known)') : '';
  }).catch(function () { listHint.textContent = ''; });

  function load() {
    saveBtn.disabled = true;
    clear(errBox);
    clear(body);
    body.appendChild(h('div.hint', { text: 'Loading ' + title + '…' }));
    return api.call('config.get', { id: id, kind: kind }).then(function (r) {
      clear(body);
      sourceTag.className = 'tag' + (r.source === 'default' ? ' default' : '');
      sourceTag.textContent = r.source === 'default' ? 'new / default' : 'from profile';
      lastEditable = r.editable !== false;
      editor = buildEditor(r.data, { instanceId: id, kind: kind });
      body.appendChild(editor.el);
      saveBtn.disabled = !lastEditable;
    }).catch(function (e) {
      clear(body);
      body.appendChild(emptyBox('Could not load ' + title.toLowerCase() + ': ' + e.message));
      failed(title, e);
    });
  }

  saveBtn.addEventListener('click', function () {
    if (!editor) return;
    saveBtn.disabled = true;
    clear(errBox);
    api.call('config.set', { id: id, kind: kind, data: editor.getData() }).then(function () {
      Toast.ok(title + ' saved');
      return load();
    }).catch(function (e) {
      if (e && e.code === 'bad-request') {
        errBox.appendChild(h('div.warnbox', { text: 'Not saved: ' + e.message }));
      }
      failed('Save ' + title, e);
      saveBtn.disabled = !lastEditable;
    });
  });
  revertBtn.addEventListener('click', load);

  load();
  return card;
}

/* ---- Healing: itemTable + spellTable (bot/healbot.lua) ---- */
function buildHealbotEditor(data) {
  data.itemTable = Array.isArray(data.itemTable) ? data.itemTable : [];
  data.spellTable = Array.isArray(data.spellTable) ? data.spellTable : [];

  var ORIGINS = ['HP%', 'HP', 'MP%', 'MP', 'burst'].map(function (v) { return { value: v, label: v }; });
  var SIGNS = [
    { value: '<', label: '< or = (inclusive)' },
    { value: '>', label: '> or = (inclusive)' },
    { value: '=', label: '= exactly' }
  ];

  var items = listEditor(data.itemTable, {
    reorder: true, addLabel: '+ Add item rule',
    orderNote: 'Array order = priority. The first ENABLED rule whose condition matches uses an item; ' +
      'one item use per 100 ms tick.',
    emptyText: 'No item rules yet.',
    rowTitle: function (row) { return 'Item ' + (row.item || '—'); },
    newRow: function () {
      return { enabled: true, origin: 'HP%', sign: '<', value: 50, item: 0, index: data.itemTable.length + 1 };
    },
    makeRow: function (row) {
      return h('div', null,
        chkF(row, 'enabled', 'Enabled'),
        h('div.row', null,
          enumF(row, 'origin', 'Trigger on', ORIGINS),
          enumF(row, 'sign', 'Comparison', SIGNS),
          numF(row, 'value', 'Threshold', '80px'),
          numF(row, 'item', 'Item id', '90px'),
          numF(row, 'index', 'Index (widget only)', '70px')));
    }
  });

  var spells = listEditor(data.spellTable, {
    reorder: true, addLabel: '+ Add spell rule',
    orderNote: 'Array order = priority. The first ENABLED rule whose condition matches casts; ' +
      'one spell cast per 50 ms tick.',
    emptyText: 'No spell rules yet.',
    rowTitle: function (row) { return row.spell || '—'; },
    newRow: function () {
      return { enabled: true, origin: 'HP%', sign: '<', value: 50, spell: '', cost: 0,
        index: data.spellTable.length + 1 };
    },
    makeRow: function (row) {
      return h('div', null,
        chkF(row, 'enabled', 'Enabled'),
        h('div.row', null,
          enumF(row, 'origin', 'Trigger on', ORIGINS),
          enumF(row, 'sign', 'Comparison', SIGNS),
          numF(row, 'value', 'Threshold', '80px'),
          txtF(row, 'spell', 'Spell words', '160px'),
          numF(row, 'cost', 'Mana cost', '80px'),
          numF(row, 'index', 'Index (widget only)', '70px')));
    }
  });

  return {
    el: h('div', null,
      h('div.cfggroup', { text: 'Spells (spellTable) — checked every 50 ms' }), spells.el,
      h('div.cfggroup', { text: 'Items (itemTable) — checked every 100 ms' }), items.el),
    /* bot/configschema.lua's `healbot` kind is `top = 'object'` with EXACTLY
       these two fields (rejectUnknown at the top level) -- unlike an entry's
       own fields, an extra top-level key here (e.g. the profile's `name`/
       `enabled`/`Visible`) is REJECTED, not tolerated. Emit only the two. */
    getData: function () { return { itemTable: data.itemTable, spellTable: data.spellTable }; }
  };
}

/* ---- Conditions: the ConditionPanel block (bot/healbot.lua) ---- */
function buildConditionsEditor(data) {
  var d = data;
  var DEF = { enabled: false, curePosion: false, poisonCost: 20, cureCurse: false, curseCost: 80,
    cureBleed: false, bleedCost: 45, cureBurn: false, burnCost: 30, cureElectrify: false, electrifyCost: 22,
    cureParalyse: false, paralyseCost: 40, paralyseSpell: 'utani hur', holdHaste: false, hasteCost: 40,
    hasteSpell: 'utani hur', holdUtamo: false, utamoCost: 40, holdUtana: false, utanaCost: 440,
    holdUtura: false, uturaType: '', uturaCost: 100, ignoreInPz: true, stopHaste: false };
  Object.keys(DEF).forEach(function (k) { if (d[k] === undefined) d[k] = DEF[k]; });

  /* curePoison / curePosion compat, per CONFIGAPI.md: read curePoison, falling
     back to the misspelled curePosion; always WRITE curePoison, and keep
     curePosion in sync only when the loaded file already carried it.
     bot/configschema.lua makes curePoison REQUIRED -- fix it up to a real
     boolean right here, not only inside the checkbox's change handler, so a
     card the user never touches still saves a valid payload. */
  var hadPosion = d.curePosion !== undefined;
  d.curePoison = d.curePoison !== undefined ? !!d.curePoison : !!d.curePosion;
  var poison = cf(d.curePoison);
  poison.addEventListener('change', function () {
    d.curePoison = poison.checked;
    if (hadPosion) d.curePosion = poison.checked;
  });

  function cureRow(label, chkEl, costKey, spellKey, spellLabel) {
    var cost = numF(d, costKey, 'Cost', '70px');
    var spell = spellKey ? txtF(d, spellKey, spellLabel || 'Spell words', '150px') : null;
    return h('div.row', { style: { alignItems: 'flex-end', marginBottom: '2px' } },
      h('label.check', { style: { minWidth: '150px' } }, chkEl, txt(label)), cost, spell);
  }

  var top = h('div.row', { style: { marginBottom: '10px' } },
    chkF(d, 'enabled', 'Conditions master switch'),
    chkF(d, 'ignoreInPz', 'Ignore in protection zone'),
    chkF(d, 'stopHaste', 'Stop haste while attacking'));

  var cures = h('div', null,
    h('div.cfggroup', { text: 'Cure (fires on the matching player-state bit)' }),
    cureRow('Poison', poison, 'poisonCost'),
    cureRow('Curse', bindChk(cf(d.cureCurse), d, 'cureCurse'), 'curseCost'),
    cureRow('Bleed', bindChk(cf(d.cureBleed), d, 'cureBleed'), 'bleedCost'),
    cureRow('Burn', bindChk(cf(d.cureBurn), d, 'cureBurn'), 'burnCost'),
    cureRow('Electrify', bindChk(cf(d.cureElectrify), d, 'cureElectrify'), 'electrifyCost'),
    cureRow('Paralyse', bindChk(cf(d.cureParalyse), d, 'cureParalyse'), 'paralyseCost', 'paralyseSpell'));

  var holds = h('div', null,
    h('div.cfggroup', { text: 'Hold (keep the buff up while it is affordable)' }),
    cureRow('Haste', bindChk(cf(d.holdHaste), d, 'holdHaste'), 'hasteCost', 'hasteSpell'),
    cureRow('Utamo vita', bindChk(cf(d.holdUtamo), d, 'holdUtamo'), 'utamoCost'),
    cureRow('Utana vid', bindChk(cf(d.holdUtana), d, 'holdUtana'), 'utanaCost'),
    cureRow('Utura', bindChk(cf(d.holdUtura), d, 'holdUtura'), 'uturaCost', 'uturaType', 'Type'));

  return { el: h('div', null, top, cures, holds), getData: function () { return d; } };
}

/* ---- Attack: attackTable entries (bot/attackbot.lua, AttackBot.json) ----
   bot/configschema.lua declares attackbot as `top = 'array'`: the kind's
   `data` IS the bare attackTable, not an object wrapping it -- unlike
   healbot/conditions/stances/targetbot, there is no profile-level object
   here (Rotate/Kills/PvpSafe/... stay on the hub's side, untouched). */
function buildAttackEditor(data) {
  var rows = Array.isArray(data) ? data : [];
  var CATS = [
    { value: 1, label: '1 — Targeted spell' },
    { value: 2, label: '2 — Area rune' },
    { value: 3, label: '3 — Targeted rune' },
    { value: 4, label: '4 — Empowerment' },
    { value: 5, label: '5 — Absolute (waves / beams / monk)' }
  ];

  var table = listEditor(rows, {
    reorder: true, addLabel: '+ Add attack entry',
    orderNote: 'Array order = priority; index 1 fires first. AttackBot fires at most one action per ~50 ms tick.',
    emptyText: 'No attack entries yet.',
    rowTitle: function (row) {
      return row.description || row.spell || (row.itemId ? ('rune ' + row.itemId) : 'entry');
    },
    newRow: function () {
      return { spell: '', itemId: 0, category: 5, patternCategory: 4, pattern: 1, count: 1, orMore: true,
        minHp: 0, maxHp: 100, mana: 0, cooldown: 1, harmony: 0, monsters: true, augmented: false,
        enabled: true, description: '' };
    },
    makeRow: function (row) {
      return h('div', null,
        h('div.row', null, chkF(row, 'enabled', 'Enabled'), txtF(row, 'description', 'Label', '260px')),
        h('div.row', null,
          enumF(row, 'category', 'Category', CATS),
          numF(row, 'pattern', 'Pattern', '70px'),
          numF(row, 'patternCategory', 'Pattern category', '90px')),
        h('div.row', null,
          txtF(row, 'spell', 'Spell words (empty for a rune)', '220px'),
          numF(row, 'itemId', 'Rune item id (> 100)', '110px')),
        monsterFilterF(row, 'monsters'),
        h('div.row', null,
          numF(row, 'count', 'Count', '60px'), chkF(row, 'orMore', 'or more'),
          numF(row, 'minHp', 'Min HP%', '70px'), numF(row, 'maxHp', 'Max HP%', '70px'),
          numF(row, 'mana', 'Min mana%', '70px')),
        h('div.row', null,
          numF(row, 'cooldown', 'Cooldown (ms spell / s rune)', '110px'),
          numF(row, 'harmony', 'Min harmony', '70px'),
          chkF(row, 'augmented', 'Augmented')));
    }
  });

  return { el: table.el, getData: function () { return rows; } };
}

/* ---- Stances: storage.stances (bot/stances.lua, vBot/Stances.lua reference) ---- */
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

function buildStancesEditor(data) {
  data.entries = Array.isArray(data.entries) ? data.entries : [];
  if (typeof data.enabled !== 'boolean') data.enabled = false;
  if (typeof data.ignoreInPz !== 'boolean') data.ignoreInPz = true;

  var STANCE_OPTIONS = STANCES_CATALOG.map(function (s) {
    return { value: s.words, label: s.name + ' (' + s.words + ')' };
  });

  var top = h('div.row', { style: { marginBottom: '10px' } },
    chkF(data, 'enabled', 'Stances enabled'),
    chkF(data, 'ignoreInPz', 'Ignore in protection zone'));

  var list = listEditor(data.entries, {
    reorder: true, addLabel: '+ Add stance',
    orderNote: 'Evaluated STRICTLY top to bottom — the FIRST entry whose conditions match wins the ' +
      'whole tick, even if a lower entry would also match. Put emergency stances first.',
    emptyText: 'No stances configured.',
    rowTitle: function (row) { return row.stanceName || row.spell || 'stance'; },
    newRow: function () {
      var s = STANCES_CATALOG[0];
      return { spell: s.words, spellId: s.id, stanceName: s.name, needTarget: s.needTarget,
        monsters: true, minHp: 0, maxHp: 100, minMana: 0, count: 0, range: 5, orMore: true,
        enabled: true, description: s.name };
    },
    makeRow: function (row) {
      var pick = selectOf(STANCE_OPTIONS, row.spell, function (o) { return o; });
      pick.addEventListener('change', function () {
        var cat = STANCES_CATALOG.filter(function (s) { return s.words === pick.value; })[0];
        if (cat) { row.spell = cat.words; row.spellId = cat.id; row.stanceName = cat.name; row.needTarget = cat.needTarget; }
      });
      return h('div', null,
        h('div.row', null,
          chkF(row, 'enabled', 'Enabled'),
          field('Known stance', pick),
          txtF(row, 'spell', 'Spell words (free text overrides the picker)', '200px')),
        txtF(row, 'description', 'Label', '260px'),
        monsterFilterF(row, 'monsters'),
        h('div.row', null,
          numF(row, 'minHp', 'Min HP%', '70px'), numF(row, 'maxHp', 'Max HP%', '70px'),
          numF(row, 'minMana', 'Min mana%', '70px')),
        h('div.row', null,
          numF(row, 'count', 'Monster count', '80px'), chkF(row, 'orMore', 'or more'),
          numF(row, 'range', 'Search range', '70px')));
    }
  });

  return { el: h('div', null, top, list.el), getData: function () { return data; } };
}

/* ---- Targeting: targeting[] + looting (bot/targetbot.lua, docs/vbot/targetbot.md) ---- */
function buildTargetbotEditor(data) {
  data.targeting = Array.isArray(data.targeting) ? data.targeting : [];
  data.looting = (data.looting && typeof data.looting === 'object' && !Array.isArray(data.looting))
    ? data.looting : {};
  var L = data.looting;
  if (typeof L.everyItem !== 'boolean') L.everyItem = false;
  if (L.maxDanger === undefined) L.maxDanger = 10;
  if (L.minCapacity === undefined) L.minCapacity = 100;
  L.items = Array.isArray(L.items) ? L.items : [];
  L.containers = Array.isArray(L.containers) ? L.containers : [];

  var targeting = listEditor(data.targeting, {
    reorder: true, addLabel: '+ Add creature entry',
    orderNote: 'List order is a TIE-BREAK only: every matching entry is considered, and when two score an ' +
      'equal priority for the same monster the earlier one in this list wins.',
    emptyText: 'No creature entries yet — TargetBot ignores every monster.',
    rowTitle: function (row) { return row.name || '*'; },
    newRow: function () {
      return { name: '*', priority: 1, danger: 1, maxDistance: 10, chase: true,
        keepDistance: false, keepDistanceRange: 1, anchor: false, anchorRange: 3,
        avoidAttacks: false, faceMonster: false, rePosition: false, rePositionAmount: 5,
        lure: false, lureCount: 1, lureCavebot: false, dynamicLure: false, lureMin: 1, lureMax: 3,
        dynamicLureDelay: false, lureDelay: 250, delayFrom: 2, closeLure: false, closeLureAmount: 3,
        dontLoot: false, diamondArrows: false, rpSafe: false };
    },
    makeRow: function (row) {
      return h('div', null,
        txtF(row, 'name', 'Name patterns (comma-separated, * and ? wildcards)', '280px'),
        h('div.cfggroup', { text: 'Priority / range' }),
        h('div.row', null,
          numF(row, 'priority', 'Priority (0-10)', '80px'),
          numF(row, 'danger', 'Danger (0-10)', '80px'),
          numF(row, 'maxDistance', 'Max distance', '80px')),
        h('div.cfggroup', { text: 'Movement' }),
        h('div.row', null,
          chkF(row, 'chase', 'Chase'),
          chkF(row, 'keepDistance', 'Keep distance'), numF(row, 'keepDistanceRange', 'Range', '60px'),
          chkF(row, 'anchor', 'Anchor'), numF(row, 'anchorRange', 'Anchor range', '80px')),
        h('div.row', null,
          chkF(row, 'avoidAttacks', 'Avoid attacks'),
          chkF(row, 'faceMonster', 'Face monster'),
          chkF(row, 'rePosition', 'Reposition'), numF(row, 'rePositionAmount', 'Threshold', '80px')),
        h('div.cfggroup', { text: 'Luring' }),
        h('div.row', null,
          chkF(row, 'lure', 'Lure'), numF(row, 'lureCount', 'Lure count', '80px'),
          chkF(row, 'lureCavebot', 'Lure via CaveBot')),
        h('div.row', null,
          chkF(row, 'dynamicLure', 'Dynamic lure'),
          numF(row, 'lureMin', 'Min', '60px'), numF(row, 'lureMax', 'Max', '60px')),
        h('div.row', null,
          chkF(row, 'dynamicLureDelay', 'Slow CaveBot while pulling'),
          numF(row, 'lureDelay', 'Delay (ms)', '80px'), numF(row, 'delayFrom', 'From count', '80px'),
          chkF(row, 'closeLure', 'Close lure'), numF(row, 'closeLureAmount', 'Until count', '80px')),
        h('div.cfggroup', { text: 'Misc' }),
        h('div.row', null,
          chkF(row, 'dontLoot', 'Don’t loot this corpse'),
          chkF(row, 'diamondArrows', 'Diamond-arrows priority'),
          chkF(row, 'rpSafe', 'PvP-safe (rpSafe)')));
    }
  });

  var lootItems = listEditor(L.items, {
    reorder: false, addLabel: '+ Add item id',
    emptyText: 'No items configured.',
    rowTitle: function (row) { return 'Item ' + (row.id || '—'); },
    newRow: function () { return { id: 0, count: 0 }; },
    makeRow: function (row) { return numF(row, 'id', 'Item id', '100px'); }
  });
  var lootContainers = listEditor(L.containers, {
    reorder: false, addLabel: '+ Add backpack id',
    emptyText: 'No loot backpacks configured — looting is off without one.',
    rowTitle: function (row) { return 'Backpack ' + (row.id || '—'); },
    newRow: function () { return { id: 0, count: 0 }; },
    makeRow: function (row) { return numF(row, 'id', 'Item id', '100px'); }
  });

  var lootBody = h('div', null,
    h('div.row', { style: { marginBottom: '8px' } },
      numF(L, 'maxDanger', 'Max danger to loot at', '90px'),
      numF(L, 'minCapacity', 'Stop below free capacity', '120px')),
    chkF(L, 'everyItem', 'Treat the item list as an IGNORE list instead'),
    h('div.hint', { style: { marginBottom: '6px' },
      text: 'The loot list is by numeric item id only — no names, no counts.' }),
    h('div.cfggroup', { text: 'Items' }), lootItems.el,
    h('div.cfggroup', { text: 'Destination backpacks (by item id)' }), lootContainers.el);

  return {
    el: h('div', null,
      h('div.cfggroup', { text: 'Targeting' }), targeting.el,
      h('div.cfggroup', { text: 'Looting' }), lootBody),
    getData: function () { return data; }
  };
}

/* ---- CaveBot: the ordered waypoint list (docs/vbot/config-compat-cavebot.md) ---- */
var CAVEBOT_WAYPOINT_TYPES = [
  'goto', 'label', 'gotolabel', 'delay', 'use', 'usewith', 'say', 'npcsay', 'function',
  'bank', 'buysupplies', 'cleartile', 'depositor', 'dpwithdraw', 'exanihur', 'follow', 'forge',
  'imbuing', 'inwithdraw', 'lure', 'opendoors', 'poscheck', 'rushlure', 'sellall', 'stowdeposit',
  'supplycheck', 'tasker', 'travel', 'turn', 'walkdelay', 'withdraw',
  'config', 'extensions', 'staypositions'
];
var CAVEBOT_MULTILINE_TYPES = { config: 1, extensions: 1, staypositions: 1 };

function buildCavebotEditor(data, ctx) {
  var rows = Array.isArray(data) ? data : [];
  var canExec = hasExec();
  var listId = 'cb-wp-types-' + ctx.instanceId;
  var datalist = h('datalist', { id: listId });
  CAVEBOT_WAYPOINT_TYPES.forEach(function (t) { datalist.appendChild(h('option', { value: t })); });

  var list = listEditor(rows, {
    reorder: true, addLabel: '+ Add waypoint',
    orderNote: 'Execution order: the bot runs this list top to bottom (label / gotolabel can jump around it).',
    emptyText: 'No waypoints yet.',
    rowTitle: function (row, i) { return (i + 1) + '. ' + (row.type || '?'); },
    canDuplicate: function (row) { return canExec || String(row.type || '').toLowerCase() !== 'function'; },
    /* bot/configschema.lua rejects an empty value outright ("an empty value
       drops the whole waypoint on load") -- default to something a save can
       actually accept, not a guaranteed 400 on the very first click. */
    newRow: function () { return { type: 'goto', value: '0,0,0' }; },
    makeRow: function (row, i, redraw) {
      var t = String(row.type || '').toLowerCase();
      var isFn = t === 'function';
      var locked = isFn && !canExec;

      var typeIn = h('input', { type: 'text', list: listId, value: row.type,
        style: { width: '170px' }, disabled: locked });
      typeIn.addEventListener('change', function () {
        // bot/configschema.lua requires the type lowercase, trimmed, with no
        // leading/trailing whitespace -- normalise here so a stray "Goto" or
        // " goto" does not turn into a guaranteed 400 on Save.
        var v = typeIn.value.trim().toLowerCase();
        if (v === 'function' && !canExec) {
          typeIn.value = row.type;
          Toast.warn('Not permitted', 'Only an admin or a canExec account may create a function waypoint.');
          return;
        }
        row.type = v;
        redraw();
      });

      var valueEl;
      if (isFn || CAVEBOT_MULTILINE_TYPES[t]) {
        valueEl = taInput(row.value, isFn ? 8 : 3, '100%');
      } else {
        valueEl = tf(row.value, '380px');
      }
      valueEl.disabled = locked;
      valueEl.addEventListener('change', function () { row.value = valueEl.value; });

      return h('div', null,
        field('Type', typeIn),
        isFn ? h('div.warnbox', { text: 'This runs as Lua inside the bot. Every add or change to a ' +
          'function waypoint’s body is written to the admin audit log with the full source — ' +
          'exactly like the Console tab’s Lua execution.' }) : null,
        field('Value', valueEl));
    }
  });

  var notice = canExec ? null : h('div.warnbox', { text:
    'Function waypoints run raw Lua inside the bot and are gated like the Console tab’s Lua execution: ' +
    'creating or editing one is administrator-only unless this account has been granted the canExec capability.' });

  return { el: h('div', null, datalist, notice, list.el), getData: function () { return rows; } };
}

function TabBotConfig(id) {
  var el = h('div');
  var KINDS = [
    ['healbot',    'Healing',    buildHealbotEditor],
    ['conditions', 'Conditions', buildConditionsEditor],
    ['attackbot',  'Attack',     buildAttackEditor],
    ['stances',    'Stances',    buildStancesEditor],
    ['targetbot',  'Targeting',  buildTargetbotEditor],
    ['cavebot',    'CaveBot',    buildCavebotEditor]
  ];
  KINDS.forEach(function (k) { el.appendChild(configCard(id, k[0], k[1], k[2])); });
  return { el: el };
}

/* ---------- 9.3 characters & accounts ---------- */

function ViewCharacters() {
  var el = h('div', null, h('div.view-head', null, h('h1', { text: 'Characters & Accounts' })));
  var accCard = h('div.card'), charCard = h('div.card'), proxyCard = h('div.card');
  el.appendChild(charCard); el.appendChild(h('div.grid.c2', null, accCard, proxyCard));

  function reload() {
    return Promise.all([
      api.call('accounts.list'), api.call('characters.list'),
      api.call('proxies.list'), loadInstances()
    ]).then(function (r) {
      S.accounts = r[0].accounts || [];
      S.characters = r[1].characters || [];
      S.proxies = r[2].proxies || [];
      render();
    }).catch(function (e) { failed('Load', e); });
  }

  function render() {
    /* --- characters --- */
    clear(charCard);
    charCard.appendChild(h('div.row', null,
      h('h3', { text: 'Characters', style: { margin: '0' } }), h('span.spacer'),
      h('button.btn.sm.primary', { text: '+ Character', onclick: charDialog })));
    var ctb = h('tbody');
    S.characters.forEach(function (c) {
      var inst = S.instances.filter(function (i) { return i.characterId === c.id; })[0];
      ctb.appendChild(h('tr', null,
        h('td', { text: c.name }),
        h('td', { text: c.accountLabel || '?' }),
        h('td', { text: c.world }),
        h('td', { text: c.vocation || '-' }),
        h('td.num', { text: c.lastLevel ? String(c.lastLevel) : '-' }),
        h('td', null, inst ? proxyPicker(inst) : h('span.hint', { text: 'needs an instance' })),
        h('td', null, inst
          ? h('button.linkish', { text: 'instance: ' + inst.state,
              onclick: function () { go('#/i/' + encodeURIComponent(inst.id) + '/overview'); } })
          : h('button.btn.sm', { text: 'Create instance', onclick: function () { instDialog(c); } })),
        h('td.nowrap', null,
          h('button.btn.sm.danger', { text: 'Remove', onclick: function () {
            Modal.confirm('Remove character', 'Remove ' + c.name + '? Its instance is deleted too.',
              function () {
                api.call('characters.delete', { id: c.id })
                  .then(function () { Toast.ok('Character removed'); reload(); })
                  .catch(function (e) { failed('Remove character', e); });
              }, 'Remove');
          } }))));
    });
    charCard.appendChild(S.characters.length
      ? h('div.tablewrap', { style: { marginTop: '10px' } },
          h('table.grid-table', null,
            h('thead', null, h('tr', null, ['Name', 'Account', 'World', 'Vocation', 'Level', 'Proxy', 'Instance', ''].map(
              function (t) { return h('th', { text: t }); }))), ctb))
      : emptyBox('No characters yet.'));

    /* --- accounts --- */
    clear(accCard);
    accCard.appendChild(h('div.row', null,
      h('h3', { text: 'Game accounts', style: { margin: '0' } }), h('span.spacer'),
      h('button.btn.sm.primary', { text: '+ Account', onclick: function () { accDialog(null); } })));
    var atb = h('tbody');
    S.accounts.forEach(function (a) {
      atb.appendChild(h('tr', null,
        h('td', { text: a.label }),
        h('td.mono', { text: a.login }),
        h('td', null, a.has2fa ? h('span.tag', { text: '2FA' }) : txt('-')),
        h('td.num', { text: String(a.characterCount || 0) }),
        h('td', { text: a.ownerName || '-' }),
        h('td.nowrap', null,
          h('button.btn.sm', { text: 'Edit', onclick: function () { accDialog(a); } }),
          h('button.btn.sm.danger', { text: 'Remove', onclick: function () {
            Modal.confirm('Remove account', 'Remove ' + a.label + ' and all its characters?', function () {
              api.call('accounts.delete', { id: a.id })
                .then(function () { Toast.ok('Account removed'); reload(); })
                .catch(function (e) { failed('Remove account', e); });
            }, 'Remove');
          } }))));
    });
    accCard.appendChild(S.accounts.length
      ? h('div.tablewrap', { style: { marginTop: '10px' } },
          h('table.grid-table', null,
            h('thead', null, h('tr', null, ['Label', 'Login', '2FA', 'Chars', 'Owner', ''].map(
              function (t) { return h('th', { text: t }); }))), atb))
      : emptyBox('No game accounts yet.'));
    accCard.appendChild(h('div.hint', { style: { marginTop: '8px' },
      text: 'The account password is write-only: it is encrypted at rest with the hub master key ' +
            'and no endpoint ever returns it. Leave the field empty to keep the stored one.' }));

    /* --- proxies --- */
    clear(proxyCard);
    proxyCard.appendChild(h('div.row', null,
      h('h3', { text: 'Proxies', style: { margin: '0' } }), h('span.spacer'),
      h('button.btn.sm.primary', { text: '+ Proxy', onclick: function () { proxyDialog(null); } })));
    var ptb = h('tbody');
    S.proxies.forEach(function (p) {
      ptb.appendChild(h('tr', null,
        h('td', { text: p.label }),
        h('td.mono', { text: p.host + ':' + p.port }),
        h('td', { text: p.kind }),
        h('td', { text: p.user ? p.user + (p.hasPass ? ' / •••' : '') : '-' }),
        h('td.num', { text: String(p.inUse || 0) }),
        h('td', { text: p.ownerName || '-' }),
        h('td.nowrap', null,
          h('button.btn.sm', { text: 'Test', onclick: function (e) {
            var b = e.currentTarget; b.disabled = true;
            api.call('proxies.test', { id: p.id }, { timeoutMs: 20000 }).then(function (r) {
              r.ok ? Toast.ok('Proxy OK', p.label + ': ' + r.latencyMs + ' ms')
                   : Toast.err('Proxy unreachable', r.error || '');
            }).catch(function (er) { failed('Proxy test', er); })
              .then(function () { b.disabled = false; });
          } }),
          h('button.btn.sm', { text: 'Edit', disabled: p.canEdit === false,
            title: p.canEdit === false ? 'Only the owner or an administrator may change this proxy'
                                       : 'Change this proxy',
            onclick: function () { proxyDialog(p); } }),
          h('button.btn.sm.danger', { text: 'Remove', disabled: p.canEdit === false,
            title: p.canEdit === false ? 'Only the owner or an administrator may remove this proxy'
                                       : 'Remove this proxy',
            onclick: function () {
            Modal.confirm('Remove proxy', 'Remove ' + p.label + '?', function () {
              api.call('proxies.delete', { id: p.id })
                .then(function () { Toast.ok('Proxy removed'); reload(); })
                .catch(function (e) { failed('Remove proxy', e); });
            }, 'Remove');
          } }))));
    });
    proxyCard.appendChild(S.proxies.length
      ? h('div.tablewrap', { style: { marginTop: '10px' } },
          h('table.grid-table', null,
            h('thead', null, h('tr', null,
              ['Label', 'Endpoint', 'Kind', 'Auth', 'Used by', 'Owner', ''].map(
              function (t) { return h('th', { text: t }); }))), ptb))
      : emptyBox('No proxies configured — instances will connect directly.'));
  }

  /** The per-character proxy assignment: it lives on that character's instance. */
  function proxyPicker(inst) {
    var sel = selectOf([{ id: '', label: '(direct)' }].concat(S.proxies), inst.proxyId || '',
      function (p) { return { value: p.id, label: p.label }; });
    sel.addEventListener('change', function () {
      var want = sel.value || null;
      sel.disabled = true;
      api.call('instances.update', { id: inst.id, proxyId: want })
        .then(function (r) { mergeInstance(r.instance); Toast.ok('Proxy assigned'); reload(); })
        .catch(function (e) { sel.value = inst.proxyId || ''; failed('Assign proxy', e); })
        .then(function () { sel.disabled = false; });
    });
    return sel;
  }

  function accDialog(a) {
    var label = h('input', { type: 'text', required: true, value: a ? a.label : '', autocomplete: 'off' });
    var login = h('input', { type: 'text', required: true, value: a ? a.login : '', autocomplete: 'off' });
    var pass = h('input', { type: 'password', autocomplete: 'new-password',
      placeholder: a ? '(unchanged)' : '' });
    var tok = h('input', { type: 'text', autocomplete: 'off', value: '' });
    Modal.open({
      title: a ? 'Edit game account' : 'Add game account',
      body: h('div', null,
        field('Label', label, 'Shown in the panel; any name you like.'),
        field('Game login', login),
        field('Password', pass, 'Write-only: stored encrypted, never returned to the browser.'),
        field('2FA secret (optional)', tok)),
      onsubmit: function (close) {
        var patch = { label: label.value, login: login.value };
        if (pass.value) patch.password = pass.value;
        if (tok.value) patch.token2fa = tok.value;
        var p;
        if (a) { patch.id = a.id; p = api.call('accounts.update', patch); }
        else p = api.call('accounts.create', patch);
        pass.value = ''; tok.value = '';           // do not leave secrets in the DOM
        p.then(function () { close(); Toast.ok(a ? 'Account updated' : 'Account added'); reload(); })
         .catch(function (e) { failed('Save account', e); });
      },
      actions: [{ label: 'Cancel' }, { label: 'Save', kind: 'primary', submit: true }]
    });
  }

  function charDialog() {
    if (!S.accounts.length) { Toast.warn('Add a game account first'); return; }
    var acc = selectOf(S.accounts, S.accounts[0].id, function (a) { return { value: a.id, label: a.label }; });
    var name = h('input', { type: 'text', required: true, autocomplete: 'off' });
    var world = h('input', { type: 'text', value: 'Gunzodus', required: true });
    var voc = selectOf(['', 'Knight', 'Paladin', 'Sorcerer', 'Druid', 'Monk'], '',
      function (v) { return { value: v, label: v || '(unknown)' }; });
    Modal.open({
      title: 'Add character',
      body: h('div', null, field('Game account', acc), field('Character name', name),
                           field('World', world), field('Vocation', voc)),
      onsubmit: function (close) {
        api.call('characters.create', { accountId: acc.value, name: name.value,
                                        world: world.value, vocation: voc.value || null })
          .then(function () { close(); Toast.ok('Character added'); reload(); })
          .catch(function (e) { failed('Add character', e); });
      },
      actions: [{ label: 'Cancel' }, { label: 'Add', kind: 'primary', submit: true }]
    });
  }

  function proxyDialog(p) {
    var label = h('input', { type: 'text', required: true, value: p ? p.label : '' });
    var host = h('input', { type: 'text', required: true, value: p ? p.host : '' });
    var port = h('input', { type: 'number', required: true, value: p ? p.port : 8080, min: '1', max: '65535' });
    var user = h('input', { type: 'text', autocomplete: 'off', value: p ? (p.user || '') : '' });
    var pass = h('input', { type: 'password', autocomplete: 'new-password', placeholder: p ? '(unchanged)' : '' });
    Modal.open({
      title: p ? 'Edit proxy' : 'Add proxy',
      body: h('div', null, field('Label', label), field('Host', host), field('Port', port),
              field('User (optional)', user), field('Password (optional)', pass,
                'Write-only, like the account password.'),
              h('div.hint', { text: 'Only http-connect is implemented on the worker side today.' })),
      onsubmit: function (close) {
        var patch = { label: label.value, kind: 'http-connect', host: host.value, port: Number(port.value),
                      user: user.value || null };
        if (pass.value) patch.pass = pass.value;
        var q;
        if (p) { patch.id = p.id; q = api.call('proxies.update', patch); }
        else q = api.call('proxies.create', patch);
        pass.value = '';
        q.then(function () { close(); Toast.ok('Proxy saved'); reload(); })
         .catch(function (e) { failed('Save proxy', e); });
      },
      actions: [{ label: 'Cancel' }, { label: 'Save', kind: 'primary', submit: true }]
    });
  }

  function instDialog(c) {
    var proxy = selectOf([{ id: '', label: '(direct, no proxy)' }].concat(S.proxies), '',
      function (p) { return { value: p.id, label: p.label }; });
    var profile = h('input', { type: 'text', value: 'profile_1' });
    var autoStart = h('input', { type: 'checkbox' });
    var autoRelog = h('input', { type: 'checkbox', checked: true });
    Modal.open({
      title: 'Create instance for ' + c.name,
      body: h('div', null, field('Proxy', proxy), field('Bot profile', profile),
        h('div.row', null,
          h('label.check', null, autoStart, txt('Auto-start')),
          h('label.check', null, autoRelog, txt('Auto-relogin')))),
      onsubmit: function (close) {
        api.call('instances.create', {
          characterId: c.id, proxyId: proxy.value || null, botProfile: profile.value,
          autoStart: autoStart.checked, autoRelogin: autoRelog.checked
        }).then(function (r) {
          close(); Toast.ok('Instance created');
          reload().then(function () { go('#/i/' + encodeURIComponent(r.instance.id) + '/overview'); });
        }).catch(function (e) { failed('Create instance', e); });
      },
      actions: [{ label: 'Cancel' }, { label: 'Create', kind: 'primary', submit: true }]
    });
  }

  reload();
  return { el: el };
}

/* ---------- 9.4 scripts ---------- */

function ViewScripts() {
  var listWrap = h('div');
  var el = h('div', null,
    h('div.view-head', null, h('h1', { text: 'Scripts' }), h('span.spacer'),
      (S.me && S.me.canExec === false) ? h('span') :
      h('button.btn.primary', { text: 'Upload .lua…', onclick: uploadDialog })),
    h('div.warnbox', { text: (S.me && S.me.canExec === false)
      ? 'Uploading a script is administrator-only on this hub: the code runs unsandboxed ' +
        'under the hub’s own user account. An administrator has to grant this account the ' +
        'remote-Lua capability first.'
      : 'Uploaded scripts run as arbitrary Lua inside the worker, in the same ' +
        'environment as the bot’s own scripts. There is no sandbox, and the worker runs ' +
        'under the hub’s own user account. Upload only code you trust.' }),
    listWrap);

  function reload() {
    return Promise.all([api.call('scripts.list'), loadInstances()]).then(function (r) {
      S.scripts = r[0].scripts || [];
      render();
    }).catch(function (e) { failed('Script list', e); });
  }

  function render() {
    clear(listWrap);
    if (!S.scripts.length) { listWrap.appendChild(emptyBox('No scripts uploaded yet.')); return; }
    var tb = h('tbody');
    S.scripts.forEach(function (sc) {
      var names = (sc.instanceIds || []).map(function (iid) {
        var i = S.byId[iid]; return i ? i.characterName : iid;
      });
      tb.appendChild(h('tr', null,
        h('td.mono', { text: sc.name }),
        h('td.num', { text: num(sc.size) }),
        h('td.mono', { text: (sc.sha256 || '').slice(0, 12) }),
        h('td', { text: sc.ownerName || '-' }),
        h('td', { text: stamp(sc.createdAt) }),
        h('td', null, names.length ? names.map(function (n) { return h('span.tag', { text: n }); })
                                   : h('span.hint', { text: 'unassigned' })),
        h('td.nowrap', null,
          h('button.btn.sm', { text: 'View', onclick: function () { viewSource(sc); } }),
          h('button.btn.sm', { text: 'Assign', onclick: function () { scriptAssign(sc); } }),
          h('button.btn.sm.danger', { text: 'Delete', onclick: function () {
            Modal.confirm('Delete script',
              'Delete ' + sc.name + '? It is removed from the ' + (sc.instanceIds || []).length +
              ' instance(s) it is assigned to.', function () {
                api.call('scripts.delete', { id: sc.id })
                  .then(function () { Toast.ok('Script deleted'); reload(); })
                  .catch(function (e) { failed('Delete script', e); });
              }, 'Delete');
          } }))));
    });
    listWrap.appendChild(h('div.tablewrap', null, h('table.grid-table', null,
      h('thead', null, h('tr', null, ['Name', 'Bytes', 'sha256', 'Owner', 'Uploaded', 'Assigned to', ''].map(
        function (t) { return h('th', { text: t }); }))), tb)));
  }

  function uploadDialog() {
    var file = h('input', { type: 'file', accept: '.lua,text/plain' });
    var name = h('input', { type: 'text', placeholder: 'my_script.lua' });
    var area = h('textarea', { rows: '12', spellcheck: 'false',
      placeholder: '-- paste Lua here, or pick a file above' });
    file.addEventListener('change', function () {
      var f = file.files && file.files[0];
      if (!f) return;
      if (f.size > 512 * 1024) { Toast.err('File too large', 'limit is 512 KiB'); file.value = ''; return; }
      if (!name.value) name.value = f.name;
      var fr = new FileReader();
      fr.onload = function () { area.value = String(fr.result); };
      fr.onerror = function () { Toast.err('Could not read the file'); };
      fr.readAsText(f);
    });
    Modal.open({
      title: 'Upload script',
      body: h('div', null, field('File', file), field('Name', name), field('Source', area)),
      onsubmit: function (close) {
        var n = (name.value || '').trim();
        if (!/^[\w.\- ]{1,64}$/.test(n)) { Toast.err('Bad name', 'letters, digits, . _ - and spaces, max 64'); return; }
        if (!area.value.trim()) { Toast.err('Empty script'); return; }
        api.call('scripts.upload', { name: n, source: area.value }, { timeoutMs: 30000 })
          .then(function () { close(); Toast.ok('Uploaded'); reload(); })
          .catch(function (e) { failed('Upload', e); });
      },
      actions: [{ label: 'Cancel' }, { label: 'Upload', kind: 'primary', submit: true }]
    });
  }

  function viewSource(sc) {
    api.call('scripts.get', { id: sc.id }).then(function (r) {
      var pre = h('pre.mono', { text: r.source,
        style: { whiteSpace: 'pre-wrap', margin: '0', maxHeight: '55vh', overflow: 'auto', fontSize: '12px' } });
      Modal.open({ title: sc.name, body: pre, actions: [{ label: 'Close' }] });
    }).catch(function (e) { failed('Read script', e); });
  }

  function scriptAssign(sc) {
    var boxes = [];
    var list = h('div');
    if (!S.instances.length) list.appendChild(h('div.hint', { text: 'No instances.' }));
    S.instances.forEach(function (i) {
      var cb = h('input', { type: 'checkbox', checked: (sc.instanceIds || []).indexOf(i.id) >= 0 });
      boxes.push({ cb: cb, id: i.id });
      list.appendChild(h('div', null, h('label.check', null, cb,
        txt(i.characterName), h('span.tag', { text: i.state }))));
    });
    Modal.open({
      title: 'Assign ' + sc.name,
      body: list,
      onsubmit: function (close) {
        api.call('scripts.assign', { id: sc.id,
          instanceIds: boxes.filter(function (b) { return b.cb.checked; }).map(function (b) { return b.id; }) })
          .then(function () { close(); Toast.ok('Assignment saved'); reload(); })
          .catch(function (e) { failed('Assign', e); });
      },
      actions: [{ label: 'Cancel' }, { label: 'Save', kind: 'primary', submit: true }]
    });
  }

  reload();
  return { el: el };
}

/* ---------- 9.5 admin (never constructed for non-admins) ---------- */

function ViewAdmin(params) {
  if (!isAdmin()) { go('#/dashboard'); return { el: h('div') }; }
  var tab = params.tab || 'users';
  var pane = h('div');
  var bar = h('div.tabs', { role: 'tablist' });
  [['users', 'Web accounts'], ['sessions', 'Sessions'], ['audit', 'Audit log']].forEach(function (t) {
    bar.appendChild(h('button', { role: 'tab', text: t[1], 'aria-selected': String(t[0] === tab),
      onclick: function () { go('#/admin/' + t[0]); } }));
  });
  var sub = tab === 'sessions' ? AdminSessions() : tab === 'audit' ? AdminAudit() : AdminUsers();
  pane.appendChild(sub.el);
  return { el: h('div', null, h('div.view-head', null, h('h1', { text: 'Administration' })), bar, pane),
           onEvent: sub.onEvent, destroy: sub.destroy };
}

function AdminUsers() {
  var wrap = h('div.card');
  function reload() {
    api.call('admin.users').then(function (r) { S.users = r.users || []; render(); })
      .catch(function (e) { failed('User list', e); });
  }
  function render() {
    clear(wrap);
    wrap.appendChild(h('div.row', null, h('h3', { text: 'Web accounts', style: { margin: '0' } }),
      h('span.spacer'), h('button.btn.sm.primary', { text: '+ Account', onclick: userDialog })));
    var tb = h('tbody');
    S.users.forEach(function (u) {
      tb.appendChild(h('tr', null,
        h('td', { text: u.name }),
        h('td', null, h('span.tag' + (u.role === 'admin' ? '.role-admin' : ''), { text: u.role })),
        h('td', { text: u.disabled ? 'disabled' : 'active' }),
        h('td', null, h('span.tag' + (u.canExec ? '.role-admin' : ''),
          { text: u.role === 'admin' ? 'always' : (u.canExec ? 'granted' : 'no') })),
        h('td', { text: stamp(u.createdAt) }),
        h('td', { text: u.lastLoginAt ? stamp(u.lastLoginAt) : 'never' }),
        h('td.nowrap', null,
          h('button.btn.sm', { text: u.disabled ? 'Enable' : 'Disable',
            disabled: S.me && u.id === S.me.id,
            onclick: function () {
              api.call('admin.userUpdate', { id: u.id, disabled: !u.disabled })
                .then(function () { reload(); }).catch(function (e) { failed('Update user', e); });
            } }),
          h('button.btn.sm', { text: 'Reset password', onclick: function () { pwDialog(u); } }),
          h('button.btn.sm', { text: u.canExec ? 'Revoke Lua' : 'Grant Lua',
            disabled: u.role === 'admin',
            onclick: function () {
              var grant = !u.canExec;
              Modal.confirm(grant ? 'Grant remote Lua' : 'Revoke remote Lua',
                grant
                  ? ('Let ' + u.name + ' run arbitrary Lua in a worker and upload scripts? '
                     + 'That code runs unsandboxed under the hub\'s own user account and can '
                     + 'read every stored credential -- it is equivalent to making them an '
                     + 'administrator of this host.')
                  : ('Stop ' + u.name + ' running Lua in a worker and uploading scripts?'),
                function () {
                  api.call('admin.userUpdate', { id: u.id, canExec: grant })
                    .then(function () { reload(); }).catch(function (e) { failed('Update user', e); });
                }, grant ? 'Grant' : 'Revoke');
            } }),
          h('button.btn.sm', { text: u.role === 'admin' ? 'Make user' : 'Make admin',
            disabled: S.me && u.id === S.me.id,
            onclick: function () {
              var nextRole = u.role === 'admin' ? 'user' : 'admin';
              Modal.confirm('Change role',
                'Make ' + u.name + ' ' + (nextRole === 'admin'
                  ? 'an administrator? Administrators see every instance and the audit log.'
                  : 'an ordinary user?'), function () {
                  api.call('admin.userUpdate', { id: u.id, role: nextRole })
                    .then(function () { reload(); }).catch(function (e) { failed('Update user', e); });
                }, 'Change role');
            } }),
          h('button.btn.sm.danger', { text: 'Delete', disabled: S.me && u.id === S.me.id,
            onclick: function () {
              Modal.confirm('Delete web account',
                'Delete ' + u.name + '? Their sessions are revoked immediately.', function () {
                  api.call('admin.userDelete', { id: u.id })
                    .then(function () { Toast.ok('Account deleted'); reload(); })
                    .catch(function (e) { failed('Delete user', e); });
                }, 'Delete');
            } }))));
    });
    wrap.appendChild(h('div.tablewrap', { style: { marginTop: '10px' } }, h('table.grid-table', null,
      h('thead', null, h('tr', null, ['Name', 'Role', 'Status', 'Remote Lua', 'Created', 'Last login', ''].map(
        function (t) { return h('th', { text: t }); }))), tb)));
  }

  function userDialog() {
    var name = h('input', { type: 'text', required: true, autocomplete: 'off' });
    var role = selectOf(['user', 'admin'], 'user', function (r) { return { value: r, label: r }; });
    var pw = h('input', { type: 'password', required: true, autocomplete: 'new-password', minlength: '10' });
    var pw2 = h('input', { type: 'password', required: true, autocomplete: 'new-password' });
    Modal.open({
      title: 'New web account',
      body: h('div', null, field('Name', name), field('Role', role),
        field('Password', pw, 'At least 10 characters. Hashed with PBKDF2-HMAC-SHA256 by the hub.'),
        field('Repeat password', pw2)),
      onsubmit: function (close) {
        if (pw.value !== pw2.value) { Toast.err('Passwords do not match'); return; }
        if (pw.value.length < 10) { Toast.err('Password too short', 'at least 10 characters'); return; }
        var payload = { name: name.value, role: role.value, password: pw.value };
        pw.value = pw2.value = '';
        api.call('admin.userCreate', payload)
          .then(function () { close(); Toast.ok('Account created'); reload(); })
          .catch(function (e) { failed('Create account', e); });
      },
      actions: [{ label: 'Cancel' }, { label: 'Create', kind: 'primary', submit: true }]
    });
  }

  function pwDialog(u) {
    var pw = h('input', { type: 'password', required: true, autocomplete: 'new-password' });
    var pw2 = h('input', { type: 'password', required: true, autocomplete: 'new-password' });
    Modal.open({
      title: 'Reset password for ' + u.name,
      body: h('div', null, field('New password', pw), field('Repeat', pw2),
        h('div.hint', { text: 'All existing sessions for this account are revoked.' })),
      onsubmit: function (close) {
        if (pw.value !== pw2.value) { Toast.err('Passwords do not match'); return; }
        if (pw.value.length < 10) { Toast.err('Password too short', 'at least 10 characters'); return; }
        var payload = { id: u.id, password: pw.value };
        pw.value = pw2.value = '';
        api.call('admin.userPassword', payload)
          .then(function () { close(); Toast.ok('Password reset'); reload(); })
          .catch(function (e) { failed('Reset password', e); });
      },
      actions: [{ label: 'Cancel' }, { label: 'Reset', kind: 'danger', submit: true }]
    });
  }

  reload();
  return { el: wrap };
}

function AdminSessions() {
  var wrap = h('div.card');
  function reload() {
    api.call('admin.sessions').then(function (r) { S.sessions = r.sessions || []; render(); })
      .catch(function (e) { failed('Session list', e); });
  }
  function render() {
    clear(wrap);
    wrap.appendChild(h('div.row', null, h('h3', { text: 'Active sessions', style: { margin: '0' } }),
      h('span.spacer'), h('button.btn.sm', { text: 'Refresh', onclick: reload })));
    if (!S.sessions.length) { wrap.appendChild(emptyBox('No sessions.')); return; }
    var tb = h('tbody');
    S.sessions.forEach(function (s) {
      tb.appendChild(h('tr', null,
        h('td', { text: s.userName }),
        h('td.mono', { text: s.ip }),
        h('td', { text: s.userAgent || '-', style: { maxWidth: '280px', overflow: 'hidden',
                                                     textOverflow: 'ellipsis', whiteSpace: 'nowrap' } }),
        h('td', { text: stamp(s.createdAt) }),
        h('td', { text: stamp(s.lastSeenAt) }),
        h('td', null, s.current ? h('span.tag', { text: 'this browser' }) : null),
        h('td', null, h('button.btn.sm.danger', { text: 'Revoke', onclick: function () {
          Modal.confirm('Revoke session',
            'Sign ' + s.userName + ' out of ' + s.ip +
            (s.current ? ' — this is your own browser, you will be sent to the login screen.' : '?'),
            function () {
              api.call('admin.sessionRevoke', { id: s.id })
                .then(function () { Toast.ok('Session revoked'); reload(); })
                .catch(function (e) { failed('Revoke', e); });
            }, 'Revoke');
        } }))));
    });
    wrap.appendChild(h('div.tablewrap', { style: { marginTop: '10px' } }, h('table.grid-table', null,
      h('thead', null, h('tr', null, ['User', 'IP', 'User agent', 'Created', 'Last seen', '', ''].map(
        function (t) { return h('th', { text: t }); }))), tb)));
  }
  reload();
  return { el: wrap };
}

function AdminAudit() {
  var actorSel = h('select'), actionSel = h('select');
  var from = h('input', { type: 'datetime-local' }), to = h('input', { type: 'datetime-local' });
  var q = h('input', { type: 'search', placeholder: 'text in target/detail…' });
  var live = h('input', { type: 'checkbox', checked: true });
  var tb = h('tbody');
  var moreBtn = h('button.btn.sm', { text: 'Load more', hidden: true });
  var cursor = null;

  function opt(sel, values, keep) {
    var cur = keep ? sel.value : '';
    clear(sel);
    sel.appendChild(h('option', { value: '', text: '(any)' }));
    values.forEach(function (v) { sel.appendChild(h('option', { value: v, text: v })); });
    sel.value = cur;
  }
  opt(actorSel, []); opt(actionSel, []);

  function tsOf(input) {
    if (!input.value) return null;
    var d = new Date(input.value);
    return isNaN(d.getTime()) ? null : d.getTime();
  }

  function query(more) {
    var args = { limit: 100 };
    if (actorSel.value) args.actor = actorSel.value;
    if (actionSel.value) args.action = actionSel.value;
    if (q.value.trim()) args.q = q.value.trim();
    var f = tsOf(from), t = tsOf(to);
    if (f) args.from = f;
    if (t) args.to = t;
    if (more && cursor) args.cursor = cursor;
    api.call('admin.audit', args).then(function (r) {
      if (!more) clear(tb);
      (r.rows || []).forEach(function (row) { tb.appendChild(rowNode(row)); });
      cursor = r.nextCursor || null;
      moreBtn.hidden = !cursor;
      if (r.actors) opt(actorSel, r.actors, true);
      if (r.actions) opt(actionSel, r.actions, true);
      if (!tb.children.length) tb.appendChild(h('tr', null, h('td', { colspan: '6' },
        emptyBox('No audit records match these filters.'))));
    }).catch(function (e) { failed('Audit query', e); });
  }
  moreBtn.addEventListener('click', function () { query(true); });

  function rowNode(r) {
    return h('tr', null,
      h('td.nowrap', { text: stamp(r.t) }),
      h('td', { text: r.actor }),
      h('td.mono', { text: r.ip || '-' }),
      h('td.mono', { text: r.action }),
      h('td', { text: r.target || '-' }),
      h('td', null,
        h('span.pill.' + (r.outcome === 'ok' ? 'on' : 'error'), { text: r.outcome }),
        r.detail ? h('div.hint', { text: r.detail }) : null));
  }

  [actorSel, actionSel].forEach(function (s) { s.addEventListener('change', function () { query(false); }); });
  [from, to].forEach(function (s) { s.addEventListener('change', function () { query(false); }); });
  var qTimer = null;
  q.addEventListener('input', function () { clearTimeout(qTimer); qTimer = setTimeout(function () { query(false); }, 250); });

  var el = h('div.card', null,
    h('div.row', { style: { marginBottom: '10px' } },
      h('h3', { text: 'Audit log', style: { margin: '0' } }),
      h('span.spacer'),
      h('div', { style: { width: '160px' } }, actorSel),
      h('div', { style: { width: '190px' } }, actionSel),
      h('div', { style: { width: '190px' } }, from),
      h('div', { style: { width: '190px' } }, to),
      h('div', { style: { width: '190px' } }, q),
      h('label.check', null, live, txt('live')),
      h('button.btn.sm', { text: 'Reset', onclick: function () {
        actorSel.value = ''; actionSel.value = ''; from.value = ''; to.value = ''; q.value = ''; query(false);
      } })),
    h('div.tablewrap', null, h('table.grid-table', null,
      h('thead', null, h('tr', null, ['Time', 'Actor', 'IP', 'Action', 'Target', 'Outcome'].map(
        function (t) { return h('th', { text: t }); }))), tb)),
    h('div.row', { style: { marginTop: '8px' } }, moreBtn,
      h('span.hint', { text: 'Only administrators can read this log. Newest first.' })));

  query(false);
  return {
    el: el,
    onEvent: function (ev, data) {
      if (ev !== 'audit' || !live.checked || !data) return;
      if (actorSel.value && data.actor !== actorSel.value) return;
      if (actionSel.value && data.action !== actionSel.value) return;
      tb.insertBefore(rowNode(data), tb.firstChild);
      while (tb.children.length > 400) tb.removeChild(tb.lastChild);
    }
  };
}

/* ---------- 9.6 login ---------- */

function renderLogin(bootstrapNeeded) {
  var appEl = document.getElementById('app');
  clear(appEl);
  appEl.appendChild(bannerBar());

  var name = h('input', { type: 'text', id: 'lg-name', required: true, autocomplete: 'username',
    autocapitalize: 'off', spellcheck: 'false' });
  var pass = h('input', { type: 'password', id: 'lg-pass', required: true, autocomplete: 'current-password' });
  var tokenIn = h('input', { type: 'text', autocomplete: 'off', spellcheck: 'false' });
  var errBox = h('div', { hidden: true });
  var btn = h('button.btn.primary', { type: 'submit', text: bootstrapNeeded ? 'Create administrator' : 'Sign in',
    style: { width: '100%', justifyContent: 'center' } });

  function showErr(m) {
    clear(errBox); errBox.hidden = false;
    errBox.appendChild(h('div#login-err', { text: m }));
  }

  var form = h('form', { onsubmit: function (e) {
    e.preventDefault();
    errBox.hidden = true;
    btn.disabled = true;
    var endpoint = bootstrapNeeded ? 'bootstrap' : 'session.login';
    var args = bootstrapNeeded
      ? { token: tokenIn.value, name: name.value, password: pass.value }
      : { name: name.value, password: pass.value };
    pass.value = '';                         // never keep the secret in the DOM
    api.call(endpoint, args, { timeoutMs: 20000 }).then(function (r) {
      args.password = '';
      S.me = r.user;
      startApp();
    }).catch(function (er) {
      args.password = '';
      showErr(er.code === 'unauthorized' ? 'Wrong name or password.'
            : er.code === 'rate-limited' ? 'Too many attempts — wait and try again.'
            : er.code === 'forbidden' ? (er.message || 'This account cannot sign in.')
            : er.message);
      btn.disabled = false;
      pass.focus();
    });
  } },
    h('h1', { text: bootstrapNeeded ? 'First run' : 'luaclient hub' }),
    h('div.sub', { text: bootstrapNeeded
      ? 'No accounts exist yet. Paste the bootstrap token the hub printed to its stdout.'
      : 'Sign in to control your worker instances.' }),
    errBox,
    bootstrapNeeded ? field('Bootstrap token', tokenIn) : null,
    field(bootstrapNeeded ? 'Administrator name' : 'Name', name),
    field('Password', pass),
    btn,
    MOCK ? h('div.hint', { style: { marginTop: '14px' },
      text: 'Mock mode: sign in as "arnold" (admin) or "sam" (user). Any password of 3+ characters works.' }) : null
  );

  appEl.appendChild(h('div#login-wrap', null, h('div.box', null, form)));
  name.focus();
}

/* =========================== 10. actions ========================= */

/**
 * Apply a local patch immediately, send it, roll back on failure.
 * Never rejects: a failure is rolled back, reported as a toast, and the
 * promise settles with null, so call sites can chain without a catch.
 */
function optimistic(obj, patch, endpoint, args, label) {
  var before = {};
  Object.keys(patch).forEach(function (k) { before[k] = obj[k]; obj[k] = patch[k]; });
  refresh();
  return api.call(endpoint, args).then(function (r) {
    if (r && r.instance) mergeInstance(r.instance);
    refresh();
    return r;
  }).catch(function (e) {
    Object.keys(before).forEach(function (k) { obj[k] = before[k]; });
    refresh();
    failed(label || endpoint, e);
    return null;
  });
}

function bulkAction(action, ids, extra, optimisticPatch, label) {
  if (!ids.length) return Promise.resolve();
  var before = ids.map(function (id) {
    var i = S.byId[id]; if (!i) return null;
    var b = {}; Object.keys(optimisticPatch).forEach(function (k) { b[k] = i[k]; i[k] = optimisticPatch[k]; });
    return { id: id, before: b };
  });
  ids.forEach(markDirty);
  var args = { action: action, ids: ids };
  for (var k in extra) args[k] = extra[k];
  return api.call('instances.action', args, { timeoutMs: 30000 }).then(function (r) {
    var bad = (r.results || []).filter(function (x) { return !x.ok; });
    if (bad.length) {
      bad.forEach(function (x) {
        var i = S.byId[x.id];
        Toast.err(label + ' failed for ' + (i ? i.characterName : x.id), x.error || '');
      });
    } else {
      Toast.ok(label + ': ' + ids.length + ' instance' + (ids.length > 1 ? 's' : ''));
    }
    return loadInstances().then(refresh);
  }).catch(function (e) {
    before.forEach(function (b) {
      if (!b) return;
      var i = S.byId[b.id]; if (!i) return;
      Object.keys(b.before).forEach(function (k) { i[k] = b.before[k]; });
    });
    refresh();
    failed(label, e);
  });
}

function doStart(ids)   { return bulkAction('start', ids, {}, { state: 'starting' }, 'Start'); }
function doStop(ids)    { return bulkAction('stop', ids, {}, { state: 'stopping' }, 'Stop'); }
function doRestart(ids) { return bulkAction('restart', ids, {}, { state: 'starting' }, 'Restart'); }
function doBot(ids, on) { return bulkAction('botEnable', ids, { on: on }, { botEnabled: on },
                                            on ? 'Bot enable' : 'Bot disable'); }

function loadInstances() {
  return api.call('instances.list').then(function (r) {
    S.instances = r.instances || [];
    S.instances.sort(function (a, b) { return String(a.characterName).localeCompare(String(b.characterName)); });
    indexInstances();
    return S.instances;
  });
}

function mergeInstance(inst) {
  if (!inst) return;
  var cur = S.byId[inst.id];
  if (!cur) { S.instances.push(inst); indexInstances(); return; }
  Object.keys(inst).forEach(function (k) { cur[k] = inst[k]; });
}

/* =========================== 11. shell =========================== */

var mainEl = null, railList = null, currentView = null, currentRoute = '';
var connPill = null, tickTimer = null;
var railItems = Object.create(null);

function bannerBar() {
  var bar = h('div#banners');
  if (MOCK) {
    bar.appendChild(h('div.banner.mock', null,
      h('b', { text: 'MOCK MODE' }),
      txt('No hub is connected. Every number on this page is generated in mock/api.js.')));
  }
  if (!IS_HTTPS) {
    var loopback = /^(localhost|127\.0\.0\.1|\[::1\])$/.test(location.hostname);
    bar.appendChild(h('div.banner', null,
      h('b', { text: 'Not HTTPS' }),
      txt(loopback
        ? 'This page is served over ' + location.protocol + ' from ' + (location.hostname || 'the filesystem') +
          '. That is fine for loopback, but never expose the hub without a TLS terminator in front of it.'
        : 'Your password and session cookie are travelling in clear text over ' + location.protocol +
          '. Put the hub behind nginx/Caddy or an SSH tunnel before using it over a network.')));
  }
  return bar;
}

function buildShell() {
  var appEl = document.getElementById('app');
  clear(appEl);
  appEl.appendChild(bannerBar());
  railItems = Object.create(null);

  connPill = h('span#conn-pill', null, h('i.dot'), h('span', { text: 'connecting' }));

  var nav = h('nav');
  var links = [['#/dashboard', 'Dashboard'], ['#/characters', 'Characters'], ['#/scripts', 'Scripts']];
  if (isAdmin()) links.push(['#/admin/users', 'Admin']);      // hidden entirely for non-admins
  links.forEach(function (l) { nav.appendChild(h('a', { href: l[0], text: l[1], dataset: { route: l[0] } })); });

  var top = h('div#topbar', null,
    h('button.btn.sm.ghost#rail-toggle', { text: '≡', 'aria-label': 'Toggle instance list',
      onclick: function () { document.body.classList.toggle('rail-open'); } }),
    h('div.brand', null, h('i.dot'), txt('luaclient hub')),
    nav,
    h('span.spacer'),
    connPill,
    h('span.hint', { text: S.me.name }),
    h('span.tag' + (isAdmin() ? '.role-admin' : ''), { text: S.me.role }),
    h('button.btn.sm', { text: 'Password', onclick: changeOwnPassword }),
    h('button.btn.sm', { text: 'Sign out', onclick: signOut }));

  railList = h('div#rail-list');
  var rail = h('div#rail', null,
    h('div.rail-head', null, txt('Instances'), h('span.spacer'),
      h('button.btn.sm.ghost', { text: '↻', 'aria-label': 'Reload instances',
        onclick: function () { loadInstances().then(refresh); } })),
    railList);

  mainEl = h('div#main', { id: 'main', tabindex: '-1' });
  appEl.appendChild(top);
  appEl.appendChild(h('div#body', null, rail, mainEl));
}

/** Incremental, like the dashboard: 40 instances must not cost 40 rebuilds a second. */
function renderRail(dirtyIds) {
  if (!railList) return;

  if (dirtyIds) {
    for (var d = 0; d < dirtyIds.length; d++) {
      var it = railItems[dirtyIds[d]], ins = S.byId[dirtyIds[d]];
      if (!it || !ins) { renderRail(null); return; }
      fillRail(it, ins);
    }
    return;
  }

  var empty = !S.instances.length;
  clear(railList);
  railItems = Object.create(null);
  if (empty) { railList.appendChild(h('div.hint', { style: { padding: '10px' }, text: 'none yet' })); return; }

  S.instances.forEach(function (i) {
    var active = currentRoute.indexOf('#/i/' + i.id) === 0;
    var nm = h('span.nm', { text: i.characterName });
    var pillWrap = h('span');
    var lvl = h('span'), exp = h('span'), bot = h('span');
    var btn = h('button.rail-item' + (active ? '.active' : ''), {
        onclick: function () { go('#/i/' + encodeURIComponent(i.id) + '/overview');
                               document.body.classList.remove('rail-open'); } },
      h('div.l1', null, nm, h('span.spacer'), pillWrap),
      h('div.l2', null, lvl, exp, bot));
    var item = { btn: btn, nm: nm, pillWrap: pillWrap, lvl: lvl, exp: exp, bot: bot, stateKey: '' };
    fillRail(item, i);
    railItems[i.id] = item;
    railList.appendChild(btn);
  });
}

function fillRail(item, i) {
  var L = i.live || {};
  setText(item.nm, i.characterName);
  if (item.stateKey !== i.state) {
    item.stateKey = i.state;
    clear(item.pillWrap);
    item.pillWrap.appendChild(statePill(i.state));
  }
  setText(item.lvl, L.level ? 'lvl ' + L.level : '–');
  setText(item.exp, rate(L.expPerHour));
  setText(item.bot, i.botEnabled ? 'bot' : '');
}

function setConn(status, detail) {
  if (!connPill) return;
  connPill.className = '';
  connPill.id = 'conn-pill';
  if (status === 'live' || status === 'retry' || status === 'down') connPill.classList.add(status);
  connPill.title = detail || '';
  setText(connPill.lastChild,
    status === 'live' ? (MOCK ? 'mock live' : 'live')
    : status === 'connecting' ? 'connecting'
    : status === 'retry' ? 'reconnecting'
    : status === 'down' ? 'offline' : 'idle');
}

/* ---------- router ---------- */

function go(hash) { if (location.hash === hash) route(); else location.hash = hash; }

function parseRoute() {
  var raw = location.hash || '#/dashboard';
  var parts = raw.replace(/^#\/?/, '').split('/').map(decodeURIComponent);
  return { name: parts[0] || 'dashboard', a: parts[1], b: parts[2], raw: raw };
}

function route() {
  if (!S.me) return;
  var r = parseRoute();
  currentRoute = r.raw;

  if (r.name === 'admin' && !isAdmin()) { location.replace('#/dashboard'); return; }

  if (currentView && currentView.destroy) { try { currentView.destroy(); } catch (e) {} }
  currentView = null;
  clear(mainEl);

  var v;
  if (r.name === 'i' && r.a) v = ViewInstance({ id: r.a, tab: r.b });
  else if (r.name === 'characters') v = ViewCharacters();
  else if (r.name === 'scripts') v = ViewScripts();
  else if (r.name === 'admin') v = ViewAdmin({ tab: r.a });
  else v = ViewDashboard();

  currentView = v;
  mainEl.appendChild(v.el);
  mainEl.scrollTop = 0;

  Array.prototype.forEach.call(document.querySelectorAll('#topbar nav a'), function (a) {
    var base = '#/' + r.name;
    a.classList.toggle('active', a.dataset.route.indexOf(base) === 0);
  });
  renderRail(null);
}

/* ---------- account actions ---------- */

function changeOwnPassword() {
  var cur = h('input', { type: 'password', required: true, autocomplete: 'current-password' });
  var nw = h('input', { type: 'password', required: true, autocomplete: 'new-password', minlength: '10' });
  var nw2 = h('input', { type: 'password', required: true, autocomplete: 'new-password' });
  Modal.open({
    title: 'Change your password',
    body: h('div', null, field('Current password', cur), field('New password', nw),
                         field('Repeat new password', nw2)),
    onsubmit: function (close) {
      if (nw.value !== nw2.value) { Toast.err('Passwords do not match'); return; }
      if (nw.value.length < 10) { Toast.err('Password too short', 'at least 10 characters'); return; }
      var payload = { current: cur.value, next: nw.value };
      cur.value = nw.value = nw2.value = '';
      api.call('session.password', payload)
        .then(function () { close(); Toast.ok('Password changed'); })
        .catch(function (e) { failed('Change password', e); });
    },
    actions: [{ label: 'Cancel' }, { label: 'Change', kind: 'primary', submit: true }]
  });
}

function signOut() {
  api.call('session.logout').catch(function () {}).then(function () {
    ws.disconnect();
    S.me = null;
    clearTimeout(tickTimer);
    renderLogin(false);
  });
}

/** Reached from a 401 on any call, and from a 4401 close on the socket. */
function onUnauthorized() {
  if (!S.me) return;
  S.me = null;
  ws.disconnect();
  clearTimeout(tickTimer);
  currentView = null;
  renderLogin(false);
  Toast.warn('Signed out', 'The hub rejected the session. Sign in again.');
}

/* ---------- live events ---------- */

function wireEvents() {
  ws.on('#status', function (s) { setConn(s.status, s.detail); });
  ws.on('#unauthorized', function () { onUnauthorized(); });

  ws.on('#ready', function () {
    /* every reconnect can have missed changes: resync the authoritative list */
    if (S.me) loadInstances().then(refresh).catch(function () {});
  });

  ws.on('status', function (d) {
    var i = d && S.byId[d.id]; if (!i) return;
    if (d.state) i.state = d.state;
    if (d.botEnabled !== undefined) i.botEnabled = d.botEnabled;
    i.live = i.live || {};
    ['hp', 'maxHp', 'mana', 'maxMana', 'level', 'expPercent', 'target', 'waypoint',
     'waypointIndex', 'waypointCount', 'uptimeMs', 'onlineMs', 'pos', 'cap', 'maxCap',
     'soul', 'stamina'].forEach(function (k) { if (d[k] !== undefined) i.live[k] = d[k]; });
    markDirty(d.id);
  });

  ws.on('stats', function (d) {
    var i = d && S.byId[d.id]; if (!i) return;
    i.live = i.live || {};
    Object.keys(d).forEach(function (k) { if (k !== 'id' && k !== 't') i.live[k] = d[k]; });
    var pts = S.history[d.id] || (S.history[d.id] = []);
    pushCapped(pts, {
      t: d.t || Date.now(),
      expPerHour: d.expPerHour, moneyPerHour: d.moneyPerHour,
      killsPerHour: d.killsPerHour, level: d.level,
      hpPercent: pct(i.live.hp, i.live.maxHp), manaPercent: pct(i.live.mana, i.live.maxMana)
    }, 360);
    markDirty(d.id);
  });

  ws.on('instance', function (d) {
    if (!d) return;
    if (d.removed) {
      S.instances = S.instances.filter(function (i) { return i.id !== d.id; });
      indexInstances();
      refresh();
    } else if (d.instance) {
      var known = !!S.byId[d.instance.id];
      mergeInstance(d.instance);
      if (known) markDirty(d.instance.id); else refresh();
    }
  });

  ws.on('loginState', function (d) {
    var i = d && S.byId[d.id]; if (!i) return;
    if (d.state) i.state = d.state;
    markDirty(d.id);
  });

  ws.on('death', function (d) {
    var i = d && S.byId[d.id];
    Toast.err('Death', (i ? i.characterName : d.id) + ' died at level ' + (d.level || '?'));
  });

  ws.on('error', function (d) {
    var i = d && S.byId[d.id];
    Toast.err(i ? i.characterName : 'Worker', d && d.message ? d.message : 'unknown error');
  });

  ws.on('gameEnd', function (d) {
    var i = d && S.byId[d.id];
    if (i) Toast.warn(i.characterName + ' left the game', d.reason || '');
  });

  ws.on('*', function (ev, data) {
    if (currentView && currentView.onEvent) {
      try { currentView.onEvent(ev, data); } catch (e) { console.error(e); }
    }
  });
}

/* ---------- keyboard ---------- */

function wireKeys() {
  document.addEventListener('keydown', function (e) {
    var t = e.target;
    var typing = t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.tagName === 'SELECT' || t.isContentEditable);
    if (typing || e.ctrlKey || e.metaKey || e.altKey) return;
    if (!S.me) return;
    if (e.key === 'd') { go('#/dashboard'); e.preventDefault(); }
    else if (e.key === 'c') { go('#/characters'); e.preventDefault(); }
    else if (e.key === 's') { go('#/scripts'); e.preventDefault(); }
    else if (e.key === 'a' && isAdmin()) { go('#/admin/users'); e.preventDefault(); }
    else if (e.key === '?') {
      Modal.open({ title: 'Keyboard shortcuts', actions: [{ label: 'Close' }],
        body: h('dl.kv', null,
          ['d', 'Dashboard', 'c', 'Characters & accounts', 's', 'Scripts',
           'a', 'Admin (administrators only)', 'Esc', 'Close dialog',
           'Ctrl+Enter', 'Run the Lua box in the Console tab', '?', 'This help']
          .map(function (v, idx) { return h(idx % 2 ? 'dd' : 'dt', { text: v }); })) });
      e.preventDefault();
    }
  });
}

/* ---------- boot ---------- */

function startApp() {
  buildShell();
  wireEvents();
  ws.connect();

  loadInstances().then(function () {
    return api.call('scripts.list').then(function (r) { S.scripts = r.scripts || []; })
      .catch(function () {});
  }).then(function () {
    route();
    refresh();
  }).catch(function (e) {
    failed('Initial load', e);
    route();
  });

  /* one slow heartbeat so uptime counters move even between pushes */
  clearTimeout(tickTimer);
  (function tick() {
    tickTimer = setTimeout(function () {
      S.instances.forEach(function (i) {
        if (i.state !== 'stopped' && i.live) { i.live.uptimeMs = (i.live.uptimeMs || 0) + 1000; markDirty(i.id); }
      });
      tick();
    }, 1000);
  })();

  window.onhashchange = route;
}

function boot() {
  wireKeys();
  window.addEventListener('resize', function () { refresh(); });

  api.call('session.get', {}, { timeoutMs: 10000 }).then(function (r) {
    S.serverVersion = r.version || '';
    if (r.bootstrap) { renderLogin(true); return; }
    if (r.user) { S.me = r.user; startApp(); }
    else renderLogin(false);
  }).catch(function (e) {
    renderLogin(false);
    if (e.code !== 'unauthorized') failed('Contacting the hub', e);
  });
}

if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
else boot();

/* a tiny surface for debugging and for panel/test/tests.js */
window.Panel = { S: S, api: api, http: http, ws: ws, go: go, refresh: refresh,
                 markDirty: markDirty, MOCK: MOCK };

})();
