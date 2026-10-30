defmodule LocalProxyWeb.InboundEndpoint do
  @moduledoc """
  Listener exposed to the Cloudflare tunnel.

  It only serves the inbound proxy and a health check. Route management,
  AshAdmin, and outbound `/r` routes live on `LocalProxyWeb.Endpoint`.
  """

  use Phoenix.Endpoint, otp_app: :local_proxy

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
  plug LocalProxyWeb.InboundRouter
end
