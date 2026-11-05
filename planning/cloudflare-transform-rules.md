# Injecting X-Proxy-Key with Cloudflare

Use this when an inbound caller, such as a Smartsuite webhook, cannot set a
custom `X-Proxy-Key` header. Cloudflare can add the header at the edge before
the request reaches the tunnel, so Local Proxy still performs its normal route
key check.

## Request header transform rule

Cloudflare dashboard -> Rules -> Transform Rules -> Modify request header.

Match as narrowly as possible. Start with host, path, and method:

```text
(http.host eq "local-proxy-mini.nikfp.com"
 and starts_with(http.request.uri.path, "/test")
 and http.request.method eq "POST")
```

If the caller has stable source IPs, include them so arbitrary clients cannot
trigger the rule:

```text
(http.host eq "local-proxy-mini.nikfp.com"
 and starts_with(http.request.uri.path, "/test")
 and http.request.method eq "POST"
 and ip.src in {203.0.113.10 203.0.113.11})
```

Do not match on `User-Agent` alone. User-Agent values can be spoofed and are not
authentication.

Action: Set static header.

- Header name: `X-Proxy-Key`
- Value: the key saved on the matching inbound route in Local Proxy

Replace the placeholder below with the key from the `/routes` form:

```text
<route-key>
```

Deploy the rule. The transform rule supplies the header only for matching
requests. Requests that do not match, and direct requests to the inbound
listener, still need to provide `X-Proxy-Key` themselves.

## Verification

1. Send the caller-style request through the public hostname without an
   `X-Proxy-Key` header. It should reach Local Proxy and return the upstream
   response, not 401.
2. Send the same request directly to `127.0.0.1:INBOUND_PORT` without the
   header. It should return 401. This confirms the header is added only at the
   edge.
3. Send a request to a different host or path and confirm it does not receive
   the injected key.

## Notes

- The rule authenticates every request matching its expression. Keep the host,
  path, method, and optional source IP restrictions tight.
- Cloudflare terminates TLS, so it can see the injected key and the request and
  response bodies.
- The key now exists in both the Local Proxy route and the Cloudflare rule.
  Update both together when rotating it.
- Keep Cloudflare account access restricted; anyone who can edit the rule can
  read or change the key.
- Do not make the inbound route keyless to solve this. The transform rule keeps
  the app-level key check in place.
