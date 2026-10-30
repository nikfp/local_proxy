defmodule LocalProxyWeb.PageControllerTest do
  use LocalProxyWeb.ConnCase

  test "GET / redirects to /routes", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/routes"
  end
end
