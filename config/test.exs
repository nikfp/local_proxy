import Config

config :ash,
  policies: [show_policy_breakdowns?: true],
  keyset_signing_secret: "snTO7BUE+kBjlknGudP0jca7svw1y9FDV5TVala6bFc",
  disable_async?: true

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :local_proxy, LocalProxy.Repo,
  database: Path.expand("../local_proxy_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :local_proxy, LocalProxyWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "cZPCh2Bzc4rAQhxjdBxRM1i7sDwhi4ab4gd2PkipI+LFp4s+wH7xG2hRQ8Lpx4z8",
  server: false

# In test we don't send emails
config :local_proxy, LocalProxy.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
