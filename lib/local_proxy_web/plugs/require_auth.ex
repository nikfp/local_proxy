defmodule LocalProxyWeb.Plugs.RequireAuth do
  @moduledoc """
  Redirects unauthenticated browser requests to the sign-in page.
  """

  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2, put_flash: 3]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if get_session(conn, :admin_authenticated) do
      conn
    else
      conn
      |> put_session(:return_to, return_to(conn))
      |> put_flash(:error, "Sign in to continue.")
      |> redirect(to: "/login")
      |> halt()
    end
  end

  defp return_to(conn) do
    case conn.query_string do
      "" -> conn.request_path
      query -> conn.request_path <> "?" <> query
    end
  end
end
