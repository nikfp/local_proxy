defmodule LocalProxyWeb.HealthController do
  @moduledoc false

  use LocalProxyWeb, :controller

  def show(conn, _params) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, ~s({"status":"ok"}))
  end
end
