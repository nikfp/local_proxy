defmodule LocalProxyWeb.HealthControllerTest do
  use LocalProxyWeb.ConnCase

  test "GET /health is unauthenticated", %{conn: conn} do
    conn = get(conn, ~p"/health")
    assert json_response(conn, 200) == %{"status" => "ok", "vault" => "unlocked"}
    assert response_content_type(conn, :json)
  end

  test "GET /health reports a locked vault", %{conn: conn} do
    LocalProxy.VaultTestHelpers.lock()

    conn = get(conn, ~p"/health")
    assert json_response(conn, 200) == %{"status" => "ok", "vault" => "locked"}
  end
end
