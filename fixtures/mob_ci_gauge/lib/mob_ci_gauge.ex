defmodule MobCiGauge do
  @moduledoc ~S"""
  Tier-2 mob plugin: a native UI component.

  Wraps `Mob.UI.native_view` so a host screen can embed
  `{MobCiGauge.widget(id: :w)}` inside a `~MOB` sigil. The matching
  `MobCiGauge.View` (`use Mob.Component`) owns Elixir-side state. The host's
  `MobBridge.kt` registers the Kotlin factory under `"MobCiGauge_View"`
  (Elixir-module name stripped of `Elixir.`, dots → underscores — the
  convention `Mob.Component` documents).

  NOTE: the `mix mob.new_plugin --tier 2` scaffold emits a `@moduledoc` whose
  example nests a `~MOB\"""…\"""` heredoc inside the doc's own `\"""…\"""`,
  which terminates the moduledoc early and fails to compile. This fixture works
  around it; the real fix belongs in `MobDev.Plugin.Scaffold.tier2_lib/2`.
  """

  @doc """
  Returns a `Mob.UI.native_view` node for the component. `:id` is required
  and must be unique on the screen.
  """
  def widget(opts \\ []) do
    {id, props} = Keyword.pop(opts, :id)

    unless is_atom(id) and not is_nil(id) do
      raise ArgumentError, "MobCiGauge.widget/1 requires an :id atom"
    end

    Mob.UI.native_view(MobCiGauge.View, [{:id, id} | props])
  end
end
