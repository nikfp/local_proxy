# Local Proxy — Design

## Purpose

A local proxy between servers running on localhost and the wider internet. It has
two directions.

1. **Outbound (local → external).** A local app calls a path on this app, which
   injects configured headers and forwards the request to an external URL. The
   upstream response is returned to the caller.
2. **Inbound (internet → local).** A Cloudflare tunnel exposes this app. Requests
   authenticate with a shared key, match a path prefix, get configured headers
   injected, and are forwarded to a local endpoint. The response is returned to
   the caller.

## Decisions

- Outbound routes are addressed as `/r/<slug>/<rest>`; inbound routes match on a
  path prefix only. There is one public Cloudflare hostname, so no host field.
- Forwarding strips the matched prefix and appends the remainder to the target's
  base path. Query strings are preserved.
- Inbound auth is a single shared key in `X-Proxy-Key`, compared against
  `INBOUND_PROXY_KEY` before route lookup. The header is stripped before
  forwarding.
- Outbound requires no auth because the app binds to `127.0.0.1` only.
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
  behind HTTP basic auth from env vars.
- Root `/` redirects to `/routes`. `GET /health` is unauthenticated.
- Secrets fail fast at boot in dev and prod. Test uses fixed fixture values.
- Build order: data model and UI, then outbound, then inbound.

## Architecture

```
Local app ──► 127.0.0.1:<PORT>/r/:slug/... ──► Proxy.forward ──► external URL
Cloudflare ─► tunnel ─► 127.0.0.1:<PORT>/* ──► InboundAuth ─► Proxy.forward ─► localhost
Browser ────► 127.0.0.1:<PORT>/routes      ──► basic auth ─► RouteLive
```

The forwarder is shared by both directions. Only route lookup, auth, and target
policy differ.

### Modules

- `LocalProxy.Vault` — Cloak vault, key from `CLOAK_KEY`.
- `LocalProxy.Routing` — Ash domain.
- `LocalProxy.Routing.Route` — the route resource.
- `LocalProxy.Proxy` — path rewrite, header merge, Req call, error mapping.
- `LocalProxy.Proxy.Result` — status, headers, body, duration in ms.
- `LocalProxyWeb.Plugs.BasicAuth` — admin/UI basic auth.
- `LocalProxyWeb.Plugs.InboundAuth` — `X-Proxy-Key` check.
- `LocalProxyWeb.ProxyController` — dispatches outbound and inbound requests.
- `LocalProxyWeb.RouteLive.Index` and `RouteLive.Form` — config UI.
- `LocalProxyWeb.HealthController` — `GET /health`.

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
- `enabled` — boolean, required, default `true`.
- `retries` — boolean, required, default `false`.
- `inserted_at`, `updated_at` — timestamps.

Validations and identities:

- Direction-specific requiredness for `slug` and `path_prefix`. Reject a route
  that sets both, or neither.
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
  result to be loopback. Reject anything else with a clear error.

Actions: `read`, `create`, `update`, `destroy`. No Ash policies; the operator is
single-user and the UI is protected by basic auth. AshAdmin is likewise behind
basic auth.

### Encryption

`Route` uses AshCloak:

```elixir
cloak do
  vault LocalProxy.Vault
  attributes [:headers]
  encrypt_nil? false
end
```

AshCloak renames the column to `encrypted_headers`, adds a calculation named
`headers`, and encrypts on write and decrypts when the calculation is loaded.
Maps are supported because values are encoded as Erlang terms. Phase 1 includes
a round-trip test and a raw SQL check that the plaintext is absent from the
stored column.

`LocalProxy.Vault` reads `CLOAK_KEY` in `init/1`, base64-decodes it, and uses
`Cloak.Ciphers.AES.GCM` with tag `"AES.GCM.V1"`. Boot fails if the key is
missing, not valid base64, or not 32 bytes. The vault starts before the Repo in
the supervision tree.

## Configuration

Required at boot in every environment except `test` (which uses fixed fixtures):

- `CLOAK_KEY` — base64-encoded 32-byte AES key.
- `INBOUND_PROXY_KEY` — shared key for inbound requests.
- `ADMIN_USER`, `ADMIN_PASSWORD` — basic auth for `/routes` and `/admin`.

Optional:

- `PORT` — listen port, default `4000`. Parsed as an integer, must be 1–65535;
  an invalid value fails at boot with a clear message. Applies in dev and prod
  via `config/runtime.exs`, so a local start can move off 4000 without editing
  config. The bind address stays loopback. Anything pointing at the app
  (browser, outbound callers, Cloudflare tunnel origin) must use the configured
  port.
- `UPSTREAM_TIMEOUT_MS` — default `30000`.
- `MAX_BODY_BYTES` — default `10485760`.
- `DATABASE_PATH`, `SECRET_KEY_BASE` — prod only, already used by
  `config/runtime.exs`.

Binding is `{127, 0, 0, 1}` in dev and prod; `PORT` changes the port only.
Secrets are exported in the shell; README documents the exports. No `.env`
loader and no generated defaults.

`runtime.exs` stores validated values in application env, so request-time code
does not re-read the environment.

## Routing table

- `GET /health` — no pipeline, returns 200 `{"status":"ok"}`.
- `GET /` — browser pipeline, redirects to `/routes`.
- `/routes`, `/routes/new`, `/routes/:id/edit` — browser pipeline plus basic
  auth, LiveViews.
- `/admin` — browser pipeline plus basic auth, AshAdmin.
- `match /r/:slug` and `/r/:slug/*rest` — proxy, outbound forwarder.
- `match /*path` — proxy, inbound forwarder.
- `/live` — LiveView socket, never proxied.

