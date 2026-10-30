defmodule LocalProxy.Routing do
  @moduledoc """
  Route configuration.
  """

  use Ash.Domain, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource LocalProxy.Routing.Route do
      define :list_routes, action: :read
      define :get_route, action: :read, get_by: [:id]
      define :get_route_by_slug, action: :read, get_by: [:slug]
      define :get_route_by_path_prefix, action: :read, get_by: [:path_prefix]
      define :create_route, action: :create
      define :update_route, action: :update
      define :destroy_route, action: :destroy
    end
  end

  @doc """
  Returns the enabled inbound route with the longest matching path prefix.

  Matching is segment-aware: `/api` matches `/api` and `/api/users`, but not
  `/apix`. Returns `nil` when nothing matches.
  """
  def get_inbound_route(path) when is_binary(path) do
    require Ash.Query

    LocalProxy.Routing.Route
    |> Ash.Query.filter(direction == :inbound and enabled == true)
    |> Ash.read!(domain: __MODULE__)
    |> Enum.filter(&prefix_match?(&1.path_prefix, path))
    |> Enum.max_by(&byte_size(&1.path_prefix), fn -> nil end)
  end

  defp prefix_match?(prefix, path) when is_binary(prefix) do
    path == prefix or String.starts_with?(path, prefix <> "/")
  end

  defp prefix_match?(_prefix, _path), do: false
end
