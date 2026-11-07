#!/usr/bin/env bash
# tests/fm-system-map.test.sh - behavior of the opt-in living system map
# (bin/fm-system-map.sh): no-map inertness, read-only collection with failure
# retention, binding validation, version-bound evidence, scoped denial,
# collection concurrency, durable request dedupe, scheduler install/removal,
# task binding and completion semantics, coverage gaps, and the local UI's
# annotation and intended-design endpoints.
#
# Every case drives the public CLI or HTTP interface. AWS is a stand-in
# executable selected through FM_SYSTEM_MAP_AWS; systemd is a stand-in selected
# through FM_SYSTEM_MAP_SYSTEMCTL and FM_SYSTEM_MAP_UNIT_DIR.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MAP="$ROOT/bin/fm-system-map.sh"
SAMPLE="$ROOT/docs/examples/system-map"
TMP_ROOT=$(fm_test_tmproot fm-system-map-tests)
MAP_SERVER_PID=
stop_map_server() {
  [ -n "$MAP_SERVER_PID" ] || return 0
  pkill -TERM -P "$MAP_SERVER_PID" 2>/dev/null || true
  kill "$MAP_SERVER_PID" 2>/dev/null || true
  wait "$MAP_SERVER_PID" 2>/dev/null || true
  MAP_SERVER_PID=
}
trap 'stop_map_server; fm_test_cleanup' EXIT
command -v python3 >/dev/null 2>&1 || { echo "# skip: python3 is required for the system map"; exit 0; }

# new_home <name>: an enabled home with the tracked sample manifest, a fake
# aws, and isolated unit/systemctl seams. Prints the home path.
new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data/system-map/example" "$home/config" "$home/fakebin" "$home/units"
  cp "$SAMPLE/sample.config" "$home/config/system-map"
  cp "$SAMPLE/sample.manifest.json" "$home/data/system-map/example/manifest.json"
  cp "$SAMPLE/sample.bindings.json" "$home/data/system-map/example/bindings.json"
  cat > "$home/fakebin/aws" <<'PY'
#!/usr/bin/env python3
# Stand-in AWS CLI. Behavior comes from $FAKE_AWS_STATE (JSON):
#   deny: [service...]   answer AccessDenied for these services
#   account: "..."       sts account; ami: "..." instance image id
#   instance_state, ecs_running, sleep, fail_all
import json, os, sys, time
st = json.load(open(os.environ["FAKE_AWS_STATE"])) if os.path.exists(os.environ.get("FAKE_AWS_STATE", "")) else {}
args = sys.argv[1:]
svc, op = args[0], args[1]
with open(os.environ["FAKE_AWS_LOG"], "a") as log:
    log.write(" ".join(args) + "\n")
time.sleep(float(st.get("sleep", 0)))
def out(o):
    print(json.dumps(o)); sys.exit(0)
if st.get("fail_all"):
    sys.stderr.write("Could not connect to the endpoint URL"); sys.exit(255)
if svc in st.get("missing", []):
    sys.stderr.write("ResourceNotFoundException: resource does not exist"); sys.exit(254)
if svc in st.get("deny", []):
    sys.stderr.write("An error occurred (AccessDeniedException) when calling %s: User arn:aws:iam::123456789012:user/x is not authorized" % op); sys.exit(254)
if op == "get-role" and "--role-name" in args:
    role_name = args[args.index("--role-name") + 1]
    if role_name in st.get("role_responses", {}): out(st["role_responses"][role_name])
if op in st.get("responses", {}): out(st["responses"][op])
if op == "describe-task-definition" and "--include" not in args: sys.exit(23)
if svc == "sts": out({"Account": st.get("account", "123456789012"), "Arn": "arn:aws:iam::123456789012:user/fixture", "UserId": "fixture"})
if op == "get-function-configuration": out({"State": "Active", "CodeSha256": "code-v1", "LastUpdateStatus": "Successful", "Runtime": "python3.13", "Timeout": 30, "Role": "arn:aws:iam::123456789012:role/example", "Environment": {"Variables": {"EXAMPLE": "fixture-private-payload"}}})
if op == "get-schedule": out({"State": "ENABLED", "ScheduleExpression": "at(2099-01-01T00:00:00)", "ScheduleExpressionTimezone": "UTC", "TargetArn": "arn:aws:lambda:us-east-1:123456789012:function:example", "RoleArn": "arn:aws:iam::123456789012:role/example", "Input": "fixture-private-payload"})
if op == "get-role": out({"RoleId": "role-v1", "CreateDate": "2026-01-01T00:00:00Z", "MaxSessionDuration": 3600})
if op == "describe-services":
    n = int(st.get("ecs_running", 0))
    out({"services": [{"status": "ACTIVE", "desiredCount": n, "runningCount": n, "pendingCount": 0, "taskDefinition": "arn:aws:ecs:us-east-1:123456789012:task-definition/example-api:7"}]})
if op == "get-queue-url": out({"QueueUrl": "https://example.invalid/q"})
if op == "get-queue-attributes": out({"Attributes": {"ApproximateNumberOfMessages": str(st.get("queue_visible", 0)), "ApproximateNumberOfMessagesNotVisible": "0"}})
if op == "describe-table": out({"Table": {"TableStatus": "ACTIVE", "ItemCount": 1}})
if op == "get-item": out({"Item": {"Halted": {"BOOL": st.get("control_halted", True)}, "Revision": {"N": "7"}}})
if op == "describe-instances":
    out({"Reservations": [{"Instances": [{"State": {"Name": st.get("instance_state", "stopped")}, "ImageId": st.get("ami", "ami-0123456789abcdef0")}]}]})
sys.stderr.write("unhandled %s %s" % (svc, op)); sys.exit(255)
PY
  chmod +x "$home/fakebin/aws"
  cat > "$home/fakebin/systemctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_SYSTEMCTL_LOG"
SH
  chmod +x "$home/fakebin/systemctl"
  printf '{}\n' > "$home/aws-state.json"
  printf '%s\n' "$home"
}

# map <home> <args...>: run the CLI against a home with every seam pinned.
map() {
  local home=$1
  shift
  env FM_HOME="$home" FM_SYSTEM_MAP_AWS="$home/fakebin/aws" FM_SYSTEM_MAP_FIXTURE="${FM_SYSTEM_MAP_TEST_FIXTURE:-1}" \
    FAKE_AWS_STATE="$home/aws-state.json" FAKE_AWS_LOG="$home/aws.log" \
    FM_SYSTEM_MAP_SYSTEMCTL="$home/fakebin/systemctl" FM_SYSTEM_MAP_UNIT_DIR="$home/units" \
    FAKE_SYSTEMCTL_LOG="$home/systemctl.log" "$MAP" "$@"
}

aws_state() { printf '%s\n' "$2" > "$1/aws-state.json"; }

# jq-free JSON reads: py <file> <python expression over d>
py() {
  python3 - "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(eval(sys.argv[2], {"d": d}))
PY
}

view_json() {  # <home>: write the derived view (bin/fm-system-map.sh view) to <home>/view.json
  map "$1" view example --compact > "$1/view.json" || fail "view failed"
}

test_no_map_home_is_inert() {
  local home="$TMP_ROOT/plain" out rc
  mkdir -p "$home/state" "$home/config" "$home/data"
  for cmd in tick summary check "complete some-task --kind ship --mode no-mistakes"; do
    # shellcheck disable=SC2086
    out=$(FM_HOME="$home" "$MAP" $cmd 2>&1); rc=$?
    expect_code 0 "$rc" "passive '$cmd' without config"
    assert_equals "" "$out" "passive '$cmd' prints nothing without config"
  done
  rc=0; out=$(FM_HOME="$home" "$MAP" collect 2>&1) || rc=$?
  expect_code 1 "$rc" "collect without config"
  assert_contains "$out" "not enabled" "collect names the missing opt-in"
  assert_absent "$home/state/system-map" "no map state is created without config"
  assert_absent "$home/data/system-map" "no map data is created without config"
  pass "a home without config/system-map is unaffected"
}

test_collect_retains_last_success_on_partial_denial() {
  local home out
  home=$(new_home retain)
  out=$(map "$home" collect) || fail "first collect failed: $out"
  assert_contains "$out" "collected example: ok" "first collection succeeds"
  assert_equals "ok" "$(py "$home/state/system-map/example/snapshot.json" 'd["observations"]["api-ecs"]["outcome"]')" "ecs read ok"
  first_finished=$(py "$home/state/system-map/example/snapshot.json" 'd["finished_at"]')
  aws_state "$home" '{"deny": ["ecs"]}'
  sleep 1
  out=$(map "$home" collect) || fail "partial collect failed: $out"
  assert_contains "$out" "partial" "a denied read makes the collection partial, not ok"
  view_json "$home"
  assert_equals "denied" "$(py "$home/view.json" 'd["subjects"]["api"]["observations"][0]["current"]["outcome"]')" "the current read is denied"
  assert_equals "zero" "$(py "$home/view.json" 'd["subjects"]["api"]["observations"][0]["last_success"]["state"]')" "the last success is retained separately"
  assert_equals "denied" "$(py "$home/view.json" 'd["subjects"]["api"]["layers"]["runtime"]["status"]')" "runtime is denied, not as-intended"
  assert_not_contains "$(py "$home/view.json" 'd["subjects"]["api"]["observations"][0]["current"]["error"]')" "123456789012" "provider text is redacted"
  assert_equals "as-intended" "$(py "$home/view.json" 'd["subjects"]["queue"]["layers"]["runtime"]["status"]')" "unaffected reads stay current"
  # A collector-level failure keeps the previous snapshot untouched.
  printf 'not json' > "$home/data/system-map/example/bindings.json"
  map "$home" collect >/dev/null 2>&1 && fail "collect with unreadable bindings should fail"
  assert_equals "failed" "$(py "$home/state/system-map/example/health.json" 'd["last_status"]')" "health records the failed collection"
  assert_not_equals "$first_finished" "$(py "$home/state/system-map/example/snapshot.json" 'd["finished_at"]')" "the partial snapshot is still the published one"
  assert_equals "partial" "$(py "$home/state/system-map/example/snapshot.json" 'd["collector"]["status"]')" "failure did not overwrite the snapshot"
  pass "denied reads retain last success separately and a failed run keeps the snapshot"
}

test_scope_mismatch_skips_aws_reads() {
  local home
  home=$(new_home scope)
  python3 - "$home/data/system-map/example/bindings.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["scope"]["expected_account"] = "999999999999"; json.dump(d, open(p, "w"))
PY
  map "$home" collect >/dev/null || fail "collect failed"
  assert_equals "unknown" "$(py "$home/state/system-map/example/snapshot.json" 'd["observations"]["api-ecs"]["outcome"]')" "aws reads are unknown under an unverified scope"
  assert_equals "False" "$(py "$home/state/system-map/example/snapshot.json" 'd["scope"]["account_verified"]')" "scope is reported unverified"
  assert_no_grep "ecs describe-services" "$home/aws.log" "no read runs against the wrong account"
  assert_equals "ok" "$(py "$home/state/system-map/example/snapshot.json" 'd["observations"]["owner-task"]["outcome"] if d["observations"]["owner-task"]["outcome"] != "absent" else "ok"')" "local reads still run"
  pass "a credential/account mismatch skips AWS reads instead of reporting false state"
}

test_absent_response_matches_absent_intent() {
  local home
  home=$(new_home absent-intent)
  python3 - "$home/data/system-map/example/manifest.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as handle: manifest = json.load(handle)
next(subject for subject in manifest["components"] if subject["id"] == "api")["intended"]["idle"] = "absent"
with open(path, "w") as handle: json.dump(manifest, handle)
PY
  aws_state "$home" '{"missing": ["ecs"]}'
  map "$home" collect >/dev/null || fail "collection failed"
  view_json "$home"
  assert_equals "absent" "$(py "$home/view.json" 'd["subjects"]["api"]["observations"][0]["current"]["state"]')" "NotFound has an absent state"
  assert_equals "as-intended" "$(py "$home/view.json" 'd["subjects"]["api"]["layers"]["runtime"]["status"]')" "absence matches intended absence"
  pass "provider absence is normalized at observation intake"
}

test_failed_collection_preserves_success_time() {
  local home before
  home=$(new_home failed-success-time)
  python3 - "$home/data/system-map/example/manifest.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as handle: manifest = json.load(handle)
manifest["components"] = [subject for subject in manifest["components"] if subject["id"] not in ("source", "owner")]
next(subject for subject in manifest["components"] if subject["id"] == "console").pop("observe", None)
manifest["prerequisites"] = [item for item in manifest["prerequisites"] if item["id"] not in ("console-source", "console-config")]
with open(path, "w") as handle: json.dump(manifest, handle)
PY
  map "$home" collect >/dev/null || fail "initial collection failed"
  before=$(py "$home/state/system-map/example/health.json" 'd["last_success_at"]')
  aws_state "$home" '{"fail_all": true}'
  map "$home" collect >/dev/null || fail "failed-read collection did not publish"
  assert_equals "failed" "$(py "$home/state/system-map/example/health.json" 'd["last_status"]')" "all failed reads mark the collection failed"
  assert_equals "$before" "$(py "$home/state/system-map/example/health.json" 'd["last_success_at"]')" "all failed reads do not advance last success"
  pass "failed observations do not refresh collection success"
}

test_intent_revision_invalidates_observations() {
  local home
  home=$(new_home intent-revision)
  map "$home" collect >/dev/null || fail "initial collection failed"
  write_evidence "$home" old-resource ami-0123456789abcdef0 pass
  view_json "$home"
  assert_equals "proven" "$(py "$home/view.json" 'd["subjects"]["worker-host"]["layers"]["proof"]["status"]')" "initial resource has proof"
  python3 - "$home/data/system-map/example/manifest.json" "$home/data/system-map/example/bindings.json" "$home/new-manifest.json" <<'PY'
import json, sys
manifest_path, bindings_path, new_path = sys.argv[1:]
with open(manifest_path) as handle: manifest = json.load(handle)
worker = next(subject for subject in manifest["components"] if subject["id"] == "worker-host")
worker["observe"][0]["binding"] = "replacement_worker"
with open(new_path, "w") as handle: json.dump(manifest, handle)
with open(bindings_path) as handle: bindings = json.load(handle)
bindings["bindings"]["replacement_worker"] = {"instance_id": "i-0replacement00001", "pin": "ami-0replacement000", "label": "replacement"}
with open(bindings_path, "w") as handle: json.dump(bindings, handle)
PY
  map "$home" intent replace example "$home/new-manifest.json" --reason "replace worker" >/dev/null || fail "intent replacement failed"
  view_json "$home"
  assert_equals "unknown" "$(py "$home/view.json" 'd["subjects"]["worker-host"]["version_state"]')" "old snapshot version is unavailable under new intent"
  assert_equals "unknown" "$(py "$home/view.json" 'd["subjects"]["worker-host"]["layers"]["proof"]["status"]')" "old resource proof does not apply to replacement"
  assert_equals "True" "$(py "$home/view.json" 'd["collector"]["stale"]')" "collector reports stale after intent changes"
  pass "a new manifest revision invalidates old observations"
}

test_binding_change_invalidates_observations_and_history() {
  local home
  home=$(new_home binding-identity)
  map "$home" collect >/dev/null || fail "initial collection failed"
  write_evidence "$home" old-binding ami-0123456789abcdef0 pass
  view_json "$home"
  assert_equals "proven" "$(py "$home/view.json" 'd["subjects"]["worker-host"]["layers"]["proof"]["status"]')" "original binding has current proof"
  assert_equals "$(py "$home/state/system-map/example/snapshot.json" 'd["bindings_digest"]')" "$(py "$home/state/system-map/example/last-success.json" 'd["worker-ec2"]["bindings_digest"]')" "snapshot and successful reads share binding identity"
  python3 - "$home/data/system-map/example/bindings.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as handle: bindings = json.load(handle)
bindings["bindings"]["worker_host"]["instance_id"] = "i-0replacement00001"
with open(path, "w") as handle: json.dump(bindings, handle)
PY
  view_json "$home"
  assert_equals "unknown" "$(py "$home/view.json" 'd["subjects"]["worker-host"]["version_state"]')" "old version is unavailable after a binding change"
  assert_equals "unknown" "$(py "$home/view.json" 'd["subjects"]["worker-host"]["layers"]["proof"]["status"]')" "old proof is unavailable after a binding change"
  aws_state "$home" '{"deny": ["ec2"]}'
  map "$home" collect >/dev/null || fail "failed replacement read did not publish"
  view_json "$home"
  assert_equals "None" "$(py "$home/view.json" 'd["subjects"]["worker-host"]["observations"][0]["last_success"]')" "old resource is absent from last-success history"
  pass "binding identity gates current and historical observations"
}

test_resource_identity_qualifies_proof() {
  local home future out rc=0
  home=$(new_home resource-proof)
  map "$home" bind task-resource --subject worker-host >/dev/null || fail "binding failed"
  map "$home" complete task-resource --kind ship >/dev/null || fail "completion failed"
  map "$home" collect >/dev/null || fail "initial collection failed"
  future=$(date -u +%Y-%m-%dT%H:%M:%SZ -d '+1 minute' 2>/dev/null || date -u -v+1M +%Y-%m-%dT%H:%M:%SZ)
  write_evidence "$home" original-run ami-0123456789abcdef0 pass false "$future"
  view_json "$home"
  assert_equals "proven" "$(py "$home/view.json" 'd["subjects"]["worker-host"]["layers"]["proof"]["status"]')" "the original resource has matching proof"
  python3 - "$home/data/system-map/example/bindings.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as handle: bindings = json.load(handle)
bindings["bindings"]["worker_host"]["instance_id"] = "i-0replacement00001"
with open(path, "w") as handle: json.dump(bindings, handle)
PY
  map "$home" collect >/dev/null || fail "replacement collection failed"
  view_json "$home"
  assert_equals "ami-0123456789abcdef0" "$(py "$home/view.json" 'd["subjects"]["worker-host"]["version"]')" "replacement has the same observed version"
  assert_not_equals "$(py "$home/view.json" 'd["subjects"]["worker-host"]["resource_identity"]')" "$(py "$home/data/system-map/example/evidence/original-run.json" 'd["resource_identities"]["worker-host"]')" "replacement has a distinct identity"
  assert_equals "stale" "$(py "$home/view.json" 'd["subjects"]["worker-host"]["layers"]["proof"]["status"]')" "old resource proof does not qualify"
  assert_equals "stale" "$(py "$home/view.json" '[a["status"] for a in d["acceptance"] if a["id"] == "mvp-run"][0]')" "acceptance also rejects old resource proof"
  rc=0; out=$(map "$home" verify task-resource) || rc=$?
  expect_code 3 "$rc" "old resource proof does not verify the replacement"
  write_evidence "$home" identity-omitted ami-0123456789abcdef0 pass false "$future" without-identity
  view_json "$home"
  assert_equals "stale" "$(py "$home/view.json" 'd["subjects"]["worker-host"]["layers"]["proof"]["status"]')" "an unstamped receipt cannot qualify"
  assert_contains "$(py "$home/view.json" '[r["id"] for r in d["subjects"]["worker-host"]["evidence"]]')" "identity-omitted" "the unstamped receipt remains visible"
  write_evidence "$home" replacement-run ami-0123456789abcdef0 pass false "$future"
  view_json "$home"
  assert_equals "proven" "$(py "$home/view.json" 'd["subjects"]["worker-host"]["layers"]["proof"]["status"]')" "matching replacement proof qualifies"
  assert_equals "passed" "$(py "$home/view.json" '[a["status"] for a in d["acceptance"] if a["id"] == "mvp-run"][0]')" "matching replacement proof passes acceptance"
  rc=0; out=$(map "$home" verify task-resource) || rc=$?
  expect_code 0 "$rc" "matching replacement proof verifies the task"
  aws_state "$home" '{"ami": "ami-0different000001"}'
  map "$home" collect >/dev/null || fail "mismatched version collection failed"
  write_evidence "$home" mismatched-run ami-0different000001 pass false "$future"
  view_json "$home"
  assert_equals "stale" "$(py "$home/view.json" 'd["subjects"]["worker-host"]["layers"]["proof"]["status"]')" "proof cannot qualify against a mismatched pin"
  rc=0; out=$(map "$home" verify task-resource) || rc=$?
  expect_code 3 "$rc" "a mismatched pin revokes task verification"
  aws_state "$home" '{"deny": ["ec2"]}'
  map "$home" collect >/dev/null || fail "denied resource collection failed"
  rc=0; out=$(map "$home" verify task-resource) || rc=$?
  expect_code 3 "$rc" "an unreadable resource cannot verify the task"
  aws_state "$home" '{"instance_state": "terminated"}'
  map "$home" collect >/dev/null || fail "absent resource collection failed"
  rc=0; out=$(map "$home" verify task-resource) || rc=$?
  expect_code 3 "$rc" "an absent resource cannot verify the task"
  pass "proof and acceptance bind to the observed resource identity"
}

test_removed_bound_subject_is_unverified() {
  local home out rc=0
  home=$(new_home removed-bound-subject)
  map "$home" bind task-removed --subject worker-writes-results >/dev/null || fail "binding failed"
  map "$home" complete task-removed --kind ship >/dev/null || fail "completion failed"
  python3 - "$home/data/system-map/example/manifest.json" "$home/new-manifest.json" <<'PY'
import json, sys
with open(sys.argv[1]) as handle: manifest = json.load(handle)
manifest["connections"] = [connection for connection in manifest["connections"] if connection["id"] != "worker-writes-results"]
with open(sys.argv[2], "w") as handle: json.dump(manifest, handle)
PY
  map "$home" intent replace example "$home/new-manifest.json" --reason "remove connection" >/dev/null || fail "intent replacement failed"
  out=$(map "$home" verify task-removed) || rc=$?
  expect_code 3 "$rc" "a removed bound subject is unverified"
  assert_contains "$out" "worker-writes-results: no longer in the manifest" "the missing subject is identified"
  pass "verification fails when a bound subject was removed"
}

test_missing_and_invalid_bindings() {
  local home out rc=0
  home=$(new_home bindings)
  python3 - "$home/data/system-map/example/bindings.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); del d["bindings"]["job_queue"]; d["bindings"]["results_table"] = {"tabel": "typo"}; json.dump(d, open(p, "w"))
PY
  out=$(map "$home" validate 2>&1) || rc=$?
  expect_code 1 "$rc" "validate with unusable bindings"
  assert_contains "$out" "queue-sqs (job_queue): binding is missing" "missing binding is named"
  assert_contains "$out" "results-ddb (results_table)" "invalid binding is named"
  map "$home" collect >/dev/null || fail "collect should still run"
  view_json "$home"
  assert_equals "unknown" "$(py "$home/view.json" 'd["subjects"]["queue"]["layers"]["runtime"]["status"]')" "a missing binding is unknown, not absent"
  assert_contains "$(py "$home/view.json" '[x["kind"] for x in d["discrepancies"] if x["status"] == "open"]')" "binding" "a binding discrepancy opens"
  rc=0; out=$(python3 - "$home/data/system-map/example/manifest.json" <<'PY' 2>&1
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["components"][0]["observe"] = [{"id": "x", "adapter": "shell.exec", "binding": "b"}]; json.dump(d, open(p, "w"))
PY
) || rc=$?
  rc=0; out=$(map "$home" validate 2>&1) || rc=$?
  expect_code 1 "$rc" "manifest naming an unknown adapter"
  assert_contains "$out" "unknown adapter" "only built-in read-only adapters are accepted"
  pass "missing, malformed, and executable-looking bindings are refused or reported"
}

