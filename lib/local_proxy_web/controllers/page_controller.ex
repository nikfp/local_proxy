defmodule LocalProxyWeb.PageController do
  @moduledoc false

  use LocalProxyWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/routes")
  end
end
