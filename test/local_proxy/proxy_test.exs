defmodule LocalProxy.ProxyTest do
  use ExUnit.Case, async: true

  import Plug.Conn

  alias LocalProxy.Proxy
  alias LocalProxy.Proxy.Request
  alias LocalProxy.Routing.Route

  @stub LocalProxy.ProxyTestStub

  defp route(overrides \\ %{}) do
    struct(
      %Route{
        name: "Example",
        direction: :outbound,
        slug: "example",
        target_url: "https://api.example.com",
        headers: %{},
        enabled: true,
        retries: false
      },
      overrides
    )
  end

  defp request(overrides \\ %{}) do
    struct(%Request{method: "GET", path: "/", query: "", headers: [], body: ""}, overrides)
  end

  defp forward(route, request, opts \\ []) do
    extra = Keyword.get(opts, :req_options, [])
    opts = Keyword.put(opts, :req_options, [plug: {Req.Test, @stub}] ++ extra)
    Proxy.forward(route, request, opts)
  end

  describe "target URL rewriting" do
    test "appends the suffix to the target base path and keeps the query" do
      Req.Test.stub(@stub, fn conn ->
        send_resp(conn, 200, conn.request_path <> "?" <> conn.query_string)
      end)

      route = route(%{target_url: "https://api.example.com/v1"})
      request = request(%{path: "/users/1", query: "x=2"})

      assert {:ok, result} = forward(route, request)
      assert result.body == "/v1/users/1?x=2"
    end

    test "an empty suffix becomes a trailing slash" do
      Req.Test.stub(@stub, fn conn -> send_resp(conn, 200, conn.request_path) end)

      assert {:ok, result} = forward(route(%{target_url: "https://api.example.com"}), request())
      assert result.body == "/"

      assert {:ok, result} =
               forward(route(%{target_url: "https://api.example.com/v1"}), request())

      assert result.body == "/v1/"
    end
  end

  describe "header merging" do
    test "route headers override caller headers and hop-by-hop headers are dropped" do
      Req.Test.stub(@stub, fn conn ->
        body =
          Jason.encode!(%{
            api_key: get_req_header(conn, "x-api-key"),
            keep: get_req_header(conn, "x-keep"),
            dropped: get_req_header(conn, "x-drop"),
            connection: get_req_header(conn, "connection"),
            host: conn.host
          })

        send_resp(conn, 200, body)
      end)

      route = route(%{headers: %{"x-api-key" => "from-route"}})

      request =
        request(%{
          headers: [
            {"x-api-key", "from-caller"},
            {"x-keep", "yes"},
            {"x-drop", "no"},
            {"connection", "x-drop"},
            {"accept-encoding", "gzip"}
          ]
        })

      assert {:ok, result} = forward(route, request)
      body = Jason.decode!(result.body)

      assert body["api_key"] == ["from-route"]
      assert body["keep"] == ["yes"]
      assert body["dropped"] == []
      assert body["connection"] == []
      assert body["host"] == "api.example.com"
    end
  end

  describe "request bodies" do
    test "forwards the method and body" do
      Req.Test.stub(@stub, fn conn ->
        {:ok, body, conn} = read_body(conn)
        send_resp(conn, 200, conn.method <> ":" <> body)
      end)

      assert {:ok, result} = forward(route(), request(%{method: "POST", body: "payload"}))
      assert result.body == "POST:payload"
    end
  end

  describe "retries" do
    test "retries are off by default" do
      counter = start_supervised!(%{id: :counter, start: {Agent, :start_link, [fn -> 0 end]}})

      Req.Test.stub(@stub, fn conn ->
        Agent.update(counter, &(&1 + 1))
        send_resp(conn, 500, "nope")
      end)

      assert {:ok, result} = forward(route(), request())
      assert result.status == 500
      assert Agent.get(counter, & &1) == 1
    end

    test "retries a safe request when enabled" do
      counter = start_supervised!(%{id: :counter, start: {Agent, :start_link, [fn -> 0 end]}})
      route = route(%{retries: true})

      Req.Test.stub(@stub, fn conn ->
        count = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)

        if count == 1 do
          send_resp(conn, 500, "nope")
        else
          send_resp(conn, 200, "ok")
        end
      end)

      assert {:ok, result} = forward(route, request(), req_options: [retry_delay: fn _ -> 0 end])
      assert result.status == 200
      assert Agent.get(counter, & &1) == 2
    end

    test "does not retry POST even when enabled" do
      counter = start_supervised!(%{id: :counter, start: {Agent, :start_link, [fn -> 0 end]}})
      route = route(%{retries: true})

      Req.Test.stub(@stub, fn conn ->
        Agent.update(counter, &(&1 + 1))
        send_resp(conn, 500, "nope")
      end)

      assert {:ok, result} = forward(route, request(%{method: "POST"}))
      assert result.status == 500
      assert Agent.get(counter, & &1) == 1
    end
  end

  describe "redirects" do
    test "follows redirects and returns the final response" do
      Req.Test.stub(@stub, fn conn ->
        case conn.request_path do
          "/start" -> conn |> put_resp_header("location", "/final") |> send_resp(302, "")
          "/final" -> send_resp(conn, 200, "done")
        end
      end)

      assert {:ok, result} = forward(route(), request(%{path: "/start"}))
      assert result.status == 200
      assert result.body == "done"
    end
  end

  describe "response bodies" do
    test "passes gzip through untouched" do
      gzipped = :zlib.gzip("hello")

      Req.Test.stub(@stub, fn conn ->
        conn
        |> put_resp_header("content-encoding", "gzip")
        |> send_resp(200, gzipped)
      end)

      assert {:ok, result} = forward(route(), request())
      assert result.body == gzipped
      assert {"content-encoding", "gzip"} in result.headers
    end

    test "returns an error when the response exceeds the cap" do
      Req.Test.stub(@stub, fn conn -> send_resp(conn, 200, String.duplicate("a", 50)) end)

      assert {:error, :upstream_response_too_large, _duration} =
               forward(route(), request(), max_body_bytes: 10)
    end
  end

  describe "errors" do
    test "maps timeouts to upstream_timeout" do
      Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, :upstream_timeout, _duration} = forward(route(), request())
    end

    test "maps refused connections to upstream_unreachable" do
      Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, :upstream_unreachable, _duration} = forward(route(), request())
    end

    test "maps unexpected exceptions to proxy_error" do
      Req.Test.stub(@stub, fn _conn -> raise "boom" end)

      assert {:error, :proxy_error, _duration} = forward(route(), request())
    end
  end
end
