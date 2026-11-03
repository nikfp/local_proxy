defmodule LocalProxy.Vault.Keys do
  @moduledoc """
  Data access for the singleton wrapped vault key.
  """

  use Ash.Domain

  resources do
    resource LocalProxy.Vault.Key do
      define :get_key, action: :read, get_by: [:id]
      define :create_key, action: :create
      define :update_key, action: :update
    end
  end
end
