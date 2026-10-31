# Local Proxy — Secret Hardening

This document extends `planning/app_design.md`. It replaces the boot-time
`CLOAK_KEY` requirement with a vault that stays locked until a human signs in,
and removes the plaintext admin password from the environment.

## Motivation

The proxy exists so development apps and LLM agents can call external services
without those services' API keys ever entering an LLM context. Today the route
headers are encrypted at rest, but the encryption key (`CLOAK_KEY`) and the
admin password (`ADMIN_PASSWORD`) are environment variables. An agent running
as the same macOS user can read both, then either decrypt the SQLite file or
sign into the UI and use the reveal button / AshAdmin.

The goal is narrow and deliberate: an agent that can read files and run shell
commands as the user must not be able to recover injected header values. It is
not a defence against a determined attacker with the user's password, nor does
it stop an agent from *using* the proxy while it is unlocked.

## Core principle

Any secret the app can obtain unattended is a secret a same-user process can
obtain. A password-protected file only helps if the password is supplied by a
human or hardware. Therefore the decryption key is bound to the one human
gesture already in the design: signing in.

## Design summary

- The vault starts with no key. No key material is read at boot.
- A random 32-byte data key `K` encrypts route headers.
- `K` is stored wrapped (AES-256-GCM) under a key derived from the admin
  password with a slow KDF. Only the wrapped form is persisted, in `vault_keys`.
- Login derives the KEK, unwraps `K`, and installs it in an in-memory keyring.
  A failed unwrap is a failed login — there is no separate password hash.
- Encryption and decryption go through a wrapper cipher that reads the keyring
  at call time. It does not require restarting the vault.
- While locked, proxy traffic returns `503 vault_locked`. `/health` and
  `/login` still work.
- Locking is implicit on app start and explicit on sign-out. The key never
  touches disk in usable form.

This keeps `app_design.md`'s promise that changing the key makes old headers
unreadable, but the key is now recoverable from the password rather than from
the environment.

## Threat model

Protected against:

- Reading the SQLite database, backups, or a synced project directory.
- Reading the shell environment, `.zshrc`, or process environment.
- Reading any key file on disk — there isn't one.
- Forging a session using a leaked `SECRET_KEY_BASE` (see session binding).
- A stale browser session surviving an app restart.

Not protected against:

- An agent using the proxy through `/r/...` while the vault is unlocked. That
  is the intended feature; decryption isolation does not prevent use.
- An agent that observes the password (keylogger, shoulder surfing, shared
  clipboard).
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
- Wrap — AES-256-GCM with the random IV, AAD `"local_proxy:vault_key:v1"`.
- Store the salt, iterations, IV, and tag inside the envelope. Never store the
  KEK or any password hash.
- A wrong password fails GCM tag verification. Compare in constant time by
  relying on the AEAD tag; do not add a separate `==` check.
- The admin username remains `ADMIN_USER` in the environment. It is not secret.

The DB, not a file, is deliberate: a DB backup then contains everything needed
to restore, given the password. Losing the password means existing headers are
unrecoverable, identical to losing `CLOAK_KEY` today.

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
- `:persistent_term` is chosen for read performance; a GenServer or ETS would
  also work. None of them are a boundary against code running inside the VM.
- Do not log the key, the KEK, the password, or the envelope.

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
      {:ok, key} -> GCM.decrypt(ciphertext, Keyword.put(opts, :key, key))
      :locked -> :error
    end
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
- `LockedError` is a small exception module. Cloak's `encrypt!/1` expects an
  exception tuple, so return `{:error, LockedError.exception([])}` rather than
  bare `:error` from `encrypt/2`.
- `decrypt/2` returning `:error` is valid for the cipher but propagates as
  `:error` from `Cloak.Vault.decrypt/1`; every caller must gate on
  `KeyRing.locked?/0` before touching headers.

## Login and unlock flow

1. `GET /login` renders the form. If `vault_keys` has no row, render a setup
   notice instead: run `mix local_proxy.set_password`. Do not allow first-run
   setup over HTTP; an agent could claim the password before the human does.
2. `POST /login` checks the username against `ADMIN_USER` with
   `Plug.Crypto.secure_compare/2`.
3. Load the singleton `vault_keys` row, derive the KEK, and attempt to unwrap
   `K`. This happens on *every* successful login, even if the vault is already
   unlocked. It is the password check.
4. On unwrap success, call `KeyRing.unlock(K)`, which returns a random
   `generation`.
