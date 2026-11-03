defmodule LocalProxy.Vault.Envelope do
  @moduledoc """
  Wraps and unwraps the 32-byte data key with a password-derived KEK.
  """

  @aad "local_proxy:vault_key:v1"
  @version 1
  @salt_size 16
  @iv_size 12
  @tag_size 16
  @key_size 32
  @default_iterations 600_000
  @min_iterations 100_000
  @max_iterations 2_000_000
  @min_password 12
  @max_password 1_024

  def aad, do: @aad
  def version, do: @version
  def default_iterations, do: @default_iterations
  def min_iterations, do: @min_iterations
  def max_iterations, do: @max_iterations
  def min_password_length, do: @min_password
  def max_password_length, do: @max_password

  @spec generate_key() :: binary()
  def generate_key, do: :crypto.strong_rand_bytes(@key_size)

  @spec wrap(binary(), binary(), keyword()) :: {:ok, binary()} | {:error, atom()}
  def wrap(key, password, opts \\ [])

  def wrap(key, password, opts)
      when is_binary(key) and byte_size(key) == @key_size and is_binary(password) do
    iterations = Keyword.get(opts, :iterations, @default_iterations)

    with :ok <- validate_password(password),
         :ok <- validate_iterations(iterations) do
      salt = :crypto.strong_rand_bytes(@salt_size)
      iv = :crypto.strong_rand_bytes(@iv_size)
      kek = derive_kek(password, salt, iterations)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, kek, iv, key, @aad, @tag_size, true)

      {:ok,
       <<@version, salt::binary-size(@salt_size), iterations::unsigned-32,
         iv::binary-size(@iv_size), tag::binary-size(@tag_size),
         ciphertext::binary-size(@key_size)>>}
    end
  end

  def wrap(_key, _password, _opts), do: {:error, :invalid_key}

  @spec unwrap(binary(), binary()) :: {:ok, binary()} | {:error, atom()}
  def unwrap(
        <<@version, salt::binary-size(@salt_size), iterations::unsigned-32,
          iv::binary-size(@iv_size), tag::binary-size(@tag_size),
          ciphertext::binary-size(@key_size)>>,
        password
      )
      when is_binary(password) do
    with :ok <- validate_password_for_unwrap(password),
         :ok <- validate_iterations(iterations) do
      kek = derive_kek(password, salt, iterations)

      case :crypto.crypto_one_time_aead(:aes_256_gcm, kek, iv, ciphertext, @aad, tag, false) do
        key when is_binary(key) and byte_size(key) == @key_size -> {:ok, key}
        _ -> {:error, :invalid_password}
      end
    end
  end

  def unwrap(<<version, _rest::binary>>, _password) when version != @version,
    do: {:error, :unsupported_version}

  def unwrap(_envelope, _password), do: {:error, :invalid_envelope}

  defp derive_kek(password, salt, iterations) do
    :crypto.pbkdf2_hmac(:sha256, password, salt, iterations, @key_size)
  end

  defp validate_password(password) when byte_size(password) in @min_password..@max_password,
    do: :ok

  defp validate_password(_password), do: {:error, :invalid_password_length}

  defp validate_password_for_unwrap(password) when byte_size(password) in 1..@max_password,
    do: :ok

  defp validate_password_for_unwrap(_password), do: {:error, :invalid_password_length}

  defp validate_iterations(iterations)
       when is_integer(iterations) and iterations in @min_iterations..@max_iterations,
       do: :ok

  defp validate_iterations(_iterations), do: {:error, :iterations_out_of_range}
end
