# P12 self-tests, the release:android cell, the SQLite results store

- Date: 2026-10-08
- Status: accepted
- Linear: MOB-414 (under MOB-410)

## Context

`2026-10-08-revived-version-rows-ios-selftests-matrix.md` §1, §4 and §5
decided three things this record lands for the Android lane: run every
plugin's own self-test over dist as invariant P12 and split plugin from
conflict by comparing with the singleton cell; make the release build path
(`mix mob.release --android`) a cell of its own, because "dev build works,
release doesn't" (MOB-372, MOB-373, MOB-376, MOB-404) is where the recent
bugs were; and keep results in SQLite on the NUC instead of per-run artifact
dirs. MOB-411 shipped the contract (`Mob.Plugin.SelfTest`, mob 0.9.15), the
runner (`MobDev.Plugin.SelfTest.run_all/3` and `grant_permissions/4`,
mob_dev 0.7.17) and three pilots (mob_location, mob_whisper, mob_deliver).
The iOS lane (MOB-415) writes into the same store.

## Decision

### P12 — every active plugin's self-test passes (or skips honestly)

`MobCi.Invariants.p12/1` calls `SelfTest.run_all(node, %{platform: :android,
device: :emulator}, plugins: <the set's manifests>, timeout_ms: 30_000)` and
maps each entry to a `:p12_item` result titled with the plugin:

| `run_all` entry | P12 item |
|---|---|
| `:pass` | pass |
| `{:skip, :needs_hardware \| :needs_user \| reason}` | skip with that reason |
| no `selftest:` in the manifest | skip, reason `no_selftest` (23 plugins on 2026-10-08; MOB-418 adds them) |
| `{:fail, reason}`, including a raise, a timeout, a missing module | fail |
| `{:fail, "node … is not reachable"}` / `"could not spawn on …"` | error @ `boot` (the call never reached the device) |

The items roll up the usual way (any fail fails P12, skips never do) and
stay on the result as `evidence.items`, so the store keeps one row per
plugin (`p12:<plugin>`). A failure is attributed by
`Invariants.p12_layer/3` against the newest stored outcome of the same
plugin's self-test in its `singleton:<p>` cell on the same versions row,
platform and path (`Store.singleton_selftest/3`):

- in the singleton cell itself, or failing there too → `plugin:<p>`;
- passing there → `conflict:<set>`;
- no singleton answer (never ran, skipped, errored) → `plugin:<p>?`, a new
  layer `{:plugin_unconfirmed, p}`: the plugin is the likely suspect, but
  nobody has shown it fails alone. Running the singleton turns it into one
  of the other two on the next run.

The lookup is the store, not a fresh singleton run: the nightly runs every
singleton anyway, and a failing large set must not trigger N extra builds.

**Permissions** are granted between install and launch, on both paths
(`Farm.grant_permissions/4`, `adb shell pm grant` per manifest
`android.permissions`): mob_dev documents that changing a running app's
grants can kill it, and a self-test must never meet a system prompt. The
sweep grants the same way. A non-runtime permission's refusal is logged,
not fatal.

### The `release:android` cell

A cell now has build paths (`--paths deploy,release`; a cell runs both by
default, the fixture harness and sloppy_joe only `deploy`):

- `deploy:android` — unchanged: `mix mob.deploy --native --device`, P1–P12.
- `release:android` — `mix mob.release --android` in the same generated
  host, then bundletool `build-apks --mode=universal` (mob_dev produces only
  the AAB; nothing in the ecosystem installed a release build before) into
  one APK, installed on a **fresh** redroid (no debug-pushed OTP or app data
  can shadow it), probed with P2, P12, P10 and P11.

Findings that shaped it (code read 2026-10-08):

1. The Android release starts distribution exactly like the debug build and
   reads the same `mob_node_suffix` / `mob_dist_port` intent extras (only iOS
   sets `MOB_RELEASE`), so `ci-farm.sh launch` works unchanged.
