defmodule MobCi.MixProject do
  use Mix.Project

  def project do
    [
      app: :mob_ci,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: false,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [extra_applications: [:logger, :eex]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Reused directly: Validator.cross_validate/1 + conflict_surface/0 (P1),
      # Manifest parsing (P6/P7). Path dep — the whole ecosystem lives in ~/code
      # and mob_ci is a dev/CI tool, not a published package.
      {:mob_dev, path: "../mob_dev"},
      # The plugin-combination sweep (milestone 2).
      {:stream_data, "~> 1.1"}
    ]
  end

  defp aliases do
    [
      # mob_ci tests never touch the farm by default; the device-driving suites
      # are tagged :integration and excluded here. `mix test --include integration`
      # runs them (requires the redroid farm + a host BEAM).
      test: ["test --exclude integration"]
    ]
  end
end
