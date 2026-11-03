# Local Proxy

Local Proxy is a loopback-only HTTP proxy for local development and personal
use. It's purpose is to contain and safely store sensitive credentials in a form
that can't be easily read by LLM's browsing through files. When traffic is
passed through the proxy using configured routes, the proxy can inject real
credentials and forward the request as configured. This allows services in
developent to use dummy credentials and still have access to real upstream
services, while also keeping those credentials out of LLM context.  

**It is not a production gateway, not multi-user, and not hardened for
exposing sensitive systems to untrusted traffic. Use the appropriate tools in
front of it to properly secure applications and systems while working.**

It has two directions and two listeners:

- **Outbound:** requests to `/r/<slug>/...` on `OUTBOUND_PORT` forward to a
  configured external URL with injected headers. All methods except `CONNECT`
  and `TRACE` are allowed.
- **Inbound:** a tunnel, reverse proxy, or other ingress points at
  `INBOUND_PORT`; requests with `X-Proxy-Key` are matched by path prefix and
  forwarded to a local service.

Route configuration lives at `/routes` and AshAdmin at `/admin`, both on
`OUTBOUND_PORT`. Both require a password sign-in that also unlocks the vault.
The inbound listener has only two entry points: `/health` and a catch-all that
serves configured inbound routes. It cannot reach the UI, admin, or `/r`.

## Requirements

- Elixir and Erlang matching `mix.exs`
- SQLite, provided by `ecto_sqlite3`; no separate database server is needed
- An ingress method only if you want inbound access

Cloudflare Tunnel is one inbound option, not a requirement. Any reverse proxy,
tunnel, port-forward, or hosting service that can publish a local HTTP port
works, including ngrok, Tailscale Funnel, frp, an SSH remote forward, or
nginx/Caddy on a VPS. It must forward requests to `127.0.0.1:INBOUND_PORT`,
preserve the path and query string, and forward the `X-Proxy-Key` header.

## Local setup and run

```sh
mix setup
export ERL_CRASH_DUMP_SECONDS=0
mix local_proxy.set_password
mix phx.server
```

`mix setup` installs dependencies, creates and migrates the SQLite database, and
builds assets. `mix local_proxy.set_password` prompts for the password that
wraps the vault data key. It is a required first-run step.

Set `ERL_CRASH_DUMP_SECONDS=0` before starting either Mix task. It tells the
Erlang VM not to write a crash dump. Without it, a crash can write process
memory, including the vault key and the password being used by the setup task,
to `erl_crash.dump` in plain text. The VM reads this variable at startup, so
application code cannot set it. Export it in the same shell, or add it to
`.envrc` or your shell profile so every run gets it.

The password is read from stdin with echo disabled. It is not passed as a
command argument or environment variable, and the Mix task does not write it to
Erlang shell history.

**Do NOT enter the vault password into IEx or any other shell prompt. IEx writes
its input history to disk, so the password would be stored in plain text. Use
`mix local_proxy.set_password` only.**


