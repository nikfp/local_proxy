# Local Proxy — Design

## Purpose

A local proxy between servers running on localhost and the wider internet. It has
two directions.

1. **Outbound (local → external).** A local app calls a path on this app, which
   injects configured headers and forwards the request to an external URL. The
   upstream response is returned to the caller.
2. **Inbound (internet → local).** A Cloudflare tunnel exposes this app. Requests
   carry the matched route's key in `X-Proxy-Key`, match a path prefix, get
   configured headers injected, and are forwarded to a local endpoint. The
   response is returned to the caller.

## Decisions

- Outbound routes are addressed as `/r/<slug>/<rest>`; inbound routes match on a
  path prefix only. There is one public Cloudflare hostname, so no host field.
- Forwarding strips the matched prefix and appends the remainder to the target's
  base path. Query strings are preserved.
- Inbound auth is per route. The caller supplies the route's key in
  `X-Proxy-Key`; the listener matches the route by path prefix, decrypts that
  route's `inbound_key`, and compares it before forwarding. The header is
  stripped before forwarding. Unknown prefixes and bad keys both return 401.
- Outbound requires no auth because the outbound listener binds to `127.0.0.1`
  and is never exposed through the tunnel.
- Two listeners: a local listener for outbound routes and the UI, and an
  inbound listener for tunnel traffic. The Cloudflare tunnel points only at the
  inbound listener.
- The UI and AshAdmin are served only by the local listener. The inbound
  listener has no UI, admin, or outbound routes.
- Inbound targets must be loopback; outbound targets may be any `http`/`https`
  URL.
- Header injection is static key/value pairs. The route's value wins over an
  incoming header with the same name.
- Headers are stored in one encrypted `:map` attribute via AshCloak.
- One `Route` resource with a `direction` field.
- Retries are off by default; each route has an on/off retry toggle.
- Bodies are buffered, capped at 10 MB. No websockets, SSE, or streaming.
- Upstream redirects are followed (Req default, max 10). This is a deliberate
  deviation from strict 1:1 response passthrough.
- Response bodies are passed through raw: no decompression, no JSON decoding.
- Upstream timeout is 30 s. Timeout → 504, unreachable → 502, other → 500.
- No request history in the database. Logs contain route, method, path, status,
  and timing only.
- Custom LiveViews for route management, AshAdmin kept at `/admin`. Both sit
  behind a password sign-in that also unlocks the vault.
- Root `/` redirects to `/routes`. `GET /health` is unauthenticated.
- The vault is locked at boot and unlocks when a human signs in locally. There
  is no `CLOAK_KEY`, `ADMIN_PASSWORD`, `INBOUND_PROXY_KEY`, or
  `SECRET_KEY_BASE` environment variable. `SECRET_KEY_BASE` is generated per
  BEAM start. `ADMIN_USER` is optional and defaults to `admin`; it is not
  secret.
- Remote unlock is impossible by design. The UI and login exist only on the
  loopback-bound outbound listener. If no human is at the machine, a restarted
  app stays locked and the tunnel returns 503.
- Changing the admin password only rewraps the data key. It does not rotate the
  data key, so old database copies remain decryptable with the old password.
- There is no backup, restore, migration, or key-adoption path. Recovery from a
  lost password or corrupted vault is to delete the SQLite database and set a
  new password, which also removes all routes.
- Build order: data model and UI, then outbound, then inbound.

## Architecture

```
Local app ──► 127.0.0.1:<OUTBOUND_PORT>/r/:slug/... ──► VaultGate ──► Proxy.forward ──► external URL
Browser ────► 127.0.0.1:<OUTBOUND_PORT>/routes       ──► sign-in/unlock ──► RouteLive
Cloudflare ─► tunnel ─► 127.0.0.1:<INBOUND_PORT>/*   ──► VaultGate ──► InboundAuth ──► Proxy.forward ──► localhost
```

Two Phoenix endpoints run in one VM. `LocalProxyWeb.Endpoint` listens on the
outbound port and serves `/r`, `/routes`, `/admin`, `/health`, and `/`.
`LocalProxyWeb.InboundEndpoint` listens on the inbound port and serves only the
authenticated inbound catch-all plus `/health`. Both bind to loopback.

The forwarder is shared by both directions. Only route lookup, auth, target
policy, and the listening endpoint differ.

