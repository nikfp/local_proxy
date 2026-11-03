defmodule LocalProxyWeb.Plugs.InboundAuth do
  @moduledoc """
  Authenticates an inbound tunnel request against the matched route's key.

  Matching happens before the key check so each route can have its own key.
  Unknown paths and bad keys both return 401 to avoid exposing route prefixes.
  """

  @behaviour Plug

  import Plug.Conn

  alias LocalProxy.Routing
  alias LocalProxy.Vault.KeyRing
  alias LocalProxy.Vault.LockedError

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if KeyRing.locked?() do
      locked(conn)
    else
      authenticate(conn)
    end
  rescue
    LockedError -> locked(conn)
  end

  defp authenticate(conn) do
    path = request_path(conn)
    given = conn |> get_req_header("x-proxy-key") |> List.first()

    with %Routing.Route{} = route <- Routing.get_inbound_route(path),
         %Routing.Route{inbound_key: expected} <- Ash.load!(route, :inbound_key, domain: Routing),
         true <- secure_equal?(given, expected) do
      assign(conn, :inbound_route, route)
    else
      _ -> unauthorized(conn)
    end
  end

  defp request_path(conn) do
    case conn.path_info do
      [] -> "/"
      segments -> "/" <> Enum.join(segments, "/")
    end
  end

  defp secure_equal?(given, expected)
       when is_binary(given) and is_binary(expected) and byte_size(given) == byte_size(expected) do
    Plug.Crypto.secure_compare(given, expected)
  end

  defp secure_equal?(_given, _expected), do: false

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{"error" => "unauthorized", "status" => 401}))
    |> halt()
  end

  defp locked(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(503, Jason.encode!(%{"error" => "vault_locked", "status" => 503}))
    |> halt()
  end
end
