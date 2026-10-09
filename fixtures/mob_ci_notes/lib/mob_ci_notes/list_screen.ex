defmodule MobCiNotes.ListScreen do
  @moduledoc """
  Tier-3 plugin screen. The host registers it as a navigable destination at
  boot (by `default_route`); tapping a row pushes the detail screen.
  """
  use Mob.Screen

  # mob >= 0.9 expands `@name` inside ~MOB as an assign, so a module attribute
  # can't be read there; a plain function can.
  defp items, do: ["alpha", "beta", "gamma"]

  def mount(_params, _session, socket), do: {:ok, socket}

  def render(_assigns) do
    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background} padding={:space_lg}>
        <Text text="MobCiNotes" text_size={:xl} text_color={:on_surface} padding={:space_sm} />
        {for item <- items(), do: row(item)}
      </Column>
    </Scroll>
    """
  end

  def handle_event("open", %{"key" => key}, socket) do
    {:noreply, Mob.Socket.push_screen(socket, MobCiNotes.DetailScreen, %{key: key})}
  end

  defp row(item) do
    ~MOB"""
    <Button text={item} background={:primary} text_color={:on_primary}
            padding={:space_md} fill_width={true} on_tap={{self(), {:open, item}}} />
    """
  end
end
