#!/usr/bin/env bash
# Run one iOS cell on this Mac: the entry point the NUC's MobCi.Lane.Ios calls
# over ssh (after sync.sh). All arguments go to `mix ci.ios_cell`, e.g.
#
#   mob_ci_ios_cell.sh --spec-b64 <base64 spec JSON>
#   mob_ci_ios_cell.sh --set default --versions hex --path release:ios
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
set -euo pipefail

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$HOME/.mix/escripts:/opt/homebrew/bin:/usr/local/bin:$ANDROID_HOME/platform-tools:$PATH"
export MIX_ENV=dev

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

here="$(cd "$(dirname "$0")" && pwd)"

# Sign from the dedicated CI keychain (ci_keychain.sh, README step 5).
# shellcheck source=ci_keychain.sh
. "$here/ci_keychain.sh"
mob_ci_signing_keychain "$here/bin"

cd "$here/../.."

# mob_ci's own deps and build; output only when they fail.
if ! out=$(mix deps.get 2>&1 && mix compile 2>&1); then
  echo "$out"
  echo "worker: mob_ci did not build" >&2
  exit 2
fi

exec mix ci.ios_cell "$@"
