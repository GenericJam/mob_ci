#!/usr/bin/env bash
# guard.sh — run a Mac-lane worker detached from the ssh session that started
# it, and tear its cell down however that session ends (MOB-466).
#
#   guard.sh start --run-dir DIR --log FILE --teardown CMD [--heartbeat-timeout S] -- WORKER [ARG…]
#
# `start` is what the ssh session runs. It
#
#   1. starts the guard (`guard.sh supervise …`) in a session of its own
#      (setsid, through perl: macOS has no setsid(1)) with its output
#      appended to FILE, so nothing that happens to the ssh session (a closed
#      stdout, SIGPIPE, SIGHUP) reaches the cell;
#   2. streams FILE to its stdout (the NUC's log of the session) until the
#      guard writes DIR/exit, then exits with that code and removes DIR
#      (unless a cell manifest is still in DIR/cells/: the reaper retries it);
#   3. when stdin is not a terminal, reads heartbeat lines from it (the NUC
#      sends one every 10 s) and stamps DIR/heartbeat with each; at EOF (the
#      NUC side closed the session) it sends the guard SIGHUP. HUP, INT, TERM
#      and PIPE sent to `start` itself are forwarded the same way. At a
#      terminal there is no heartbeat, and Ctrl-C stops the cell.
#
# The guard runs WORKER in the background with MOB_CI_RUN=<DIR's basename>
# and MOB_CI_RUN_DIR=DIR in its environment. Every process the cell starts
# inherits that tag, and teardown stops the processes carrying it and all
# their descendants (MobCi.Lane.Ios.Reaper): a process group would not do,
# because the BEAM gives each port program (mix, zig, gradle, xcodebuild) a
# session of its own. The guard stamps DIR/alive every 2 s and stops the
# cell when
#
#   - it gets SIGHUP, SIGTERM or SIGINT, or
#   - S > 0 and DIR/heartbeat is older than S seconds (the link dropped
#     without closing it: no EOF ever arrives).
#
# The reason goes to DIR/abort. Then, and also when the worker exits on its
# own, it runs `CMD DIR`: the same teardown either way (`mix ci.ios_cell
# --teardown DIR` stops the run's processes, then runs the worker's
# teardown for every cell whose manifest is still in DIR/cells/).
# Finally it kills the worker if it is somehow still alive, and writes the
# exit code (the worker's, or 2 for a stopped cell) to DIR/exit.
#
# Written for macOS's bash 3.2.
set -uo pipefail

usage() {
  echo "usage: guard.sh start --run-dir DIR --log FILE --teardown CMD [--heartbeat-timeout S] -- WORKER [ARG…]" >&2
  exit 64
}

mode=${1:-}
[ $# -gt 0 ] && shift
run_dir="" log="" teardown="" hb_timeout=60
while [ $# -gt 0 ]; do
  case $1 in
    --run-dir) run_dir=${2:-}; shift 2 ;;
    --log) log=${2:-}; shift 2 ;;
    --teardown) teardown=${2:-}; shift 2 ;;
    --heartbeat-timeout) hb_timeout=${2:-}; shift 2 ;;
    --) shift; break ;;
    *) usage ;;
  esac
