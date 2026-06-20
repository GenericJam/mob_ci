defmodule MobCiGauge do
  @moduledoc """
  Tier-2 mob plugin: a native UI component.

  Wraps `Mob.UI.native_view` so a host screen can write:

      use Mob.Sigil

      ~MOB"""
      <Column>
        {MobCiGauge.widget(id: :w)}
      </Column>
      """

  The matching `MobCiGauge.View` (`use Mob.Component`) owns Elixir-side state.
  The host's `MobBridge.kt` registers the Kotlin factory under
  `"MobCiGauge_View"` (Elixir-module name stripped of `Elixir.` with dots →
  underscores — the convention `Mob.Component` documents).
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
