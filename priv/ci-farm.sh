#!/usr/bin/env bash
# ci-farm.sh — redroid driver for mob_ci device runs, coexisting with the LIVE
# sloppy_joe staging farm (~/code/.redroid-farm/farm.sh) on the same box.
#
# Separation from staging (so a CI run can never collide with or be mistaken for
# a staging lease):
#   * container name   = ci-redroid<i>   (staging uses redroid<i>; disjoint regex)
#   * adb host port     = 5700 + i        (staging uses 5556+i)
#   * dist port         = 9300 + i        (staging uses 9101+i)
#   * the CI app is a different package, so it never dials sloppyjoe.ca — it only
#     clusters to the host BEAM for Mob.Test RPC.
#
# Shared with staging (so the box can't be oversubscribed):
#   * the same flock (~/code/.redroid-farm/.farm.lock) guards index allocation
#     AND box-level admission — `admit` refuses when total running redroid*
#     containers (staging + CI) would exceed the ceiling, so CI yields to staging.
#
# Boot path (base redroid + fresh APK + OTP inject) mirrors the proven bake.sh:
# adb install --abi x86_64, then docker-cp the OTP tree in (adb push of the big
# OTP transfer is too flaky on redroid), chown to the app uid, restorecon.
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
# Total concurrent redroid containers (staging + CI) the 4-core box tolerates.
# Staging runs warm=1/max=4; CI yields when adding one would cross this.
CEILING=${MOB_CI_FARM_CEILING:-5}

host_port() { echo $((5700 + $1)); }
dist_port() { echo $((9300 + $1)); }
serial()    { echo "127.0.0.1:$(host_port "$1")"; }

ensure_epmd() { epmd -daemon 2>/dev/null || true; }

# All running redroid containers, staging (redroid<i>) and CI (ci-redroid<i>).
running_count() { $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -cE '^(ci-)?redroid[0-9]+$' || true; }

# CI instance indices currently allocated.
ci_indices() {
  $DOCKER ps -a --format '{{.Names}}' 2>/dev/null \
    | sed -n 's/^ci-redroid\([0-9]\+\)$/\1/p' | sort -n
}

# Print OK if the box has headroom for one more container, else BUSY (+count).
# Used by MobCi.Farm.admit?/0 before attempting a lease.
admit() {
  exec 9>"$LOCK"; flock 9
  local n; n=$(running_count)
  flock -u 9
  if [ "$n" -lt "$CEILING" ]; then echo "OK $n/$CEILING"; else echo "BUSY $n/$CEILING"; fi
}

# up-auto <apk> <otp_dir> <node_suffix_base> [w h dpi]
#   Allocate the lowest free CI index under the flock (also enforcing the box
#   ceiling), boot a base redroid, install the APK, inject OTP, wire dist tunnels,
#   launch with MOB_NODE_SUFFIX=<base><idx> + MOB_DIST_PORT. Prints INDEX=/SERIAL=/
#   SUFFIX=/DIST_PORT= for MobCi.Farm to parse.
up_auto() {
  local apk=$1 otp=$2 base=${3:-ci} w=${4:-1080} h=${5:-2340} dpi=${6:-440}
  [ -f "$apk" ] || { echo "ERR apk not found: $apk" >&2; exit 3; }
  [ -d "$otp" ] || { echo "ERR otp dir not found: $otp" >&2; exit 3; }

  exec 9>"$LOCK"; flock 9
  local n; n=$(running_count)
  if [ "$n" -ge "$CEILING" ]; then flock -u 9; echo "BUSY $n/$CEILING" >&2; exit 4; fi
  local used i=0
  used=" $(ci_indices | tr '\n' ' ') "
  while echo "$used" | grep -q " $i "; do i=$((i + 1)); done
  local hp; hp=$(host_port "$i")
  # Reserve the index by creating the container before releasing the lock.
  $DOCKER run -itd --privileged --name "ci-redroid$i" \
    -p "127.0.0.1:$hp:5555" "$BASE" \
    androidboot.redroid_width="$w" androidboot.redroid_height="$h" \
    androidboot.redroid_dpi="$dpi" androidboot.redroid_fps=30 >/dev/null
  flock -u 9

  _boot_install_launch "$i" "$apk" "$otp" "$base"
  echo "INDEX=$i"
  echo "SERIAL=$(serial "$i")"
  echo "SUFFIX=${base}$i"
  echo "DIST_PORT=$(dist_port "$i")"
}

