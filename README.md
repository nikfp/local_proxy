# Local Proxy

A loopback-bound proxy with two directions and two listeners:

- **Outbound:** requests to `/r/<slug>/...` on `OUTBOUND_PORT` forward to a
  configured external URL with injected headers. All methods except `CONNECT`
  and `TRACE` are allowed.
- **Inbound:** a Cloudflare tunnel points at `INBOUND_PORT`; requests with
  `X-Proxy-Key` are matched by path prefix and forwarded to a local service.

Route configuration lives at `/routes` and AshAdmin at `/admin`, both on
`OUTBOUND_PORT`. Both require a password sign-in that also unlocks the vault.
The inbound listener exposes only `/health` and the inbound catch-all; it cannot
reach the UI, admin, or `/r`.

## Requirements

- Elixir and Erlang matching `mix.exs`
- SQLite
- A Cloudflare tunnel only if you want inbound access

## Environment variables

There are no required secret environment variables. The vault key, admin
password, inbound route keys, and `SECRET_KEY_BASE` are not read from the
environment. `SECRET_KEY_BASE` is generated per BEAM start, so sessions do not
survive a restart.

The following variables are optional:

- `ADMIN_USER` — sign-in username, default `admin`. Not secret.
- `OUTBOUND_PORT` — local listener port, default `4000`. Serves the UI,
  AshAdmin, `/health`, and outbound `/r` routes.
- `INBOUND_PORT` — tunnel listener port, default `4001`. Serves `/health` and
  the inbound catch-all.
- `UPSTREAM_TIMEOUT_MS` — upstream connect and receive timeout, default
  `30000`.
- `MAX_BODY_BYTES` — request and response body cap, default `10485760` (10 MB).
- `DATABASE_PATH` — production path to the SQLite file, for example
  `/var/lib/local_proxy/local_proxy.db`.
- `POOL_SIZE` — SQLite connection pool size in production, default `10`.
- `PHX_HOST` — URL host used for generated URLs in production, default
  `example.com`.
- `DNS_CLUSTER_QUERY` — optional clustering query; leave unset for a single
  node.
- `PHX_SERVER=true` — required when starting a release; it enables both
  listeners. `mix phx.server` in development does not need it.
- `ERL_CRASH_DUMP_SECONDS=0` — recommended so the in-memory vault key is not
  written to `erl_crash.dump`. This is read by the BEAM, not by the app.

Both listeners bind to `127.0.0.1`. `OUTBOUND_PORT` and `INBOUND_PORT` must
differ; boot fails with a clear message if they match.

## Local setup and run

```sh
mix setup
mix local_proxy.set_password
mix phx.server
```

`mix setup` installs dependencies, creates and migrates the SQLite database, and
builds assets. `mix local_proxy.set_password` prompts for the password that
wraps the vault data key. It is a required first-run step.

Open the UI at [`http://localhost:4000/routes`](http://localhost:4000/routes),
replacing the port if `OUTBOUND_PORT` is set. You will be redirected to
`/login`; sign in with `ADMIN_USER` (default `admin`) and the vault password.
`GET /health` is unauthenticated on both listeners and reports `status` and
`vault`.

The app starts locked. Proxy requests return `503 vault_locked` until a human
signs in locally. Sign out to lock the vault again. Sessions do not survive an
app restart because the signing secret is generated at boot.

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

## Tunnel

Point the public hostname at the inbound listener,
`http://127.0.0.1:4001` (or `INBOUND_PORT`). Each inbound route has its own key.
The caller supplies that route's key in `X-Proxy-Key`; Cloudflare does not add
it. Inbound target URLs must be loopback (`localhost`, `127.0.0.0/8`, or
`::1`).

An inbound route with prefix `/api` and target `http://localhost:3000` maps:

- `/api` -> `http://localhost:3000/`
- `/api/users?x=1` -> `http://localhost:3000/users?x=1`

Any request that does not match an inbound prefix, or that carries the wrong
key for the matched route, returns 401. The key check uses the route's own key,
not a shared global key.

The tunnel listener does not contain `/r`, `/routes`, or `/admin`. A tunneled
request to those paths returns 401 because no inbound route matches, so
exposing the tunnel does not expose the outbound proxy or the management UI.
The outbound listener stays local and is only reachable on loopback.

The tunnel does not add `X-Proxy-Key` by itself. The caller must send it. For
example, a Smartsuite outbound webhook can set it as a custom header.

## Production deployment

1. Generate the release scaffolding once and commit it:
   ```sh
   mix phx.gen.release
   ```

2. Set the production variables you need: `DATABASE_PATH`, `PHX_SERVER=true`,
   and optionally `ADMIN_USER`, `PHX_HOST`, and the port/timing limits. Do not
   set `SECRET_KEY_BASE`, `CLOAK_KEY`, `ADMIN_PASSWORD`, or
   `INBOUND_PROXY_KEY`.

3. Build assets and the release:
   ```sh
   MIX_ENV=prod mix assets.deploy
   MIX_ENV=prod mix release
   ```
   `assets.deploy` creates `priv/static/cache_manifest.json`, which
   `config/prod.exs` expects.

4. Run migrations on the deployment host before starting:
   ```sh
   bin/local_proxy eval "LocalProxy.Release.migrate()"
   ```

5. Set the vault password once using the release eval equivalent of
   `mix local_proxy.set_password`, then start both listeners:
   ```sh
   PHX_SERVER=true bin/local_proxy start
   ```

6. Keep the SQLite directory writable. There is no backup or restore feature.
   If you copy the database, the password current at the time of the copy can
   open it. To reset, stop the app, delete the database and `-wal`/`-shm`
   sidecars, recreate the schema, and run the password setup again. All routes
   must be re-created.

The release starts locked. The tunnel returns 503 until a human signs in through
the local UI. There is deliberately no remote unlock path.

## Before exposing the tunnel

- Confirm the tunnel origin is the inbound listener, not `OUTBOUND_PORT`.
- Confirm `OUTBOUND_PORT` is not reachable from another machine and is absent
  from every tunnel ingress rule.
- Use a strong vault password. The password is the only way to unlock the local
  vault.
- Give each inbound route its own high-entropy key and copy that key into the
  caller, for example the Smartsuite webhook configuration.
- Test `/health` through the tunnel and one inbound route end to end.
- Verify inbound `/r`, `/routes`, and `/admin` return 401 through the tunnel.
- Check logs for route, status, and timing without leaking keys or headers.

## Tests

```sh
mix test
```