The inbound catch-all is declared last. Static assets and `/favicon.ico` are
served by the endpoint before the router. Root `/` and `/health` are never
proxied.

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

1. Check `X-Proxy-Key` before anything else. Missing or wrong → 401 JSON with
   `WWW-Authenticate` omitted (this is not a browser prompt). Compare with
   `Plug.Crypto.secure_compare/2`, with a length check first.
2. Load enabled inbound routes and pick the route whose `path_prefix` matches
   exactly or as a path segment. Longest prefix wins.
3. No match → 404 JSON.
4. Method check, body read, header merge, and forward as in outbound. Strip
   `X-Proxy-Key` from the forwarded headers even if a route did not inject it.
5. Validate the target is still loopback at request time; otherwise 502.
6. Return the upstream response with the same response header rules.

Example: prefix `/api` and target `http://localhost:3000` maps
`/api/users?x=1` → `http://localhost:3000/users?x=1`.

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

- `401` `{"error":"unauthorized","status":401}`
- `404` `{"error":"no_route","status":404}`
- `405` `{"error":"method_not_allowed","status":405}`
- `413` `{"error":"request_too_large","status":413}`
- `500` `{"error":"proxy_error","status":500}`
- `502` `{"error":"upstream_unreachable","status":502}`
- `502` `{"error":"upstream_response_too_large","status":502}`
- `504` `{"error":"upstream_timeout","status":504}`

No target URL, exception detail, or header value appears in an error body.

## UI

`/routes` shows a list with name, direction, path or slug, target, enabled
toggle, and a test button. Filter by direction and enabled state.

`/routes/new` and `/routes/:id/edit` render the form:

- name, description, direction
- slug (shown for outbound) or path prefix (shown for inbound)
- target URL
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
  Changing the bind address requires adding auth to outbound routes.
- Basic auth is only as strong as the password; the tunnel terminates TLS, and
  local access is plain HTTP on loopback.
- Injected headers can be triggered by anything that can reach loopback, so the
  injected credentials are only as protected as the machine.
- Inbound loopback validation prevents the public tunnel from reaching LAN or
  internet hosts.
- `encrypt_nil? false` keeps `encrypted_headers` meaningful for future cleanup
  tasks.
- Changing `CLOAK_KEY` makes existing headers unreadable. There is no rotation
  task in this design.

## Testing

Use `Req.Test` as the upstream by passing test-only Req options through the
forwarder (`plug: {Req.Test, name}`).

Data and encryption:

- Slug and path prefix required by direction; both or neither rejected.
- Format, reserved-word, reserved-prefix, and target URL validation.
- Unique collisions on create and update produce a form error.
- Header names normalised to lowercase; forbidden names rejected.
- `headers` round-trip through AshCloak.
- Raw SQL shows the plaintext is not in `encrypted_headers`.
- Defaults: enabled true, retries false.

Configuration:

- `PORT` defaults to 4000, accepts a valid integer, and rejects non-numeric or
  out-of-range values at boot.

Forwarding:

- Path rewriting with and without a target base path; query preserved.
- Longest inbound prefix wins; segment boundary respected (`/api` does not
  match `/apix`).
- Injected headers override caller values.
- Hop-by-hop headers dropped; `Host` is the target host.
- Inbound `X-Proxy-Key` stripped.
- Missing or wrong key → 401; no match → 404; disabled route → 404.
- `CONNECT` and `TRACE` → 405.
- Body over limit → 413; response over limit → 502.
- Timeout → 504; refused connection → 502; other exception → 500.
- Retries off: a 500 from upstream produces exactly one upstream request.
- Retries on: a 500 on GET is retried; a 500 on POST is not.
- Redirects followed; final response returned.
- Gzip response body and `Content-Encoding` pass through unchanged.

LiveView:

- Create, edit, disable, and delete a route.
- Reveal a header value.
- Test button result rendering with a stubbed upstream.

## Build phases

### Phase 1 — Data model and UI

- Add `LocalProxy.Vault`, wire it into the supervision tree.
- Add `LocalProxy.Routing.Route` and the Ash domain, with migration.
- Add validations, identities, and AshCloak configuration.
- Add basic auth plug and mount `/routes` LiveViews; protect `/admin`.
- Add `/health` and the root redirect.
- Configure `PORT` in `config/runtime.exs` with integer/range validation,
  defaulting to `4000`, and keep the loopback bind.
- Add Phase 1 tests and README env exports (including how to run on another
  port).

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

- Add `InboundAuth` and the inbound dispatcher with longest-prefix matching.
- Add loopback target enforcement at save and request time.
- Strip `X-Proxy-Key`, reuse the forwarder, add inbound tests.
- Document the app-side tunnel requirement in README: public hostname forwards
  to `http://127.0.0.1:<PORT>` (default 4000), and `X-Proxy-Key` is added to
  inbound requests.

Done when: a request through the tunnel with the correct key reaches a local
service, and missing/wrong keys get 401 without touching a target.

## Out of scope

- Websockets, SSE, and streaming bodies.
- Multiple public hostnames and host-based routing.
- Request history, metrics, or audit tables.
- Multiple users, per-route keys, HMAC signing, Cloudflare Access JWT
  verification.
- CORS.
- Cloak key rotation.
- Import/export of route configuration.

## Open questions

- `CLOAK_KEY` rotation: deferred, but a re-encrypt mix task may be wanted later.
- `localhost` handling: if you prefer literal-only loopback targets, we can
  reject the `localhost` hostname and require `127.0.0.1`.
