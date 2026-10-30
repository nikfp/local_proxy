defmodule LocalProxyWeb.ProxyControllerTest do
  use LocalProxyWeb.ConnCase, async: false

  alias LocalProxy.Routing

  @stub LocalProxy.ProxyControllerTestStub

  defp create_route(attrs \\ %{}) do
    Routing.create_route!(
      Map.merge(
        %{
          name: "GitHub",
          direction: :outbound,
          slug: "github",
          target_url: "https://api.example.com",
          headers: %{}
        },
        attrs
      )
    )
  end

  defp stub(plug), do: Req.Test.stub(@stub, plug)

  defp set_proxy_config(values) do
    previous = Application.get_env(:local_proxy, :proxy, [])

    Application.put_env(
      :local_proxy,
      :proxy,
      Keyword.merge(previous, values ++ [req_options: [plug: {Req.Test, @stub}]])
    )

    on_exit(fn -> Application.put_env(:local_proxy, :proxy, previous) end)
  end

  test "forwards methods, bodies, paths, and queries", %{conn: conn} do
    create_route(%{headers: %{"X-Api-Key" => "secret"}})

    stub(fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send_resp(
        conn,
        200,
        Jason.encode!(%{
          method: conn.method,
          path: conn.request_path,
          query: conn.query_string,
          body: body,
          key: Plug.Conn.get_req_header(conn, "x-api-key")
        })
      )
    end)

    # The forwarder picks up the test plug through the proxy config, not
    # through the controller, so make it available here.
    set_proxy_config([])

    conn = put_req_header(conn, "content-type", "text/plain")
    conn = dispatch(conn, @endpoint, "POST", "/r/github/users/1?x=2", "payload")

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "method" => "POST",
             "path" => "/users/1",
             "query" => "x=2",
             "body" => "payload",
             "key" => ["secret"]
           }
  end

  test "missing route returns 404", %{conn: conn} do
    conn = get(conn, "/r/missing")
    assert json_response(conn, 404) == %{"error" => "no_route", "status" => 404}
  end

  test "disabled route returns 404", %{conn: conn} do
    create_route(%{enabled: false})
    conn = get(conn, "/r/github")
    assert json_response(conn, 404) == %{"error" => "no_route", "status" => 404}
  end

  test "inbound routes are not reachable through /r", %{conn: conn} do
    Routing.create_route!(%{
      name: "Local",
      direction: :inbound,
      path_prefix: "/api",
      target_url: "http://localhost:3000"
    })

    conn = get(conn, "/r/api")
    assert json_response(conn, 404) == %{"error" => "no_route", "status" => 404}
  end

  test "CONNECT and TRACE return 405", %{conn: _conn} do
    create_route()

    for method <- ["CONNECT", "TRACE"] do
      conn = dispatch(build_conn(), @endpoint, method, "/r/github")
      assert json_response(conn, 405) == %{"error" => "method_not_allowed", "status" => 405}
    end
  end

  test "request bodies over the limit return 413", %{conn: conn} do
    create_route()
    set_proxy_config(max_body_bytes: 4)

    conn = put_req_header(conn, "content-type", "text/plain")
    conn = dispatch(conn, @endpoint, "POST", "/r/github/echo", "too large")

    assert json_response(conn, 413) == %{
             "error" => "request_too_large",
             "route" => "github",
             "status" => 413
           }
  end

  test "upstream timeout returns 504", %{conn: conn} do
    create_route()
    stub(fn conn -> Req.Test.transport_error(conn, :timeout) end)
    set_proxy_config([])

    conn = get(conn, "/r/github")

    assert json_response(conn, 504) == %{
             "error" => "upstream_timeout",
             "route" => "github",
             "status" => 504
           }
  end

  test "connection refused returns 502", %{conn: conn} do
    create_route()
    stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
    set_proxy_config([])

    conn = get(conn, "/r/github")

    assert json_response(conn, 502) == %{
             "error" => "upstream_unreachable",
             "route" => "github",
             "status" => 502
           }
  end

  test "oversized upstream response returns 502", %{conn: conn} do
    create_route()
    set_proxy_config(max_body_bytes: 4)
    stub(fn conn -> send_resp(conn, 200, "too large") end)
    set_proxy_config([])

    conn = get(conn, "/r/github")

    assert json_response(conn, 502) == %{
             "error" => "upstream_response_too_large",
             "route" => "github",
             "status" => 502
           }
  end

  test "unexpected upstream exceptions return 500", %{conn: conn} do
    create_route()
    stub(fn _conn -> raise "boom" end)
    set_proxy_config([])

    conn = get(conn, "/r/github")

    assert json_response(conn, 500) == %{
             "error" => "proxy_error",
             "route" => "github",
             "status" => 500
           }
  end

  test "upstream response headers pass through", %{conn: conn} do
    create_route()

    stub(fn conn ->
      conn
      |> put_resp_header("content-type", "text/plain")
      |> put_resp_header("x-upstream", "yes")
      |> send_resp(201, "created")
    end)

    set_proxy_config([])

    conn = get(conn, "/r/github")
    assert conn.status == 201
    assert conn.resp_body == "created"
    assert get_resp_header(conn, "x-upstream") == ["yes"]
    assert get_resp_header(conn, "content-type") == ["text/plain"]
  end
end
