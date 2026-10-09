# The iOS lane: the Mac mini as an ssh worker

- Date: 2026-10-08
- Status: accepted
- Linear: MOB-415 (under MOB-410)

## Context

`2026-10-08-revived-version-rows-ios-selftests-matrix.md` §4 decided that iOS
cells run on the Mac mini, driven from the NUC over ssh, one host at a time,
on a Mac with single-digit GB free. iOS builds need Xcode, the signing
keychain (`Apple Distribution: Kevin Edey (Q89CW299G8)`) and the simulators,
all of which belong to the `kevin` account on the Mac; the NUC has none of
them. The Mac is also shared: several agents deploy to its simulators and
Kevin's iPhone through `agent-lease` at any time.

## Decision

### Split: the NUC plans, the Mac builds and runs

`MobCi.Lane.Ios` (NUC) plans the cell with `MobCi.Cell.plan/3` (so the row is
resolved to exact pins once, where every other cell is resolved), runs the
static gate (`cross_validate`; a rejected set never leaves the NUC, layer
`static`), and sends each path to the Mac as a `MobCi.Lane.Ios.Spec`: set,
plugins, `MobCi.Versions.record/1`, path, udid, `min_runtime`, mob_ci sha.
The worker re-materialises only what it must from those pins (mob_new's
tarball, a checkout per git pin) and never re-resolves a row, so a `hex`
release published between planning and building cannot split a cell.

### Transport: two ssh sessions, everything on the command line

