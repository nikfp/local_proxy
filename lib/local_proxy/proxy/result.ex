defmodule LocalProxy.Proxy.Result do
  @moduledoc """
  A successful upstream response.
  """

  @enforce_keys [:status, :body, :duration_ms]
  defstruct status: 200, headers: [], body: "", duration_ms: 0

  @type t :: %__MODULE__{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          body: binary(),
          duration_ms: non_neg_integer()
        }
end
