# The Mac mini as mob_ci's iOS worker

The NUC (`MobCi.Lane.Ios`, `mix ci.device --platform ios`) drives this Mac
over ssh. Nothing here is started by hand in normal use; this directory is
what the NUC runs:

| file | role |
|---|---|
| `sync.sh` | shipped inline by the NUC each run: clones/fetches the worker's own checkouts under `~/.cache/mob_ci/worker/` (mob_ci at the NUC's sha, mob_dev at its default branch) |
| `mob_ci_ios_cell.sh` | the entry point per cell: hands the cell to `guard.sh`, then (as the guard's worker) puts the toolchain on PATH, unlocks the CI keychain (`ci_keychain.sh`), builds mob_ci, runs `mix ci.ios_cell --spec-b64 <spec>` |
| `guard.sh` | runs the cell detached from the ssh session, streams its log back, and runs its teardown however the session ends (heartbeat lost, stdin closed, SIGHUP/SIGTERM) |
| `ci_keychain.sh`, `bin/codesign` | signing over ssh: unlock `mob_ci.keychain-db` for the session and put a `codesign` first on PATH that adds `--keychain` to it (step 5) |
| `probe.exs` | run by the worker inside the generated host (`mix run --no-start`): grants, relaunches, attaches, reads health, runs the self-tests |

There is no launchd job: a cell runs only because the NUC started it over
ssh, and the Mac builds one host at a time. The cell is not tied to that
session, though: if the NUC side goes away (killed, the link drops,
`ci-run.sh pause ios`), the cell is stopped and torn down within a minute
(see "What a cell does to this Mac").

## One-time setup (Kevin)

The worker runs as **`kevin`**, the account that owns Xcode, the signing
identities, the provisioning profiles, `agent-lease` and `~/.mob/cache`.
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
   agent-lease), `~/.mix/escripts` and Homebrew. For the physical-Android
   path it also points `JAVA_HOME` at JDK 17 (`/usr/libexec/java_home`,
   version checked): the template's Gradle 8.2.1 fails on Homebrew's
   default JDK 26 (and would on 21), and ssh doesn't read the `JAVA_HOME`
   in `~/.zshrc`. Temurin 17 is installed; nothing else to install.

4. **Signing material** for the release path: the "Io App Store"
   provisioning profile for `com.genericjam.io` (team Q89CW299G8). The
   simulator and iPhone paths build `com.genericjam.mobci`, which the team's
   wildcard development profile covers; no app uses that id, so teardown's
   uninstall only ever removes what a cell installed.

