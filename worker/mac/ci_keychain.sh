# Sourced by mob_ci_ios_cell.sh: lets codesign sign inside an ssh session.
#
# The login keychain is unlocked only in Kevin's GUI session. In an ssh
# session it is locked, and codesign, which takes the identity from the first
# keychain on the search list holding it, fails with errSecInternalComponent.
# The two signing identities therefore also live in a dedicated keychain
# (worker/mac/README.md step 5) whose random password is in a kevin-only file.
#
# `mob_ci_signing_keychain <bin_dir>` unlocks that keychain for this session
# and puts <bin_dir> first on PATH. Its `codesign` adds `--keychain <the CI
# keychain>`, so every codesign mob_dev runs signs from it, whatever the
# mob_dev version: mob_dev calls codesign by name, from Elixir and from its
# release script. Nothing global changes: the search list and its order, and
# the login keychain, are left as they are.
#
# Without the keychain or the password file, or when the unlock fails, the
# cell runs anyway: the simulator path needs no signing, and the iPhone and
# release paths fail at build:<path> with errSecInternalComponent.
#
# MOB_CI_KEYCHAIN and MOB_CI_KEYCHAIN_PASSWORD_FILE point elsewhere.
mob_ci_signing_keychain() {
  local bin_dir=$1
  local kc="${MOB_CI_KEYCHAIN:-$HOME/Library/Keychains/mob_ci.keychain-db}"
  local pw_file="${MOB_CI_KEYCHAIN_PASSWORD_FILE:-$HOME/.config/mob_ci/ci-keychain-password}"
  local out

  if [ ! -f "$kc" ] || [ ! -r "$pw_file" ]; then
    echo "worker: no CI keychain ($kc, $pw_file): the iPhone and release paths cannot sign" >&2
    return 0
  fi

  # The password goes on stdin: on the command line, ps would show it.
  if ! out=$(security unlock-keychain "$kc" <"$pw_file" 2>&1); then
    echo "worker: could not unlock $kc with $pw_file: $out" >&2
    return 0
  fi

  export MOB_CI_CODESIGN_KEYCHAIN="$kc"
  export PATH="$bin_dir:$PATH"
}
