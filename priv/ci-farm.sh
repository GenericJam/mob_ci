#!/usr/bin/env bash
# ci-farm.sh — redroid driver for mob_ci device runs, coexisting with the LIVE
# sloppy_joe staging farm (~/code/.redroid-farm/farm.sh) on the same box.
#
# Flow (validated 2026-06-19): this script only BOOTS a base redroid + adb
# connects (boot), and LAUNCHES the installed app with the CI node identity
# (launch). The build+install+OTP-push is done by `mix mob.deploy --native
# --device <serial>` (MobCi.Build) between the two — adb push to a redroid over
# loopback is reliable, so the old install/inject path isn't needed.
#
# Separation from staging (so a CI run can never collide with a staging lease):
#   container name = ci-redroid<i>   (staging uses redroid<i>; disjoint regex)
#   adb host port  = 5700 + i        (staging uses 5556+i)
#   dist port      = 9300 + i        (staging uses 9101+i)
# Shared with staging: the same flock (~/code/.redroid-farm/.farm.lock) guards
# index allocation AND box-level admission — `admit`/`boot` refuse when total
# running redroid* containers would exceed the ceiling, so CI yields to staging.
#
# Ownership (MOB-467): `boot` writes $STATE/ci-redroid<i>.owner (the owner's
# pid, $MOB_CI_FARM_OWNER_PID, and its /proc start time; run/job/cell; boot
# time) under the flock before the container exists; `down` removes it.
# `reap` downs every ci-redroid<i> whose owner is dead, or that has no owner
# and is older than MOB_CI_FARM_REAP_AFTER_MIN (20) minutes. Only
# ^ci-redroid[0-9]+$ is ever touched: staging's redroid<i> never is.
#
# SAFE-NETWORKING INVARIANTS (a bad change here once cut host wifi):
#   default docker bridge only; NEVER --network host / macvlan / overlapping
#   subnet; adb published to LOOPBACK only; all dist traffic loopback via adb.
set -euo pipefail

BASE=redroid/redroid:13.0.0_64only-latest
FARM_ROOT=/home/kevin/code/.redroid-farm
LOCK=${MOB_CI_FARM_LOCK:-$FARM_ROOT/.farm.lock}
STATE=${MOB_CI_FARM_STATE:-$HOME/.local/share/mob_ci/farm}
REAP_AFTER_MIN=${MOB_CI_FARM_REAP_AFTER_MIN:-20}
PROC=${MOB_CI_FARM_PROC:-/proc}
DOCKER="sudo docker"
ADB=adb
CEILING=${MOB_CI_FARM_CEILING:-5}

host_port() { echo $((5700 + $1)); }
serial()    { echo "127.0.0.1:$(host_port "$1")"; }

ensure_epmd() { epmd -daemon 2>/dev/null || true; }

running_count() { $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -cE '^(ci-)?redroid[0-9]+$' || true; }
ci_indices()    { $DOCKER ps -a --format '{{.Names}}' 2>/dev/null | sed -n 's/^ci-redroid\([0-9]\+\)$/\1/p' | sort -n; }
ci_names()      { grep -E '^ci-redroid[0-9]+$' || true; }   # filter `docker ps -a` names on stdin

# ── ownership ────────────────────────────────────────────────────────────────

record() { echo "$STATE/ci-redroid$1.owner"; }
# field <record> <key>: one value (empty if absent); records are written by write_record only.
field() { { sed -n "s/^$2=//p" "$1" 2>/dev/null || true; } | head -n 1; }
# A process's start time in clock ticks since boot (/proc/<pid>/stat field 22),
# empty when it is gone. Kept with the pid so a reused pid never passes for
# the owner; unlike `ps -o lstart` it moves with no clock step, TZ or locale.
# The comm field (2) may hold spaces and parens: cut after its last ") ".
pid_start() { { sed 's/.*) //' "$PROC/$1/stat" 2>/dev/null || true; } | cut -d' ' -f20; }

# write_record <i>: the owner is $MOB_CI_FARM_OWNER_PID (MobCi.Farm passes its
# BEAM's pid). A hand boot without it records no pid, so its instance goes
# by the orphan age rule; set MOB_CI_FARM_OWNER_PID=$$ from a shell that stays
# open (tmux) to keep it. Run/job/cell are labels only.
write_record() {
  local f pid=${MOB_CI_FARM_OWNER_PID:-} run=${MOB_CI_FARM_RUN:-}
  f=$(record "$1")
  mkdir -p "$STATE"
  {
    echo "pid=$pid"
    echo "pid_start=$([ -n "$pid" ] && pid_start "$pid")"
    echo "run=${run//[$'\n\r']/ }"
    echo "job=${MOB_CI_JOB_ID:-}"
    echo "cell=${MOB_CI_CELL_ID:-}"
    echo "booted=$(date +%s)"
  } >"$f.tmp"
  mv "$f.tmp" "$f"
}

# owned <i>: a record naming an owner pid exists.
owned() { [[ "$(field "$(record "$1")" pid)" =~ ^[0-9]+$ ]]; }

