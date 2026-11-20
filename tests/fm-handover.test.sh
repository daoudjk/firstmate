#!/usr/bin/env bash
# tests/fm-handover.test.sh - behavior tests for bin/fm-handover.sh, the
# supervisor-to-supervisor handover record, and bin/fm-lock.sh release.
#
# Coverage:
#   - prepare refuses a live worker with no backlog item, naming the command
#     that fixes it, refuses an open decision that no captain hold covers, and
#     reports ready once both are fixed
#   - write builds state/handover.json and the readable summary from fixture
#     records: worker identity, git facts, intent, next step from --next and
#     from the worker's HANDOFF.md, held decisions; it refuses over gaps and
#     over a pending record without --replace
#   - accept refuses while a resume worker is neither relaunched nor marked,
#     and consumes the record once it is
#   - status reports nothing pending, and release refuses without a record
#   - fm-lock.sh release frees this session's own lock and refuses another's
# The digest section itself is covered in tests/fm-session-start.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

HANDOVER="$ROOT/bin/fm-handover.sh"
TMP_ROOT=$(fm_test_tmproot fm-handover-tests)
fm_git_identity fmtest fmtest@example.invalid

# new_home <name>: a home with a markdown backlog, a worker local copy on
# branch fm/<name>, and a fakebin whose tmux reports every recorded window as an
# idle pane. Echoes "<home>|<fakebin>|<local-copy>".
new_home() {
  local name=$1 dir home fakebin wt
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  wt="$dir/wt"
  mkdir -p "$home/state" "$home/data" "$home/config"
  fm_test_tasks_toml "$home/.tasks.toml"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) sed -n 's/^window=[^:]*://p' "$FM_HOME"/state/*.meta 2>/dev/null ;;
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/no-mistakes"
  chmod +x "$fakebin/tmux" "$fakebin/no-mistakes"
  fm_git_init_commit "$wt"
  git -C "$wt" checkout -q -b "fm/$name"
  printf '%s|%s|%s\n' "$home" "$fakebin" "$wt"
}

hand() {  # <home> <fakebin> <args...>
  local home=$1 fakebin=$2
  shift 2
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_CREW_STATE_NO_FORGE=1 "$HANDOVER" "$@"
}

backlog() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" "$@" >/dev/null
}

# add_worker <home> <id> <local-copy> <harness> [status-line]: a live worker
# record whose current state reads from its own status line, as an idle pane
# with a declared wait does.
add_worker() {
  local home=$1 id=$2 wt=$3 harness=$4 line=${5:-"paused [at=1795190000]: waiting for review"} gen
  fm_write_meta "$home/state/$id.meta" "window=fmh:$id" "worktree=$wt" "harness=$harness" \
    "kind=ship" "mode=local-only" "branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD)" \
    "model=model-$id" "spawn_gen=s-$id"
  printf '%s\n' "$line" > "$home/state/$id.status"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" "$id" idle --gen "$gen" \
    --source claude-hook --event stop >/dev/null
}

test_prepare_refuses_worker_without_backlog_item() {
  local rec home fakebin wt out rc
  rec=$(new_home prep)
  IFS='|' read -r home fakebin wt <<EOF
$rec
EOF
  add_worker "$home" alpha "$wt" claude
  backlog "$home" add alpha 'Alpha work' --kind ship
  backlog "$home" start alpha
  add_worker "$home" orphan "$wt" claude

  out=$(hand "$home" "$fakebin" prepare 2>&1)
  rc=$?
  expect_code 1 "$rc" "prepare accepted a live worker with no backlog item: $out"
  assert_contains "$out" "GAP backlog orphan: live worker with no backlog item" "the missing item was not named"
  assert_contains "$out" "bin/fm-tasks-axi.sh add orphan" "the gap did not name the command that fixes it"
  assert_not_contains "$out" "GAP backlog alpha" "a worker with a backlog item was reported missing"
  assert_contains "$out" "prepare: 1 gap(s)" "the gap count is wrong"
  assert_absent "$home/state/handover.json" "prepare wrote a record"

  backlog "$home" add orphan 'Orphan work' --kind ship
  backlog "$home" start orphan
  printf '%s\n' "needs-decision [key=route] [at=1795190100]: choose route one or two" >> "$home/state/alpha.status"
  out=$(hand "$home" "$fakebin" prepare 2>&1)
  rc=$?
  expect_code 1 "$rc" "prepare accepted an open decision with no captain hold: $out"
  assert_contains "$out" "GAP decision alpha [key=route]" "the unheld decision was not named"
  assert_contains "$out" "bin/fm-captain-hold.sh hold alpha" "the decision gap did not name the hold command"

  FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" hold alpha --reason 'choose route one or two' >/dev/null
  out=$(hand "$home" "$fakebin" prepare 2>&1)
  rc=$?
  expect_code 0 "$rc" "prepare still refused after every gap was fixed: $out"
  assert_contains "$out" "prepare: ready - 2 worker(s)" "prepare did not report ready"
  pass "prepare refuses a worker with no backlog item and an unheld decision, naming each fix"
}

test_write_builds_record_from_fixture_records() {
  local rec home fakebin wt out rc head goal summary
  rec=$(new_home write)
  IFS='|' read -r home fakebin wt <<EOF
$rec
EOF
  add_worker "$home" alpha "$wt" claude
  add_worker "$home" beta "$wt" claude
  backlog "$home" add alpha 'Alpha work' --kind ship
  backlog "$home" start alpha
  backlog "$home" add beta 'Beta work' --kind ship
  backlog "$home" start beta
  mkdir -p "$home/data/beta"
  printf '# Beta handoff\n\nContext line.\n\n## Next steps\n\nRun the image build and record the result.\n' > "$home/data/beta/HANDOFF.md"
  printf 'dirty\n' > "$wt/scratch.txt"
  goal="$TMP_ROOT/write/goal.txt"
  printf 'Finish the observation pipeline integration.\n' > "$goal"
  head=$(git -C "$wt" rev-parse HEAD)

  out=$(hand "$home" "$fakebin" write --goal-file "$goal" --next 'alpha=rerun the unit tests' --hold beta 2>&1)
  rc=$?
  expect_code 0 "$rc" "write failed on a ready fleet: $out"
  assert_present "$home/state/handover.json" "write did not publish the record"
  assert_equals "$(jq -r .schema "$home/state/handover.json")" fm-handover.v1 "wrong schema"
  assert_equals "$(jq -c .goal "$home/state/handover.json")" '"Finish the observation pipeline integration.\n"' \
    "the goal text was not recorded verbatim"
  assert_equals "$(jq -r '.workers | map(.id) | join(",")' "$home/state/handover.json")" "alpha,beta" "worker list"
  assert_equals "$(jq -r '.workers[] | select(.id=="alpha") | [.intent, .harness, .model, .branch, .head, (.dirty|tostring), .next] | join("|")' "$home/state/handover.json")" \
    "resume|claude|model-alpha|fm/write|$head|true|rerun the unit tests" "alpha's recorded facts"
  assert_equals "$(jq -r '.workers[] | select(.id=="beta") | [.intent, .next] | join("|")' "$home/state/handover.json")" \
    "hold|Run the image build and record the result." "beta's intent and HANDOFF.md next step"
  assert_contains "$(jq -r '.workers[] | select(.id=="alpha") | .current_state' "$home/state/handover.json")" "state: paused" \
    "the crew-state line was not recorded"
  summary=$(jq -r .summary_path "$home/state/handover.json")
  assert_present "$summary" "the readable summary was not written"
  assert_grep "Finish the observation pipeline integration." "$summary" "the summary lost the goal"
  assert_grep "rerun the unit tests" "$(jq -r '.workers[] | select(.id=="alpha") | .note_file' "$home/state/handover.json")" \
    "alpha's relaunch note lost its next step"
  [ "$(tail -1 "$home/state/alpha.status")" = "paused [at=1795190000]: waiting for review" ] \
    || fail "write appended a worker status line"

  out=$(hand "$home" "$fakebin" write 2>&1)
  rc=$?
  expect_code 1 "$rc" "write replaced a pending record without --replace"
  assert_contains "$out" "already pending" "the pending refusal was not explained"

  out=$(hand "$home" "$fakebin" status --digest 2>&1)
  assert_contains "$out" "resume  alpha" "status lost the resume row"
  assert_contains "$out" "hold  beta" "status lost the hold row"
  assert_contains "$out" "a quiet queue is NOT progress" "status lost the parked-fleet line"

  rm -f "$home/state/handover.json"
  add_worker "$home" gamma "$wt" claude
  out=$(hand "$home" "$fakebin" write 2>&1)
  rc=$?
  expect_code 1 "$rc" "write published a record over an open gap"
  assert_contains "$out" "GAP backlog gamma" "write did not name the gap it refused over"
  assert_absent "$home/state/handover.json" "write left a record behind after refusing"
  pass "write records workers, intent, next steps, and goal from the authoritative records and refuses over gaps"
}

test_accept_refuses_until_resume_rows_are_relaunched() {
  local rec home fakebin wt out rc
  rec=$(new_home accept)
  IFS='|' read -r home fakebin wt <<EOF
$rec
EOF
  add_worker "$home" alpha "$wt" claude
  add_worker "$home" beta "$wt" claude
  backlog "$home" add alpha 'Alpha work' --kind ship
  backlog "$home" start alpha
  backlog "$home" add beta 'Beta work' --kind ship
  backlog "$home" start beta
  hand "$home" "$fakebin" write >/dev/null 2>&1 || fail "write failed on a ready fleet"

  out=$(hand "$home" "$fakebin" resume-plan 2>&1)
  assert_contains "$out" "bin/fm-control.sh alpha relaunch" "resume-plan did not print alpha's relaunch"
  assert_contains "$out" "--note-file $home/data/handover/" "resume-plan did not pass the recorded note"

  out=$(hand "$home" "$fakebin" accept 2>&1)
  rc=$?
  expect_code 1 "$rc" "accept consumed a handover with resume rows not relaunched"
  assert_contains "$out" "alpha" "accept did not name the pending worker"
  assert_present "$home/state/handover.json" "a refused accept moved the record"

  # A relaunch republishes the worker's record with a new spawn_gen.
  sed -i.bak 's/^spawn_gen=.*/spawn_gen=s-alpha-2/' "$home/state/alpha.meta" && rm -f "$home/state/alpha.meta.bak"
  out=$(hand "$home" "$fakebin" accept 2>&1)
  rc=$?
  expect_code 1 "$rc" "accept ignored beta, which is still neither relaunched nor marked"
  assert_contains "$out" "beta" "accept did not name beta"
  assert_not_contains "$out" "  alpha" "a relaunched worker was still reported pending"

  hand "$home" "$fakebin" mark beta running >/dev/null 2>&1 || fail "mark refused a recorded worker"
  out=$(hand "$home" "$fakebin" accept 2>&1)
  rc=$?
  expect_code 0 "$rc" "accept refused once every resume row was relaunched or marked: $out"
  assert_absent "$home/state/handover.json" "accept left the pending record in place"
  set -- "$home"/state/handover.accepted.*.json
  [ "$#" -eq 1 ] && [ -f "$1" ] || fail "accept did not keep exactly one accepted copy"
  out=$(hand "$home" "$fakebin" status 2>&1)
  assert_equals "$out" "handover: none pending" "status still reports a consumed handover"
  pass "accept refuses while a resume row is neither relaunched nor marked, then consumes the record"
}

