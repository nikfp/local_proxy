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
    plug :fetch_flash
    plug :fetch_live_flash
    plug :put_root_layout, html: {LocalProxyWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :require_auth do
    plug LocalProxyWeb.Plugs.RequireAuth
  end

  pipeline :vault_gate do
    plug LocalProxyWeb.Plugs.VaultGate
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
    get "/login", SessionController, :new
    post "/login", SessionController, :create
    post "/logout", SessionController, :delete
  end

  scope "/", LocalProxyWeb do
    pipe_through [:browser, :require_auth]

    live "/routes", RouteLive.Index, :index
    live "/routes/new", RouteLive.Form, :new
    live "/routes/:id/edit", RouteLive.Form, :edit
  end

  scope "/", LocalProxyWeb do
    pipe_through :vault_gate

    match :*, "/r/:slug", ProxyController, :outbound
    match :*, "/r/:slug/*rest", ProxyController, :outbound
  end

  scope "/" do
    pipe_through [:browser, :require_auth]

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
end
