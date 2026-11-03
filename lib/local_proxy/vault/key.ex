defmodule LocalProxy.Vault.Key do
  @moduledoc """
  Singleton row holding the wrapped vault data key.
  """

  use Ash.Resource,
    domain: LocalProxy.Vault.Keys,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "vault_keys"
    repo LocalProxy.Repo
  end

  actions do
    read :read do
      primary? true
    end

    create :create do
      primary? true
      accept [:id, :wrapped]
    end

    update :update do
      primary? true
      accept [:wrapped]
      require_atomic? false
    end
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      default "default"
    end

    attribute :wrapped, :binary do
      allow_nil? false
    end

    timestamps()
  end
end
