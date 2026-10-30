defmodule LocalProxy.Proxy do
  @moduledoc """
  Shared forwarder for both proxy directions.

  The caller resolves the route and reads the request body. This module rewrites
  the target URL, merges headers, calls the upstream with `Req`, enforces limits,
  and maps failures to stable error atoms.
  """

  require Logger

  alias LocalProxy.Proxy.Request
  alias LocalProxy.Proxy.Result
  alias LocalProxy.Routing

  @hop_by_hop ~w(
    connection
    keep-alive
    proxy-authenticate
    proxy-authorization
    te
    trailer
    transfer-encoding
    upgrade
  )

  @request_drop @hop_by_hop ++ ~w(host content-length accept-encoding x-proxy-key)
  @response_drop @hop_by_hop ++ ~w(content-length)

  @default_timeout 30_000
  @default_max_body_bytes 10_485_760

  @type error_reason ::
          :upstream_timeout
          | :upstream_unreachable
          | :upstream_response_too_large
          | :proxy_error

  @doc """
  Forwards a request for `route`.

  Returns `{:ok, result}` for any upstream response, including 4xx and 5xx, and
  `{:error, reason, duration_ms}` when the proxy itself could not complete the
  exchange.

  Options:

    * `:req_options` — extra options merged into the `Req` request. Tests pass
      `plug: {Req.Test, name}` here.
    * `:upstream_timeout_ms` and `:max_body_bytes` — override application config.
  """
  @spec forward(Routing.Route.t(), Request.t(), keyword()) ::
          {:ok, Result.t()} | {:error, error_reason(), non_neg_integer()}
  def forward(%Routing.Route{} = route, %Request{} = request, opts \\ []) do
    started_at = System.monotonic_time(:millisecond)
    url = target_url(route, request.path, request.query)
    headers = merge_headers(request.headers, route_headers(route))

    req_options =
      [
        url: url,
        method: normalize_method(request.method),
        headers: headers,
        receive_timeout: timeout(opts),
        connect_options: [timeout: timeout(opts)],
        retry: if(route.retries, do: :safe_transient, else: false),
        redirect: true,
        max_redirects: 10,
        redirect_trusted: false,
        raw: true,
        into: body_collector(max_body_bytes(opts))
      ] ++ retry_limit(route)

    req =
      req_options
      |> Req.new()
      |> maybe_put_body(request.body)
      |> Req.new((config()[:req_options] || []) ++ (opts[:req_options] || []))

    result =
      try do
        Req.request(req)
      rescue
        exception -> {:raised, exception}
      end

    case result do
      {:ok, %Req.Response{status: status, headers: response_headers, body: body}} ->
        duration_ms = elapsed(started_at)

        case body do
          {:too_large, _partial} ->
            log_error(route, request, :upstream_response_too_large, url)
            {:error, :upstream_response_too_large, duration_ms}

          body ->
            body = if is_binary(body), do: body, else: ""

            log_success(route, request, status, duration_ms)

            {:ok,
             %Result{
               status: status,
               headers: normalize_response_headers(response_headers),
               body: body,
               duration_ms: duration_ms
             }}
        end

      {:error, exception} ->
        duration_ms = elapsed(started_at)
        reason = error_reason(exception)

        log_error(route, request, {reason, exception.__struct__}, url)
        {:error, reason, duration_ms}

      {:raised, exception} ->
        duration_ms = elapsed(started_at)

        log_error(route, request, {:proxy_error, exception.__struct__}, url)
        {:error, :proxy_error, duration_ms}
    end
  end

  @doc """
  Builds the upstream URL from a route target, a suffix path, and a query string.
  """
  def target_url(%Routing.Route{target_url: target_url}, suffix, query) do
    uri = URI.parse(target_url)

    %{uri | path: join_paths(uri.path, suffix), query: blank_to_nil(query)}
    |> URI.to_string()
  end

  @doc """
  Merges caller headers and route headers.

  Hop-by-hop headers, `Host`, `Content-Length`, `Accept-Encoding`, and
  `X-Proxy-Key` are dropped. Route headers override caller headers with the same
  lowercase name.
  """
  def merge_headers(incoming, injected) do
    injected = normalize_injected(injected)
    connection_tokens = connection_tokens(incoming)
    drop = MapSet.new(@request_drop ++ connection_tokens)

    incoming
    |> Enum.reject(fn {name, _value} -> MapSet.member?(drop, downcase(name)) end)
    |> Enum.reject(fn {name, _value} -> Map.has_key?(injected, downcase(name)) end)
    |> Enum.map(fn {name, value} -> {downcase(name), value} end)
    |> Kernel.++(Map.to_list(injected))
  end

  defp route_headers(%Routing.Route{headers: %Ash.NotLoaded{}} = route) do
    route
    |> Ash.load!(:headers, domain: Routing)
    |> Map.fetch!(:headers)
  end

  defp route_headers(%Routing.Route{headers: headers}) when is_map(headers), do: headers
  defp route_headers(_route), do: %{}

  defp normalize_injected(headers) when is_map(headers) do
    Map.new(headers, fn {name, value} -> {downcase(name), value} end)
  end

  defp normalize_injected(_headers), do: %{}

  defp connection_tokens(headers) do
    headers
    |> Enum.filter(fn {name, _value} -> downcase(name) == "connection" end)
    |> Enum.flat_map(fn {_name, value} ->
      value
      |> String.split(",")
      |> Enum.map(&(&1 |> String.trim() |> downcase()))
      |> Enum.reject(&(&1 == ""))
    end)
  end

  defp join_paths(base, suffix) do
    base = String.trim_trailing(base || "", "/")
    suffix = String.trim_leading(suffix || "", "/")

    cond do
      base == "" and suffix == "" -> "/"
      base == "" -> "/" <> suffix
      suffix == "" -> base <> "/"
      true -> base <> "/" <> suffix
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(query), do: query

  defp downcase(name), do: name |> to_string() |> String.downcase()

  defp normalize_method(method) when is_atom(method) do
    method |> Atom.to_string() |> String.downcase() |> method_atom()
  end

  defp normalize_method(method) when is_binary(method),
    do: method |> String.downcase() |> method_atom()

  defp method_atom(method) do
    case method do
      "get" -> :get
      "head" -> :head
      "post" -> :post
      "put" -> :put
      "patch" -> :patch
      "delete" -> :delete
      "options" -> :options
      other -> other
    end
  end

  defp maybe_put_body(req, body) when body in [nil, ""], do: req
  defp maybe_put_body(req, body), do: Req.new(req, body: body)

  defp retry_limit(%Routing.Route{retries: true}), do: [max_retries: 3]
  defp retry_limit(_route), do: []

  defp body_collector(max_bytes) do
    fn {:data, chunk}, {req, response} ->
      body = response.body || ""

      if byte_size(body) + byte_size(chunk) > max_bytes do
        {:halt, {req, %{response | body: {:too_large, body}}}}
      else
        {:cont, {req, %{response | body: body <> chunk}}}
      end
    end
  end

  defp normalize_response_headers(headers) do
    headers
    |> Enum.flat_map(fn {name, values} ->
      values
      |> List.wrap()
      |> Enum.map(fn value -> {downcase(name), value} end)
    end)
    |> Enum.reject(fn {name, _value} -> name in @response_drop end)
  end

  defp error_reason(%Req.TransportError{reason: :timeout}), do: :upstream_timeout

  defp error_reason(%Req.TransportError{}), do: :upstream_unreachable
  defp error_reason(%Req.HTTPError{}), do: :upstream_unreachable
  defp error_reason(_exception), do: :proxy_error

  defp timeout(opts) do
    opts[:upstream_timeout_ms] || config()[:upstream_timeout_ms] || @default_timeout
  end

  defp max_body_bytes(opts) do
    opts[:max_body_bytes] || config()[:max_body_bytes] || @default_max_body_bytes
  end

  defp config, do: Application.get_env(:local_proxy, :proxy, [])

  defp elapsed(started_at), do: System.monotonic_time(:millisecond) - started_at

  defp log_success(route, request, status, duration_ms) do
    Logger.info("proxy request",
      route: route_label(route),
      direction: route.direction,
      method: request.method,
      path: request.path,
      status: status,
      duration_ms: duration_ms
    )
  end

  defp log_error(route, request, error, url) do
    Logger.warning("proxy error",
      route: route_label(route),
      direction: route.direction,
      method: request.method,
      path: request.path,
      error: inspect(error),
      target_host: url |> URI.parse() |> Map.get(:host)
    )
  end

  defp route_label(%Routing.Route{slug: slug}) when is_binary(slug), do: slug
  defp route_label(%Routing.Route{path_prefix: prefix}), do: prefix
end