_boot_install_launch() {
  local i=$1 apk=$2 otp=$3 base=$4 ser dp pkg uid
  ser=$(serial "$i"); dp=$(dist_port "$i")
  echo ">> [ci-redroid$i] waiting for boot_completed ($ser)..." >&2
  $ADB connect "$ser" >/dev/null 2>&1 || true
  for _ in $(seq 1 90); do
    [ "$($ADB -s "$ser" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
    sleep 2
  done

  echo ">> [ci-redroid$i] installing APK" >&2
  $ADB -s "$ser" install -r --abi x86_64 "$apk" >/dev/null
  pkg=$(_apk_package "$apk")
  uid=$($ADB -s "$ser" shell dumpsys package "$pkg" 2>/dev/null | grep -m1 userId= | tr -d '\r' | sed -E 's/.*userId=([0-9]+).*/\1/')
  echo ">> [ci-redroid$i] pkg=$pkg uid=$uid; injecting OTP" >&2
  $DOCKER exec "ci-redroid$i" mkdir -p "/data/data/$pkg/files"
  $DOCKER cp "$otp" "ci-redroid$i:/data/data/$pkg/files/otp"
  $DOCKER exec "ci-redroid$i" chown -R "$uid:$uid" "/data/data/$pkg"
  $DOCKER exec "ci-redroid$i" restorecon -R "/data/data/$pkg" 2>/dev/null || true

  ensure_epmd
  echo ">> [ci-redroid$i] tunnels (reverse 4369, forward $dp) + launch suffix=${base}$i" >&2
  $ADB -s "$ser" reverse tcp:4369 tcp:4369 >/dev/null
  $ADB -s "$ser" forward "tcp:$dp" "tcp:$dp" >/dev/null
  $ADB -s "$ser" shell am start -n "$pkg/.MainActivity" \
    --es mob_node_suffix "${base}$i" --ei mob_dist_port "$dp" >/dev/null
}

# Resolve an APK's package name via aapt (Android SDK build-tools) — falls back
# to the manifest dump if a specific aapt path isn't on PATH.
_apk_package() {
  local apk=$1 aapt
  aapt=$(command -v aapt || command -v aapt2 || echo "")
  if [ -z "$aapt" ]; then
    aapt=$(ls -1 "$HOME"/Android/Sdk/build-tools/*/aapt 2>/dev/null | sort -V | tail -1 || true)
  fi
  [ -n "$aapt" ] || { echo "ERR aapt not found (need Android build-tools)" >&2; exit 5; }
  "$aapt" dump badging "$apk" | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -1
}

down() {
  local i=$1
  $DOCKER rm -f "ci-redroid$i" >/dev/null 2>&1 || true
  $ADB disconnect "$(serial "$i")" >/dev/null 2>&1 || true
  echo "removed ci-redroid$i"
}

nuke() { for c in $($DOCKER ps -a --format '{{.Names}}' | grep -E '^ci-redroid[0-9]+$'); do $DOCKER rm -f "$c" >/dev/null; echo "removed $c"; done; }

status() {
  echo "== ci containers =="; $DOCKER ps --filter 'name=ci-redroid' --format '  {{.Names}}\t{{.Status}}\t{{.Ports}}'
  echo "== admission =="; admit
}

cmd=${1:-status}
case "$cmd" in
  up-auto) shift; up_auto "$@";;
  down)    down "${2:?ci index}";;
  admit)   admit;;
  indices) ci_indices;;
  nuke)    nuke;;
  status)  status;;
  pkg)     _apk_package "${2:?apk path}";;
  *) echo "usage: $0 {up-auto <apk> <otp_dir> <suffix_base> [W H DPI]|down <i>|admit|indices|nuke|status|pkg <apk>}"; exit 2;;
esac