### Modules

- `LocalProxy.Vault` — Cloak vault with a static wrapper cipher; the key comes
  from the keyring at call time.
- `LocalProxy.Vault.KeyRing` — process-wide in-memory key and generation.
- `LocalProxy.Vault.Cipher` — Cloak cipher wrapper that reads the keyring.
- `LocalProxy.Vault.Envelope` — password KDF and AES-GCM key wrapping.
- `LocalProxy.Vault.Key` — Ash resource for the wrapped data key.
- `LocalProxy.Vault.KeyStore` — create, unwrap, and rewrap the vault key.
- `LocalProxy.Vault.LoginLimiter` — in-memory failed-login limiter.
- `LocalProxy.Vault.LockedError` — clean locked-state exception.
- `LocalProxy.Vault.DecryptError` — clean ciphertext/authentication failure.
- `LocalProxy.Routing.InboundKey` — per-route key generation.
- `LocalProxy.Routing` — Ash domain.
- `LocalProxy.Routing.Route` — the route resource.
- `LocalProxy.Proxy` — path rewrite, header merge, Req call, error mapping.
- `LocalProxy.Proxy.Result` — status, headers, body, duration in ms.
- `LocalProxyWeb.Plugs.RequireAuth` — redirects unauthenticated or stale UI
  requests.
- `LocalProxyWeb.Plugs.VaultGate` — returns 503 before proxy route lookup while
  locked.
- `LocalProxyWeb.SessionController` — sign-in, unlock, and sign-out.
- `LocalProxyWeb.Plugs.InboundAuth` — matches the inbound route, checks its
  `X-Proxy-Key`, and assigns the route.
- `LocalProxyWeb.ProxyController` — dispatches outbound and inbound requests.
- `LocalProxyWeb.InboundEndpoint` — listener used by the tunnel.
- `LocalProxyWeb.InboundRouter` — health plus authenticated inbound catch-all.
- `LocalProxyWeb.RouteLive.Index` and `RouteLive.Form` — config UI, including
  inbound key generation and rotation.
- `LocalProxyWeb.HealthController` — `GET /health`.
- `LocalProxyWeb.LiveUserAuth` — LiveView mount and lock handling.

## Data model

Resource `LocalProxy.Routing.Route`, table `routes`.

Fields:

- `id` — UUID primary key.
- `name` — string, required, 1–120 chars.
- `description` — string, optional, max 500 chars.
- `direction` — atom, required, one of `:outbound`, `:inbound`.
- `slug` — string, nullable. Required for outbound, must be nil for inbound.
  Lowercase letters, digits, hyphens. 1–64 chars. Unique.
- `path_prefix` — string, nullable. Required for inbound, must be nil for
  outbound. Starts with `/`, no trailing slash, no query or fragment. Unique.
- `target_url` — string, required. `http` or `https`, host present, optional
  base path, no query, no fragment, no userinfo.
- `headers` — map, required, default `%{}`. Cloaked by AshCloak.
- `inbound_key` — string, nullable. Required for enabled inbound routes; must
  be nil for outbound routes. Cloaked by AshCloak. The caller sends it in
  `X-Proxy-Key`. Generated by the UI or pasted by the operator; 32–256
  characters, with generated values using 32 random bytes encoded with
  `Base.url_encode64(..., padding: false)`.
- `enabled` — boolean, required, default `true`.
- `retries` — boolean, required, default `false`.
- `inserted_at`, `updated_at` — timestamps.

Validations and identities:

- Direction-specific requiredness for `slug` and `path_prefix`. Reject a route
  that sets both, or neither.
- `inbound_key` is required when `direction == :inbound` and `enabled == true`;
  it must be nil for outbound routes. Rotation replaces the key immediately;
  the previous key stops working at once.
- Unique identity on `slug` and on `path_prefix`, plus a unique index in the
  migration. Collisions are detected on create and update and surface as a form
  error, with the DB constraint as backstop.
- `slug` must not be a reserved word: `new`, `edit`, `admin`, `health`.
- `path_prefix` must not be `/` and must not start with a reserved prefix:
  `/r`, `/routes`, `/admin`, `/health`, `/live`, `/assets`, `/dev`.
  Comparison is case-insensitive and segment-aware (`/router` is allowed).