2. A release APK has **no dist cookie**: mob_dev writes the managed cookie to
   `files/otp/<app>/mob_dist_cookie` at deploy, and the release path never
   does; the first launch's `otp.zip` extraction also wipes `files/otp`. So
   mob_ci launches once, waits for `files/otp/.installed_version`, stops the
   app, writes the cookie as root with the app's uid and the data dir's
   SELinux label (`run-as` is refused: release builds are not debuggable),
   then launches for real (`Farm.provision_release/2`).
3. The generated `build.gradle` signs the release only when
   `android/keystore.properties` exists. mob_ci writes a throwaway JKS upload
   key in the shape `mix mob.google_play` writes (alias `upload`,
   `upload_jks.keystore`) into the gitignored host, so the release is signed
   the way a user's is; bundletool signs the universal APK with the same key.
4. The template's `abiFilters` include x86_64, so the release carries the
   x86_64 `lib<app>.so` the farm runs; `otp.zip` is the arm64 OTP tree,
   which works because the BEAM is linked into the per-ABI `.so` and the
   ERTS helpers ride in `jniLibs/<abi>`. The release path also *compiles*
   arm64 and armv7 — the farm proves those build, not that they run.

**Attribution.** A path that fails outright is an error cell with layer
`build:deploy:android` or `build:release:android`, extended to
`build:<path>/<plugin>` when mob_dev's output names the plugin
(`Build.failing_plugin/1`: a signature-gate refusal, mob_dev's
`plugin :mob_x` wording, or a compiler error inside `deps/mob_x/`). A
release APK the device refuses to install is `build:release:android` too.
This replaces the old `{:build, host_dir}` for build-step failures (still
used by invariants that point at the host: P1, P5, P6, P7).

### The results store

`MobCi.Store`, SQLite through `exqlite`, one file per machine:
`~/.local/share/mob_ci/results.sqlite`, `MOB_CI_STORE` / `--store`
override. Schema (`priv/schema.sql`, `PRAGMA user_version` 1):

- `runs(id, started_at, trigger, versions_row, host, mob_ci_sha)`;
- `cells(run_id, set, platform, path, invariant, layer, outcome, duration_ms,
  log_path, detail json, versions json)`, with `outcome` constrained to
  pass | fail | skip | error.

The one addition to the planned columns is `invariant`: NULL is the cell's
summary row (outcome rolled up: fail > error > pass, all-skip = skip; layer
`Result.attribute/1` of the non-passing results), the other rows of the same
(run, set, platform, path) are its invariants (`p2`, `p12`) and its plugins'
self-tests (`p12:mob_location`). That keeps the grid a plain `WHERE
invariant IS NULL` and the P12 singleton lookup a plain equality, without a
second table. Every schema statement is `IF NOT EXISTS`, so `open/1`
migrates on every open; a later change adds a step keyed on `user_version`.
WAL mode and a 10 s busy timeout let the iOS lane and an Android run write
the same file.

Every `mix ci.device` and `mix ci.sweep` run records: device cells per path,
`--static` as path `static` / platform `all`, each device-sweep subset as
set `sweep:<plugins>`, a host generation failure as an error cell per path
at layer `mob_new` / `elixir`. The `--artifacts` dir keeps `junit.xml`
(now spanning both paths, test names prefixed `[path]`), `summary.json`,
`timings.json` (release steps are `release:build`, `release:boot`, …) and
`deploy.log` / `release.log`, whose paths the cells record.

`Store.query/2` (filters: run_id, versions_row, set, platform, path,
outcome, trigger, invariant — `nil` for summaries —, `latest`, `limit`) is
the read API; `mix ci.report` prints the latest grid per versions row with
it, and MOB-417's `matrix.md` builds on it.

## Consequences

- P12 makes mob_ci stop guessing at plugin internals as the self-tests
  land: P3's probe table can shrink once a plugin's self-test covers its
  NIF.
- The release cell doubles a cell's device time and adds the release build
  (see `docs/budgets.md`); `--paths deploy` keeps the old cost where the
  release adds nothing (pairwise rows).
- A `hex` row reports `no_selftest` for a plugin whose self-test is merged
  but not released; that is accurate (it is what a user gets) and the
  `master` row shows the self-test.
- Results now accumulate on the NUC; nothing prunes them yet. At a few
  hundred rows per nightly the file stays small for years.
