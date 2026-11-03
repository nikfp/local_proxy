defmodule LocalProxy.Vault.KeyRing do
  @moduledoc """
  Process-wide in-memory vault key and unlock generation.

  The key is held in `:persistent_term` because reads happen on every proxied
  request. Writes happen only on unlock and lock.
  """

  @pt_key {__MODULE__, :state}

  @spec unlock(binary()) :: {:ok, binary()}
  def unlock(key) when is_binary(key) and byte_size(key) == 32 do
    generation = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    :persistent_term.put(@pt_key, %{key: key, generation: generation})
    {:ok, generation}
  end

  @spec lock() :: :ok
  def lock do
    :persistent_term.erase(@pt_key)

    if Process.whereis(LocalProxy.PubSub) do
      Phoenix.PubSub.broadcast(LocalProxy.PubSub, "vault", :vault_locked)
    end

    :ok
  end

  @spec key() :: {:ok, binary()} | :locked
  def key do
    case :persistent_term.get(@pt_key, :locked) do
      %{key: key} -> {:ok, key}
      :locked -> :locked
    end
  end

  @spec generation() :: {:ok, binary()} | :locked
  def generation do
    case :persistent_term.get(@pt_key, :locked) do
      %{generation: generation} -> {:ok, generation}
      :locked -> :locked
    end
  end

  @spec locked?() :: boolean()
  def locked?, do: key() == :locked
end
