# Local Proxy

A loopback-bound proxy with two directions:

- **Outbound:** `GET /r/<slug>/...` forwards to a configured external URL with
  injected headers.
- **Inbound:** a Cloudflare tunnel points at this app; requests with
  `X-Proxy-Key` are matched by path prefix and forwarded to a local service.

Route configuration lives at `/routes`. AshAdmin is at `/admin`. Both require
HTTP basic auth.

## Setup

```sh
mix setup
```

## Environment

The app fails fast at boot if a required secret is missing or malformed. Export
these before starting the server in development or production:

```sh
# 32 random bytes, base64-encoded. Generate one with:
#   elixir -e 'IO.puts(Base.encode64(:crypto.strong_rand_bytes(32)))'
export CLOAK_KEY="..."

export INBOUND_PROXY_KEY="..."
export ADMIN_USER="admin"
export ADMIN_PASSWORD="..."
```

Optional:

```sh
# Listen port (default 4000). The bind address stays 127.0.0.1.
export PORT=4100

export UPSTREAM_TIMEOUT_MS=30000
export MAX_BODY_BYTES=10485760
```

Production also uses the existing `DATABASE_PATH` and `SECRET_KEY_BASE`.
Tests use fixed fixture secrets and do not read the variables above.

## Running

```sh
mix phx.server
```

Visit [`localhost:<PORT>/routes`](http://localhost:4000/routes), replacing the
port if `PORT` is set. `GET /health` is unauthenticated and returns
`{"status":"ok"}`.

## Outbound routes

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

Point the public hostname at `http://127.0.0.1:<PORT>` (default `4000`) and add
the `X-Proxy-Key` header to inbound requests. Inbound target URLs must be
loopback (`localhost`, `127.0.0.0/8`, or `::1`).

## Tests

```sh
mix test
```
