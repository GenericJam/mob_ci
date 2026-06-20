defmodule MobCiNotes.DetailScreen do
  @moduledoc "Tier-3 plugin detail screen, pushed from the list screen."
  use Mob.Screen

  def mount(params, _session, socket) do
    {:ok, Mob.Socket.assign(socket, :key, params[:key] || params["key"] || "?")}
  end

  def render(assigns) do
    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background} padding={:space_lg}>
        <Text text={"key: " <> assigns.key} text_size={:lg} text_color={:on_surface} padding={4} />
        <Button text="Back" background={:primary} text_color={:on_primary}
                padding={:space_md} on_tap={{self(), :back}} />
      </Column>
    </Scroll>
    """
  end

  def handle_event("back", _params, socket), do: {:noreply, Mob.Socket.pop_screen(socket)}
end
