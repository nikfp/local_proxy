defmodule LocalProxy.Routing.Validations.InboundKey do
  @moduledoc false

  use Ash.Resource.Validation

  @min_length 32
  @max_length 256

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    direction = Ash.Changeset.get_attribute(changeset, :direction)
    enabled = Ash.Changeset.get_attribute(changeset, :enabled)
    argument = Ash.Changeset.fetch_argument(changeset, :inbound_key)

    case direction do
      :outbound -> validate_outbound(argument)
      :inbound -> validate_inbound(argument, enabled, changeset)
      _ -> :ok
    end
  end

  defp validate_outbound({:ok, nil}), do: :ok
  defp validate_outbound(:error), do: :ok

  defp validate_outbound({:ok, _key}) do
    {:error, field: :inbound_key, message: "must be empty for outbound routes"}
  end

  defp validate_inbound({:ok, nil}, true, _changeset) do
    {:error, field: :inbound_key, message: "is required for enabled inbound routes"}
  end

  defp validate_inbound({:ok, nil}, _enabled, _changeset), do: :ok
  defp validate_inbound({:ok, key}, _enabled, _changeset), do: validate_text(key)

  defp validate_inbound(:error, true, %{data: %{id: nil}}) do
    {:error, field: :inbound_key, message: "is required for enabled inbound routes"}
  end

  defp validate_inbound(:error, _enabled, _changeset), do: :ok

  defp validate_text(key) when is_binary(key) do
    cond do
      String.trim(key) != key ->
        {:error, field: :inbound_key, message: "must not contain surrounding whitespace"}

      String.contains?(key, [" ", "\t", "\n", "\r"]) ->
        {:error, field: :inbound_key, message: "must not contain whitespace"}

      byte_size(key) < @min_length ->
        {:error, field: :inbound_key, message: "must be at least #{@min_length} characters"}

      byte_size(key) > @max_length ->
        {:error, field: :inbound_key, message: "must be at most #{@max_length} characters"}

      true ->
        :ok
    end
  end

  defp validate_text(_key) do
    {:error, field: :inbound_key, message: "must be a string"}
  end
end
