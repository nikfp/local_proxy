defmodule LocalProxy.Config do
  @moduledoc """
  Parses and validates configuration values read from the environment.

  `config/runtime.exs` calls these functions at boot so that invalid values fail
  fast with a clear message instead of surfacing later at request time.
  """

  @default_port 4000

  @doc """
  Parses `PORT`, falling back to #{@default_port}.
  """
  def parse_port(nil), do: {:ok, @default_port}

  def parse_port(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {port, ""} when port in 1..65_535 -> {:ok, port}
      _ -> {:error, "expected an integer between 1 and 65535, got #{inspect(value)}"}
    end
  end

  def parse_port(value) when is_integer(value) and value in 1..65_535, do: {:ok, value}

  def parse_port(value),
    do: {:error, "expected an integer between 1 and 65535, got #{inspect(value)}"}

  @doc """
  Same as `parse_port/1`, but raises on invalid input.
  """
  def parse_port!(value) do
    case parse_port(value) do
      {:ok, port} -> port
      {:error, message} -> raise "invalid PORT: #{message}"
    end
  end

  @doc """
  Decodes a base64-encoded 32-byte AES key.
  """
  def decode_cloak_key(nil), do: {:error, "CLOAK_KEY is missing"}

  def decode_cloak_key(value) when is_binary(value) do
    with {:ok, key} <- Base.decode64(String.trim(value)),
         true <- byte_size(key) == 32 do
      {:ok, key}
    else
      :error -> {:error, "CLOAK_KEY must be valid base64"}
      false -> {:error, "CLOAK_KEY must decode to 32 bytes"}
    end
  end

  @doc """
  Same as `decode_cloak_key/1`, but raises on invalid input.
  """
  def decode_cloak_key!(value) do
    case decode_cloak_key(value) do
      {:ok, key} -> key
      {:error, message} -> raise "invalid CLOAK_KEY: #{message}"
    end
  end

  @doc """
  Parses a positive integer setting, falling back to `default`.
  """
  def parse_positive_integer(nil, default), do: {:ok, default}

  def parse_positive_integer(value, _default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> {:error, "expected a positive integer, got #{inspect(value)}"}
    end
  end

  def parse_positive_integer(value, _default) when is_integer(value) and value > 0,
    do: {:ok, value}

  def parse_positive_integer(value, _default),
    do: {:error, "expected a positive integer, got #{inspect(value)}"}

  @doc """
  Same as `parse_positive_integer/2`, but raises on invalid input.
  """
  def parse_positive_integer!(value, default, name) do
    case parse_positive_integer(value, default) do
      {:ok, integer} -> integer
      {:error, message} -> raise "invalid #{name}: #{message}"
    end
  end
end
