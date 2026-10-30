import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/local_proxy start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :local_proxy, LocalProxyWeb.Endpoint, server: true
end

port = LocalProxy.Config.parse_port!(System.get_env("PORT"))

upstream_timeout_ms =
  LocalProxy.Config.parse_positive_integer!(
    System.get_env("UPSTREAM_TIMEOUT_MS"),
    30_000,
    "UPSTREAM_TIMEOUT_MS"
  )

max_body_bytes =
  LocalProxy.Config.parse_positive_integer!(
    System.get_env("MAX_BODY_BYTES"),
    10_485_760,
    "MAX_BODY_BYTES"
  )

config :local_proxy, LocalProxyWeb.Endpoint, http: [port: port]

config :local_proxy, :proxy,
  upstream_timeout_ms: upstream_timeout_ms,
  max_body_bytes: max_body_bytes

if config_env() != :test do
  config :local_proxy, LocalProxy.Vault,
    key: LocalProxy.Config.decode_cloak_key!(System.get_env("CLOAK_KEY"))

  config :local_proxy, :admin,
    user:
      System.get_env("ADMIN_USER") ||
        raise("environment variable ADMIN_USER is missing"),
    password:
      System.get_env("ADMIN_PASSWORD") ||
        raise("environment variable ADMIN_PASSWORD is missing")

  config :local_proxy,
         :inbound_proxy_key,
         System.get_env("INBOUND_PROXY_KEY") ||
           raise("environment variable INBOUND_PROXY_KEY is missing")
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :local_proxy, LocalProxyWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/local_proxy_web/router\.ex$"E,
        ~r"lib/local_proxy_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/local_proxy/local_proxy.db
      """

  config :local_proxy, LocalProxy.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :local_proxy, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :local_proxy, LocalProxyWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # The proxy has unauthenticated outbound routes, so it must only listen
      # on loopback. Put a tunnel or reverse proxy in front for public access.
      ip: {127, 0, 0, 1}
    ],
    secret_key_base: secret_key_base

  config :ash,
    keyset_signing_secret:
      :crypto.mac(
        :hmac,
        :sha256,
        System.get_env("SECRET_KEY_BASE") ||
          raise("environment variable SECRET_KEY_BASE is missing"),
        "ash keyset signing"
      )

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :local_proxy, LocalProxyWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :local_proxy, LocalProxyWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :local_proxy, LocalProxy.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
