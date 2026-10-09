#!/usr/bin/env bash
# ci-run.sh — the canonical mob_ci runner that every L5 trigger calls.
#
# The orchestrator (mix ci.device / ci.sweep) is the product; this script is the
# glue that makes it runnable from a bare environment (systemd unit, git hook,
# cron, an ssh command from the Mac) without a login shell: it puts the
# mise-managed Elixir/Erlang toolchain on PATH, cds to the repo, tees a
# timestamped log, and propagates the task's exit code (0 pass / 1 invariant
# failure / 2 orchestration error) so the caller can gate on it.
#
#   priv/ci-run.sh static            # fast composability gate (no device) — git hook
#   priv/ci-run.sh device [host]     # full P1–P11 (host: harness|sloppy_joe)
#   priv/ci-run.sh realism           # P1–P11 against the real sloppy_joe app
#   priv/ci-run.sh sweep [runs]      # device property sweep over N subsets
#
# The trigger queue (MobCi.Queue, decisions/2026-10-09-trigger-queue.md):
#
#   priv/ci-run.sh nightly           # queue tonight's hex + master sets, Android + iOS
#   priv/ci-run.sh poll              # one git-remote poll cycle (static gate + queue)
#   priv/ci-run.sh rc <repo>@<sha>   # static gate + queue the rc:<repo>@<sha> row
#   priv/ci-run.sh push <repo> <sha> [<ref>]  # a pre-push notice from the Mac
#   priv/ci-run.sh confirm           # wait for noticed pushes to land, then poll
#   priv/ci-run.sh drain <lane>      # run the queued cells of android | ios
#   priv/ci-run.sh pause <lane>      # stop a lane (its running cell is requeued) until resume
#   priv/ci-run.sh resume <lane>     # let a paused lane drain again
#   priv/ci-run.sh queue [args…]     # mix ci.queue (status, show <id>, enqueue …)
#
# Every queueing mode then starts both lane workers (kick_lanes); a worker
# holds its lane's lock, so at most one cell per lane runs at a time.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

# A bare systemd/git environment has none of the tools the orchestrator shells
# out to on PATH. Put them all there explicitly:
#   - mise shims  → mix/elixir/erl/epmd at the versions this repo pins
#   - /usr/sbin   → arp, which mob_dev's deploy probes (F5) — :enoent-crashes otherwise
#   - SDK platform-tools → adb, which ci-farm.sh uses to drive the redroid
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$HOME/Android/Sdk/platform-tools:/usr/sbin:/sbin:$PATH"

# A bare systemd/cron environment has no locale; the BEAM then runs latin1 name
# encoding and warns it "may malfunction". Force UTF-8 (and +fnu as a belt).
export LANG="${LANG:-C.UTF-8}"
export ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-+fnu}"

MODE="${1:-static}"
TS="$(date +%Y%m%dT%H%M%S)"
LOG_DIR="$REPO/artifacts/ci-run"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/${MODE}-${TS}.log"
# Fixed (not $XDG_RUNTIME_DIR): systemd, ssh and cron must all see one lock per lane.
LOCK_DIR="$HOME/.local/share/mob_ci/locks"

# The poller runs every 10 minutes; keep a week of its logs (and of the other
# frequent modes), not every one ever.
find "$LOG_DIR" -maxdepth 1 \( -name 'poll-*.log' -o -name 'confirm-*.log' -o -name 'push-*.log' \
  -o -name 'drain-*.log' -o -name 'queue-*.log' \) -mtime +7 -delete 2>/dev/null || true

echo "[ci-run] mode=$MODE repo=$REPO at=$TS → $LOG"

# Start both lane workers (no-op for a lane already draining). The systemd
# units are the normal path; without them, say how to drain by hand.
kick_lanes() {
  if command -v systemctl >/dev/null && systemctl --user cat mob-ci-drain@.service >/dev/null 2>&1; then
    # A start can fail (e.g. a unit being reloaded); the next poll kicks again.
    systemctl --user start --no-block mob-ci-drain@android.service mob-ci-drain@ios.service \
      && echo "[ci-run] lane workers started (mob-ci-drain@android, mob-ci-drain@ios)" \
      || echo "[ci-run] could not start the lane workers; the next poll retries"
  else
    echo "[ci-run] lane units not installed (priv/install-triggers.sh); drain by hand: priv/ci-run.sh drain android|ios"
  fi
}

