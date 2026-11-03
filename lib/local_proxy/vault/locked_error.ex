defmodule LocalProxy.Vault.LockedError do
  @moduledoc """
  Raised or returned when encrypted data is touched while the vault is locked.
  """

  defexception message: "vault is locked"
end

defimpl Plug.Exception, for: LocalProxy.Vault.LockedError do
  def status(_exception), do: 503
  def actions(_exception), do: []
end
