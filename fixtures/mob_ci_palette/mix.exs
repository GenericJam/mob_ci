defmodule MobCiPalette.MixProject do
  use Mix.Project

  def project do
    [
      app: :mob_ci_palette,
      version: "0.1.0",
      elixir: "~> 1.17",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:mob, "~> 0.7"}
    ]
  end
end