- Header names use RFC 7230 token characters and are stored lowercase. Reject
  `host`, `content-length`, `x-proxy-key`, and hop-by-hop names:
  `connection`, `keep-alive`, `proxy-authenticate`, `proxy-authorization`,
  `te`, `trailer`, `transfer-encoding`, `upgrade`.
- Inbound `target_url` host must be `localhost`, `127.0.0.0/8`, or `::1`.
  Resolve `localhost` at validation and at request time and require every
  result to be loopback. Reject anything else with a clear error. `localhost`
  is allowed deliberately; reject only when it resolves outside loopback.

Actions: `read`, `create`, `update`, `destroy`. No Ash policies; the operator is
single-user and the UI is protected by a session sign-in. AshAdmin is likewise
behind the sign-in.

### Encryption

`Route` uses AshCloak:

```elixir
cloak do
  vault LocalProxy.Vault
  attributes [:headers, :inbound_key]
  encrypt_nil? false
  on_decrypt &LocalProxy.Vault.Cipher.on_decrypt/4
end
```

AshCloak renames the columns to `encrypted_headers` and `encrypted_inbound_key`,
adds calculations named `headers` and `inbound_key`, and encrypts on write and
decrypts when the calculations are loaded. Maps are supported because values are
encoded as Erlang terms. Phase 1 includes a round-trip test and a raw SQL check
that neither plaintext is present in the stored columns.

`LocalProxy.Vault` no longer reads `CLOAK_KEY`. It uses
`Cloak.Ciphers.AES.GCM` through `LocalProxy.Vault.Cipher` with tag
`"AES.GCM.V1"` and `iv_length: 12`. The data key is unwrapped at login and held
in `LocalProxy.Vault.KeyRing`; while locked, encryption and decryption return
`LocalProxy.Vault.LockedError`. See `planning/hardening.md` for the envelope,
KDF, and locked behavior.

There is no migration from `CLOAK_KEY`. Existing development databases are
discarded by deleting the SQLite files and recreating the schema.

## Configuration

There are no required secret environment variables. The vault key, admin
password, inbound route keys, and cookie signing secret are not read from the
environment.

Optional:

- `ADMIN_USER` — sign-in username, default `admin`. Not secret.
- `OUTBOUND_PORT` — local listener, default `4000`. Parsed as an integer, must
  be 1–65535; an invalid value fails at boot with a clear message. Serves the
  UI, admin, `/health`, and outbound `/r` routes. Browsers and local callers use
  this port.
- `INBOUND_PORT` — tunnel listener, default `4001`. Same validation. Serves only
  `/health` and the inbound catch-all. The Cloudflare tunnel origin points
  here.
- `UPSTREAM_TIMEOUT_MS` — default `30000`.
- `MAX_BODY_BYTES` — default `10485760`.
- `DATABASE_PATH` — prod only, already used by `config/runtime.exs`.

`SECRET_KEY_BASE` is generated once per BEAM start with
`:crypto.strong_rand_bytes(64) |> Base.encode64()` and shared by both endpoints
and the Ash keyset signing secret. Sessions therefore do not survive a restart,
which is consistent with the vault locking on boot. This app is single-node and
local-only; do not use generated secrets in a cluster.

Both listeners bind to `{127, 0, 0, 1}` in dev and prod. The two ports must
differ; boot fails with a clear message otherwise. Ports only change the listen
ports. No `.env` loader and no generated defaults other than the signing secret
and `ADMIN_USER` default.

`runtime.exs` stores validated values in application env, so request-time code
does not re-read the environment.

## Routing table

Local listener (`OUTBOUND_PORT`, never tunneled):

- `GET /health` — no pipeline, returns 200 with `status` and `vault`.
- `GET /` — browser pipeline, redirects to `/routes`.
- `GET /login`, `POST /login` — sign-in form and credential check.
- `POST /logout` — clears the session.
- `/routes`, `/routes/new`, `/routes/:id/edit` — browser pipeline plus
  `RequireAuth`, LiveViews.
- `/admin` — browser pipeline plus `RequireAuth`, AshAdmin.
- `match /r/:slug` and `/r/:slug/*rest` — proxy, outbound forwarder.
- `/live` — LiveView socket.

Inbound listener (`INBOUND_PORT`, the tunnel origin):

