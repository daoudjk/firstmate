#!/usr/bin/env bash
# Portable behavior checks for the trusted Codex Stop checkpoint adapter.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-stop)
nonexistent_pid() {
  local pid=999999
  while kill -0 "$pid" 2>/dev/null; do pid=$((pid + 1)); done
  printf '%s\n' "$pid"
}
# The Codex Stop adapter is synchronous: each continuation must be backed by a
# real foreground checkpoint, including stops already marked as continued.
test_codex_stop_parks_repeatedly_and_refuses_unowned_locks() {
  local dir bin out status dead cadence_home
  dir="$TMP_ROOT/codex-stop-park"
  mkdir -p "$dir/state"
  git init -q "$dir"
  : > "$dir/AGENTS.md"
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-watch-checkpoint.sh" "$dir/bin/"
  # Use the complete production watcher and its dependencies, while the guard's
  # primary scope and operational home remain isolated to this fixture.
  cp "$ROOT"/bin/*.sh "$dir/bin/"
  mkdir -p "$dir/bin/backends"
  cp "$ROOT"/bin/backends/*.sh "$dir/bin/backends/"
  : > "$dir/state/task1.meta"
  bin="$dir/codex"
  cp "$(command -v bash)" "$bin"
  # shellcheck disable=SC2016 # The isolated harness shell expands its own variables.
  out=$(env -u CLAUDECODE -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID \
    FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_CODEX_WATCH_CHECKPOINT=1 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$bin" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      for active in false true true; do
        printf "{\"stop_hook_active\":%s}" "$active" | "$FM_HOME/bin/fm-turnend-guard.sh" --codex
        printf "guard-exit=%s\n" "$?"
      done
    ' 2>&1)
  [ "$(printf '%s\n' "$out" | grep -c '^guard-exit=2$')" -eq 3 ] \
    || fail "Codex stopped after its one-continuation budget: $out"
  assert_contains "$out" 'checkpoint: no actionable wake' "quiet Stop did not run a real checkpoint"
  assert_absent "$dir/state/.watch.lock/pid" "quiet checkpoint leaked a watcher"
  pass "Codex Stop runs three real bounded foreground cycles across false/true/true stops"

  mkdir -p "$dir/config"
  : > "$dir/config/supervision-host"
  # shellcheck disable=SC2016 # The isolated primary expands its own variables.
  out=$(env -u CLAUDECODE -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID \
    FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_CODEX_WATCH_CHECKPOINT=1 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$bin" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      for active in false true; do
        printf "{\"stop_hook_active\":%s}" "$active" | "$FM_HOME/bin/fm-turnend-guard.sh" --codex
        printf "host-guard-exit=%s\n" "$?"
      done
    ' 2>&1)
  [ "$(printf '%s\n' "$out" | grep -c '^host-guard-exit=2$')" -eq 2 ] \
    || fail "host broke repeated native Stop continuation: $out"
  assert_grep $'\tboundary\t' "$dir/state/.supervision-host.log" "native Stop did not run the real host"
  assert_absent "$dir/state/.watch.lock/pid" "host Stop checkpoint leaked its watcher"
  rm "$dir/config/supervision-host"
  pass "Codex Stop repeatedly runs the opted-in real supervision host within its native bound"

  cadence_home="$dir/cadence-home"
  mkdir -p "$cadence_home/config" "$cadence_home/state"
  printf 'export FM_CHECK_INTERVAL=1\n' > "$cadence_home/config/x-mode.env"
  cat > "$cadence_home/state/cadence.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'stop-child-cadence=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$cadence_home/state/cadence.check.sh"
  FM_HOME="$cadence_home" "$dir/bin/fm-check-register.sh" cadence >/dev/null || fail "could not register cadence check"
  touch "$cadence_home/state/.last-check"
  # shellcheck disable=SC2016
  out=$(env -u CLAUDECODE -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID \
    FM_HOME="$cadence_home" FM_ROOT_OVERRIDE="$dir" FM_CODEX_WATCH_CHECKPOINT=4 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$bin" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "{\"stop_hook_active\":false}" | "$FM_ROOT_OVERRIDE/bin/fm-turnend-guard.sh" --codex
      printf "guard-exit=%s\n" "$?"
    ' 2>&1)
  assert_contains "$out" 'stop-child-cadence=1' "Stop child did not load Relay cadence: $out"
  assert_contains "$out" 'guard-exit=2' "cadence wake did not continue Stop"
  rm -f "$cadence_home/config/x-mode.env" "$cadence_home/state/cadence.check.sh" "$cadence_home/state/cadence.check-trust"
  pass "actual Stop child loads the existing Relay cadence configuration"

  dead=$(nonexistent_pid)
  printf '%s\n' "$dead" > "$dir/state/.lock"
  status=0
  out=$(printf '{"stop_hook_active":true}' | FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" \
    "$dir/bin/fm-turnend-guard.sh" --codex 2>&1) || status=$?
  expect_code 0 "$status" "Codex cannot recover a stale session lock at Stop"
  assert_contains "$out" 'FIRSTMATE CODEX SUPERVISION STOPPED' "unowned-lock failure was silent"
  [ "$(cat "$dir/state/.lock")" = "$dead" ] || fail "Codex Stop rewrote the unowned session lock"
  assert_absent "$dir/state/.watch.lock/pid" "unowned Stop started a watcher"
  pass "Codex Stop reports a bounded visible failure and leaves a stale lock untouched"

  status=0
  # shellcheck disable=SC2016 # The isolated harness shell expands its own variables.
  out=$(FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_CODEX_WATCH_CHECKPOINT=541 \
    "$bin" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "{\"stop_hook_active\":true}" | "$FM_HOME/bin/fm-turnend-guard.sh" --codex
      printf "failure-first=%s\n" "$?"
      printf "{\"stop_hook_active\":true}" | "$FM_HOME/bin/fm-turnend-guard.sh" --codex
      printf "failure-second=%s\n" "$?"
    ' 2>&1) || status=$?
  expect_code 0 "$status" "Codex invalid Stop wait should permit an attended exit"
  assert_contains "$out" 'failure-first=2' "first failure did not force a visible model continuation"
  assert_contains "$out" 'failure-second=0' "repeated failure did not permit a bounded attended exit"
  assert_contains "$out" '540s maximum' "hook timeout overrun was not explained"
  assert_absent "$dir/state/.watch.lock/pid" "invalid Stop wait started a watcher"
  pass "Codex Stop rejects a wait longer than its hook timeout with a visible attended exit"
}

test_codex_stop_parks_repeatedly_and_refuses_unowned_locks
