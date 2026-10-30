defmodule LocalProxyWeb.InboundRouter do
  @moduledoc """
  Router for the tunnel-facing listener.

  Only an unauthenticated health check and the authenticated inbound catch-all
  are exposed here. UI, admin, and outbound `/r` routes are not present.
  """

  use LocalProxyWeb, :router

  import Phoenix.Router

  pipeline :inbound_auth do
    plug LocalProxyWeb.Plugs.InboundAuth
  end

  scope "/" do
    get "/health", LocalProxyWeb.HealthController, :show
  end

  scope "/", LocalProxyWeb do
    pipe_through :inbound_auth

    match :*, "/*path", ProxyController, :inbound
  end
end
