#!/usr/bin/env bash
# Bring the Mac worker's own checkouts to the NUC's mob_ci sha.
#
#   sync.sh <mob_ci sha>
#
# The NUC (MobCi.Lane.Ios) ships this file inline over ssh, so nothing needs to
# be installed on the Mac first. The worker never builds from ~/code (those are
# Kevin's working trees, on any branch): it keeps its own clones under
# $MOB_CI_WORKER_ROOT (default ~/.cache/mob_ci/worker):
#
#   mob_ci/   detached at <sha>  (must be pushed to origin)
#   mob_dev/  detached at origin's default branch: mob_ci's `path: "../mob_dev"`
#             dep. The host apps the worker generates depend on the row's own
#             mob_dev, not on this one.
set -euo pipefail

sha="${1:?usage: sync.sh <mob_ci sha>}"
root="${MOB_CI_WORKER_ROOT:-$HOME/.cache/mob_ci/worker}"
mkdir -p "$root"

clone_or_fetch() {
  local dir=$1 url=$2
  if [ -d "$dir/.git" ]; then
    git -C "$dir" fetch --quiet --prune origin
    git -C "$dir" remote set-head origin --auto >/dev/null
  else
    git clone --quiet "$url" "$dir"
  fi
}

clone_or_fetch "$root/mob_ci" https://github.com/GenericJam/mob_ci
clone_or_fetch "$root/mob_dev" https://github.com/GenericJam/mob_dev

git -C "$root/mob_ci" checkout --quiet --force --detach "$sha"
git -C "$root/mob_dev" checkout --quiet --force --detach origin/HEAD

echo "worker: mob_ci $(git -C "$root/mob_ci" rev-parse --short HEAD)," \
  "mob_dev $(git -C "$root/mob_dev" rev-parse --short HEAD) under $root"
