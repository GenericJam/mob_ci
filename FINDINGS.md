# mob_ci findings — bugs the CI surfaced before users hit them

Running log of real defects found by building/exercising the ecosystem. Each is
the kind of thing that previously only surfaced when a user (or an agent) hit it.

## F1 — `mix mob.new_plugin` scaffolds plugins pinned to `mob ~> 0.6`, incompatible with mob 0.7

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
