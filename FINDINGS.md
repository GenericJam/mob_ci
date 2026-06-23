# mob_ci findings — bugs the CI surfaced before users hit them

Running log of real defects found by building/exercising the ecosystem. Each is
the kind of thing that previously only surfaced when a user (or an agent) hit it.

## F1 — `mix mob.new_plugin` scaffolds plugins pinned to `mob ~> 0.6`, incompatible with mob 0.7

- **Upstream:** [GenericJam/mob_dev#21](https://github.com/GenericJam/mob_dev/issues/21)
- **Found:** 2026-06-19, first harness build.
- **Where:** `MobDev.Plugin.Scaffold` (mob_dev 0.6.5) emits `mob_version: "~> 0.6"`
  in the manifest and `{:mob, "~> 0.6"}` in `mix.exs` for every tier.
- **Impact:** the current published mob is **0.7.1**. A freshly scaffolded plugin
  fails activation — `Validator.validate_plugin/3` reports `installed :mob 0.7.1
  does not satisfy mob_version "~> 0.6"`, and `mix deps.get` resolves an old mob.
  A user running `mix mob.new_plugin` today gets a plugin that won't build against
  current mob.
- **Fix:** bump the scaffold templates to `~> 0.7` (or derive from the installed
  mob version at scaffold time so this can't lag again).
- **Workaround in mob_ci:** fixtures bumped to `~> 0.7`.

## F2 — `mix mob.new_plugin --tier 2` generates a plugin that does not compile

- **Upstream:** [GenericJam/mob_dev#22](https://github.com/GenericJam/mob_dev/issues/22)
- **Found:** 2026-06-19, first harness build.
- **Where:** `MobDev.Plugin.Scaffold.tier2_lib/2`. The generated `lib/<name>.ex`
  `@moduledoc """ … """` contains an example that nests a `~MOB""" … """`
  heredoc. The inner `"""` **terminates the moduledoc heredoc early**, so the
  prose after it is parsed as code:

  ```
  ** (SyntaxError) unexpected token: "`" (column 16)
     15 │   The matching `MobCiGauge.View` (`use Mob.Component`) owns Elixir-side state.
  ```

- **Impact:** `mix mob.new_plugin --tier 2 <name>` produces a project that fails
  `mix compile` out of the box. Every tier-2 plugin author hits this immediately.
- **Fix:** in `tier2_lib/2`, use `@moduledoc ~S"""…"""` and avoid nesting a `"""`
  heredoc inside it (the fixture inlines the example instead). The scaffold's own
  doc claims "a freshly scaffolded plugin compiles + activates" — tier-2 does not.
- **Workaround in mob_ci:** `fixtures/mob_ci_gauge/lib/mob_ci_gauge.ex` moduledoc
  rewritten to not nest a triple-quote.

## F3 — first-party plugins are inconsistently signed (mob_touch signed, mob_notify not)

- **Found:** 2026-06-20, sloppy_joe realism gate.
- **Where:** the published first-party plugins. `mob_touch` ships signed with the
  release key (`ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=`); `mob_notify`
  is **unsigned** (`mix mob.plugin.sign` never run).
- **Impact:** a host activating both can't satisfy the signature gate with one
  mechanism — signed plugins need `config :mob, :trusted_plugins`, unsigned ones
  need `config :mob, :acknowledge_unsafe_plugins`. A user adding two official
  plugins hits a confusing "one is trusted, the other refuses to build" wall.
- **Fix:** sign all first-party plugins in the release pipeline (or document the
  split). The gate works around it by listing every activated plugin in BOTH
  config keys.
- **Update (2026-06-22, discovery run over the full sloppy_joe set):** the signed
  first-party plugins are **not all signed with the same key**. `mob_touch` and
  `mob_video` share `ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=`, but
  `mob_bluetooth` is signed with a **different** key
  (`ed25519:iIGSryZyTiwFp8a6kUpUd8nIt6Ble3k+pnY6+6AMsZQ=`). Pinning one constant
  fingerprint in `trusted_plugins` trips the gate's **key-rotation** path for the
  odd one out (`{:untrusted, name, actual, trusted}`) — and unlike a missing
  signature, key-rotation is **not** suppressible via `acknowledge_unsafe_plugins`,
  so the build hard-fails. The realism gate only caught this once the full set
  (incl. bluetooth) was activated; the earlier two-plugin gate never hit it.
- **Fix in mob_ci:** `Build.sloppy_joe_mob_exs` now derives each signed plugin's
  real fingerprint from its shipped `priv/mob_plugin.pub` (mirroring
  `MobDev.Plugin.{Verify.load_pubkey, Crypto.fingerprint}`) instead of pinning a
  constant, so multiple keys / future rotations are handled automatically; unsigned
  plugins ship no pubkey, drop out of `trusted_plugins`, and are cleared via
  `acknowledge_unsafe_plugins`.

## F4 — `mob_screencast` has an undeclared hard host_requirement (manifest `<service>`)

- **Found:** 2026-06-22, device_caps discovery run.
- **Where:** `mob_screencast` requires `<service android:name="io.mob.screencast.ScreencastService">`
  in the **host** app's `AndroidManifest.xml`. Without it the **Android build fails**
  (not a runtime degradation) — the plugin can't be activated on an unmodified host.
- **Impact:** activating `mob_screencast` on any host that hasn't hand-edited its
  manifest is an immediate, opaque build failure. There's no scaffold step or
  validator check that surfaces the requirement before the build breaks.
- **Fix:** have the plugin's manifest-merge contribute the `<service>` entry (so it
  composes like other plugins' manifest fragments), or have the validator flag the
  missing host `<service>` with an actionable message.
- **Workaround in mob_ci:** `priv/device_caps.exs` marks `mob_screencast`
  `buildable: false`, so `DeviceCaps.buildable/1` excludes it from auto-discovery
  sets. (sloppy_joe itself ships a `FileProvider`, so camera/photos/video are fine.)
