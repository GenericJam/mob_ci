defmodule MobCiPalette do
  @moduledoc """
  Tier-0 mob plugin: pure-Elixir, no manifest, hot-pushable.

  A regular Hex package depending on `:mob`. mob_dev treats it as an
  ordinary dependency; it shows in `mix mob.plugins` only once activated
  in the host's `mob.exs`:

      config :mob, :plugins, [:mob_ci_palette]

  Replace `hello/0` with your plugin's API.
  """

  @doc "Example helper — replace with your plugin's real API."
  def hello, do: :ok
end
