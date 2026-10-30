defmodule LocalProxy.Vault do
  @moduledoc """
  Cloak vault used by `LocalProxy.Routing.Route` to encrypt header values.

  The key is decoded and validated in `config/runtime.exs` and stored in the
  application environment, so a missing or malformed `CLOAK_KEY` fails at boot.
  """

  use Cloak.Vault, otp_app: :local_proxy

  @impl GenServer
  def init(config) do
    key =
      :local_proxy
      |> Application.get_env(__MODULE__, [])
      |> Keyword.fetch!(:key)

    config =
      Keyword.put(config, :ciphers,
        default: {
          Cloak.Ciphers.AES.GCM,
          tag: "AES.GCM.V1", key: key, iv_length: 12
        }
      )

    {:ok, config}
  end
end
