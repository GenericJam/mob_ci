#!/usr/bin/env bash
# install-triggers.sh — wire up the mob_ci L5 trigger adapters on this box.
# Idempotent; safe to re-run after editing the hook or unit files.
#
#   priv/install-triggers.sh          # install hook + timer (does NOT start the timer)
#   priv/install-triggers.sh --enable # also enable + start the nightly sweep timer
#
# Triggers are thin: both just call priv/ci-run.sh. The orchestrator lives in the
# repo, so swapping or removing a trigger never touches CI logic.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENABLE="${1:-}"

# 1. git pre-push hook → the fast static gate. core.hooksPath points git at the
#    tracked priv/hooks dir (no copying into .git, survives reclone per-worktree).
git -C "$REPO" config core.hooksPath priv/hooks
chmod +x "$REPO/priv/hooks/pre-push" "$REPO/priv/ci-run.sh"
echo "✓ git pre-push hook active (core.hooksPath → priv/hooks)"

# 2. systemd user units → the nightly device sweep.
UNIT_DIR="$HOME/.config/systemd/user"
mkdir -p "$UNIT_DIR"
cp "$REPO/priv/systemd/mob-ci.service" "$REPO/priv/systemd/mob-ci.timer" "$UNIT_DIR/"
systemctl --user daemon-reload
echo "✓ systemd user units installed → $UNIT_DIR"

if [ "$ENABLE" = "--enable" ]; then
  systemctl --user enable --now mob-ci.timer
  echo "✓ mob-ci.timer enabled:"
  systemctl --user list-timers mob-ci.timer --no-pager || true
else
  echo "ℹ timer installed but NOT started. To enable the nightly sweep:"
  echo "    systemctl --user enable --now mob-ci.timer"
  echo "  (and 'loginctl enable-linger $USER' so it runs while logged out)."
fi
