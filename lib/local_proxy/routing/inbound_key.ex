defmodule LocalProxy.Routing.InboundKey do
  @moduledoc """
  Generates route-scoped inbound bearer keys.
  """

  @spec generate() :: binary()
  def generate do
    Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end
end
