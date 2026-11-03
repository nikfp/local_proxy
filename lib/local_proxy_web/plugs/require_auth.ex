defmodule LocalProxyWeb.Plugs.RequireAuth do
  @moduledoc """
  Redirects unauthenticated or stale browser requests to the sign-in page.
  """

  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2, put_flash: 3]

  alias LocalProxy.Vault.KeyRing

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if authenticated?(conn) do
      conn
    else
      conn
      |> clear_session()
      |> put_session(:return_to, return_to(conn))
      |> put_flash(:error, "Sign in to continue.")
      |> redirect(to: "/login")
      |> halt()
    end
  end

  defp authenticated?(conn) do
    session_generation = get_session(conn, :unlock_generation)

    get_session(conn, :admin_authenticated) == true and
      match?({:ok, ^session_generation}, KeyRing.generation())
  end

  defp return_to(conn) do
    case conn.query_string do
      "" -> conn.request_path
      query -> conn.request_path <> "?" <> query
    end
  end
end
