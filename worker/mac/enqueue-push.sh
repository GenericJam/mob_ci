#!/usr/bin/env bash
# enqueue-push.sh — tell the NUC's mob_ci queue about a push, from a mob-family
# repo's .githooks/pre-push on the Mac. Optional: the NUC's 10-minute poller
# finds every default-branch push anyway; a notice only makes it start sooner,
# and makes a branch push run as an rc:<repo>@<sha> row (the poller only
# watches default branches).
#
#   enqueue-push.sh <local_sha> <remote_ref>     # one ref (what the hook line passes)
#   enqueue-push.sh < pre-push-stdin             # every "<lref> <lsha> <rref> <rsha>" line
#
# Never blocks or fails the push: the ssh runs in the background with a short
# connect timeout, all output goes to ~/mob_ci_logs/enqueue-push.log, and the
# script always exits 0. The NUC records the notice and runs nothing until the
# sha is on the remote (priv/ci-run.sh push → confirm), so a push the hook or
# the remote refuses just expires.
#
# Environment: MOB_CI_NUC (ssh host, default "nuc"), MOB_CI_NUC_REPO (the NUC
# checkout, default "code/mob_ci"), MOB_CI_ENQUEUE=0 to switch it off.
set -u

[ "${MOB_CI_ENQUEUE:-1}" = "0" ] && exit 0

NUC="${MOB_CI_NUC:-nuc}"
NUC_REPO="${MOB_CI_NUC_REPO:-code/mob_ci}"
LOG="$HOME/mob_ci_logs/enqueue-push.log"
ZERO=0000000000000000000000000000000000000000
mkdir -p "$(dirname "$LOG")" 2>/dev/null || exit 0

# The repo name as the NUC knows it: origin's basename, not the worktree dir.
url="$(git remote get-url origin 2>/dev/null)" || exit 0
repo="$(basename "$url" .git)"

notify() {
  local sha="$1" ref="$2"
  case "$sha" in "$ZERO"|"") return 0 ;; esac   # a branch deletion
  (
    echo "$(date '+%F %T') $repo $sha $ref"
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$NUC" \
      "$NUC_REPO/priv/ci-run.sh push $(printf '%q' "$repo") $(printf '%q' "$sha") $(printf '%q' "$ref")" \
      </dev/null
  ) >>"$LOG" 2>&1 &
}

if [ $# -ge 1 ]; then
  notify "$1" "${2:-}"
else
  while read -r _lref lsha rref _rsha; do notify "$lsha" "$rref"; done
fi

exit 0
