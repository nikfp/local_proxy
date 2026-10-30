defmodule LocalProxy.Routing.Validations.DirectionShape do
  @moduledoc false

  use Ash.Resource.Validation

  alias LocalProxy.Routing.Constraints

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    direction = Ash.Changeset.get_attribute(changeset, :direction)
    slug = Ash.Changeset.get_attribute(changeset, :slug)
    path_prefix = Ash.Changeset.get_attribute(changeset, :path_prefix)

    case direction do
      :outbound -> validate_outbound(slug, path_prefix)
      :inbound -> validate_inbound(slug, path_prefix)
      _ -> :ok
    end
  end

  defp validate_outbound(nil, _path_prefix) do
    {:error, field: :slug, message: "is required for outbound routes"}
  end

  defp validate_outbound(_slug, path_prefix) when not is_nil(path_prefix) do
    {:error, field: :path_prefix, message: "must be empty for outbound routes"}
  end

  defp validate_outbound(slug, nil) do
    cond do
      not String.match?(slug, Constraints.slug_format()) ->
        {:error,
         field: :slug, message: "must contain only lowercase letters, digits, and hyphens"}

      Constraints.reserved_slug?(slug) ->
        {:error, field: :slug, message: "is reserved"}

      true ->
        :ok
    end
  end

  defp validate_inbound(_slug, nil) do
    {:error, field: :path_prefix, message: "is required for inbound routes"}
  end

  defp validate_inbound(slug, _path_prefix) when not is_nil(slug) do
    {:error, field: :slug, message: "must be empty for inbound routes"}
  end

  defp validate_inbound(nil, path_prefix) do
    cond do
      path_prefix == "/" ->
        {:error, field: :path_prefix, message: "must not be /"}

      not String.starts_with?(path_prefix, "/") ->
        {:error, field: :path_prefix, message: "must start with /"}

      String.ends_with?(path_prefix, "/") ->
        {:error, field: :path_prefix, message: "must not end with /"}

      String.contains?(path_prefix, ["?", "#"]) ->
        {:error, field: :path_prefix, message: "must not contain a query or fragment"}

      String.contains?(path_prefix, "//") ->
        {:error, field: :path_prefix, message: "must not contain empty segments"}

      not String.match?(path_prefix, Constraints.path_prefix_format()) ->
        {:error, field: :path_prefix, message: "contains unsupported characters"}

      Constraints.reserved_prefix?(path_prefix) ->
        {:error, field: :path_prefix, message: "conflicts with a reserved application path"}

      true ->
        :ok
    end
  end
end
