defmodule LocalProxy.Vault.KeyRingTest do
  use ExUnit.Case, async: false

  alias LocalProxy.Vault.KeyRing

  setup do
    on_exit(&LocalProxy.VaultTestHelpers.unlock/0)
    :ok
  end

  test "unlocks, reports the key and generation, and locks" do
    key = LocalProxy.VaultTestHelpers.key()
    assert {:ok, generation} = KeyRing.unlock(key)
    assert {:ok, ^key} = KeyRing.key()
    assert {:ok, ^generation} = KeyRing.generation()
    refute KeyRing.locked?()

    assert :ok = KeyRing.lock()
    assert KeyRing.locked?()
    assert :locked = KeyRing.key()
    assert :locked = KeyRing.generation()
  end
end
