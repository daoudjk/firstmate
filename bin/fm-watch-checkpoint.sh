#!/usr/bin/env bash
# Run one bounded foreground watcher checkpoint for harnesses that should not
# rely on background-task completion to wake the model.
#
# SUPERVISION HOST. A home opted in with config/supervision-host
# (docs/configuration.md "Supervision host" owns the gate;
# config/supervision-host-off opts out, and a Codex home without the file does not run the host) runs
# bin/fm-supervision-host.sh in the watcher's place for the checkpoint's bound,
# as the host's park boundary; the host takes away-posture wakes itself and
# returns only when main is needed (its header owns the output read here).
# While an away record state/.afk-contract exists (never quiet mode's, whose
# captain is present: bin/fm-afk-contract.sh mode), the bound is
# raised to FM_CODEX_WATCH_CHECKPOINT_AWAY (default 3600) when that is longer,
# so a parked main is not woken every few minutes; an engine turn that starts
# before the bound may finish after it. A close that carries a wake or a
# "supervision-host:" line other than the park boundary passes through as a
# wake; the boundary alone is the ordinary quiet checkpoint. On a home that
# does not run the host nothing below changes.
# --stop-owned selects the native Codex Stop boundary: the host keeps its own
# park and engine handling, with a 540-second turn limit and a 550-second outer
# watchdog plus 40 seconds for cleanup inside the hook's 600 seconds. Away widening applies only to
# standalone checkpoints. Cancellation reaps only this checkpoint's owned
# watcher or host; fm-watch.sh owns its sleeps, check groups and event waits.
# Both timers keep their child in the caller's process group so native hook
# cancellation reaches it even when the hook shell cannot run its EXIT trap.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SECONDS_ARG=${FM_CODEX_WATCH_CHECKPOINT:-180}
STOP_OWNED=0

usage() {
  cat <<'EOF'
Usage: fm-watch-checkpoint.sh [--seconds <n>] [--stop-owned]

Run bin/fm-watch.sh in the foreground for a bounded checkpoint.
On an actionable watcher wake, pass through the watcher output and exit 0.
On a quiet checkpoint, print "checkpoint: no actionable wake within <n>s" and exit 124.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --stop-owned) STOP_OWNED=1; shift ;;
    --seconds)
      [ "$#" -gt 1 ] || { echo "error: --seconds requires a value" >&2; exit 2; }
      SECONDS_ARG=$2
      shift 2
      ;;
    --seconds=*)
      SECONDS_ARG=${1#--seconds=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$SECONDS_ARG" in
  ''|*[!0-9]*) echo "error: --seconds must be a positive integer" >&2; exit 2 ;;
  0) echo "error: --seconds must be greater than zero" >&2; exit 2 ;;
esac

# A checkpoint is neither an ordinary watcher start nor an Option B handling
# successor. It keeps an announced recovery episode stable while preserving the
# watcher's ordinary recovery of a generation that becomes pending.
export FM_WATCH_FOREGROUND_CHECKPOINT=1

OUT=$(mktemp "${TMPDIR:-/tmp}/fm-watch-checkpoint.out.XXXXXX") || exit 1
ERR=$(mktemp "${TMPDIR:-/tmp}/fm-watch-checkpoint.err.XXXXXX") || {
  rm -f "$OUT"
  exit 1
}
CHECKPOINT_PID=
# shellcheck disable=SC2329 # Registered by the EXIT trap below.
cleanup_checkpoint() {
  local watcher_pid watcher_parent
  if [ -n "$CHECKPOINT_PID" ]; then
    watcher_pid=$(cat "$STATE/.watch.lock/pid" 2>/dev/null || true)
    watcher_parent=
    case "$watcher_pid" in
      ''|*[!0-9]*) ;;
      *) watcher_parent=$(ps -o ppid= -p "$watcher_pid" 2>/dev/null | tr -d ' ') ;;
    esac
    if [ "$watcher_parent" = "$CHECKPOINT_PID" ]; then
      # Signal the owned watcher first so the timeout parent reaps it normally.
      # Signalling GNU timeout first can return before the watcher EXIT cleanup.
      kill -TERM "$watcher_pid" 2>/dev/null || true
    else
      kill -TERM "$CHECKPOINT_PID" 2>/dev/null || true
    fi
    wait "$CHECKPOINT_PID" 2>/dev/null || true
  fi
  rm -f "$OUT" "$ERR"
}
trap cleanup_checkpoint EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

