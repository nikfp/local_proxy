defmodule Mix.Tasks.LocalProxy.SetPassword do
  @shortdoc "Creates or rewraps the local proxy vault password"

  @moduledoc """
  Creates the wrapped vault key on first run, or rewraps the existing key with a
  new password.

      mix local_proxy.set_password

  The password is prompted for and never accepted as an argument or environment
  variable. The task starts only the Repo, not the web endpoints.
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl true
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:ash_sqlite)
    {:ok, _} = LocalProxy.Repo.start_link()

    if LocalProxy.Vault.KeyStore.configured?() do
      rotate()
    else
      create()
    end
  end

  defp create do
    password = prompt_password("New password: ")
    confirmation = prompt_password("Confirm password: ")

    if password != confirmation do
      Mix.raise("Passwords do not match.")
    end

    case LocalProxy.Vault.KeyStore.create(password) do
      {:ok, _key} ->
        Mix.shell().info("Vault password created.")

      {:error, reason} ->
        Mix.raise("Could not create the vault password: #{inspect(reason)}")
    end
  end

  defp rotate do
    current = prompt_password("Current password: ")
    password = prompt_password("New password: ")
    confirmation = prompt_password("Confirm password: ")

    if password != confirmation do
      Mix.raise("Passwords do not match.")
    end

    case LocalProxy.Vault.KeyStore.rewrap(current, password) do
      {:ok, _key} ->
        Mix.shell().info("Vault password updated.")

      {:error, :invalid_password} ->
        Mix.raise("Current password is incorrect.")

      {:error, reason} ->
        Mix.raise("Could not update the vault password: #{inspect(reason)}")
    end
  end

  defp prompt_password(label) do
    IO.write(label)
    :io.setopts(:standard_io, echo: false)

    try do
      case IO.gets("") do
        :eof -> Mix.raise("No password supplied.")
        line -> String.trim_trailing(line, "\n")
      end
    after
      :io.setopts(:standard_io, echo: true)
      IO.write("\n")
    end
  end
end