- `GET /health` — no pipeline, returns 200 with `status` and `vault`.
- `match /*path` — `VaultGate`, then `InboundAuth` with the matched route's
  key, then the inbound forwarder.

The inbound listener has no UI, admin, static assets, LiveView socket, or
outbound `/r` routes. A tunnel request to `/r/...` or `/routes` matches the
catch-all, fails inbound route/key matching, and returns 401.

## Request flow

### Outbound

1. Match `/r/:slug/*rest`.
2. Parse the remainder as the path suffix; keep `conn.query_string` as-is.
3. Load the route by slug where `direction == :outbound` and `enabled == true`.
   Missing or disabled → 404 JSON.
4. Method check: reject `CONNECT` and `TRACE` with 405. All other methods pass.
5. Read the request body up to `MAX_BODY_BYTES`. Over the limit → 413.
6. Build the target URL: target base path plus suffix, no duplicate slashes.
   An empty suffix becomes `/`.
7. Merge headers: copy incoming headers, drop hop-by-hop and headers named in
   `Connection`, overwrite with the route's injected headers (lowercase names),
   and let Req set `Host`, `Content-Length`, and `Accept-Encoding`.
8. Call Req with the body, timeout, retry policy, `redirect: true`,
   `max_redirects: 10`, and `raw: true`.
9. Return the upstream status and headers, dropping hop-by-hop and
   `Content-Length` (Plug recomputes it). Keep `Content-Encoding` and
   `Content-Type`.

Examples:

- `/r/github/users/1?x=2` with target `https://api.github.com` →
  `https://api.github.com/users/1?x=2`.
- `/r/stripe/v1/charges` with target `https://api.stripe.com/v1` →
  `https://api.stripe.com/v1/charges`.

### Inbound

1. If the vault is locked, return 503 before route lookup.
2. Match the request path against enabled inbound routes by longest
   `path_prefix`; matching is exact or path-segment aware.
3. No match → 401 JSON. Do not distinguish no-route from bad-key.
4. Load and decrypt the matched route's `inbound_key`. If it is missing or does
   not match `X-Proxy-Key`, return 401 JSON with `WWW-Authenticate` omitted.
   Compare with `Plug.Crypto.secure_compare/2`, with a length check first.
5. Assign the matched route to `conn.assigns` so the controller does not look it
   up twice.
6. Method check, body read, header merge, and forward as in outbound. Strip
   `X-Proxy-Key` from the forwarded headers even if a route did not inject it.
7. Validate the target is still loopback at request time; otherwise 502.
8. Return the upstream response with the same response header rules.

Example: prefix `/api` with key `k1` and target `http://localhost:3000` maps
`/api/users?x=1` with `X-Proxy-Key: k1` → `http://localhost:3000/users?x=1`.

### Req options

- `receive_timeout: UPSTREAM_TIMEOUT_MS`
- `connect_options: [timeout: UPSTREAM_TIMEOUT_MS]`
- `retry: false` when the route's `retries` is false.
- `retry: :safe_transient`, `max_retries: 3` when true. POST is still not
  retried; `Retry-After` is honoured.
- `redirect: true`, `max_redirects: 10`. Credentials are not forwarded across
  hosts (`redirect_trusted` stays false).
- `raw: true` so gzip and JSON bodies pass through untouched.
- Response body cap enforced while reading; over `MAX_BODY_BYTES` → 502
  `upstream_response_too_large`.

### Error responses

All proxy-generated errors are JSON with `error` and `status`, plus `route` when
a route was matched.

- `401` `{"error":"unauthorized","status":401}` — inbound no route, missing
  key, or wrong key
- `404` `{"error":"no_route","status":404}` — outbound missing or disabled
  route
- `405` `{"error":"method_not_allowed","status":405}`
- `413` `{"error":"request_too_large","status":413}`
- `500` `{"error":"proxy_error","status":500}`
- `502` `{"error":"upstream_unreachable","status":502}`
- `502` `{"error":"upstream_response_too_large","status":502}`
- `503` `{"error":"vault_locked","status":503}`
- `504` `{"error":"upstream_timeout","status":504}`

No target URL, exception detail, or header value appears in an error body.

## UI

`/routes` shows a list with name, direction, path or slug, target, enabled
toggle, and a test button. Filter by direction and enabled state.

