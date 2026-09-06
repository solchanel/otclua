/* ==================================================================
   panel/test/tests.js — DOM-free unit tests for the panel transport
   plus a contract-coverage check between api.js and mock/api.js.
   ------------------------------------------------------------------
   Runs in any browser: open panel/test/index.html. There is no test
   framework and no network; the HTTP client is driven with an
   injected fake fetch and the WebSocket client with a fake socket and
   a fake clock, so timing assertions are exact rather than flaky.

   The result is left on window.TESTS_RESULT = {pass, fail, total,
   failures:[...]} so a harness can read it without scraping the page.
   ================================================================== */

(function () {
'use strict';

var RPC = window.PanelRpc;
var APIDEF = window.PanelApi;

/* ----------------------------- runner ---------------------------- */

var tests = [];
function test(name, fn) { tests.push({ name: name, fn: fn }); }

function eq(a, b, what) {
  if (a !== b) throw new Error((what || 'value') + ': expected ' + JSON.stringify(b) +
                               ', got ' + JSON.stringify(a));
}
function ok(v, what) { if (!v) throw new Error((what || 'assertion') + ' is falsy'); }
function near(a, lo, hi, what) {
  if (!(a >= lo && a <= hi)) throw new Error((what || 'value') + ': ' + a + ' not in [' + lo + ',' + hi + ']');
}
async function throws(p, code, what) {
  try { await p; }
  catch (e) { if (code) eq(e.code, code, (what || 'error') + '.code'); return e; }
  throw new Error((what || 'call') + ' should have rejected');
}

/* --------------------------- fake clock -------------------------- */

function Clock() {
  this.t = 1000;
  this.seq = 0;
  this.timers = {};
}
Clock.prototype.setTimeout = function (fn, ms) {
  var id = ++this.seq;
  this.timers[id] = { at: this.t + (ms || 0), fn: fn, every: 0 };
  return id;
};
Clock.prototype.setInterval = function (fn, ms) {
  var id = ++this.seq;
  this.timers[id] = { at: this.t + (ms || 0), fn: fn, every: ms || 1 };
  return id;
};
Clock.prototype.clearTimeout = function (id) { delete this.timers[id]; };
Clock.prototype.clearInterval = function (id) { delete this.timers[id]; };
Clock.prototype.now = function () { return this.t; };
Clock.prototype.pending = function () {
  var out = [], k;
  for (k in this.timers) out.push(this.timers[k]);
  return out.sort(function (a, b) { return a.at - b.at; });
};
/** ms until the next timer would fire, or -1. */
Clock.prototype.nextIn = function () {
  var p = this.pending();
  return p.length ? p[0].at - this.t : -1;
};
/** advance, firing timers, flushing microtasks between each */
Clock.prototype.advance = async function (ms) {
  var end = this.t + ms;
  for (;;) {
    var p = this.pending();
    var due = p.filter(function (x) { return x.at <= end; });
    if (!due.length) break;
    var first = due[0];
    this.t = first.at;
    var id = null, k;
    for (k in this.timers) if (this.timers[k] === first) { id = k; break; }
    if (first.every) first.at = this.t + first.every; else delete this.timers[id];
    try { first.fn(); } catch (e) { /* a timer callback throwing is the test's problem */ }
    await flushMicro();
  }
  this.t = end;
  await flushMicro();
};
/** Drain the microtask queue: the client's promise chains are several `then`s
    deep, so one tick is not enough before asserting on what they scheduled. */
async function flushMicro() {
  for (var i = 0; i < 40; i++) await Promise.resolve();
}

/* --------------------------- fake fetch -------------------------- */

/** replies: array or function(url, init) -> {status, body} | {throw:'msg'} */
function fakeFetch(replies) {
  var calls = [];
  var idx = 0;
  var fn = function (url, init) {
    calls.push({ url: url, init: init, method: (init && init.method) || 'GET' });
    var r = typeof replies === 'function' ? replies(url, init, idx) : replies[Math.min(idx, replies.length - 1)];
    idx++;
    /* a hanging request that still honours AbortController, exactly as a real
       fetch does — otherwise the timeout path could not be tested at all */
    if (!r || r.hang) {
      return new Promise(function (_resolve, reject) {
        var sig = init && init.signal;
        if (sig) sig.addEventListener('abort', function () {
          var e = new Error('The user aborted a request.');
          e.name = 'AbortError';
          reject(e);
        });
      });
    }
    if (r.throw) return Promise.reject(new TypeError(r.throw));
    var text = r.text !== undefined ? r.text : JSON.stringify(r.body === undefined ? {} : r.body);
    return Promise.resolve({
      status: r.status || 200,
      ok: (r.status || 200) < 300,
      text: function () { return Promise.resolve(text); }
    });
  };
  fn.calls = calls;
  return fn;
}

/* ------------------------ fake WebSocket ------------------------- */

var sockets = [];
function FakeWS(url) {
  this.url = url;
  this.readyState = 0;
  this.sent = [];
  this.onopen = this.onmessage = this.onclose = this.onerror = null;
  sockets.push(this);
}
FakeWS.prototype.send = function (s) { this.sent.push(JSON.parse(s)); };
FakeWS.prototype.close = function (code) {
  if (this.readyState === 3) return;
  this.readyState = 3;
  if (this.onclose) this.onclose({ code: code || 1000 });
};
FakeWS.prototype.open = function () { this.readyState = 1; if (this.onopen) this.onopen({}); };
FakeWS.prototype.deliver = function (obj) { if (this.onmessage) this.onmessage({ data: JSON.stringify(obj) }); };
FakeWS.prototype.serverClose = function (code) {
  this.readyState = 3; if (this.onclose) this.onclose({ code: code || 1006 });
};

function mkWs(clock, opts) {
  sockets.length = 0;
  var o = {
    base: 'http://hub.test',
    getCsrf: function () { return 'tok-1'; },
    WebSocket: FakeWS,
    setTimeout: clock.setTimeout.bind(clock),
    clearTimeout: clock.clearTimeout.bind(clock),
    setInterval: clock.setInterval.bind(clock),
    clearInterval: clock.clearInterval.bind(clock),
    now: clock.now.bind(clock),
    random: function () { return 0.5 },        // jitter -> exactly the nominal delay
    backoff: { baseMs: 500, factor: 2, maxMs: 15000, jitter: 0.3, maxShift: 6 }
  };
  for (var k in (opts || {})) o[k] = opts[k];
  return new RPC.WsClient(o);
}

/* ========================== backoff ============================== */

test('backoff grows exponentially and is capped', function () {
  var half = function () { return 0.5; };            // jitter factor 1.0
  eq(RPC.backoffDelay(1, null, half), 500, 'attempt 1');
  eq(RPC.backoffDelay(2, null, half), 1000, 'attempt 2');
  eq(RPC.backoffDelay(3, null, half), 2000, 'attempt 3');
  eq(RPC.backoffDelay(4, null, half), 4000, 'attempt 4');
  eq(RPC.backoffDelay(5, null, half), 8000, 'attempt 5');
  eq(RPC.backoffDelay(6, null, half), 15000, 'attempt 6 hits the 15 s cap');
  eq(RPC.backoffDelay(99, null, half), 15000, 'attempt 99 stays capped');
});

test('backoff jitter stays inside +/-30% and never goes negative', function () {
  for (var attempt = 1; attempt <= 8; attempt++) {
    var nominal = Math.min(15000, 500 * Math.pow(2, Math.min(attempt - 1, 6)));
    for (var i = 0; i < 200; i++) {
      var d = RPC.backoffDelay(attempt, null, Math.random);
      near(d, Math.floor(nominal * 0.7), Math.ceil(nominal * 1.3), 'attempt ' + attempt);
    }
  }
  eq(RPC.backoffDelay(1, { baseMs: 100, jitter: 0 }, function () { return 0; }), 100, 'no jitter');
  ok(RPC.backoffDelay(1, null, function () { return 0; }) >= 0, 'never negative');
});

/* ========================== buildPath ============================ */

test('buildPath encodes parameters and query values', function () {
  eq(RPC.buildPath('/api/instances/:id/logs', { id: 'i 1' }, { limit: 400 }),
     '/api/instances/i%201/logs?limit=400');
  eq(RPC.buildPath('/api/instances/:id', { id: '../admin/users' }, null),
     '/api/instances/..%2Fadmin%2Fusers', 'a hostile id cannot escape its segment');
  eq(RPC.buildPath('/api/x', null, { a: '', b: null, c: undefined, d: 'v' }), '/api/x?d=v',
     'empty query values are dropped');
  eq(RPC.buildPath('/api/admin/audit', null, { q: 'a&b=c' }), '/api/admin/audit?q=a%26b%3Dc');
  var threw = false;
  try { RPC.buildPath('/api/x/:id', {}, null); } catch (e) { threw = e.code === 'bad-request'; }
  ok(threw, 'a missing path parameter throws');
});

/* ========================= HttpClient ============================ */

test('GET carries no CSRF header; unsafe verbs do', async function () {
  var f = fakeFetch([{ body: { ok: 1 } }, { body: { ok: 1 } }]);
  var c = new RPC.HttpClient({ fetch: f });
  c.setCsrf('tok-9');
  await c.get('/api/session');
  await c.post('/api/instances', { a: 1 });
  eq(f.calls[0].init.headers['X-CSRF-Token'], undefined, 'GET header');
  eq(f.calls[1].init.headers['X-CSRF-Token'], 'tok-9', 'POST header');
  eq(f.calls[1].init.credentials, 'same-origin', 'cookie mode');
  eq(f.calls[1].init.body, '{"a":1}', 'JSON body');
});

test('a csrfToken in any response body is adopted', async function () {
  var f = fakeFetch([{ body: { user: null, csrfToken: 'fresh' } }]);
  var c = new RPC.HttpClient({ fetch: f });
  await c.get('/api/session');
  eq(c.csrf, 'fresh', 'stored token');
});

test('an error envelope becomes an RpcError with its code', async function () {
  var f = fakeFetch([{ status: 409, body: { error: { code: 'conflict', message: 'already running' } } }]);
  var c = new RPC.HttpClient({ fetch: f });
  var e = await throws(c.post('/api/x', {}), 'conflict');
  eq(e.message, 'already running');
  eq(e.status, 409);
});

test('a bare 500 with no body still yields a coded error', async function () {
  var f = fakeFetch([{ status: 500, text: '' }, { status: 500, text: '' }]);
  var c = new RPC.HttpClient({ fetch: f, retries: 0 });
  await throws(c.post('/api/x', {}), 'http-500');
});

test('204/empty body resolves to {}', async function () {
  var f = fakeFetch([{ status: 204, text: '' }]);
  var c = new RPC.HttpClient({ fetch: f });
  var r = await c.del('/api/x');
  eq(JSON.stringify(r), '{}');
});

test('401 fires onUnauthorized exactly once and rejects', async function () {
  var hits = 0;
  var f = fakeFetch([{ status: 401, body: { error: { code: 'unauthorized', message: 'no session' } } }]);
  var c = new RPC.HttpClient({ fetch: f, onUnauthorized: function () { hits++; } });
  await throws(c.get('/api/instances'), 'unauthorized');
  eq(hits, 1, 'onUnauthorized calls');
});

test('a request times out and reports it', async function () {
  var clock = new Clock();
  var f = fakeFetch([{ hang: true }]);
  var c = new RPC.HttpClient({ fetch: f, timeoutMs: 5000, retries: 0,
    setTimeout: clock.setTimeout.bind(clock), clearTimeout: clock.clearTimeout.bind(clock) });
  var p = c.get('/api/instances');
  var caught = null;
  p.catch(function (e) { caught = e; });
  await clock.advance(4999);
  eq(caught, null, 'not yet');
  await clock.advance(2);
  ok(caught && caught.code === 'timeout', 'timeout raised');
  eq(c.inflight, 0, 'inflight released');
});

test('an idempotent GET retries once with backoff; a POST never does', async function () {
  var clock = new Clock();
  var f = fakeFetch(function (url, init, i) {
    return i === 0 ? { throw: 'connection refused' } : { body: { instances: [] } };
  });
  var c = new RPC.HttpClient({ fetch: f, retries: 1, random: function () { return 0.5; },
    setTimeout: clock.setTimeout.bind(clock), clearTimeout: clock.clearTimeout.bind(clock) });
  var done = null;
  c.get('/api/instances').then(function (r) { done = r; });
  await flushMicro();
  eq(f.calls.length, 1, 'first attempt');
  eq(clock.nextIn(), 250, 'waits one backoff step (250 ms base) before retrying');
  await clock.advance(260);
  ok(done, 'resolved after the retry');
  eq(f.calls.length, 2, 'exactly two attempts');
  eq(c.retried, 1, 'retry counter');

  var f2 = fakeFetch([{ throw: 'connection refused' }, { body: {} }]);
  var c2 = new RPC.HttpClient({ fetch: f2, retries: 1,
    setTimeout: clock.setTimeout.bind(clock), clearTimeout: clock.clearTimeout.bind(clock) });
  await throws(c2.post('/api/instances/actions', { action: 'stop', ids: [] }), 'network');
  eq(f2.calls.length, 1, 'a write is never replayed automatically');
});

test('a retry gives up after the configured number of attempts', async function () {
  var clock = new Clock();
  var f = fakeFetch([{ throw: 'down' }, { throw: 'down' }, { throw: 'down' }, { throw: 'down' }]);
  var c = new RPC.HttpClient({ fetch: f, retries: 2, random: function () { return 0.5; },
    setTimeout: clock.setTimeout.bind(clock), clearTimeout: clock.clearTimeout.bind(clock) });
  var err = null;
  c.get('/api/x').catch(function (e) { err = e; });
  await flushMicro();
  await clock.advance(250);       // retry 1
  await clock.advance(500);       // retry 2
  await clock.advance(2000);
  ok(err && err.code === 'network', 'final rejection');
  eq(f.calls.length, 3, 'one original + two retries');
});

test('a stale CSRF token is refreshed and the call replayed once', async function () {
  var refreshed = 0;
  var f = fakeFetch(function (url, init, i) {
    if (i === 0) return { status: 403, body: { error: { code: 'csrf-invalid', message: 'stale' } } };
    return { body: { instance: { id: 'i_1' } } };
  });
  var c = new RPC.HttpClient({ fetch: f });
  c.refreshCsrf = function () { refreshed++; c.setCsrf('tok-2'); return Promise.resolve(); };
  c.setCsrf('tok-1');
  var r = await c.patch('/api/instances/i_1', { autoStart: true });
  eq(refreshed, 1, 'refresh calls');
  eq(f.calls.length, 2, 'attempts');
  eq(f.calls[1].init.headers['X-CSRF-Token'], 'tok-2', 'replayed with the new token');
  ok(r.instance, 'result returned');
});

test('a second csrf failure is surfaced, not looped', async function () {
  var f = fakeFetch([{ status: 403, body: { error: { code: 'csrf-invalid', message: 'stale' } } },
                     { status: 403, body: { error: { code: 'csrf-invalid', message: 'stale' } } },
                     { status: 403, body: { error: { code: 'csrf-invalid', message: 'stale' } } }]);
  var c = new RPC.HttpClient({ fetch: f });
  c.refreshCsrf = function () { return Promise.resolve(); };
  await throws(c.post('/api/x', {}), 'csrf-invalid');
  eq(f.calls.length, 2, 'exactly one replay');
});

/* ========================== WsClient ============================= */

test('the socket authenticates, then reports live', async function () {
  var clock = new Clock();
  var w = mkWs(clock);
  var seen = [];
  w.on('#status', function (s) { seen.push(s.status); });
  w.connect();
  eq(sockets.length, 1, 'socket opened');
  eq(w.url(), 'ws://hub.test/ws', 'ws url from the http base');
  sockets[0].open();
  eq(JSON.stringify(sockets[0].sent[0]), '{"type":"auth","csrf":"tok-1"}', 'auth frame');
  eq(w.status, 'connecting', 'not live until the hub answers');
  sockets[0].deliver({ event: 'ready', data: { version: 'x' } });
  eq(w.status, 'live', 'live after ready');
  eq(seen.join(','), 'connecting,live');
});

test('events reach handlers and the wildcard, but control frames do not', async function () {
  var clock = new Clock();
  var w = mkWs(clock);
  var got = [], star = [];
  w.on('status', function (d) { got.push(d.id); });
  w.on('*', function (ev) { star.push(ev); });
  w.connect(); sockets[0].open();
  sockets[0].deliver({ event: 'ready', data: {} });
  sockets[0].deliver({ event: 'status', data: { id: 'i_1' } });
  sockets[0].deliver({ event: 'pong', data: { t: 1 } });
  sockets[0].deliver('not json at all');
  eq(got.join(','), 'i_1');
  eq(star.join(','), 'status', 'ready/pong are control frames, and garbage is ignored');
});

test('a dropped socket reconnects with growing backoff', async function () {
  var clock = new Clock();
  var w = mkWs(clock);
  w.connect(); sockets[0].open(); sockets[0].deliver({ event: 'ready', data: {} });

  sockets[0].serverClose(1006);
  eq(w.status, 'retry', 'first drop');
  eq(clock.nextIn(), 500, 'first retry after 500 ms');
  await clock.advance(500);
  eq(sockets.length, 2, 'reconnected');

  sockets[1].serverClose(1006);
  eq(clock.nextIn(), 1000, 'second retry after 1 s');
  await clock.advance(1000);
  sockets[2].serverClose(1006);
  eq(clock.nextIn(), 2000, 'third retry after 2 s');
  await clock.advance(2000);
  sockets[3].serverClose(1006);
  eq(w.status, 'down', 'reported offline after four failures');
  eq(clock.nextIn(), 4000, 'fourth retry after 4 s');
  await clock.advance(4000);

  /* a successful handshake resets the ladder */
  sockets[4].open(); sockets[4].deliver({ event: 'ready', data: {} });
  eq(w.status, 'live');
  sockets[4].serverClose(1006);
  eq(clock.nextIn(), 500, 'backoff reset to the base delay');
});

test('close code 4401 stops retrying and reports unauthorized', async function () {
  var clock = new Clock();
  var w = mkWs(clock);
  var unauth = 0;
  w.on('#unauthorized', function () { unauth++; });
  w.connect(); sockets[0].open();
  sockets[0].serverClose(4401);
  eq(unauth, 1, 'unauthorized fired');
  eq(w.wanted, false, 'no further attempts wanted');
  await clock.advance(60000);
  eq(sockets.length, 1, 'never reconnected');
});

test('a hub that never answers the auth frame is retried', async function () {
  var clock = new Clock();
  var w = mkWs(clock, { authTimeoutMs: 3000 });
  w.connect(); sockets[0].open();
  await clock.advance(2999);
  eq(sockets.length, 1, 'still waiting');
  await clock.advance(2);
  eq(w.status, 'retry', 'gave up on the handshake');
  await clock.advance(500);
  eq(sockets.length, 2, 'opened a new socket');
});

test('heartbeat pings, and a silent socket is recycled', async function () {
  var clock = new Clock();
  var w = mkWs(clock, { heartbeatMs: 1000, staleMs: 4000 });
  w.connect(); sockets[0].open(); sockets[0].deliver({ event: 'ready', data: {} });
  await clock.advance(1000);
  var frames = sockets[0].sent;                       // auth, subscribe, ping
  eq(frames[frames.length - 1].type, 'ping', 'a ping was sent');
  await clock.advance(1000);
  sockets[0].deliver({ event: 'status', data: {} });      // traffic resets the staleness clock
  await clock.advance(3000);
  eq(sockets.length, 1, 'still alive while traffic flows');
  await clock.advance(5000);
  ok(sockets.length > 1 || w.status === 'retry', 'a silent socket is dropped and retried');
});

test('subscriptions are (re)sent after every successful handshake', async function () {
  var clock = new Clock();
  var w = mkWs(clock);
  w.connect(); sockets[0].open(); sockets[0].deliver({ event: 'ready', data: {} });
  w.subscribe('i_7', null);
  var last = sockets[0].sent[sockets[0].sent.length - 1];
  eq(JSON.stringify(last), '{"type":"subscribe","logs":"i_7","chat":null}');
  sockets[0].serverClose(1006);
  await clock.advance(500);
  sockets[1].open(); sockets[1].deliver({ event: 'ready', data: {} });
  var resub = sockets[1].sent.filter(function (f) { return f.type === 'subscribe'; })[0];
  eq(JSON.stringify(resub), '{"type":"subscribe","logs":"i_7","chat":null}', 'resubscribed');
});

test('disconnect() is final', async function () {
  var clock = new Clock();
  var w = mkWs(clock);
  w.connect(); sockets[0].open(); sockets[0].deliver({ event: 'ready', data: {} });
  w.disconnect();
  eq(w.status, 'idle');
  await clock.advance(60000);
  eq(sockets.length, 1, 'no reconnect after an explicit disconnect');
});

/* ==================== contract coverage ========================== */

test('every endpoint in api.js is answered by the mock', function () {
  ok(window.HubMock, 'the mock is loaded');
  var routes = {};
  window.HubMock._routes().forEach(function (k) { routes[k] = true; });
  var missing = [];
  Object.keys(APIDEF.ENDPOINTS).forEach(function (name) {
    var ep = APIDEF.ENDPOINTS[name];
    var key = ep.method + ' ' + ep.path;
    if (!routes[key]) missing.push(name + ' -> ' + key);
  });
  eq(missing.join(' | '), '', 'endpoints with no mock route');
});

test('the mock has no routes the panel never calls', function () {
  var used = {};
  Object.keys(APIDEF.ENDPOINTS).forEach(function (name) {
    var ep = APIDEF.ENDPOINTS[name];
    used[ep.method + ' ' + ep.path] = true;
  });
  var orphans = window.HubMock._routes().filter(function (k) { return !used[k]; });
  eq(orphans.join(' | '), '', 'mock routes with no endpoint');
});

test('the endpoint table is well formed', function () {
  var names = Object.keys(APIDEF.ENDPOINTS);
  ok(names.length >= 40, 'endpoint count (' + names.length + ')');
  names.forEach(function (n) {
    var ep = APIDEF.ENDPOINTS[n];
    ok(/^(GET|POST|PUT|PATCH|DELETE)$/.test(ep.method), n + ' method');
    ok(ep.path.indexOf('/api/') === 0, n + ' path starts with /api/');
    /* every :param in the path must be declared, and vice versa */
    var inPath = (ep.path.match(/:[A-Za-z_][A-Za-z0-9_]*/g) || [])
      .map(function (s) { return s.slice(1); }).sort().join(',');
    var declared = (ep.params || []).slice().sort().join(',');
    eq(declared, inPath, n + ' params');
    /* a read must never take a body, a write must never be a GET */
    if (ep.method === 'GET') ok(!ep.body, n + ' GET has no body');
  });
});

test('Api.call splits arguments into path, query and body', async function () {
  var f = fakeFetch(function () { return { body: { lines: [] } }; });
  var c = new RPC.HttpClient({ fetch: f });
  var a = new APIDEF.Api(c);
  await a.call('instances.logs', { id: 'i_1', limit: 400 });
  eq(f.calls[0].url, '/api/instances/i_1/logs?limit=400');
  eq(f.calls[0].method, 'GET');
  eq(f.calls[0].init.body, undefined, 'a GET has no body');

  await a.call('instances.macro', { id: 'i_1', name: 'healbot', on: true });
  eq(f.calls[1].url, '/api/instances/i_1/macros/healbot');
  eq(f.calls[1].method, 'PUT');
  eq(f.calls[1].init.body, '{"on":true}', 'the rest of the args are the body');

  await a.call('admin.audit', { actor: 'arnold', limit: 100 });
  eq(f.calls[2].url, '/api/admin/audit?actor=arnold&limit=100');
});

test('a failed call reports which endpoint it was', async function () {
  var f = fakeFetch([{ status: 404, body: { error: { code: 'not-found', message: 'gone' } } }]);
  var a = new APIDEF.Api(new RPC.HttpClient({ fetch: f, retries: 0 }));
  var e = await throws(a.call('instances.get', { id: 'i_x' }), 'not-found');
  eq(e.endpoint, 'instances.get');
  eq(e.method, 'GET');
  eq(e.path, '/api/instances/i_x');
});

test('an unknown endpoint name rejects instead of guessing a URL', async function () {
  var a = new APIDEF.Api(new RPC.HttpClient({ fetch: fakeFetch([{ body: {} }]) }));
  await throws(a.call('nope.nothing', {}), 'internal');
});

/* =============== end-to-end against the mock transport =========== */

test('the mock refuses a write without the CSRF header', async function () {
  var c = new RPC.HttpClient({ fetch: window.HubMock.fetch });
  window.HubMock.latencyMs = 0;
  c.setCsrf('not-the-real-token');
  await throws(c.post('/api/session', { name: 'arnold', password: 'secret' }), 'csrf-invalid');
});

test('the mock login/logout round trip works through the real client', async function () {
  window.HubMock.latencyMs = 0;
  var unauthorized = 0;
  var c = new RPC.HttpClient({ fetch: window.HubMock.fetch,
                               onUnauthorized: function () { unauthorized++; } });
  var a = new APIDEF.Api(c);

  var s0 = await a.call('session.get');
  eq(s0.user, null, 'signed out at first');
  ok(c.csrf, 'a token was handed out');

  await throws(a.call('instances.list'), 'unauthorized');
  eq(unauthorized, 1, 'the 401 was reported');

  var login = await a.call('session.login', { name: 'arnold', password: 'hunter22' });
  eq(login.user.role, 'admin');
  var list = await a.call('instances.list');
  ok(list.instances.length >= 5, 'instances came back');

  /* the write-only rule: no password field anywhere in the account projection */
  var accs = await a.call('accounts.list');
  var json = JSON.stringify(accs);
  ok(json.indexOf('password') < 0, 'no password field in accounts.list');
  ok(json.indexOf('pass"') < 0, 'no pass field either');
  var pxs = await a.call('proxies.list');
  ok(JSON.stringify(pxs).indexOf('"pass"') < 0, 'no proxy password in proxies.list');

  await a.call('session.logout');
  var s1 = await a.call('session.get');
  eq(s1.user, null, 'signed out again');
});

test('a non-admin is refused the admin endpoints by the mock', async function () {
  window.HubMock.latencyMs = 0;
  var c = new RPC.HttpClient({ fetch: window.HubMock.fetch });
  var a = new APIDEF.Api(c);
  await a.call('session.get');
  await a.call('session.login', { name: 'sam', password: 'hunter22' });
  await throws(a.call('admin.users'), 'forbidden');
  await throws(a.call('admin.audit', { limit: 10 }), 'forbidden');
  await a.call('session.logout');
});

test('the mock WebSocket refuses a bad auth frame and accepts a good one', async function () {
  window.HubMock.latencyMs = 0;
  var c = new RPC.HttpClient({ fetch: window.HubMock.fetch });
  var a = new APIDEF.Api(c);
  await a.call('session.get');
  await a.call('session.login', { name: 'arnold', password: 'hunter22' });

  /* wrong token -> 4401 -> the client reports #unauthorized and stops */
  var bad = new RPC.WsClient({ base: '', getCsrf: function () { return 'wrong'; },
                               WebSocket: window.HubMock.WebSocket });
  var refused = await new Promise(function (resolve) {
    bad.on('#unauthorized', function () { resolve(true); });
    bad.connect();
    setTimeout(function () { resolve(false); }, 500);
  });
  ok(refused, 'a bad CSRF token is refused on the socket too');

  var good = new RPC.WsClient({ base: '', getCsrf: function () { return c.csrf; },
                                WebSocket: window.HubMock.WebSocket });
  var ready = await new Promise(function (resolve) {
    good.on('#ready', function () { resolve(true); });
    good.connect();
    setTimeout(function () { resolve(false); }, 1000);
  });
  ok(ready, 'the handshake completed');
  eq(good.status, 'live');
  good.disconnect();
  await a.call('session.logout');
});

/* ============================ run ================================ */

async function run() {
  var out = document.getElementById('out');
  var pass = 0, fail = 0, failures = [];
  for (var i = 0; i < tests.length; i++) {
    var t = tests[i];
    var line = document.createElement('div');
    try {
      await t.fn();
      pass++;
      line.className = 'p';
      line.textContent = 'PASS  ' + t.name;
    } catch (e) {
      fail++;
      failures.push(t.name + ': ' + (e && e.message ? e.message : String(e)));
      line.className = 'f';
      line.textContent = 'FAIL  ' + t.name + '\n      ' + (e && e.message ? e.message : String(e));
    }
    if (out) out.appendChild(line);
  }
  var sum = document.createElement('div');
  sum.className = fail ? 'f sum' : 'p sum';
  sum.textContent = (fail ? 'FAILED' : 'OK') + ' — ' + pass + ' passed, ' + fail + ' failed, ' +
                    tests.length + ' total';
  if (out) out.appendChild(sum);
  window.TESTS_RESULT = { pass: pass, fail: fail, total: tests.length, failures: failures };
  if (window.console) console.log(sum.textContent);
}

if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', run);
else run();

})();