test_missing_declared_pin_blocks_acceptance() {
  local home future out rc=0 outcome
  home=$(new_home missing-pin)
  map "$home" bind task-missing-pin --subject worker-host >/dev/null || fail "binding failed"
  map "$home" complete task-missing-pin --kind ship >/dev/null || fail "completion failed"
  python3 - "$home/data/system-map/example/bindings.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as handle: bindings = json.load(handle)
del bindings["bindings"]["worker_host"]["pin"]
with open(path, "w") as handle: json.dump(bindings, handle)
PY
  map "$home" collect >/dev/null || fail "collection with missing pin failed"
  future=$(date -u +%Y-%m-%dT%H:%M:%SZ -d '+1 minute' 2>/dev/null || date -u -v+1M +%Y-%m-%dT%H:%M:%SZ)
  write_evidence "$home" observed-without-pin ami-0123456789abcdef0 pass false "$future"
  view_json "$home"
  assert_equals "unknown" "$(py "$home/view.json" 'd["subjects"]["worker-host"]["layers"]["deployment"]["status"]')" "a declared pin without a value cannot establish deployment"
  assert_equals "stale" "$(py "$home/view.json" 'd["subjects"]["worker-host"]["layers"]["proof"]["status"]')" "an unresolved pin cannot qualify proof"
  assert_equals "stale" "$(py "$home/view.json" '[a["status"] for a in d["acceptance"] if a["id"] == "mvp-run"][0]')" "the pinned-image criterion does not pass without a pin"
  assert_equals "['worker-host']" "$(py "$home/view.json" '[a["unresolved_pins"] for a in d["acceptance"] if a["id"] == "mvp-run"][0]')" "the unresolved pin is identified"
  assert_equals "1" "$(py "$home/data/system-map/example/discrepancies.json" 'sum(1 for item in d["discrepancies"].values() if item["kind"] == "version" and item["subject"] == "worker-host" and item["status"] == "open" and "no value" in item["title"])')" "an unresolved pin opens a version discrepancy"
  assert_contains "$(map "$home" check)" "system-map:" "the pin discrepancy reaches the owner check"
  out=$(map "$home" verify task-missing-pin) || rc=$?
  expect_code 3 "$rc" "an unresolved pin cannot verify a completed task"
  for outcome in denied absent error; do
    case "$outcome" in
      denied) aws_state "$home" '{"deny": ["ec2"]}' ;;
      absent) aws_state "$home" '{"missing": ["ec2"]}' ;;
      error) aws_state "$home" '{"fail_all": true}' ;;
    esac
    map "$home" collect >/dev/null || fail "$outcome collection failed"
    view_json "$home"
    assert_equals "True" "$(py "$home/view.json" 'd["subjects"]["worker-host"]["layers"]["deployment"].get("pin_missing")')" "the missing pin remains visible when the resource is $outcome"
    assert_equals "1" "$(py "$home/data/system-map/example/discrepancies.json" 'sum(1 for item in d["discrepancies"].values() if item["kind"] == "version" and item["subject"] == "worker-host" and item["status"] == "open" and "no value" in item["title"])')" "the missing pin discrepancy remains open when the resource is $outcome"
  done
  python3 - "$home/data/system-map/example/bindings.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as handle: bindings = json.load(handle)
bindings["bindings"]["worker_host"]["pin"] = "ami-0123456789abcdef0"
with open(path, "w") as handle: json.dump(bindings, handle)
PY
  map "$home" collect >/dev/null || fail "collection after restoring pin failed"
  assert_equals "0" "$(py "$home/data/system-map/example/discrepancies.json" 'sum(1 for item in d["discrepancies"].values() if item["kind"] == "version" and item["subject"] == "worker-host" and item["status"] == "open" and "no value" in item["title"])')" "the restored pin resolves its discrepancy despite an unreadable resource"
  pass "unresolved declared pins block acceptance"
}

test_manifest_rejects_duplicate_ids() {
  local section home out rc
  for section in groups phases acceptance known_gaps credentials; do
    home=$(new_home "duplicate-$section")
    python3 - "$home/data/system-map/example/manifest.json" "$section" <<'PY'
import json, sys
path, section = sys.argv[1:]
with open(path) as handle: manifest = json.load(handle)
entries = manifest["lifecycle"]["phases"] if section == "phases" else manifest[section]
entries.append(dict(entries[0]))
with open(path, "w") as handle: json.dump(manifest, handle)
PY
    rc=0; out=$(map "$home" validate 2>&1) || rc=$?
    expect_code 1 "$rc" "duplicate $section id"
    assert_contains "$out" "duplicate id" "$section duplicate is rejected"
  done
  pass "manifest validation rejects duplicate ids in named collections"
}

test_credential_material_is_refused() {
  local home out rc=0
  home=$(new_home creds)
  python3 - "$home/data/system-map/example/manifest.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["credentials"][0]["secret"] = "x"; json.dump(d, open(p, "w"))
PY
  out=$(map "$home" validate 2>&1) || rc=$?
  expect_code 1 "$rc" "manifest carrying a secret field"
  assert_contains "$out" "credential material" "credential values are refused"
  home=$(new_home creds-ev)
  cat > "$home/ev.json" <<'EOF'
{"schema": "fm-system-map.evidence.v1", "id": "leak", "subjects": ["api"], "result": "pass", "summary": "AKIAABCDEFGHIJKLMNOP",
 "recorded_at": "2026-01-01T00:00:00Z", "provenance": {"source": "test"}}
EOF
  rc=0; out=$(map "$home" evidence add example "$home/ev.json" 2>&1) || rc=$?
  expect_code 1 "$rc" "evidence carrying an access key"
  pass "manifests and evidence never accept credential material"
}

write_evidence() {  # <home> <id> <version> <result> [historical] [recorded_at]
  local hist=${5:-false} at=${6:-2026-01-01T00:00:00Z}
  python3 - "$1" "$2" "$3" "$4" "$hist" "$at" "${7:-with-identity}" <<'PY'
import json, os, sys
home, receipt_id, version, result, historical, recorded_at, identity_mode = sys.argv[1:]
receipt = {"schema": "fm-system-map.evidence.v1", "id": receipt_id, "subjects": ["worker-host"],
           "criterion": "mvp-run", "versions": {"worker-host": version}, "result": result,
           "historical": historical == "true", "summary": "run on " + version,
           "recorded_at": recorded_at, "provenance": {"source": "test receipt", "kind": "receipt"}}
snapshot = os.path.join(home, "state/system-map/example/snapshot.json")
if identity_mode == "with-identity" and os.path.exists(snapshot):
    with open(snapshot) as handle:
        observation = json.load(handle)["observations"]["worker-ec2"]
    receipt["resource_identities"] = {"worker-host": observation["binding_digest"]}
with open(os.path.join(home, "ev-" + receipt_id + ".json"), "w") as handle:
    json.dump(receipt, handle)
PY
  map "$1" evidence add example "$1/ev-$2.json" >/dev/null || fail "evidence $2 not recorded"
}

test_evidence_is_version_bound() {
  local home
  home=$(new_home evidence)
  aws_state "$home" '{"ami": "ami-0newnewnewnewnew0"}'
  write_evidence "$home" old-pass ami-0oldoldoldoldold0 pass
  map "$home" collect >/dev/null || fail "collect failed"
  view_json "$home"
  assert_equals "stale" "$(py "$home/view.json" 'd["subjects"]["worker-host"]["layers"]["proof"]["status"]')" "old-version proof does not qualify the new version"
  assert_equals "failed" "$(py "$home/view.json" '[a["status"] for a in d["acceptance"] if a["id"] == "mvp-run"][0]')" "the criterion fails when deployment differs from its pin"
  assert_equals "mismatch" "$(py "$home/view.json" 'd["subjects"]["worker-host"]["layers"]["deployment"]["status"]')" "a non-pinned image is a deployment mismatch"
  write_evidence "$home" hist-pass ami-0newnewnewnewnew0 pass true
  view_json "$home"
  assert_equals "stale" "$(py "$home/view.json" 'd["subjects"]["worker-host"]["layers"]["proof"]["status"]')" "historical evidence never qualifies"
  write_evidence "$home" new-pass ami-0newnewnewnewnew0 pass false 2026-01-02T00:00:00Z
  view_json "$home"
  assert_equals "stale" "$(py "$home/view.json" 'd["subjects"]["worker-host"]["layers"]["proof"]["status"]')" "current-version evidence cannot prove a pin mismatch"
  assert_equals "failed" "$(py "$home/view.json" '[a["status"] for a in d["acceptance"] if a["id"] == "mvp-run"][0]')" "current-version proof cannot pass a mismatched deployment"
  assert_equals "['worker-host']" "$(py "$home/view.json" '[a["deployment_mismatches"] for a in d["acceptance"] if a["id"] == "mvp-run"][0]')" "the mismatched subject is identified"
  aws_state "$home" '{"ami": "ami-0nextnextnextnex0"}'
  map "$home" collect >/dev/null || fail "collect failed"
  view_json "$home"
  assert_equals "stale" "$(py "$home/view.json" 'd["subjects"]["worker-host"]["layers"]["proof"]["status"]')" "a version change drops the qualification"
  aws_state "$home" '{"deny": ["ec2"]}'
  map "$home" collect >/dev/null || fail "collect failed"
  view_json "$home"
  assert_equals "unknown" "$(py "$home/view.json" 'd["subjects"]["worker-host"]["layers"]["proof"]["status"]')" "an unobserved version cannot be proven"
  pass "evidence qualifies only the exact observed version"
}

test_tagged_instances_report_observed_state() {
  local home
  home=$(new_home tagged-instances)
  python3 - "$home/data/system-map/example/manifest.json" "$home/data/system-map/example/bindings.json" <<'PY'
import json, sys
manifest_path, bindings_path = sys.argv[1:]
with open(manifest_path) as handle: manifest = json.load(handle)
console = next(item for item in manifest["components"] if item["id"] == "console")
console["intended"] = {"idle": "stopped", "active": "running"}
console["observe"] = [{"id": "tagged-workers", "adapter": "aws.ec2_tagged_instances", "binding": "tagged_workers"}]
manifest["prerequisites"] = [item for item in manifest["prerequisites"] if item["id"] not in ("console-source", "console-config")]
with open(manifest_path, "w") as handle: json.dump(manifest, handle)
with open(bindings_path) as handle: bindings = json.load(handle)
bindings["bindings"]["tagged_workers"] = {"tag_key": "example-worker"}
with open(bindings_path, "w") as handle: json.dump(bindings, handle)
PY
  map "$home" collect >/dev/null || fail "stopped tagged instance collection failed"
  view_json "$home"
  assert_equals "stopped" "$(py "$home/view.json" 'd["subjects"]["console"]["observations"][0]["current"]["state"]')" "a stopped tagged instance is not running"
  assert_equals "as-intended" "$(py "$home/view.json" 'd["subjects"]["console"]["layers"]["runtime"]["status"]')" "stopped state matches idle intent"
  aws_state "$home" '{"instance_state": "running"}'
  map "$home" collect >/dev/null || fail "running tagged instance collection failed"
  view_json "$home"
  assert_equals "running" "$(py "$home/view.json" 'd["subjects"]["console"]["observations"][0]["current"]["state"]')" "a running tagged instance is reported running"
  pass "tagged instance state follows observed instances"
}

test_terminated_instance_has_no_current_version() {
  local home
  home=$(new_home terminated-instance)
  map "$home" collect >/dev/null || fail "initial collection failed"
  write_evidence "$home" before-termination ami-0123456789abcdef0 pass
  view_json "$home"
  assert_equals "proven" "$(py "$home/view.json" 'd["subjects"]["worker-host"]["layers"]["proof"]["status"]')" "the original instance has current proof"
  aws_state "$home" '{"instance_state": "terminated"}'
  map "$home" collect >/dev/null || fail "terminated instance collection failed"
  view_json "$home"
  assert_equals "absent" "$(py "$home/view.json" 'd["subjects"]["worker-host"]["observations"][0]["current"]["outcome"]')" "terminated instances are absent observations"
  assert_equals "None" "$(py "$home/view.json" 'd["subjects"]["worker-host"]["observations"][0]["current"]["version"]')" "a terminated instance has no current image version"
  assert_equals "absent" "$(py "$home/view.json" 'd["subjects"]["worker-host"]["layers"]["deployment"]["status"]')" "a terminated instance is not deployed"
  assert_equals "unknown" "$(py "$home/view.json" 'd["subjects"]["worker-host"]["layers"]["proof"]["status"]')" "old proof is not current after termination"
  pass "termination removes the current deployment and version"
}

test_evidence_ids_are_create_only() {
  local home i pid successes=0 rc=0
  local -a pids=()
  home=$(new_home evidence-create-only)
  for i in 1 2 3 4 5 6; do
    cat > "$home/ev-$i.json" <<EOF
{"schema":"fm-system-map.evidence.v1","id":"shared-id","subjects":["worker-host"],"versions":{"worker-host":"ami-0123456789abcdef0"},"result":"pass","summary":"receipt $i","recorded_at":"2026-01-01T00:00:00Z","provenance":{"source":"test"}}
EOF
    map "$home" evidence add example "$home/ev-$i.json" > "$home/ev-$i.out" 2>&1 &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || rc=$?
    if [ "$rc" -eq 0 ]; then successes=$((successes + 1)); fi
    rc=0
  done
  assert_equals "1" "$successes" "only one concurrent writer creates an evidence ID"
  cp "$home/data/system-map/example/evidence/shared-id.json" "$home/first-evidence.json"
  mkdir -p "$home/data/system-map/example/inbox"
  cp "$home/ev-1.json" "$home/data/system-map/example/inbox/duplicate.json"
  map "$home" collect >/dev/null || fail "collection with duplicate inbox receipt failed"
  cmp -s "$home/first-evidence.json" "$home/data/system-map/example/evidence/shared-id.json" || fail "inbox ingestion replaced existing evidence"
  assert_present "$home/data/system-map/example/inbox/rejected/duplicate.json" "duplicate inbox receipt was not rejected"
  pass "evidence IDs are create-only across CLI and inbox ingestion"
}

test_timeline_orders_offset_timestamps() {
  local home id at result
  home=$(new_home timeline-offset)
  for id in earlier later; do
    if [ "$id" = earlier ]; then at=2026-01-01T10:00:00+02:00; result=pass
    else at=2026-01-01T09:00:00Z; result=fail; fi
    cat > "$home/ev-$id.json" <<EOF
{"schema":"fm-system-map.evidence.v1","id":"$id","subjects":["worker-host"],"versions":{"worker-host":"ami-0123456789abcdef0"},"result":"$result","summary":"$id","recorded_at":"$at","run_id":"run-a","phase":"run","provenance":{"source":"test"}}
EOF
    map "$home" evidence add example "$home/ev-$id.json" >/dev/null || fail "timeline evidence failed"
  done
  view_json "$home"
  assert_equals "later" "$(py "$home/view.json" 'd["timeline"]["runs"][0]["cells"]["run"]["record"]')" "the later instant wins despite its smaller timestamp text"
  assert_equals "2026-01-01T09:00:00Z" "$(py "$home/view.json" 'd["timeline"]["runs"][0]["last"]')" "run last follows absolute time"
  for id in tie-fail tie-pass; do
    if [ "$id" = tie-fail ]; then at=2026-01-01T09:00:00Z; result=fail
    else at=2026-01-01T10:00:00+01:00; result=pass; fi
    cat > "$home/ev-$id.json" <<EOF
{"schema":"fm-system-map.evidence.v1","id":"$id","subjects":["worker-host"],"versions":{"worker-host":"ami-0123456789abcdef0"},"result":"$result","summary":"$id","recorded_at":"$at","run_id":"run-b","phase":"run","provenance":{"source":"test"}}
EOF
    map "$home" evidence add example "$home/ev-$id.json" >/dev/null || fail "timeline tie evidence failed"
  done
  view_json "$home"
  assert_equals "tie-fail" "$(py "$home/view.json" '[r["cells"]["run"]["record"] for r in d["timeline"]["runs"] if r["run_id"] == "run-b"][0]')" "failure wins a parsed-time tie despite receipt order"
  pass "timeline compares timestamp instants"
}

test_completion_retry_preserves_first_receipt() {
  local home out rc=0
  home=$(new_home completion-retry)
  map "$home" bind task-retry --subject worker-host >/dev/null || fail "binding failed"
  map "$home" complete task-retry --kind ship --mode no-mistakes >/dev/null || fail "completion failed"
  python3 - "$home/data/system-map/example/completions/task-retry.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as handle: record = json.load(handle)
record["completed_at"] = "2026-01-01T00:00:00Z"
with open(path, "w") as handle: json.dump(record, handle)
PY
  cp "$home/data/system-map/example/completions/task-retry.json" "$home/first-completion.json"
  map "$home" collect >/dev/null || fail "collect failed"
  write_evidence "$home" retry-proof ami-0123456789abcdef0 pass false 2026-01-02T00:00:00Z
  rc=0; out=$(map "$home" verify task-retry) || rc=$?
  expect_code 0 "$rc" "the first completion has later proof"
  map "$home" complete task-retry --kind ship --mode no-mistakes >/dev/null || fail "completion retry failed"
  cmp -s "$home/first-completion.json" "$home/data/system-map/example/completions/task-retry.json" || fail "retry replaced the first completion receipt"
  rc=0; out=$(map "$home" verify task-retry) || rc=$?
  expect_code 0 "$rc" "retry keeps previously qualifying proof"
  pass "completion retries preserve the first receipt and proof"
}

test_prelanding_receipt_never_verifies() {
  local home out rc=0 future
  home=$(new_home prelanding-proof)
  map "$home" bind task-timing --subject worker-host >/dev/null || fail "binding failed"
  map "$home" collect >/dev/null || fail "collection failed"
  future=$(date -u +%Y-%m-%dT%H:%M:%SZ -d '+1 minute' 2>/dev/null || date -u -v+1M +%Y-%m-%dT%H:%M:%SZ)
  write_evidence "$home" prelanding ami-0123456789abcdef0 pass false "$future"
  map "$home" complete task-timing --kind ship >/dev/null || fail "completion failed"
  rc=0; out=$(map "$home" verify task-timing) || rc=$?
  expect_code 3 "$rc" "a receipt accepted before completion cannot verify it"
  assert_contains "$out" "live-verified no" "prelanding proof is excluded"
  write_evidence "$home" postlanding ami-0123456789abcdef0 pass false "$future"
  rc=0; out=$(map "$home" verify task-timing) || rc=$?
  expect_code 0 "$rc" "a later receipt can verify completion"
  pass "receipt intake order is part of live verification"
}

test_collect_lock_is_single_owner() {
  local home pid rc=0 out
  home=$(new_home lock)
  aws_state "$home" '{"sleep": 0.4}'
  map "$home" collect > "$home/first.out" 2>&1 &
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$home/aws.log" ] && break
    sleep 0.2
  done
  out=$(map "$home" collect 2>&1) || rc=$?
  expect_code 75 "$rc" "a concurrent collection"
  assert_contains "$out" "busy" "the second collector reports busy"
  wait "$pid" || fail "the first collection failed: $(cat "$home/first.out")"
  assert_contains "$(cat "$home/first.out")" "collected example: ok" "the owner finished"
  python3 -m json.tool "$home/state/system-map/example/snapshot.json" >/dev/null || fail "snapshot is not complete JSON"
  [ -z "$(find "$home/state/system-map/example" -name '.tmp-*')" ] || fail "temporary files were left behind"
  pass "one collection per project at a time, published atomically"
}

test_requests_dedupe_and_review_cadence() {
  local home out rc=0
  home=$(new_home requests)
  out=$(map "$home" tick) || fail "tick failed"
  assert_contains "$out" "example: ok" "first tick collects"
  assert_contains "$out" "review requested" "first tick queues the daily review"
  out=$(map "$home" tick) || fail "tick failed"
  assert_contains "$out" "not due (idle cadence)" "an idle home waits for the idle interval"
  map "$home" tick --force >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "forced scheduler tick is unsupported"
  assert_not_contains "$out" "review requested" "the review is requested once per interval"
  out=$(map "$home" check)
  assert_contains "$out" "system-map:" "check surfaces pending requests"
  assert_contains "$out" "review-due" "check names the review request"
  assert_contains "$out" "discrepancies:" "check names new discrepancies"
  assert_equals "" "$(map "$home" check)" "a surfaced request is not re-emitted immediately"
  map "$home" review-done example --note "reviewed" >/dev/null || fail "review-done failed"
  assert_equals "0" "$(py "$home/state/system-map/example/requests.json" 'len(d["requests"])')" "review-done clears pending requests"
  out=$(map "$home" collect) || fail "collect failed"
  assert_equals "0" "$(py "$home/state/system-map/example/requests.json" 'len(d["requests"])')" "unchanged discrepancies are not re-queued"
  aws_state "$home" '{"instance_state": "running"}'
  map "$home" collect >/dev/null || fail "collect failed"
  assert_contains "$(map "$home" check)" "discrepancies:" "a newly opened discrepancy queues one request"
  ids=$(py "$home/data/system-map/example/discrepancies.json" 'sorted(k for k, v in d["discrepancies"].items() if v["kind"] == "runtime")')
  aws_state "$home" '{}'
  map "$home" collect >/dev/null || fail "collect failed"
  assert_equals "resolved" "$(py "$home/data/system-map/example/discrepancies.json" '[v["status"] for k, v in d["discrepancies"].items() if v["kind"] == "runtime"][0]')" "a cleared deviation resolves under the same id"
  aws_state "$home" '{"instance_state": "running"}'
  map "$home" collect >/dev/null || fail "collect failed"
  assert_equals "$ids" "$(py "$home/data/system-map/example/discrepancies.json" 'sorted(k for k, v in d["discrepancies"].items() if v["kind"] == "runtime")')" "a reopened deviation keeps its durable id"
  assert_equals "2" "$(py "$home/data/system-map/example/discrepancies.json" '[v["occurrences"] for k, v in d["discrepancies"].items() if v["kind"] == "runtime"][0]')" "reopening counts an occurrence"
  aws_state "$home" '{"deny": ["ec2"]}'
  map "$home" collect >/dev/null || fail "collect failed"
  assert_equals "open" "$(py "$home/data/system-map/example/discrepancies.json" '[v["status"] for k, v in d["discrepancies"].items() if v["kind"] == "runtime"][0]')" "an unreadable subject does not resolve its discrepancy"
  pass "requests dedupe, the review is daily, and discrepancy ids are durable"
}