case "$MODE" in
  static)
    mix ci.device --static --junit "artifacts/ci-run/static-${TS}.xml" 2>&1 | tee "$LOG"
    mix ci.sweep --static 2>&1 | tee -a "$LOG"
    ;;
  device)
    mix ci.device --host "${2:-harness}" 2>&1 | tee "$LOG"
    ;;
  realism)
    mix ci.device --host sloppy_joe 2>&1 | tee "$LOG"
    ;;
  sweep)
    mix ci.sweep --runs "${2:-4}" 2>&1 | tee "$LOG"
    ;;
  nightly)
    mix ci.queue nightly 2>&1 | tee "$LOG"
    kick_lanes
    ;;
  poll)
    mix ci.poll 2>&1 | tee "$LOG"
    # Always kick: it also catches a job queued while a worker was exiting.
    kick_lanes
    ;;
  rc)
    [ $# -eq 2 ] || { echo "usage: ci-run.sh rc <repo>@<sha>" >&2; exit 64; }
    mix ci.queue rc "$2" 2>&1 | tee "$LOG"
    kick_lanes
    ;;
  push)
    [ $# -ge 3 ] || { echo "usage: ci-run.sh push <repo> <sha> [<ref>]" >&2; exit 64; }
    mix ci.queue push "$2" "$3" ${4:+"$4"} 2>&1 | tee "$LOG"
    # Confirm in the background so the Mac's ssh (and its git push) returns now.
    # One confirm unit at a time: a running one re-reads every pending push.
    if command -v systemd-run >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then
      if systemd-run --user --collect --unit=mob-ci-confirm "$REPO/priv/ci-run.sh" confirm >/dev/null 2>&1; then
        echo "[ci-run] confirming in mob-ci-confirm.service"
      else
        echo "[ci-run] mob-ci-confirm already running; it picks this push up"
      fi
    else
      nohup "$REPO/priv/ci-run.sh" confirm >/dev/null 2>&1 &
      echo "[ci-run] confirming in the background (pid $!)"
    fi
    ;;
  confirm)
    mix ci.poll --await-pushes 2>&1 | tee "$LOG"
    kick_lanes
    ;;
  drain)
    LANE="${2:-}"
    case "$LANE" in android|ios) ;; *) echo "usage: ci-run.sh drain android|ios" >&2; exit 64 ;; esac
    mkdir -p "$LOCK_DIR"
    if [ -e "$LOCK_DIR/pause-$LANE" ]; then
      echo "[ci-run] $LANE lane paused ($LOCK_DIR/pause-$LANE); priv/ci-run.sh resume $LANE"
      exit 0
    fi
    # One worker per lane: the farm is shared, and the Mac builds one host at a time.
    set +e
    flock -n -E 75 "$LOCK_DIR/drain-$LANE.lock" mix ci.queue drain --lane "$LANE" 2>&1 | tee "$LOG"
    status=${PIPESTATUS[0]}
    set -e
    if [ "$status" -eq 75 ]; then echo "[ci-run] $LANE lane already draining"; exit 0; fi
    exit "$status"
    ;;
  pause|resume)
    LANE="${2:-}"
    case "$LANE" in android|ios) ;; *) echo "usage: ci-run.sh $MODE android|ios" >&2; exit 64 ;; esac
    mkdir -p "$LOCK_DIR"
    if [ "$MODE" = pause ]; then
      # The pause file keeps the poller's kicks from restarting the lane; the
      # stopped worker's cell goes back to queued when the lane next starts.
      touch "$LOCK_DIR/pause-$LANE"
      systemctl --user stop "mob-ci-drain@$LANE.service" 2>/dev/null || true
      echo "[ci-run] $LANE lane paused"
    else
      rm -f "$LOCK_DIR/pause-$LANE"
      echo "[ci-run] $LANE lane resumed"
      kick_lanes
    fi
    ;;
  queue)
    shift
    mix ci.queue "$@" 2>&1 | tee "$LOG"
    ;;
  *)
    echo "usage: ci-run.sh {static | device [harness|sloppy_joe] | realism | sweep [runs] |" >&2
    echo "                  nightly | poll | rc <repo>@<sha> | push <repo> <sha> [<ref>] | confirm |" >&2
    echo "                  drain|pause|resume android|ios | queue [args…]}" >&2
    exit 64
    ;;
esac
