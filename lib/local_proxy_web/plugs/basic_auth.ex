defmodule LocalProxyWeb.Plugs.BasicAuth do
  @moduledoc """
  HTTP basic auth for the route configuration UI and AshAdmin.

  Credentials come from the application environment, populated by
  `config/runtime.exs` from `ADMIN_USER` and `ADMIN_PASSWORD`.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    %{user: expected_user, password: expected_password} = credentials()

    with {user, password} <- Plug.BasicAuth.parse_basic_auth(conn),
         true <- secure_equal?(user, expected_user),
         true <- secure_equal?(password, expected_password) do
      conn
    else
      _ ->
        conn
        |> Plug.BasicAuth.request_basic_auth()
        |> halt()
    end
  end

  defp credentials do
    :local_proxy
    |> Application.fetch_env!(:admin)
    |> Map.new()
  end

  defp secure_equal?(given, expected)
       when is_binary(given) and is_binary(expected) and byte_size(given) == byte_size(expected) do
    Plug.Crypto.secure_compare(given, expected)
  end

  defp secure_equal?(_given, _expected), do: false
end
