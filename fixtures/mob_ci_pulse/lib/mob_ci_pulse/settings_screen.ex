defmodule MobCiPulse.SettingsScreen do
  @moduledoc "Settings editor screen the host pushes for this plugin."
  use Mob.Screen

  def mount(_params, _session, socket), do: {:ok, socket}

  def render(_assigns) do
    ~MOB"""
    <Column background={:background} padding={:space_lg}>
      <Text text="MobCiPulse settings" text_size={:xl} text_color={:on_surface} />
    </Column>
    """
  end
end
