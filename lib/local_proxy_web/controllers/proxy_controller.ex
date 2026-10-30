defmodule LocalProxyWeb.ProxyController do
  @moduledoc """
  Entry point for outbound proxy requests (`/r/:slug/...`).
  """

  use LocalProxyWeb, :controller

  alias LocalProxy.Proxy
  alias LocalProxy.Proxy.Request
  alias LocalProxy.Routing
  alias LocalProxy.Routing.Route

  @disallowed_methods ~w(CONNECT TRACE)
  @allowed_methods "GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS"

  def outbound(conn, %{"slug" => slug} = params) do
    cond do
      conn.method in @disallowed_methods ->
        conn
        |> put_resp_header("allow", @allowed_methods)
        |> error(405, "method_not_allowed")

      true ->
        case outbound_route(slug) do
          nil ->
            error(conn, 404, "no_route")

          %Route{} = route ->
            read_body_and_forward(conn, route, params)
        end
    end
  end

  defp outbound_route(slug) do
    case Routing.get_route_by_slug(slug) do
      {:ok, %Route{direction: :outbound, enabled: true} = route} -> route
      %Route{direction: :outbound, enabled: true} = route -> route
      _ -> nil
    end
  end

  defp read_body_and_forward(conn, route, params) do
    case read_request_body(conn) do
      {:ok, body, conn} ->
        request = %Request{
          method: conn.method,
          path: suffix_path(params),
          query: conn.query_string,
          headers: conn.req_headers,
          body: body
        }

        conn
        |> respond(route, Proxy.forward(route, request))

      {:error, :too_large, conn} ->
        error(conn, 413, "request_too_large", route)

      {:error, :read_error, conn} ->
        error(conn, 500, "proxy_error", route)
    end
  end

  defp read_request_body(conn) do
    max_body_bytes = Application.get_env(:local_proxy, :proxy, [])[:max_body_bytes] || 10_485_760

    case Plug.Conn.read_body(conn, length: max_body_bytes + 1) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, conn} -> {:error, :too_large, conn}
      {:error, _reason} -> {:error, :read_error, conn}
    end
  end

  defp suffix_path(%{"rest" => rest}) when is_list(rest) do
    case Enum.reject(rest, &(&1 == "")) do
      [] -> "/"
      segments -> "/" <> Enum.join(segments, "/")
    end
  end

  defp suffix_path(_params), do: "/"

  defp respond(conn, _route, {:ok, %Proxy.Result{} = result}) do
    conn =
      Enum.reduce(result.headers, conn, fn {name, value}, conn ->
        safe_put_resp_header(conn, name, value)
      end)

    send_resp(conn, result.status, result.body)
  end

  defp respond(conn, route, {:error, reason, _duration_ms}) do
    {status, error} =
      case reason do
        :upstream_timeout -> {504, "upstream_timeout"}
        :upstream_unreachable -> {502, "upstream_unreachable"}
        :upstream_response_too_large -> {502, "upstream_response_too_large"}
        :proxy_error -> {500, "proxy_error"}
      end

    error(conn, status, error, route)
  end

  defp safe_put_resp_header(conn, name, value) do
    put_resp_header(conn, name, value)
  rescue
    ArgumentError -> conn
  end

  defp error(conn, status, error, route \\ nil) do
    body =
      %{"error" => error, "status" => status}
      |> maybe_put_route(route)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp maybe_put_route(body, nil), do: body

  defp maybe_put_route(body, %Route{slug: slug}) when is_binary(slug),
    do: Map.put(body, "route", slug)

  defp maybe_put_route(body, %Route{path_prefix: prefix}), do: Map.put(body, "route", prefix)
end
