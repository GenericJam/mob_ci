# The Mac mini as mob_ci's iOS worker

The NUC (`MobCi.Lane.Ios`, `mix ci.device --platform ios`) drives this Mac
over ssh. Nothing here is started by hand in normal use; this directory is
what the NUC runs:

| file | role |
|---|---|
| `sync.sh` | shipped inline by the NUC each run: clones/fetches the worker's own checkouts under `~/.cache/mob_ci/worker/` (mob_ci at the NUC's sha, mob_dev at its default branch) |
| `mob_ci_ios_cell.sh` | the entry point per cell: puts the toolchain on PATH, builds mob_ci, runs `mix ci.ios_cell --spec-b64 <spec>` |
| `probe.exs` | run by the worker inside the generated host (`mix run --no-start`): grants, relaunches, attaches, reads health, runs the self-tests |

There is no launchd job: the worker only runs while the NUC holds an ssh
session, and it builds one host at a time.

## One-time setup (Kevin)

The worker runs as **`kevin`**, the account that owns Xcode, the signing
keychain (`Apple Distribution: Kevin Edey (Q89CW299G8)` with "Always Allow"
for codesign), the provisioning profiles, `agent-lease` and `~/.mob/cache`.
Never the `claude` account.

1. **Remote Login on**:

   ```sh
   sudo systemsetup -setremotelogin on
   ```

   (System Settings → General → Sharing → Remote Login, allowed for `kevin`.)

2. **The NUC's key** in `~kevin/.ssh/authorized_keys` — the line in the NUC's
   `~/.ssh/id_ed25519.pub`:

   ```sh
   ssh nuc cat .ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
   chmod 600 ~/.ssh/authorized_keys
   ```

   Then from the NUC once, to accept the host key:
   `ssh kevin@10.0.0.71 true`.

3. **Toolchain where a non-interactive shell finds it.** An ssh command gets
   a bare PATH; `mob_ci_ios_cell.sh` adds `~/.local/share/mise/shims`
   (elixir, erlang, zig via mise's global config), `~/.local/bin` (mise,
   agent-lease), `~/.mix/escripts` and Homebrew. Nothing else to install.

4. **Signing material** for the release path: the "Io App Store"
   provisioning profile for `com.genericjam.io` (team Q89CW299G8). The
   simulator and iPhone paths build `com.genericjam.mobci`, which the team's
   wildcard development profile covers; no app uses that id, so teardown's
   uninstall only ever removes what a cell installed.

5. **Signing over ssh.** An ssh session cannot use a login keychain that the
   GUI session unlocked: `codesign` fails with `errSecInternalComponent`, so
   the iPhone and release paths fail at `build:<path>` (the simulator path
   needs no signing). To let them sign, put the login password in a
   kevin-only file; `mob_ci_ios_cell.sh` unlocks the keychain with it at the
   start of each cell:

   ```sh
   mkdir -p ~/.config/mob_ci && chmod 700 ~/.config/mob_ci
   printf '%s' 'LOGIN-PASSWORD' > ~/.config/mob_ci/keychain-password
   chmod 600 ~/.config/mob_ci/keychain-password
   ```

   (`MOB_CI_KEYCHAIN_PASSWORD_FILE` points elsewhere.) The alternative is a
   dedicated, password-less CI keychain holding the two signing identities.

6. **Devices**: at least one booted simulator on an iOS 27+ runtime (the lane
   leases the newest one free; `simctl privacy grant photos` is ignored on
   26.x runtimes, so they are not used by default), and Kevin's iPhone
   (00008110-001E1C3A34F8401E) attached when the iPhone path should run —
   otherwise that cell records `skip: device_absent`.

## What a cell does to this Mac

- Refuses to start under 5 GB free on `/` (`df -k /`).
- Writes only under `$TMPDIR/mob_ci_ios/<cell_id>/` (the host, its `deps`
  and `_build`, and `tmp/`, which is every child's `TMPDIR`) plus mob_dev's
  staged BEAMs for the `ci_*` app under `~/.mob/{cache,runtime}`. All of it
  is deleted when the cell ends, whatever happened. The shared OTP runtime in
  `~/.mob/cache` and the Hex cache are kept.
- Leases its device through `agent-lease` (session `mob_ci_ios_<cell_id>`),
  installs `com.genericjam.mobci`, and uninstalls it and releases the lease
  in teardown.
- Persistent footprint: `~/.cache/mob_ci/worker/` (mob_ci + mob_dev
  checkouts and mob_ci's own `_build`, ~100 MB) and `~/.cache/mob_ci/hex/`.

## By hand

```sh
cd ~/.cache/mob_ci/worker/mob_ci        # or any mob_ci checkout
mix ci.ios_cell --set default --versions hex --path deploy:ios_sim
mix ci.ios_cell --set default --versions hex --path release:ios --out /tmp/results
```

Each cell prints `MOB_CI_RESULT <json>`; exit 0 pass/skip, 1 fail, 2 error.
