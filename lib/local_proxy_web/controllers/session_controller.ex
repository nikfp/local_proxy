defmodule LocalProxyWeb.SessionController do
  @moduledoc false

  use LocalProxyWeb, :controller

  def new(conn, _params) do
    if get_session(conn, :admin_authenticated) do
      redirect(conn, to: ~p"/routes")
    else
      render(conn, :new,
        error: nil,
        csrf_token: Plug.CSRFProtection.get_csrf_token()
      )
    end
  end

  def create(conn, %{"session" => %{"username" => username, "password" => password}}) do
    if valid_credentials?(username, password) do
      return_to = safe_return_to(get_session(conn, :return_to))

      conn
      |> configure_session(renew: true)
      |> put_session(:admin_authenticated, true)
      |> delete_session(:return_to)
      |> put_flash(:info, "Signed in.")
      |> redirect(to: return_to)
    else
      conn
      |> put_status(:unauthorized)
      |> render(:new,
        error: "Invalid username or password.",
        csrf_token: Plug.CSRFProtection.get_csrf_token()
      )
    end
  end

  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: ~p"/login")
  end

  defp valid_credentials?(username, password) do
    credentials =
      :local_proxy
      |> Application.fetch_env!(:admin)
      |> Map.new()

    secure_equal?(username, credentials.user) and
      secure_equal?(password, credentials.password)
  end

  defp secure_equal?(given, expected)
       when is_binary(given) and is_binary(expected) and byte_size(given) == byte_size(expected) do
    Plug.Crypto.secure_compare(given, expected)
  end

  defp secure_equal?(_given, _expected), do: false

  defp safe_return_to(path) when is_binary(path) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//") do
      path
    else
      ~p"/routes"
    end
  end

  defp safe_return_to(_path), do: ~p"/routes"
end