# owner_alive <record>: the pid runs and is the same process that booted.
owner_alive() {
  local pid want now
  pid=$(field "$1" pid)
  want=$(field "$1" pid_start)
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  now=$(pid_start "$pid")
  [ -n "$now" ] || return 1
  [ -z "$want" ] || [ "$now" = "$want" ]
}

# owner_text <i>: one line for status and reap.
owner_text() {
  local f s booted run job cell
  f=$(record "$1")
  if [ ! -f "$f" ]; then
    echo "none (no record: reaped once ${REAP_AFTER_MIN} min old)"
    return
  fi
  if ! owned "$1"; then
    s="none (no owner pid: reaped once ${REAP_AFTER_MIN} min old)"
  elif owner_alive "$f"; then
    s="pid $(field "$f" pid) alive"
  else
    s="pid $(field "$f" pid) DEAD"
  fi
  run=$(field "$f" run); job=$(field "$f" job); cell=$(field "$f" cell); booted=$(field "$f" booted)
  [ -n "$run" ] && s="$s, run $run"
  [ -n "$job" ] && s="$s, job $job"
  [ -n "$cell" ] && s="$s, cell $cell"
  [[ "$booted" =~ ^[0-9]+$ ]] && s="$s, booted $((($(date +%s) - booted) / 60)) min ago"
  echo "$s"
}

# Docker's RFC 3339 `Created` (2026-10-09T18:01:02.123456789Z) → epoch (GNU or BSD date).
to_epoch() {
  local t=${1%%.*}
  t=${t%Z}
  [ -n "$t" ] || return 0
  date -u -d "${t/T/ }" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%S' "$t" +%s 2>/dev/null || true
}

# Print OK if the box has headroom for one more container, else BUSY (+count).
admit() {
  exec 9>"$LOCK"; flock 9
  local n; n=$(running_count)
  flock -u 9
  if [ "$n" -lt "$CEILING" ]; then echo "OK $n/$CEILING"; else echo "BUSY $n/$CEILING"; fi
}

