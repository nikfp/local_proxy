# Local Proxy

A loopback-bound proxy with two directions and two listeners:

- **Outbound:** requests to `/r/<slug>/...` on `OUTBOUND_PORT` forward to a
  configured external URL with injected headers. All methods except `CONNECT`
  and `TRACE` are allowed.
- **Inbound:** a Cloudflare tunnel points at `INBOUND_PORT`; requests with
  `X-Proxy-Key` are matched by path prefix and forwarded to a local service.

Route configuration lives at `/routes` and AshAdmin at `/admin`, both on
`OUTBOUND_PORT`. Both require HTTP basic auth. The inbound listener exposes only
`/health` and the inbound catch-all; it cannot reach the UI, admin, or `/r`.

## Requirements

- Elixir and Erlang matching `mix.exs`
- SQLite
- A Cloudflare tunnel only if you want inbound access

## Environment variables

The app fails fast if a required value is missing or malformed. Export values in
the shell; there is no `.env` loader.

### Required in development and production

- `CLOAK_KEY` — base64-encoded 32-byte AES key used to encrypt route headers.
  Generate one with:
  ```sh
  elixir -e 'IO.puts(Base.encode64(:crypto.strong_rand_bytes(32)))'
  ```
  Changing this key makes existing stored headers unreadable. Back it up.
- `INBOUND_PROXY_KEY` — shared key for inbound requests. Callers send it as
  `X-Proxy-Key`.
- `ADMIN_USER` — basic auth user for `/routes` and `/admin`.
- `ADMIN_PASSWORD` — basic auth password for `/routes` and `/admin`.

Tests use fixed fixture values and do not require these variables.

### Required in production

- `SECRET_KEY_BASE` — generate with `mix phx.gen.secret`.
- `DATABASE_PATH` — absolute path to the SQLite file, for example
  `/var/lib/local_proxy/local_proxy.db`.
- `PHX_SERVER=true` — required when starting a release; it enables both
  listeners. `mix phx.server` in development does not need it.

### Optional

- `OUTBOUND_PORT` — local listener port, default `4000`. Serves the UI,
  AshAdmin, `/health`, and outbound `/r` routes.
- `INBOUND_PORT` — tunnel listener port, default `4001`. Serves `/health` and
  the inbound catch-all.
- `UPSTREAM_TIMEOUT_MS` — upstream connect and receive timeout, default
  `30000`.
- `MAX_BODY_BYTES` — request and response body cap, default `10485760` (10 MB).
- `POOL_SIZE` — SQLite connection pool size in production, default `10`.
- `PHX_HOST` — URL host used for generated URLs in production, default
  `example.com`.
- `DNS_CLUSTER_QUERY` — optional clustering query; leave unset for a single
  node.

Both listeners bind to `127.0.0.1`. `OUTBOUND_PORT` and `INBOUND_PORT` must
differ; boot fails with a clear message if they match.

## Local setup and run

Export the required secrets first, then:

```sh
mix setup
mix phx.server
```

`mix setup` installs dependencies, creates and migrates the SQLite database, and
builds assets.

Open the UI at [`http://localhost:4000/routes`](http://localhost:4000/routes),
replacing the port if `OUTBOUND_PORT` is set. `GET /health` is unauthenticated on
both listeners and returns `{"status":"ok"}`.

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
`http://127.0.0.1:4001` (or `INBOUND_PORT`), and add the `X-Proxy-Key` header to
inbound requests. Inbound target URLs must be loopback (`localhost`,
`127.0.0.0/8`, or `::1`).

An inbound route with prefix `/api` and target `http://localhost:3000` maps:

- `/api` -> `http://localhost:3000/`
- `/api/users?x=1` -> `http://localhost:3000/users?x=1`

Any request that does not match an inbound prefix returns 404. Requests with a
missing or wrong key get 401 before a target is contacted.

The tunnel listener does not contain `/r`, `/routes`, or `/admin`. A tunneled
request to those paths returns 404 after auth, so exposing the tunnel does not
expose the outbound proxy or the management UI. The outbound listener stays
local and is only reachable on loopback.

The tunnel does not add `X-Proxy-Key` by itself. The caller must send it, or a
Cloudflare transform rule must add it before the request reaches the origin.

## Production deployment

1. Generate the release scaffolding once and commit it:
   ```sh
   mix phx.gen.release
   ```

2. Export the production variables, including `SECRET_KEY_BASE`,
   `DATABASE_PATH`, `PHX_SERVER=true`, and all required secrets above.

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

5. Start both listeners:
   ```sh
   PHX_SERVER=true bin/local_proxy start
   ```

6. Keep the SQLite directory writable and backed up. Back up `CLOAK_KEY`
   separately; without it, stored header values cannot be decrypted.

## Before exposing the tunnel

- Confirm the tunnel origin is the inbound listener, not `OUTBOUND_PORT`.
- Confirm `OUTBOUND_PORT` is not reachable from another machine and is absent
  from every tunnel ingress rule.
- Use a strong `INBOUND_PROXY_KEY` and a strong `ADMIN_PASSWORD`.
- Decide how callers will supply `X-Proxy-Key`.
- Test `/health` through the tunnel and one inbound route end to end.
- Verify inbound `/r`, `/routes`, and `/admin` return 404 through the tunnel.
- Check logs for route, status, and timing without leaking keys or headers.

## Tests

```sh
mix test
```