`/routes/new` and `/routes/:id/edit` render the form:

- name, description, direction
- slug (shown for outbound) or path prefix (shown for inbound)
- target URL
- inbound key (shown for inbound): generate, paste, copy, and rotate. Rotation
  replaces the old key immediately. The key is displayed after generation or
  rotation so it can be pasted into the caller, and is otherwise masked. Saving
  with the masked value keeps the stored key.
- enabled and retries toggles
- header rows with name and value, add and remove buttons
- a visible note that inbound targets must be loopback

Header values are masked with a reveal button. Revealing decrypts one value and
sends it over the LiveView socket; it is not rendered into the initial HTML.
Saving with a masked value keeps the stored value; editing replaces it. New rows
with blank names are ignored.

Deleting a route asks for confirmation. Pausing is the enabled toggle.

The test button calls `LocalProxy.Proxy.forward/2` directly with the selected
route, so it works for disabled routes and needs no auth. It shows status,
duration, and up to 4 KB of the response body. It verifies rewriting, header
injection, and target connectivity, not route matching.

## Logging

One log line per proxied request at `:info`, with metadata: route slug or
prefix, direction, method, request path without query string, upstream status,
and duration. No header values, no query strings, no request or response bodies.

Errors log the target host and exception class, never the full URL or headers.
The auth key and decrypted headers are never logged.

## Security notes

- Binding to loopback is what makes unauthenticated outbound routes acceptable.
  The tunnel points only at the inbound listener, which has no `/r` routes.
  Changing either bind address requires reconsidering this.
- The two listeners are the boundary: the outbound listener is never exposed by
  the tunnel, so `X-Proxy-Key` is not needed on `/r`.
- The UI and login exist only on the loopback listener. There is deliberately no
  remote or tunnel path to unlock the vault. A headless restart stays locked and
  returns 503 until a human uses the local UI.
- The session cookie is only as strong as the password; the tunnel terminates
  TLS, and local access is plain HTTP on loopback. `SECRET_KEY_BASE` is generated
  per BEAM start, so cookies do not survive a restart.
- Injected headers can be triggered by anything that can reach loopback, so the
  injected credentials are only as protected as the machine.
- Inbound loopback validation prevents the public tunnel from reaching LAN or
  internet hosts.
- Each inbound route has its own key. The caller holds a copy in its own
  configuration, usually Smartsuite; the vault only protects the local copy.
  Per-route keys limit the blast radius of a leaked caller config.
- `encrypt_nil? false` keeps `encrypted_headers` and `encrypted_inbound_key`
  meaningful for cleanup.
- Changing the admin password rewraps the data key; it does not rotate it. Old
  database copies remain decryptable with the old password. There is no key
  rotation or backup/restore task.
- Losing the password or deleting the vault means re-creating all routes after
  resetting the database. There is no recovery path.

## Testing

Use `Req.Test` as the upstream by passing test-only Req options through the
forwarder (`plug: {Req.Test, name}`).

Data and encryption:

- Slug and path prefix required by direction; both or neither rejected.
- Format, reserved-word, reserved-prefix, and target URL validation.
- Unique collisions on create and update produce a form error.
- Header names normalised to lowercase; forbidden names rejected.
- `headers` and `inbound_key` round-trip through AshCloak.
- Raw SQL shows neither plaintext is in `encrypted_headers` or
  `encrypted_inbound_key`.
- Inbound key is required for enabled inbound routes and rejected for outbound.
- Inbound keys shorter than 32 characters or longer than 256 are rejected when
  pasted.
- `localhost` is accepted when every resolved address is loopback; a
  non-loopback resolution is rejected at save and at request time.
- Defaults: enabled true, retries false.

Configuration:

- `OUTBOUND_PORT` defaults to 4000 and `INBOUND_PORT` to 4001; both accept a
  valid integer and reject non-numeric or out-of-range values at boot.
- No vault key, admin password, inbound key, or `SECRET_KEY_BASE` is read from
  the environment.
- `ADMIN_USER` defaults to `admin` and can be overridden.
- `SECRET_KEY_BASE` differs across BEAM starts and is shared by both endpoints.

Listener isolation:

- The local listener does not serve the inbound catch-all.
- The inbound listener returns 401 for `/r/...`, `/routes`, and `/admin`.
- The inbound listener serves an unauthenticated `/health`.

