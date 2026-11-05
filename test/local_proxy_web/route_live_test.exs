defmodule LocalProxyWeb.RouteLiveTest do
  use LocalProxyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias LocalProxy.Routing

  @outbound %{
    name: "GitHub",
    direction: :outbound,
    slug: "github",
    target_url: "https://api.github.com"
  }

  defp authed_conn(conn) do
    {:ok, generation} = LocalProxy.Vault.KeyRing.generation()

    init_test_session(conn, %{
      admin_authenticated: true,
      unlock_generation: generation
    })
  end

  defp create_route(attrs \\ %{}) do
    Routing.create_route!(Map.merge(@outbound, attrs))
  end

  defp choose_direction(view, direction) do
    view
    |> form("#route-form", route: %{"direction" => direction})
    |> render_change()

    view
  end

  defp first_header_row_id(view) do
    [_, id] = Regex.run(~r/id="header-row-(\d+)"/, render(view))
    id
  end

  test "creates an outbound route", %{conn: conn} do
    {:ok, view, _html} = live(authed_conn(conn), ~p"/routes/new")

    view = choose_direction(view, "outbound")

    view
    |> form("#route-form",
      route: %{
        "name" => "Stripe",
        "direction" => "outbound",
        "slug" => "stripe",
        "target_url" => "https://api.stripe.com/v1",
        "enabled" => "true"
      }
    )
    |> render_submit()

    assert_redirect(view, ~p"/routes")
    route = Routing.get_route_by_slug!("stripe")
    assert route.name == "Stripe"
    assert route.enabled
  end

  test "creates a route with an injected header", %{conn: conn} do
    {:ok, view, _html} = live(authed_conn(conn), ~p"/routes/new")

    view = choose_direction(view, "outbound")
    id = first_header_row_id(view)

    view
    |> element(~s(input[name="header[#{id}][name]"]))
    |> render_change(%{
      "header" => %{id => %{"name" => "X-Api-Key"}}
    })

    view
    |> element(~s(input[name="header[#{id}][value]"]))
    |> render_change(%{
      "header" => %{id => %{"value" => "top-secret"}}
    })

    view
    |> form("#route-form",
      route: %{
        "name" => "With header",
        "direction" => "outbound",
        "slug" => "with-header",
        "target_url" => "https://api.example.com",
        "enabled" => "true"
      }
    )
    |> render_submit()

    route = Routing.get_route_by_slug!("with-header", load: [:headers])
    assert route.headers["x-api-key"] == "top-secret"
  end

  test "saves headers submitted with the form without change events", %{conn: conn} do
    {:ok, view, _html} = live(authed_conn(conn), ~p"/routes/new")

    view = choose_direction(view, "outbound")
    id = first_header_row_id(view)

    view
    |> form("#route-form",
      route: %{
        "name" => "Header from form",
        "direction" => "outbound",
        "slug" => "header-from-form",
        "target_url" => "https://api.example.com",
        "enabled" => "true"
      },
      header: %{id => %{"name" => "X-Api-Key", "value" => "top-secret"}}
    )
    |> render_submit()

    assert_redirect(view, ~p"/routes")
    route = Routing.get_route_by_slug!("header-from-form", load: [:headers])
    assert route.headers["x-api-key"] == "top-secret"
  end

  test "preserves a masked header value when saving an edit", %{conn: conn} do
    route = create_route(%{headers: %{"X-Api-Key" => "top-secret"}})
    {:ok, view, _html} = live(authed_conn(conn), ~p"/routes/#{route.id}/edit")

    id = first_header_row_id(view)

    view
    |> form("#route-form",
      route: %{"name" => "Renamed"},
      header: %{id => %{"name" => "x-api-key"}}
    )
    |> render_submit()

    assert_redirect(view, ~p"/routes")
    updated = Routing.get_route!(route.id, load: [:headers])
    assert updated.name == "Renamed"
    assert updated.headers["x-api-key"] == "top-secret"
  end

  test "edits a route", %{conn: conn} do
    route = create_route()
    {:ok, view, _html} = live(authed_conn(conn), ~p"/routes/#{route.id}/edit")

    view
    |> form("#route-form", route: %{"name" => "Renamed"})
    |> render_submit()

    assert_redirect(view, ~p"/routes")
    assert Routing.get_route!(route.id).name == "Renamed"
  end

  test "switching direction clears the unused path field", %{conn: conn} do
    route = create_route()
    {:ok, view, _html} = live(authed_conn(conn), ~p"/routes/#{route.id}/edit")

    view
    |> form("#route-form", route: %{"direction" => "inbound"})
    |> render_change()

    view
    |> form("#route-form",
      route: %{
        "direction" => "inbound",
        "path_prefix" => "/svc",
        "target_url" => "http://localhost:3000",
        "inbound_key" => "test-inbound-key-0123456789abcdef"
      }
    )
    |> render_submit()

    assert_redirect(view, ~p"/routes")
    updated = Routing.get_route!(route.id)
    assert updated.direction == :inbound
    assert updated.slug == nil
    assert updated.path_prefix == "/svc"
  end

  test "creates an inbound route with a pasted key", %{conn: conn} do
    key = "test-inbound-key-0123456789abcdef"
    {:ok, view, _html} = live(authed_conn(conn), ~p"/routes/new")

    view = choose_direction(view, "inbound")

    view
    |> form("#route-form",
      route: %{
        "name" => "Local",
        "direction" => "inbound",
        "path_prefix" => "/api",
        "target_url" => "http://localhost:3000",
        "enabled" => "true",
        "inbound_key" => key
      }
    )
    |> render_change()

    assert render(view) =~ key

    view
    |> form("#route-form")
    |> render_submit()

    assert_redirect(view, ~p"/routes")
    route = Routing.get_route_by_path_prefix!("/api", load: [:inbound_key])
    assert route.inbound_key == key
  end

  test "generating an inbound key preserves the rest of the form", %{conn: conn} do
    {:ok, view, _html} = live(authed_conn(conn), ~p"/routes/new")

    view = choose_direction(view, "inbound")

    view
    |> form("#route-form",
      route: %{
        "name" => "Local API",
        "direction" => "inbound",
        "path_prefix" => "/api",
        "target_url" => "http://localhost:3000",
        "enabled" => "true"
      }
    )
    |> render_change()

    html =
      view
      |> element("button[phx-click=generate_inbound_key]")
      |> render_click()

    assert html =~ ~s(value="Local API")
    assert html =~ ~s(value="/api")
    assert html =~ ~s(value="http://localhost:3000")

    view
    |> form("#route-form")
    |> render_submit()

    assert_redirect(view, ~p"/routes")
    route = Routing.get_route_by_path_prefix!("/api", load: [:inbound_key])
    assert route.name == "Local API"
    assert byte_size(route.inbound_key) >= 32
  end

  test "masks a stored inbound key and preserves it when saving other changes", %{conn: conn} do
    key = "test-inbound-key-0123456789abcdef"

    route =
      Routing.create_route!(%{
        name: "Local",
        direction: :inbound,
        path_prefix: "/api",
        target_url: "http://localhost:3000",
        inbound_key: key
      })

    {:ok, view, html} = live(authed_conn(conn), ~p"/routes/#{route.id}/edit")

    refute html =~ key
    assert html =~ "••••"

    view
    |> form("#route-form", route: %{"name" => "Renamed"})
    |> render_submit()

    assert_redirect(view, ~p"/routes")
    updated = Routing.get_route!(route.id, load: [:inbound_key])
    assert updated.name == "Renamed"
    assert updated.inbound_key == key
  end

  test "generating a replacement key on edit preserves the route fields", %{conn: conn} do
    original_key = "test-inbound-key-0123456789abcdef"

    route =
      Routing.create_route!(%{
        name: "Local",
        direction: :inbound,
        path_prefix: "/api",
        target_url: "http://localhost:3000",
        inbound_key: original_key
      })

    {:ok, view, _html} = live(authed_conn(conn), ~p"/routes/#{route.id}/edit")

    view
    |> element("button[phx-click=generate_inbound_key]")
    |> render_click()

    view
    |> form("#route-form")
    |> render_submit()

    assert_redirect(view, ~p"/routes")
    updated = Routing.get_route!(route.id, load: [:inbound_key])
    assert updated.name == "Local"
    assert updated.path_prefix == "/api"
    assert updated.target_url == "http://localhost:3000"
    assert updated.inbound_key != original_key
    assert byte_size(updated.inbound_key) >= 32
  end

  test "reveals a stored header value without rendering it initially", %{conn: conn} do
    route = create_route(%{headers: %{"Authorization" => "Bearer top-secret"}})

    {:ok, view, html} = live(authed_conn(conn), ~p"/routes/#{route.id}/edit")

    refute html =~ "top-secret"
    assert html =~ "••••"

    view |> element("button[aria-label='Reveal value']") |> render_click()
    assert render(view) =~ "top-secret"
  end

  test "pauses and enables a route from the index", %{conn: conn} do
    route = create_route()
    {:ok, view, _html} = live(authed_conn(conn), ~p"/routes")

    view |> element("[role=switch]") |> render_click()
    refute Routing.get_route!(route.id).enabled

    view |> element("[role=switch]") |> render_click()
    assert Routing.get_route!(route.id).enabled
  end

  test "deletes a route", %{conn: conn} do
    create_route()
    {:ok, view, _html} = live(authed_conn(conn), ~p"/routes")

    view |> element("button[phx-click=delete]") |> render_click()
    assert Routing.list_routes!() == []
  end

  test "shows a copy link for outbound routes only", %{conn: conn} do
    create_route()

    Routing.create_route!(%{
      name: "Local",
      direction: :inbound,
      path_prefix: "/api",
      target_url: "http://localhost:3000",
      inbound_key: "test-inbound-key-0123456789abcdef"
    })

    {:ok, _view, html} = live(authed_conn(conn), ~p"/routes")

    assert html =~ ~r/data-copy="http:\/\/[^"]+\/r\/github"/
    assert html =~ ~r/id="copy-link-[^"]+"/
    assert html =~ ~r/name="_csrf_token" value="[^"]+"/
    assert length(Regex.scan(~r/data-copy=/, html)) == 1
  end

  test "the test button shows the stubbed upstream response", %{conn: conn} do
    route = create_route(%{enabled: false})
    stub = LocalProxy.RouteLiveTestStub

    Req.Test.stub(stub, fn upstream_conn ->
      Req.Test.text(upstream_conn, "hello from upstream")
    end)

    previous = Application.get_env(:local_proxy, :proxy, [])

    Application.put_env(
      :local_proxy,
      :proxy,
      Keyword.put(previous, :req_options, plug: {Req.Test, stub})
    )

    on_exit(fn -> Application.put_env(:local_proxy, :proxy, previous) end)

    {:ok, view, _html} = live(authed_conn(conn), ~p"/routes")
    Req.Test.allow(stub, self(), view.pid)

    view |> element("button[phx-click=test]") |> render_click()

    html = render(view)
    assert html =~ "200"
    assert html =~ "hello from upstream"
    assert html =~ "route-#{route.id}"
  end

  test "filters by direction", %{conn: conn} do
    create_route()

    Routing.create_route!(%{
      name: "Local",
      direction: :inbound,
      path_prefix: "/api",
      target_url: "http://localhost:3000",
      inbound_key: "test-inbound-key-0123456789abcdef"
    })

    {:ok, view, _html} = live(authed_conn(conn), ~p"/routes")

    view
    |> form("#route-filters", %{"direction" => "inbound", "enabled" => "all"})
    |> render_change()

    html = render(view)
    assert html =~ "Local"
    refute html =~ "GitHub"
  end
end
