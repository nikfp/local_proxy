defmodule LocalProxy.Vault.CipherTest do
  use ExUnit.Case, async: false

  alias LocalProxy.Vault.Cipher
  alias LocalProxy.Vault.DecryptError
  alias LocalProxy.Vault.LockedError

  @opts [tag: "AES.GCM.V1", iv_length: 12]

  setup do
    LocalProxy.VaultTestHelpers.unlock()
    on_exit(&LocalProxy.VaultTestHelpers.unlock/0)
    :ok
  end

  test "encrypts and decrypts while unlocked" do
    assert {:ok, ciphertext} = Cipher.encrypt("hello", @opts)
    assert {:ok, "hello"} = Cipher.decrypt(ciphertext, @opts)
  end

  test "returns LockedError from encrypt and decrypt while locked" do
    {:ok, ciphertext} = Cipher.encrypt("hello", @opts)
    LocalProxy.VaultTestHelpers.lock()

    assert {:error, %LockedError{}} = Cipher.encrypt("hello", @opts)
    assert {:error, %LockedError{}} = Cipher.decrypt(ciphertext, @opts)
    assert Cipher.can_decrypt?(ciphertext, @opts)
  end

  test "returns DecryptError for tampered ciphertext" do
    {:ok, ciphertext} = Cipher.encrypt("hello", @opts)

    prefix = binary_part(ciphertext, 0, byte_size(ciphertext) - 1)
    <<last>> = binary_part(ciphertext, byte_size(ciphertext) - 1, 1)
    tampered = prefix <> <<Bitwise.bxor(last, 1)>>

    assert {:error, %DecryptError{}} = Cipher.decrypt(tampered, @opts)
  end

  test "bang functions raise clean errors" do
    assert_raise LockedError, fn ->
      LocalProxy.VaultTestHelpers.lock()
      LocalProxy.Vault.encrypt!("hello")
    end

    LocalProxy.VaultTestHelpers.unlock()
    ciphertext = LocalProxy.Vault.encrypt!("hello")
    LocalProxy.VaultTestHelpers.lock()

    assert_raise LockedError, fn -> LocalProxy.Vault.decrypt!(ciphertext) end
  end
end