5. Renew the session, store `:admin_authenticated` and
   `:unlock_generation`, then redirect.
6. On unwrap failure, return 401 with the generic invalid-credentials message.
   Do not distinguish unknown user from bad password.

Verifying the unwrap on every login matters. It means a tampered admin hash or
a forged cookie cannot mint a session while the vault is unlocked. The only
password that produces a session is the one that wrapped the stored key.

### Session binding

Sessions are signed with `SECRET_KEY_BASE`, which may itself be readable from
the environment. Bind each session to the unlock generation:

- `RequireAuth` requires `:admin_authenticated` **and** that
  `get_session(:unlock_generation)` equals `KeyRing.generation/0`.
- If the vault is locked or the generation differs, drop the session, set a
  flash, and redirect to `/login`.
- LiveView mounts must apply the same check. A socket that outlives a lock
  should be disconnected or redirected. Broadcast a `:vault_locked` event on
  `LocalProxy.PubSub` from `KeyRing.lock/0` and handle it in LiveViews.
- This also invalidates sessions after an app restart, which is correct: the
  vault is locked even though the cookie is still cryptographically valid.

### Sign-out and idle lock

- `POST /logout` drops the session **and** calls `KeyRing.lock/0`. Signing out
  therefore stops the proxy until the next sign-in. This is the secure default.
- A separate "Lock now" button is optional sugar for the same action.
- Optional: an idle timeout (`UNLOCK_TTL_MINUTES`, default off) that calls
  `KeyRing.lock/0` after N minutes without an authenticated request. Out of
  scope for the first cut.

## Locked behaviour

- Outbound `match /r/...` and the inbound catch-all return
  `503 {"error":"vault_locked","status":503}` before route lookup. Route
  selection itself is cheap, but gating first avoids touching encrypted
  columns and makes the state obvious.
- `/health` stays unauthenticated and `200`. Add `"vault":"locked"` or
  `"vault":"unlocked"` to the payload so scripts can wait for unlock.
- `/login`, `/routes`, and `/admin` require a session as today. While locked,
  there is no valid session because `RequireAuth` also checks the generation.
- The inbound listener serves the same 503. Consequence: after every BEAM
  start, the Cloudflare tunnel returns 503 until a human signs in. This is
  accepted. It is the cost of never reading a key at boot.
- Optional refinement: allow routes with empty headers to forward while
  locked. Not worth the extra branching for the first cut.

## First run, rotation, migration

Add a small set of mix tasks. All password prompts disable terminal echo
(`stty -echo`) and never accept the password as a CLI argument or env var.

- `mix local_proxy.set_password`
  - If no `vault_keys` row: generate `K`, prompt for a new password twice,
    write the envelope.
  - If a row exists: prompt for the current password, unwrap `K`, prompt for a
    new password, rewrap and update in one transaction.
  - Enforce a minimum length (12+ characters). The KDF is the only defence if
    the DB leaks, so weak passwords are the weak point.
- `mix local_proxy.adopt_key`
  - Migration path for an existing install. Prompt for the current
    base64 `CLOAK_KEY` and a password, wrap that key, write the row. Afterwards
    remove `CLOAK_KEY` from the environment and restart.
- `mix local_proxy.reset_vault`
  - Destructive. Requires typed confirmation. Deletes the `vault_keys` row and
    clears every route's headers. Headers created afterward use a new `K`.
    Never silently regenerate when the envelope fails to unwrap.

Boot order stays `KeyRing` (stateless) → `Vault` → `Repo`. The vault no longer
needs a key to start, so `lib/local_proxy/application.ex:12` can stay where it
is.

### Optional `CLOAK_KEY` override

For CI and headless runs, keep `CLOAK_KEY` as a deprecated escape hatch: if set
and valid, unlock `KeyRing` at boot. The UI still requires the password and the
wrapped row. An install running this way is not protected from environment
reads, which is exactly why it is opt-in and documented as such. The default is
no `CLOAK_KEY`.

`ADMIN_PASSWORD` is removed entirely. `ADMIN_USER` stays. `SECRET_KEY_BASE`
stays for cookie signing.

## Configuration changes

Remove from the required list in `planning/app_design.md`:

- `CLOAK_KEY` — replaced by the wrapped key and sign-in unlock.
- `ADMIN_PASSWORD` — replaced by the password that wraps the key.

Keep:

- `ADMIN_USER`
- `INBOUND_PROXY_KEY` (still an environment secret; see Open questions)
- `SECRET_KEY_BASE`, `DATABASE_PATH` (prod only)
- Ports, timeout, body limit

