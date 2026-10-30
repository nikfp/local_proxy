defmodule LocalProxy.Routing.Validations.TargetUrl do
  @moduledoc false

  use Ash.Resource.Validation

  alias LocalProxy.Routing.Loopback

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    direction = Ash.Changeset.get_attribute(changeset, :direction)
    target_url = Ash.Changeset.get_attribute(changeset, :target_url)

    with {:ok, uri} <- parse(target_url),
         :ok <- validate_shape(uri) do
      validate_loopback(direction, uri)
    else
      {:error, message} -> {:error, field: :target_url, message: message}
    end
  end

  defp parse(nil), do: {:error, "is required"}

  defp parse(value) when is_binary(value) do
    if String.trim(value) == value do
      {:ok, URI.parse(value)}
    else
      {:error, "must not contain leading or trailing whitespace"}
    end
  rescue
    _ -> {:error, "is not a valid URL"}
  end

  defp parse(_value), do: {:error, "must be a URL"}

  defp validate_shape(%URI{} = uri) do
    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, "must start with http:// or https://"}

      is_nil(uri.host) or uri.host == "" ->
        {:error, "must include a host"}

      not is_nil(uri.userinfo) ->
        {:error, "must not include user information"}

      not is_nil(uri.query) ->
        {:error, "must not include a query string"}

      not is_nil(uri.fragment) ->
        {:error, "must not include a fragment"}

      true ->
        :ok
    end
  end

  defp validate_loopback(:inbound, %URI{host: host}) do
    case Loopback.resolve_loopback(host) do
      :ok -> :ok
      {:error, message} -> {:error, message}
    end
  end

  defp validate_loopback(_direction, _uri), do: :ok
end
