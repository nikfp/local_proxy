defmodule LocalProxyWeb.Router do
  use LocalProxyWeb, :router

  import Phoenix.Router

  pipeline :browser do
    plug :accepts, ["html"]

    plug Plug.Parsers,
      parsers: [:urlencoded, :multipart, :json],
      pass: ["*/*"],
      json_decoder: Phoenix.json_library()

    plug Plug.MethodOverride
    plug Plug.Head
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LocalProxyWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :admin_auth do
    plug LocalProxyWeb.Plugs.BasicAuth
  end

  pipeline :inbound_auth do
    plug LocalProxyWeb.Plugs.InboundAuth
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/" do
    get "/health", LocalProxyWeb.HealthController, :show
  end

  scope "/", LocalProxyWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/", LocalProxyWeb do
    pipe_through [:browser, :admin_auth]

    live "/routes", RouteLive.Index, :index
    live "/routes/new", RouteLive.Form, :new
    live "/routes/:id/edit", RouteLive.Form, :edit
  end

  scope "/", LocalProxyWeb do
    match :*, "/r/:slug", ProxyController, :outbound
    match :*, "/r/:slug/*rest", ProxyController, :outbound
  end

  scope "/" do
    pipe_through [:browser, :admin_auth]

    import AshAdmin.Router
    ash_admin "/admin"
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:local_proxy, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: LocalProxyWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # Inbound catch-all. Keep this last so routes, admin, assets, and LiveView
  # paths above are never proxied.
  scope "/", LocalProxyWeb do
    pipe_through :inbound_auth

    match :*, "/*path", ProxyController, :inbound
  end
end
