#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_registered_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for registered custom checks"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

test_resolved_reply_history_does_not_starve_wakes() {
  local home status out i corr
  home=$(make_home reply-history)
  mkdir -p "$home/state/pending-replies"
  for ((i=0; i<1600; i++)); do
    printf 'corr_id=history-%s\ntask_id=retired\nphase=resolved\n' "$i" \
      > "$home/state/pending-replies/history-$i"
  done
  corr=$(FM_HOME="$home" bash -c '
    . "$1"
    corr=$(fm_pending_reply_create "$2" "$2/state" demo "active request through retained history")
    fm_pending_reply_mark_delivered "$2/state" "$corr"
    printf "%s" "$corr"
  ' _ "$ROOT/bin/fm-pending-reply-lib.sh" "$home")
  : > "$home/state/demo.meta"
  printf 'done: history does not block this wake corr=%s\n' "$corr" > "$home/state/demo.status"
  status=0
  out=$(FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 10 2>&1) || status=$?
  expect_code 0 "$status" "retained reply history starved the foreground watcher"
  assert_contains "$out" 'signal:' "ready status was not delivered through retained reply history"
  [ -f "$home/state/pending-replies/history-1599" ] || fail "watcher discarded retained reply history"
  grep -q '^phase=resolved$' "$home/state/pending-replies/$corr" || fail "active pending report was skipped through retained history"
  pass "1600 settled replies stay durable while an active report resolves and its task wake is delivered"
}

test_interruption_reaps_only_the_owned_watcher() {
  local mode home checkpoint_pid watcher_pid status i
  for mode in timeout perl; do
    home=$(make_home "interrupt-$mode")
    (
      if [ "$mode" = perl ]; then
        command() {
          case "$*" in '-v timeout'|'-v gtimeout') return 1 ;; esac
          builtin command "$@"
        }
        export -f command
      fi
      exec env FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 \
        FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 30 >"$home/out" 2>"$home/err"
    ) &
    checkpoint_pid=$!
    watcher_pid=
    for ((i=0; i<100; i++)); do
      if [ -f "$home/state/.watch.lock/pid" ]; then
        watcher_pid=$(cat "$home/state/.watch.lock/pid")
        break
      fi
      sleep 0.05
    done
    [ -n "$watcher_pid" ] || fail "$mode checkpoint did not publish its owned watcher"
    kill -TERM "$checkpoint_pid"
    status=0
    wait "$checkpoint_pid" || status=$?
    expect_code 143 "$status" "$mode checkpoint interruption exit"
    assert_absent "$home/state/.watch.lock/pid" "$mode cancellation left a watcher singleton"
    if kill -0 "$watcher_pid" 2>/dev/null; then
      fail "$mode cancellation left its watcher process running"
    fi
    pass "$mode checkpoint cancellation reaps its own watcher and releases the singleton"
  done
}

test_startup_recovery_failure_retains_evidence() {
  python3 - "$ROOT" "$TMP_ROOT" <<'PYTEST' || fail "startup recovery failure discarded evidence"
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
root = Path(sys.argv[1])
home = Path(sys.argv[2]) / 'startup-marker-refusal'
state = home / 'state'
fakebin = home / 'bin'
state.mkdir(parents=True)
fakebin.mkdir()
marker = state / '.watcher-down'
marker.write_text('announced:downtime:fixture\n')
real_mv = shutil.which('mv')
(fakebin / 'mv').write_text('''#!/usr/bin/env bash
last=
for arg in "$@"; do last=$arg; done
[ "$last" != "$FM_TEST_REFUSED_MARKER" ] || exit 1
exec ''' + shlex.quote(real_mv) + ' "$@"\n')
(fakebin / 'mv').chmod(0o755)
env = os.environ.copy()
env.update(FM_HOME=str(home), FM_STATE_OVERRIDE=str(state), FM_TEST_REFUSED_MARKER=str(marker), PATH=str(fakebin) + os.pathsep + env['PATH'])
result = subprocess.run([str(root / 'bin/fm-watch-checkpoint.sh'), '--seconds', '5'], env=env, text=True, capture_output=True)
assert result.returncode == 1, result
assert 'retaining stale lock evidence' in result.stdout + result.stderr, result
pid = int((state / '.watch.lock/pid').read_text())
try:
    os.kill(pid, 0)
except ProcessLookupError:
    pass
else:
    raise AssertionError('failed startup still has a live watcher')
assert marker.read_text() == 'announced:downtime:fixture\n', 'refused recovery transaction changed the old receipt'
PYTEST
  pass "explicit startup recovery-state failure keeps its dead lock and prior receipt"
}

test_resolved_reply_history_does_not_starve_wakes
test_startup_recovery_failure_retains_evidence
test_interruption_reaps_only_the_owned_watcher
test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
