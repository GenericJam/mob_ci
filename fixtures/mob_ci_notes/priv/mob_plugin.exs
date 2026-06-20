%{
  name: :mob_ci_notes,
  mob_version: "~> 0.7",
  plugin_spec_version: 1,
  description: "TODO: describe your plugin",

  # Whole screens the host can navigate to. Registered by default_route at
  # boot; two distinct plugins may not claim the same route (cross-plugin
  # validation rejects it — see MOB_PLUGINS.md "Cross-plugin conflict detection").
  screens: [
    %{module: MobCiNotes.ListScreen, default_route: "/mob_ci_notes/list"},
    %{module: MobCiNotes.DetailScreen, default_route: "/mob_ci_notes/detail"}
  ],

  # Ecto migrations the plugin ships. mob_dev copies them into the host's
  # migrations dir at `--native` build, prefixing each with repo_namespace
  # (so vendors don't collide); the host's Ecto.Migrator runs them. The
  # repo_namespace must be unique across activated plugins.
  migrations: %{
    repo_namespace: "mob_ci_notes_",
    migrations_dir: "priv/repo/migrations"
  }

  # Optional tier-3 assets — add real files then uncomment:
  #
  #   assets: %{
  #     fonts: ["priv/fonts/MyFont.ttf"],   # registered (iOS UIAppFonts / Android res/font)
  #     images: ["priv/assets/icon.png"]    # addressable via plugin://mob_ci_notes/icon.png
  #   }
}
