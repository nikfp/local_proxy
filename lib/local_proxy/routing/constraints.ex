defmodule LocalProxy.Routing.Constraints do
  @moduledoc false

  @reserved_slugs ~w(new edit admin health)
  @reserved_prefix_segments ~w(r routes admin health live assets dev)

  @slug_format ~r/^[a-z0-9-]+$/
  @path_prefix_format ~r{^/[A-Za-z0-9._~!$&'()*+,;=:@%/-]*$}
  @header_name_format ~r/^[!#$%&'*+\-.^_`|~0-9a-z]+$/

  @forbidden_headers ~w(
    host
    content-length
    x-proxy-key
    connection
    keep-alive
    proxy-authenticate
    proxy-authorization
    te
    trailer
    transfer-encoding
    upgrade
  )

  def reserved_slugs, do: @reserved_slugs
  def reserved_prefix_segments, do: @reserved_prefix_segments
  def slug_format, do: @slug_format
  def path_prefix_format, do: @path_prefix_format
  def header_name_format, do: @header_name_format
  def forbidden_headers, do: @forbidden_headers

  def reserved_slug?(slug) when is_binary(slug), do: slug in @reserved_slugs

  def reserved_prefix?(prefix) when is_binary(prefix) do
    case prefix |> String.downcase() |> String.split("/", trim: true) do
      [segment | _] -> segment in @reserved_prefix_segments
      [] -> true
    end
  end

  def forbidden_header?(name) when is_binary(name), do: name in @forbidden_headers
end
