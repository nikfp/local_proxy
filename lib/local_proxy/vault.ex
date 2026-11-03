defmodule LocalProxy.Vault do
  @moduledoc """
  Cloak vault used by `LocalProxy.Routing.Route`.

  The cipher configuration is static and keyless. The data key is read from
  `LocalProxy.Vault.KeyRing` at call time, so the vault does not need a key to
  start and can be locked or unlocked without a restart.
  """

  use Cloak.Vault, otp_app: :local_proxy

  @impl GenServer
  def init(config) do
    ciphers = [
      default: {LocalProxy.Vault.Cipher, tag: "AES.GCM.V1", iv_length: 12}
    ]

    {:ok, Keyword.put(config, :ciphers, ciphers)}
  end
end
