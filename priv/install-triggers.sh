#!/usr/bin/env bash
# install-triggers.sh — wire up the mob_ci L5 trigger adapters on this box.
# Idempotent: safe to re-run after editing the hook or unit files; a second run
# with nothing changed rewrites nothing and reports the same state.
#
#   priv/install-triggers.sh          # hook + units installed, timers NOT started
#   priv/install-triggers.sh --enable # also enable + start the nightly and poll timers,
#                                     # and enable lingering so they run logged out
#
# Triggers are thin: every unit just calls priv/ci-run.sh. The orchestrator and
# the queue live in the repo, so swapping or removing a trigger never touches
# CI logic. See priv/triggers.md and decisions/2026-10-09-trigger-queue.md.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENABLE="${1:-}"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNITS=(mob-ci-nightly.service mob-ci-nightly.timer mob-ci-poll.service mob-ci-poll.timer mob-ci-drain@.service)
TIMERS=(mob-ci-nightly.timer mob-ci-poll.timer)
# Replaced by the queue (2026-10-09): the old standalone sweep timer would race
# the android lane for the farm and the mob_ci@127.0.0.1 node name.
OBSOLETE=(mob-ci.timer mob-ci.service)

# 1. git pre-push hook → the fast static gate. core.hooksPath points git at the
#    tracked priv/hooks dir (no copying into .git, survives reclone per-worktree).
git -C "$REPO" config core.hooksPath priv/hooks
chmod +x "$REPO/priv/hooks/pre-push" "$REPO/priv/ci-run.sh"
echo "✓ git pre-push hook active (core.hooksPath → priv/hooks)"

# 2. systemd user units. The committed units name the NUC's checkout
#    (%h/code/mob_ci); render them for wherever this checkout is.
mkdir -p "$UNIT_DIR"
changed=0
for unit in "${UNITS[@]}"; do
  rendered="$(sed "s#%h/code/mob_ci#$REPO#g" "$REPO/priv/systemd/$unit")"
  if [ ! -f "$UNIT_DIR/$unit" ] || [ "$(cat "$UNIT_DIR/$unit")" != "$rendered" ]; then
    printf '%s\n' "$rendered" > "$UNIT_DIR/$unit"
    changed=1
    echo "  wrote $UNIT_DIR/$unit"
  fi
done

for unit in "${OBSOLETE[@]}"; do
  if [ -f "$UNIT_DIR/$unit" ]; then
    systemctl --user disable --now "$unit" >/dev/null 2>&1 || true
    rm -f "$UNIT_DIR/$unit"
    changed=1
    echo "  removed obsolete $unit"
  fi
done

if [ "$changed" = 1 ]; then
  systemctl --user daemon-reload
  echo "✓ systemd user units installed → $UNIT_DIR"
else
  echo "✓ systemd user units up to date → $UNIT_DIR"
fi

if [ "$ENABLE" = "--enable" ]; then
  # enable --now is itself idempotent.
  systemctl --user enable --now "${TIMERS[@]}"
  if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != "yes" ]; then
    loginctl enable-linger "$USER"
    echo "✓ lingering enabled for $USER (timers run while logged out)"
  fi
  echo "✓ timers enabled:"
  systemctl --user list-timers "${TIMERS[@]}" --no-pager || true
else
  echo "ℹ timers installed but NOT started. To enable the nightly + poller:"
  echo "    priv/install-triggers.sh --enable"
fi
