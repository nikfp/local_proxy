defmodule LocalProxyWeb.SessionAuthTest do
  use LocalProxyWeb.ConnCase

  alias LocalProxy.Vault.KeyStore

  setup do
    LocalProxy.VaultTestHelpers.unlock()
    LocalProxy.Vault.LoginLimiter.reset("127.0.0.1")
    {:ok, _key} = KeyStore.create("password-123456")
    :ok
  end

  defp login(conn, username \\ "admin", password \\ "password-123456") do
    conn = get(conn, ~p"/login")

    [_, token] =
      Regex.run(~r/name="_csrf_token" value="([^"]+)"/, html_response(conn, 200))

    conn
    |> recycle()
    |> post(~p"/login", %{
      "_csrf_token" => token,
      "session" => %{"username" => username, "password" => password}
    })
  end

  defp authenticated(conn) do
    {:ok, generation} = LocalProxy.Vault.KeyRing.generation()

    init_test_session(conn, %{
      admin_authenticated: true,
      unlock_generation: generation
    })
  end

  test "unauthenticated users are redirected to the sign-in page", %{conn: conn} do
    conn = get(conn, ~p"/routes")

    assert redirected_to(conn) == ~p"/login"
  end

  test "the sign-in page renders", %{conn: conn} do
    conn = get(conn, ~p"/login")
    assert html_response(conn, 200) =~ "Sign in"
  end

  test "wrong credentials are rejected", %{conn: conn} do
    conn = login(conn, "admin", "wrong")
    assert html_response(conn, 401) =~ "Invalid username or password"
  end

  test "valid credentials create a session and continue to the requested page", %{conn: conn} do
    conn = get(conn, ~p"/routes")
    assert redirected_to(conn) == ~p"/login"

    conn =
      conn
      |> recycle()
      |> login()

    assert redirected_to(conn) == ~p"/routes"

    conn = get(conn, ~p"/routes")
    assert html_response(conn, 200) =~ "Routes"
  end

  test "a successful login stores the unlock generation", %{conn: conn} do
    conn = login(conn)

    assert get_session(conn, :admin_authenticated) == true
    assert is_binary(get_session(conn, :unlock_generation))
  end

  test "five failed logins cause the next attempt to be rate limited", %{conn: conn} do
    for _ <- 1..5 do
      conn = login(conn, "admin", "wrong-password")
      assert html_response(conn, 401) =~ "Invalid username or password"
    end

    conn = login(conn, "admin", "password-123456")
    assert html_response(conn, 429) =~ "Too many sign-in attempts"
  end

  test "a session with a stale generation is redirected to login", %{conn: conn} do
    conn = authenticated(conn)
    LocalProxy.VaultTestHelpers.unlock()

    conn = get(conn, ~p"/routes")
    assert redirected_to(conn) == ~p"/login"
  end

  test "a stale session does not loop on the login page", %{conn: conn} do
    conn = authenticated(conn)
    LocalProxy.VaultTestHelpers.unlock()

    conn = get(conn, ~p"/login")
    assert html_response(conn, 200) =~ "Sign in"
  end

  test "admin requires a session", %{conn: conn} do
    conn = get(conn, "/admin")
    assert redirected_to(conn) == ~p"/login"

    conn = conn |> recycle() |> authenticated() |> get("/admin")
    assert html_response(conn, 200) =~ "Local Proxy Admin"
  end

  test "logout clears the session", %{conn: conn} do
    conn = authenticated(conn)
    conn = post(conn, ~p"/logout")

    assert redirected_to(conn) == ~p"/login"

    conn = get(conn, ~p"/routes")
    assert redirected_to(conn) == ~p"/login"
  end
end
