/* ==================================================================
   panel/api.js — THE CONTRACT.
   ------------------------------------------------------------------
   One table, ENDPOINTS, is the single source of truth for every call
   the panel makes: the HTTP method, the path template, which argument
   is a path parameter, which is a query parameter, and (as a comment)
   what comes back. The hub (work item B3) must match this table
   exactly; panel/mock/api.js implements the same table in the browser
   so ?mock=1 exercises the identical code path.

   Rules that hold for every endpoint:
     * Request bodies are JSON objects. Responses are JSON objects
       (never a bare array), 2xx on success.
     * An error is a non-2xx status with
           {"error": {"code": "<stable-string>", "message": "<human>"}}
       codes: bad-request, unauthorized, forbidden, not-found, conflict,
       too-large, rate-limited, csrf-invalid, internal.
     * The session is an HttpOnly cookie. State-changing verbs
       (POST/PUT/PATCH/DELETE) carry the X-CSRF-Token header; the token
       comes from GET /api/session (field csrfToken) and is kept in
       memory only.
     * A secret only ever travels INTO the hub: game-account passwords,
       proxy passwords and web-account passwords are write-only fields.
       No response in this table contains a password or a session token.
   ================================================================== */

(function (global) {
'use strict';

var rpc = global.PanelRpc;

/* ------------------------------------------------------------------
   name                   method  path                                       params/query
   ------------------------------------------------------------------ */
var ENDPOINTS = {

  /* ---- session & bootstrap ---------------------------------------- */

  // -> {user:{id,name,role}|null, version, bootstrap:bool, insecure:bool,
  //     serverTime:ms, csrfToken}
  'session.get':      { method: 'GET',    path: '/api/session' },

  // {name,password} -> {user, csrfToken}   + Set-Cookie: session=...; HttpOnly
  'session.login':    { method: 'POST',   path: '/api/session' },

  // -> {}   + the cookie is expired server-side
  'session.logout':   { method: 'DELETE', path: '/api/session' },

  // {current,next} -> {}   (every other session of this user is revoked)
  'session.password': { method: 'POST',   path: '/api/session/password' },

  // {token,name,password} -> {user, csrfToken}   first-run admin creation
  'bootstrap':        { method: 'POST',   path: '/api/bootstrap' },

  /* ---- instances --------------------------------------------------- */

  // -> {instances:[Instance]}                       (only the caller's, all for admin)
  'instances.list':   { method: 'GET',    path: '/api/instances' },
  // -> {instance:Instance}
  'instances.get':    { method: 'GET',    path: '/api/instances/:id', params: ['id'] },
  // {characterId,proxyId|null,botProfile,autoStart,autoRelogin} -> {instance}
  'instances.create': { method: 'POST',   path: '/api/instances' },
  // {proxyId?,botProfile?,cavebotConfig?,targetbotConfig?,scripts?,autoStart?,autoRelogin?}
  //   -> {instance}
  'instances.update': { method: 'PATCH',  path: '/api/instances/:id', params: ['id'] },
  // -> {}
  'instances.delete': { method: 'DELETE', path: '/api/instances/:id', params: ['id'] },
  // {action:'start'|'stop'|'restart'|'botEnable', ids:[id], on?:bool}
  //   -> {results:[{id, ok:bool, error?}]}          bulk; one id is a one-element list
  'instances.action': { method: 'POST',   path: '/api/instances/actions' },
  // -> {cavebot:[name], targetbot:[name], profiles:[name],
  //     macros:[{name,label,on,hotkey}]}
  'instances.configs':{ method: 'GET',    path: '/api/instances/:id/configs', params: ['id'] },
  // {on:bool} -> {macro:{name,label,on,hotkey}}
  'instances.macro':  { method: 'PUT',    path: '/api/instances/:id/macros/:name', params: ['id', 'name'] },
  // -> {}                                            reload the bot profile in the worker
  'instances.reload': { method: 'POST',   path: '/api/instances/:id/reload', params: ['id'] },
  // {code} -> {output:string}                        audited, admin-visible
  'instances.exec':   { method: 'POST',   path: '/api/instances/:id/exec', params: ['id'] },
  // ?since=ms -> {points:[{t,expPerHour,moneyPerHour,killsPerHour,level,
  //                        hpPercent,manaPercent}]}
  'instances.history':{ method: 'GET',    path: '/api/instances/:id/history', params: ['id'], query: ['since'] },
  // ?limit=n -> {lines:[{id,t,level,text}]}
  'instances.logs':   { method: 'GET',    path: '/api/instances/:id/logs', params: ['id'], query: ['limit'] },
  // ?limit=n -> {messages:[{id,t,channel,from,text}]}
  'instances.chat':   { method: 'GET',    path: '/api/instances/:id/chat', params: ['id'], query: ['limit'] },
  // {channel:number, text} -> {}
  'instances.say':    { method: 'POST',   path: '/api/instances/:id/chat', params: ['id'] },

  /* ---- game accounts ------------------------------------------------ */

  // -> {accounts:[{id,label,login,ownerUserId,ownerName,has2fa,characterCount}]}
  //    NOTE: no password field exists in this response. Ever.
  'accounts.list':    { method: 'GET',    path: '/api/accounts' },
  // {label,login,password,token2fa?} -> {account}          password is write-only
  'accounts.create':  { method: 'POST',   path: '/api/accounts' },
  // {label?,login?,password?,token2fa?} -> {account}       omit password = unchanged
  'accounts.update':  { method: 'PATCH',  path: '/api/accounts/:id', params: ['id'] },
  // -> {}   (its characters and their instances go too)
  'accounts.delete':  { method: 'DELETE', path: '/api/accounts/:id', params: ['id'] },

  /* ---- characters ---------------------------------------------------- */

  // -> {characters:[{id,accountId,accountLabel,name,world,vocation,lastLevel,instanceId}]}
  'characters.list':  { method: 'GET',    path: '/api/characters' },
  // {accountId,name,world,vocation?} -> {character}
  'characters.create':{ method: 'POST',   path: '/api/characters' },
  // -> {}
  'characters.delete':{ method: 'DELETE', path: '/api/characters/:id', params: ['id'] },

  /* ---- proxies -------------------------------------------------------- */

  // -> {proxies:[{id,label,kind,host,port,user,hasPass,inUse}]}   no password field
  'proxies.list':     { method: 'GET',    path: '/api/proxies' },
  // {label,kind,host,port,user?,pass?} -> {proxy}
  'proxies.create':   { method: 'POST',   path: '/api/proxies' },
  // {label?,kind?,host?,port?,user?,pass?} -> {proxy}
  'proxies.update':   { method: 'PATCH',  path: '/api/proxies/:id', params: ['id'] },
  // -> {}   409 while an instance still uses it
  'proxies.delete':   { method: 'DELETE', path: '/api/proxies/:id', params: ['id'] },
  // -> {ok:bool, latencyMs, error?}      hub dials CONNECT through the proxy
  'proxies.test':     { method: 'POST',   path: '/api/proxies/:id/test', params: ['id'] },

  /* ---- scripts --------------------------------------------------------- */

  // -> {scripts:[{id,name,size,sha256,ownerUserId,ownerName,createdAt,instanceIds}]}
  'scripts.list':     { method: 'GET',    path: '/api/scripts' },
  // -> {script, source}
  'scripts.get':      { method: 'GET',    path: '/api/scripts/:id', params: ['id'] },
  // {name,source} -> {script}      same name replaces, 413 past 512 KiB
  'scripts.upload':   { method: 'POST',   path: '/api/scripts' },
  // -> {}
  'scripts.delete':   { method: 'DELETE', path: '/api/scripts/:id', params: ['id'] },
  // {instanceIds:[id]} -> {script}     full replacement of the assignment set
  'scripts.assign':   { method: 'PUT',    path: '/api/scripts/:id/assignments', params: ['id'] },

  /* ---- admin (403 for a non-admin) -------------------------------------- */

  // -> {users:[{id,name,role,createdAt,disabled,lastLoginAt}]}
  'admin.users':      { method: 'GET',    path: '/api/admin/users', admin: true },
  // {name,role,password} -> {user}
  'admin.userCreate': { method: 'POST',   path: '/api/admin/users', admin: true },
  // {role?,disabled?} -> {user}
  'admin.userUpdate': { method: 'PATCH',  path: '/api/admin/users/:id', params: ['id'], admin: true },
  // -> {}
  'admin.userDelete': { method: 'DELETE', path: '/api/admin/users/:id', params: ['id'], admin: true },
  // {password} -> {}    revokes that user's sessions
  'admin.userPassword': { method: 'POST', path: '/api/admin/users/:id/password', params: ['id'], admin: true },
  // -> {sessions:[{id,userId,userName,ip,userAgent,createdAt,lastSeenAt,current}]}
  'admin.sessions':   { method: 'GET',    path: '/api/admin/sessions', admin: true },
  // -> {}
  'admin.sessionRevoke': { method: 'DELETE', path: '/api/admin/sessions/:id', params: ['id'], admin: true },
  // ?actor&action&from&to&q&limit&cursor
  //   -> {rows:[{t,actor,ip,action,target,outcome,detail}], nextCursor|null,
  //       total, actors:[name], actions:[name]}
  'admin.audit':      { method: 'GET',    path: '/api/admin/audit', admin: true,
                        query: ['actor', 'action', 'from', 'to', 'q', 'limit', 'cursor'] }
};

/* The WebSocket side of the contract, documented here so the hub and the
   mock agree. See panel/rpc.js WsClient for the client half. */
var WS = {
  path: '/ws',
  clientFrames: ['auth', 'subscribe', 'ping'],
  serverEvents: ['ready', 'pong', 'status', 'stats', 'log', 'chat', 'instance',
                 'script', 'loginState', 'gameStart', 'gameEnd', 'death', 'error', 'audit'],
  closeCodes: { unauthenticated: 4401, forbidden: 4403 }
};

/* ------------------------------------------------------------------ */

function Api(http) {
  this.http = http;
}

/**
 * call(name, args, opt) -> Promise<result>
 *   `args` is one flat object. Keys named in the endpoint's `params` fill the
 *   path, keys named in `query` become the query string, everything else is
 *   the JSON body (for a verb that has one). Unknown endpoint = programming
 *   error, and it throws synchronously inside the promise.
 */
Api.prototype.call = function (name, args, opt) {
  var ep = ENDPOINTS[name];
  var self = this;
  if (!ep) return Promise.reject(new rpc.RpcError('internal', 'unknown endpoint: ' + name));
  args = args || {};

  var params = {}, query = {}, body = {}, hasBody = false, k;
  var pset = {}, qset = {};
  (ep.params || []).forEach(function (p) { pset[p] = true; });
  (ep.query || []).forEach(function (q) { qset[q] = true; });

  for (k in args) {
    if (!Object.prototype.hasOwnProperty.call(args, k)) continue;
    if (pset[k]) params[k] = args[k];
    else if (qset[k]) query[k] = args[k];
    else { body[k] = args[k]; hasBody = true; }
  }

  var path;
  try { path = rpc.buildPath(ep.path, params, query); }
  catch (e) { return Promise.reject(e); }

  var sendBody = (ep.method === 'GET' || ep.method === 'DELETE') ? null : (hasBody ? body : {});
  return this.http.request(ep.method, path, sendBody, opt).then(function (r) {
    return r;
  }, function (e) {
    /* attach the endpoint name so a toast can say what actually failed */
    if (e && !e.endpoint) e.endpoint = name;
    if (e) e.method = ep.method;
    if (e) e.path = path;
    throw e;
  });
};

/** Every endpoint name, for the coverage test. */
Api.prototype.names = function () { return Object.keys(ENDPOINTS); };

var api = { ENDPOINTS: ENDPOINTS, WS: WS, Api: Api };
global.PanelApi = api;
if (typeof module !== 'undefined' && module.exports) module.exports = api;

})(typeof window !== 'undefined' ? window : this);
