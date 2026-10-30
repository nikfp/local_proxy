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
end