run_with_perl_timeout() {  # <seconds> <signal> <kill-after-seconds> <command...>
  exec perl -e '
    use POSIX qw(:sys_wait_h);
    my $seconds = shift;
    my $signal = shift;
    my $kill_after = shift;
    my $pid = fork;
    die "fork failed\n" unless defined $pid;
    if (!$pid) {
      $SIG{INT} = $SIG{TERM} = $SIG{HUP} = "DEFAULT";
      exec @ARGV;
      die "exec failed: $!\n";
    }
    my $timed_out = 0;
    local $SIG{ALRM} = sub {
      if ($timed_out) {
        kill "KILL", $pid;
        waitpid $pid, 0;
        exit 124;
      }
      $timed_out = 1;
      kill $signal, $pid;
      alarm($kill_after) if $kill_after;
    };
    my $cancel = sub {
      kill "TERM", $pid;
      alarm($kill_after || 5);
      $timed_out = 1;
    };
    local $SIG{HUP} = $cancel;
    local $SIG{INT} = $cancel;
    local $SIG{TERM} = $cancel;
    alarm $seconds;
    while (1) {
      my $waited = waitpid $pid, WNOHANG;
      if ($waited == $pid) {
        alarm 0;
        exit($timed_out ? 124 : ($? >> 8));
      }
      select undef, undef, undef, 0.05;
    }
  ' "$@"
}

run_bounded() {  # <seconds> <signal> <kill-after-seconds> <command...>
  local seconds=$1 signal=$2 kill_after=$3 cleanup_lock_bound
  shift 3
  if [ "$kill_after" -gt 0 ]; then
    cleanup_lock_bound=${FM_WATCHER_CLEANUP_LOCK_BOUND:-2}
    case "$cleanup_lock_bound" in
      ''|*[!0-9]*) cleanup_lock_bound=2 ;;
      *) cleanup_lock_bound=$((10#$cleanup_lock_bound)) ;;
    esac
    [ "$cleanup_lock_bound" -gt 0 ] || cleanup_lock_bound=2
    [ "$cleanup_lock_bound" -gt "$kill_after" ] || cleanup_lock_bound=$kill_after
    kill_after=$cleanup_lock_bound
  fi
  if command -v timeout >/dev/null 2>&1; then
    if [ "$kill_after" -gt 0 ]; then
      exec timeout --foreground --signal="$signal" --kill-after="${kill_after}s" "$seconds" "$@"
    else
      exec timeout --foreground --signal="$signal" "$seconds" "$@"
    fi
  elif command -v gtimeout >/dev/null 2>&1; then
    if [ "$kill_after" -gt 0 ]; then
      exec gtimeout --foreground --signal="$signal" --kill-after="${kill_after}s" "$seconds" "$@"
    else
      exec gtimeout --foreground --signal="$signal" "$seconds" "$@"
    fi
  else
    run_with_perl_timeout "$seconds" "$signal" "$kill_after" "$@"
  fi
}

run_checkpoint() {
  run_bounded "$@" >"$OUT" 2>"$ERR" &
  CHECKPOINT_PID=$!
  RC=0
  wait "$CHECKPOINT_PID" || RC=$?
  CHECKPOINT_PID=
}

positive_or() {  # <value> <default>
  case "$1" in ''|0*|*[!0-9]*) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac
}

