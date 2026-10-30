defmodule LocalProxy.Routing.Loopback do
  @moduledoc """
  Checks that inbound targets point at the local machine.

  Only `localhost`, IPv4 loopback addresses, and `::1` are accepted. Hostnames
  that merely resolve to loopback are rejected because DNS answers can change
  between validation and request time.
  """

  @doc """
  Returns true when `host` is a literal loopback host or `localhost`.
  """
  def loopback_host?(host) when host in ["localhost", "LOCALHOST"], do: true

  def loopback_host?(host) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _ -> false
    end
  end

  def loopback_host?(_host), do: false

  @doc """
  Resolves `localhost` and checks that every answer is a loopback address.

  Literal addresses are checked directly. Returns `:ok` or `{:error, reason}`.
  """
  def resolve_loopback(host) when is_binary(host) do
    cond do
      not loopback_host?(host) ->
        {:error, "must be localhost, an IPv4 loopback address, or ::1"}

      host == "localhost" ->
        resolve_localhost()

      true ->
        :ok
    end
  end

  defp resolve_localhost do
    addresses =
      for family <- [:inet, :inet6],
          {:ok, addrs} <- [:inet.getaddrs(~c"localhost", family)],
          address <- addrs,
          do: address

    case addresses do
      [] ->
        {:error, "localhost could not be resolved to a loopback address"}

      addresses ->
        if Enum.all?(addresses, &loopback_address?/1) do
          :ok
        else
          {:error, "localhost resolved to a non-loopback address"}
        end
    end
  end

  defp loopback_address?({127, _, _, _}), do: true
  defp loopback_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback_address?(_address), do: false
end
