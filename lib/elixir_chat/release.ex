defmodule ElixirChat.Release do
  @moduledoc "Release tasks invoked by the container before the web server starts."

  @app :elixir_chat

  def migrate do
    load_app()

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def seed do
    load_app()
    Application.ensure_all_started(:elixir_chat)
    Code.eval_file(Application.app_dir(@app, "priv/repo/seeds.exs"))
  end

  def admin do
    load_app()
    Application.ensure_all_started(@app)

    result =
      case System.fetch_env!("ORBIT_ADMIN_COMMAND") do
        "bootstrap" ->
          ElixirChat.Accounts.bootstrap_invitation(
            System.fetch_env!("ORBIT_ADMIN_LOGIN"),
            System.fetch_env!("ORBIT_ADMIN_NAME")
          )

        "transfer" ->
          ElixirChat.Accounts.transfer_admin(System.fetch_env!("ORBIT_ADMIN_LOGIN"))

        "reset" ->
          ElixirChat.Accounts.admin_password_reset()
      end

    case result do
      {:ok, _record, token} -> IO.puts(ElixirChatWeb.InvitationPath.for_token(token))
      {:ok, _record} -> IO.puts("Administrator transferred.")
      {:error, reason} -> raise "admin command failed: #{inspect(reason)}"
    end
  end

  defp load_app do
    Application.load(@app)
  end
end
