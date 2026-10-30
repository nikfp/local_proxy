defmodule LocalProxyWeb.InboundTest do
  use LocalProxyWeb.ConnCase, async: false

  alias LocalProxy.Repo
  alias LocalProxy.Routing

  @stub LocalProxy.InboundTestStub
  @key "test-inbound-key"

  defp create_route(attrs \\ %{}) do
    Routing.create_route!(
      Map.merge(
        %{
          name: "Local API",
          direction: :inbound,
          path_prefix: "/api",
          target_url: "http://127.0.0.1:4567",
          headers: %{}
        },
        attrs
      )
    )
  end

  defp with_upstream(plug) do
    Req.Test.stub(@stub, plug)
    previous = Application.get_env(:local_proxy, :proxy, [])

    Application.put_env(
      :local_proxy,
      :proxy,
      Keyword.put(previous, :req_options, plug: {Req.Test, @stub})
    )

    on_exit(fn -> Application.put_env(:local_proxy, :proxy, previous) end)
  end

  defp inbound_conn do
    build_conn() |> put_req_header("x-proxy-key", @key)
  end

  describe "authentication" do
    test "missing key returns 401 without a browser challenge", %{conn: conn} do
      create_route()

      conn = get(conn, "/api/users")

      assert json_response(conn, 401) == %{"error" => "unauthorized", "status" => 401}
      assert get_resp_header(conn, "www-authenticate") == []
    end

    test "wrong key returns 401", %{conn: conn} do
      create_route()

      conn =
        conn
        |> put_req_header("x-proxy-key", "wrong")
        |> get("/api/users")

      assert json_response(conn, 401) == %{"error" => "unauthorized", "status" => 401}
    end

    test "authentication runs before route lookup", %{conn: conn} do
      conn = get(conn, "/does-not-match-a-route")

      assert json_response(conn, 401) == %{"error" => "unauthorized", "status" => 401}
    end
  end

  describe "route matching" do
    test "no matching prefix returns 404", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-proxy-key", @key)
        |> get("/api/users")

      assert json_response(conn, 404) == %{"error" => "no_route", "status" => 404}
    end

    test "disabled routes are ignored", %{conn: conn} do
      create_route(%{enabled: false})

      conn =
        conn
        |> put_req_header("x-proxy-key", @key)
        |> get("/api/users")

      assert json_response(conn, 404) == %{"error" => "no_route", "status" => 404}
    end

    test "prefix matching is segment-aware", %{conn: conn} do
      create_route()

      conn =
        conn
        |> put_req_header("x-proxy-key", @key)
        |> get("/apix/users")

      assert json_response(conn, 404) == %{"error" => "no_route", "status" => 404}
    end

    test "the longest prefix wins", %{conn: conn} do
      create_route(%{path_prefix: "/api", headers: %{"X-Route" => "short"}})

      create_route(%{
        name: "Local API v1",
        path_prefix: "/api/v1",
        headers: %{"X-Route" => "long"}
      })

      with_upstream(fn upstream_conn ->
        send_resp(
          upstream_conn,
          200,
          upstream_conn |> Plug.Conn.get_req_header("x-route") |> List.first()
        )
      end)

      conn =
        conn
        |> put_req_header("x-proxy-key", @key)
        |> get("/api/v1/things")

      assert response(conn, 200) == "long"
    end
  end

  describe "forwarding" do
    test "strips the prefix, keeps the query, and removes X-Proxy-Key", %{conn: conn} do
      create_route()

      with_upstream(fn upstream_conn ->
        send_resp(
          upstream_conn,
          200,
          Jason.encode!(%{
            path: upstream_conn.request_path,
            query: upstream_conn.query_string,
            key: Plug.Conn.get_req_header(upstream_conn, "x-proxy-key")
          })
        )
      end)

      conn =
        conn
        |> put_req_header("x-proxy-key", @key)
        |> get("/api/users/1?x=2")

      assert conn.status == 200

      assert Jason.decode!(conn.resp_body) == %{
               "path" => "/users/1",
               "query" => "x=2",
               "key" => []
             }
    end

    test "an exact prefix maps to /", %{conn: conn} do
      create_route()

      with_upstream(fn upstream_conn ->
        send_resp(upstream_conn, 200, upstream_conn.request_path)
      end)

      conn =
        conn
        |> put_req_header("x-proxy-key", @key)
        |> get("/api")

      assert response(conn, 200) == "/"
    end

    test "CONNECT and TRACE return 405 after auth", %{conn: _conn} do
      create_route()

      for method <- ["CONNECT", "TRACE"] do
        conn = dispatch(inbound_conn(), @endpoint, method, "/api")

        assert json_response(conn, 405) == %{
                 "error" => "method_not_allowed",
                 "status" => 405
               }
      end
    end
  end

  describe "loopback policy at request time" do
    test "a target that is no longer loopback returns 502", %{conn: conn} do
      route = create_route()

      Repo.query!(
        "update routes set target_url = ? where path_prefix = ?",
        ["http://example.com", route.path_prefix]
      )

      conn =
        conn
        |> put_req_header("x-proxy-key", @key)
        |> get("/api/users")

      assert json_response(conn, 502) == %{
               "error" => "upstream_unreachable",
               "route" => "/api",
               "status" => 502
             }
    end
  end
end
