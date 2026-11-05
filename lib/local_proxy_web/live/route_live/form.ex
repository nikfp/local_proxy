defmodule LocalProxyWeb.RouteLive.Form do
  @moduledoc false

  use LocalProxyWeb, :live_view

  alias LocalProxy.Routing
  alias LocalProxy.Routing.InboundKey
  alias LocalProxy.Routing.Route

  @impl true
  def mount(params, _session, socket) do
    socket =
      case socket.assigns.live_action do
        :new ->
          socket
          |> assign(:page_title, "New route")
          |> assign(:header_rows, [new_header_row()])
          |> assign(:inbound_key_revealed, true)
          |> assign_form(new_form())

        :edit ->
          case load_route(params["id"]) do
            nil ->
              {:ok,
               socket
               |> put_flash(:error, "Route not found.")
               |> push_navigate(to: ~p"/routes")}

            route ->
              socket
              |> assign(:page_title, "Edit #{route.name}")
              |> assign(:route, route)
              |> assign(:header_rows, rows_from_headers(route.headers))
              |> assign(:inbound_key_revealed, false)
              |> assign_form(edit_form(route))
          end
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"route" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.form, clear_unused_path(params))
    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save", %{"route" => params} = form_params, socket) do
    header_rows =
      merge_submitted_headers(socket.assigns.header_rows, form_params["header"])

    params =
      params
      |> clear_unused_path()
      |> Map.put("headers", headers_from_rows(header_rows))

    try do
      case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
        {:ok, route} ->
          {:noreply,
           socket
           |> put_flash(:info, "Route #{route.name} saved.")
           |> push_navigate(to: ~p"/routes")}

        {:error, form} ->
          {:noreply,
           socket
           |> put_flash(:error, "Please fix the highlighted fields.")
           |> assign(:form, form)}
      end
    rescue
      LocalProxy.Vault.LockedError ->
        {:noreply, put_flash(socket, :error, "The vault is locked. Sign in again.")}

      LocalProxy.Vault.DecryptError ->
        {:noreply, put_flash(socket, :error, "The vault could not decrypt the saved values.")}
    end
  end

  def handle_event("generate_inbound_key", _params, socket) do
    form = put_inbound_key(socket.assigns.form, InboundKey.generate())

    {:noreply, assign(socket, form: form, inbound_key_revealed: true)}
  end

  def handle_event("reveal_inbound_key", _params, socket) do
    {:noreply, assign(socket, :inbound_key_revealed, true)}
  end

  def handle_event("hide_inbound_key", _params, socket) do
    {:noreply, assign(socket, :inbound_key_revealed, false)}
  end

  def handle_event("add_header", _params, socket) do
    {:noreply, assign(socket, :header_rows, socket.assigns.header_rows ++ [new_header_row()])}
  end

  def handle_event("remove_header", %{"id" => id}, socket) do
    id = String.to_integer(id)

    {:noreply,
     assign(socket, :header_rows, Enum.reject(socket.assigns.header_rows, &(&1.id == id)))}
  end

  def handle_event("reveal_header", %{"id" => id}, socket) do
    id = String.to_integer(id)
    {:noreply, update_row(socket, id, &Map.put(&1, :revealed, true))}
  end

  def handle_event("hide_header", %{"id" => id}, socket) do
    id = String.to_integer(id)
    {:noreply, update_row(socket, id, &Map.put(&1, :revealed, false))}
  end

  def handle_event("header_change", %{"header" => submitted}, socket) when is_map(submitted) do
    {:noreply,
     assign(
       socket,
       :header_rows,
       merge_submitted_headers(socket.assigns.header_rows, submitted)
     )}
  end

  def handle_event("header_change", _params, socket), do: {:noreply, socket}

  defp update_row(socket, id, fun) do
    assign(
      socket,
      :header_rows,
      Enum.map(socket.assigns.header_rows, fn row ->
        if row.id == id, do: fun.(row), else: row
      end)
    )
  end

  defp merge_submitted_headers(rows, nil), do: rows

  defp merge_submitted_headers(rows, submitted) when is_map(submitted) do
    Enum.map(rows, fn row ->
      case Map.get(submitted, Integer.to_string(row.id)) do
        %{} = fields ->
          row
          |> maybe_update(:name, fields["name"])
          |> maybe_update(:value, fields["value"])

        _ ->
          row
      end
    end)
  end

  defp merge_submitted_headers(rows, _submitted), do: rows

  defp maybe_update(row, _key, nil), do: row
  defp maybe_update(row, key, value), do: Map.put(row, key, value)

  defp load_route(id) do
    case Routing.get_route(id) do
      nil -> nil
      {:ok, route} -> Ash.load!(route, [:headers, :inbound_key], domain: Routing)
      route -> Ash.load!(route, [:headers, :inbound_key], domain: Routing)
    end
  end

  defp clear_unused_path(params) do
    case params["direction"] do
      "outbound" ->
        params
        |> Map.put("path_prefix", nil)
        |> Map.put("inbound_key", nil)

      "inbound" ->
        Map.put(params, "slug", nil)

      _ ->
        params
    end
  end

  defp new_form do
    Route
    |> AshPhoenix.Form.for_create(:create, domain: Routing, as: "route")
    |> to_form()
  end

  defp edit_form(route) do
    route
    |> AshPhoenix.Form.for_update(:update, domain: Routing, as: "route")
    |> to_form()
  end

  defp assign_form(socket, form), do: assign(socket, :form, form)

  defp rows_from_headers(headers) when is_map(headers) do
    headers
    |> Enum.sort_by(fn {name, _value} -> name end)
    |> Enum.map(fn {name, value} ->
      %{id: System.unique_integer([:positive]), name: name, value: value, revealed: false}
    end)
    |> case do
      [] -> [new_header_row()]
      rows -> rows
    end
  end

  defp rows_from_headers(_headers), do: [new_header_row()]

  defp new_header_row do
    %{id: System.unique_integer([:positive]), name: "", value: "", revealed: true}
  end

  defp headers_from_rows(rows) do
    Enum.reduce(rows, %{}, fn row, acc ->
      name = String.trim(row.name)

      if name == "" do
        acc
      else
        Map.put(acc, name, row.value)
      end
    end)
  end

  defp direction(%Phoenix.HTML.Form{} = form) do
    case form[:direction].value do
      :outbound -> "outbound"
      :inbound -> "inbound"
      value -> to_string(value)
    end
  end

  defp header_errors(%Phoenix.HTML.Form{} = form) do
    case form[:headers] do
      %Phoenix.HTML.FormField{errors: errors} -> errors
      _ -> []
    end
  end

  defp put_inbound_key(%Phoenix.HTML.Form{} = form, key) do
    params = AshPhoenix.Form.params(form)

    route_params =
      case params do
        %{"route" => %{} = nested} -> nested
        params when is_map(params) -> Map.reject(params, fn {name, _} -> name =~ ~r/^_/ end)
      end
      |> Map.put("inbound_key", key)

    validation_params =
      if match?(%{"route" => _}, params), do: %{"route" => route_params}, else: route_params

    AshPhoenix.Form.validate(form, validation_params)
  end

  defp inbound_key_present?(%Phoenix.HTML.Form{} = form) do
    case form[:inbound_key] do
      %Phoenix.HTML.FormField{value: value} -> is_binary(value) and value != ""
      _ -> false
    end
  end

  defp inbound_key_changed?(%Phoenix.HTML.Form{} = form, %Route{} = route) do
    case form[:inbound_key] do
      %Phoenix.HTML.FormField{value: value} -> value != route.inbound_key
      _ -> false
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        {@page_title}
        <:subtitle>
          Outbound routes are a local entry point for API calls. Inbound routes
          are reached through the tunnel and require a path prefix.
        </:subtitle>
        <:actions>
          <.button navigate={~p"/routes"} variant="primary">
            Back to routes
          </.button>
        </:actions>
      </.header>

      <div class="grid gap-3 rounded-xl border border-base-300 bg-base-200/40 p-4 text-sm sm:grid-cols-2">
        <div class="grid gap-1">
          <h2 class="font-semibold">Outbound</h2>
          <p class="text-base-content/70">
            Callers use <code class="font-mono">&lt;base&gt;/r/&lt;slug&gt;/...</code>.
            The path after the slug and the query string are appended to the target,
            and the route's headers are injected on every call. The target URL is
            never exposed to the caller.
          </p>
          <p class="text-base-content/70">
            HTML is returned unchanged. CSS, JS, images, and links are not rewritten
            or fetched through the proxy, so browsing a website through an outbound
            route will render without its assets. Use outbound routes for API
            endpoints, not pages you intend to view in a browser.
          </p>
        </div>

        <div class="grid gap-1">
          <h2 class="font-semibold">Inbound</h2>
          <p class="text-base-content/70">
            Requests through the tunnel are matched by the path prefix. This is
            required and cannot be <code class="font-mono">/</code>, since that would
            capture every tunnel request. The prefix is stripped, the remaining path
            and query are appended to the target, and the route's headers are
            injected.
          </p>
          <div class="mt-2 grid gap-1 rounded-lg border border-base-300 bg-base-100 p-3 font-mono text-xs">
            <p class="font-sans text-base-content/50">
              Example: prefix <code class="font-mono">/api</code>, target
              <code class="font-mono">http://localhost:3000</code>
            </p>
            <p>Caller sends: <span class="text-primary">GET /api/users?x=1</span></p>
            <p>Local server gets: <span class="text-primary">GET /users?x=1</span></p>
            <p>Caller sends: <span class="text-primary">GET /api</span></p>
            <p>Local server gets: <span class="text-primary">GET /</span></p>
          </div>
          <p class="text-base-content/70">
            Inbound targets must be loopback addresses. Callers must send this
            route's <code class="font-mono">X-Proxy-Key</code>
            value. Unknown paths and wrong keys return 401.
          </p>
        </div>
      </div>

      <.form
        for={@form}
        id="route-form"
        phx-change="validate"
        phx-submit="save"
        class="grid gap-6 rounded-xl border border-base-300 bg-base-100 p-6"
      >
        <div class="grid gap-5 sm:grid-cols-2">
          <.input field={@form[:name]} label="Name" required maxlength="120" />

          <.input
            field={@form[:direction]}
            type="select"
            label="Direction"
            options={[Outbound: "outbound", Inbound: "inbound"]}
            prompt="Choose a direction"
          />
        </div>

        <.input field={@form[:description]} type="textarea" label="Description" maxlength="500" />

        <div :if={direction(@form) == "outbound"} class="grid gap-5 sm:grid-cols-2">
          <.input
            field={@form[:slug]}
            label="Slug"
            placeholder="github"
          />
          <p class="-mt-1 text-xs text-base-content/60">
            Lowercase letters, digits, and hyphens. Public path: <code class="font-mono">/r/&lt;slug&gt;</code>.
          </p>
        </div>

        <div :if={direction(@form) == "inbound"} class="grid gap-5 sm:grid-cols-2">
          <.input
            field={@form[:path_prefix]}
            label="Path prefix"
            placeholder="/api"
            required
          />
          <p class="-mt-1 text-xs text-base-content/60">
            Required for inbound routes. Matched as a path segment and stripped
            before forwarding. <code class="font-mono">/</code>
            is not allowed because it would capture every tunnel request and leave
            no unmatched path.
          </p>
        </div>

        <div :if={direction(@form) == "inbound"} class="grid gap-2">
          <div class="flex items-end gap-2">
            <div class="flex-1">
              <.input
                :if={@live_action == :new or @inbound_key_revealed or not inbound_key_present?(@form)}
                field={@form[:inbound_key]}
                label="Inbound key"
                placeholder="Generate or paste the key the caller sends"
                autocomplete="off"
              />
              <div
                :if={
                  @live_action == :edit and not @inbound_key_revealed and
                    inbound_key_present?(@form)
                }
                class="grid gap-1"
              >
                <span class="text-xs font-medium text-base-content/60">Inbound key</span>
                <span class="flex h-10 items-center gap-1 rounded-md border border-base-300 bg-base-200 px-3 font-mono text-xs tracking-widest text-base-content/50">
                  ••••••••••••
                  <.button
                    type="button"
                    class="btn btn-xs btn-ghost ml-auto"
                    phx-click="reveal_inbound_key"
                    aria-label="Reveal inbound key"
                  >
                    <.icon name="hero-eye" class="size-4" />
                  </.button>
                </span>
              </div>
            </div>
            <.button
              type="button"
              phx-click="generate_inbound_key"
              class="btn btn-sm btn-ghost"
            >
              <.icon name="hero-key" class="size-4" /> Generate
            </.button>
            <.button
              :if={
                @live_action == :edit and @inbound_key_revealed and inbound_key_present?(@form) and
                  not inbound_key_changed?(@form, @route)
              }
              type="button"
              phx-click="hide_inbound_key"
              class="btn btn-sm btn-ghost"
              aria-label="Hide inbound key"
            >
              <.icon name="hero-eye-slash" class="size-4" />
            </.button>
          </div>
          <p class="-mt-1 text-xs text-base-content/60">
            The caller sends this exact value in <code class="font-mono">X-Proxy-Key</code>.
            Rotating it replaces the old key immediately, so update the caller first.
          </p>
        </div>

        <.input
          field={@form[:target_url]}
          label="Target URL"
          placeholder={
            if direction(@form) == "inbound",
              do: "http://localhost:3000",
              else: "https://api.example.com"
          }
        />

        <p :if={direction(@form) == "inbound"} class="-mt-2 text-xs text-base-content/60">
          Inbound targets must be loopback: <code class="font-mono">localhost</code>,
          an IPv4 loopback address, or <code class="font-mono">::1</code>.
        </p>

        <fieldset class="grid gap-3 rounded-lg border border-base-200 p-4 sm:grid-cols-2">
          <legend class="px-1 text-xs font-medium uppercase tracking-wide text-base-content/50">
            Behaviour
          </legend>
          <.input field={@form[:enabled]} type="checkbox" label="Enabled" />
          <.input
            field={@form[:retries]}
            type="checkbox"
            label="Retry transient upstream failures"
          />
        </fieldset>

        <section class="grid gap-3">
          <div class="flex items-center justify-between">
            <div>
              <h2 class="text-sm font-semibold">Injected headers</h2>
              <p class="text-xs text-base-content/60">
                Added to every forwarded request. Values are encrypted at rest.
              </p>
            </div>
            <.button type="button" phx-click="add_header" class="btn btn-sm btn-ghost">
              <.icon name="hero-plus" class="size-4" /> Add header
            </.button>
          </div>

          <div :for={row <- @header_rows} id={"header-row-#{row.id}"} class="flex items-end gap-2">
            <label class="grid flex-1 gap-1 text-xs font-medium text-base-content/60">
              Header
              <input
                type="text"
                name={"header[#{row.id}][name]"}
                value={row.name}
                phx-change="header_change"
                phx-debounce="200"
                placeholder="Authorization"
                class="input input-sm input-bordered w-full font-mono"
              />
            </label>

            <label class="grid flex-[2] gap-1 text-xs font-medium text-base-content/60">
              Value
              <span class="flex items-center gap-1">
                <input
                  :if={row.revealed or row.value == ""}
                  type="text"
                  name={"header[#{row.id}][value]"}
                  value={row.value}
                  phx-change="header_change"
                  phx-debounce="200"
                  placeholder="Bearer …"
                  class="input input-sm input-bordered w-full font-mono"
                />
                <span
                  :if={not row.revealed and row.value != ""}
                  class="flex h-8 flex-1 items-center gap-1 rounded-md border border-base-300 bg-base-200 px-3 font-mono text-xs tracking-widest text-base-content/50"
                >
                  ••••••••
                </span>
                <.button
                  :if={row.value != ""}
                  type="button"
                  class="btn btn-sm btn-ghost"
                  phx-click={if row.revealed, do: "hide_header", else: "reveal_header"}
                  phx-value-id={row.id}
                  aria-label={if row.revealed, do: "Hide value", else: "Reveal value"}
                >
                  <.icon
                    name={if row.revealed, do: "hero-eye-slash", else: "hero-eye"}
                    class="size-4"
                  />
                </.button>
              </span>
            </label>

            <.button
              type="button"
              class="btn btn-sm btn-ghost text-error"
              phx-click="remove_header"
              phx-value-id={row.id}
              aria-label="Remove header"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </.button>
          </div>

          <p :if={header_errors(@form) != []} class="text-sm text-error">
            {header_errors(@form) |> Enum.map(&translate_error/1) |> Enum.join(", ")}
          </p>
        </section>

        <div class="flex flex-wrap items-center justify-end gap-2 border-t border-base-200 pt-4">
          <.button navigate={~p"/routes"} type="button" class="btn btn-ghost">Cancel</.button>
          <.button type="submit" variant="primary" phx-disable-with="Saving…">
            Save route
          </.button>
        </div>
      </.form>
    </Layouts.app>
    """
  end
end
