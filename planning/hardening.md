# Local Proxy — Secret Hardening

This document extends `planning/app_design.md`. It replaces the boot-time
`CLOAK_KEY` requirement with a vault that stays locked until a human signs in,
removes the plaintext admin password and inbound key from the environment, and
generates `SECRET_KEY_BASE` per BEAM start.

## Motivation

The proxy exists so development apps and LLM agents can call external services
without those services' API keys ever entering an LLM context. Today the route
headers are encrypted at rest, but the encryption key (`CLOAK_KEY`), admin
password (`ADMIN_PASSWORD`), inbound key (`INBOUND_PROXY_KEY`), and cookie
signing secret (`SECRET_KEY_BASE`) are environment variables. An agent running
as the same macOS user can read them, then either decrypt the SQLite file or
sign into the UI and use the reveal button / AshAdmin.

The goal is narrow and deliberate: an agent that can read files and run shell
commands as the user must not be able to recover injected header values. It is
not a defence against a determined attacker with the user's password, and it
does not stop an agent from *using* the proxy while it is unlocked. The proxy
also cannot prevent an upstream that reflects request headers from returning
them to the caller; that is out of scope and depends on route targets not
behaving that way.

## Core principle

Any secret the app can obtain unattended is a secret a same-user process can
obtain. A password-protected file only helps if the password is supplied by a
human or hardware. Therefore the decryption key is bound to the one human
gesture already in the design: signing in.

## Design summary

- The vault starts with no key. No key material is read at boot.
- A random 32-byte data key `K` encrypts route headers and per-route inbound
  keys.
- `K` is stored wrapped (AES-256-GCM) under a key derived from the admin
  password with a slow KDF. Only the wrapped form is persisted, in `vault_keys`.
- Login derives the KEK, unwraps `K`, and installs it in an in-memory keyring.
  A failed unwrap is a failed login — there is no separate password hash.
- Encryption and decryption go through a wrapper cipher that reads the keyring
  at call time. It does not require restarting the vault.
- While locked, proxy traffic returns `503 vault_locked`. `/health` and
  `/login` still work.
- Each inbound route has its own key, stored encrypted under `K`. The caller
  supplies it in `X-Proxy-Key`.
- `SECRET_KEY_BASE` is generated per BEAM start. There is no environment secret
  to read.
- Locking is implicit on app start and explicit on sign-out. The key never
  touches disk in usable form.

This replaces the old `CLOAK_KEY` promise. The key is now recoverable from the
password rather than from the environment, and changing the password only
rewraps `K`. Old database copies remain readable with the old password.

## Threat model

Protected against:

- Reading the SQLite database, backups, or a synced project directory.
- Reading the shell environment, `.zshrc`, or process environment. The vault
  key, admin password, inbound keys, and `SECRET_KEY_BASE` are not there.
- Reading any key file on disk — there isn't one.
- Forging a session using a leaked `SECRET_KEY_BASE`; it is generated per BEAM
  start and never stored.
- A stale browser session surviving an app restart.
- Remote or tunnel-based unlock. Login exists only on the loopback listener.

Not protected against:

- An agent using the proxy through `/r/...` while the vault is unlocked. That
  is the intended feature; decryption isolation does not prevent use.
- An upstream that reflects injected headers or redirects them onward. If an
  agent can make such a request while unlocked, the values can return in the
  response. This is out of scope and depends on route targets.
- An agent that observes the password (keylogger, shoulder surfing, shared
  clipboard).
- An agent that can read the caller's configuration, for example Smartsuite's
  copy of an inbound key. The vault protects only the local copy.
- An agent that deletes or corrupts `vault_keys` or the database. That is a
  denial of service, not a leak.
- An agent that can modify application code or the running BEAM.
- Same-user OS-level isolation. If that is required, run the app as a separate
  macOS user via launchd (see Alternatives).

Note the asymmetry: DB write access lets an attacker replace the wrapped key,
but the replacement cannot decrypt existing ciphertext, so headers stay
confidential. It can only break the app.

## Key envelope

Persisted in a `vault_keys` table with exactly one row.

- `id` — fixed string, `"default"`, primary key. Enforces the singleton.
- `wrapped` — binary, the envelope below.
- `inserted_at`, `updated_at`.

