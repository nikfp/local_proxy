defmodule LocalProxy.Proxy.Request do
  @moduledoc """
  The parts of an incoming request that the forwarder needs.

  `path` is already rewritten relative to the route; it always starts with `/`.
  `headers` is the raw list of `{name, value}` pairs from `Plug.Conn.req_headers`.
  """

  @enforce_keys [:method, :path]
  defstruct method: "GET", path: "/", query: "", headers: [], body: ""

  @type t :: %__MODULE__{
          method: String.t(),
          path: String.t(),
          query: String.t(),
          headers: [{String.t(), String.t()}],
          body: binary()
        }
end
