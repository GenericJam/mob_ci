%{
  name: :mob_ci_pulse,
  mob_version: "~> 0.6",
  plugin_spec_version: 1,
  description: "TODO: describe your plugin",

  # Lifecycle hooks + supervised children. on_start/on_resume/on_background
  # are {Module, fun, args} MFAs; supervised children join the host's plugin
  # supervisor. A supervised worker's registered name must be unique across
  # activated plugins.
  lifecycle: %{
    on_start: {MobCiPulse, :start, []},
    on_resume: {MobCiPulse, :on_resume, []},
    on_background: {MobCiPulse, :on_background, []},
    supervised: [MobCiPulse.Worker]
  },

  # Typed, per-plugin-namespaced settings (read/written via Mob.Plugins
  # get_setting/3 + put_setting/4, validated against :type). editor_screen
  # is the screen the host pushes to let the user change them.
  settings: %{
    schema: [%{key: :enabled, type: :boolean, default: true}],
    editor_screen: MobCiPulse.SettingsScreen
  },

  # Notification handlers. `match` is a map prefix-matched against the
  # payload (or a 1-arity predicate); the first matching handler across all
  # plugins wins, so two plugins may not declare the identical match.
  notifications: %{
    handlers: [
      %{match: %{type: "mob_ci_pulse"}, handler: {MobCiPulse.Notifications, :handle, 1}}
    ]
  }
}
