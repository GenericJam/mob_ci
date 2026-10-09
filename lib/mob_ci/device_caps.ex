defmodule MobCi.DeviceCaps do
  @moduledoc """
  The per-plugin device-capability baseline (`priv/device_caps.exs`): safe NIF
  init-probes and DemoScreen expectations for a headless x86_64 redroid.

  Two jobs:

    * feed `Context.nif_probes` so P3 can confirm a real plugin's NIF actually
      *initialized* (via a safe `*_stop`/`*_cancel` export), turning P3 from a
      "loaded, unconfirmed → skip" into a real pass for hardware plugins;

    * feed `Context.screen_caps` so P4 treats a *graceful* degradation on a
      hardware-less emulator (a screen that renders an error state, or whose
      mount errors) as a `:skip`, while a genuine BEAM crash stays a `:fail`.

  The table is data, refined by the discovery run. Unknown plugins (no entry)
  get no probe and a `nil` screen expectation — the conservative default.
  """

  @caps_path Path.expand("../../priv/device_caps.exs", __DIR__)

  @doc "The raw capability table (plugin → %{nif, probe, screen, note})."
  @spec table() :: %{atom() => map()}
  def table do
    {caps, _} = Code.eval_file(@caps_path)
    caps
  end

  @doc "Capability entry for a plugin, or `nil` if unclassified."
  @spec for_plugin(atom()) :: map() | nil
  def for_plugin(plugin), do: Map.get(table(), plugin)

  @doc """
  Is a plugin buildable on an unmodified host? `false` for plugins the CI farm
  can't build or load (e.g. mob_nx_eigen's arm-only NIF on the x86_64 redroid).
  Unclassified/missing → buildable (the optimistic default).
  """
  @spec buildable?(atom()) :: boolean()
  def buildable?(plugin) do
    case for_plugin(plugin) do
      %{buildable: false} -> false
      _ -> true
    end
  end

  @doc "Filter a set to the plugins buildable on an unmodified host (for discovery)."
  @spec buildable([atom()]) :: [atom()]
  def buildable(set), do: Enum.filter(set, &buildable?/1)

  @doc """
  NIF probes for a plugin set, keyed by NIF module (the shape `Context.nif_probes`
  wants): `%{nif_module => {fun, args}}`. Plugins with no safe probe are omitted.
  """
  @spec nif_probes([atom()]) :: %{atom() => {atom(), [term()]}}
  def nif_probes(set) do
    for plugin <- set,
        entry = for_plugin(plugin),
        is_map(entry),
        probe = entry[:probe],
        not is_nil(probe),
        into: %{},
        do: {entry[:nif], probe}
  end

  @doc """
  DemoScreen expectations for a plugin set, keyed by the screen MODULE (so P4 can
  look up the expectation for the screen it's about to push). Resolves each
  plugin's screen module from its manifest. Plugins with no screen are omitted.
  """
  @spec screen_caps([atom()]) :: %{module() => :emulator_ok | :hardware_degraded}
  def screen_caps(set) do
    for plugin <- set,
        entry = for_plugin(plugin),
        is_map(entry),
        expectation = entry[:screen],
        not is_nil(expectation),
        module <- screen_modules(plugin),
        into: %{},
        do: {module, expectation}
  end

  defp screen_modules(plugin) do
    case MobCi.Plugins.load_manifest(plugin) do
      m when is_map(m) ->
        for s <- Map.get(m, :screens, []), is_map(s), mod = s[:module], is_atom(mod), do: mod

      _ ->
        []
    end
  end
end
