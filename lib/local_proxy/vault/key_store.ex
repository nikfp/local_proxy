defmodule LocalProxy.Vault.KeyStore do
  @moduledoc """
  Reads and writes the wrapped vault key.
  """

  require Ash.Query

  alias LocalProxy.Vault.Envelope
  alias LocalProxy.Vault.Key
  alias LocalProxy.Vault.Keys

  @id "default"

  @spec fetch() :: {:ok, Key.t() | nil} | {:error, term()}
  def fetch do
    Key
    |> Ash.Query.filter(id == ^@id)
    |> Ash.read_one(domain: Keys)
  end

  @spec configured?() :: boolean()
  def configured? do
    match?({:ok, %Key{}}, fetch())
  end

  @spec create(binary()) :: {:ok, binary()} | {:error, term()}
  def create(password) do
    key = Envelope.generate_key()

    with {:ok, wrapped} <- Envelope.wrap(key, password),
         {:ok, _row} <- Ash.create(Key, %{id: @id, wrapped: wrapped}, domain: Keys) do
      {:ok, key}
    end
  end

  @spec unwrap(binary()) :: {:ok, binary()} | {:error, term()}
  def unwrap(password) when is_binary(password) do
    with {:ok, %Key{wrapped: wrapped}} <- fetch_row(),
         {:ok, key} <- Envelope.unwrap(wrapped, password) do
      {:ok, key}
    end
  end

  @spec rewrap(binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def rewrap(current_password, new_password) do
    with {:ok, %Key{} = row} <- fetch_row(),
         {:ok, key} <- Envelope.unwrap(row.wrapped, current_password),
         {:ok, wrapped} <- Envelope.wrap(key, new_password),
         {:ok, _row} <- Ash.update(row, %{wrapped: wrapped}, domain: Keys) do
      {:ok, key}
    end
  end

  defp fetch_row do
    case fetch() do
      {:ok, %Key{} = row} -> {:ok, row}
      {:ok, nil} -> {:error, :not_configured}
      {:error, error} -> {:error, error}
    end
  end
end
