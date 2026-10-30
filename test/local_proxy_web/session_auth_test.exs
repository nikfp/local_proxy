defmodule LocalProxyWeb.SessionAuthTest do
  use LocalProxyWeb.ConnCase

  defp login(conn, username \\ "admin", password \\ "password") do
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
    init_test_session(conn, %{admin_authenticated: true})
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
