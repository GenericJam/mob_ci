%{
  name: :mob_ci_clash_a,
  mob_version: "~> 0.7",
  plugin_spec_version: 1,
  description: "CI fixture: deliberately collides with mob_ci_clash_b to exercise P1.",

  # Same default_route, same NIF module, and same component atom as clash_b.
  # cross_validate must reject this pair on all three; the build must fail at
  # validate with those values named (never silently link them).
  screens: [
    %{module: MobCiClashA.HomeScreen, default_route: "/mob_ci_clash/home"}
  ],
  nifs: [
    %{module: :mob_ci_clash_nif, native_dir: "priv/native/jni"}
  ],
  ui_components: [
    %{tag: "ClashWidget", atom: :mob_ci_clash_widget, props: [:label],
      ios: %{view_module: "MobCiClash_View"}, android: %{composable: "MobCiClash_View"}}
  ]
}
