%{
  name: :mob_ci_clash_b,
  mob_version: "~> 0.6",
  plugin_spec_version: 1,
  description: "CI fixture: deliberately collides with mob_ci_clash_a to exercise P1.",
  screens: [
    %{module: MobCiClashB.HomeScreen, default_route: "/mob_ci_clash/home"}
  ],
  nifs: [
    %{module: :mob_ci_clash_nif, native_dir: "priv/native/jni"}
  ],
  ui_components: [
    %{tag: "ClashWidget", atom: :mob_ci_clash_widget, props: [:label],
      ios: %{view_module: "MobCiClash_View"}, android: %{composable: "MobCiClash_View"}}
  ]
}
