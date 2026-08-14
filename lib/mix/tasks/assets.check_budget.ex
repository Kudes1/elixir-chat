defmodule Mix.Tasks.Assets.CheckBudget do
  use Mix.Task

  @shortdoc "Checks gzip budgets for production CSS and JavaScript"

  @budgets [
    {"JavaScript", "priv/static/assets/js/app.js", 55 * 1024},
    {"CSS", "priv/static/assets/css/app.css", 20 * 1024}
  ]

  @impl Mix.Task
  def run(_args) do
    Enum.each(@budgets, fn {label, path, budget} ->
      size = path |> File.read!() |> :zlib.gzip() |> byte_size()
      Mix.shell().info("#{label} gzip: #{size} / #{budget} bytes")

      if size > budget do
        Mix.raise("#{label} gzip asset budget exceeded by #{size - budget} bytes")
      end
    end)
  end
end
