defmodule LocalProxyWeb.SessionController do
  @moduledoc false

  use LocalProxyWeb, :controller

  alias LocalProxy.Vault.KeyRing
  alias LocalProxy.Vault.KeyStore
  alias LocalProxy.Vault.LoginLimiter

  def new(conn, _params) do
    if authenticated?(conn) do
      redirect(conn, to: ~p"/routes")
    else
      conn
      |> maybe_drop_stale_session()
      |> render(:new,
        error: nil,
        setup: not KeyStore.configured?(),
        csrf_token: Plug.CSRFProtection.get_csrf_token()
      )
    end
  end

  def create(conn, %{"session" => %{"username" => username, "password" => password}}) do
    source = source(conn)

    if LoginLimiter.allowed?(source) do
      sign_in(conn, source, username, password)
    else
      conn
      |> put_resp_header("retry-after", "60")
      |> put_status(:too_many_requests)
      |> render(:new,
        error: "Too many sign-in attempts. Wait a minute and try again.",
        setup: false,
        csrf_token: Plug.CSRFProtection.get_csrf_token()
      )
    end
  end

  def delete(conn, _params) do
    KeyRing.lock()

    conn
    |> configure_session(drop: true)
    |> redirect(to: ~p"/login")
  end

  defp sign_in(conn, source, username, password) do
    with true <- username_valid?(username),
         {:ok, key} <- KeyStore.unwrap(password),
         {:ok, generation} <- KeyRing.unlock(key) do
      LoginLimiter.reset(source)
      return_to = safe_return_to(get_session(conn, :return_to))

      conn
      |> configure_session(renew: true)
      |> put_session(:admin_authenticated, true)
      |> put_session(:unlock_generation, generation)
      |> delete_session(:return_to)
      |> put_flash(:info, "Signed in.")
      |> redirect(to: return_to)
    else
      _ ->
        LoginLimiter.record_failure(source)

        conn
        |> put_status(:unauthorized)
        |> render(:new,
          error: "Invalid username or password.",
          setup: false,
          csrf_token: Plug.CSRFProtection.get_csrf_token()
        )
    end
  end

  defp username_valid?(username) when is_binary(username) do
    expected =
      :local_proxy
      |> Application.get_env(:admin, [])
      |> Keyword.get(:user, "admin")

    secure_equal?(username, expected)
  end

  defp username_valid?(_username), do: false

  defp authenticated?(conn) do
    session_generation = get_session(conn, :unlock_generation)

    get_session(conn, :admin_authenticated) == true and
      match?({:ok, ^session_generation}, KeyRing.generation())
  end

  defp maybe_drop_stale_session(conn) do
    if get_session(conn, :admin_authenticated) do
      configure_session(conn, drop: true)
    else
      conn
    end
  end

  defp secure_equal?(given, expected)
       when is_binary(given) and is_binary(expected) and byte_size(given) == byte_size(expected) do
    Plug.Crypto.secure_compare(given, expected)
  end

  defp secure_equal?(_given, _expected), do: false

  defp source(conn) do
    conn.remote_ip
    |> :inet.ntoa()
    |> to_string()
  rescue
    _ -> "unknown"
  end

  defp safe_return_to(path) when is_binary(path) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//") do
      path
    else
      ~p"/routes"
    end
  end

  defp safe_return_to(_path), do: ~p"/routes"
end
