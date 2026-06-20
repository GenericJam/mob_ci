defmodule MobCiGauge.View do
  @moduledoc """
  `Mob.Component` for MobCiGauge. Native registration key is
  `"MobCiGauge_View"` (the convention in `Mob.Component`'s docs).
  """
  use Mob.Component

  @impl true
  def mount(props, socket) do
    {:ok, Mob.Socket.assign(socket, :label, props[:label] || "Hello from MobCiGauge")}
  end

  @impl true
  def update(props, socket) do
    {:ok, Mob.Socket.assign(socket, :label, props[:label] || socket.assigns.label)}
  end

  @impl true
  def render(assigns) do
    %{label: assigns.label}
  end
end
