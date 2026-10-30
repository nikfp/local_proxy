defmodule LocalProxyWeb.RouteLive.Index do
  @moduledoc false

  use LocalProxyWeb, :live_view

  alias LocalProxy.Proxy
  alias LocalProxy.Proxy.Request
  alias LocalProxy.Proxy.Result
  alias LocalProxy.Routing

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Routes")
     |> assign(:direction, "all")
     |> assign(:enabled, "all")
     |> assign(:test_results, %{})
     |> assign_routes()}
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:direction, params["direction"] || "all")
     |> assign(:enabled, params["enabled"] || "all")
     |> assign_routes()}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    route = Routing.get_route!(id)

    case Routing.update_route(route, %{enabled: !route.enabled}) do
      {:ok, _route} ->
        {:noreply, assign_routes(socket)}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "Could not update the route.")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    route = Routing.get_route!(id)

    case Routing.destroy_route(route) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Route #{route.name} deleted.")
         |> assign_routes()}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "Could not delete the route.")}
    end
  end

  def handle_event("test", %{"id" => id}, socket) do
    route = Routing.get_route!(id)
    request = %Request{method: "GET", path: "/", query: "", headers: [], body: ""}

    result =
      case Proxy.forward(route, request) do
        {:ok, %Result{} = result} ->
          %{
            status: result.status,
            duration_ms: result.duration_ms,
            body: preview(result.body),
            error: nil
          }

        {:error, reason, duration_ms} ->
          %{
            status: error_status(reason),
            duration_ms: duration_ms,
            body: "",
            error: to_string(reason)
          }
      end

    {:noreply, assign(socket, :test_results, Map.put(socket.assigns.test_results, id, result))}
  end

  defp error_status(:upstream_timeout), do: 504
  defp error_status(:upstream_unreachable), do: 502
  defp error_status(:upstream_response_too_large), do: 502
  defp error_status(_reason), do: 500

  defp preview(body) when is_binary(body) do
    preview = binary_part(body, 0, min(byte_size(body), 4096))

    if String.valid?(preview) do
      preview
    else
      inspect(preview)
    end
  end

  defp assign_routes(socket) do
    routes =
      Routing.list_routes!()
      |> Enum.filter(&matches_direction?(&1, socket.assigns.direction))
      |> Enum.filter(&matches_enabled?(&1, socket.assigns.enabled))
      |> Enum.sort_by(& &1.name)

    assign(socket, :routes, routes)
  end

  defp matches_direction?(_route, "all"), do: true
  defp matches_direction?(route, direction), do: to_string(route.direction) == direction

  defp matches_enabled?(_route, "all"), do: true
  defp matches_enabled?(route, "enabled"), do: route.enabled
  defp matches_enabled?(route, "disabled"), do: not route.enabled
  defp matches_enabled?(_route, _enabled), do: true

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Routes
        <:subtitle>Forward requests with injected headers, outbound or inbound.</:subtitle>
        <:actions>
          <.button navigate={~p"/routes/new"} variant="primary">
            <.icon name="hero-plus" class="size-4" /> New route
          </.button>
        </:actions>
      </.header>

      <form
        id="route-filters"
        phx-change="filter"
        class="flex flex-wrap items-end gap-3 rounded-xl border border-base-300 bg-base-100 p-4"
      >
        <label class="flex flex-col gap-1 text-xs font-medium uppercase tracking-wide text-base-content/60">
          Direction
          <select name="direction" class="select select-sm select-bordered">
            <option value="all" selected={@direction == "all"}>All</option>
            <option value="outbound" selected={@direction == "outbound"}>Outbound</option>
            <option value="inbound" selected={@direction == "inbound"}>Inbound</option>
          </select>
        </label>

        <label class="flex flex-col gap-1 text-xs font-medium uppercase tracking-wide text-base-content/60">
          State
          <select name="enabled" class="select select-sm select-bordered">
            <option value="all" selected={@enabled == "all"}>All</option>
            <option value="enabled" selected={@enabled == "enabled"}>Enabled</option>
            <option value="disabled" selected={@enabled == "disabled"}>Paused</option>
          </select>
        </label>

        <span class="ml-auto text-sm text-base-content/60">
          {length(@routes)} route(s)
        </span>
      </form>

      <div
        :if={@routes == []}
        class="rounded-xl border border-dashed border-base-300 p-10 text-center"
      >
        <p class="text-sm text-base-content/60">No routes match these filters.</p>
        <a href={~p"/routes/new"} class="link link-primary text-sm">Create the first route</a>
      </div>

      <div :if={@routes != []} class="grid gap-3">
        <article
          :for={route <- @routes}
          id={"route-#{route.id}"}
          class="group flex flex-col gap-4 rounded-xl border border-base-300 bg-base-100 p-5 transition hover:border-base-content/20 hover:shadow-sm"
        >
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2">
                <h2 class="truncate text-base font-semibold">{route.name}</h2>
                <span class={[
                  "badge badge-sm",
                  route.direction == :outbound && "badge-primary",
                  route.direction == :inbound && "badge-secondary"
                ]}>
                  {route.direction}
                </span>
                <span :if={!route.enabled} class="badge badge-sm badge-ghost">Paused</span>
              </div>
              <p :if={route.description} class="mt-1 line-clamp-2 text-sm text-base-content/60">
                {route.description}
              </p>
            </div>

            <div class="flex items-center gap-2">
              <.button
                type="button"
                class="btn btn-sm btn-ghost"
                phx-click="test"
                phx-value-id={route.id}
              >
                <.icon name="hero-paper-airplane" class="size-4" /> Test
              </.button>
              <.link
                navigate={~p"/routes/#{route.id}/edit"}
                class="btn btn-sm btn-ghost"
                aria-label={"Edit #{route.name}"}
              >
                <.icon name="hero-pencil-square" class="size-4" /> Edit
              </.link>
              <.button
                type="button"
                class="btn btn-sm btn-ghost text-error"
                phx-click="delete"
                phx-value-id={route.id}
                data-confirm={"Delete #{route.name}? This cannot be undone."}
              >
                <.icon name="hero-trash" class="size-4" /> Delete
              </.button>
            </div>
          </div>

          <dl class="grid gap-3 text-sm sm:grid-cols-2">
            <div class="min-w-0">
              <dt class="text-xs font-medium uppercase tracking-wide text-base-content/50">
                {if route.direction == :outbound, do: "Slug", else: "Path prefix"}
              </dt>
              <dd class="mt-1 truncate font-mono text-xs">
                {if route.direction == :outbound,
                  do: "/r/#{route.slug}",
                  else: route.path_prefix}
              </dd>
            </div>
            <div class="min-w-0">
              <dt class="text-xs font-medium uppercase tracking-wide text-base-content/50">
                Target
              </dt>
              <dd class="mt-1 truncate font-mono text-xs">{route.target_url}</dd>
            </div>
          </dl>

          <div
            :if={@test_results[route.id]}
            id={"test-result-#{route.id}"}
            class="rounded-lg border border-base-200 bg-base-200/50 p-3"
          >
            <div class="flex flex-wrap items-center gap-2 text-xs">
              <span class={[
                "badge badge-sm font-mono",
                (@test_results[route.id].error && "badge-error") || "badge-success"
              ]}>
                {@test_results[route.id].status}
              </span>
              <span class="text-base-content/60">
                {@test_results[route.id].duration_ms} ms
              </span>
              <span :if={@test_results[route.id].error} class="font-mono text-error">
                {@test_results[route.id].error}
              </span>
              <span class="ml-auto text-base-content/50">Test request: GET /</span>
            </div>
            <pre
              :if={@test_results[route.id].body != ""}
              class="mt-2 max-h-48 overflow-auto whitespace-pre-wrap break-all rounded bg-base-100 p-2 text-xs"
            >{@test_results[route.id].body}</pre>
          </div>

          <div class="flex items-center justify-between border-t border-base-200 pt-3">
            <span class="text-xs text-base-content/50">
              {if route.enabled, do: "Forwarding enabled", else: "Forwarding paused"}
            </span>
            <button
              type="button"
              phx-click="toggle"
              phx-value-id={route.id}
              class={[
                "relative inline-flex h-6 w-11 items-center rounded-full transition",
                if(route.enabled, do: "bg-primary", else: "bg-base-300")
              ]}
              role="switch"
              aria-checked={to_string(route.enabled)}
              aria-label={if route.enabled, do: "Pause route", else: "Enable route"}
            >
              <span class={[
                "inline-block size-5 transform rounded-full bg-white shadow transition",
                if(route.enabled, do: "translate-x-5", else: "translate-x-0.5")
              ]} />
            </button>
          </div>
        </article>
      </div>
    </Layouts.app>
    """
  end
end