New optional:

- `UNLOCK_TTL_MINUTES` — idle lock, default off.
- `CLOAK_KEY` — deprecated override, default unset.

`config/runtime.exs:62-77` shrinks to reading `ADMIN_USER`,
`INBOUND_PROXY_KEY`, and the optional `CLOAK_KEY`.

## Data model additions

`LocalProxy.Vault.Key` — an Ash resource in its own domain, kept out of
AshAdmin.

- `id` — string primary key, `"default"`.
- `wrapped` — binary, `allow_nil?: false`.
- `inserted_at`, `updated_at`.
- Actions: `read`, `upsert`. No UI, no policies; single-user tool.
- Migration creates the table with a check or a fixed PK so only one row can
  exist.

Do not add a password hash column. The AEAD tag is the verifier.

## Error responses

Add to the proxy error list in `planning/app_design.md`:

- `503` `{"error":"vault_locked","status":503}`

No route, target, or timing information is included while locked.

## Testing

Vault and envelope:

- Locked `encrypt/2` returns a `LockedError`; locked `decrypt/2` returns
  `:error`.
- `can_decrypt?/2` still identifies `"AES.GCM.V1"` ciphertext while locked.
- Unlock installs the key; encrypt/decrypt round-trip.
- Wrong password fails unwrap and leaves the vault locked.
- Tampered envelope (salt, IV, tag, ciphertext) fails unwrap.
- Envelope version byte is rejected when unknown.
- Ciphertext produced by the old `AES.GCM` configuration decrypts through the
  wrapper with the same tag and `iv_length: 12`.
- The raw key is never present in the `vault_keys` row.

Login and sessions:

- Login with the correct password unlocks and sets the generation.
- Login with a wrong password returns 401 and does not unlock.
- Login while already unlocked still verifies the unwrap.
- A session with a stale or missing generation is redirected to `/login`.
- A valid cookie from before an app restart is rejected while locked.
- Logout drops the session and locks the vault.
- `RequireAuth` is applied to `/routes` and `/admin`; LiveView mounts check the
  generation too.

Proxy:

- `/r/...` and the inbound catch-all return 503 while locked, without touching
  the target.
- They work after unlock.
- `/health` returns 200 and reports `locked` before sign-in.

Mix tasks:

- `set_password` creates the row on first run and rewraps on rotation.
- `adopt_key` wraps a supplied base64 key and the resulting vault decrypts
  existing fixtures.
- `reset_vault` clears headers and the row.

## Deltas to `planning/app_design.md`

- Decisions: replace "Secrets fail fast at boot" with "the vault is locked at
  boot and unlocks on sign-in". Add the 503 state.
- Modules: add `LocalProxy.Vault.KeyRing`, `LocalProxy.Vault.Cipher`,
  `LocalProxy.Vault.Key`, and the three mix tasks.
- Encryption: replace the `CLOAK_KEY` paragraph with the envelope and wrapper
  design above. Note the unchanged `"AES.GCM.V1"` / `iv_length: 12` format.
- Configuration: drop `CLOAK_KEY` and `ADMIN_PASSWORD` from required secrets;
  `ADMIN_USER` remains.
- Request flow: gate both directions on `KeyRing.locked?/0` before route
  lookup.
- Error responses: add `503 vault_locked`.
- Security notes: replace "changing `CLOAK_KEY`" with "losing the password".
  Add the threat-model section from this document.
- Testing: add the vault, envelope, session, and locked-proxy cases.
- Build phases: add Phase 4 — vault hardening, after the current three.
- README: document `mix local_proxy.set_password` as a required first-run step,
  the unlock-on-login workflow, the 503 window after restarts, and how to adopt
  an existing `CLOAK_KEY`.

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

- Should `INBOUND_PROXY_KEY` also move behind the sign-in unlock? An agent can
  read it today and call the inbound listener directly on loopback, which lets
  it reach local services. It does not expose injected headers, but it may be
  worth deriving it from the same password.
- Should signing out really stop the proxy, or should logout end the session
  while a separate "Lock" action wipes the key? Locking on sign-out is safer;
  it is also surprising for local apps. Default to lock, revisit if noisy.
- Idle lock default: off, or something like eight hours?
- Do we want a per-route "sensitive" flag that forces re-authentication before
  the test button or reveal? Not needed for the stated threat model, since
  those actions already require a session and a session now requires the
  password.
