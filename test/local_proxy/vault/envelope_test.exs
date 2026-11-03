defmodule LocalProxy.Vault.EnvelopeTest do
  use ExUnit.Case, async: true

  alias LocalProxy.Vault.Envelope

  @password "correct horse battery staple"

  defp wrap(key \\ Envelope.generate_key()) do
    {:ok, wrapped} = Envelope.wrap(key, @password, iterations: 100_000)
    {key, wrapped}
  end

  test "round-trips a key" do
    {key, wrapped} = wrap()

    assert {:ok, ^key} = Envelope.unwrap(wrapped, @password)
    refute wrapped =~ key
  end

  test "rejects the wrong password" do
    {_key, wrapped} = wrap()

    assert {:error, :invalid_password} = Envelope.unwrap(wrapped, "wrong password")
  end

  test "rejects short passwords on wrap" do
    assert {:error, :invalid_password_length} = Envelope.wrap(Envelope.generate_key(), "short")
  end

  test "rejects unknown envelope versions" do
    {_key, <<_version, rest::binary>>} = wrap()

    assert {:error, :unsupported_version} = Envelope.unwrap(<<2, rest::binary>>, @password)
  end

  test "rejects out-of-range iterations before deriving a key" do
    {key, wrapped} = wrap()

    <<head::binary-size(17), _iterations::unsigned-32, rest::binary>> = wrapped
    tampered = <<head::binary, 99_999::unsigned-32, rest::binary>>

    assert {:error, :iterations_out_of_range} = Envelope.unwrap(tampered, @password)

    assert {:error, :iterations_out_of_range} =
             Envelope.wrap(key, @password, iterations: 2_000_001)
  end

  test "rejects tampered salt, iv, tag, and ciphertext" do
    {_key, wrapped} = wrap()

    for offset <- [1, 17, 33, 49] do
      prefix = binary_part(wrapped, 0, offset)
      <<byte, rest::binary>> = binary_part(wrapped, offset, byte_size(wrapped) - offset)
      tampered = prefix <> <<Bitwise.bxor(byte, 1)>> <> rest
      assert {:error, _} = Envelope.unwrap(tampered, @password)
    end
  end
end
