# Notes for the first real login (needs the account owner)

## The game world address is not discoverable without credentials

`docs/login-http-and-packet.md` is right that the world host/port arrive only in the HTTPS login
reply (`worlds[].externaladdressprotected` / `externalportprotected`). Probed 2026-09-05:

| candidate | result |
|---|---|
| `www.gunzodus.net:443` | the login endpoint; answers our POST correctly (invalid account → `{"errorCode":3,…}`) |
| `31.59.20.176:6754` | **an HTTP proxy**, not the game server: `HTTP/1.1 407 Proxy Authentication Required`, `Proxy-Authenticate: Basic realm="Invalid proxy credentials or missing IP Authorization."` |
| `31.59.20.176:7171/7172`, `147.93.191.117:7171/7172` | closed/filtered |

So the game socket cannot be exercised against the real server until someone logs in once with a
valid account. Everything up to and including the HTTPS reply is proven; everything after it is
proven only against `test/fakeserver.lua`.

Feeding that proxy address to the client as if it were the world server produced exactly the right
behaviour, which is worth recording as a real negative test: the first two bytes of the proxy's
`HTTP/1.1 407 …` response parse as a block count of 21576, and the transport refused it with
`invalid packet size: 172612 bytes` instead of crashing or hanging.

## The user's real client connects through an HTTP proxy

That 407 is the giveaway: `31.59.20.176:6754` is configured as a proxy in
`otclient/profiles/config.otml`, and the reference client tunnels the **game socket** through it with
an HTTP `CONNECT` handshake (`src/framework/net/connection.cpp`, `startProxyHandshake`, plus
`EnterGame.applyHttpProxy` / `g_http_proxy.setProxy` on the Lua side).

**luaclient does not implement this yet.** If the account is IP-restricted to that proxy, a direct
connection will fail no matter how correct the framing is. Planned:

* `--proxy=host:port` and `--proxy-auth=user:pass` flags.
* Before the world-name preamble, write
  `CONNECT <gameHost>:<gamePort> HTTP/1.1\r\nHost: …\r\n[Proxy-Authorization: Basic base64(user:pass)]\r\n\r\n`,
  read headers until `\r\n\r\n`, require a `200`, then hand the socket to the normal transport path
  (the game protocol is unchanged inside the tunnel).
* The same proxy should optionally front the HTTPS login POST (WinHTTP and libcurl both take a proxy
  setting directly).

## When credentials are available, do this in order

1. `run.bat --account=… --password=… --character=… --log-level=debug --capture=first-session.cam`
   (add `--proxy=…` if the direct connection is refused).
2. If it reaches `game started`, the whole wire format is confirmed. Keep `first-session.cam`: it is
   the first real corpus and `test/replay.lua` can then assert the parser consumes every byte of a
   genuine session, including a full map description.
3. Watch for these specific unknowns, each of which has a documented fallback:
   * the `u16 2` gunz marker and the `"261"` extended-data string inside the RSA block (unverified);
   * the content revision string (`42196` today) — a client update changes it;
   * the pong opcode `0x1C` (`--ping` can be raised to reduce exposure; opcode 30 is the alternative);
   * inbound zlib compression (bit 31 of the sequence dword) has never been seen from this server.
4. If the server drops the connection immediately after the login packet, the most likely causes in
   order are: the proxy requirement above, a stale content revision, then the RSA-block extras.
