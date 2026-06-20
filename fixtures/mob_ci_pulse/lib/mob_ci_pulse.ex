defmodule MobCiPulse do
  @moduledoc """
  Tier-4 sub-app plugin: lifecycle hooks + a supervised worker + settings +
  a notification handler. The host runs `on_start` at boot (under the plugin
  supervisor), starts the `supervised` children, and calls `on_resume` /
  `on_background` on OS foreground/background transitions.
  """

  @doc "lifecycle.on_start — runs once at boot under the plugin supervisor."
  def start, do: :ok

  @doc "lifecycle.on_resume — host came to the foreground."
  def on_resume, do: :ok

  @doc "lifecycle.on_background — host went to the background."
  def on_background, do: :ok
end