Envelope layout (versioned, self-describing):

```
<<1,
  salt::binary-size(16),
  iterations::unsigned-32,
  iv::binary-size(12),
  tag::binary-size(16),
  ciphertext::binary-size(32)>>
```

- `K` — 32 random bytes from `:crypto.strong_rand_bytes/1`.
- KEK — `:crypto.pbkdf2_hmac(:sha256, password, salt, iterations, 32)`.
  Baseline 600,000 iterations. Argon2id is preferable if a raw-digest API is
  available; if added, encode it as version 2 and keep PBKDF2 for reading.
- Accepted `iterations` range is 100,000 to 2,000,000. Reject anything outside
  that range before running the KDF, so a tampered row cannot hang login.
- Password length is 12 to 1,024 bytes.
- Wrap — AES-256-GCM with the random IV, AAD `"local_proxy:vault_key:v1"`.
- Store the salt, iterations, IV, and tag inside the envelope. Never store the
  KEK or any password hash.
- A wrong password fails GCM tag verification. Compare in constant time by
  relying on the AEAD tag; do not add a separate `==` check.
- The admin username is `ADMIN_USER`, optional and defaulting to `admin`. It is
  not secret.

There is no backup or restore feature in this design. If an operator makes a
copy of the database, that copy contains the wrapped key and every ciphertext,
and the password that was current when the copy was made can open it. Changing
the password later does not invalidate old copies. Losing the password means
existing headers are unrecoverable; recovery is to delete the database and
re-enter the routes.

## Keyring

`LocalProxy.Vault.KeyRing` is a tiny module over `:persistent_term`. Writes
happen only on unlock/lock, so reads stay free in the hot path.

```elixir
@pt_key {__MODULE__, :state}

def unlock(key) when byte_size(key) == 32 do
  generation = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  :persistent_term.put(@pt_key, %{key: key, generation: generation})
  {:ok, generation}
end

def lock do
  :persistent_term.erase(@pt_key)

  if Process.whereis(LocalProxy.PubSub) do
    Phoenix.PubSub.broadcast(LocalProxy.PubSub, "vault", :vault_locked)
  end

  :ok
end

def key do
  case :persistent_term.get(@pt_key, :locked) do
    %{key: key} -> {:ok, key}
    :locked -> :locked
  end
end

def generation do
  case :persistent_term.get(@pt_key, :locked) do
    %{generation: generation} -> {:ok, generation}
    :locked -> :locked
  end
end

def locked?, do: key() == :locked
```

- The key is in VM memory only. It is process-wide, so every authenticated
  session shares the unlocked vault. That is acceptable for a single-user tool
  and is bounded by the login check below.
- `KeyRing.lock/0` erases the term and broadcasts `:vault_locked` on
  `LocalProxy.PubSub` so LiveViews can redirect or disconnect. It must tolerate
  PubSub not being started in a mix task.
- `:persistent_term` is chosen for read performance; a GenServer or ETS would
  also work. None of them are a boundary against code running inside the VM.
- Do not log the key, the KEK, the password, or the envelope.
- Disable or redirect BEAM crash dumps (`ERL_CRASH_DUMP_SECONDS=0`) so the
  in-memory key cannot be written to `erl_crash.dump`.

## Wrapper cipher

`Cloak.Cipher` is a simple behaviour (`can_decrypt?/2`, `encrypt/2`,
`decrypt/2`), so the vault can keep a static cipher configuration and still
pick up the key at runtime.

```elixir
defmodule LocalProxy.Vault.Cipher do
  @behaviour Cloak.Cipher

  alias Cloak.Ciphers.AES.GCM
  alias LocalProxy.Vault.KeyRing

  @impl true
  def can_decrypt?(ciphertext, opts), do: GCM.can_decrypt?(ciphertext, opts)

  @impl true
  def encrypt(plaintext, opts) do
    case KeyRing.key() do
      {:ok, key} -> GCM.encrypt(plaintext, Keyword.put(opts, :key, key))
      :locked -> {:error, LocalProxy.Vault.LockedError.exception([])}
    end
  end

  @impl true
  def decrypt(ciphertext, opts) do
    case KeyRing.key() do
      {:ok, key} ->
        case GCM.decrypt(ciphertext, Keyword.put(opts, :key, key)) do
          {:ok, plaintext} when is_binary(plaintext) -> {:ok, plaintext}
          _ -> {:error, LocalProxy.Vault.DecryptError.exception([])}
        end

      :locked ->
        {:error, LocalProxy.Vault.LockedError.exception([])}
    end
  end

  def on_decrypt(_resource, _records, _field, _context) do
    if KeyRing.locked?(), do: {:error, LocalProxy.Vault.LockedError.exception([])}, else: :ok
  end
end
```