5. **Signing over ssh: the CI keychain.** An ssh session cannot use the
   login keychain, which only the GUI session has unlocked: `codesign` takes
   the identity from the first keychain on the search list that holds it and
   fails with `errSecInternalComponent`. So the two signing identities are
   copied into a dedicated keychain with a random password of its own, and no
   login password is stored anywhere:

   - `Apple Development: genericjam@gmail.com (HAWF754E8H)`: the iPhone
     build (`mix mob.deploy --native --ios --device`; mob_dev picks the one
     `Apple Development` identity `security find-identity` lists);
   - `Apple Distribution: Kevin Edey (Q89CW299G8)`: `mix mob.release --ios`.

   `mob_ci_ios_cell.sh` (via `ci_keychain.sh`) unlocks it at the start of
   each cell, the password on stdin, and puts `worker/mac/bin` first on PATH.
   That `codesign` runs `/usr/bin/codesign --keychain <CI keychain> …`, so
   every signature mob_dev makes (it calls `codesign` by name, any version)
   comes from the CI keychain, while the search list and Kevin's GUI session
   stay as they are. Without the keychain or its password file the cell
   still runs: the simulator path needs no signing, the iPhone and release
   paths fail at `build:<path>`.

   Setup, from a GUI session (the export asks once per private key to allow
   it, with the login password):

   ```sh
   umask 077; d=$(mktemp -d)
   openssl rand -base64 32 | tr -d '\n' > "$d/pass"
   # The login keychain holds exactly these two identities; check with
   # `security find-identity`, and delete any other from mob_ci afterwards.
   security export -k login.keychain-db -t identities -f pkcs12 \
     -P "$(cat "$d/pass")" -o "$d/ids.p12"

   mkdir -p ~/.config/mob_ci && chmod 700 ~/.config/mob_ci
   pw=~/.config/mob_ci/ci-keychain-password
   openssl rand -base64 32 | tr -d '\n' > "$pw"; chmod 600 "$pw"
   kc=~/Library/Keychains/mob_ci.keychain-db
   security create-keychain -p "$(cat "$pw")" "$kc"
   security set-keychain-settings "$kc"        # no auto-lock, no lock on sleep
   security unlock-keychain -p "$(cat "$pw")" "$kc"
   security import "$d/ids.p12" -k "$kc" -f pkcs12 -P "$(cat "$d/pass")" -T /usr/bin/codesign
   security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$(cat "$pw")" "$kc" >/dev/null
   # Append to the user search list, keeping what is there.
   security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$kc"
   /bin/rm -P "$d/ids.p12" "$d/pass"; rmdir "$d"

   security find-identity -v -p codesigning "$kc"   # the two identities
   ```

   `MOB_CI_KEYCHAIN` and `MOB_CI_KEYCHAIN_PASSWORD_FILE` point elsewhere.
   The first version of this step kept the login password in
   `~/.config/mob_ci/keychain-password`; nothing reads it any more, so if it
   exists, delete it: `/bin/rm -P ~/.config/mob_ci/keychain-password`.

   **Rotate** (a new password, or renewed certificates): delete the keychain
   and run the setup again. **Revoke** (the Mac or the file is compromised,
   or CI should stop signing): delete it, the password file, and its search
   list entry, and revoke the certificates at developer.apple.com if the
   private keys may have leaked:

   ```sh
   security delete-keychain ~/Library/Keychains/mob_ci.keychain-db  # also drops it from the search list
   /bin/rm -P ~/.config/mob_ci/ci-keychain-password
   ```

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
- Runs under `guard.sh`, detached from the ssh session, with
  `MOB_CI_RUN=<run>` in every process's environment. The NUC sends a
  heartbeat every 10 s; when it stops for 60 s
  (`MOB_CI_HEARTBEAT_TIMEOUT_S`), the session's stdin closes, or the guard
  gets SIGHUP/SIGTERM, the guard stops the cell and runs the same teardown as
  a finished cell: stop the run's processes (tagged, and their
  descendants; never the adb server or epmd), then uninstall, release,
  delete. Its log: `~/mob_ci_logs/mac-worker/<run>.log` (kept 7 days); the
  run's state: `~/.cache/mob_ci/runs/<run>/` while it runs.
- Reaps first: before its own cell, each run tears down runs whose guard
  died (SIGKILL, a reboot), stops processes tagged with a dead run, releases
  `mob_ci_ios_*` leases no live cell owns, prunes their
  `~/.agent-device/agents/` state dirs, and deletes cell scratch and `ci_*`
  app state no live cell owns, idle for 30 minutes (`MOB_CI_REAP_AFTER_S`).
- Persistent footprint: `~/.cache/mob_ci/worker/` (mob_ci + mob_dev
  checkouts and mob_ci's own `_build`, ~100 MB) and `~/.cache/mob_ci/hex/`.

## By hand

```sh
cd ~/.cache/mob_ci/worker/mob_ci        # or any mob_ci checkout
mix ci.ios_cell --set default --versions hex --path deploy:ios_sim
mix ci.ios_cell --set default --versions hex --path release:ios --out /tmp/results
```

Each cell prints `MOB_CI_RESULT <json>`; exit 0 pass/skip, 1 fail, 2 error.
A hand run registers a run of its own, so a later cell's reaper cleans up
after it if it is killed; `worker/mac/mob_ci_ios_cell.sh <args>` from a
terminal runs it under the guard (Ctrl-C stops it and tears it down).

## Pre-push notices to the NUC (optional)

`worker/mac/enqueue-push.sh` tells the NUC's trigger queue about a push from
a mob-family repo, so its cells start without waiting for the 10-minute
poller, and a branch push runs as `rc:<repo>@<sha>` (the poller only
watches default branches). It backgrounds `ssh nuc code/mob_ci/priv/ci-run.sh
push <repo> <sha> <ref>` with a 5 s connect timeout and always exits 0, so it
never slows or blocks a push; the NUC runs nothing until the sha is on the
remote. Log: `~/mob_ci_logs/enqueue-push.log`. `MOB_CI_ENQUEUE=0` turns it
off; `MOB_CI_NUC` / `MOB_CI_NUC_REPO` override the ssh host (`nuc`) and the
NUC checkout (`code/mob_ci`).

Install: keep this checkout at `~/code/mob_ci` (or adjust the path) and add
one line inside the `while read …` loop of the repo's `.githooks/pre-push`:

```bash
    "$HOME/code/mob_ci/worker/mac/enqueue-push.sh" "$local_sha" "$remote_ref" </dev/null || true
```

Run by hand, it also reads git's pre-push lines on stdin
(`<local ref> <local sha> <remote ref> <remote sha>`).
