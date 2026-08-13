defmodule Mix.Tasks.Orbit.Admin do
  use Mix.Task
  @shortdoc "Bootstrap, transfer, or reset the Orbit administrator"

  def run(args) do
    Mix.Task.run("app.start")

    case args do
      ["bootstrap" | rest] ->
        {opts, _, _} = OptionParser.parse(rest, strict: [login: :string, name: :string])

        with login when is_binary(login) <- opts[:login],
             name when is_binary(name) <- opts[:name],
             {:ok, {_invitation, token}} <- ElixirChat.Accounts.bootstrap_invitation(login, name) do
          Mix.shell().info(invitation_url(token))
        else
          {:error, reason} -> Mix.raise("bootstrap failed: #{inspect(reason)}")
          _ -> Mix.raise("usage: mix orbit.admin bootstrap --login LOGIN --name NAME")
        end

      ["transfer" | rest] ->
        {opts, _, _} = OptionParser.parse(rest, strict: [to_login: :string])

        case ElixirChat.Accounts.transfer_admin(opts[:to_login]) do
          {:ok, _} -> Mix.shell().info("Administrator transferred.")
          {:error, reason} -> Mix.raise("transfer failed: #{inspect(reason)}")
        end

      ["reset"] ->
        case ElixirChat.Accounts.admin_password_reset() do
          {:ok, _, token} -> Mix.shell().info(invitation_url(token))
          {:error, reason} -> Mix.raise("reset failed: #{inspect(reason)}")
        end

      _ ->
        Mix.raise("usage: mix orbit.admin bootstrap|transfer|reset")
    end
  end

  defp invitation_url(token) do
    base = System.get_env("ORBIT_URL", "http://localhost:4000")
    base <> "/invitation/" <> token
  end
end
