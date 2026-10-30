defmodule LocalProxyWeb.Plugs.InboundAuth do
  @moduledoc """
  Checks the shared `X-Proxy-Key` on inbound tunnel requests.

  Runs before route lookup, so a bad key never reaches a target. Returns JSON
  and deliberately omits `WWW-Authenticate`: this is an API key, not a browser
  login prompt.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    expected = Application.fetch_env!(:local_proxy, :inbound_proxy_key)
    given = conn |> get_req_header("x-proxy-key") |> List.first()

    if secure_equal?(given, expected) do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(401, Jason.encode!(%{"error" => "unauthorized", "status" => 401}))
      |> halt()
    end
  end

  defp secure_equal?(given, expected)
       when is_binary(given) and is_binary(expected) and byte_size(given) == byte_size(expected) do
    Plug.Crypto.secure_compare(given, expected)
  end

  defp secure_equal?(_given, _expected), do: false
end
