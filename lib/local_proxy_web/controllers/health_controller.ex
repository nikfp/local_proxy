defmodule LocalProxyWeb.HealthController do
  @moduledoc false

  use LocalProxyWeb, :controller

  alias LocalProxy.Vault.KeyRing

  def show(conn, _params) do
    body = %{
      "status" => "ok",
      "vault" => if(KeyRing.locked?(), do: "locked", else: "unlocked")
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
  end
end