Vault configuration becomes static and keyless:

```elixir
def init(config) do
  ciphers = [default: {LocalProxy.Vault.Cipher, tag: "AES.GCM.V1", iv_length: 12}]
  {:ok, Keyword.put(config, :ciphers, ciphers)}
end
```

Important compatibility points:

- Keep `tag: "AES.GCM.V1"` and `iv_length: 12` exactly as today
  (`lib/local_proxy/vault.ex:20-23`). Existing `encrypted_headers` values must
  keep decrypting without a migration.
- `Cloak.Ciphers.AES.GCM.can_decrypt?/2` only inspects the tag header and does
  not use the key, so the wrapper can delegate while locked. This lets Cloak
  pick the cipher without exposing key material.
- `LockedError` is a small exception module implementing `Plug.Exception` with
  status 503. Cloak's `encrypt!/1` and `decrypt!/1` expect an exception tuple,
  so both callbacks return `{:error, LockedError.exception([])}` when locked.
- Never return bare `:error` from `decrypt/2`. `Cloak.Vault.decrypt!/1` only
  matches `{:ok, _}` and `{:error, _}`; a bare `:error` would raise
  `CaseClauseError`. Cloak's GCM cipher returns `{:ok, :error}` when the tag
  does not authenticate, so normalize any non-binary plaintext to
  `LocalProxy.Vault.DecryptError`.
- AshCloak calls `vault.decrypt!/1`, so `Route` sets `on_decrypt` to
  `LocalProxy.Vault.Cipher.on_decrypt/4`. That returns `{:error, LockedError}`
  before AshCloak reaches `decrypt!` while locked.
- A lock can still arrive between the pre-check and `decrypt!`. Proxy
  controllers and LiveView event handlers rescue `LockedError` and return 503 or
  redirect.

## Login and unlock flow

1. `GET /login` renders the form. If `vault_keys` has no row, render a setup
   notice instead: run `mix local_proxy.set_password`. Do not allow first-run
   setup over HTTP; an agent could claim the password before the human does.
2. Apply the login rate limit: five failed attempts per minute per source, then
   429 with `Retry-After`. Reset the counter on success. The limiter is
   in-memory per BEAM; a restart clears it.
3. `POST /login` checks the username against `ADMIN_USER` (default `admin`) with
   the existing length guard and `Plug.Crypto.secure_compare/2`.
4. Load the singleton `vault_keys` row, validate the envelope and iteration
   range, derive the KEK, and attempt to unwrap `K`. This happens on *every*
   successful login, even if the vault is already unlocked. It is the password
   check.
5. On unwrap success, call `KeyRing.unlock(K)`, which returns a random
   `generation`.
6. Renew the session, store `:admin_authenticated` and
   `:unlock_generation`, then redirect.
7. On unwrap failure, return 401 with the generic invalid-credentials message.
   Do not distinguish unknown user from bad password.

Verifying the unwrap on every login matters. It means a tampered admin hash or
a forged cookie cannot mint a session while the vault is unlocked. The only
password that produces a session is the one that wrapped the stored key.

### Session binding

Sessions are signed with `SECRET_KEY_BASE`, which is generated per BEAM start
and is not in the environment. Bind each session to the unlock generation:

- `RequireAuth` requires `:admin_authenticated` **and** that
  `get_session(:unlock_generation)` equals `KeyRing.generation/0`.
- If the vault is locked or the generation differs, drop the session, set a
  flash, and redirect to `/login`.
- `SessionController.new/2` must also check the generation, otherwise a stale
  session can loop between `/login` and `/routes`.
