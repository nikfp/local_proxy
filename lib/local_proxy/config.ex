defmodule LocalProxy.Config do
  @moduledoc """
  Parses and validates configuration values read from the environment.

  `config/runtime.exs` calls these functions at boot so that invalid values fail
  fast with a clear message instead of surfacing later at request time.
  """

  @default_port 4000

  @doc """
  Parses a port, falling back to `default`.
  """
  def parse_port(value, default \\ @default_port)

  def parse_port(nil, default), do: {:ok, default}

  def parse_port(value, _default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {port, ""} when port in 1..65_535 -> {:ok, port}
      _ -> {:error, "expected an integer between 1 and 65535, got #{inspect(value)}"}
    end
  end

  def parse_port(value, _default) when is_integer(value) and value in 1..65_535, do: {:ok, value}

  def parse_port(value, _default),
    do: {:error, "expected an integer between 1 and 65535, got #{inspect(value)}"}

  @doc """
  Same as `parse_port/2`, but raises on invalid input with the variable name.
  """
  def parse_port!(value, default, name) do
    case parse_port(value, default) do
      {:ok, port} -> port
      {:error, message} -> raise "invalid #{name}: #{message}"
    end
  end

  @doc """
  Ensures the two listeners do not try to bind the same port.
  """
  def ensure_distinct_ports!(outbound_port, inbound_port) do
    if outbound_port == inbound_port do
      raise "OUTBOUND_PORT and INBOUND_PORT must differ, both are #{outbound_port}"
    end

    :ok
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
