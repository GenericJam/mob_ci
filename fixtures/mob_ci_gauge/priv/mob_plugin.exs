%{
  name: :mob_ci_gauge,
  mob_version: "~> 0.6",
  plugin_spec_version: 1,
  description: "TODO: describe your plugin",

  ui_components: [
    %{
      tag: "MobCiGauge",
      atom: :mob_ci_gauge,
      props: [:label],
      # Native registration name = `<Elixir module>`, stripped of `Elixir.`
      # with dots → `_`. Matches what `Mob.Component` emits as the
      # `:module` prop at render time, and what `MobNativeViewRegistry`
      # looks up.
      ios: %{view_module: "MobCiGauge_View"},
      android: %{composable: "MobCiGauge_View"}
    }
  ]
}
