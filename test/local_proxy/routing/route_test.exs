defmodule LocalProxy.Routing.RouteTest do
  use LocalProxy.DataCase, async: false

  alias LocalProxy.Repo
  alias LocalProxy.Routing
  alias LocalProxy.Routing.Route

  @outbound %{
    name: "GitHub",
    direction: :outbound,
    slug: "github",
    target_url: "https://api.github.com"
  }

  @inbound %{
    name: "Local API",
    direction: :inbound,
    path_prefix: "/api",
    target_url: "http://localhost:3000",
    inbound_key: "test-inbound-key-0123456789abcdef"
  }

  defp create(attrs) do
    case Routing.create_route(attrs) do
      {:ok, route} -> Routing.get_route!(route.id, load: [:headers])
      {:error, error} -> {:error, error}
    end
  end

  defp create_outbound(attrs), do: create(Map.merge(@outbound, attrs))
  defp create_inbound(attrs), do: create(Map.merge(@inbound, attrs))

  defp error_text({:error, error}), do: Exception.message(error)

  describe "direction-specific fields" do
    test "outbound requires a slug" do
      assert error_text(create_outbound(%{slug: nil})) =~ "is required for outbound routes"
    end

    test "outbound rejects a path prefix" do
      assert error_text(create_outbound(%{path_prefix: "/nope"})) =~
               "must be empty for outbound routes"
    end

    test "inbound requires a path prefix" do
      assert error_text(create_inbound(%{path_prefix: nil})) =~ "is required for inbound routes"
    end

    test "inbound rejects a slug" do
      assert error_text(create_inbound(%{slug: "nope"})) =~ "must be empty for inbound routes"
    end

    test "enabled inbound routes require an inbound key" do
      assert error_text(create_inbound(%{inbound_key: nil})) =~
               "is required for enabled inbound routes"
    end

    test "outbound routes must not set an inbound key" do
      assert error_text(create_outbound(%{inbound_key: String.duplicate("k", 32)})) =~
               "must be empty for outbound routes"
    end

    test "inbound keys must be at least 32 characters" do
      assert error_text(create_inbound(%{inbound_key: "short"})) =~
               "must be at least 32 characters"
    end
  end

  describe "slug validation" do
    test "rejects invalid characters" do
      assert error_text(create_outbound(%{slug: "Bad Slash"})) =~ "lowercase letters"
    end

    test "rejects reserved slugs" do
      for slug <- ~w(new edit admin health) do
        assert error_text(create_outbound(%{slug: slug})) =~ "is reserved"
      end
    end

    test "enforces uniqueness on create" do
      assert %Route{} = create_outbound(%{})
      assert error_text(create_outbound(%{name: "Duplicate"})) =~ "already been taken"
    end

    test "enforces uniqueness on update" do
      route = create_outbound(%{})
      other = create_outbound(%{slug: "other", name: "Other"})

      assert error_text(Routing.update_route(other, %{slug: route.slug})) =~
               "already been taken"
    end
  end

  describe "path prefix validation" do
    test "rejects the root path" do
      assert error_text(create_inbound(%{path_prefix: "/"})) =~ "must not be /"
    end

    test "rejects trailing slashes, queries, and fragments" do
      for prefix <- ["/api/", "/api?x=1", "/api#frag"] do
        assert {:error, _} = create_inbound(%{path_prefix: prefix})
      end
    end

    test "rejects reserved prefixes but allows similar segments" do
      for prefix <- ~w(/r /routes /admin /health /live /assets /dev /r/foo) do
        assert error_text(create_inbound(%{path_prefix: prefix})) =~
                 "reserved application path"
      end

      assert %Route{} = create_inbound(%{path_prefix: "/router"})
    end

    test "enforces uniqueness" do
      assert %Route{} = create_inbound(%{})
      assert error_text(create_inbound(%{name: "Duplicate"})) =~ "already been taken"
    end
  end

  describe "target URL validation" do
    test "requires http or https and a host" do
      assert error_text(create_outbound(%{target_url: "ftp://example.com"})) =~
               "must start with http:// or https://"

      assert error_text(create_outbound(%{target_url: "https://"})) =~ "must include a host"
    end

    test "rejects queries, fragments, and userinfo" do
      for url <- [
            "https://example.com?a=1",
            "https://example.com#frag",
            "https://user:pass@example.com"
          ] do
        assert {:error, _} = create_outbound(%{target_url: url})
      end
    end

    test "inbound targets must be loopback" do
      for url <- ["https://example.com", "http://192.168.1.10:3000"] do
        assert error_text(create_inbound(%{target_url: url})) =~ "must be localhost"
      end

      for {url, index} <-
            Enum.with_index([
              "http://localhost:3000",
              "http://127.0.0.1:3000",
              "http://127.5.5.5",
              "http://[::1]:3000"
            ]) do
        assert %Route{} = create_inbound(%{target_url: url, path_prefix: "/p#{index}"})
      end
    end
  end

  describe "headers" do
    test "normalises names to lowercase" do
      route =
        create_outbound(%{headers: %{"X-Api-Key" => "secret", "Authorization" => "Bearer token"}})

      assert route.headers == %{"x-api-key" => "secret", "authorization" => "Bearer token"}
    end

    test "rejects forbidden and malformed names" do
      for name <- ~w(Host Content-Length X-Proxy-Key connection transfer-encoding) do
        assert error_text(create_outbound(%{headers: %{name => "value"}})) =~ "not allowed"
      end

      assert error_text(create_outbound(%{headers: %{"bad header" => "value"}})) =~
               "not a valid HTTP header name"

      assert error_text(create_outbound(%{headers: %{"ok" => 123}})) =~ "must be strings"
    end

    test "defaults to an empty map" do
      assert create_outbound(%{}).headers == %{}
    end

    test "round-trips through the vault" do
      route = create_outbound(%{headers: %{"Authorization" => "Bearer super-secret"}})
      assert route.headers["authorization"] == "Bearer super-secret"

      reloaded = Routing.get_route!(route.id, load: [:headers])
      assert reloaded.headers["authorization"] == "Bearer super-secret"
    end

    test "does not store plaintext in the encrypted column" do
      secret = "plaintext-#{System.unique_integer([:positive])}"
      route = create_outbound(%{headers: %{"X-Secret" => secret}})

      %{rows: rows} =
        Repo.query!("select encrypted_headers from routes where slug = ?", ["github"])

      assert [%{encrypted_headers: ciphertext}] =
               Enum.map(rows, fn [value] -> %{encrypted_headers: value} end)

      refute ciphertext =~ secret

      reloaded = Routing.get_route!(route.id, load: [:headers])
      assert reloaded.headers["x-secret"] == secret
    end

    test "inbound keys round-trip and are not stored in plaintext" do
      key = "route-key-#{System.unique_integer([:positive])}-0123456789abcdef0123456789abcdef"
      route = create_inbound(%{inbound_key: key})

      reloaded = Routing.get_route!(route.id, load: [:inbound_key])
      assert reloaded.inbound_key == key

      %{rows: rows} =
        Repo.query!("select encrypted_inbound_key from routes where path_prefix = ?", [
          route.path_prefix
        ])

      assert [%{encrypted_inbound_key: ciphertext}] =
               Enum.map(rows, fn [value] -> %{encrypted_inbound_key: value} end)

      refute ciphertext =~ key
    end
  end

  describe "defaults" do
    test "enabled is true and retries is false" do
      route = create_outbound(%{})
      assert route.enabled
      refute route.retries
    end
  end
end
