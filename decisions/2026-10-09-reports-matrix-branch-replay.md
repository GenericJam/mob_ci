# Reports: matrix.md, COMPATIBILITY.md on the `matrix` branch, Muster posts, replay, retention

- Date: 2026-10-09
- Status: accepted
- Linear: MOB-417 (under MOB-410)

## Context

`2026-10-08-revived-version-rows-ios-selftests-matrix.md` §5 decided that
`matrix.md` (latest grid per version row) and `COMPATIBILITY.md` (version
tuples with passing `default` and `all` on every platform, linked from the
documentation as "verified combinations") are generated from the results
store, that Muster `#mob` gets one post per run with `@kevin` only when the
`hex` row regresses, that `mix ci.replay <cell id>` reruns a stored cell,
and that a failing sweep seed becomes a committed regression set.
`2026-10-08-p12-release-cell-results-store.md` left retention open ("nothing
prunes them yet"). The triggers (MOB-416) call the publish step after every
job.

## Decision

### Where the reports live: the `matrix` branch, pushed from the NUC

The files are generated, so they are not hand-reviewed and change after
every job. Committing them to `main` would put a bot commit on `main` every
few hours (the ecosystem rule is no direct commits to the default branch),
race every PR merge, and dirty the NUC's checkout of `main`. Keeping them
only in the store would leave nothing a user can find.

So `mix ci.report --publish` (`MobCi.Publish`) commits them to a dedicated
branch, `matrix`, of the public mob_ci repo, with git plumbing: a temporary
index, `hash-object` / `update-index` / `write-tree` / `commit-tree` on top
of `origin/matrix`, `push origin <sha>:refs/heads/matrix`. No working tree
or HEAD is touched; an unchanged tree is not committed; a rejected push (two
publishes racing) is retried once on the new tip. The branch's tree is
exactly `README.md` (what the branch is), `matrix.md` and
`COMPATIBILITY.md`, so its history is the history of the results. Stable
URLs, linked from mob_ci's README and the place mob's docs link to:

- https://github.com/GenericJam/mob_ci/blob/matrix/COMPATIBILITY.md
- https://github.com/GenericJam/mob_ci/blob/matrix/matrix.md

The same files are also written into the checkout's root (`--out`), where
`.gitignore` keeps them out of `main`.

### What they say (`MobCi.Matrix`, pure)

Both are pure functions of the store's summary rows, sorted at every step,
so the same store renders the same bytes and a diff on the branch is a
change in results. Nothing private is rendered: no hosts, no log paths, and
absolute paths inside a layer (`build:/home/…/ci_x`) are cut to their last
segment.

- **matrix.md**: one section per published version row (`hex`, `master`,
  the five newest `rc:` rows; the fixture hosts `harness` / `sloppy_joe`
  are not version rows and stay on the console report), each the newest
  non-replay cell per (set, platform, path) as `✓ pass`, `✗ fail @ layer`,
  `! error @ layer`, `– skip`, `·`; the core versions in the grid; a tally.
  Sampled sets (`random:<seed>`, device-sweep subsets `sweep:<plugins>`) are
  listed only while their latest cell fails, with the cell id
  `mix ci.replay` takes; `sweep:<named set>` (the static sweep) is a grid
  line.
- **COMPATIBILITY.md**: a *tuple* is the exact pins (version, sha, source;
  not the recording machine's `dir`) of mob, mob_dev, mob_new and the
  plugins. The `default` and `all` cells of the published rows are clustered
  into tuples by consistency (every repo two cells share has the same pin),
  so one night's `default` (two plugins) and `all` (24) on Android and iOS
  form one tuple. A tuple is **verified** when the newest cell of each of
  `default` and `all` on each of `static`, `deploy:android`,
  `release:android`, `deploy:ios_sim`, `deploy:ios_device`, `release:ios`
  passed — a skip is not a pass. Verified tuples newest first, then the ten
  newest candidates with their set × path outcomes, then a table of which
  plugin versions passed (in a passing `singleton:<p>`, `default` or `all`
  cell) with which mob / mob_dev on which paths. The page states the ABI
  each path exercises (`docs/budgets.md`: the farm is x86_64; iOS is arm64).

### Muster: one post per publish, `@kevin` on a hex regression

The post covers the summary cells recorded since the previous *successful*
post: a marker file beside the store (`published_cell_id`) holds the last
reported summary id and advances only when the post went out. So
`--no-post` (a trigger folding a job into the next post) or a failed post
loses nothing, and overlapping jobs report each cell exactly once. No new
cells, no post. The text: cell count per row, outcome counts, failures by
layer, one line per regression, `@kevin the hex row regressed` when one is
on `hex`, the matrix link. It posts as `@mob_ci-nightly`, a bot registered
for the NUC (token in the NUC's `~/.config/muster/bots/`, server
`https://muster.boltbrain.ca`, `muster` CLI in `~/.local/bin`; override with
`$MOB_CI_MUSTER_BOT`). Its token lives only on the NUC, so the Mac's idle
sweep never retires it.

**Regression**, precisely: a non-replay cell that failed or errored whose
previous non-skip outcome for the same (row, set, platform, path), among
non-replay cells, was a pass. So `pass → fail`, `pass → error` (a build or
generator error breaks the user's path just as much) and
`pass → skip → fail` regress; `fail → fail`, `error → fail`, a first-ever
failure, and `skip → fail` with no pass before it don't — nothing that
worked broke, and a skip (device absent) proves nothing either way.
Regressions on other rows are listed without the mention.

Exit status of `--publish`: 0 whenever both files were written, including
nothing to post and a failed push or post (printed as warnings; the next
publish catches up); 1 only when a file can't be written. The triggers log
a non-zero exit and keep draining.

### Replay and regression sets

`mix ci.replay <cell id>` (any row of the cell names it) runs the
`mix ci.device` call of that one path (`--static`, `--paths deploy|release`,
`--platform ios --paths <path>`) with two variables:

- `$MOB_CI_PINS`, a file holding the cell's stored versions record.
  `MobCi.Cell.plan/3` reads it (so the Android path and the iOS lane need no
  new flag) and resolves every repo at its recorded pin
  (`Versions.resolve/2`'s `:pins`: Hex tarballs at that version, git
  checkouts at that sha) instead of the row's latest, and builds the
  recorded plugin list, in committed order for sets defined by it (`all`,
  `pairwise`, `random`) and in the set's activation order otherwise. A
  `random:<seed>` cell is therefore the same set after the pool changed.
- `$MOB_CI_TRIGGER=replay` (honoured by `Store.record_run/2`, MOB-416), so
  the rerun is recorded as a replay: evidence for COMPATIBILITY.md (exact
  versions), never the latest of a matrix cell nor a regression (an old
  version is not the row today).

`--current` drops the pins (trigger `replay-current`, a real result of the
row today); `--dry-run` prints the call and the pins. `--promote` writes a
failing `random:<seed>` (plugins from its pins) or `sweep:<plugins>` cell
to `priv/sets/<name>.exs` (default `random-<seed>` / `sweep-<cell id>`),
headed with where it came from; committed in a PR, `Sets.nightly/0` runs it
every night.

### Retention

`--publish` ends with `Store.prune/2`: cells whose run is older than 30
days are deleted, except the newest cell per (row, set, platform, path) —
overall and among non-replay runs, kept whole forever (the grid, the P12
singleton lookup and the next regression check read it) — and the newest
passing `default` / `all` / `singleton:<p>` summary per (set, platform,
path, exact pins), kept as its summary row only, because that is the
evidence `COMPATIBILITY.md` is built from and a verified combination must
not vanish after a month. Runs left empty go. Log files go when older than
30 days and no remaining cell points at them: those the pruned cells
referenced and `*.log` under `~/mob_ci_logs` (scripts and other files
there are left alone). `mix ci.report --prune` runs only this step.

## Consequences

- The verified list is empty until `default` and `all` pass on all six
  paths with one tuple. Today that waits on F9 (the `all` static gate) and
  on iOS device signing over ssh; the candidates section shows exactly
  which cells are missing.
- The `matrix` branch must never be merged into `main`; it shares no
  history with it.
- A pinned replay before MOB-416's `MOB_CI_TRIGGER` support lands records
  as `ci.device` and would show in the grid; the two land in the same wave.
