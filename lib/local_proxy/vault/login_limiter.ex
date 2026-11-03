defmodule LocalProxy.Vault.LoginLimiter do
  @moduledoc """
  Small in-memory failed-login limiter.

  This is intentionally per-BEAM and resets on restart. The login form is local
  only, so a persistent store would add complexity without much benefit.
  """

  use GenServer

  @window_seconds 60
  @max_failures 5

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec allowed?(term()) :: boolean()
  def allowed?(key), do: GenServer.call(__MODULE__, {:allowed?, key})

  @spec record_failure(term()) :: non_neg_integer()
  def record_failure(key), do: GenServer.call(__MODULE__, {:record_failure, key})

  @spec reset(term()) :: :ok
  def reset(key), do: GenServer.call(__MODULE__, {:reset, key})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:allowed?, key}, _from, state) do
    failures = prune(Map.get(state, key, []))
    {:reply, length(failures) < @max_failures, Map.put(state, key, failures)}
  end

  def handle_call({:record_failure, key}, _from, state) do
    failures = [now() | prune(Map.get(state, key, []))]
    {:reply, length(failures), Map.put(state, key, failures)}
  end

  def handle_call({:reset, key}, _from, state), do: {:reply, :ok, Map.delete(state, key)}

  defp prune(failures) do
    cutoff = now() - @window_seconds
    Enum.filter(failures, &(&1 > cutoff))
  end

  defp now, do: System.monotonic_time(:second)
end
