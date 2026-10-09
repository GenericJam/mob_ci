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
# SAFE-NETWORKING INVARIANTS (a bad change here once cut host wifi):
#   default docker bridge only; NEVER --network host / macvlan / overlapping
#   subnet; adb published to LOOPBACK only; all dist traffic loopback via adb.
set -euo pipefail

BASE=redroid/redroid:13.0.0_64only-latest
FARM_ROOT=/home/kevin/code/.redroid-farm
LOCK=$FARM_ROOT/.farm.lock
DOCKER="sudo docker"
ADB=adb
CEILING=${MOB_CI_FARM_CEILING:-5}

host_port() { echo $((5700 + $1)); }
serial()    { echo "127.0.0.1:$(host_port "$1")"; }

ensure_epmd() { epmd -daemon 2>/dev/null || true; }

running_count() { $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -cE '^(ci-)?redroid[0-9]+$' || true; }
ci_indices()    { $DOCKER ps -a --format '{{.Names}}' 2>/dev/null | sed -n 's/^ci-redroid\([0-9]\+\)$/\1/p' | sort -n; }

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
  $DOCKER run -itd --privileged --name "ci-redroid$i" \
    -p "127.0.0.1:$(host_port "$i"):5555" "$BASE" \
    androidboot.redroid_width="$w" androidboot.redroid_height="$h" \
    androidboot.redroid_dpi="$dpi" androidboot.redroid_fps=30 >/dev/null
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

down() {
  local i=$1
  $DOCKER rm -f "ci-redroid$i" >/dev/null 2>&1 || true
  $ADB disconnect "$(serial "$i")" >/dev/null 2>&1 || true
  echo "removed ci-redroid$i"
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

nuke() { for c in $($DOCKER ps -a --format '{{.Names}}' | grep -E '^ci-redroid[0-9]+$'); do $DOCKER rm -f "$c" >/dev/null; echo "removed $c"; done; }

status() {
  echo "== ci containers =="; $DOCKER ps --filter 'name=ci-redroid' --format '  {{.Names}}\t{{.Status}}\t{{.Ports}}'
  echo "== admission =="; admit
}

cmd=${1:-status}
case "$cmd" in
  boot)    boot "${2:-}" "${3:-}" "${4:-}";;
  launch)  launch "${2:?index}" "${3:?suffix}" "${4:?dist_port}" "${5:?pkg}";;
  down)    down "${2:?ci index}";;
  alive)   alive "${2:?ci index}";;
  admit)   admit;;
  indices) ci_indices;;
  nuke)    nuke;;
  status)  status;;
  *) echo "usage: $0 {boot [W H DPI]|launch <i> <suffix> <dist_port> <pkg>|down <i>|alive <i>|admit|indices|nuke|status}"; exit 2;;
esac
