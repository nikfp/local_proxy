defmodule LocalProxy.Routing.Changes.NormalizeHeaders do
  @moduledoc false

  use Ash.Resource.Change

  alias LocalProxy.Routing.Constraints

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.fetch_argument(changeset, :headers) do
      {:ok, headers} -> normalize(changeset, headers)
      :error -> changeset
    end
  end

  defp normalize(changeset, headers) when is_map(headers) do
    Enum.reduce_while(headers, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      with {:ok, name} <- normalize_name(name),
           :ok <- validate_name(name),
           :ok <- validate_value(value) do
        {:cont, {:ok, Map.put(acc, name, value)}}
      else
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, normalized} ->
        Ash.Changeset.set_argument(changeset, :headers, normalized)

      {:error, message} ->
        Ash.Changeset.add_error(changeset, field: :headers, message: message)
    end
  end

  defp normalize(changeset, _headers) do
    Ash.Changeset.add_error(changeset,
      field: :headers,
      message: "must be a map of header names to values"
    )
  end

  defp normalize_name(name) when is_binary(name) do
    {:ok, name |> String.trim() |> String.downcase()}
  end

  defp normalize_name(_name), do: {:error, "header names must be strings"}

  defp validate_name(""), do: {:error, "header names must not be blank"}

  defp validate_name(name) do
    cond do
      not String.match?(name, Constraints.header_name_format()) ->
        {:error, "header name #{inspect(name)} is not a valid HTTP header name"}

      Constraints.forbidden_header?(name) ->
        {:error, "header name #{inspect(name)} is not allowed"}

      true ->
        :ok
    end
  end

  defp validate_value(value) when is_binary(value), do: :ok

  defp validate_value(_value), do: {:error, "header values must be strings"}
end