test_release_requires_a_record() {
  local rec home fakebin wt out rc
  rec=$(new_home release)
  IFS='|' read -r home fakebin wt <<EOF
$rec
EOF
  out=$(hand "$home" "$fakebin" release 2>&1)
  rc=$?
  expect_code 1 "$rc" "release ran with no handover written"
  assert_contains "$out" "no handover is pending" "the refusal did not say why"
  pass "release refuses until write has run"
}

# fm-lock.sh resolves its owner from the process ancestry. This fake ps names
# only the test shell (and the stand-in other session) a claude harness and
# reports real parents, so the test shell is the stable owning session.
test_lock_release_frees_only_this_sessions_lock() {
  local dir fakebin out rc other='' owner=$$
  dir="$TMP_ROOT/lock"
  mkdir -p "$dir/state"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
pid=
previous=
for argument in "$@"; do
  [ "$previous" = -p ] && pid=$argument
  previous=$argument
done
case "$*" in
  *comm=*) if [ "$pid" = "$FM_TEST_OWNER_PID" ] || [ "$pid" = "${FM_TEST_OTHER_PID:-}" ]; then printf '/usr/local/bin/claude\n'; else printf '/bin/bash\n'; fi ;;
  *args=*) if [ "$pid" = "$FM_TEST_OWNER_PID" ] || [ "$pid" = "${FM_TEST_OTHER_PID:-}" ]; then printf 'claude\n'; else printf 'bash\n'; fi ;;
  *) exec /bin/ps "$@" ;;
