#!/usr/bin/env bash
# ci-run.sh — the canonical mob_ci runner that every L5 trigger calls.
#
# The orchestrator (mix ci.device / ci.sweep) is the product; this script is the
# ~30-line glue that makes it runnable from a bare environment (systemd unit, git
# hook, cron, a Forgejo/GH step) without a login shell: it puts the mise-managed
# Elixir/Erlang toolchain on PATH, cds to the repo, tees a timestamped log, and
# propagates the task's exit code (0 pass / 1 invariant failure / 2 orchestration
# error) so the caller can gate on it.
#
#   priv/ci-run.sh static            # fast composability gate (no device) — git hook
#   priv/ci-run.sh device [host]     # full P1–P11 (host: harness|sloppy_joe)
#   priv/ci-run.sh realism           # P1–P11 against the real sloppy_joe app
#   priv/ci-run.sh sweep [runs]      # device property sweep over N subsets
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

echo "[ci-run] mode=$MODE repo=$REPO at=$TS → $LOG"

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
  *)
    echo "usage: ci-run.sh {static | device [harness|sloppy_joe] | realism | sweep [runs]}" >&2
    exit 64
    ;;
esac
