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
    log.write(" ".join(args[:2]) + "\n")
time.sleep(float(st.get("sleep", 0)))
def out(o):
    print(json.dumps(o)); sys.exit(0)
if st.get("fail_all"):
    sys.stderr.write("Could not connect to the endpoint URL"); sys.exit(255)
if svc in st.get("missing", []):
    sys.stderr.write("ResourceNotFoundException: resource does not exist"); sys.exit(254)
if svc in st.get("deny", []):
    sys.stderr.write("An error occurred (AccessDeniedException) when calling %s: User arn:aws:iam::123456789012:user/x is not authorized" % op); sys.exit(254)
if svc == "sts": out({"Account": st.get("account", "123456789012")})
if op == "describe-services":
    n = int(st.get("ecs_running", 0))
    out({"services": [{"status": "ACTIVE", "desiredCount": n, "runningCount": n, "pendingCount": 0, "taskDefinition": "arn:aws:ecs:us-east-1:123456789012:task-definition/example-api:7"}]})
if op == "get-queue-url": out({"QueueUrl": "https://example.invalid/q"})
if op == "get-queue-attributes": out({"Attributes": {"ApproximateNumberOfMessages": "0", "ApproximateNumberOfMessagesNotVisible": "0"}})
if op == "describe-table": out({"Table": {"TableStatus": "ACTIVE", "ItemCount": 1}})
if op == "get-item": out({"Item": {"Halted": {"BOOL": True}, "Revision": {"N": "7"}}})
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
