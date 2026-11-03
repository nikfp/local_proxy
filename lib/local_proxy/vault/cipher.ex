defmodule LocalProxy.Vault.Cipher do
  @moduledoc """
  Cloak cipher wrapper that reads the vault key at call time.
  """

  @behaviour Cloak.Cipher

  alias Cloak.Ciphers.AES.GCM
  alias LocalProxy.Vault.DecryptError
  alias LocalProxy.Vault.KeyRing
  alias LocalProxy.Vault.LockedError

  @impl true
  def can_decrypt?(ciphertext, opts), do: GCM.can_decrypt?(ciphertext, opts)

  @impl true
  def encrypt(plaintext, opts) do
    case KeyRing.key() do
      {:ok, key} -> GCM.encrypt(plaintext, Keyword.put(opts, :key, key))
      :locked -> {:error, LockedError.exception([])}
    end
  end

  @impl true
  def decrypt(ciphertext, opts) do
    case KeyRing.key() do
      {:ok, key} ->
        case GCM.decrypt(ciphertext, Keyword.put(opts, :key, key)) do
          {:ok, plaintext} when is_binary(plaintext) -> {:ok, plaintext}
          _ -> {:error, DecryptError.exception([])}
        end

      :locked ->
        {:error, LockedError.exception([])}
    end
  end

  @doc """
  AshCloak `on_decrypt` callback. Avoids reaching `decrypt!/1` while locked.
  """
  def on_decrypt(_resource, _records, _field, _context) do
    if KeyRing.locked?() do
      {:error, LockedError.exception([])}
    else
      :ok
    end
  end
end