esac
SH
  chmod +x "$fakebin/ps"
  lock() {
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_TEST_OWNER_PID="$owner" FM_TEST_OTHER_PID="${other:-}" \
      PATH="$fakebin:$PATH" FM_HOME="$dir" "$ROOT/bin/fm-lock.sh" "$@"
  }

  out=$(lock 2>&1) || fail "acquire failed: $out"
  out=$(lock release 2>&1)
  rc=$?
  expect_code 0 "$rc" "release refused this session's own lock: $out"
  assert_contains "$out" "lock released" "release did not report the release"
  assert_absent "$dir/state/.lock" "release left the lock file"
  out=$(lock release 2>&1)
  assert_equals "$out" "lock: already free" "a second release is not idempotent"

  sleep 30 &
  other=$!
  printf '%s\n' "$other" > "$dir/state/.lock"
  out=$(lock release 2>&1)
  rc=$?
  kill "$other" 2>/dev/null || true
  expect_code 1 "$rc" "release removed a lock another live session holds"
  assert_contains "$out" "another live firstmate session holds the lock" "the refusal did not name the holder"
  assert_equals "$(cat "$dir/state/.lock")" "$other" "a refused release changed the lock"
  pass "fm-lock.sh release frees this session's own lock and refuses another session's"
}

test_prepare_refuses_worker_without_backlog_item
test_write_builds_record_from_fixture_records
test_accept_refuses_until_resume_rows_are_relaunched
test_release_requires_a_record
test_lock_release_frees_only_this_sessions_lock

echo "# fm-handover.test.sh: all assertions passed"