`ssh -o BatchMode=yes kevin@10.0.0.71`, key auth only. Per run, one session
runs `worker/mac/sync.sh`, shipped base64 on the command line, which keeps the
worker's own clones under `~/.cache/mob_ci/worker/` (mob_ci at the NUC's sha,
mob_dev at its default branch): nothing is installed on the Mac beforehand
and the worker never builds from Kevin's `~/code` trees, which may be on any
branch. Per path, one session runs `mob_ci_ios_cell.sh --spec-b64 <spec>`.
Base64 keeps remote quoting out of it, and avoids stdin, which `System.cmd`
cannot half-close. The session's output streams to
`~/mob_ci_logs/ios/<cell_id>.log`; the worker's last line, `MOB_CI_RESULT
<json>`, is the result, also written beside the log. A session that ends
without one is an `error` at `error:ssh` with the exit code and log tail.

No launchd job: a cell runs only because a NUC session started it. It is not
tied to that session, though; see "When the NUC side goes away" below.

### The worker: a step list with one teardown

`MobCi.Lane.Ios.Worker` runs, in order: `disk` (refuse under 5 GB free on
`/`, `df -k /`), `resolve`, `generate` (`MobCi.Host.generate/4` with
`platform: :ios`, the row's mob_new run with `--ios`), `doctor`
(`mix mob.doctor`), then per path:

- `deploy:ios_sim` / `deploy:ios_device`: `device`, `lease` (`agent-lease
  acquire`), `build` (`mix mob.deploy --native --ios --device <udid>`), and
  `probe` — `worker/mac/probe.exs` run with `mix run --no-start` inside the
  generated host, so it uses the row's own mob_dev: grant every declared
  permission (`MobDev.Plugin.SelfTest.grant_permissions/4`) before
  relaunching (a simulator may kill an app whose privacy settings change),
  relaunch and attach (`MobDev.Connector.connect_all/1`), read
  `Mob.Diag.health/0`, run `SelfTest.run_all/3`, read health again
  (`MobDev.Smoke.health_findings/2`). Lease comes before the build because
  `mob.deploy` installs as it builds.
- `release:ios`: `build` (`mix mob.regen_driver_tab --format c`, `mix
  mob.release --ios`) and `artifact` (exactly one `.ipa`, a zip with a signed
  `Payload/*.app`; name, size, sha256 recorded).

Each step's failure has a layer: `mob_new` / `elixir` (generation),
`doctor`, `boot` (no device, no lease on a simulator, node not up),
`build:<path>`, then from the probe `p2` (`boot`), `p12:<plugin>`
(`plugin:<p>` in a singleton set, `plugin:<p>?` otherwise until the NUC
compares with the plugin's singleton cell, `MobCi.Invariants.p12_layer/3`)
and `health`. Problems of the worker itself are `error:disk`,
`error:worker`, `error:ssh`. A step that raises is an `error` at the layer
its own failure would have had. The iPhone not attached or held by another
agent is `skip: device_absent`, not a failure.

Teardown runs whatever happened: uninstall from a device the cell leased,
release the lease (whenever one was attempted: a failed acquire may have
started its daemon), delete the app's staged BEAMs under
`~/.mob/{cache/otp-ios-*,runtime/ios-*}/<app>` and the cell's scratch dir,
then record free disk. The scratch dir holds the host (with `deps` and
`_build`) and `tmp/`, which is every child's `TMPDIR`, so mob_dev's
`mob_ios_*` dirs land inside it. macOS `mktemp -d` ignores `TMPDIR`, and
mob_dev's release script leaks its build dir that way (FINDINGS F11,
MOB-425), so teardown also removes `$(getconf DARWIN_USER_TEMP_DIR)/tmp.*`
dirs holding the cell's own `Ci<App>.app`. `ci_*` app names belong to mob_ci
alone, which is what makes these deletions safe on a shared Mac.

### When the NUC side goes away (MOB-466, 2026-10-09)

The first version ran the worker inside the ssh session. A NUC side that
went away mid-cell (the drain unit stopped, `ci-run.sh pause ios`, the link
dropped) took the worker with it, by SIGPIPE on its closed stdout, before
teardown ran: the agent-lease claim stayed held (blocking every other
agent), zig/gradle kept building, and the scratch dir and staged BEAMs
stayed.

Now `mob_ci_ios_cell.sh` hands the cell to `worker/mac/guard.sh`, which
starts a guard in a session of its own (`setsid`, through perl) with its
output in `~/mob_ci_logs/mac-worker/<run>.log`, and streams that log back to
the ssh session. The NUC's transport (`MobCi.Lane.Ios.ssh/3`) writes a
heartbeat line to the session's stdin every 10 s. The guard stops the cell
when its stdin closes or the session's side gets SIGHUP, SIGTERM or SIGPIPE
(the NUC process or ssh died), when it gets SIGHUP/SIGTERM itself, or when
no heartbeat came for 60 s (a link that dropped without closing). Then, and
when the worker ends on its own, it runs the same teardown,
`mix ci.ios_cell --teardown <run dir>` (`MobCi.Lane.Ios.Reaper.teardown_run/2`):

- stop the run's processes: every process whose environment carries
  `MOB_CI_RUN=<run>`, which the guard gives the worker and every child
  inherits, and all their descendants (macOS shows `ps -E` no environment
  for Apple's own binaries: `/bin/sh`, xcodebuild, clang). A process group
  would not do: the BEAM gives each port program (mix, zig, gradle,
  xcodebuild) a session of its own. One snapshot of the process table,
  SIGTERM to all, SIGKILL after 10 s. Never `pkill` by name, and never the
  adb server or epmd, which a cell may have started but every agent shares;
- undo every cell whose manifest is left in `<run dir>/cells/`: the worker
  writes one before its first step and after each (spec, scratch, lease
  attempted/held, device, host) and removes it after its own teardown, so
  a killed cell is undone exactly as a finished one (uninstall, release,
  app state, scratch);
- stop what is still tagged, the lease's agent-device daemon last, so the
  release could still talk to it.

Gradle runs without its long-lived daemon (`-Dorg.gradle.daemon=false`): a
cell's daemon would outlive the cell, and another agent's build could pick
it up before teardown stopped it.

A guard can still die without teardown (SIGKILL, a reboot). So every cell
first reaps (`Reaper.reap/2`): a run whose guard is gone, or has not stamped
`<run dir>/alive` for 2 minutes, is torn down as above; a process tagged
with a run that is not live is stopped; `mob_ci_ios_*` agent-lease sessions
(state dirs under `~/.agent-device/agents/`, claims in `agent-device device
status`) that no live cell owns are released and their state dirs pruned;
cell scratch dirs, `ci_*` staged BEAMs and leaked `tmp.*/Ci*.app` dirs no
live cell owns are deleted. The ones not tied to a dead run must also be
idle for 30 minutes (`MOB_CI_REAP_AFTER_S`). A hand run of `mix
ci.ios_cell` registers a run of its own, so it is protected and reaped the
same way.

### Bundle ids and signing

Simulator and iPhone builds use `com.genericjam.mobci`: covered by the team's
wildcard development profile, and used by no installed app, so uninstall can
only remove what a cell installed (`com.genericjam.io`, the test app's id, is
installed on Kevin's iPhone). The release uses `com.genericjam.io`, the only
id with an App Store profile ("Io App Store"); nothing is installed or
uploaded. Both go into the host's `mob.exs` as `ios_bundle_id` and
`ios_team_id` (`MobCi.Host.mob_exs/5`).

### Signing over ssh: a dedicated CI keychain (2026-10-09)

The login keychain is unlocked only in Kevin's GUI session. `codesign` takes
the signing identity from the first keychain on the search list holding it,
so in an ssh session it finds the login keychain, locked there, and fails
with `errSecInternalComponent`: the iPhone and release paths stopped at
`build:<path>`. The first version unlocked the login keychain with Kevin's
login password from a file; Kevin chose not to keep that password on disk.

Instead the two signing identities (`Apple Development: genericjam@gmail.com
(HAWF754E8H)` for `mob.deploy --native --ios --device`, which auto-detects the
one `Apple Development` identity; `Apple Distribution: Kevin Edey
(Q89CW299G8)` for `mob.release --ios`) were exported once from the login
keychain and imported into `~/Library/Keychains/mob_ci.keychain-db`, which
has its own random password in `~/.config/mob_ci/ci-keychain-password`
(mode 600, directory 700), no auto-lock, `codesign` in its ACL and partition
list, and an entry at the end of the user search list.

Unlocking it is not enough: the login keychain still comes first on the
search list and holds identities of the same name, so `codesign --sign
<name>` still fails on it. Each cell therefore (`worker/mac/ci_keychain.sh`,
sourced by `mob_ci_ios_cell.sh`) unlocks the CI keychain for its ssh session,
the password on stdin rather than argv, and puts `worker/mac/bin` first on
PATH; its `codesign` execs `/usr/bin/codesign --keychain <CI keychain> "$@"`.
mob_dev runs `codesign` by name, from Elixir and from its release script,
so every version of it signs from the CI keychain without a mob_dev option.
Setup, rotation and revocation are in `worker/mac/README.md` step 5.

### Simulator choice: iOS 27+ by default, newest first

`xcrun simctl privacy grant photos` on an iOS 26.x simulator runtime writes a
TCC row (`auth_version=1`) that PhotoKit ignores, so a photos plugin's
self-test meets a prompt there; from iOS 27 the grant takes. A cell therefore
runs on a simulator whose runtime is at least the spec's `min_runtime`
(default `27.0`, `--min-runtime` to change it). Unless `--sim-udid` pins one,
the worker lists booted simulators (`simctl list devices booted -j`), keeps
those at or above the minimum, and tries to lease them newest runtime first;
the first free one is the cell's device. A pinned simulator below the minimum
is refused, not used. Each result records the device and its runtime
(`"device": {"udid", "name", "runtime"}`); for the iPhone, from `devicectl
list devices --json-output`.

### Results

The NUC writes each result as JSON beside its log and records the run in the
results store (MOB-414): one run row, then per path
`MobCi.Store.record_results/4` with `MobCi.Lane.Ios.to_outcome/1`
(`{:error, reason, layer}` for a cell stopped at a step, `{:ok | :fail,
[Result]}` with `p2`, `p12` items per plugin and `health` for a device run,
one `ipa` pass for a release), platform `ios`. A P12 failure in a larger set
is settled against the plugin's singleton cell on the same row, platform and
path (`Store.singleton_selftest/3`, `Invariants.p12_layer/3`), as on Android.

## Alternatives considered

- **The login password in a file** (the first version of the signing step):
  the most valuable secret on the Mac stored to sign test builds.
- **The CI keychain first on the user search list**, permanently or for the
  length of a cell: the search list is per user, not per session, so Kevin's
  GUI session and other agents' builds would then look in a keychain locked
  in their session and fail or prompt; a cell killed mid-run would leave the
  order changed.
- **A `--keychain` option in mob_dev**: only new mob_dev releases would have
  it, and the matrix builds old ones too.
- **Run the whole of mob_ci on the Mac.** It would need the farm, the store
  and the versions cache in two places, and the Mac has no room for the
  Android side.
- **`scp` the spec and results, or pipe the spec on stdin.** Two more
  transports to stub and fail; the spec is ~2 KB, the result one line.
- **A fixed simulator udid.** The booted simulators change and are leased by
  other agents; a fixed one made the lane fail whenever its owner was busy,
  and could be a 26.x runtime.
- **Delete every `$TMPDIR/mob_ios_*`.** Other agents build in the same temp
  dir; only the cell's own `TMPDIR` and its own app's leftovers are removed.

## Consequences

- One-time setup on the Mac (Remote Login, the NUC's key for `kevin`, the CI
  keychain): see `worker/mac/README.md`.
- The signing private keys exist twice on the Mac, in the login keychain and
  in `mob_ci.keychain-db`, whose password is a file readable by `kevin`;
  `security delete-keychain` undoes it. Renewed certificates must be
  re-exported into it (README step 5, "Rotate").
- The NUC's mob_ci sha must be pushed before a run (the worker checks it out
  from origin).
- `MobCi.Host` gained `platform:`, `root:` and `mob_exs:` options; its reuse
  marker now includes the platform, so cached Android hosts regenerate once.
- Physical-device cells depend on Kevin's iPhone being attached and free; when
  it is not, the matrix shows `skip`, not red.
