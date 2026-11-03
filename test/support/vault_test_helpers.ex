defmodule LocalProxy.VaultTestHelpers do
  @moduledoc false

  @test_key Base.decode64!("MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=")

  def key, do: @test_key

  def unlock do
    {:ok, generation} = LocalProxy.Vault.KeyRing.unlock(@test_key)
    generation
  end

  def lock, do: LocalProxy.Vault.KeyRing.lock()
end
