defmodule LocalProxyWeb.HealthControllerTest do
  use LocalProxyWeb.ConnCase

  test "GET /health is unauthenticated", %{conn: conn} do
    conn = get(conn, ~p"/health")
    assert response(conn, 200) == ~s({"status":"ok"})
    assert response_content_type(conn, :json)
  end
end