Locked behavior:

- `/r/...` and the inbound catch-all return 503 while locked.
- `/health` reports `vault: locked` or `vault: unlocked`.
- UI requests with a stale generation redirect to `/login`.
- A lock during a request returns 503 or redirects, never a
  `CaseClauseError`.

Forwarding:

- Path rewriting with and without a target base path; query preserved.
- Longest inbound prefix wins; segment boundary respected (`/api` does not
  match `/apix`).
- Injected headers override caller values.
- Hop-by-hop headers dropped; `Host` is the target host.
- Inbound `X-Proxy-Key` stripped.
- Per-route inbound keys: the right key for the matched route succeeds; another
  route's key fails.
- Missing or wrong key → 401; no match → 401; disabled route → 401.
- Unknown inbound paths and bad keys are indistinguishable.
- `CONNECT` and `TRACE` → 405.
- Body over limit → 413; response over limit → 502.
- Timeout → 504; refused connection → 502; other exception → 500.
- Retries off: a 500 from upstream produces exactly one upstream request.
- Retries on: a 500 on GET is retried; a 500 on POST is not.
- Redirects followed; final response returned.
- Gzip response body and `Content-Encoding` pass through unchanged.

LiveView:

- Create, edit, disable, and delete a route.
- Generate, rotate, reveal, and copy an inbound key.
- Reveal a header value.
- Test button result rendering with a stubbed upstream.

## Build phases

### Phase 1 — Data model and UI

- Add `LocalProxy.Vault`, `LocalProxy.Vault.KeyRing`,
  `LocalProxy.Vault.Cipher`, `LocalProxy.Vault.Key`, and
  `LocalProxy.Vault.LockedError`; wire the vault into the supervision tree.
- Add `mix local_proxy.set_password` for first-run setup and rotation.
- Add `LocalProxy.Routing.Route` and the Ash domain, with migration.
- Add validations, identities, and AshCloak configuration for headers and
  inbound keys.
- Add the password sign-in, unlock flow, generation-bound `RequireAuth`,
  LiveView mounts, and `/admin` protection.
- Add `/health` and the root redirect.
- Add the local endpoint and the `LocalProxyWeb.InboundEndpoint`, configured
  with `OUTBOUND_PORT` (default 4000) and `INBOUND_PORT` (default 4001) in
  `config/runtime.exs`, both binding loopback.
- Add Phase 1 tests and README env exports (including how to run on other
  ports).

Done when: `mix test` passes and you can create, edit, pause, and delete a route
in the browser, with header values encrypted in SQLite.

### Phase 2 — Outbound

- Add `LocalProxy.Proxy.forward/2` and the outbound controller path.
- Implement path rewrite, header merge, Req options, error mapping, logging.
- Add the test button.
- Add forwarding tests with `Req.Test`.

Done when: a local call to `/r/<slug>/...` reaches the target with injected
headers, and all outbound tests pass.

### Phase 3 — Inbound

- Add `VaultGate`, `InboundAuth`, and the inbound dispatcher with
  longest-prefix matching plus per-route key checks.
- Add inbound key generation, rotation, reveal, and copy to the route form.
- Add `LocalProxyWeb.InboundEndpoint` and `InboundRouter`; move the catch-all
  there so the tunnel listener has no UI, admin, or outbound routes.
- Add loopback target enforcement at save and request time.
- Strip `X-Proxy-Key`, reuse the forwarded route assigned by `InboundAuth`, add
  inbound tests.
- Document in README that the tunnel points at
  `http://127.0.0.1:<INBOUND_PORT>` (default 4001), the caller supplies the
  route's key in `X-Proxy-Key`, and the UI is only reachable on `OUTBOUND_PORT`
  (default 4000) locally.

Done when: a request through the tunnel with the correct per-route key reaches
a local service, and an unknown path or wrong key gets 401 without touching a
target.

## Out of scope

- Websockets, SSE, and streaming bodies.
- Multiple public hostnames and host-based routing.
- Request history, metrics, or audit tables.
- Multiple users, HMAC signing, Cloudflare Access JWT verification.
- CORS.
- Data key rotation, backup, restore, or migration from `CLOAK_KEY`.
- Import/export of route configuration.

## Open questions

None.
