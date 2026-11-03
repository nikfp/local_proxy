defmodule LocalProxyWeb.Plugs.VaultGate do
  @moduledoc """
  Rejects proxy traffic before route lookup while the vault is locked.
  """

  @behaviour Plug

  import Plug.Conn

  alias LocalProxy.Vault.KeyRing

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if KeyRing.locked?() do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(503, Jason.encode!(%{"error" => "vault_locked", "status" => 503}))
      |> halt()
    else
      conn
    end
  end
end
