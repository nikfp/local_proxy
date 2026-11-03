defmodule LocalProxy.Vault.DecryptError do
  @moduledoc """
  Returned when ciphertext cannot be authenticated with the unlocked key.
  """

  defexception message: "could not decrypt vault data"
end

defimpl Plug.Exception, for: LocalProxy.Vault.DecryptError do
  def status(_exception), do: 500
  def actions(_exception), do: []
end
