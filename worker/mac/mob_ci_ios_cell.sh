#!/usr/bin/env bash
# Run one Mac lane cell on this Mac: the entry point the NUC's MobCi.Lane.Ios
# calls over ssh (after sync.sh). All arguments go to `mix ci.ios_cell`, e.g.
#
#   mob_ci_ios_cell.sh --spec-b64 <base64 spec JSON>
#   mob_ci_ios_cell.sh --set default --versions hex --path release:ios
#
# The cell does not run in the ssh session: guard.sh starts it detached
# (its own session, its own log) and streams the log back, so a NUC side that
# goes away (killed, the link drops, `ci-run.sh pause`) can't kill it before
# its teardown. The NUC writes a heartbeat line to the session's stdin every
# 10 s; when they stop for MOB_CI_HEARTBEAT_TIMEOUT_S (default 60) or stdin
# closes, the guard stops the cell and runs the same teardown as a cell that
# ends normally (`mob_ci_ios_cell.sh --teardown <run dir>`, see guard.sh and
# MobCi.Lane.Ios.Reaper). From a terminal there is no heartbeat; Ctrl-C stops
# the cell the same way. Keep stdin open when calling it from a script
# (`ssh -n` or `</dev/null` stops the cell at once).
#
# A non-interactive ssh session gets a bare PATH (/usr/bin:/bin:…), so the
# toolchain is put on it here, as Kevin's login shell has it: mise's shims
# (elixir, erlang, zig), ~/.local/bin (mise, agent-lease), the mix escripts,
# Homebrew, and the Android platform-tools (`mix mob.doctor` requires adb
# even for an iOS-only host). Xcode's tools are in /usr/bin. The worker runs
# as the user that owns the CI signing keychain.
#
# Gradle needs JDK 17: the mob_new template's Gradle 8.2.1 wrapper runs on
# neither 21 (Gradle ≥ 8.5) nor Homebrew's default 26 ("Unsupported class
# file major version 70"). Kevin's .zshrc exports JAVA_HOME for JDK 17, but
# ssh doesn't read it. `java_home -v 17` returns the newest JDK when 17
# isn't installed, so the candidate's `release` file must name major 17.
# Gradle runs without its long-lived daemon: a cell's daemon would outlive
# the cell, and another agent's build could pick it up before teardown
# stops the cell's processes.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
self="$here/$(basename "$0")"

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$HOME/.mix/escripts:/opt/homebrew/bin:/usr/local/bin:$ANDROID_HOME/platform-tools:$PATH"
export MIX_ENV=dev

# mob_ci's own deps and build; output only when they fail.
build_mob_ci() {
  cd "$here/../.."
  if ! out=$(mix deps.get 2>&1 && mix compile 2>&1); then
    echo "$out"
    echo "worker: mob_ci did not build" >&2
    exit 2
  fi
}

case "${1:-}" in
  --teardown)
    # Run by the guard when its worker ended, however it ended.
    build_mob_ci
    exec mix ci.ios_cell --teardown "${2:?--teardown needs the run dir}"
    ;;
  --worker)
    shift
    ;;
  *)
    runs="${MOB_CI_RUNS_ROOT:-$HOME/.cache/mob_ci/runs}"
    logs="$HOME/mob_ci_logs/mac-worker"
    mkdir -p "$runs" "$logs"
    find "$logs" -maxdepth 1 -name '*.log' -mtime +7 -delete 2>/dev/null || true
    run_id="r$(date -u +%Y%m%dT%H%M%SZ)-$$"
    exec /bin/bash "$here/guard.sh" start --run-dir "$runs/$run_id" --log "$logs/$run_id.log" \
      --heartbeat-timeout "${MOB_CI_HEARTBEAT_TIMEOUT_S:-60}" --teardown "\"$self\" --teardown" \
      -- "$self" --worker "$@"
    ;;
esac

jdk_home() {
  local major=$1 home
  home=$(/usr/libexec/java_home -v "$major" 2>/dev/null) || return 1
  grep -Eq "^JAVA_VERSION=\"$major(\\.|\")" "$home/release" 2>/dev/null && echo "$home"
}

if java_home=$(jdk_home 17); then
  export JAVA_HOME="$java_home"
  export PATH="$JAVA_HOME/bin:$PATH"
else
  echo "worker: no JDK 17 found (/usr/libexec/java_home -V); Android Gradle builds will fail" >&2
fi
export GRADLE_OPTS="${GRADLE_OPTS:+$GRADLE_OPTS }-Dorg.gradle.daemon=false"

# Sign from the dedicated CI keychain (ci_keychain.sh, README step 5).
# shellcheck source=ci_keychain.sh
. "$here/ci_keychain.sh"
mob_ci_signing_keychain "$here/bin"

build_mob_ci
exec mix ci.ios_cell "$@"
