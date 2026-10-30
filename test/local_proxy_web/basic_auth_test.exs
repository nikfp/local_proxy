defmodule LocalProxyWeb.BasicAuthTest do
  use LocalProxyWeb.ConnCase

  defp authorize(conn) do
    put_req_header(conn, "authorization", "Basic " <> Base.encode64("admin:password"))
  end

  test "route UI requires basic auth", %{conn: conn} do
    conn = get(conn, ~p"/routes")
    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") != []
  end

  test "route UI renders with valid credentials", %{conn: conn} do
    conn = conn |> authorize() |> get(~p"/routes")
    assert html_response(conn, 200) =~ "Routes"
  end

  test "rejects wrong credentials", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Basic " <> Base.encode64("admin:nope"))
      |> get(~p"/routes")

    assert conn.status == 401
  end

  test "admin requires basic auth", %{conn: conn} do
    conn = get(conn, "/admin")
    assert conn.status == 401
  end

  test "admin renders with valid credentials", %{conn: conn} do
    conn = conn |> authorize() |> get("/admin")
    assert html_response(conn, 200) =~ "Local Proxy Admin"
  end
end
