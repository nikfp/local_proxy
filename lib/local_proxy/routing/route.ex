defmodule LocalProxy.Routing.Route do
  @moduledoc """
  A proxy route, outbound or inbound.

  Header values are encrypted at rest by AshCloak. Outbound routes are addressed
  by `slug`; inbound routes match on `path_prefix`.
  """

  use Ash.Resource,
    domain: LocalProxy.Routing,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCloak]

  sqlite do
    table "routes"
    repo LocalProxy.Repo
  end

  cloak do
    vault(LocalProxy.Vault)
    attributes([:headers, :inbound_key])
    encrypt_nil?(false)
    on_decrypt(&LocalProxy.Vault.Cipher.on_decrypt/4)
  end

  actions do
    default_accept [
      :name,
      :description,
      :direction,
      :slug,
      :path_prefix,
      :target_url,
      :headers,
      :inbound_key,
      :enabled,
      :retries
    ]

    read :read do
      primary? true
    end

    create :create do
      accept [
        :name,
        :description,
        :direction,
        :slug,
        :path_prefix,
        :target_url,
        :headers,
        :inbound_key,
        :enabled,
        :retries
      ]

      change LocalProxy.Routing.Changes.NormalizeHeaders
    end

    update :update do
      accept [
        :name,
        :description,
        :direction,
        :slug,
        :path_prefix,
        :target_url,
        :headers,
        :inbound_key,
        :enabled,
        :retries
      ]

      require_atomic? false
      change LocalProxy.Routing.Changes.NormalizeHeaders
    end

    destroy :destroy
  end

  validations do
    validate {LocalProxy.Routing.Validations.DirectionShape, []}
    validate {LocalProxy.Routing.Validations.TargetUrl, []}
    validate {LocalProxy.Routing.Validations.InboundKey, []}
  end

  attributes do
    attribute :id, :uuid do
      primary_key? true
      allow_nil? false
      default &Ash.UUID.generate/0
    end

    attribute :name, :string do
      allow_nil? false
      constraints min_length: 1, max_length: 120
    end

    attribute :description, :string do
      constraints max_length: 500
    end

    attribute :direction, :atom do
      allow_nil? false
      constraints one_of: [:outbound, :inbound]
    end

    attribute :slug, :string do
      constraints min_length: 1, max_length: 64
    end

    attribute :path_prefix, :string do
      constraints max_length: 256
    end

    attribute :target_url, :string do
      allow_nil? false
    end

    attribute :headers, :map do
      allow_nil? false
      default %{}
    end

    attribute :inbound_key, :string do
      constraints min_length: 32, max_length: 256
    end

    attribute :enabled, :boolean do
      allow_nil? false
      default true
    end

    attribute :retries, :boolean do
      allow_nil? false
      default false
    end

    timestamps()
  end

  identities do
    identity :unique_slug, [:slug]
    identity :unique_path_prefix, [:path_prefix]
  end
end