- LiveView mounts must apply the same check. A socket that outlives a lock
  should be disconnected or redirected. `KeyRing.lock/0` broadcasts
  `:vault_locked` on `LocalProxy.PubSub`; LiveViews handle it and disconnect.
- Set the session cookie `max_age` to 12 hours.
- Every successful login creates a new generation, so a second browser
  invalidates the first session. Logout locks the vault for everyone.
- This also invalidates sessions after an app restart, which is correct: the
  cookie is no longer verifiable and the vault is locked.

### Sign-out and idle lock

- `POST /logout` drops the session **and** calls `KeyRing.lock/0`. Signing out
  therefore stops the proxy until the next sign-in. This is the chosen secure
  default.
- A separate "Lock now" button is optional sugar for the same action.
- Idle lock is not implemented in this cut. The vault stays unlocked until
  sign-out or restart.

## Locked behaviour

- Outbound `match /r/...` and the inbound catch-all return
  `503 {"error":"vault_locked","status":503}` before route lookup. A
  `VaultGate` plug runs first. Inbound does not look up routes or keys while
  locked.
- `/health` stays unauthenticated and `200`. Add `"vault":"locked"` or
  `"vault":"unlocked"` to the payload so scripts can wait for unlock.
- `/login`, `/routes`, and `/admin` require a session as today. While locked,
  there is no valid session because `RequireAuth` also checks the generation.
- The inbound listener serves the same 503. Consequence: after every BEAM
  start, the Cloudflare tunnel returns 503 until a human signs in locally. This
  is accepted and is the cost of never reading a key at boot.
- While locked, UI reads return an Ash error rather than a crash because
  `on_decrypt` returns `LockedError`. Writes and any lock that races a request
  are rescued at the controller or LiveView boundary.
- Do not allow routes with empty headers to forward while locked. The exception
  adds branching and weakens the single locked state.

## First run, rotation, reset

Add one mix task. In a terminal it uses a hidden password prompt; when stdin is
not a terminal it falls back to a plain line read so scripted setup still works.
It never accepts the password as a CLI argument or env var. The task starts only
the Repo, not the web endpoints, so it can run with the app stopped.

- `mix local_proxy.set_password`
  - If no `vault_keys` row: generate `K`, prompt for a new password twice,
    validate 12–1,024 bytes, and write the envelope.
  - If a row exists: prompt for the current password, unwrap `K`, prompt for a
    new password, rewrap, and update in one transaction.
  - Changing the password only rewraps `K`. It does not rotate the data key, so
    old database copies remain decryptable with the old password.
  - Never regenerate silently when the envelope fails to unwrap.

There is no `adopt_key` task and no `reset_vault` task. This app is per-machine
and not migrateable.

To reset, stop the app and delete the SQLite database and its sidecars:

```sh
rm -f local_proxy_dev.db local_proxy_dev.db-wal local_proxy_dev.db-shm
```

In production, use the configured `DATABASE_PATH` and delete the matching
`-wal` and `-shm` files. Then run `mix ecto.reset` in dev, or start the release
once so `Ecto.Migrator` creates the schema. Finally run
`mix local_proxy.set_password` (or the release `eval` equivalent) and start the
app. All routes and inbound keys are re-created manually. There is no backup or
restore path.

Boot order stays `KeyRing` (stateless) → `Vault` → `Repo`. The vault no longer
needs a key to start, so `lib/local_proxy/application.ex:12` can stay where it
is.

There is no `CLOAK_KEY` override. `ADMIN_PASSWORD` is removed entirely.
`ADMIN_USER` is optional and defaults to `admin`. `SECRET_KEY_BASE` is generated
per BEAM start and is not read from the environment.

## Configuration changes

Remove from the required list in `planning/app_design.md`:

- `CLOAK_KEY` — replaced by the wrapped key and sign-in unlock.
- `ADMIN_PASSWORD` — replaced by the password that wraps the key.
- `INBOUND_PROXY_KEY` — replaced by per-route inbound keys stored encrypted
  under `K`.
- `SECRET_KEY_BASE` — generated per BEAM start.

Keep:

- `ADMIN_USER` — optional, default `admin`, not secret.
- `DATABASE_PATH` (prod only)
- Ports, timeout, body limit

New optional:

- None. Idle lock is deferred.