Open the UI at [`http://localhost:4000/routes`](http://localhost:4000/routes),
replacing the port if `OUTBOUND_PORT` is set. You will be redirected to
`/login`; sign in with `ADMIN_USER` (default `admin`) and the vault password.
`GET /health` is unauthenticated on both listeners and reports `status` and
`vault`.

The app starts locked. Proxy requests return `503 vault_locked` until a human
signs in locally. Sign out to lock the vault again. Sessions do not survive an
app restart because the signing secret is generated at boot.

## Environment variables

There are no required secret environment variables. The vault key, admin
password, inbound route keys, and `SECRET_KEY_BASE` are not read from the
environment. `SECRET_KEY_BASE` is generated per BEAM start, so sessions do not
survive a restart.

The following variables are optional:

- `ADMIN_USER` — sign-in username, default `admin`. Not secret.
- `OUTBOUND_PORT` — local listener port, default `4000`. Serves the UI,
  AshAdmin, `/health`, and outbound `/r` routes.
- `INBOUND_PORT` — inbound listener port, default `4001`. Serves `/health` and
  the catch-all that handles configured inbound routes.
- `UPSTREAM_TIMEOUT_MS` — upstream connect and receive timeout, default
  `30000`.
- `MAX_BODY_BYTES` — request and response body cap, default `10485760` (10 MB).
- `ERL_CRASH_DUMP_SECONDS=0` — recommended so the in-memory vault key is not
  written to `erl_crash.dump`. This is read by the BEAM before any application
  code runs, so application code cannot set it. Export it in `.envrc`, your
  shell profile, or the service environment before starting `mix phx.server` or
  a release.

Both listeners bind to `127.0.0.1`. `OUTBOUND_PORT` and `INBOUND_PORT` must
differ; boot fails with a clear message if they match.

`config/runtime.exs` contains production-oriented variables such as
`DATABASE_PATH`, `POOL_SIZE`, `PHX_HOST`, `PHX_SERVER`, and
`DNS_CLUSTER_QUERY`. They exist because the Phoenix project still has
production configuration, but production deployment is not a supported use of
this tool.

## Vault and reset

The vault data key is wrapped with the password you set through
`mix local_proxy.set_password`. There is no password hash; the AEAD tag is the
verifier. Changing the password rewraps the same data key, so old database
copies remain readable with the old password. There is no data-key rotation,
backup, or restore task.

If you lose the password or want a clean reset, stop the app and delete the
database and its sidecars:

```sh
rm -f local_proxy_dev.db local_proxy_dev.db-wal local_proxy_dev.db-shm
mix ecto.reset
mix local_proxy.set_password
```

All routes and inbound keys are re-created manually. Deleting only the
`vault_keys` row is not enough; route ciphertext would become unreadable. There
is no adoption path from the old `CLOAK_KEY` design; reset the database instead.

## Outbound routes

Outbound routes accept any HTTP method except `CONNECT` and `TRACE`. `GET` is
just the simplest example.

An outbound route with slug `github` and target `https://api.github.com` is
called at:

```sh
curl "http://127.0.0.1:4000/r/github/users/1?x=2"
```

The request becomes `GET https://api.github.com/users/1?x=2`. The matched slug
prefix is stripped, the query string is preserved, and the route's headers are
injected. If the target has a base path, it is kept:

- Target `https://api.stripe.com/v1`
- Call `/r/stripe/v1/charges`
- Forwards to `https://api.stripe.com/v1/charges`

The **Test** button on `/routes` sends a `GET /` through the same forwarder and
shows the status, duration, and response preview. It works for disabled routes
and does not require the caller to know the public path.

Outbound routes do not have their own caller key. While the vault is unlocked,
any local process that can reach `OUTBOUND_PORT` can call them and use the
injected credentials.

## Inbound access

Point the public hostname at the inbound listener,
`http://127.0.0.1:4001` (or `INBOUND_PORT`). Each inbound route has its own key.
The caller supplies that route's key in `X-Proxy-Key`; the tunnel does not add
it. Inbound target URLs must be loopback (`localhost`, `127.0.0.0/8`, or `::1`).

An inbound route with prefix `/api` and target `http://localhost:3000` maps:

- `/api` -> `http://localhost:3000/`
- `/api/users?x=1` -> `http://localhost:3000/users?x=1`

Any request that does not match an inbound prefix, or that carries the wrong
key for the matched route, returns 401. The key check uses the route's own key,
not a shared global key.

The inbound listener does not contain `/r`, `/routes`, or `/admin`. A request
to those paths returns 401 because no inbound route matches, so exposing the
inbound listener does not directly expose the outbound proxy or the management
UI. The outbound listener stays local and is only reachable on loopback.

The tunnel does not add `X-Proxy-Key` by itself. The caller must send it. For
example, a Smartsuite outbound webhook can set it as a custom header.

### Cloudflare-specific caveats

Cloudflare Tunnel is a common choice but adds edge behavior outside this app's
control:

- Bot Fight Mode can challenge server-to-server webhooks. On the Free plan it
  cannot be skipped by WAF custom rules and is zone-wide; the workarounds are to
  disable it, use IP Access Rules for stable webhook IPs, or upgrade to Super
  Bot Fight Mode.
- A WAF rule that allows traffic based on `User-Agent` is not authentication.
  Any client can spoof the header.
- Cloudflare terminates TLS, so it can see request headers, including
  `X-Proxy-Key`, and request/response bodies.

## Security model and known risks

Intended boundaries:

- Both listeners bind to `127.0.0.1`.
- The inbound listener has only two entry points: `/health` and the catch-all
  that serves configured inbound routes. It does not serve the UI, admin, or
  outbound `/r` routes.
- The UI and admin require a local password sign-in, which also unlocks the
  vault. The UI an only be reached on the local port, not the inbound listener
  from the public internet
- Inbound routes require a per-route key.
- Injected headers and inbound keys are encrypted at rest.
- All unlocked secrets are in-memory only
- The vault starts locked and locks again on sign-out.

Known risks and limitations:

- **Single shared admin identity.** There are no user accounts, roles,
  permissions, MFA, or per-route admin access. Anyone with the admin username
  and vault password controls every route and can read every secret.
- **Outbound routes have no caller authentication.** While the vault is
  unlocked, any local process or user that can reach `OUTBOUND_PORT` can call
  `/r/<slug>/...` and spend the injected credentials against the target.
- **Inbound keys travel in a header.** Any component that can see request
  headers can capture the key: the tunnel provider, an intermediate reverse
  proxy, access logs, or the local upstream. Use a different key per route and
  rotate it if exposed.
- **Tunnel traffic is plain HTTP locally.** TLS normally terminates at the
  tunnel or reverse proxy, and the hop to `INBOUND_PORT` is unencrypted
  loopback HTTP. The tunnel provider can read all traffic.
- **Inbound targets can reach any loopback service.** The loopback restriction
  prevents arbitrary remote targets, but a route can still point at any
  service on the machine, including the outbound UI or another local admin
  interface. Creating such a route requires admin access.
- **Outbound targets are unrestricted.** An outbound route can call any
  `http://` or `https://` host. This is intentional, but it also means the tool
  can be used as a local SSRF primitive if a local attacker can create routes.
- **Secrets can be sent over plain HTTP.** If an outbound target uses `http://`,
  injected headers and request bodies are sent unencrypted.
- **Only some fields are encrypted.** Headers and inbound keys are encrypted by
  AshCloak. Route names, descriptions, prefixes, slugs, target URLs, and other
  metadata are stored in plaintext in SQLite.
- **The vault key lives in memory.** A BEAM crash dump can contain it. Set
  `ERL_CRASH_DUMP_SECONDS=0` and restrict access to the machine and crash
  artifacts.
- **No password recovery or key rotation.** Losing the vault password means
  recreating the database and every route. Changing the password rewraps the
  same data key; it does not rotate the key or invalidate old database copies.
- **No backup or restore feature.** You must copy the SQLite database and
  `-wal`/`-shm` files yourself, and any copy is readable with the password in
  use at the time of the copy.
- **No proxy rate limiting.** Login attempts are rate-limited, but inbound and
  outbound proxy requests are not. A valid caller can generate load up to
  `MAX_BODY_BYTES` and the upstream timeout. Add rate limiting at the tunnel
  provider if the endpoint is public.
- **No audit log.** Standard Phoenix/Logger output is the only record. Request
  logging is intentionally minimal; debug logging can expose keys and headers.
- **Not multi-tenant.** There is no isolation between routes, secrets, or
  callers beyond the per-route inbound key. Do not share one instance between
  people who should not see each other's routes.
- **Edge controls are not app authentication.** Cloudflare bot rules, WAF
  rules, IP allowlists, and User-Agent rules are protection at the edge. The
  only app-level gates are the admin sign-in and inbound route keys.

## Before exposing inbound access

- Confirm the tunnel origin is the inbound listener, not `OUTBOUND_PORT`.
- Confirm `OUTBOUND_PORT` is not reachable from another machine and is absent
  from every tunnel ingress rule.
- Use a strong vault password. The password is the only way to unlock the local
  vault.
- Give each inbound route its own high-entropy key and copy that key into the
  caller, for example the Smartsuite webhook configuration.
- Prefer a separate domain or zone for the public hostname so edge settings do
  not affect unrelated sites.
- Add rate limiting at the tunnel provider for the inbound path.
- Test `/health` through the tunnel and one inbound route end to end.
- Verify inbound `/r`, `/routes`, and `/admin` return 401 through the tunnel.
- Do not enable debug logging that prints `X-Proxy-Key` or injected headers on
  a long-running instance.

## Not for production

This project is intentionally a local tool. It is not designed for production
deployments, high availability, multiple users, or use as a security boundary
in front of sensitive systems.

Reasons include the in-memory vault key that requires a human to unlock after
every restart, the single shared admin identity, SQLite as the only datastore,
random session signing secrets per boot, no audit trail, and no key rotation,
backup, or restore tooling.

Use a real API gateway or reverse proxy with proper identity, authorization,
rate limiting, and key management if you need those properties.

## Tests

```sh
mix test
```
