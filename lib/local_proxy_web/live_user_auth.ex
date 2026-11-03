defmodule LocalProxyWeb.LiveUserAuth do
  @moduledoc """
  LiveView mount hook that mirrors `RequireAuth` and the unlock generation.
  """

  import Phoenix.LiveView

  alias LocalProxy.Vault.KeyRing

  def on_mount(:ensure_unlocked, _params, session, socket) do
    generation = session_value(session, :unlock_generation)
    authenticated = session_value(session, :admin_authenticated) == true

    if authenticated and match?({:ok, ^generation}, KeyRing.generation()) do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/login")}
    end
  end

  defp session_value(session, key) do
    Map.get(session, Atom.to_string(key), Map.get(session, key))
  end
end
