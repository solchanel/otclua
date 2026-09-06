/* ==================================================================
   panel/rpc.js — the transport half of the panel.
   ------------------------------------------------------------------
   Two objects, both usable without a DOM (panel/test/tests.js drives
   them with fake timers, a fake fetch and a fake WebSocket):

     HttpClient  JSON over fetch: session cookie, CSRF header on every
                 state-changing verb, per-request timeout, one retry
                 for idempotent requests, 401 -> onUnauthorized.
     WsClient    the /ws event stream: authenticate, heartbeat,
                 reconnect with exponential backoff + jitter.

   Security rules that are load-bearing here:
     * The session is an HttpOnly cookie the hub sets. Nothing in this
       file reads, writes or stores a session id, and no token of any
       kind is ever put into localStorage or a URL.
     * The CSRF token lives in a closure variable for the lifetime of
       the page and is sent ONLY as the X-CSRF-Token request header.
     * credentials:'same-origin' — the cookie is never sent to a
       cross-origin base.

   Installs window.PanelRpc = {RpcError, HttpClient, WsClient,
                               backoffDelay, buildPath, VERSION}
   (and module.exports when a CommonJS loader is present).
   ================================================================== */

(function (global) {
'use strict';

var VERSION = '2.0';

/* ============================ errors ============================= */

/**
 * Every rejection from this file is an RpcError.
 *   code    a stable machine string: 'unauthorized', 'forbidden', 'not-found',
 *           'conflict', 'bad-request', 'rate-limited', 'csrf-invalid',
 *           'timeout', 'network', 'bad-response', 'internal', 'http-<n>'
 *   status  the HTTP status when there was one, else 0
 */
function RpcError(code, message, status) {
  this.name = 'RpcError';
  this.code = code || 'internal';
  this.message = message || 'request failed';
  this.status = status || 0;
  if (Error.captureStackTrace) Error.captureStackTrace(this, RpcError);
}
RpcError.prototype = Object.create(Error.prototype);
RpcError.prototype.constructor = RpcError;

function isRpcError(e) { return !!e && e.name === 'RpcError'; }

/* =========================== backoff ============================= */

var BACKOFF = { baseMs: 500, factor: 2, maxMs: 15000, jitter: 0.3, maxShift: 6 };

/**
 * backoffDelay(attempt, opts, random) -> ms
 *   attempt 1 is the first retry. Exponential with a hard ceiling, then
 *   full +/- `jitter` scaling so a fleet of tabs does not resynchronise.
 *   `random` defaults to Math.random and is injected by the tests, which
 *   is why this is a pure function and not a method.
 */
function backoffDelay(attempt, opts, random) {
  var o = opts || BACKOFF;
  var base = o.baseMs === undefined ? BACKOFF.baseMs : o.baseMs;
  var factor = o.factor === undefined ? BACKOFF.factor : o.factor;
  var maxMs = o.maxMs === undefined ? BACKOFF.maxMs : o.maxMs;
  var jitter = o.jitter === undefined ? BACKOFF.jitter : o.jitter;
  var maxShift = o.maxShift === undefined ? BACKOFF.maxShift : o.maxShift;
  var n = Math.max(1, Math.floor(attempt));
  var raw = base * Math.pow(factor, Math.min(n - 1, maxShift));
  raw = Math.min(maxMs, raw);
  if (!jitter) return Math.round(raw);
  var r = (random || Math.random)();
  return Math.max(0, Math.round(raw * (1 - jitter + r * jitter * 2)));
}

/* ========================= path building ========================= */

/**
 * buildPath('/api/instances/:id/logs', {id:'i 1'}, {limit:400})
 *   -> '/api/instances/i%201/logs?limit=400'
 * Every substituted segment and every query value is percent-encoded, so an
 * id that came from the server can never inject a path segment or a parameter.
 */
function buildPath(template, params, query) {
  var out = String(template).replace(/:([A-Za-z_][A-Za-z0-9_]*)/g, function (m, name) {
    var v = params ? params[name] : undefined;
    if (v === undefined || v === null || v === '') {
      throw new RpcError('bad-request', 'missing path parameter "' + name + '" for ' + template);
    }
    return encodeURIComponent(String(v));
  });
  var qs = [];
  if (query) {
    for (var k in query) {
      if (!Object.prototype.hasOwnProperty.call(query, k)) continue;
      var qv = query[k];
      if (qv === undefined || qv === null || qv === '') continue;
      qs.push(encodeURIComponent(k) + '=' + encodeURIComponent(String(qv)));
    }
  }
  return qs.length ? out + '?' + qs.join('&') : out;
}

/* ========================== HttpClient =========================== */

var SAFE_METHOD = { GET: true, HEAD: true, OPTIONS: true };

/**
 * new HttpClient({
 *   base:'',                  // hub origin override, '' = same origin
 *   timeoutMs:15000,
 *   retries:1,                // idempotent requests only
 *   fetch:window.fetch,       // injectable
 *   setTimeout/clearTimeout,  // injectable
 *   random:Math.random,       // injectable (backoff jitter)
 *   onUnauthorized:fn,        // called once per 401
 *   onCsrfToken:fn(token),    // hub handed us a fresh token
 *   refreshCsrf:fn -> Promise // re-fetch the token after a csrf-invalid
 * })
 */
function HttpClient(opts) {
  opts = opts || {};
  this.base = opts.base || '';
  this.timeoutMs = opts.timeoutMs || 15000;
  this.retries = opts.retries === undefined ? 1 : opts.retries;
  this.backoff = opts.backoff || { baseMs: 250, factor: 2, maxMs: 4000, jitter: 0.3, maxShift: 4 };
  this._fetch = opts.fetch || (typeof fetch !== 'undefined' ? fetch.bind(global) : null);
  this._setTimeout = opts.setTimeout || function (fn, ms) { return setTimeout(fn, ms); };
  this._clearTimeout = opts.clearTimeout || function (t) { return clearTimeout(t); };
  this._random = opts.random || Math.random;
  this._AbortController = opts.AbortController ||
    (typeof AbortController !== 'undefined' ? AbortController : null);
  this.onUnauthorized = opts.onUnauthorized || null;
  this.onCsrfToken = opts.onCsrfToken || null;
  this.refreshCsrf = opts.refreshCsrf || null;
  this.csrf = '';
  this.inflight = 0;
  this.calls = 0;                      // diagnostics; the tests assert on it
  this.retried = 0;
}

HttpClient.prototype.setCsrf = function (token) {
  this.csrf = token ? String(token) : '';
  if (this.onCsrfToken) this.onCsrfToken(this.csrf);
  return this.csrf;
};

/**
 * request(method, path, body, opt) -> Promise<object>
 *   Resolves with the parsed JSON body (an object, {} for 204).
 *   Rejects with an RpcError for every failure, including HTTP errors.
 * opt: {timeoutMs, retries, noCsrfRetry}
 */
HttpClient.prototype.request = function (method, path, body, opt) {
  var self = this;
  opt = opt || {};
  method = String(method).toUpperCase();
  var maxRetry = opt.retries === undefined
    ? (SAFE_METHOD[method] ? this.retries : 0)
    : opt.retries;

  this.calls++;

  function attempt(n) {
    return self._once(method, path, body, opt).catch(function (e) {
      /* one silent retry for reads that never reached a handler */
      var retryable = (e.code === 'network' || e.code === 'timeout' ||
                       (e.status >= 500 && e.status <= 599));
      if (retryable && n < maxRetry) {
        self.retried++;
        var wait = backoffDelay(n + 1, self.backoff, self._random);
        return new Promise(function (resolve) { self._setTimeout(resolve, wait); })
          .then(function () { return attempt(n + 1); });
      }
      /* the token went stale (hub restarted, session rotated): get a new one and
         replay exactly once, so a click does not silently do nothing */
      if (e.code === 'csrf-invalid' && !opt.noCsrfRetry && self.refreshCsrf) {
        return Promise.resolve(self.refreshCsrf()).then(function () {
          return self._once(method, path, body, { timeoutMs: opt.timeoutMs, noCsrfRetry: true });
        });
      }
      throw e;
    });
  }
  return attempt(0);
};

HttpClient.prototype._once = function (method, path, body, opt) {
  var self = this;
  if (!this._fetch) return Promise.reject(new RpcError('internal', 'no fetch implementation'));

  var ctrl = this._AbortController ? new this._AbortController() : null;
  var timedOut = false;
  var ms = opt.timeoutMs || this.timeoutMs;
  var timer = this._setTimeout(function () {
    timedOut = true;
    if (ctrl) { try { ctrl.abort(); } catch (e) {} }
  }, ms);

  var headers = { 'Accept': 'application/json' };
  if (body !== undefined && body !== null) headers['Content-Type'] = 'application/json';
  if (!SAFE_METHOD[method]) headers['X-CSRF-Token'] = this.csrf || '';
  headers['X-Requested-With'] = 'panel';       // a second, header-only CSRF signal

  var init = {
    method: method,
    credentials: 'same-origin',
    cache: 'no-store',
    redirect: 'error',
    headers: headers
  };
  if (body !== undefined && body !== null) init.body = JSON.stringify(body);
  if (ctrl) init.signal = ctrl.signal;

  this.inflight++;
  var done = false;
  function finish() { if (!done) { done = true; self.inflight--; self._clearTimeout(timer); } }

  return Promise.resolve()
    .then(function () { return self._fetch(self.base + path, init); })
    .then(function (res) {
      return Promise.resolve(res.text ? res.text() : '').then(function (text) {
        return self._interpret(res, text);
      });
    })
    .then(function (v) { finish(); return v; },
          function (e) {
            finish();
            if (isRpcError(e)) throw e;
            if (timedOut) throw new RpcError('timeout', 'the hub did not answer in ' + ms + ' ms');
            throw new RpcError('network', (e && e.message) ? e.message : 'network error');
          });
};

HttpClient.prototype._interpret = function (res, text) {
  var status = res.status || 0;
  var data = null;
  if (text) {
    try { data = JSON.parse(text); }
    catch (e) {
      if (status >= 200 && status < 300) {
        throw new RpcError('bad-response', 'HTTP ' + status + ': the body is not JSON', status);
      }
      data = null;
    }
  }
  if (data && typeof data === 'object' && data.csrfToken) this.setCsrf(data.csrfToken);

  if (status >= 200 && status < 300) return (data && typeof data === 'object') ? data : {};

  var code = (data && data.error && data.error.code) || null;
  var msg = (data && data.error && data.error.message) || null;
  if (!code) {
    code = status === 401 ? 'unauthorized'
         : status === 403 ? 'forbidden'
         : status === 404 ? 'not-found'
         : status === 409 ? 'conflict'
         : status === 413 ? 'too-large'
         : status === 429 ? 'rate-limited'
         : status === 400 ? 'bad-request'
         : 'http-' + status;
  }
  if (status === 401) {
    if (this.onUnauthorized) { try { this.onUnauthorized(); } catch (e) {} }
    throw new RpcError('unauthorized', msg || 'the session is not valid', status);
  }
  throw new RpcError(code, msg || ('HTTP ' + status), status);
};

/* sugar */
HttpClient.prototype.get = function (p, o) { return this.request('GET', p, null, o); };
HttpClient.prototype.post = function (p, b, o) { return this.request('POST', p, b === undefined ? {} : b, o); };
HttpClient.prototype.put = function (p, b, o) { return this.request('PUT', p, b === undefined ? {} : b, o); };
HttpClient.prototype.patch = function (p, b, o) { return this.request('PATCH', p, b === undefined ? {} : b, o); };
HttpClient.prototype.del = function (p, o) { return this.request('DELETE', p, null, o); };

/* =========================== WsClient ============================ */

/**
 * The event stream. One socket for the whole page.
 *
 *   client -> hub   {"type":"auth","csrf":"<token>"}          first frame, always
 *                   {"type":"subscribe","logs":<id|null>,"chat":<id|null>}
 *                   {"type":"ping","t":<ms>}
 *   hub -> client   {"event":"ready","data":{...}}            answer to auth
 *                   {"event":"<name>","data":{...}}
 *                   close 4401                                 auth refused
 *
 * States: idle -> connecting -> live -> retry -> down (-> connecting ...)
 */
function WsClient(opts) {
  opts = opts || {};
  this.base = opts.base || '';
  this.path = opts.path || '/ws';
  this.getCsrf = opts.getCsrf || function () { return ''; };
  this.backoff = opts.backoff || BACKOFF;
  this.authTimeoutMs = opts.authTimeoutMs || 10000;
  this.heartbeatMs = opts.heartbeatMs || 25000;
  this.staleMs = opts.staleMs || 70000;
  this.downAfter = opts.downAfter || 4;

  this._WS = opts.WebSocket || (typeof WebSocket !== 'undefined' ? WebSocket : null);
  this._setTimeout = opts.setTimeout || function (fn, ms) { return setTimeout(fn, ms); };
  this._clearTimeout = opts.clearTimeout || function (t) { return clearTimeout(t); };
  this._setInterval = opts.setInterval || function (fn, ms) { return setInterval(fn, ms); };
  this._clearInterval = opts.clearInterval || function (t) { return clearInterval(t); };
  this._now = opts.now || function () { return Date.now(); };
  this._random = opts.random || Math.random;
  this._location = opts.location || (typeof location !== 'undefined' ? location : null);

  this.handlers = Object.create(null);
  this.ws = null;
  this.wanted = false;
  this.attempts = 0;
  this.status = 'idle';
  this.lastRxAt = 0;
  this.opens = 0;                       // diagnostics for the tests
  this.subs = { logs: null, chat: null };
  this._retryTimer = null;
  this._authTimer = null;
  this._hbTimer = null;
}

WsClient.prototype.on = function (ev, fn) {
  (this.handlers[ev] || (this.handlers[ev] = [])).push(fn);
  return this;
};
WsClient.prototype.emit = function (ev, data) {
  var list = this.handlers[ev], i;
  if (list) for (i = 0; i < list.length; i++) {
    try { list[i](data); } catch (e) { if (global.console) console.error('ws handler ' + ev, e); }
  }
  var any = this.handlers['*'];
  if (any && ev.charAt(0) !== '#') for (i = 0; i < any.length; i++) {
    try { any[i](ev, data); } catch (e) { if (global.console) console.error('ws handler *', e); }
  }
};

WsClient.prototype._setStatus = function (s, detail) {
  if (this.status === s && !detail) return;
  this.status = s;
  this.emit('#status', { status: s, detail: detail || '' });
};

WsClient.prototype.url = function () {
  if (this.base) return this.base.replace(/^http/, 'ws') + this.path;
  var loc = this._location;
  var proto = (loc && loc.protocol === 'https:') ? 'wss://' : 'ws://';
  return proto + ((loc && loc.host) || 'localhost') + this.path;
};

WsClient.prototype.connect = function () {
  this.wanted = true;
  this.attempts = 0;
  this._open();
};

WsClient.prototype.disconnect = function () {
  this.wanted = false;
  this._clearTimers();
  if (this.ws) {
    var w = this.ws; this.ws = null;
    try { w.onclose = null; w.onmessage = null; w.onerror = null; w.onopen = null; w.close(); } catch (e) {}
  }
  this._setStatus('idle');
};

WsClient.prototype._clearTimers = function () {
  this._clearTimeout(this._retryTimer); this._retryTimer = null;
  this._clearTimeout(this._authTimer); this._authTimer = null;
  if (this._hbTimer) { this._clearInterval(this._hbTimer); this._hbTimer = null; }
};

WsClient.prototype._open = function () {
  var self = this;
  if (!this.wanted || this.ws) return;
  if (!this._WS) { this._setStatus('down', 'this browser has no WebSocket'); return; }
  this._setStatus(this.attempts ? 'retry' : 'connecting');

  var ws;
  try { ws = new this._WS(this.url()); }
  catch (e) { this._retry('cannot open the socket'); return; }
  this.ws = ws;
  this.authed = false;

  ws.onopen = function () {
    self.opens++;
    self.lastRxAt = self._now();
    self._send({ type: 'auth', csrf: self.getCsrf() });
    /* the hub must answer with {event:'ready'}; if it does not, this is not our hub
       (or a proxy is buffering) and retrying beats hanging on a silent socket */
    self._authTimer = self._setTimeout(function () {
      if (!self.authed) { self._drop(); self._retry('no answer to the auth frame'); }
    }, self.authTimeoutMs);
  };

  ws.onmessage = function (m) {
    self.lastRxAt = self._now();
    var frame;
    try { frame = JSON.parse(m.data); } catch (e) { return; }
    if (!frame || typeof frame !== 'object') return;
    if (frame.event === 'ready') {
      self.authed = true;
      self.attempts = 0;
      self._clearTimeout(self._authTimer); self._authTimer = null;
      self._startHeartbeat();
      self._resubscribe();
      self._setStatus('live');
      self.emit('#ready', frame.data || {});
      return;
    }
    if (frame.event === 'pong') return;
    if (!frame.event) return;
    self.emit(frame.event, frame.data);
  };

  ws.onerror = function () { /* onclose always follows; nothing to do here */ };

  ws.onclose = function (e) {
    var code = e && e.code;
    self.ws = null;
    self._clearTimers();
    if (!self.wanted) { self._setStatus('idle'); return; }
    if (code === 4401 || code === 4403) {        // the hub says: not authenticated
      self.wanted = false;
      self._setStatus('idle');
      self.emit('#unauthorized', { code: code });
      return;
    }
    self._retry('socket closed' + (code ? ' (' + code + ')' : ''));
  };
};

WsClient.prototype._drop = function () {
  if (!this.ws) return;
  var w = this.ws; this.ws = null;
  try { w.onclose = null; w.onmessage = null; w.onerror = null; w.close(); } catch (e) {}
};

WsClient.prototype._retry = function (why) {
  var self = this;
  if (!this.wanted) return;
  this._clearTimers();
  this.attempts++;
  var wait = backoffDelay(this.attempts, this.backoff, this._random);
  this._setStatus(this.attempts >= this.downAfter ? 'down' : 'retry',
                  why + ' — retrying in ' + (Math.round(wait / 100) / 10) + ' s');
  this._retryTimer = this._setTimeout(function () { self._retryTimer = null; self._open(); }, wait);
};

WsClient.prototype._startHeartbeat = function () {
  var self = this;
  if (this._hbTimer) this._clearInterval(this._hbTimer);
  this._hbTimer = this._setInterval(function () {
    if (!self.ws) return;
    /* a TCP connection can be dead for minutes without a FIN (a laptop lid, a
       NAT timeout). No frame for staleMs means dead: drop it and back off. */
    if (self._now() - self.lastRxAt > self.staleMs) {
      self._drop();
      self._retry('no traffic for ' + Math.round(self.staleMs / 1000) + ' s');
      return;
    }
    self._send({ type: 'ping', t: self._now() });
  }, this.heartbeatMs);
};

WsClient.prototype._send = function (obj) {
  if (!this.ws) return false;
  try { this.ws.send(JSON.stringify(obj)); return true; }
  catch (e) { return false; }
};

/** Follow one instance's log and chat streams; null unsubscribes. */
WsClient.prototype.subscribe = function (logsId, chatId) {
  this.subs = { logs: logsId || null, chat: chatId || null };
  if (this.authed) this._resubscribe();
};
WsClient.prototype._resubscribe = function () {
  this._send({ type: 'subscribe', logs: this.subs.logs, chat: this.subs.chat });
};

/* =========================== exports ============================= */

var api = {
  VERSION: VERSION,
  RpcError: RpcError,
  isRpcError: isRpcError,
  HttpClient: HttpClient,
  WsClient: WsClient,
  backoffDelay: backoffDelay,
  buildPath: buildPath,
  BACKOFF: BACKOFF
};

global.PanelRpc = api;
if (typeof module !== 'undefined' && module.exports) module.exports = api;

})(typeof window !== 'undefined' ? window : this);
