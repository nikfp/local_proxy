defmodule LocalProxy.Vault.KeyStoreTest do
  use LocalProxy.DataCase, async: false

  alias LocalProxy.Vault.KeyStore

  @password "correct horse battery staple"
  @new_password "another correct horse battery"

  setup do
    LocalProxy.VaultTestHelpers.unlock()
    :ok
  end

  test "creates, unwraps, and rewraps the key" do
    refute KeyStore.configured?()

    assert {:ok, key} = KeyStore.create(@password)
    assert KeyStore.configured?()
    assert {:ok, ^key} = KeyStore.unwrap(@password)
    assert {:error, :invalid_password} = KeyStore.unwrap("wrong password")

    assert {:ok, ^key} = KeyStore.rewrap(@password, @new_password)
    assert {:error, :invalid_password} = KeyStore.unwrap(@password)
    assert {:ok, ^key} = KeyStore.unwrap(@new_password)
  end

  test "rejects short passwords" do
    assert {:error, :invalid_password_length} = KeyStore.create("short")
  end
end