`config/runtime.exs` no longer reads `CLOAK_KEY`, `ADMIN_PASSWORD`,
`INBOUND_PROXY_KEY`, or `SECRET_KEY_BASE`. It sets `ADMIN_USER` to the env value
or `admin`, parses ports and limits, and generates a per-boot signing secret.
Remove `LocalProxy.Config.decode_cloak_key/1` and
`decode_cloak_key!/1` if nothing else uses them. Update `config/test.exs` to
unlock `KeyRing` with a fixed test key in setup and to drop the old
`:admin.password` and `:inbound_proxy_key` values.

Each inbound route stores its own `inbound_key`, encrypted with AshCloak under
`K`. The caller supplies that key in `X-Proxy-Key`. There is no global inbound
key and no tunnel-side key injection assumption.

### README environment variables

The README must state that there are no required secret environment variables.
List only these optional variables:

- `ADMIN_USER` — sign-in username, default `admin`; not secret.
- `OUTBOUND_PORT` — default `4000`.
- `INBOUND_PORT` — default `4001`.
- `UPSTREAM_TIMEOUT_MS` — default `30000`.
- `MAX_BODY_BYTES` — default `10485760`.
- `DATABASE_PATH` — production SQLite path.
- `POOL_SIZE` — production SQLite pool size, default `10`.
- `PHX_HOST` — production URL host.
- `DNS_CLUSTER_QUERY` — optional single-node clustering query.
- `PHX_SERVER=true` — release start only.
- `ERL_CRASH_DUMP_SECONDS=0` — recommended BEAM setting, not read by the app.

Do not list `CLOAK_KEY`, `ADMIN_PASSWORD`, `INBOUND_PROXY_KEY`, or
`SECRET_KEY_BASE`. `.env.example` must also drop them and contain only optional
non-secret values.

## Data model additions

`LocalProxy.Vault.Key` — an Ash resource in its own domain, kept out of
AshAdmin.

- `id` — string primary key, `"default"`.
- `wrapped` — binary, `allow_nil?: false`.
- `inserted_at`, `updated_at`.
- Actions: primary `read`, primary `create`, and primary `update`.
- Migration creates the table with a fixed primary key and a SQLite trigger that
  rejects any `id` other than `'default'`.
- No UI, no policies; single-user tool.

`LocalProxy.Routing.Route` gains:

- `inbound_key` — string, nullable, encrypted by AshCloak alongside `headers`.
  Required for enabled inbound routes, nil for outbound, 32–256 characters.
  The UI generates, shows once, and rotates it immediately; the old key stops
  working at once. Generated values use 32 random bytes encoded with
  `Base.url_encode64(..., padding: false)`. It is never logged or shown in
  AshAdmin.

Do not add a password hash column. The AEAD tag is the verifier.

## Error responses

Add to the proxy error list in `planning/app_design.md`:

- `503` `{"error":"vault_locked","status":503}`
- Inbound `401` `{"error":"unauthorized","status":401}` now covers unknown
  path, missing route key, and wrong key.

No route, target, or timing information is included while locked. Unknown
inbound paths and bad keys are indistinguishable.

## Testing

Vault and envelope:

- Locked `encrypt/2` and `decrypt/2` return `{:error, %LockedError{}}`; bang
  functions raise `LockedError`, never `CaseClauseError`.
- A tampered or unauthentic ciphertext returns `{:error, %DecryptError{}}`;
  `decrypt!` raises `DecryptError`, never `CaseClauseError`.
- `can_decrypt?/2` still identifies `"AES.GCM.V1"` ciphertext while locked.
- Unlock installs the key; encrypt/decrypt round-trip.
- Wrong password fails unwrap and leaves the vault locked.
- Tampered envelope (salt, IV, tag, ciphertext) fails unwrap.
- Envelope version byte and iteration range are validated; out-of-range values
  are rejected without running the KDF.
- Ciphertext produced by the old `AES.GCM` configuration decrypts through the
  wrapper with the same tag and `iv_length: 12`.
- The raw key is never present in the `vault_keys` row.

Login and sessions:

