defmodule MobCiPulse.Notifications do
  @moduledoc "Notification handler — invoked when an incoming payload matches."

  @doc "Handles a notification payload routed here by the host dispatcher."
  def handle(_payload), do: :ok
end
