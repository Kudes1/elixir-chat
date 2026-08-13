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

  defp load_app do
    Application.load(@app)
  end
end