# shellcheck source=bin/fm-supervision-engine-lib.sh
. "$SCRIPT_DIR/fm-supervision-engine-lib.sh"
if fm_supervision_host_enabled "$CONFIG" codex; then
  BOUND=$SECONDS_ARG
  if [ -f "$STATE/.afk-contract" ] \
    && [ "$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-afk-contract.sh" mode 2>/dev/null)" != quiet ]; then
    AWAY_BOUND=$(positive_or "${FM_CODEX_WATCH_CHECKPOINT_AWAY:-}" 3600)
    [ "$AWAY_BOUND" -le "$BOUND" ] 2>/dev/null || BOUND=$AWAY_BOUND
  fi
  # The host's park boundary stays below the 28800-second registration.
  [ "$BOUND" -lt 27000 ] 2>/dev/null || BOUND=27000
  LIMIT=$(( BOUND + $(positive_or "${FM_SUPERVISION_HOST_TURN_TIMEOUT:-}" 1200) + $(positive_or "${FM_SUPERVISION_ENGINE_GRACE:-}" 30) ))
  if [ "$STOP_OWNED" -eq 1 ]; then
    # Native Stop has a 600-second registration. Reserve cleanup headroom,
    # and let the host return a close whose engine could exceed this limit.
    BOUND=$SECONDS_ARG
    [ "$BOUND" -le 540 ] || { echo "error: Stop checkpoint exceeds 540s" >&2; exit 2; }
    LIMIT=540
    TURN_BOUND=$(positive_or "${FM_SUPERVISION_HOST_TURN_TIMEOUT:-}" 1200)
    ENGINE_GRACE=$(positive_or "${FM_SUPERVISION_ENGINE_GRACE:-}" 30)
    AVAILABLE=$((LIMIT - BOUND - ENGINE_GRACE - 1))
    [ "$AVAILABLE" -gt 0 ] || AVAILABLE=1
    [ "$TURN_BOUND" -le "$AVAILABLE" ] || TURN_BOUND=$AVAILABLE
    export FM_SUPERVISION_HOST_TURN_TIMEOUT=$TURN_BOUND
    OUTER_LIMIT=550
    HOST_KILL_AFTER=40
  else
    OUTER_LIMIT=$((LIMIT + 120))
    HOST_KILL_AFTER=0
  fi
  set +e
  # The host ends its own park; the outer bound only catches a host that
  # outlived every one of its own bounds.
  FM_SUPERVISION_HOST_PRIMARY=codex FM_SUPERVISION_HOST_PARK_SECONDS=$BOUND FM_SUPERVISION_HOST_PARK_LIMIT=$LIMIT \
    run_checkpoint "$OUTER_LIMIT" TERM "$HOST_KILL_AFTER" "$SCRIPT_DIR/fm-supervision-host.sh" park
  set -e
  if grep -E '^(signal:|stale:|check:|heartbeat($|:)|supervision-host:)' "$OUT" 2>/dev/null \
    | grep -Ev '^supervision-host: cycle boundary' >/dev/null; then
    grep -Ev '^watcher: (started|attached) ' "$OUT"
    [ ! -s "$ERR" ] || cat "$ERR" >&2
    exit 0
  fi
  if grep -E '^supervision-host: cycle boundary' "$OUT" >/dev/null 2>&1; then
    printf 'checkpoint: no actionable wake within %ss\n' "$BOUND"
    exit 124
  fi
  [ ! -s "$OUT" ] || cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  if [ "$RC" -eq 124 ]; then
    echo "checkpoint: the supervision host outlived its own bound of ${BOUND}s" >&2
    exit 1
  fi
  [ "$RC" -ne 0 ] || RC=1
  exit "$RC"
fi

set +e
# Interrupt the watcher so its native EXIT cleanup retires its owned check group and releases its lock; ordinary shutdown still uses TERM.
run_checkpoint "$SECONDS_ARG" INT 5 "$SCRIPT_DIR/fm-watch.sh"
set -e

if grep -E '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" >/dev/null 2>&1; then
  cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  exit 0
fi

if grep -E '^watcher: already running' "$OUT" "$ERR" >/dev/null 2>&1; then
  [ ! -s "$OUT" ] || cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  echo "checkpoint: watcher is already running outside this foreground checkpoint" >&2
  exit 1
fi

if [ "$RC" -eq 124 ]; then
  printf 'checkpoint: no actionable wake within %ss\n' "$SECONDS_ARG"
  exit 124
fi

[ ! -s "$OUT" ] || cat "$OUT"
[ ! -s "$ERR" ] || cat "$ERR" >&2
exit "$RC"
