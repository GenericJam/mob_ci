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
# as the user that owns the signing keychain.
set -euo pipefail

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$HOME/.mix/escripts:/opt/homebrew/bin:/usr/local/bin:$ANDROID_HOME/platform-tools:$PATH"
export MIX_ENV=dev

# An ssh session cannot use the login keychain while it is locked to that
# session: codesign fails with errSecInternalComponent (the iPhone and release
# paths). If Kevin has left the login password in a kevin-only file, unlock
# the keychain for this session; otherwise those paths fail at
# build:<path> with that error and the simulator path still runs.
pw_file="${MOB_CI_KEYCHAIN_PASSWORD_FILE:-$HOME/.config/mob_ci/keychain-password}"
if [ -r "$pw_file" ]; then
  security unlock-keychain -p "$(cat "$pw_file")" "$HOME/Library/Keychains/login.keychain-db" \
    || echo "worker: could not unlock the login keychain with $pw_file" >&2
fi

cd "$(dirname "$0")/../.."

# mob_ci's own deps and build; output only when they fail.
if ! out=$(mix deps.get 2>&1 && mix compile 2>&1); then
  echo "$out"
  echo "worker: mob_ci did not build" >&2
  exit 2
fi

exec mix ci.ios_cell "$@"