done
{ [ -n "$run_dir" ] && [ -n "$log" ] && [ -n "$teardown" ] && [ $# -gt 0 ]; } || usage
case $hb_timeout in '' | *[!0-9]*) usage ;; esac

self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

now() { date +%s; }
say() { echo "[guard $(date -u +%H:%M:%S)] $*"; }

start() {
  mkdir -p "$run_dir/cells" "$(dirname "$log")" || exit 2
  : >>"$log"
  rm -f "$run_dir/exit" "$run_dir/abort"
  now >"$run_dir/heartbeat"
  local hb=$hb_timeout
  [ -t 0 ] && hb=0

  perl -MPOSIX=setsid -e 'setsid() >= 0 or die "guard: setsid: $!\n"; exec @ARGV or die "guard: exec: $!\n"' \
    "$BASH" "$self" supervise --run-dir "$run_dir" --log "$log" --teardown "$teardown" --heartbeat-timeout "$hb" \
    -- "$@" </dev/null >>"$log" 2>&1 &
  guard=$!

  stop_cell() { kill -HUP "$guard" 2>/dev/null; }
  trap stop_cell HUP INT TERM
  trap 'stop_cell; exit 141' PIPE

  reader=""
  if [ "$hb" -gt 0 ]; then
    exec 3<&0
    (
      trap - HUP INT TERM PIPE
      while IFS= read -r _ <&3; do
        now >"$run_dir/heartbeat.tmp" && mv -f "$run_dir/heartbeat.tmp" "$run_dir/heartbeat"
      done
      # EOF: the NUC side closed the session.
      kill -HUP "$guard" 2>/dev/null
    ) &
    reader=$!
    exec 3<&-
  fi

  # Stream the log; a line still being written waits in buf for its end. A
  # stdout that is gone (EPIPE when SIGPIPE is ignored) is the session gone.
  exec 4<"$log"
  buf=""
  emit() { printf '%s\n' "$1" 2>/dev/null || { stop_cell; exit 141; }; }
  pump() {
    local line
    while IFS= read -r line <&4; do
      emit "$buf$line"
      buf=""
    done
    buf="$buf$line"
  }
  while [ ! -e "$run_dir/exit" ]; do
    pump
    kill -0 "$guard" 2>/dev/null || break
    sleep 1
  done
  pump
  [ -n "$buf" ] && emit "$buf"
  [ -n "$reader" ] && kill "$reader" 2>/dev/null

  local code
  code=$(cat "$run_dir/exit" 2>/dev/null)
  case $code in '' | *[!0-9]*) say "the guard ended without an exit code"; code=2 ;; esac
  ls "$run_dir"/cells/*.json >/dev/null 2>&1 || rm -rf "$run_dir"
  exit "$code"
}

supervise() {
  local run_id worker reason="" code last age
  run_id=$(basename "$run_dir")
  echo $$ >"$run_dir/guard.pid"
  trap 'reason=${reason:-"SIGHUP: the session that started the cell went away"}' HUP
  trap 'reason=${reason:-SIGTERM}' TERM
  trap 'reason=${reason:-SIGINT}' INT

  say "run $run_id: guard pid $$, heartbeat timeout ${hb_timeout}s (0: none), log $log"
  MOB_CI_RUN=$run_id MOB_CI_RUN_DIR=$run_dir "$@" </dev/null &
  worker=$!
  echo "$worker" >"$run_dir/worker.pid"

  while kill -0 "$worker" 2>/dev/null; do
    touch "$run_dir/alive"
    if [ -z "$reason" ] && [ "$hb_timeout" -gt 0 ]; then
      last=$(cat "$run_dir/heartbeat" 2>/dev/null)
      case $last in '' | *[!0-9]*) last=0 ;; esac
      age=$(($(now) - last))
      [ "$age" -gt "$hb_timeout" ] && reason="heartbeat lost: nothing from the NUC for ${age}s (limit ${hb_timeout}s)"
    fi
    [ -n "$reason" ] && break
    # A trapped signal ends the wait at once.
    sleep 2 &
    wait $!
  done

  if [ -n "$reason" ]; then
    say "stopping the cell: $reason"
    printf '%s\n' "$reason" >"$run_dir/abort"
    code=2
  else
    wait "$worker"
    code=$?
  fi

  # The run stays live (the `alive` stamp) while its teardown runs, so a
  # reaper starting meanwhile leaves it alone.
  eval "$teardown \"\$run_dir\"" &
  local td=$! td_code
  while kill -0 "$td" 2>/dev/null; do
    touch "$run_dir/alive"
    sleep 2 &
    wait $!
  done
  wait "$td"
  td_code=$?
  [ "$td_code" -eq 0 ] || say "teardown exited $td_code"
  # Teardown stops every tagged process; the worker is the guard's own child.
  kill -KILL "$worker" 2>/dev/null && say "killed worker $worker, still alive after teardown"

  printf '%s\n' "$code" >"$run_dir/exit.tmp" && mv -f "$run_dir/exit.tmp" "$run_dir/exit"
  exit "$code"
}

case $mode in
  start) start "$@" ;;
  supervise) supervise "$@" ;;
  *) usage ;;
esac