test_active_cadence_ignores_secondmates() {
  local home out
  home=$(new_home cadence)
  map "$home" tick >/dev/null || fail "tick failed"
  fm_write_secondmate_meta "$home/state/mate.meta" "$home"
  printf 'paused [at=1]: idle\n' > "$home/state/mate.status"
  python3 - "$home/state/system-map/example/health.json" <<'PY'
import json, sys, time
p = sys.argv[1]; d = json.load(open(p))
d["last_attempt_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 600)); json.dump(d, open(p, "w"))
PY
  out=$(map "$home" tick)
  assert_contains "$out" "not due (idle cadence)" "a persistent idle secondmate is not active work"
  fm_write_meta "$home/state/ship1.meta" "kind=ship" "project=$home/projects/other"
  out=$(map "$home" tick)
  assert_contains "$out" "example: ok" "a live ship task selects the active cadence"
  pass "only ship and scout records select the active cadence"
}

test_task_state_ignores_last_wake_event() {
  local home
  home=$(new_home task-events)
  fm_write_meta "$home/state/example-owner.meta" "kind=ship" "project=$home/projects/example-project"
  printf 'done [at=1]: earlier wake\n' > "$home/state/example-owner.status"
  map "$home" collect >/dev/null || fail "live task collection failed"
  assert_equals "live" "$(py "$home/state/system-map/example/snapshot.json" 'd["observations"]["owner-task"]["state"]')" "an old done event does not end a live task"
  assert_equals "done [at=1]: earlier wake" "$(py "$home/state/system-map/example/snapshot.json" 'd["observations"]["owner-task"]["facts"]["last_event"]')" "the wake line is labelled as an event"
  rm "$home/state/example-owner.meta"
  printf 'blocked [at=2]: earlier wake\n' > "$home/state/example-owner.status"
  map "$home" collect >/dev/null || fail "ended task collection failed"
  assert_equals "ended" "$(py "$home/state/system-map/example/snapshot.json" 'd["observations"]["owner-task"]["state"]')" "an old blocked event does not define ended state"
  assert_equals "blocked [at=2]: earlier wake" "$(py "$home/state/system-map/example/snapshot.json" 'd["observations"]["owner-task"]["facts"]["last_event"]')" "the last event remains visible after ending"
  pass "task state follows the task record, not wake events"
}

test_scheduler_install_is_idempotent_and_removable() {
  local home out rc=0
  home=$(new_home units)
  out=$(map "$home" install 2>&1) || rc=$?
  expect_code 1 "$rc" "fixture install is refused"
  assert_contains "$out" "fixture run" "fixture refusal is explicit"
  [ -z "$(ls "$home/units")" ] || fail "fixture install wrote units"
  assert_absent "$home/state/system-map.check.sh" "fixture install did not register a check"
  out=$(FM_SYSTEM_MAP_TEST_FIXTURE=0 map "$home" install) || fail "install failed: $out"
  assert_contains "$out" "registered: state/system-map.check.sh" "the watcher check is registered"
  set -- "$home/units"/*-collect.timer
  [ -f "$1" ] || fail "timer unit missing"
  unit=$(ls "$home/units"/*-collect.service)
  python3 - "$unit" "$ROOT" "$home" <<'PY' || fail "collector unit settings are wrong"
import os, shlex, sys
unit, root, home = sys.argv[1:]
settings = {}
section = None
with open(unit) as handle:
    for raw in handle:
        line = raw.strip()
        if not line or line.startswith(("#", ";")):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            continue
        key, value = line.split("=", 1)
        settings.setdefault(section, {}).setdefault(key, []).append(value)
service = settings["Service"]
environment = dict(entry.split("=", 1) for item in service["Environment"] for entry in shlex.split(item))
assert shlex.split(service["ExecStart"][0]) == [os.path.join(root, "bin/fm-system-map.sh"), "tick"]
assert environment["FM_HOME"] == os.path.realpath(home)
assert environment["PATH"].split(os.pathsep)
assert "/usr/bin" in environment["PATH"].split(os.pathsep)
PY
  assert_contains "$(cat "$home/systemctl.log")" "--user enable --now" "install enables the units"
  : > "$home/systemctl.log"
  out=$(FM_SYSTEM_MAP_TEST_FIXTURE=0 map "$home" install) || fail "second install failed"
  assert_contains "$out" "unchanged" "a repeated install changes nothing"
  assert_not_contains "$(cat "$home/systemctl.log")" "daemon-reload" "no reload without a unit change"
  rc=0; map "$home" install --only ui >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "partial installation is unsupported"
  out=$(FM_HOME="$home" "$home/state/system-map.check.sh")
  assert_equals "" "$out" "the registered check is quiet with nothing pending"
  map "$home" uninstall >/dev/null || fail "uninstall failed"
  [ -z "$(ls "$home/units")" ] || fail "units were left behind"
  assert_absent "$home/state/system-map.check.sh" "the watcher check is retired"
  printf '[Unit]\nDescription=not ours\n' > "$home/units/$(basename "$unit")"
  out=$(FM_SYSTEM_MAP_TEST_FIXTURE=0 map "$home" install 2>&1) || rc=$?
  expect_code 1 "$rc" "install over an unmanaged unit"
  assert_contains "$out" "not managed by this installer" "an unmanaged unit is never overwritten"
  pass "scheduler install is single-owner, idempotent, and removable"
}

test_scheduler_preserves_unmanaged_artifacts() {
  local home out rc=0 timer check trust
  home=$(new_home unmanaged-check)
  check="$home/state/system-map.check.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$check"
  cp "$check" "$home/custom.check"
  out=$(FM_SYSTEM_MAP_TEST_FIXTURE=0 map "$home" install 2>&1) || rc=$?
  expect_code 1 "$rc" "install over an unmanaged watcher check"
  assert_contains "$out" "not managed by this installer" "unmanaged check is refused"
  cmp -s "$check" "$home/custom.check" || fail "install changed the unmanaged check"
  [ -z "$(ls "$home/units")" ] || fail "install wrote units before refusing the unmanaged check"

  home=$(new_home unmanaged-uninstall)
  FM_SYSTEM_MAP_TEST_FIXTURE=0 map "$home" install >/dev/null || fail "install failed"
  timer=$(ls "$home/units"/*-collect.timer)
  check="$home/state/system-map.check.sh"
  trust="$home/state/system-map.check-trust"
  printf '[Unit]\nDescription=custom timer\n' > "$timer"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$check"
  : > "$home/systemctl.log"
  map "$home" uninstall >/dev/null || fail "uninstall failed"
  assert_present "$timer" "unmanaged timer was removed"
  assert_present "$check" "unmanaged watcher check was removed"
  assert_present "$trust" "unmanaged watcher trust was removed"
  assert_not_contains "$(cat "$home/systemctl.log")" "disable --now $(basename "$timer")" "unmanaged timer was disabled"
  pass "scheduler ownership checks leave unmanaged artifacts untouched"
}

test_binding_completion_and_live_verification() {
  local home out rc=0
  home=$(new_home complete)
  rc=0; map "$home" bind task-a --subject nope >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "binding to an unknown subject"
  out=$(map "$home" bind task-a --subject worker-host,queue-wakes-worker) || fail "bind failed"
  assert_contains "$out" "bound task-a to example" "bind confirms"
  out=$(map "$home" complete task-unbound --kind ship --mode no-mistakes --pr https://example.invalid/pr/1)
  assert_equals "" "$out" "an unbound task records nothing"
  out=$(map "$home" complete task-a --kind ship --mode no-mistakes --pr https://example.invalid/pr/2)
  assert_contains "$out" "implementation-complete" "landing records implementation-complete"
  assert_contains "$out" "live verification stays separate" "the advisory keeps verification separate"
  map "$home" collect >/dev/null || fail "collect failed"
  rc=0; out=$(map "$home" verify task-a) || rc=$?
  expect_code 3 "$rc" "verify before live evidence"
  assert_contains "$out" "live-verified no" "landed work is not live-verified yet"
  view_json "$home"
  assert_equals "True" "$(py "$home/view.json" 'all(x["category"] == "verification" for x in d["presentation"]["differences"] if x["kind"] == "completion")')" "unverified completions remain verification concerns"
  assert_equals "complete" "$(py "$home/view.json" 'd["subjects"]["worker-host"]["layers"]["implementation"]["status"]')" "implementation layer shows the completion"
  assert_contains "$(py "$home/view.json" '[x["kind"] for x in d["discrepancies"] if x["status"] == "open"]')" "completion" "an unverified completion is a visible discrepancy"
  write_evidence "$home" after-landing ami-0123456789abcdef0 pass false "$(date -u +%Y-%m-%dT%H:%M:%SZ -d '+1 minute' 2>/dev/null || date -u -v+1M +%Y-%m-%dT%H:%M:%SZ)"
  rc=0; out=$(map "$home" verify task-a) || rc=$?
  expect_code 3 "$rc" "verify while one bound subject still lacks evidence"
  assert_contains "$out" "worker-host: deployment deployed, runtime as-intended, proof proven, live-verified yes" "later current-version evidence verifies"
  assert_contains "$out" "queue-wakes-worker: deployment untracked, runtime not-observed, proof not-demonstrated, live-verified no" "the unproven connection stays unverified"
  cat > "$home/ev-conn.json" <<EOF
{"schema": "fm-system-map.evidence.v1", "id": "conn-after", "subjects": ["queue-wakes-worker"], "result": "pass", "summary": "wake observed",
 "recorded_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ -d '+1 minute' 2>/dev/null || date -u -v+1M +%Y-%m-%dT%H:%M:%SZ)", "provenance": {"source": "test receipt"}}
EOF
  map "$home" evidence add example "$home/ev-conn.json" >/dev/null || fail "connection evidence not recorded"
  rc=0; out=$(map "$home" verify task-a) || rc=$?
  expect_code 3 "$rc" "unversioned proof never verifies a bound subject"
  assert_contains "$out" "queue-wakes-worker: deployment untracked, runtime not-observed, proof unversioned, live-verified no (proof not version-bound)" "a subject without a version source shows unversioned proof"
  map "$home" bind task-b --subject worker-host >/dev/null || fail "bind failed"
  map "$home" complete task-b --kind ship --mode no-mistakes >/dev/null
  rc=0; out=$(map "$home" verify task-a) || rc=$?
  expect_code 3 "$rc" "task A keeps its own completion boundary despite task B landing"
  assert_contains "$out" "worker-host: deployment deployed, runtime as-intended, proof proven, live-verified yes" "task A retains its passing verification"
  write_evidence "$home" after-b ami-0123456789abcdef0 pass false "$(date -u +%Y-%m-%dT%H:%M:%SZ -d '+2 minute' 2>/dev/null || date -u -v+2M +%Y-%m-%dT%H:%M:%SZ)"
  rc=0; out=$(map "$home" verify task-b) || rc=$?
  expect_code 0 "$rc" "verify once every bound subject has later version-bound evidence"
  write_evidence "$home" failed-after-b ami-0123456789abcdef0 fail false "$(date -u +%Y-%m-%dT%H:%M:%SZ -d '+3 minute' 2>/dev/null || date -u -v+3M +%Y-%m-%dT%H:%M:%SZ)"
  rc=0; out=$(map "$home" verify task-b) || rc=$?
  expect_code 3 "$rc" "a later failure revokes task verification"
  view_json "$home"
  assert_equals "False" "$(py "$home/view.json" 'd["subjects"]["worker-host"]["live_verified"]')" "subject verification follows the latest decisive result"
  assert_equals "failed" "$(py "$home/view.json" 'd["subjects"]["worker-host"]["layers"]["proof"]["status"]')" "the failed proof remains visible"
  out=$(map "$home" bind task-s --subject api) && map "$home" complete task-s --kind scout >/dev/null
  assert_absent "$home/data/system-map/example/completions/task-s.json" "a scout never records implementation-complete"
  pass "binding, landing, and live verification stay distinct"
}

test_verify_uses_completed_subjects() {
  local home out rc=0 future
  home=$(new_home frozen-subjects)
  map "$home" bind task-frozen --subject worker-host >/dev/null || fail "binding failed"
  map "$home" complete task-frozen --kind ship >/dev/null || fail "completion failed"
  map "$home" bind task-frozen --no-subjects --note "later exemption" >/dev/null || fail "rebinding failed"
  assert_equals "[]" "$(py "$home/data/system-map/example/tasks/task-frozen.json" 'd["subjects"]')" "current binding is empty"
  assert_equals "['worker-host']" "$(py "$home/data/system-map/example/completions/task-frozen.json" 'd["subjects"]')" "completion retains the landed subject"
  map "$home" collect >/dev/null || fail "collection failed"
  out=$(map "$home" verify task-frozen) || rc=$?
  expect_code 3 "$rc" "an empty current binding cannot hide missing proof"
  assert_contains "$out" "worker-host:" "verify checks the landed subject"
  future=$(date -u +%Y-%m-%dT%H:%M:%SZ -d '+1 minute' 2>/dev/null || date -u -v+1M +%Y-%m-%dT%H:%M:%SZ)
  write_evidence "$home" frozen-proof ami-0123456789abcdef0 pass false "$future"
  rc=0; out=$(map "$home" verify task-frozen) || rc=$?
  expect_code 0 "$rc" "the completed subject verifies with matching proof"
  assert_contains "$out" "worker-host:" "the completed subject is still checked"
  pass "verification uses completion subjects after rebinding"
}

test_coverage_gap_for_unbound_project_tasks() {
  local home rc=0
  home=$(new_home coverage)
  fm_write_meta "$home/state/ship-x.meta" "kind=ship" "project=$home/projects/example-project"
  fm_write_meta "$home/state/ship-y.meta" "kind=ship" "project=$home/projects/unrelated"
  map "$home" collect >/dev/null || fail "collect failed"
  view_json "$home"
  assert_contains "$(py "$home/view.json" '[x["title"] for x in d["discrepancies"] if x["kind"] == "coverage" and x["status"] == "open"]')" "ship-x" "an unbound task in a mapped project is a coverage gap"
  assert_not_contains "$(py "$home/view.json" '[x["title"] for x in d["discrepancies"] if x["kind"] == "coverage"]')" "ship-y" "other projects are not reported"
  map "$home" bind ship-x --no-subjects >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "an exemption without a reason"
  map "$home" bind ship-x --no-subjects --note "docs only" >/dev/null || fail "exemption failed"
  map "$home" collect >/dev/null || fail "collect failed"
  view_json "$home"
  assert_equals "[]" "$(py "$home/view.json" '[x["id"] for x in d["discrepancies"] if x["kind"] == "coverage" and x["status"] == "open"]')" "a reviewed exemption closes the gap"
  pass "mapped-project tasks without a map reference show as a coverage gap"
}

free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

http() {  # <method> <url> [json-body] [origin] [host] [content-type] [fetch-site] -> "<status> <body>"
  python3 - "$@" <<'PY'
import json, sys, urllib.request, urllib.error
method, url = sys.argv[1], sys.argv[2]
body = sys.argv[3].encode() if len(sys.argv) > 3 and sys.argv[3] else None
req = urllib.request.Request(url, data=body, method=method)
if body is not None:
    req.add_header("Content-Type", sys.argv[6] if len(sys.argv) > 6 and sys.argv[6] else "application/json")
if len(sys.argv) > 4 and sys.argv[4]:
    req.add_header("Origin", sys.argv[4])
if len(sys.argv) > 5 and sys.argv[5]:
    req.add_header("Host", sys.argv[5])
if len(sys.argv) > 7 and sys.argv[7]:
    req.add_header("Sec-Fetch-Site", sys.argv[7])
try:
    with urllib.request.urlopen(req, timeout=10) as res:
        print(res.status, res.read().decode())
except urllib.error.HTTPError as err:
    print(err.code, err.read().decode())
PY
}

test_ui_annotations_and_intent_edits() {
  local home port pid base page out
  home=$(new_home ui)
  python3 - "$home/data/system-map/example/manifest.json" <<'PY'
import datetime,json,sys
p=sys.argv[1]; manifest=json.load(open(p)); now=datetime.datetime.now(datetime.timezone.utc)
for id,title,days in [('expired-ui','Expired certificate',-1),('soon-ui','Soon certificate',2),('future-ui','Future certificate',30)]:
    manifest['credentials'].append({'id':id,'title':title,'purpose':'Rendering regression','owner':'Fixture owner','expires':(now+datetime.timedelta(days=days)).isoformat(),'expiry_basis':'observed'})
manifest['credentials'].append({'id':'secondary-ui','title':'Second certificate','purpose':'Separate renewal','owner':'Second owner','renewal_owner':'Issuer team','rotation':'Manual swap','issuer':'api-cert'})
json.dump(manifest,open(p,'w'))
PY
  map "$home" collect >/dev/null || fail "collect failed"
  cp "$home/state/system-map/example/snapshot.json" "$home/snapshot.before"
  port=$(free_port)
  python3 - "$home/config/system-map" "$port" <<'PY'
import sys
path, port = sys.argv[1:]
with open(path) as handle: config = handle.read()
with open(path, "w") as handle: handle.write(config.replace("port=4790", "port=" + port))
PY
  mkdir -p "$home/state/system-map"
  : > "$home/state/system-map/capability"
  map "$home" serve > "$home/serve.log" 2>&1 &
  pid=$!
  MAP_SERVER_PID=$pid
  base="http://127.0.0.1:$port"
  for _ in $(seq 1 50); do page=$(http GET "$base/" 2>/dev/null) && break; sleep 0.1; done
  assert_contains "$page" "200 " "the page is served"
  assert_equals "$base/" "$(map "$home" open)" "open did not print the bare local URL"
  [ -f "$home/state/system-map/capability" ] && [ ! -s "$home/state/system-map/capability" ] || fail "the legacy capability file was changed"
  out=$(http GET "$base/api/projects" "" "" "evil.example:$port")
  assert_contains "$out" "403" "a foreign Host header is refused"
  out=$(http GET "$base/api/projects")
  assert_contains "$out" "200" "a bare local request could not read the project list"
  out=$(http GET "$base/api/state?project=example")
  assert_contains "$out" "200" "a bare local request could not read map state"
  if command -v google-chrome >/dev/null 2>&1; then
    google-chrome --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
      --user-data-dir="$home/chrome-profile" --virtual-time-budget=1500 --dump-dom \
      "$base/#tab=cred" > "$home/rendered.html" 2> "$home/chrome.log" || fail "browser could not render credential view"
    python3 - "$home/rendered.html" <<'PY' || fail "credential table rendered incorrect renewal or expiry states"
from html.parser import HTMLParser
import sys
class CredentialCells(HTMLParser):
    def __init__(self):
        super().__init__()
        self.table = False
        self.cell = False
        self.row = False
        self.column = -1
        self.cells = []
        self.rows = {}
    def handle_starttag(self, tag, attrs):
        if tag == 'table' and ('id', 'cred-table') in attrs:
            self.table = True
        elif self.table and tag == 'tr':
            self.row = True
            self.column = -1
            self.row_cells = []
            self.chip = None
        elif self.table and tag == 'td':
            self.cell = True
            self.column += 1
            self.cell_text = []
        elif self.cell and self.column == 3 and tag == 'span':
            classes = dict(attrs).get('class', '').split()
            self.chip = next((name for name in classes if name.startswith('chip--')), self.chip)
    def handle_endtag(self, tag):
        if self.table and tag == 'td':
            self.row_cells.append(''.join(self.cell_text).strip())
            self.cell = False
        elif self.table and tag == 'tr':
            if self.row_cells:
                self.rows[self.row_cells[0]] = {'chip': self.chip, 'cells': self.row_cells}
            self.row = False
        elif self.table and tag == 'table':
            self.table = False
    def handle_data(self, data):
        if self.cell:
            self.cells.append(data)
            self.cell_text.append(data)
cells = CredentialCells()
cells.feed(open(sys.argv[1]).read())
assert 'Mechanism: Reissue from the platform CA' in ' '.join(cells.cells)
assert cells.rows['Expired certificate']['chip'] == 'chip--bad', cells.rows
assert cells.rows['Soon certificate']['chip'] == 'chip--warn', cells.rows
assert cells.rows['Future certificate']['chip'] == 'chip--ok', cells.rows
secondary = cells.rows['Second certificate']['cells']
assert 'Second owner' in secondary[2] and 'Renewal owner: Issuer team' in secondary[2]
assert 'Mechanism: Manual swap' in secondary[2]
assert 'Issuer: api-cert' in secondary[3]
PY
  fi
  out=$(http GET "$base/../config/system-map")
  assert_contains "$out" "404" "arbitrary paths are not served"
  out=$(http POST "$base/api/annotate" '{"project":"example","target":"api","text":"foreign origin"}' 'https://evil.example')
  assert_contains "$out" "403" "a foreign Origin was accepted"
  out=$(http POST "$base/api/annotate" '{"project":"example","target":"api","text":"cross-site fetch"}' "$base" '' '' 'cross-site')
  assert_contains "$out" "403" "a cross-site fetch was accepted"
  out=$(http POST "$base/api/annotate" '{"project":"example","target":"api","text":"form body"}' "$base" '' 'text/plain')
  assert_contains "$out" "415" "a non-JSON POST was accepted"
  out=$(http POST "$base/api/annotate" '{"project":"example","target":"api","text":"check scaling"}')
  assert_contains "$out" "201" "an annotation is saved"
  assert_grep "check scaling" "$home/data/system-map/example/annotations.json" "the annotation persists on disk"
  assert_not_contains "$(cat "$home/data/system-map/example/annotations.json")" "foreign origin" "a foreign-Origin POST changed annotations"
  assert_not_contains "$(cat "$home/data/system-map/example/annotations.json")" "cross-site fetch" "a cross-site POST changed annotations"
  assert_not_contains "$(cat "$home/data/system-map/example/annotations.json")" "form body" "a non-JSON POST changed annotations"
  out=$(http POST "$base/api/annotate" '{"project":"example","target":"nope","text":"x"}' "$base")
  assert_contains "$out" "400" "an annotation on an unknown target is refused"
  out=$(http POST "$base/api/intent" '{"project":"example","subject":"api","field":"intended.idle","value":"zero","base_revision":99}' "$base")
  assert_contains "$out" "409" "a stale design revision is refused"
  out=$(http POST "$base/api/intent" '{"project":"example","subject":"api","field":"observe","value":"x","base_revision":1}' "$base")
  assert_contains "$out" "400" "structural fields are not editable here"
  out=$(http POST "$base/api/intent" '{"project":"example","subject":"api","field":"description","value":"Accepts jobs.","base_revision":1,"reason":"clarify"}' "$base")
  assert_contains "$out" '"revision": 2' "a valid intent edit raises the revision"
  assert_present "$home/data/system-map/example/history/manifest-r1.json" "the previous design is archived"
  cmp -s "$home/snapshot.before" "$home/state/system-map/example/snapshot.json" || fail "an intent edit changed observed records"
  out=$(http GET "$base/api/state?project=example")
  assert_contains "$out" "Accepts jobs." "the view reflects the edited intent"
  assert_contains "$out" '"fixture": true' "stand-in observations are marked as test data"
  stop_map_server
  # The annotation survives a server restart.
  view_json "$home"
  assert_equals "check scaling" "$(py "$home/view.json" 'd["subjects"]["api"]["annotations"][0]["text"]')" "annotations persist across restarts"
  pass "local UI reads are keyless and same-origin JSON writes are validated and persisted"
}

test_summary_is_bounded_and_marks_fixtures() {
  local home out
  home=$(new_home summary)
  map "$home" collect >/dev/null || fail "collect failed"
  out=$(map "$home" summary)
  assert_contains "$out" "TEST DATA, not live" "summary marks stand-in data"
  assert_contains "$out" "open discrepancies" "summary counts discrepancies"
  [ "$(printf '%s\n' "$out" | wc -l)" -le 16 ] || fail "summary exceeds its line bound"
  : > "$home/aws.log"
  map "$home" summary >/dev/null
  [ ! -s "$home/aws.log" ] || fail "summary made an AWS call"
  pass "the startup summary is local, bounded, and labels test data"
}

test_summary_includes_later_project_requests() {
  local home out project
  home=$(new_home summary-projects)
  for project in extra1 extra2 extra3 extra4; do
    printf 'project=%s\n' "$project" >> "$home/config/system-map"
  done
  mkdir -p "$home/state/system-map/extra4"
  printf '{"requests":{"review-due":{"kind":"daily"}}}\n' > "$home/state/system-map/extra4/requests.json"
  out=$(map "$home" summary) || fail "summary failed"
  assert_contains "$out" "extra4: review-due" "a fifth project's pending request reaches session start"
  [ "$(printf '%s\n' "$out" | wc -l)" -le 16 ] || fail "summary exceeds its line bound"
  pass "summary surfaces pending requests from every project"
}

test_proactive_prerequisites_and_lineage() {
  local home rc out
  home=$(new_home proactive)
  python3 - "$home/data/system-map/example/manifest.json" "$home/data/system-map/example/bindings.json" <<'PY'
import json, sys
m=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
for sid, adapter, entry in [('wake-function', 'aws.lambda_configuration', {'function_name':'example-wake'}), ('stop-schedule','aws.scheduler_schedule', {'schedule_name':'example-stop','group_name':'default'}), ('scheduler-role','aws.iam_role', {'role_name':'example-stop'})]:
    m['components'].append({'id':sid,'title':sid,'observe':[{'id':sid+'-read','binding':sid,'adapter':adapter}], 'version_from':sid+'-read'})
    b['bindings'][sid]=entry
m['components'][1]['lineage']=[{'stage':'source','subject':'source'}, {'stage':'installed','subject':'worker-host','expected':'ami-new'}, {'stage':'artifact','subject':'console','evidence':'owner-report'}]
m['prerequisites']=[]
for pid, producer, observation in [('wake-ready','wake-function','wake-function-read'),('stop-ready','stop-schedule','stop-schedule-read'),('role-ready','scheduler-role','scheduler-role-read'),('unmeasured','console',None),('owner-check','console',None)]:
    item={'id':pid,'title':pid,'producer':producer,'resource':pid,'phases':['submit'],'baseline':'both','authorization':'awaiting-authorization','next_check':'Obtain a bounded owner receipt.'}
    if observation: item['observation']=observation
    if pid=='owner-check': item['evidence']='owner-report'; item['producer']='worker-host'
    m['prerequisites'].append(item)
json.dump(m,open(sys.argv[1],'w')); json.dump(b,open(sys.argv[2],'w'))
PY
  map "$home" validate >/dev/null || fail "new adapters and prerequisites invalid"
  map "$home" collect >/dev/null || fail "fixture collection failed"
  view_json "$home"
  assert_equals "present" "$(py "$home/view.json" 'd["readiness"]["prerequisites"][0]["state"]')" "successful Lambda metadata is present"
  assert_equals "awaiting-authorization" "$(py "$home/view.json" 'd["readiness"]["prerequisites"][0]["authorization"]')" "presence does not authorize execution"
  assert_equals "unknown" "$(py "$home/view.json" 'd["readiness"]["prerequisites"][3]["state"]')" "unmeasured resource remains unknown"
  assert_equals "uncovered" "$(py "$home/view.json" 'd["readiness"]["prerequisites"][3]["coverage"]')" "missing observer is visible"
  assert_equals "uncovered" "$(py "$home/view.json" 'd["readiness"]["phases"][1]["coverage"]')" "unmodeled phase has a coverage gap"
  assert_equals "missing-evidence" "$(py "$home/view.json" 'd["readiness"]["prerequisites"][4]["coverage"]')" "missing receipt is visible"
  assert_equals "mismatch" "$(py "$home/view.json" 'd["subjects"]["api"]["lineage"][1]["status"]')" "installed lineage mismatch remains explicit"
  assert_equals "not-demonstrated" "$(py "$home/view.json" 'd["subjects"]["wake-function"]["layers"]["proof"]["status"]')" "metadata is not demonstrated proof"
  assert_not_contains "$(cat "$home/view.json")" "123456789012" "adapter metadata omits native role ids"
  assert_not_contains "$(cat "$home/view.json")" "fixture-private-payload" "adapters persist metadata only"
  assert_grep "lambda get-function-configuration" "$home/aws.log" "exact Lambda metadata operation"
  assert_grep "scheduler get-schedule" "$home/aws.log" "exact Scheduler metadata operation"
  assert_grep "iam get-role" "$home/aws.log" "exact IAM role metadata operation"
  aws_state "$home" '{"deny":["lambda"],"missing":["scheduler"]}'
  map "$home" collect >/dev/null || fail "partial read failed"
  view_json "$home"
  assert_equals "denied" "$(py "$home/view.json" 'd["readiness"]["prerequisites"][0]["state"]')" "denied prerequisite never becomes absent"
  assert_equals "absent" "$(py "$home/view.json" 'd["readiness"]["prerequisites"][1]["state"]')" "successful not-found means absent"
  python3 - "$home/receipt.json" "$home/view.json" <<'PY'
import json, sys, datetime
identity=json.load(open(sys.argv[2]))['subjects']['worker-host']['resource_identity']
json.dump({'schema':'fm-system-map.evidence.v1','id':'owner-report','subjects':['console'],'result':'not-run','recorded_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'summary':'Owner has not tested installation.','scope':'retained owner report only','versions':{'console':'locally-built-v2','worker-host':'ami-0123456789abcdef0'},'resource_identities':{'worker-host':identity},'prerequisites':{'owner-check':'not-tested'},'provenance':{'kind':'imported-report','source':'fixture owner'}},open(sys.argv[1],'w'))
PY
  map "$home" evidence add example "$home/receipt.json" >/dev/null || fail "owner receipt rejected"
  view_json "$home"
  assert_equals "not-tested" "$(py "$home/view.json" 'd["readiness"]["prerequisites"][4]["state"]')" "not tested differs from unknown"
  assert_equals "stale" "$(py "$home/view.json" 'd["subjects"]["api"]["lineage"][2]["status"]')" "unbound artifact report is not current lineage"
  assert_equals "None" "$(py "$home/view.json" 'd["subjects"]["api"]["lineage"][2]["version"]')" "reported artifact does not create an observed deployment"
  python3 - "$home/receipt.json" "$home/historical-lineage.json" "$home/data/system-map/example/manifest.json" <<'PY'
import json,sys
receipt=json.load(open(sys.argv[1])); receipt['id']='old-artifact'; receipt['historical']=True
receipt.pop('prerequisites'); receipt.pop('resource_identities'); receipt.pop('scope')
json.dump(receipt,open(sys.argv[2],'w'))
manifest=json.load(open(sys.argv[3])); artifact=manifest['components'][1]['lineage'][2]
artifact['evidence']='old-artifact'; artifact['expected']='locally-built-v3'
json.dump(manifest,open(sys.argv[3],'w'))
PY
  map "$home" evidence add example "$home/historical-lineage.json" >/dev/null || fail "historical lineage receipt rejected"
  view_json "$home"
  assert_equals "stale" "$(py "$home/view.json" 'd["subjects"]["api"]["lineage"][2]["status"]')" "historical artifact cannot claim a current mismatch"
  assert_equals "locally-built-v2" "$(py "$home/view.json" 'd["subjects"]["api"]["lineage"][2]["reported_version"]')" "historical reported version remains visible"
  python3 - "$home/data/system-map/example/bindings.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['bindings']['worker_host']['instance_id']='i-abcdef01234567890'; json.dump(d,open(p,'w'))
PY
  map "$home" collect >/dev/null || fail "resource B collection failed"
  view_json "$home"
  assert_equals "unknown" "$(py "$home/view.json" 'd["readiness"]["prerequisites"][4]["state"]')" "resource A receipt does not assess resource B"
  assert_equals "missing-evidence" "$(py "$home/view.json" 'd["readiness"]["prerequisites"][4]["coverage"]')" "resource B has no qualified owner receipt"
  python3 - "$home/data/system-map/example/bindings.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); del d['bindings']['worker_host']; json.dump(d,open(p,'w'))
PY
  view_json "$home"
  assert_equals "unknown" "$(py "$home/view.json" 'd["readiness"]["prerequisites"][4]["state"]')" "unbound resource cannot inherit the owner assessment"
  python3 - "$home/data/system-map/example/bindings.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['bindings']['worker_host']={'instance_id':'i-abcdef01234567890','pin':'ami-0123456789abcdef0'}; json.dump(d,open(p,'w'))
PY
  map "$home" collect >/dev/null || fail "resource B recollection failed"
  python3 - "$home/receipt.json" <<'PY'
import json,sys
p=sys.argv[1]; r=json.load(open(p)); r['id']='bad-reference'; r['prerequisites']={'typo':'present'}; json.dump(r,open(p,'w'))
PY
  rc=0; out=$(map "$home" evidence add example "$home/receipt.json" 2>&1) || rc=$?
  expect_code 1 "$rc" "receipt with unknown prerequisite is rejected"
  assert_contains "$out" "unknown prerequisite" "narrow prerequisite reference validation"
  python3 - "$home/state/system-map/example/snapshot.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['observations']['scheduler-role-read']['checked_at']='2000-01-01T00:00:00Z'; json.dump(d,open(p,'w'))
PY
  view_json "$home"
  assert_equals "stale" "$(py "$home/view.json" 'd["readiness"]["prerequisites"][2]["state"]')" "old present observation becomes stale"
  assert_equals "present" "$(py "$home/view.json" 'd["readiness"]["prerequisites"][2]["observed_state"]')" "historical observed state remains visible"
  python3 - "$home/data/system-map/example/manifest.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['prerequisites'][0]['observation']='typo'; json.dump(d,open(p,'w'))
PY
  rc=0; out=$(map "$home" validate 2>&1) || rc=$?
  expect_code 1 "$rc" "unknown prerequisite observation rejected"
  assert_contains "$out" "must belong to its producer" "prerequisite observation ownership enforced"
  pass "prerequisites distinguish coverage, denial, absence, stale, untested, authorization and lineage"
}

test_lineage_report_requires_current_binding() {
  local home
  home=$(new_home lineage-binding)
  python3 - "$home/data/system-map/example/manifest.json" <<'PY'
import json,sys
p=sys.argv[1]; manifest=json.load(open(p))
next(c for c in manifest['components'] if c['id']=='api')['lineage']=[{'stage':'installed','subject':'worker-host','expected':'ami-new','evidence':'lineage-report'}]
json.dump(manifest,open(p,'w'))
PY
  map "$home" collect >/dev/null || fail "lineage binding fixture collection failed"
  view_json "$home"
  python3 - "$home/view.json" "$home/lineage-receipt.json" <<'PY'
import datetime,json,sys
identity=json.load(open(sys.argv[1]))['subjects']['worker-host']['resource_identity']
receipt={'schema':'fm-system-map.evidence.v1','id':'lineage-report','subjects':['worker-host'],'result':'not-run','recorded_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'summary':'Worker version reported by owner.','versions':{'worker-host':'ami-old'},'resource_identities':{'worker-host':identity},'provenance':{'kind':'imported-report','source':'fixture owner'}}
json.dump(receipt,open(sys.argv[2],'w'))
PY
  map "$home" evidence add example "$home/lineage-receipt.json" >/dev/null || fail "lineage receipt rejected"
  view_json "$home"
  assert_equals "mismatch" "$(py "$home/view.json" 'd["subjects"]["api"]["lineage"][0]["status"]')" "observed installed version can establish a mismatch"
  aws_state "$home" '{"deny":["ec2"]}'
  map "$home" collect >/dev/null || fail "unobserved lineage collection failed"
  view_json "$home"
  assert_equals "reported" "$(py "$home/view.json" 'd["subjects"]["api"]["lineage"][0]["status"]')" "same-binding receipt cannot prove a current mismatch after denial"
  assert_equals "None" "$(py "$home/view.json" 'd["subjects"]["api"]["lineage"][0]["version"]')" "denied read leaves the installed version unobserved"
  assert_equals "ami-old" "$(py "$home/view.json" 'd["subjects"]["api"]["lineage"][0]["reported_version"]')" "receipt-reported version remains visible after denial"
  assert_equals "fixture owner" "$(py "$home/view.json" 'd["subjects"]["api"]["lineage"][0]["provenance"]["source"]')" "receipt provenance remains visible after denial"
  python3 - "$home/data/system-map/example/bindings.json" <<'PY'
import json,sys
p=sys.argv[1]; bindings=json.load(open(p)); bindings['bindings']['worker_host']['instance_id']='i-abcdef01234567890'; json.dump(bindings,open(p,'w'))
PY
  view_json "$home"
  assert_equals "stale" "$(py "$home/view.json" 'd["subjects"]["api"]["lineage"][0]["status"]')" "report for previous binding cannot claim a current mismatch"
  assert_equals "ami-old" "$(py "$home/view.json" 'd["subjects"]["api"]["lineage"][0]["reported_version"]')" "stale report keeps its version metadata"
  pass "lineage reports retain metadata without claiming an unobserved version"
}

test_prerequisite_receipt_requires_current_version() {
  local home rc=0 out
  home=$(new_home prerequisite-version)
  python3 - "$home/data/system-map/example/manifest.json" <<'PY'
import json,sys
p=sys.argv[1]; manifest=json.load(open(p))
next(item for item in manifest['prerequisites'] if item['id']=='migration-worker-record')['evidence']='worker-assessment'
json.dump(manifest,open(p,'w'))
PY
  map "$home" collect >/dev/null || fail "prerequisite version fixture collection failed"
  view_json "$home"
  python3 - "$home/view.json" "$home/worker-assessment.json" <<'PY'
import datetime,json,sys
worker=json.load(open(sys.argv[1]))['subjects']['worker-host']
receipt={'schema':'fm-system-map.evidence.v1','id':'worker-assessment','subjects':['worker-host'],'result':'not-run','recorded_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'summary':'Owner assessed current worker.','scope':'example worker','versions':{'worker-host':worker['version']},'resource_identities':{'worker-host':worker['resource_identity']},'prerequisites':{'migration-worker-record':'present'},'provenance':{'kind':'imported-report','source':'fixture owner'}}
json.dump(receipt,open(sys.argv[2],'w'))
PY
  map "$home" evidence add example "$home/worker-assessment.json" >/dev/null || fail "worker assessment rejected"
  view_json "$home"
  assert_equals "present" "$(py "$home/view.json" '[p for p in d["readiness"]["prerequisites"] if p["id"] == "migration-worker-record"][0]["state"]')" "matching version and resource qualify the assessment"
  aws_state "$home" '{"ami":"ami-abcdef01234567890"}'
  map "$home" collect >/dev/null || fail "same-instance new-image collection failed"
  view_json "$home"
  assert_equals "ami-abcdef01234567890" "$(py "$home/view.json" 'd["subjects"]["worker-host"]["version"]')" "worker image changed on the same instance"
  assert_equals "unknown" "$(py "$home/view.json" '[p for p in d["readiness"]["prerequisites"] if p["id"] == "migration-worker-record"][0]["state"]')" "old version assessment cannot qualify the new image"
  assert_equals "missing-evidence" "$(py "$home/view.json" '[p for p in d["readiness"]["prerequisites"] if p["id"] == "migration-worker-record"][0]["coverage"]')" "version mismatch stays unqualified"
  aws_state "$home" '{"deny":["ec2"]}'
  map "$home" collect >/dev/null || fail "denied-version collection failed"
  view_json "$home"
  assert_equals "unknown" "$(py "$home/view.json" '[p for p in d["readiness"]["prerequisites"] if p["id"] == "migration-worker-record"][0]["state"]')" "unobserved current version cannot qualify the receipt"
  python3 - "$home/data/system-map/example/manifest.json" <<'PY'
import json,sys
p=sys.argv[1]; manifest=json.load(open(p)); manifest['prerequisites'][0]['max_age_seconds']=86400
json.dump(manifest,open(p,'w'))
PY
  out=$(map "$home" validate 2>&1) || rc=$?
  expect_code 1 "$rc" "per-prerequisite freshness override is unsupported"
  assert_contains "$out" "unknown field 'max_age_seconds'" "freshness uses the shared cadence"
  pass "prerequisite receipts require current observed versions and shared freshness"
}

test_sample_lifecycle_coverage() {
  local home
  home=$(new_home sample-lifecycle)
  python3 - "$home/data/system-map/example/manifest.json" <<'PY'
import json,sys
p=sys.argv[1]; manifest=json.load(open(p)); next(item for item in manifest['prerequisites'] if item['id']=='console-config')['evidence']='console-install-report'; json.dump(manifest,open(p,'w'))
PY
  map "$home" validate >/dev/null || fail "sample lifecycle is invalid"
  view_json "$home"
  python3 - "$home/view.json" <<'PY' || fail "sample lifecycle coverage or proof state is wrong"
import json, sys
view = json.load(open(sys.argv[1]))
phases = {phase['id']: phase for phase in view['readiness']['phases']}
required = {'submit', 'wake', 'enroll', 'launch', 'score', 'cleanup', 'stop'}
assert required <= phases.keys()
assert all(phases[phase]['coverage'] == 'declared' for phase in required)
assert len(view['acceptance']) == 9
assert all(criterion['status'] == 'not-demonstrated' for criterion in view['acceptance'])
checks = {item['id']: item for item in view['readiness']['prerequisites']}
assert checks['migration-worker-record']['baseline'] == 'migration'
assert checks['worker-host']['baseline'] == 'both'
assert view['credentials'][0]['expiry_basis'] == 'unknown'
assert view['credentials'][0]['latest_safe_start'] is None
assert 'latest_possible_start' not in view['credentials'][0]
PY
  mkdir -p "$home/projects/example-platform/console-config-checkout"
  git -C "$home/projects/example-platform/console-config-checkout" init -q || fail "source checkout fixture could not initialize"
  git -C "$home/projects/example-platform/console-config-checkout" -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm source || fail "source checkout fixture could not commit"
  aws_state "$home" '{"queue_visible":1,"control_halted":false,"ecs_running":1}'
  map "$home" collect >/dev/null || fail "queued-work collection failed"
  view_json "$home"
  assert_equals "running" "$(py "$home/view.json" 'd["subjects"]["api"]["observations"][0]["current"]["state"]')" "fixture represents the post-submit API"
  assert_equals "present" "$(py "$home/view.json" '[p for p in d["readiness"]["prerequisites"] if p["id"] == "submission-api"][0]["state"]')" "post-submit running state does not contradict API availability"
  assert_equals "present" "$(py "$home/view.json" '[p for p in d["readiness"]["prerequisites"] if p["id"] == "api-stop"][0]["state"]')" "pre-stop running state does not contradict API availability"
  assert_equals "holding" "$(py "$home/view.json" 'd["subjects"]["queue"]["observations"][0]["current"]["state"]')" "fixture represents queued work"
  assert_equals "present" "$(py "$home/view.json" '[p for p in d["readiness"]["prerequisites"] if p["id"] == "wake-queue"][0]["state"]')" "queued work does not contradict the wake prerequisite"
  assert_equals "open" "$(py "$home/view.json" 'd["subjects"]["control-switch"]["observations"][0]["current"]["state"]')" "fixture represents the post-enrollment lift"
  assert_equals "present" "$(py "$home/view.json" '[p for p in d["readiness"]["prerequisites"] if p["id"] == "enroll-control"][0]["state"]')" "post-enrollment lift does not imply enrollment mismatch"
  assert_equals "present" "$(py "$home/view.json" '[p for p in d["readiness"]["prerequisites"] if p["id"] == "console-source"][0]["state"]')" "checkout establishes source availability"
  assert_equals "unknown" "$(py "$home/view.json" '[p for p in d["readiness"]["prerequisites"] if p["id"] == "console-config"][0]["state"]')" "source checkout does not establish installation"
  python3 - "$home/view.json" "$home/console-receipt.json" <<'PY'
import datetime,json,sys
view_path,receipt_path=sys.argv[1:]
view=json.load(open(view_path))
identity=view['subjects']['console']['observations'][0]['current']['binding_digest']
receipt={'schema':'fm-system-map.evidence.v1','id':'console-install-report','subjects':['console'],'result':'not-run','recorded_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'summary':'Source checkout alone does not prove installation.','scope':'example console checkout','resource_identities':{'console':identity},'prerequisites':{'console-config':'present'},'provenance':{'kind':'imported-report','source':'fixture owner'}}
json.dump(receipt,open(receipt_path,'w'))
PY
  map "$home" evidence add example "$home/console-receipt.json" >/dev/null || fail "source-scoped console receipt rejected"
  view_json "$home"
  assert_equals "unknown" "$(py "$home/view.json" '[p for p in d["readiness"]["prerequisites"] if p["id"] == "console-config"][0]["state"]')" "source-scoped receipt cannot qualify installed configuration"
  assert_equals "missing-evidence" "$(py "$home/view.json" '[p for p in d["readiness"]["prerequisites"] if p["id"] == "console-config"][0]["coverage"]')" "installed configuration still lacks bound evidence"
  pass "sample covers lifecycle prerequisites without manufacturing proof or issuer validity"
}

test_credential_full_window() {
  local home
  home=$(new_home cert-window)
  python3 - "$home/data/system-map/example/manifest.json" <<'PY'
import datetime,json,sys
p=sys.argv[1]; m=json.load(open(p)); now=datetime.datetime.now(datetime.timezone.utc)
iso=lambda t:t.isoformat()
m['credentials']=[{'id':'issuer','title':'Issuer','purpose':'Test issuer','kind':'ca','not_before':iso(now-datetime.timedelta(seconds=60)),'expires':iso(now+datetime.timedelta(seconds=1800)),'expiry_basis':'observed'}, {'id':'leaf','title':'Leaf','purpose':'Test identity','kind':'tls-leaf','not_before':iso(now-datetime.timedelta(seconds=60)),'issuer':'issuer','expires':iso(now+datetime.timedelta(seconds=7200)), 'expiry_basis':'observed','full_window_seconds':3600,'restart_required':'yes','renewal_owner':'fixture owner'}]
json.dump(m,open(p,'w'))
PY
  view_json "$home"
  assert_equals "does-not-fit" "$(py "$home/view.json" 'd["credentials"][1]["full_window"]')" "issuer limits remaining full window"
  assert_equals "3600" "$(py "$home/view.json" 'd["credentials"][1]["full_window_seconds"]')" "full interval preserved"
  python3 - "$home/view.json" <<'PY' || fail "safe-start arithmetic incorrect"
import datetime,json,sys
d=json.load(open(sys.argv[1])); c=d['credentials']; parse=lambda t:datetime.datetime.fromisoformat(t.replace('Z','+00:00')).timestamp()
assert abs(parse(c[0]['expires'])-parse(c[1]['latest_safe_start'])-3600)<1
PY
  python3 - "$home/data/system-map/example/manifest.json" <<'PY'
import json,sys
p=sys.argv[1]; m=json.load(open(p)); issuer=m['credentials'][0]; issuer['expiry_basis']='inferred'; issuer['expected_expires']=issuer.pop('expires'); json.dump(m,open(p,'w'))
PY
  view_json "$home"
  assert_equals "unknown" "$(py "$home/view.json" 'd["credentials"][1]["full_window"]')" "inferred issuer cannot establish feasibility"
  assert_equals "None" "$(py "$home/view.json" 'd["credentials"][1]["latest_safe_start"]')" "inferred issuer gives no latest safe start"
  assert_equals "False" "$(py "$home/view.json" '"latest_possible_start" in d["credentials"][1]')" "unknown timing has no speculative upper bound"
  python3 - "$home/data/system-map/example/manifest.json" <<'PY'
import json,sys
p=sys.argv[1]; m=json.load(open(p)); issuer=m['credentials'][0]; issuer['expiry_basis']='observed'; issuer['expires']=issuer.pop('expected_expires'); issuer.pop('not_before'); issuer.pop('kind'); json.dump(m,open(p,'w'))
PY
  view_json "$home"
  assert_equals "unknown" "$(py "$home/view.json" 'd["credentials"][1]["full_window"]')" "unlabeled issuer without validity cannot qualify safe timing"
  assert_equals "None" "$(py "$home/view.json" 'd["credentials"][1]["latest_safe_start"]')" "unlabeled issuer has no safe start"
  python3 - "$home/data/system-map/example/manifest.json" <<'PY'
import json,sys
p=sys.argv[1]; m=json.load(open(p)); m['credentials'][0]['kind']='intermediate'; json.dump(m,open(p,'w'))
PY
  view_json "$home"
  assert_equals "unknown" "$(py "$home/view.json" 'd["credentials"][1]["full_window"]')" "alternative issuer kind cannot bypass missing validity"
  python3 - "$home/data/system-map/example/manifest.json" <<'PY'
import datetime,json,sys
p=sys.argv[1]; m=json.load(open(p)); m['credentials'][0]['kind']='ca'; m['credentials'][0]['not_before']=(datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=60)).isoformat(); m['credentials'][0]['expires']=(datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(seconds=7200)).isoformat(); json.dump(m,open(p,'w'))
PY
  view_json "$home"
  assert_equals "fits" "$(py "$home/view.json" 'd["credentials"][1]["full_window"]')" "entire observed chain has full interval"
  python3 - "$home/data/system-map/example/manifest.json" <<'PY'
import json,sys
p=sys.argv[1]; manifest=json.load(open(p)); manifest['credentials'][1]['renewal_group']='shared'
json.dump(manifest,open(p,'w'))
PY
  local rc=0 out
  out=$(map "$home" validate 2>&1) || rc=$?
  expect_code 1 "$rc" "renewal grouping is unsupported"
  assert_contains "$out" "unknown field 'renewal_group'" "each credential owns its renewal metadata"
  pass "full-window timing accounts for issuer validity and inference"
}

test_inferred_expiry_does_not_alert() {
  local home rc out
  home=$(new_home inferred-expiry)
  python3 - "$home/data/system-map/example/manifest.json" <<'PY'
import datetime,json,sys
p=sys.argv[1]; manifest=json.load(open(p)); expired=(datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=1)).isoformat()
manifest['credentials']=[{'id':'inferred-cert','title':'Inferred certificate','kind':'tls-leaf','purpose':'Test identity','expiry_basis':'inferred','expected_expires':expired,'subjects':['api'],'full_window_seconds':3600}]
json.dump(manifest,open(p,'w'))
PY
  map "$home" collect >/dev/null || fail "inferred-expiry fixture collection failed"
  view_json "$home"
  assert_equals "False" "$(py "$home/view.json" 'any(g["kind"] == "credential" for g in d["discrepancies"])')" "inferred expiry cannot create an observed expiry alert"
  assert_equals "None" "$(py "$home/view.json" 'd["credentials"][0]["latest_safe_start"]')" "inferred expiry cannot establish safe start"
  python3 - "$home/data/system-map/example/manifest.json" <<'PY'
import json,sys
p=sys.argv[1]; manifest=json.load(open(p)); cred=manifest['credentials'][0]; cred['expires']=cred['expected_expires']; json.dump(manifest,open(p,'w'))
PY
  rc=0; out=$(map "$home" validate 2>&1) || rc=$?
  expect_code 1 "$rc" "inferred date in observed expiry field is rejected"
  assert_contains "$out" "put inferred dates in expected_expires" "inferred expiry uses its separate field"
  python3 - "$home/data/system-map/example/manifest.json" <<'PY'
import json,sys
p=sys.argv[1]; manifest=json.load(open(p)); cred=manifest['credentials'][0]; cred['expiry_basis']='observed'; cred.pop('expected_expires'); json.dump(manifest,open(p,'w'))
PY
  map "$home" collect >/dev/null || fail "observed-expiry fixture collection failed"
  view_json "$home"
  assert_equals "True" "$(py "$home/view.json" 'any(g["kind"] == "credential" and "expired" in g["title"] for g in d["discrepancies"])')" "observed expiry still creates an alert"
  pass "inferred expiry stays separate from observed alerts and timing"
}

test_legacy_expiry_basis_retains_observed_dates() {
  local home
  home=$(new_home legacy-expiry)
  python3 - "$home/data/system-map/example/manifest.json" <<'PY'
import datetime,json,sys
p=sys.argv[1]; manifest=json.load(open(p)); now=datetime.datetime.now(datetime.timezone.utc)
date=lambda days:(now+datetime.timedelta(days=days)).isoformat()
base={'kind':'ca','purpose':'Test identity','not_before':date(-30),'full_window_seconds':3600,'subjects':['api']}
manifest['credentials']=[dict(base,id='old-expired',title='Old expired',expires=date(-1)),
                         dict(base,id='old-expiring',title='Old expiring',expires=date(1)),
                         dict(base,id='old-future',title='Old future',expires=date(30)),
                         dict(base,id='unlabeled-window',title='Unlabeled window',expires=date(30),not_before=None),
                         dict(base,id='alternative-window',title='Alternative window',expires=date(30),not_before=None,kind='intermediate'),
                         dict(base,id='unknown-date',title='Unknown date',expires=date(-1),expiry_basis='unknown'),
                         dict(base,id='inferred-date',title='Inferred date',expected_expires=date(-1),expiry_basis='inferred')]
for cred in manifest['credentials']:
    if cred['id'] in ('unlabeled-window','alternative-window'):
        cred.pop('not_before')
        if cred['id']=='unlabeled-window': cred.pop('kind')
json.dump(manifest,open(p,'w'))
PY
  map "$home" collect >/dev/null || fail "legacy expiry fixture collection failed"
  view_json "$home"
  python3 - "$home/view.json" <<'PY' || fail "legacy and explicit expiry bases were classified incorrectly"
import json,sys
view=json.load(open(sys.argv[1])); creds={c['id']:c for c in view['credentials']}
alerts={d['title'] for d in view['discrepancies'] if d['status']=='open' and d['kind']=='credential'}
assert alerts=={'Old expired has expired','Old expiring expires within 7 days'},alerts
assert creds['old-expired']['remaining_seconds']<0
assert creds['old-expiring']['remaining_seconds']>0
assert creds['old-future']['full_window']=='fits'
assert creds['old-future']['latest_safe_start'] is not None
for id in ('unlabeled-window','alternative-window'):
    assert creds[id]['full_window']=='unknown'
    assert creds[id]['latest_safe_start'] is None
assert creds['unknown-date']['full_window']=='unknown'
assert creds['unknown-date']['latest_safe_start'] is None
assert creds['inferred-date']['full_window']=='unknown'
assert creds['inferred-date']['latest_safe_start'] is None
PY
  pass "legacy expires retain alerts and safe timing while explicit unknown and inferred do not"
}

test_historical_imported_assessment() {
  local home
  home=$(new_home historical-import)
  python3 - "$home/data/system-map/example/manifest.json" <<'PY'
import json,sys
p=sys.argv[1]; manifest=json.load(open(p)); next(item for item in manifest['prerequisites'] if item['id']=='migration-worker-record')['evidence']='historical-owner-report'; json.dump(manifest,open(p,'w'))
PY
  map "$home" collect >/dev/null || fail "historical assessment fixture collection failed"
  view_json "$home"
  python3 - "$home/view.json" "$home/historical-receipt.json" <<'PY'
import datetime,json,sys
identity=json.load(open(sys.argv[1]))['subjects']['worker-host']['resource_identity']
receipt={'schema':'fm-system-map.evidence.v1','id':'historical-owner-report','subjects':['worker-host'],'result':'not-run','recorded_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'summary':'Earlier bound worker assessment.','scope':'example worker','historical':True,'versions':{'worker-host':'ami-0123456789abcdef0'},'resource_identities':{'worker-host':identity},'prerequisites':{'migration-worker-record':'present'},'provenance':{'kind':'imported-report','source':'fixture owner'}}
json.dump(receipt,open(sys.argv[2],'w'))
PY
  map "$home" evidence add example "$home/historical-receipt.json" >/dev/null || fail "historical receipt rejected"
  view_json "$home"
  assert_equals "stale" "$(py "$home/view.json" '[p for p in d["readiness"]["prerequisites"] if p["id"] == "migration-worker-record"][0]["state"]')" "historical assessment is stale"
  assert_equals "present" "$(py "$home/view.json" '[p for p in d["readiness"]["prerequisites"] if p["id"] == "migration-worker-record"][0]["observed_state"]')" "historical receipt retains its assessed state"
  python3 - "$home/historical-receipt.json" "$home/future-receipt.json" <<'PY'
import datetime,json,sys
receipt=json.load(open(sys.argv[1])); receipt['id']='future-owner-report'
receipt['historical']=False
receipt['observed_at']=(datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=1)).isoformat()
json.dump(receipt,open(sys.argv[2],'w'))
PY
  local rc=0 out
  out=$(map "$home" evidence add example "$home/future-receipt.json" 2>&1) || rc=$?
  expect_code 1 "$rc" "future-dated prerequisite assessment is rejected"
  assert_contains "$out" "assessment time is in the future" "intake explains the unqualified assessment"
  python3 - "$home/future-receipt.json" <<'PY'
import json,sys
p=sys.argv[1]; receipt=json.load(open(p)); receipt['id']='future-recorded-report'
receipt['recorded_at']=receipt.pop('observed_at'); json.dump(receipt,open(p,'w'))
PY
  rc=0; out=$(map "$home" evidence add example "$home/future-receipt.json" 2>&1) || rc=$?
  expect_code 1 "$rc" "future recorded time cannot qualify a prerequisite"
  assert_contains "$out" "assessment time is in the future" "recorded time is checked when observed time is absent"
  pass "historical owner receipts retain assessed state separately from freshness"
}

test_delegated_active_to_idle() {
  local home out epoch
  home=$(new_home delegated)
  epoch=$(date +%s)
  printf 'kind=secondmate\n' > "$home/state/mate.meta"
  printf 'working [at=%s]: commissioned work in progress\n' "$epoch" > "$home/state/mate.status"
  map "$home" collect >/dev/null || fail "initial collection failed"
  python3 - "$home/state/system-map/example/health.json" <<'PY'
import datetime,json,sys
p=sys.argv[1]; d=json.load(open(p)); d['last_success_at']=(datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=900)).isoformat(); json.dump(d,open(p,'w'))
PY
  view_json "$home"
  assert_equals "True" "$(py "$home/view.json" 'd["collector"]["stale"]')" "delegated active cadence marks delayed observations stale"
  assert_equals "True" "$(py "$home/view.json" 'd["collector"]["activity"]["active"]')" "working parent record selects active cadence"
  printf 'paused [at=%s]: parked for authorized native work\n' "$epoch" >> "$home/state/mate.status"
  view_json "$home"
  assert_equals "False" "$(py "$home/view.json" 'd["collector"]["activity"]["active"]')" "paused mate returns cadence to idle"
  assert_equals "False" "$(py "$home/view.json" 'd["collector"]["stale"]')" "idle cadence allows the idle observation interval"
  mkdir -p "$home/state/pending-replies"
  printf 'schema=fm-pending-reply.v1\ntask_id=mate\nphase=awaiting_report\ndelivered_epoch=%s\n' "$((epoch+1))" > "$home/state/pending-replies/request"
  view_json "$home"
  assert_equals "True" "$(py "$home/view.json" 'd["collector"]["activity"]["active"]')" "delivered delegated request selects active"
  printf 'schema=fm-pending-reply.v1\ntask_id=mate\nphase=resolved\ndelivered_epoch=%s\n' "$((epoch+1))" > "$home/state/pending-replies/request"
  view_json "$home"
  assert_equals "False" "$(py "$home/view.json" 'd["collector"]["activity"]["active"]')" "resolved request does not keep parked mate active"
  printf 'working [corr=0123456789abcdef] [at=%s]: delegated work resumed\n' "$((epoch+2))" >> "$home/state/mate.status"
  view_json "$home"
  assert_equals "True" "$(py "$home/view.json" 'd["collector"]["activity"]["active"]')" "correlated working report restores active cadence"
  assert_equals "True" "$(py "$home/view.json" 'd["collector"]["stale"]')" "correlated working report tightens freshness"
  printf 'paused [at=%s] [corr=0123456789abcdef]: delegated work parked\n' "$((epoch+3))" >> "$home/state/mate.status"
  view_json "$home"
  assert_equals "False" "$(py "$home/view.json" 'd["collector"]["activity"]["active"]')" "correlated pause returns to idle cadence"
  printf 'schema=fm-pending-reply.v1\ncorr_id=2222222222222222\ntask_id=mate\nphase=awaiting_report\ndelivered_epoch=%s\n' "$((epoch+3))" > "$home/state/pending-replies/request-new"
  view_json "$home"
  assert_equals "True" "$(py "$home/view.json" 'd["collector"]["activity"]["active"]')" "same-second unrelated pause cannot park a new request"
  printf 'paused [corr=3333333333333333] [at=%s]: another request parked\n' "$((epoch+4))" >> "$home/state/mate.status"
  view_json "$home"
  assert_equals "True" "$(py "$home/view.json" 'd["collector"]["activity"]["active"]')" "later unrelated pause cannot park the pending request"
  printf 'paused [corr=2222222222222222] [at=%s]: pending request parked\n' "$((epoch+4))" >> "$home/state/mate.status"
  view_json "$home"
  assert_equals "False" "$(py "$home/view.json" 'd["collector"]["activity"]["active"]')" "matching pause parks the pending request"
  printf 'working corr=4444444444444444 [at=%s]: delegated work resumed after a resolved request\n' "$((epoch+5))" >> "$home/state/mate.status"
  view_json "$home"
  assert_equals "True" "$(py "$home/view.json" 'd["collector"]["activity"]["active"]')" "unbracketed working report restores active cadence"
  printf 'schema=fm-pending-reply.v1\ncorr_id=4444444444444444\ntask_id=mate\nphase=awaiting_report\ndelivered_epoch=%s\n' "$((epoch+5))" > "$home/state/pending-replies/request-unbracketed"
  printf 'needs-decision corr=4444444444444444 [key=review] [at=%s]: delegated decision pending\n' "$((epoch+6))" >> "$home/state/mate.status"
  view_json "$home"
  assert_equals "False" "$(py "$home/view.json" 'd["collector"]["activity"]["active"]')" "unbracketed decision parks its correlated request"
  out=$(map "$home" tick)
  assert_contains "$out" 'not due (idle cadence)' "tick uses same derived activity"
  pass "delegated work changes cadence without scanning child fleets"
}

test_access_relationships_and_conservative_comparison() {
  local home out before after
  home=$(new_home access)
  python3 - "$home" <<'PYTEST'
import json,sys,hashlib
from pathlib import Path
h=Path(sys.argv[1]); p=h/'data/system-map/example/manifest.json'; m=json.load(open(p))
def sha(v): return hashlib.sha256(json.dumps(v,sort_keys=True,separators=(',',':')).encode()).hexdigest()
policy={"Version":"2012-10-17","Statement":[{"Effect":"Deny","Principal":{"AWS":["arn:aws:iam::123456789012:role/a","arn:aws:iam::123456789012:role/b"]},"Action":["s3:GetObject","s3:PutObject"],"Resource":["arn:aws:s3:::fixture/*"],"Condition":{"Bool":{"aws:SecureTransport":"false"}}}]}
# The fixture baseline is already canonical by the declared normalization.
base={"format":"policy","complete":True,"sha256":sha(policy),"raw_sha256":sha(json.dumps(policy)),"source":"sanitized owner fixture","observed_at":"2026-01-01T00:00:00Z"}
owners=[{"name":"fixture owner"}]
components=m['components']
components.append({"id":"access-role","title":"Access role","observe":[{"id":"access-trust","adapter":"aws.iam_role_access","binding":"access_role","role":"version"}],"version_from":"access-trust"})
components.append({"id":"trust-source","title":"Required trust principal","observe":[{"id":"source-role","adapter":"aws.iam_role_access","binding":"source_role","role":"version"}],"version_from":"source-role"})
for oid,adapter,binding in [('access-bucket','aws.s3_policy','access_bucket'),('access-inline','aws.iam_inline_policy','access_inline'),('access-managed','aws.iam_managed_policy','access_managed'),('access-queue','aws.sqs_policy','access_queue'),('access-table','aws.dynamodb_policy','access_table'),('access-key','aws.kms_policy','access_kms'),('access-tags','aws.ecs_task_metadata','access_tags')]:
 components.append({'id':oid,'title':oid,'observe':[{'id':oid+'-read','adapter':adapter,'binding':binding,'role':'version'}],'version_from':oid+'-read'})
deps=[]
for did,kind,subject in [('bucket-check','resource-policy','access-bucket'),('trust-check','trust','access-role'),('role-check','role-existence','trust-source'),('inline-check','identity-policy','access-inline'),('managed-check','identity-policy','access-managed'),('boundary-check','permissions-boundary','access-managed'),('key-check','key-policy','access-key'),('queue-check','resource-policy','access-queue'),('tags-check','tags','access-tags')]:
 d={'id':did,'title':did,'kind':kind,'subject':subject,'participant':'target' if kind in ('resource-policy','key-policy','tags') else 'identity','observation':next(c for c in components if c['id']==subject)['observe'][0]['id'],'baseline':dict(base),'owners':owners,'next_check':'Read exact configured metadata with existing identity.'}
 if did=='trust-check': d['references']=['trust-source']
 if did=='queue-check': d['key_dependency']='key-check'; d['baseline']['encryption_identity']=sha({'KmsMasterKeyId':'fixture-key','SqsManagedSseEnabled':None})
 if did=='tags-check': d['baseline']={'format':'tags','complete':False,'source':'retained request omitted include=TAGS','observed_at':'2026-01-01T00:00:00Z'}
 deps.append(d)
deps.append(dict(next(d for d in deps if d['id']=='trust-check'),id='identity-role-check',title='Identity role',kind='role-existence',references=[]))
deps.append({'id':'bucket-key-na','title':'Bucket key policy','kind':'key-policy','subject':'access-bucket','participant':'target','applicability':'not-applicable','reason':'The fixture bucket declares no KMS key relationship.','owners':owners,'next_check':'Review encryption configuration before changing this reason.'})
for kind in ['permissions-boundary','session-policy','organization-policy','endpoint-policy']:
 deps.append({'id':kind,'title':kind,'kind':kind,'subject':'access-role','participant':'identity','owners':owners,'next_check':'Owner must supply restriction evidence.'})
m['access_dependencies']=deps
identity_deps={'identity-role-check','trust-check','inline-check','managed-check','permissions-boundary','session-policy','organization-policy','endpoint-policy'}
m['interactions']=[{'id':'console-request','title':'Console to exact bucket','caller':'access-role','identity':'access-role','target':'access-bucket','operations':['s3:GetObject'],'phases':[m['lifecycle']['phases'][0]['id']],'dependencies':[d['id'] for d in deps if d['id'] in identity_deps|{'bucket-check','bucket-key-na'}],'context':{'transport':'TLS','unknown_condition_context':'explicitly unobserved'},'analysis_scope':'Exact configured action and target; no effective IAM evaluation.','owners':owners,'next_check':'Owner supplies actual current-version request receipt.'}]
queue_request=dict(m['interactions'][0],id='queue-request',title='Identity to encrypted queue',target='access-queue',operations=['sqs:SendMessage'],dependencies=[d['id'] for d in deps if d['id'] in identity_deps|{'queue-check','key-check'}])
m['interactions'].append(queue_request)
role_request=dict(m['interactions'][0],id='lowercase-role-request',title='Synthetic role-carrying request',operations=['lambda:createfunction'])
m['interactions'].append(role_request)
pass_role_request=dict(m['interactions'][0],id='explicit-pass-role-request',title='Synthetic explicit PassRole request',operations=['iam:PassRole'])
m['interactions'].append(pass_role_request)
p.write_text(json.dumps(m))
p=h/'data/system-map/example/bindings.json'; b=json.load(open(p)); b['scope']['expected_account']='123456789012'; b['bindings'].update({'access_role':{'role_name':'fixture-target'},'source_role':{'role_name':'fixture-source'},'access_bucket':{'bucket':'fixture'},'access_inline':{'role_name':'fixture-target','policy_name':'fixture-inline'},'access_managed':{'policy_arn':'arn:aws:iam::123456789012:policy/fixture'},'access_queue':{'queue_url':'https://sqs.us-east-1.amazonaws.com/123456789012/fixture'},'access_table':{'resource_arn':'arn:aws:dynamodb:us-east-1:123456789012:table/fixture'},'access_kms':{'key_id':'fixture-key'},'access_tags':{'task_definition':'fixture:1'}}); p.write_text(json.dumps(b))
reordered=json.loads(json.dumps(policy)); reordered['Statement'][0]['Principal']['AWS'].reverse(); reordered['Statement'][0]['Action'].reverse()
responses={'get-bucket-policy':{'Policy':json.dumps(reordered)},'get-role-policy':{'PolicyDocument':policy},'get-policy':{'DefaultVersionId':'v7'},'get-policy-version':{'PolicyDocument':policy},'get-queue-attributes':{'Attributes':{'Policy':json.dumps(policy),'KmsMasterKeyId':'fixture-key','ApproximateNumberOfMessages':'0','ApproximateNumberOfMessagesNotVisible':'0'}},'get-resource-policy':{'Policy':json.dumps(policy)},'get-key-policy':{'Policy':json.dumps(policy)},'describe-task-definition':{'taskDefinition':{'taskDefinitionArn':'arn:aws:ecs:us-east-1:123456789012:task-definition/fixture:1','revision':1},'tags':[{'key':'Owner','value':'fixture'}]},'get-role':{'RoleId':'fixture-role-id','Arn':'arn:aws:iam::123456789012:role/fixture-source','CreateDate':'2026-01-01T00:00:00Z','PermissionsBoundary':None,'AssumeRolePolicyDocument':{'Statement':[{'Effect':'Allow','Principal':{'AWS':'arn:aws:iam::123456789012:role/fixture-source'},'Action':'sts:AssumeRole'}]}},'list-attached-role-policies':{'AttachedPolicies':[{'PolicyArn':'arn:aws:iam::123456789012:policy/fixture','PolicyName':'fixture'}],'IsTruncated':False},'list-role-policies':{'PolicyNames':['fixture-inline'],'IsTruncated':False}}
(h/'aws-state.json').write_text(json.dumps({'responses':responses})); (h/'access-original.json').write_text(json.dumps({'responses':responses}))
PYTEST
  python3 - "$home" <<'PYTEST'
import json,sys,pathlib
p=pathlib.Path(sys.argv[1])/'data/system-map/example/manifest.json'; m=json.load(open(p)); m['interactions'][-1]['operations']=['iam:*']; p.write_text(json.dumps(m))
PYTEST
  local rc=0
  out=$(map "$home" validate 2>&1) || rc=$?
  expect_code 1 "$rc" "wildcard interaction action must be rejected"
  assert_contains "$out" "operations must be explicit" "wildcard rejection names exact operations"
  python3 - "$home" <<'PYTEST'
import json,sys,pathlib
p=pathlib.Path(sys.argv[1])/'data/system-map/example/manifest.json'; m=json.load(open(p)); m['interactions'][-1]['operations']=['iam:PassRole']; p.write_text(json.dumps(m))
PYTEST
  map "$home" validate >/dev/null || fail "explicit PassRole interaction is invalid"
  out=$(map "$home" collect) || fail "access collection: $out"
  view_json "$home"
  assert_equals "representation-only" "$(py "$home/view.json" 'next(d for d in d["access"]["dependencies"] if d["id"]=="bucket-check")["comparison"]')" "principal/action order is representational"
  assert_equals "incomplete-baseline" "$(py "$home/view.json" 'next(d for d in d["access"]["dependencies"] if d["id"]=="tags-check")["comparison"]')" "unrequested historical tags are incomplete"
  assert_equals "unknown" "$(py "$home/view.json" 'd["access"]["interactions"][0]["effective_access"]')" "observed policy does not imply effective permission"
  assert_equals "not-demonstrated" "$(py "$home/view.json" 'd["access"]["interactions"][0]["request_proof"]')" "request proof stays separate"
  assert_equals "['pass-role']" "$(py "$home/view.json" 'next(i for i in d["access"]["interactions"] if i["id"]=="lowercase-role-request")["missing_kinds"]')" "lowercase role-carrying action requires PassRole coverage"
  assert_equals "['pass-role']" "$(py "$home/view.json" 'next(i for i in d["access"]["interactions"] if i["id"]=="explicit-pass-role-request")["missing_kinds"]')" "explicit iam:PassRole requires its dependency"
  assert_equals "[]" "$(py "$home/view.json" 'd["access"]["interactions"][0]["missing_kinds"]')" "ordinary read needs no PassRole dependency"
  assert_equals "4" "$(py "$home/view.json" 'len([g for g in d["access"]["gaps"] if g.get("state")=="unobserved"])')" "all independent restriction gaps appear together"
  assert_equals "observed" "$(py "$home/view.json" 'next(d for d in d["access"]["dependencies"] if d["id"]=="trust-check")["reference_states"][0]["state"]')" "exact trust reference is observed"
  assert_grep 'include TAGS' "$home/aws.log" "tag collector explicitly requests tags"
  assert_equals "v7" "$(py "$home/view.json" 'd["subjects"]["access-managed"]["observations"][0]["current"]["facts"]["policy_version"]')" "managed policy default version retained"
  python3 - "$home" <<'PYTEST'
import json,sys,pathlib
h=pathlib.Path(sys.argv[1]); p=h/'aws-state.json'; s=json.load(open(p)); policy=json.loads(s['responses']['get-bucket-policy']['Policy']); policy['Statement'][0]['Condition']['Bool']['aws:SecureTransport']='true'; s['responses']['get-bucket-policy']['Policy']=json.dumps(policy); del s['responses']['describe-task-definition']['tags']; s['responses']['get-role']['Arn']='arn:aws:iam::123456789012:role/wrong-source'; s['responses']['list-role-policies']={'PolicyNames':['hidden-policy'],'IsTruncated':True,'Marker':'more'}; p.write_text(json.dumps(s))
PYTEST
  map "$home" collect >/dev/null || fail "independent partial sweep"
  view_json "$home"
  assert_equals "policy-drift" "$(py "$home/view.json" 'next(d for d in d["access"]["dependencies"] if d["id"]=="bucket-check")["comparison"]')" "condition change is true drift"
  assert_equals "wrong-reference" "$(py "$home/view.json" 'next(d for d in d["access"]["dependencies"] if d["id"]=="trust-check")["reference_states"][0]["state"]')" "existing but wrong trust principal is distinct"
  assert_equals "unknown" "$(py "$home/view.json" 'd["subjects"]["access-tags"]["observations"][0]["current"]["outcome"]')" "missing tags member is unknown"
  assert_equals "False" "$(py "$home/view.json" 'd["subjects"]["access-role"]["observations"][0]["current"]["facts"]["complete"]')" "truncated policy list cannot become complete"
  python3 - "$home" <<'PYTEST'
import json,sys,pathlib
p=pathlib.Path(sys.argv[1])/'aws-state.json'; s=json.load(open(p)); s['responses']['list-role-policies']={'PolicyNames':['hidden-policy'],'IsTruncated':False};p.write_text(json.dumps(s))
PYTEST
  map "$home" collect >/dev/null || fail "unread policy inventory"
  view_json "$home"
  assert_equals "1" "$(py "$home/view.json" 'len(next(d for d in d["access"]["dependencies"] if d["id"]=="trust-check")["unobserved_policy_documents"])')" "an attachment list cannot substitute for a policy document"
  aws_state "$home" '{"deny":["iam"]}'
  map "$home" collect >/dev/null || fail "denial collection"
  view_json "$home"
  assert_equals "denied" "$(py "$home/view.json" 'next(d for d in d["access"]["dependencies"] if d["id"]=="trust-check")["state"]')" "denied role checks remain denied"
  assert_equals "ok" "$(py "$home/view.json" 'd["subjects"]["queue"]["observations"][0]["current"]["outcome"]')" "denial never stops independent configured reads"
  assert_equals "denied" "$(py "$home/view.json" 'next(d for d in d["access"]["dependencies"] if d["id"]=="trust-check")["reference_states"][0]["state"]')" "unobserved principal not inferred from historical role"
  aws_state "$home" '{"missing":["iam"]}'
  map "$home" collect >/dev/null || fail "authoritative role absence"
  view_json "$home"
  assert_equals "absent" "$(py "$home/view.json" 'next(d for d in d["access"]["dependencies"] if d["id"]=="trust-check")["reference_states"][0]["state"]')" "authoritatively missing role remains distinct"
  assert_no_grep 'sts assume-role' "$home/aws.log" "collector never pivots to retry a denied or absent read"
  [ ! -e "$home/state/system-map/example/reads" ] || fail "raw access responses must not be archived"
  # Complete only the synthetic declared baselines, then record an actual
  # fixture request through public evidence intake. No AWS request is sent.
  python3 - "$home" <<'PYTEST'
import json,sys,pathlib
h=pathlib.Path(sys.argv[1]); (h/'aws-state.json').write_text((h/'access-original.json').read_text())
p=h/'data/system-map/example/manifest.json'; m=json.load(open(p));
for i in m['interactions'][:2]:
 i['evidence']='fixture-request'; i['context_complete']=True; i['context']={'transport':'TLS','resource_prefix':'fixture/*'}
p.write_text(json.dumps(m))
PYTEST
  map "$home" collect >/dev/null || fail "restore synthetic observations"
  python3 - "$home" <<'PYTEST'
import json,sys,pathlib
h=pathlib.Path(sys.argv[1]); p=h/'data/system-map/example/manifest.json'; m=json.load(open(p)); snap=json.load(open(h/'state/system-map/example/snapshot.json'))
for dep in m['access_dependencies']:
 if dep.get('observation'):
  facts=snap['observations'][dep['observation']]['facts']; dep['baseline']={'format':facts['format'],'complete':True,'sha256':facts['sha256'],'raw_sha256':facts['raw_sha256'],'source':'fixture exact read','observed_at':snap['finished_at']}
  if dep['id']=='queue-check': dep['baseline']['encryption_identity']=facts['encryption_identity']
  if dep['id'] in ('trust-check','role-check','identity-role-check'): dep['baseline']['relationships_sha256']=facts['relationships_sha256']
 else:
  dep['applicability']='not-applicable'; dep['reason']='Synthetic fixture with no restriction in this declared class; no production claim.'
p.write_text(json.dumps(m))
PYTEST
  view_json "$home"
  assert_equals "declared-baselines-observed" "$(py "$home/view.json" 'd["access"]["interactions"][0]["static_coverage"]')" "complete declared coverage is separate from permission"
  assert_equals "declared-baselines-observed" "$(py "$home/view.json" 'd["access"]["interactions"][1]["static_coverage"]')" "queue access has participant-bound coverage"
  python3 - "$home" <<'PYTEST'
import json,sys,pathlib,datetime
h=pathlib.Path(sys.argv[1]); v=json.load(open(h/'view.json')); ids=['access-role','access-bucket','access-queue']; at=datetime.datetime.now(datetime.timezone.utc).isoformat()
r={'schema':'fm-system-map.evidence.v1','id':'fixture-request','subjects':ids,'versions':{s:v['subjects'][s]['version'] for s in ids},'resource_identities':{s:v['subjects'][s]['resource_identity'] for s in ids},'result':'pass','recorded_at':at,'observed_at':at,'scope':'sanitized fixture request; no native execution','summary':'Fixture owner request receipt','provenance':{'kind':'receipt','source':'fixture owner'},'access_requests':{i['id']:i['assertion_digest'] for i in v['access']['interactions'][:2]}}
(h/'request.json').write_text(json.dumps(r))
PYTEST
  map "$home" evidence add example "$home/request.json" >/dev/null || fail "valid request receipt"
  view_json "$home"
  assert_equals "demonstrated" "$(py "$home/view.json" 'd["access"]["interactions"][0]["request_proof"]')" "exact current-version request qualifies"
  assert_equals "demonstrated" "$(py "$home/view.json" 'd["access"]["interactions"][1]["request_proof"]')" "queue request proof qualifies independently"
  assert_equals "unknown" "$(py "$home/view.json" 'd["access"]["interactions"][0]["effective_access"]')" "one request never proves general effective access"
  map "$home" collect >/dev/null || fail "repeat identical read"
  view_json "$home"
  assert_equals "demonstrated" "$(py "$home/view.json" 'd["access"]["interactions"][0]["request_proof"]')" "identical refreshed checks preserve exact receipt binding"
  cp "$home/data/system-map/example/manifest.json" "$home/inventory-manifest.json"
  cp "$home/aws-state.json" "$home/inventory-aws-state.json"
  python3 - "$home" <<'PYTEST'
import datetime,json,pathlib,sys
h=pathlib.Path(sys.argv[1]); p=h/'data/system-map/example/manifest.json'; m=json.load(open(p)); at=datetime.datetime.now(datetime.timezone.utc).isoformat(); owners=[{'name':'fixture owner'}]
for did,kind,mark in [('imported-role-existence','role-existence','1'),('imported-trust','trust','2')]:
 m['access_dependencies'].append({'id':did,'title':did,'kind':kind,'subject':'access-role','participant':'identity','evidence':'inventory-owner','baseline':{'format':'role' if kind=='role-existence' else 'policy','complete':True,'sha256':mark*64,'source':'fixture owner assessment','observed_at':at},'owners':owners,'next_check':'Review current bound role evidence.'})
i=dict(m['interactions'][0],id='unlinked-role-inventory',title='Imported role checks with incomplete policy documents',evidence='inventory-request'); i['dependencies']=[d for d in i['dependencies'] if d not in ('identity-role-check','trust-check')]+['imported-role-existence','imported-trust']; m['interactions'].append(i); p.write_text(json.dumps(m)); p=h/'aws-state.json'; s=json.load(open(p)); s['responses']['list-attached-role-policies']['AttachedPolicies'].append({'PolicyArn':'arn:aws:iam::123456789012:policy/fixture-second','PolicyName':'fixture-second'}); p.write_text(json.dumps(s))
PYTEST
  map "$home" collect >/dev/null || fail "two-policy role inventory collection"
  view_json "$home"
  python3 - "$home" <<'PYTEST'
import datetime,json,pathlib,sys
h=pathlib.Path(sys.argv[1]); v=json.load(open(h/'view.json')); subject=v['subjects']['access-role']; at=datetime.datetime.now(datetime.timezone.utc).isoformat(); checks={}
for did,fmt,mark in [('imported-role-existence','role','1'),('imported-trust','policy','2')]:
 checks[did]={'outcome':'ok','binding_digest':subject['resource_identity'],'observer_identity':'1'*64,'version':did+'-v1','facts':{'format':fmt,'complete':True,'sha256':mark*64}}
r={'schema':'fm-system-map.evidence.v1','id':'inventory-owner','subjects':['access-role'],'versions':{'access-role':subject['version']},'resource_identities':{'access-role':subject['resource_identity']},'result':'pass','recorded_at':at,'observed_at':at,'scope':'fixture current role and trust review','summary':'Owner role and trust assessments','provenance':{'kind':'receipt','source':'fixture owner'},'access_checks':checks}; (h/'inventory-owner.json').write_text(json.dumps(r))
PYTEST
  map "$home" evidence add example "$home/inventory-owner.json" >/dev/null || fail "imported role and trust assessments"
  view_json "$home"
  assert_equals "observed" "$(py "$home/view.json" 'next(i for i in d["access"]["interactions"] if i["id"]=="unlinked-role-inventory")["identity_role_inventory"]')" "bound identity inventory is current"
  assert_equals "[]" "$(py "$home/view.json" 'next(i for i in d["access"]["interactions"] if i["id"]=="unlinked-role-inventory")["missing_dependencies"]')" "declared policy A and imported role checks remain current"
  assert_equals "1" "$(py "$home/view.json" 'len(next(i for i in d["access"]["interactions"] if i["id"]=="unlinked-role-inventory")["uncovered_policy_identities"])')" "second attached policy has its own uncovered fingerprint"
  assert_equals "gaps" "$(py "$home/view.json" 'next(i for i in d["access"]["interactions"] if i["id"]=="unlinked-role-inventory")["static_coverage"]')" "imported role checks cannot hide missing attached policy"
  python3 - "$home" <<'PYTEST'
import datetime,json,pathlib,sys
h=pathlib.Path(sys.argv[1]); v=json.load(open(h/'view.json')); i=next(i for i in v['access']['interactions'] if i['id']=='unlinked-role-inventory'); ids=['access-role','access-bucket']; at=datetime.datetime.now(datetime.timezone.utc).isoformat(); r={'schema':'fm-system-map.evidence.v1','id':'inventory-request','subjects':ids,'versions':{s:v['subjects'][s]['version'] for s in ids},'resource_identities':{s:v['subjects'][s]['resource_identity'] for s in ids},'result':'pass','recorded_at':at,'observed_at':at,'scope':'synthetic request with one unchecked attached policy','summary':'Current request cannot establish complete coverage','provenance':{'kind':'receipt','source':'fixture owner'},'access_requests':{i['id']:i['assertion_digest']}}; (h/'inventory-request.json').write_text(json.dumps(r))
PYTEST
  map "$home" evidence add example "$home/inventory-request.json" >/dev/null || fail "inventory request receipt intake"
  view_json "$home"
  assert_equals "stale" "$(py "$home/view.json" 'next(i for i in d["access"]["interactions"] if i["id"]=="unlinked-role-inventory")["request_proof"]')" "matching receipt cannot prove missing attached policy"
  cp "$home/inventory-manifest.json" "$home/data/system-map/example/manifest.json"
  cp "$home/inventory-aws-state.json" "$home/aws-state.json"
  map "$home" collect >/dev/null || fail "restore role inventory fixture"
  cp "$home/data/system-map/example/manifest.json" "$home/shared-policy-manifest.json"
  cp "$home/data/system-map/example/bindings.json" "$home/shared-policy-bindings.json"
  python3 - "$home" <<'PYTEST'
import copy,json,pathlib,sys
h=pathlib.Path(sys.argv[1]); p=h/'data/system-map/example/manifest.json'; m=json.load(open(p)); bpath=h/'data/system-map/example/bindings.json'; b=json.load(open(bpath))
subjects={'access-role':'access-role-b','access-inline':'access-inline-b','access-managed':'access-managed-b'}
bindings={'access_role':'access_role_b','access_inline':'access_inline_b','access_managed':'access_managed_b'}
observations={}
for c in list(m['components']):
 if c['id'] in subjects:
  clone=copy.deepcopy(c); clone['id']=subjects[c['id']]; clone['title']=clone['id']; clone['observe'][0]['id']+='-b'; clone['observe'][0]['binding']=bindings[clone['observe'][0]['binding']]; clone['version_from']=clone['observe'][0]['id']; observations[c['id']]=clone['observe'][0]['id']; m['components'].append(clone)
for d in list(m['access_dependencies']):
 if d['id'] in ('identity-role-check','trust-check','inline-check','managed-check','permissions-boundary','session-policy','organization-policy','endpoint-policy'):
  clone=copy.deepcopy(d); clone['id']+='-b'; clone['title']=clone['id']; clone['subject']=subjects[d['subject']]
  if clone.get('observation'): clone['observation']=observations[d['subject']]
  m['access_dependencies'].append(clone)
a=copy.deepcopy(m['interactions'][0]); a['id']='shared-managed-a'; a['evidence']='shared-managed-request'; m['interactions'].append(a)
other=copy.deepcopy(a); other['id']='shared-managed-b'; other['caller']='access-role-b'; other['identity']='access-role-b'; other['dependencies']=[d+'-b' if d in ('identity-role-check','trust-check','inline-check','managed-check','permissions-boundary','session-policy','organization-policy','endpoint-policy') else d for d in a['dependencies']]; m['interactions'].append(other); p.write_text(json.dumps(m))
b['bindings']['access_role_b']={'role_name':'fixture-other'}; b['bindings']['access_inline_b']={'role_name':'fixture-other','policy_name':'fixture-inline'}; b['bindings']['access_managed_b']=copy.deepcopy(b['bindings']['access_managed']); bpath.write_text(json.dumps(b))
PYTEST
  map "$home" collect >/dev/null || fail "shared managed policy collection"
  python3 - "$home" <<'PYTEST'
import json,pathlib,sys
h=pathlib.Path(sys.argv[1]); p=h/'data/system-map/example/manifest.json'; m=json.load(open(p)); snap=json.load(open(h/'state/system-map/example/snapshot.json'))
for dep in m['access_dependencies']:
 if dep['id'].endswith('-b') and dep.get('observation'):
  facts=snap['observations'][dep['observation']]['facts']; dep['baseline']={'format':facts['format'],'complete':True,'sha256':facts['sha256'],'raw_sha256':facts['raw_sha256'],'source':'fixture exact read','observed_at':snap['finished_at']}
  if dep['kind'] in ('trust','role-existence'): dep['baseline']['relationships_sha256']=facts['relationships_sha256']
p.write_text(json.dumps(m))
PYTEST
  view_json "$home"
  assert_equals "declared-baselines-observed" "$(py "$home/view.json" 'next(i for i in d["access"]["interactions"] if i["id"]=="shared-managed-a")["static_coverage"]')" "second role policy check does not create a false gap for first role"
  assert_equals "declared-baselines-observed" "$(py "$home/view.json" 'next(i for i in d["access"]["interactions"] if i["id"]=="shared-managed-b")["static_coverage"]')" "first role policy check does not create a false gap for second role"
  assert_equals "[]" "$(py "$home/view.json" 'next(i for i in d["access"]["interactions"] if i["id"]=="shared-managed-a")["unlinked_dependencies"]')" "shared policy duplicate is not required by first interaction"
  assert_equals "[]" "$(py "$home/view.json" 'next(i for i in d["access"]["interactions"] if i["id"]=="shared-managed-b")["unlinked_dependencies"]')" "shared policy duplicate is not required by second interaction"
  python3 - "$home" <<'PYTEST'
import datetime,json,pathlib,sys
h=pathlib.Path(sys.argv[1]); v=json.load(open(h/'view.json')); ids=['access-role','access-role-b','access-bucket']; at=datetime.datetime.now(datetime.timezone.utc).isoformat(); interactions=[i for i in v['access']['interactions'] if i['id'] in ('shared-managed-a','shared-managed-b')]
r={'schema':'fm-system-map.evidence.v1','id':'shared-managed-request','subjects':ids,'versions':{s:v['subjects'][s]['version'] for s in ids},'resource_identities':{s:v['subjects'][s]['resource_identity'] for s in ids},'result':'pass','recorded_at':at,'observed_at':at,'scope':'fixture shared managed policy request','summary':'Current fixture requests','provenance':{'kind':'receipt','source':'fixture owner'},'access_requests':{i['id']:i['assertion_digest'] for i in interactions}}
(h/'shared-managed-request.json').write_text(json.dumps(r))
PYTEST
  map "$home" evidence add example "$home/shared-managed-request.json" >/dev/null || fail "shared policy request receipt intake"
  view_json "$home"
  assert_equals "demonstrated" "$(py "$home/view.json" 'next(i for i in d["access"]["interactions"] if i["id"]=="shared-managed-a")["request_proof"]')" "first role request is bound to its own check"
  assert_equals "demonstrated" "$(py "$home/view.json" 'next(i for i in d["access"]["interactions"] if i["id"]=="shared-managed-b")["request_proof"]')" "second role request is bound to its own check"
  python3 - "$home" <<'PYTEST'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1])/'data/system-map/example/manifest.json'; m=json.load(open(p)); next(i for i in m['interactions'] if i['id']=='shared-managed-b')['dependencies'].remove('managed-check-b'); p.write_text(json.dumps(m))
PYTEST
  view_json "$home"
  assert_equals "gaps" "$(py "$home/view.json" 'next(i for i in d["access"]["interactions"] if i["id"]=="shared-managed-b")["static_coverage"]')" "unlinked duplicate cannot cover missing second role check"
  assert_equals "1" "$(py "$home/view.json" 'len(next(i for i in d["access"]["interactions"] if i["id"]=="shared-managed-b")["uncovered_policy_identities"])')" "missing linked shared policy is identified"
  assert_equals "stale" "$(py "$home/view.json" 'next(i for i in d["access"]["interactions"] if i["id"]=="shared-managed-b")["request_proof"]')" "missing linked check invalidates second role proof"
  cp "$home/shared-policy-manifest.json" "$home/data/system-map/example/manifest.json"
  cp "$home/shared-policy-bindings.json" "$home/data/system-map/example/bindings.json"
  map "$home" collect >/dev/null || fail "restore shared policy fixture"
  cp "$home/data/system-map/example/manifest.json" "$home/compatible-manifest.json"
  cp "$home/data/system-map/example/bindings.json" "$home/compatible-bindings.json"
  cp "$home/aws-state.json" "$home/compatible-aws-state.json"
  python3 - "$home" <<'PYTEST'
import json,pathlib,sys
h=pathlib.Path(sys.argv[1]); p=h/'data/system-map/example/manifest.json'; m=json.load(open(p)); owners=[{'name':'fixture owner'}]; m['access_dependencies'].append({'id':'imds-check','title':'EC2 metadata configuration','kind':'configuration','subject':'worker-host','participant':'caller','observation':'worker-ec2','owners':owners,'next_check':'Read current instance metadata settings.'}); i=dict(m['interactions'][0],id='imds-request',title='EC2 caller to bucket',caller='worker-host'); i.pop('evidence',None); i['dependencies']=i['dependencies']+['imds-check']; m['interactions'].append(i); p.write_text(json.dumps(m)); p=h/'aws-state.json'; s=json.load(open(p)); s['responses']['describe-instances']={'Reservations':[{'Instances':[{'State':{'Name':'running'},'ImageId':'ami-0123456789abcdef0','MetadataOptions':{'HttpEndpoint':'enabled','HttpTokens':'required','HttpPutResponseHopLimit':1}}]}]}; p.write_text(json.dumps(s))
PYTEST
  map "$home" collect >/dev/null || fail "EC2 configuration collection"
  python3 - "$home" <<'PYTEST'
import json,pathlib,sys
h=pathlib.Path(sys.argv[1]); p=h/'data/system-map/example/manifest.json'; m=json.load(open(p)); snap=json.load(open(h/'state/system-map/example/snapshot.json')); f=snap['observations']['worker-ec2']['facts']; d=next(d for d in m['access_dependencies'] if d['id']=='imds-check'); d['baseline']={'format':'configuration','complete':True,'sha256':f['sha256'],'raw_sha256':f['raw_sha256'],'source':'fixture EC2 metadata read','observed_at':snap['finished_at']}; p.write_text(json.dumps(m))
PYTEST
  view_json "$home"
  assert_equals "matches-baseline" "$(py "$home/view.json" 'next(d for d in d["access"]["dependencies"] if d["id"]=="imds-check")["comparison"]')" "complete EC2 metadata settings match baseline"
  assert_equals "False" "$(py "$home/view.json" '"imds-check" in next(i for i in d["access"]["interactions"] if i["id"]=="imds-request")["unmatched_dependencies"]')" "EC2 configuration read covers its bound caller"
  cp "$home/compatible-manifest.json" "$home/data/system-map/example/manifest.json"
  cp "$home/compatible-bindings.json" "$home/data/system-map/example/bindings.json"
  cp "$home/compatible-aws-state.json" "$home/aws-state.json"
  map "$home" collect >/dev/null || fail "restore EC2 configuration fixture"
  python3 - "$home" <<'PYTEST'
import json,pathlib,sys
h=pathlib.Path(sys.argv[1]); p=h/'data/system-map/example/manifest.json'; m=json.load(open(p)); role=next(s for s in m['components'] if s['id']=='access-role'); role['observe'].append({'id':'same-role-inline-read','adapter':'aws.iam_inline_policy','binding':'same_role_inline','role':'info'}); d=dict(next(d for d in m['access_dependencies'] if d['id']=='inline-check'),id='same-role-inline-check',title='Same role inline policy',subject='access-role',observation='same-role-inline-read'); m['access_dependencies'].append(d); m['interactions'][0]['dependencies'].append('same-role-inline-check'); p.write_text(json.dumps(m)); p=h/'data/system-map/example/bindings.json'; b=json.load(open(p)); b['bindings']['same_role_inline']={'role_name':'fixture-target','policy_name':'fixture-inline'}; p.write_text(json.dumps(b))
PYTEST
  map "$home" collect >/dev/null || fail "same-role inline policy collection"
  python3 - "$home" <<'PYTEST'
import json,pathlib,sys
h=pathlib.Path(sys.argv[1]); p=h/'data/system-map/example/manifest.json'; m=json.load(open(p)); snap=json.load(open(h/'state/system-map/example/snapshot.json')); f=snap['observations']['same-role-inline-read']['facts']; d=next(d for d in m['access_dependencies'] if d['id']=='same-role-inline-check'); d['baseline']={'format':'policy','complete':True,'sha256':f['sha256'],'raw_sha256':f['raw_sha256'],'source':'fixture inline policy read','observed_at':snap['finished_at']}; p.write_text(json.dumps(m))
PYTEST
  view_json "$home"
  assert_equals "False" "$(py "$home/view.json" '"same-role-inline-check" in d["access"]["interactions"][0]["unmatched_dependencies"]')" "complete same-role inventory covers its inline policy"
  python3 - "$home" <<'PYTEST'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1])/'data/system-map/example/bindings.json'; b=json.load(open(p)); b['bindings']['same_role_inline']['role_name']='fixture-other'; p.write_text(json.dumps(b))
PYTEST
  map "$home" collect >/dev/null || fail "wrong-role inline policy collection"
  view_json "$home"
  assert_equals "matches-baseline" "$(py "$home/view.json" 'next(d for d in d["access"]["dependencies"] if d["id"]=="same-role-inline-check")["comparison"]')" "wrong-role document can still match its policy baseline"
  assert_equals "True" "$(py "$home/view.json" '"same-role-inline-check" in d["access"]["interactions"][0]["unmatched_dependencies"]')" "wrong-role inline policy cannot cover identity"
  cp "$home/compatible-manifest.json" "$home/data/system-map/example/manifest.json"
  cp "$home/compatible-bindings.json" "$home/data/system-map/example/bindings.json"
  map "$home" collect >/dev/null || fail "restore inline policy fixture"
  cp "$home/data/system-map/example/manifest.json" "$home/pass-role-manifest.json"
  python3 - "$home" <<'PYTEST'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1])/'data/system-map/example/manifest.json'; m=json.load(open(p)); role=next(d for d in m['access_dependencies'] if d['id']=='identity-role-check'); m['access_dependencies'].append(dict(role,id='wrong-pass-role',title='Trust read labeled PassRole',kind='pass-role')); m['access_dependencies'].append(dict(role,id='wrong-session-policy',title='Trust read labeled session policy',kind='session-policy')); i=next(i for i in m['interactions'] if i['id']=='explicit-pass-role-request'); i['dependencies']=[d for d in i['dependencies'] if d!='session-policy']+['wrong-pass-role','wrong-session-policy']; i['context_complete']=True; i['evidence']='wrong-pass-role-request'; p.write_text(json.dumps(m))
PYTEST
  view_json "$home"
  python3 - "$home" <<'PYTEST'
import datetime,json,pathlib,sys
h=pathlib.Path(sys.argv[1]); v=json.load(open(h/'view.json')); i=next(i for i in v['access']['interactions'] if i['id']=='explicit-pass-role-request'); ids=['access-role','access-bucket']; at=datetime.datetime.now(datetime.timezone.utc).isoformat(); r={'schema':'fm-system-map.evidence.v1','id':'wrong-pass-role-request','subjects':ids,'versions':{s:v['subjects'][s]['version'] for s in ids},'resource_identities':{s:v['subjects'][s]['resource_identity'] for s in ids},'result':'pass','recorded_at':at,'observed_at':at,'scope':'synthetic policy-kind mismatch request','summary':'Trust metadata cannot establish PassRole','provenance':{'kind':'receipt','source':'fixture owner'},'access_requests':{i['id']:i['assertion_digest']}}; (h/'wrong-pass-role-request.json').write_text(json.dumps(r))
PYTEST
  map "$home" evidence add example "$home/wrong-pass-role-request.json" >/dev/null || fail "wrong PassRole receipt intake"
  view_json "$home"
  assert_equals "True" "$(py "$home/view.json" '"pass-role" in next(i for i in d["access"]["interactions"] if i["id"]=="explicit-pass-role-request")["missing_kinds"]')" "trust metadata cannot satisfy PassRole coverage"
  assert_equals "True" "$(py "$home/view.json" '"session-policy" in next(i for i in d["access"]["interactions"] if i["id"]=="explicit-pass-role-request")["missing_kinds"]')" "trust metadata cannot satisfy session-policy coverage"
  assert_equals "gaps" "$(py "$home/view.json" 'next(i for i in d["access"]["interactions"] if i["id"]=="explicit-pass-role-request")["static_coverage"]')" "wrong policy kind cannot complete declared coverage"
  assert_equals "stale" "$(py "$home/view.json" 'next(i for i in d["access"]["interactions"] if i["id"]=="explicit-pass-role-request")["request_proof"]')" "matching receipt cannot prove wrong policy kind"
  cp "$home/pass-role-manifest.json" "$home/data/system-map/example/manifest.json"
  cp "$home/data/system-map/example/manifest.json" "$home/participant-manifest.json"
  cp "$home/data/system-map/example/bindings.json" "$home/participant-bindings.json"
  cp "$home/aws-state.json" "$home/trust-state.json"
  python3 - "$home" <<'PYTEST'
import json,pathlib,sys
h=pathlib.Path(sys.argv[1]); p=h/'data/system-map/example/manifest.json'; m=json.load(open(p)); m['components'].append({'id':'caller-only','title':'Separate caller','observe':[{'id':'caller-role-read','adapter':'aws.iam_role','binding':'caller_role','role':'version'}],'version_from':'caller-role-read'}); i=dict(m['interactions'][0],id='caller-version-request',title='Separate caller to bucket',caller='caller-only'); i.pop('evidence',None); m['interactions'].append(i); p.write_text(json.dumps(m)); p=h/'data/system-map/example/bindings.json'; b=json.load(open(p)); b['bindings']['caller_role']={'role_name':'fixture-caller'}; p.write_text(json.dumps(b))
PYTEST
  map "$home" collect >/dev/null || fail "separate caller collection"
  view_json "$home"
  assert_equals "declared-baselines-observed" "$(py "$home/view.json" 'next(i for i in d["access"]["interactions"] if i["id"]=="caller-version-request")["static_coverage"]')" "fresh separate caller qualifies declared coverage"
  python3 - "$home" <<'PYTEST'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1])/'state/system-map/example/snapshot.json'; s=json.load(open(p)); s['observations']['caller-role-read']['checked_at']='2020-01-01T00:00:00Z'; p.write_text(json.dumps(s))
PYTEST
  view_json "$home"
  assert_equals "['caller-only']" "$(py "$home/view.json" 'next(i for i in d["access"]["interactions"] if i["id"]=="caller-version-request")["participant_gaps"]')" "stale caller is the only unqualified participant"
  assert_equals "[]" "$(py "$home/view.json" 'next(i for i in d["access"]["interactions"] if i["id"]=="caller-version-request")["missing_dependencies"]')" "dependency baselines remain current"
  assert_equals "gaps" "$(py "$home/view.json" 'next(i for i in d["access"]["interactions"] if i["id"]=="caller-version-request")["static_coverage"]')" "stale caller invalidates declared coverage"
  cp "$home/participant-manifest.json" "$home/data/system-map/example/manifest.json"
  cp "$home/participant-bindings.json" "$home/data/system-map/example/bindings.json"
  map "$home" collect >/dev/null || fail "restore separate caller fixture"
  python3 - "$home" <<'PYTEST'
import json,pathlib,sys
h=pathlib.Path(sys.argv[1]); p=h/'data/system-map/example/manifest.json'; m=json.load(open(p)); source=next(s for s in m['components'] if s['id']=='trust-source'); source['observe'].insert(0,{'id':'other-source-read','adapter':'aws.iam_role_access','binding':'other_source_role','role':'info'}); p.write_text(json.dumps(m)); p=h/'data/system-map/example/bindings.json'; b=json.load(open(p)); b['bindings']['other_source_role']={'role_name':'fixture-other'}; p.write_text(json.dumps(b)); p=h/'aws-state.json'; s=json.load(open(p)); base=s['responses']['get-role']; a=json.loads(json.dumps(base)); a['Arn']='arn:aws:iam::123456789012:role/fixture-source'; other=json.loads(json.dumps(base)); other['Arn']='arn:aws:iam::123456789012:role/fixture-other'; s['role_responses']={'fixture-source':a,'fixture-other':other}; s['responses']['get-role']['AssumeRolePolicyDocument']['Statement'][0]['Principal']['AWS']=other['Arn']; p.write_text(json.dumps(s))
PYTEST
  map "$home" collect >/dev/null || fail "conflicting trust role collection"
  python3 - "$home" <<'PYTEST'
import json,pathlib,sys
h=pathlib.Path(sys.argv[1]); snap=json.load(open(h/'state/system-map/example/snapshot.json')); facts=snap['observations']['access-trust']['facts']; p=h/'data/system-map/example/manifest.json'; m=json.load(open(p)); dep=next(d for d in m['access_dependencies'] if d['id']=='trust-check'); dep['baseline'].update({k:facts[k] for k in ('format','complete','sha256','raw_sha256','relationships_sha256')}); p.write_text(json.dumps(m))
PYTEST
  view_json "$home"
  assert_equals "wrong-reference" "$(py "$home/view.json" 'next(d for d in d["access"]["dependencies"] if d["id"]=="trust-check")["reference_states"][0]["state"]')" "unrelated successful role read cannot satisfy trust reference"
  assert_equals "insufficient-evidence" "$(py "$home/view.json" 'next(d for d in d["access"]["dependencies"] if d["id"]=="trust-check")["comparison"]')" "matching trust baseline cannot hide wrong referenced resource"
  cp "$home/participant-manifest.json" "$home/data/system-map/example/manifest.json"
  cp "$home/participant-bindings.json" "$home/data/system-map/example/bindings.json"
  cp "$home/trust-state.json" "$home/aws-state.json"
  map "$home" collect >/dev/null || fail "restore trust references"
  python3 - "$home" <<'PYTEST'
import json,pathlib,sys
h=pathlib.Path(sys.argv[1]); p=h/'data/system-map/example/manifest.json'; m=json.load(open(p)); role=next(s for s in m['components'] if s['id']=='access-role'); role['observe'][0]['adapter']='aws.iam_role'; role['observe'].append({'id':'other-identity-role-read','adapter':'aws.iam_role_access','binding':'other_identity_role','role':'info'}); m['interactions'][0]['dependencies'].append('boundary-check'); p.write_text(json.dumps(m)); p=h/'data/system-map/example/bindings.json'; b=json.load(open(p)); b['bindings']['other_identity_role']={'role_name':'fixture-other'}; p.write_text(json.dumps(b)); p=h/'aws-state.json'; s=json.load(open(p)); s['responses']['get-role']['PermissionsBoundary']={'PermissionsBoundaryArn':'arn:aws:iam::123456789012:policy/fixture','PermissionsBoundaryType':'PermissionsBoundary'}; p.write_text(json.dumps(s))
PYTEST
  map "$home" collect >/dev/null || fail "wrong identity role inventory collection"
  view_json "$home"
  assert_equals "matches-baseline" "$(py "$home/view.json" 'next(d for d in d["access"]["dependencies"] if d["id"]=="managed-check")["comparison"]')" "readable policy document remains observed"
  assert_equals "True" "$(py "$home/view.json" '"identity-policy" in d["access"]["interactions"][0]["missing_kinds"]')" "policy inventory from another role cannot cover identity"
  assert_equals "True" "$(py "$home/view.json" '"boundary-check" in d["access"]["interactions"][0]["unmatched_dependencies"]')" "boundary from another role cannot cover identity"
  cp "$home/participant-manifest.json" "$home/data/system-map/example/manifest.json"
  cp "$home/participant-bindings.json" "$home/data/system-map/example/bindings.json"
  cp "$home/trust-state.json" "$home/aws-state.json"
  map "$home" collect >/dev/null || fail "restore identity role inventory"
  python3 - "$home" <<'PYTEST'
import json,sys,pathlib
h=pathlib.Path(sys.argv[1]); p=h/'data/system-map/example/manifest.json'; m=json.load(open(p)); bucket=next(s for s in m['components'] if s['id']=='access-bucket'); bucket['observe'].append({'id':'other-bucket-read','adapter':'aws.s3_policy','binding':'other_bucket','role':'info'}); check=next(d for d in m['access_dependencies'] if d['id']=='bucket-check'); m['access_dependencies'].append(dict(check,id='other-bucket-check',title='Other bucket policy',observation='other-bucket-read')); i=dict(m['interactions'][0],id='wrong-bound-resource',title='Wrong bound bucket policy',evidence='wrong-bound-request'); i['dependencies']=['other-bucket-check' if d=='bucket-check' else d for d in i['dependencies']]; m['interactions'].append(i); p.write_text(json.dumps(m)); p=h/'data/system-map/example/bindings.json'; b=json.load(open(p)); b['bindings']['other_bucket']={'bucket':'other-fixture'}; p.write_text(json.dumps(b))
PYTEST
  map "$home" collect >/dev/null || fail "wrong bound resource collection"
  view_json "$home"
  assert_equals "True" "$(py "$home/view.json" '"resource-policy" in next(i for i in d["access"]["interactions"] if i["id"]=="wrong-bound-resource")["missing_kinds"]')" "same subject with a different bound resource cannot satisfy policy coverage"
  assert_equals "gaps" "$(py "$home/view.json" 'next(i for i in d["access"]["interactions"] if i["id"]=="wrong-bound-resource")["static_coverage"]')" "wrong bound resource cannot report complete coverage"
  cp "$home/participant-manifest.json" "$home/data/system-map/example/manifest.json"
  cp "$home/participant-bindings.json" "$home/data/system-map/example/bindings.json"
  map "$home" collect >/dev/null || fail "restore participant bindings"
  python3 - "$home" <<'PYTEST'
import json,sys,pathlib
p=pathlib.Path(sys.argv[1])/'data/system-map/example/manifest.json'; m=json.load(open(p)); role=next(d for d in m['access_dependencies'] if d['id']=='role-check'); m['access_dependencies'].append(dict(role,id='wrong-trust-check',title='Other role trust',kind='trust'))
i=dict(m['interactions'][0],id='wrong-subject-request',title='Unrelated checks for bucket request',evidence='wrong-request'); i['dependencies']=[d for d in i['dependencies'] if d not in ('identity-role-check','trust-check','bucket-check','bucket-key-na')]+['role-check','wrong-trust-check','queue-check','key-check']; m['interactions'].append(i); p.write_text(json.dumps(m))
PYTEST
  view_json "$home"
  assert_equals "['key-policy', 'resource-policy', 'role-existence', 'trust']" "$(py "$home/view.json" 'next(i for i in d["access"]["interactions"] if i["id"]=="wrong-subject-request")["missing_kinds"]')" "checks for another role and resource do not satisfy participant coverage"
  assert_equals "gaps" "$(py "$home/view.json" 'next(i for i in d["access"]["interactions"] if i["id"]=="wrong-subject-request")["static_coverage"]')" "wrong-subject checks cannot report complete coverage"
  python3 - "$home" <<'PYTEST'
import datetime,json,sys,pathlib
h=pathlib.Path(sys.argv[1]); v=json.load(open(h/'view.json')); i=next(i for i in v['access']['interactions'] if i['id']=='wrong-subject-request'); ids=['access-role','access-bucket']; at=datetime.datetime.now(datetime.timezone.utc).isoformat(); r={'schema':'fm-system-map.evidence.v1','id':'wrong-request','subjects':ids,'versions':{s:v['subjects'][s]['version'] for s in ids},'resource_identities':{s:v['subjects'][s]['resource_identity'] for s in ids},'result':'pass','recorded_at':at,'observed_at':at,'scope':'synthetic wrong-subject request','summary':'Wrong-subject regression receipt','provenance':{'kind':'receipt','source':'fixture owner'},'access_requests':{i['id']:i['assertion_digest']}}; (h/'wrong-request.json').write_text(json.dumps(r))
PYTEST
  map "$home" evidence add example "$home/wrong-request.json" >/dev/null || fail "wrong-subject receipt intake"
  view_json "$home"
  assert_equals "stale" "$(py "$home/view.json" 'next(i for i in d["access"]["interactions"] if i["id"]=="wrong-subject-request")["request_proof"]')" "matching receipt cannot prove unrelated checks"
  cp "$home/participant-manifest.json" "$home/data/system-map/example/manifest.json"
  python3 - "$home" <<'PYTEST'
import json,sys,pathlib
p=pathlib.Path(sys.argv[1])/'data/system-map/example/manifest.json'; m=json.load(open(p)); next(d for d in m['access_dependencies'] if d['id']=='organization-policy').pop('participant'); p.write_text(json.dumps(m))
PYTEST
  view_json "$home"
  assert_equals "['organization-policy']" "$(py "$home/view.json" 'd["access"]["interactions"][0]["missing_kinds"]')" "shared caller and identity do not imply an ambiguous restriction mapping"
  assert_equals "stale" "$(py "$home/view.json" 'd["access"]["interactions"][0]["request_proof"]')" "unknown participant mapping cannot qualify request proof"
  cp "$home/participant-manifest.json" "$home/data/system-map/example/manifest.json"
  view_json "$home"
  assert_equals "demonstrated" "$(py "$home/view.json" 'd["access"]["interactions"][0]["request_proof"]')" "restored participant mapping requalifies request proof"
  python3 - "$home" <<'PYTEST'
import json,sys,pathlib
p=pathlib.Path(sys.argv[1])/'data/system-map/example/manifest.json'; m=json.load(open(p)); role=next(s for s in m['components'] if s['id']=='access-role'); role['observe'].append({'id':'access-trust-alternate','adapter':'aws.iam_role_access','binding':'access_role','role':'info'}); p.write_text(json.dumps(m))
PYTEST
  map "$home" collect >/dev/null || fail "ambiguous identity role collection"
  view_json "$home"
  assert_equals "True" "$(py "$home/view.json" '"identity-policy" in d["access"]["interactions"][0]["missing_kinds"]')" "two healthy role reads do not pick an arbitrary policy membership source"
  assert_equals "stale" "$(py "$home/view.json" 'd["access"]["interactions"][0]["request_proof"]')" "ambiguous role mapping cannot qualify request proof"
  cp "$home/participant-manifest.json" "$home/data/system-map/example/manifest.json"
  map "$home" collect >/dev/null || fail "restore single identity role read"
  cp "$home/data/system-map/example/manifest.json" "$home/closure-manifest.json"
  python3 - "$home" <<'PYTEST'
import json,sys,pathlib
p=pathlib.Path(sys.argv[1])/'data/system-map/example/manifest.json'; m=json.load(open(p)); m['interactions'][0]['dependencies'].remove('managed-check'); m['interactions'][1]['dependencies'].remove('key-check'); p.write_text(json.dumps(m))
PYTEST
  view_json "$home"
  assert_equals "['managed-check']" "$(py "$home/view.json" 'd["access"]["interactions"][0]["unlinked_dependencies"]')" "role policy check remains required when omitted"
  assert_equals "['key-check']" "$(py "$home/view.json" 'd["access"]["interactions"][1]["unlinked_dependencies"]')" "queue key check remains required when omitted"
  assert_equals "gaps" "$(py "$home/view.json" 'd["access"]["interactions"][0]["static_coverage"]')" "globally observed checks do not fill missing interaction links"
  assert_equals "stale" "$(py "$home/view.json" 'd["access"]["interactions"][0]["request_proof"]')" "omitted checks invalidate old request proof"
  before=$(py "$home/view.json" 'd["access"]["interactions"][1]["assertion_digest"]')
  python3 - "$home" <<'PYTEST'
import json,sys,pathlib
p=pathlib.Path(sys.argv[1])/'aws-state.json'; s=json.load(open(p)); policy=json.loads(s['responses']['get-key-policy']['Policy']); policy['Statement'][0]['Condition']['Bool']['aws:SecureTransport']='true'; s['responses']['get-key-policy']['Policy']=json.dumps(policy); p.write_text(json.dumps(s))
PYTEST
  map "$home" collect >/dev/null || fail "changed omitted key policy"
  python3 - "$home" <<'PYTEST'
import json,sys,pathlib
h=pathlib.Path(sys.argv[1]); p=h/'data/system-map/example/manifest.json'; m=json.load(open(p)); facts=json.load(open(h/'state/system-map/example/snapshot.json'))['observations']['access-key-read']['facts']; d=next(d for d in m['access_dependencies'] if d['id']=='key-check'); d['baseline'].update(sha256=facts['sha256'],raw_sha256=facts['raw_sha256']); p.write_text(json.dumps(m))
PYTEST
  view_json "$home"
  assert_equals "matches-baseline" "$(py "$home/view.json" 'next(d for d in d["access"]["dependencies"] if d["id"]=="queue-check")["comparison"]')" "queue check remains green after key baseline review"
  after=$(py "$home/view.json" 'd["access"]["interactions"][1]["assertion_digest"]')
  assert_not_equals "$before" "$after" "omitted key-policy version enters request assertion"
  before=$(py "$home/view.json" 'd["access"]["interactions"][0]["assertion_digest"]')
  python3 - "$home" <<'PYTEST'
import json,sys,pathlib
p=pathlib.Path(sys.argv[1])/'aws-state.json'; s=json.load(open(p)); s['responses']['get-policy-version']['PolicyDocument']['Statement'][0]['Condition']['Bool']['aws:SecureTransport']='true'; p.write_text(json.dumps(s))
PYTEST
  map "$home" collect >/dev/null || fail "changed omitted role policy"
  python3 - "$home" <<'PYTEST'
import json,sys,pathlib
h=pathlib.Path(sys.argv[1]); p=h/'data/system-map/example/manifest.json'; m=json.load(open(p)); facts=json.load(open(h/'state/system-map/example/snapshot.json'))['observations']['access-managed-read']['facts'];
for d in m['access_dependencies']:
 if d['id'] in ('managed-check','boundary-check'): d['baseline'].update(sha256=facts['sha256'],raw_sha256=facts['raw_sha256'])
p.write_text(json.dumps(m))
PYTEST
  view_json "$home"
  assert_equals "matches-baseline" "$(py "$home/view.json" 'next(d for d in d["access"]["dependencies"] if d["id"]=="trust-check")["comparison"]')" "role inventory remains green after policy document review"
  after=$(py "$home/view.json" 'd["access"]["interactions"][0]["assertion_digest"]')
  assert_not_equals "$before" "$after" "omitted attached-policy version enters request assertion"
  python3 - "$home" <<'PYTEST'
import json,sys,pathlib
h=pathlib.Path(sys.argv[1]); p=h/'aws-state.json'; s=json.load(open(p)); s['deny']=['kms']; p.write_text(json.dumps(s))
PYTEST
  map "$home" collect >/dev/null || fail "denied required key policy"
  view_json "$home"
  assert_equals "denied" "$(py "$home/view.json" 'next(d for d in d["access"]["dependencies"] if d["id"]=="key-check")["state"]')" "denied transitive key check remains denied"
  assert_equals "gaps" "$(py "$home/view.json" 'd["access"]["interactions"][1]["static_coverage"]')" "denied transitive key check cannot complete coverage"
  assert_equals "unknown" "$(py "$home/view.json" 'd["access"]["interactions"][1]["effective_access"]')" "denied transitive coverage never becomes effective access"
  cp "$home/closure-manifest.json" "$home/data/system-map/example/manifest.json"
  cp "$home/access-original.json" "$home/aws-state.json"
  map "$home" collect >/dev/null || fail "restore interaction closure fixture"
  view_json "$home"
  assert_equals "demonstrated" "$(py "$home/view.json" 'd["access"]["interactions"][0]["request_proof"]')" "restored links and versions requalify the original receipt"
  python3 - "$home" <<'PYTEST'
import json,sys,pathlib
p=pathlib.Path(sys.argv[1])/'aws-state.json'; s=json.load(open(p)); s['responses']['list-attached-role-policies']['AttachedPolicies']=[]; p.write_text(json.dumps(s))
PYTEST
  map "$home" collect >/dev/null || fail "removed role policy attachment"
  view_json "$home"
  assert_equals "configuration-drift" "$(py "$home/view.json" 'next(d for d in d["access"]["dependencies"] if d["id"]=="trust-check")["comparison"]')" "removed role attachment drifts despite unchanged trust"
  assert_equals "matches-baseline" "$(py "$home/view.json" 'next(d for d in d["access"]["dependencies"] if d["id"]=="managed-check")["comparison"]')" "readable detached policy does not cover role membership"
  assert_equals "gaps" "$(py "$home/view.json" 'd["access"]["interactions"][0]["static_coverage"]')" "removed role attachment invalidates declared coverage"
  assert_equals "stale" "$(py "$home/view.json" 'd["access"]["interactions"][0]["request_proof"]')" "removed role attachment invalidates request proof"
  python3 - "$home" <<'PYTEST'
import json,sys,pathlib
h=pathlib.Path(sys.argv[1]); p=h/'aws-state.json'; s=json.load(open(h/'access-original.json')); s['responses']['get-role']['PermissionsBoundary']={'PermissionsBoundaryArn':'arn:aws:iam::123456789012:policy/fixture','PermissionsBoundaryType':'PermissionsBoundary'}; p.write_text(json.dumps(s))
PYTEST
  map "$home" collect >/dev/null || fail "changed role boundary"
  view_json "$home"
  assert_equals "configuration-drift" "$(py "$home/view.json" 'next(d for d in d["access"]["dependencies"] if d["id"]=="trust-check")["comparison"]')" "changed boundary drifts despite readable replacement document"
  assert_equals "0" "$(py "$home/view.json" 'len(next(d for d in d["access"]["dependencies"] if d["id"]=="trust-check")["unobserved_policy_documents"])')" "readable boundary document cannot hide relationship drift"
  python3 - "$home" <<'PYTEST'
import json,sys,pathlib
h=pathlib.Path(sys.argv[1]); p=h/'aws-state.json'; s=json.load(open(h/'access-original.json')); s['responses']['list-attached-role-policies']['IsTruncated']=True; p.write_text(json.dumps(s))
PYTEST
  map "$home" collect >/dev/null || fail "incomplete role inventory"
  view_json "$home"
  assert_equals "insufficient-evidence" "$(py "$home/view.json" 'next(d for d in d["access"]["dependencies"] if d["id"]=="trust-check")["comparison"]')" "incomplete attachment inventory cannot match relationship baseline"
  python3 - "$home" <<'PYTEST'
import json,sys,pathlib
h=pathlib.Path(sys.argv[1]); (h/'aws-state.json').write_text((h/'access-original.json').read_text())
PYTEST
  map "$home" collect >/dev/null || fail "restore role relationships"
  python3 - "$home" <<'PYTEST'
import json,sys,pathlib
p=pathlib.Path(sys.argv[1])/'aws-state.json'; s=json.load(open(p)); s['responses']['get-queue-attributes']['Attributes']['KmsMasterKeyId']='replacement-key'; p.write_text(json.dumps(s))
PYTEST
  map "$home" collect >/dev/null || fail "changed queue encryption key"
  view_json "$home"
  assert_equals "configuration-drift" "$(py "$home/view.json" 'next(d for d in d["access"]["dependencies"] if d["id"]=="queue-check")["comparison"]')" "changed key with unchanged queue policy drifts"
  assert_equals "matches-baseline" "$(py "$home/view.json" 'next(d for d in d["access"]["dependencies"] if d["id"]=="key-check")["comparison"]')" "old key policy read alone cannot cover the queue"
  assert_equals "stale" "$(py "$home/view.json" 'd["access"]["interactions"][1]["request_proof"]')" "changed queue key invalidates request proof"
  assert_equals "demonstrated" "$(py "$home/view.json" 'd["access"]["interactions"][0]["request_proof"]')" "queue key change leaves bucket request proof intact"
  python3 - "$home" <<'PYTEST'
import json,sys,pathlib
h=pathlib.Path(sys.argv[1]); p=h/'data/system-map/example/manifest.json'; m=json.load(open(p)); v=json.load(open(h/'view.json')); d=next(d for d in m['access_dependencies'] if d['id']=='queue-check'); observed=next(d for d in v['access']['dependencies'] if d['id']=='queue-check'); d['baseline']['encryption_identity']=observed['facts']['encryption_identity']; p.write_text(json.dumps(m))
PYTEST
  view_json "$home"
  assert_equals "insufficient-evidence" "$(py "$home/view.json" 'next(d for d in d["access"]["dependencies"] if d["id"]=="queue-check")["comparison"]')" "updated queue baseline cannot keep old key-policy relationship green"
  python3 - "$home" <<'PYTEST'
import hashlib,json,sys,pathlib
h=pathlib.Path(sys.argv[1]); (h/'aws-state.json').write_text((h/'access-original.json').read_text()); p=h/'data/system-map/example/manifest.json'; m=json.load(open(p)); d=next(d for d in m['access_dependencies'] if d['id']=='queue-check'); d['baseline']['encryption_identity']=hashlib.sha256(json.dumps({'KmsMasterKeyId':'fixture-key','SqsManagedSseEnabled':None},sort_keys=True,separators=(',',':')).encode()).hexdigest(); p.write_text(json.dumps(m))
PYTEST
  map "$home" collect >/dev/null || fail "restore queue key"
  python3 - "$home" <<'PYTEST'
import json,sys,pathlib,datetime
h=pathlib.Path(sys.argv[1]);p=h/'data/system-map/example/manifest.json';m=json.load(open(p));d=next(d for d in m['access_dependencies'] if d['id']=='endpoint-policy');d.pop('applicability');d.pop('reason');d['evidence']='fixture-owner-check';d['baseline']={'format':'configuration','complete':True,'sha256':'0'*64,'raw_sha256':'0'*64,'source':'fixture owner endpoint policy hash','observed_at':datetime.datetime.now(datetime.timezone.utc).isoformat()};p.write_text(json.dumps(m))
v=json.load(open(h/'view.json'));subject=v['subjects']['access-role'];at=datetime.datetime.now(datetime.timezone.utc).isoformat()
r={'schema':'fm-system-map.evidence.v1','id':'fixture-owner-check','subjects':['access-role'],'versions':{'access-role':subject['version']},'resource_identities':{'access-role':subject['resource_identity']},'result':'pass','recorded_at':at,'observed_at':at,'scope':'fixture existing owner endpoint policy read; no native call','summary':'Fixture owner supplies current bounded policy metadata','provenance':{'kind':'receipt','source':'fixture owner'},'access_checks':{'endpoint-policy':{'outcome':'ok','binding_digest':subject['resource_identity'],'observer_identity':'1'*64,'version':'endpoint-v1','facts':{'format':'configuration','complete':True,'sha256':'0'*64,'raw_sha256':'0'*64}}}}
(h/'owner-check.json').write_text(json.dumps(r))
PYTEST
  map "$home" evidence add example "$home/owner-check.json" >/dev/null || fail "owner check intake"
  view_json "$home"
  assert_equals "imported" "$(py "$home/view.json" 'next(d for d in d["access"]["dependencies"] if d["id"]=="endpoint-policy")["coverage"]')" "qualified owner check is labeled imported"
  assert_equals "matches-baseline" "$(py "$home/view.json" 'next(d for d in d["access"]["dependencies"] if d["id"]=="endpoint-policy")["comparison"]')" "owner check preserves exact baseline digest"
  cp "$home/data/system-map/example/manifest.json" "$home/imported-format-manifest.json"
  python3 - "$home" <<'PYTEST'
import json,pathlib,sys
h=pathlib.Path(sys.argv[1]); p=h/'data/system-map/example/manifest.json'; m=json.load(open(p)); d=dict(next(d for d in m['access_dependencies'] if d['id']=='endpoint-policy'),id='wrong-format-trust',title='Configuration mislabeled as trust',kind='trust',evidence='fixture-wrong-format'); m['access_dependencies'].append(d); m['interactions'][0]['dependencies'].append('wrong-format-trust'); p.write_text(json.dumps(m)); r=json.load(open(h/'owner-check.json')); r['id']='fixture-wrong-format'; r['access_checks']={'wrong-format-trust':r['access_checks']['endpoint-policy']}; (h/'wrong-format-check.json').write_text(json.dumps(r))
PYTEST
  map "$home" evidence add example "$home/wrong-format-check.json" >/dev/null || fail "wrong-format owner check intake"
  view_json "$home"
  assert_equals "imported" "$(py "$home/view.json" 'next(d for d in d["access"]["dependencies"] if d["id"]=="wrong-format-trust")["coverage"]')" "wrong-format owner receipt remains visible"
  assert_equals "matches-baseline" "$(py "$home/view.json" 'next(d for d in d["access"]["dependencies"] if d["id"]=="wrong-format-trust")["comparison"]')" "wrong-format receipt matches its own declared baseline"
  assert_equals "True" "$(py "$home/view.json" '"wrong-format-trust" in d["access"]["interactions"][0]["unmatched_dependencies"]')" "configuration receipt cannot satisfy trust coverage"
  cp "$home/imported-format-manifest.json" "$home/data/system-map/example/manifest.json"
  python3 - "$home" <<'PYTEST'
import json,sys,pathlib
h=pathlib.Path(sys.argv[1]);p=h/'owner-check.json';r=json.load(open(p));r['id']='fixture-wrong-binding';r['access_checks']['endpoint-policy']['binding_digest']='2'*64;p.write_text(json.dumps(r));p=h/'data/system-map/example/manifest.json';m=json.load(open(p));next(d for d in m['access_dependencies'] if d['id']=='endpoint-policy')['evidence']='fixture-wrong-binding';p.write_text(json.dumps(m))
PYTEST
  map "$home" evidence add example "$home/owner-check.json" >/dev/null || fail "unqualified check is retained"
  view_json "$home"
  assert_equals "missing-evidence" "$(py "$home/view.json" 'next(d for d in d["access"]["dependencies"] if d["id"]=="endpoint-policy")["coverage"]')" "owner check with wrong binding remains unqualified"
  python3 - "$home" <<'PYTEST'
import json,sys,pathlib
h=pathlib.Path(sys.argv[1]); p=h/'state/system-map/example/snapshot.json'; s=json.load(open(p)); s['observations']['access-trust']['checked_at']='2020-01-01T00:00:00Z'; p.write_text(json.dumps(s))
PYTEST
  view_json "$home"
  assert_equals "stale" "$(py "$home/view.json" 'd["access"]["interactions"][0]["request_proof"]')" "stale dependency invalidates request proof"
  python3 - "$home" <<'PYTEST'
import json,sys,pathlib
h=pathlib.Path(sys.argv[1]); p=h/'data/system-map/example/bindings.json'; b=json.load(open(p)); b['bindings']['access_bucket']['bucket']='other-fixture'; p.write_text(json.dumps(b))
PYTEST
  view_json "$home"
  assert_equals "stale" "$(py "$home/view.json" 'd["access"]["interactions"][0]["request_proof"]')" "changed binding invalidates request proof"
  python3 - "$home" <<'PYTEST'
import json,sys,pathlib
h=pathlib.Path(sys.argv[1]); p=h/'request.json'; r=json.load(open(p));r['id']='unknown-request';r['access_requests']={'missing-interaction':'0'*64};p.write_text(json.dumps(r))
PYTEST
  map "$home" evidence add example "$home/request.json" >"$home/rejected.txt" 2>&1 && fail "unknown interaction receipt accepted"
  assert_grep 'unknown interaction' "$home/rejected.txt" "request receipt reference validation"
  python3 - "$home" <<'PYTEST'
import json,sys,pathlib
h=pathlib.Path(sys.argv[1]); p=h/'data/system-map/example/bindings.json'; b=json.load(open(p)); b['bindings']['access_bucket']['bucket']='fixture';p.write_text(json.dumps(b));p=h/'aws-state.json';s=json.load(open(p));s['responses']['get-role']['AssumeRolePolicyDocument']['Statement'][0]['Effect']='Deny';p.write_text(json.dumps(s))
PYTEST
  map "$home" collect >/dev/null || fail "changed trust check"
  view_json "$home"
  assert_equals "policy-drift" "$(py "$home/view.json" 'next(d for d in d["access"]["dependencies"] if d["id"]=="trust-check")["comparison"]')" "changed trust denial is semantic drift"
  assert_equals "denied-reference" "$(py "$home/view.json" 'next(d for d in d["access"]["dependencies"] if d["id"]=="trust-check")["reference_states"][0]["state"]')" "a principal present only in Deny is not an observed Allow reference"
  assert_equals "unknown" "$(py "$home/view.json" 'd["access"]["interactions"][0]["effective_access"]')" "denied-only reference does not claim effective access"
  assert_equals "unobserved" "$(py "$home/view.json" 'd["access"]["interactions"][0]["propagation"]')" "matching GetRole never proves downstream propagation"
  pass "access view batches gaps, classifies policy/tag drift, and qualifies exact trust dependencies"
}

test_presentation_preserves_evidence_distinctions() {
  local home ledger_before requests_before
  home=$(new_home presentation)
  python3 - "$home/data/system-map/example/manifest.json" "$home/data/system-map/example/bindings.json" <<'PYFIXTURE'
import datetime, json, sys
p, b = sys.argv[1:]; m = json.load(open(p)); bindings = json.load(open(b))
owner = [{"name": "Example owner", "task": "example-owner"}]
queue = next(c for c in m["components"] if c["id"] == "queue")
queue["x-presentation"] = {"runtime": {"group": "Retained abandoned job", "detail": "A specifically abandoned job remains unclosed; queue message retained by decision.", "next_action": "Owner must decide disposition; no automatic acknowledgment."}}
m["known_gaps"] = [
 {"id": "required-consumption", "title": "Required queue consumption is not implemented", "subjects": ["queue"], "severity": "medium", "owners": owner, "x-presentation": {"category": "implementation", "expected": "Consumer processes admitted jobs", "impact": "Required jobs cannot progress", "next_action": "Implement consumer then prove runtime consumption"}},
 {"id": "retained-job", "title": "Abandoned job remains unclosed", "subjects": ["queue"], "severity": "medium", "x-presentation": {"category": "operational", "group": "Retained abandoned job"}},
 {"id": "publisher-grant", "title": "Generated publisher lacks scheduler:GetSchedule", "subjects": ["api"], "severity": "medium", "detail": "Source review only; applied permissions and actual request remain unverified.", "owners": owner, "x-presentation": {"category": "implementation", "expected": "Publisher can inspect its schedule", "impact": "Schedule reconciliation lacks the required grant", "next_action": "Repair generated policy; separately deploy and collect authorized request evidence"}},
 {"id": "role-context", "title": "Exact operation and context unknown", "subjects": ["api"], "severity": "high", "x-presentation": {"category": "access"}},
 {"id": "cleanup", "title": "Cleanup obligations need current census", "subjects": ["api"], "severity": "medium", "x-presentation": {"category": "verification", "urgent": True}},
 {"id": "renewal", "title": "Certificate renewal automation missing", "subjects": ["api"], "severity": "medium", "x-presentation": {"category": "implementation"}},
 {"id": "unclassified", "title": "Unknown source requirement", "subjects": ["api"], "severity": "medium"}]
expires = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=2)).isoformat()
m["credentials"] = [{"id": "cert-%d" % i, "title": "Example leaf %d" % i, "purpose": "Synthetic transport", "owner": "Example renewal owner", "subjects": ["api"], "expires": expires, "not_before": "2026-01-01T00:00:00Z", "rotation": "Owner rotation", "note": "Issuer validity is unknown"} for i in range(6)]
m["components"] += [{"id": "example-role", "title": "Neutral name", "observe": [{"id": "role-observation", "adapter": "aws.iam_role", "binding": "role-binding"}], "owners": owner}, {"id": "shared-policy", "title": "Shared policy", "x-presentation": {"section": "access"}, "owners": owner}]
m["connections"].append({"id": "api-role", "title": "API assumes example role", "from": "api", "to": "example-role", "owners": owner})
bindings["bindings"]["role-binding"] = {"role_name": "synthetic-role"}
json.dump(m, open(p, "w")); json.dump(bindings, open(b, "w"))
PYFIXTURE
  aws_state "$home" '{"queue_visible": 1, "deny": ["ecs"], "missing": ["dynamodb"]}'
  map "$home" collect >/dev/null || fail "presentation collection failed"
  ledger_before=$(cksum < "$home/data/system-map/example/discrepancies.json")
  requests_before=$(cksum < "$home/state/system-map/example/requests.json")
  view_json "$home"
  assert_equals "$ledger_before" "$(cksum < "$home/data/system-map/example/discrepancies.json")" "presentation does not resolve or rewrite ledger obligations"
  assert_equals "$requests_before" "$(cksum < "$home/state/system-map/example/requests.json")" "presentation never acknowledges requests"
  python3 - "$home/view.json" <<'PYCHECK' || fail "presentation distinctions failed"
import json, sys
v = json.load(open(sys.argv[1])); p = v["presentation"]; ds = p["differences"]
assert len(ds) == len(v["discrepancies"])
assert {d["id"] for d in ds} == {d["id"] for d in v["discrepancies"]}
assert "example-role" in p["access_subjects"] and "shared-policy" in p["access_subjects"]
assert "api-role" in p["access_connections"] and "api-role" not in p["connections"]
assert v["subjects"]["api-role"]["from"] == "api" and v["subjects"]["api-role"]["to"] == "example-role"
assert "queue" in p["components"] and "api" in p["components"]
assert len(p["access_subjects"]) == len(set(p["access_subjects"]))
runtime = next(d for d in ds if d["kind"] == "runtime" and d["subject"] == "queue")
assert runtime["category"] == "operational" and not runtime["urgent"] and not runtime["in_overview"]
assert "abandoned" in runtime["disposition"]
assert runtime["group"] == next(d for d in ds if d["title"] == "Abandoned job remains unclosed")["group"]
required = next(d for d in ds if d["title"] == "Required queue consumption is not implemented")
assert required["category"] == "implementation" and required["expected"] and required["impact"] and required["next_action"]
assert next(d for d in ds if "GetSchedule" in d["title"])["category"] == "implementation"
assert next(d for d in ds if "renewal automation" in d["title"])["category"] == "implementation"
expiry = [d for d in ds if d["kind"] == "credential"]
assert len(expiry) == 6 and {d["category"] for d in expiry} == {"maintenance"}
assert len({d["group"] for d in expiry}) == 1 and all(d["owners"] for d in expiry)
assert all(d["category"] == "verification" for d in ds if d["kind"] == "observation")
assert v["subjects"]["api"]["observations"][0]["current"]["outcome"] == "denied"
assert v["subjects"]["results"]["observations"][0]["current"]["outcome"] == "absent"
assert next(d for d in ds if d["title"] == "Exact operation and context unknown")["urgent"] is False
assert next(d for d in ds if d["title"] == "Cleanup obligations need current census")["urgent"] is True
assert next(d for d in ds if d["title"] == "Unknown source requirement")["category"] == "review"
assert next(d for d in ds if d["title"] == "Unknown source requirement")["in_overview"]
assert v["subjects"]["api"]["layers"]["proof"]["status"] == "not-demonstrated"
assert not any(a["status"] == "passed" for a in v["acceptance"])
print("presentation categories retain distinct evidence and urgent obligations")
PYCHECK
  # A normal nonempty queue alone does not create the explicit implementation gap.
  python3 - "$home/data/system-map/example/manifest.json" <<'PYFIXTURE'
import json, sys
p = sys.argv[1]; m = json.load(open(p)); m["known_gaps"] = []; json.dump(m, open(p, "w"))
PYFIXTURE
  map "$home" collect >/dev/null || fail "normal queue collection failed"
  view_json "$home"
  assert_equals "0" "$(py "$home/view.json" 'sum(d["category"] == "implementation" and d["subject"] == "queue" and d["status"] == "open" for d in d["presentation"]["differences"])')" "nonempty queue does not imply missing consumption implementation"
  assert_equals "0" "$(py "$home/view.json" 'sum(d["in_overview"] for d in d["presentation"]["differences"] if d["kind"] == "runtime" and d["subject"] == "queue")')" "routine queue deviation stays outside overview"
  python3 - "$home/data/system-map/example/manifest.json" <<'PYFIXTURE'
import json, sys
p = sys.argv[1]; m = json.load(open(p)); m["components"][0]["x-presentation"] = {"section": "arbitrary"}; json.dump(m, open(p, "w"))
PYFIXTURE
  map "$home" validate >"$home/invalid-presentation.txt" 2>&1 && fail "invalid presentation section accepted"
  assert_grep 'section: component or access' "$home/invalid-presentation.txt" "presentation hints are validated"
  python3 - "$home/data/system-map/example/manifest.json" <<'PYFIXTURE'
import json, sys
p = sys.argv[1]; m = json.load(open(p)); m["components"][0]["x-presentation"] = {"runtime": {"category": "implementation"}}; json.dump(m, open(p, "w"))
PYFIXTURE
  map "$home" validate >"$home/invalid-runtime-category.txt" 2>&1 && fail "ignored runtime category accepted"
  assert_grep "runtime: unknown field 'category'" "$home/invalid-runtime-category.txt" "runtime classification setting is rejected"
  pass "presentation groups expiry and separates implementation, operations, coverage and verification"
}

test_presentation_preserves_evidence_distinctions

test_access_relationships_and_conservative_comparison

test_proactive_prerequisites_and_lineage
test_lineage_report_requires_current_binding
test_prerequisite_receipt_requires_current_version
test_sample_lifecycle_coverage
test_credential_full_window
test_inferred_expiry_does_not_alert
test_legacy_expiry_basis_retains_observed_dates
test_historical_imported_assessment
test_delegated_active_to_idle

test_no_map_home_is_inert
test_collect_retains_last_success_on_partial_denial
test_scope_mismatch_skips_aws_reads
test_absent_response_matches_absent_intent
test_failed_collection_preserves_success_time
test_intent_revision_invalidates_observations
test_binding_change_invalidates_observations_and_history
test_resource_identity_qualifies_proof
test_removed_bound_subject_is_unverified
test_missing_and_invalid_bindings
test_missing_declared_pin_blocks_acceptance
test_manifest_rejects_duplicate_ids
test_credential_material_is_refused
test_evidence_is_version_bound
test_tagged_instances_report_observed_state
test_terminated_instance_has_no_current_version
test_evidence_ids_are_create_only
test_timeline_orders_offset_timestamps
test_completion_retry_preserves_first_receipt
test_prelanding_receipt_never_verifies
test_collect_lock_is_single_owner
test_requests_dedupe_and_review_cadence
test_active_cadence_ignores_secondmates
test_task_state_ignores_last_wake_event
test_scheduler_install_is_idempotent_and_removable
test_scheduler_preserves_unmanaged_artifacts
test_binding_completion_and_live_verification
test_verify_uses_completed_subjects
test_coverage_gap_for_unbound_project_tasks
test_ui_annotations_and_intent_edits
test_summary_is_bounded_and_marks_fixtures
test_summary_includes_later_project_requests

echo "# fm-system-map.test.sh: all assertions passed"