- Login with the correct password unlocks and sets the generation.
- Login with a wrong password returns 401 and does not unlock.
- Login while already unlocked still verifies the unwrap.
- The sixth failed login in a minute returns 429; a success resets the counter.
- A session with a stale or missing generation is redirected to `/login`.
- `SessionController.new/2` does not redirect a stale session into a loop.
- A valid cookie from before an app restart is rejected while locked.
- Logout drops the session and locks the vault.
- `RequireAuth` is applied to `/routes` and `/admin`; LiveView mounts check the
  generation too.

Proxy:

- `/r/...` and the inbound catch-all return 503 while locked, without touching
  the target.
- They work after unlock.
- `/health` returns 200 and reports `locked` before sign-in.
- Per-route inbound keys reject another route's key with 401.
- No route and bad key return the same 401.

Mix tasks and reset:

- `set_password` creates the row on first run and rewraps on rotation.
- Password prompts never echo; the task never reads the password from env or
  argv.
- Reset by deleting the database and sidecars, recreating the schema, and
  running `set_password` produces a working locked-then-unlocked vault.

## Deltas to `planning/app_design.md`

- Decisions: replace "Secrets fail fast at boot" with "the vault is locked at
  boot and unlocks on sign-in". Remove `CLOAK_KEY`, `ADMIN_PASSWORD`,
  `INBOUND_PROXY_KEY`, and `SECRET_KEY_BASE` from the environment. Add the 503
  state and per-route inbound keys.
- Modules: add `LocalProxy.Vault.KeyRing`, `LocalProxy.Vault.Cipher`,
  `LocalProxy.Vault.Envelope`, `LocalProxy.Vault.Key`,
  `LocalProxy.Vault.KeyStore`, `LocalProxy.Vault.LoginLimiter`,
  `LocalProxy.Vault.LockedError`, `LocalProxy.Vault.DecryptError`,
  `LocalProxy.Routing.InboundKey`, `LocalProxyWeb.LiveUserAuth`, and
  `LocalProxyWeb.Plugs.VaultGate`. `set_password` is the only new mix task.
- Encryption: replace the `CLOAK_KEY` paragraph with the envelope and wrapper
  design above. Note the unchanged `"AES.GCM.V1"` / `iv_length: 12` format.
  Add `inbound_key` to AshCloak attributes and `on_decrypt`.
- Configuration: drop all secret environment variables. `ADMIN_USER` is
  optional and defaults to `admin`. `SECRET_KEY_BASE` is generated per boot.
- Request flow: gate both directions on `KeyRing.locked?/0` before route
  lookup. Inbound matches the route first, then checks that route's key.
- Error responses: add `503 vault_locked`; inbound unknown route and bad key
  are both 401.
- Security notes: replace "changing `CLOAK_KEY`" with "losing the password".
  Document that password rotation does not rotate the data key, remote unlock
  is impossible, and an unlocked proxy can be used by an agent.
- Testing: add the vault, envelope, session, locked-proxy, rate-limit, and
  per-route inbound key cases.
- Build phases: fold vault hardening into Phase 1 and per-route inbound keys
  into Phase 3; no separate Phase 4.
- README: document `mix local_proxy.set_password` as a required first-run step,
  the unlock-on-login workflow, the 503 window after restarts, resetting by
  deleting the database, local-only unlock, and per-route inbound keys supplied
  by callers such as Smartsuite.

## Alternatives considered

- **Plain `0600` key file.** Removes the env var, gives no protection against a
  same-user agent. Rejected as a security measure; acceptable only for
  convenience.
- **macOS Keychain generic password.** A login-keychain item is readable by
  `security` while the keychain is unlocked, which is exactly the agent's
  situation. Only an item with an ACL trusting a specific helper is a barrier,
  and that behaviour varies across macOS versions. Adds a platform-specific
  dependency for a partial win.
- **Touch ID / 1Password CLI (`op read`).** Real human-presence barrier with
  little custom code. Good fallback if the password-on-login workflow proves
  annoying, at the cost of a third-party dependency.
- **Encrypted key file with a passphrase at boot.** Equivalent to the chosen
  design but adds a third secret to remember; the admin password already
  exists.
- **Separate macOS user plus launchd.** The only true same-user isolation. The
  agent cannot read another account's home without `sudo`. Heavy for a dev
  tool; document as the escalation path if the threat model tightens.

## Open questions

None.