# boot [w h dpi] — allocate the lowest free CI index under the flock (enforcing
# the box ceiling), boot a base redroid, adb connect, wait for boot_completed.
# Prints INDEX=/SERIAL= for MobCi.Farm to parse. Exit 4 = box busy.
boot() {
  local w=${1:-1080} h=${2:-2340} dpi=${3:-440}
  exec 9>"$LOCK"; flock 9
  local n; n=$(running_count)
  if [ "$n" -ge "$CEILING" ]; then flock -u 9; echo "BUSY $n/$CEILING" >&2; exit 4; fi
  local used i=0
  used=" $(ci_indices | tr '\n' ' ') "
  while echo "$used" | grep -q " $i "; do i=$((i + 1)); done
  write_record "$i"
  if ! $DOCKER run -itd --privileged --name "ci-redroid$i" \
    -p "127.0.0.1:$(host_port "$i"):5555" "$BASE" \
    androidboot.redroid_width="$w" androidboot.redroid_height="$h" \
    androidboot.redroid_dpi="$dpi" androidboot.redroid_fps=30 >/dev/null; then
    rm -f "$(record "$i")"
    flock -u 9
    echo "docker run ci-redroid$i failed" >&2
    exit 1
  fi
  flock -u 9

  local ser; ser=$(serial "$i")
  $ADB connect "$ser" >/dev/null 2>&1 || true
  for _ in $(seq 1 45); do
    [ "$($ADB -s "$ser" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
    sleep 2
  done
  echo "INDEX=$i"
  echo "SERIAL=$ser"
}

# launch <index> <suffix> <dist_port> <pkg> — wire dist tunnels and (re)launch
# the installed app with the CI node identity. Assumes the app is already
# installed + OTP pushed (mix mob.deploy --native --device ran against SERIAL).
launch() {
  local i=$1 suffix=$2 dp=$3 pkg=$4 ser; ser=$(serial "$i")
  ensure_epmd
  $ADB -s "$ser" reverse tcp:4369 tcp:4369 >/dev/null
  $ADB -s "$ser" forward "tcp:$dp" "tcp:$dp" >/dev/null
  $ADB -s "$ser" shell am force-stop "$pkg" >/dev/null 2>&1 || true
  sleep 1
  $ADB -s "$ser" shell am start -n "$pkg/.MainActivity" \
    --es mob_node_suffix "$suffix" --ei mob_dist_port "$dp" >/dev/null
  echo "LAUNCHED suffix=$suffix dist=$dp pkg=$pkg"
}

# remove <i>: the ownership record, the container and its adb transport. The
# record goes first: once the container is gone a boot may reuse index <i>
# and write its own record, which a late `rm` here would delete.
remove() {
  rm -f "$(record "$1")"
  $DOCKER rm -f "ci-redroid$1" >/dev/null 2>&1 || true
  $ADB disconnect "$(serial "$1")" >/dev/null 2>&1 || true
  echo "removed ci-redroid$1"
}

down() { remove "$1"; }

# down-owned <pid> — release every instance <pid> owns (MobCi.Farm's SIGTERM
# trap: the cell's BEAM is stopping and its `after` blocks won't run).
down_owned() {
  local f i
  exec 9>"$LOCK"; flock 9
  for f in "$STATE"/ci-redroid*.owner; do
    [ -f "$f" ] && [ "$(field "$f" pid)" = "$1" ] || continue
    i=$(basename "$f" .owner); i=${i#ci-redroid}
    remove "$i"
  done
  flock -u 9
}

# reap — down every ci-redroid<i> no live cell owns: its owner is dead, or it
# has no owner (no record, or a hand boot's pid-less one) and is older than
# REAP_AFTER_MIN. A record without a container is dropped. Runs under the
# flock, so a boot in flight (record written, then docker run) is never seen
# half-done. Prints `down|keep|forget <name>: why` per instance and
# `REAPED <n>`; exits 1 without touching anything when docker can't list.
reap() {
  local after=$((REAP_AFTER_MIN * 60)) now all names c i f why created age n=0
  now=$(date +%s)
  exec 9>"$LOCK"; flock 9
  if ! all=$($DOCKER ps -a --format '{{.Names}}' 2>&1); then
    flock -u 9
    echo "reap: docker ps failed, nothing reaped: $all" >&2
    exit 1
  fi
  names=$(echo "$all" | ci_names)
  for c in $names; do
    i=${c#ci-redroid}
    f=$(record "$i")
    if owned "$i"; then
      if owner_alive "$f"; then echo "keep $c: owner $(owner_text "$i")"; continue; fi
      echo "down $c: owner $(owner_text "$i")"
    else
      why="no owner record"
      [ -f "$f" ] && why="no owner pid"
      created=$(to_epoch "$($DOCKER inspect -f '{{.Created}}' "$c" 2>/dev/null || true)")
      if [ -z "$created" ]; then echo "keep $c: $why, age unknown"; continue; fi
      age=$((now - created))
      if [ "$age" -lt "$after" ]; then
        echo "keep $c: $why, $((age / 60)) min old (reaped at $REAP_AFTER_MIN)"
        continue
      fi
      echo "down $c: $why, $((age / 60)) min old"
    fi
    remove "$i" >/dev/null
    n=$((n + 1))
  done
  for f in "$STATE"/ci-redroid*.owner; do
    [ -f "$f" ] || continue
    c=$(basename "$f" .owner)
    echo "$names" | grep -qx "$c" && continue
    rm -f "$f"
    echo "forget $c: no container"
  done
  flock -u 9
  echo "REAPED $n"
}

# alive <index> — is the instance still usable? The container must be running
# and adb must see the device; an adbd restart (`adb root`) gets
# MOB_CI_ALIVE_TRIES × MOB_CI_ALIVE_SLEEP (6 × 2 s) to come back. Prints ALIVE
# or `LOST <why>` (MobCi.Farm.alive/1 → layer `farm`).
alive() {
  local i=$1 ser running state="" n
  ser=$(serial "$i")
  # `docker inspect` of a missing container prints an empty line and fails.
  running=$($DOCKER inspect -f '{{.State.Running}}' "ci-redroid$i" 2>/dev/null | tr -d '[:space:]' || true)
  [ -n "$running" ] || running=missing
  if [ "$running" != true ]; then echo "LOST container ci-redroid$i: $running"; return 0; fi
  for n in $(seq "${MOB_CI_ALIVE_TRIES:-6}"); do
    # adb exits 1 when the device is offline or gone: that is the answer, not an error.
    state=$($ADB -s "$ser" get-state 2>&1 | tr -d '\r' | tail -1) || true
    [ "$state" = device ] && { echo ALIVE; return 0; }
    [ "$n" -lt "${MOB_CI_ALIVE_TRIES:-6}" ] && sleep "${MOB_CI_ALIVE_SLEEP:-2}"
  done
  echo "LOST adb $ser: $state"
}

nuke() { for c in $($DOCKER ps -a --format '{{.Names}}' | ci_names); do remove "${c#ci-redroid}"; done; }

status() {
  local c st ports
  echo "== ci containers =="
  while IFS=$'\t' read -r c st ports; do
    [[ "$c" =~ ^ci-redroid[0-9]+$ ]] || continue
    printf '  %s\t%s\t%s\towner: %s\n' "$c" "$st" "$ports" "$(owner_text "${c#ci-redroid}")"
  done < <($DOCKER ps -a --filter 'name=ci-redroid' --format $'{{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true)
  echo "== admission =="; admit
}

cmd=${1:-status}
case "$cmd" in
  boot)    boot "${2:-}" "${3:-}" "${4:-}";;
  launch)  launch "${2:?index}" "${3:?suffix}" "${4:?dist_port}" "${5:?pkg}";;
  down)    down "${2:?ci index}";;
  down-owned) down_owned "${2:?owner pid}";;
  reap)    reap;;
  alive)   alive "${2:?ci index}";;
  admit)   admit;;
  indices) ci_indices;;
  nuke)    nuke;;
  status)  status;;
  *) echo "usage: $0 {boot [W H DPI]|launch <i> <suffix> <dist_port> <pkg>|down <i>|down-owned <pid>|reap|alive <i>|admit|indices|nuke|status}"; exit 2;;
esac
