defmodule LocalProxyWeb.PageController do
  use LocalProxyWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
