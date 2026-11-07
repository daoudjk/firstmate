"""Access relationships for the system map; no authorization evaluator or actions.

The public CLI in fm_system_map.py owns validation, collection and receipt intake.
This module owns the bounded access adapters, conservative baseline comparison,
and the derived access view. Data contracts live in docs/system-map.md.
"""
import hashlib
import json
import re
import urllib.parse


KINDS = {"role-existence", "trust", "identity-policy", "resource-policy", "key-policy",
         "permissions-boundary", "session-policy", "organization-policy", "endpoint-policy",
         "pass-role", "configuration", "tags"}
REQUIRED_KINDS = KINDS - {"pass-role", "configuration", "tags"}
PASS_ROLE_OPERATIONS = {"lambda:createfunction", "lambda:updatefunctionconfiguration",
                        "scheduler:createschedule", "scheduler:updateschedule",
                        "ecs:registertaskdefinition", "ecs:runtask", "ec2:runinstances"}
BINDING_FIELDS = {
    "aws.iam_role_access": {"role_name": "str"},
    "aws.iam_inline_policy": {"role_name": "str", "policy_name": "str"},
    "aws.iam_managed_policy": {"policy_arn": "str"},
    "aws.s3_policy": {"bucket": "str"},
    "aws.sqs_policy": {"queue_url": "str"},
    "aws.dynamodb_policy": {"resource_arn": "str"},
    "aws.kms_policy": {"key_id": "str"},
    "aws.ecs_task_metadata": {"task_definition": "str"},
}


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()).hexdigest()


def canonical_policy(doc):
    """Normalize only IAM's set-valued statement fields; retain scalar/list types.

    Conditions, including their arrays, are deliberately opaque. No condition,
    identifier, scalar/list equivalence or arbitrary JSON array is rewritten.
    """
    if isinstance(doc, str):
        doc = json.loads(urllib.parse.unquote(doc) if not doc.lstrip().startswith("{") else doc)
    if not isinstance(doc, dict) or not isinstance(doc.get("Statement"), (dict, list)):
        raise ValueError("policy lacks a Statement object or array")
    result = dict(doc)
    statements = doc["Statement"]
    single = isinstance(statements, dict)
    normalized = []
    for statement in ([statements] if single else statements):
        if not isinstance(statement, dict) or statement.get("Effect") not in ("Allow", "Deny"):
            raise ValueError("invalid policy statement")
        statement = dict(statement)
        for key in ("Action", "NotAction", "Resource", "NotResource"):
            if isinstance(statement.get(key), list):
                statement[key] = sorted(statement[key], key=lambda v: json.dumps(v, sort_keys=True))
        for key in ("Principal", "NotPrincipal"):
            if isinstance(statement.get(key), dict):
                statement[key] = {k: sorted(v, key=lambda x: json.dumps(x, sort_keys=True)) if isinstance(v, list) else v for k, v in statement[key].items()}
        normalized.append(statement)
    result["Statement"] = normalized[0] if single else sorted(normalized, key=lambda v: json.dumps(v, sort_keys=True))
    return result


def policy_facts(document):
    canonical = canonical_policy(document)
    statements = canonical["Statement"]
    if isinstance(statements, dict):
        statements = [statements]
    principals = []
    allow_principals = []
    deny_principals = []
    for statement in statements:
        principal = statement.get("Principal", {})
        identities = []
        if isinstance(principal, dict):
            for value in principal.values():
                identities.extend(value if isinstance(value, list) else [value])
        elif isinstance(principal, str):
            identities.append(principal)
        principals.extend(identities)
        (allow_principals if statement["Effect"] == "Allow" else deny_principals).extend(identities)
    # No policy values, principal names or condition values are exposed by the
    # projection. The private owner retains original request/response documents.
    return {"format": "policy", "complete": True, "sha256": digest(canonical),
            "raw_sha256": digest(document), "statements": len(statements),
            "principal_identities": sorted(digest(v) for v in principals),
            "allow_principal_identities": sorted(digest(v) for v in allow_principals),
            "deny_principal_identities": sorted(digest(v) for v in deny_principals),
            "allow_statements": sum(s.get("Effect") == "Allow" for s in statements),
            "deny_statements": sum(s.get("Effect") == "Deny" for s in statements),
            "condition_operators": sorted({k for s in statements for k in s.get("Condition", {})}),
            "limit": "Document baseline only; no condition evaluation, propagation or effective permission proof."}


def validate_manifest(manifest, subjects, credentials, phases, error):
    def fail(message):
        raise error("access: " + message)

    def fields(item, allowed):
        if not isinstance(item, dict) or set(item) - allowed:
            fail("invalid object or unknown fields")

    def text(item, key):
        if not isinstance(item.get(key), str) or not item[key].strip():
            fail(key + " must be a nonempty string")

    def identifier(item, seen):
        text(item, "id")
        if not re.fullmatch(r"[a-z0-9][a-z0-9_.-]{0,62}", item["id"]) or item["id"] in seen:
            fail("invalid or duplicate id")
        seen.add(item["id"])

    def owners(item):
        value = item.get("owners")
        if not isinstance(value, list) or not value or any(not isinstance(o, dict) or not (o.get("name") or o.get("task") or o.get("role")) or set(o) - {"name", "task", "role"} or any(not isinstance(v, str) or not v for v in o.values()) for o in value):
            fail("owners must name at least one owner")

    def records(key):
        value = manifest.get(key, [])
        if not isinstance(value, list):
            fail(key + " must be an array")
        return value

    subject_map = {s["id"]: s for s in manifest["components"] + manifest["connections"]}
    deps = set()
    for d in records("access_dependencies"):
        fields(d, {"id", "title", "kind", "subject", "participant", "observation", "baseline", "applicability", "reason", "owners", "next_check", "references", "key_dependency", "evidence"})
        identifier(d, deps)
        for k in ("title", "next_check"):
            text(d, k)
        owners(d)
        if d.get("subject") not in subjects or d.get("kind") not in KINDS:
            fail("dependency must name an existing subject and kind")
        if "participant" in d and d["participant"] not in ("caller", "identity", "target"):
            fail("dependency participant must be caller, identity or target")
        if d.get("applicability", "required") not in ("required", "not-applicable"):
            fail("invalid applicability")
        if d.get("applicability") == "not-applicable":
            text(d, "reason")
            if d.get("observation") or d.get("baseline"):
                fail("not-applicable dependency cannot carry an observation or baseline")
        if "observation" in d and d["observation"] not in [o["id"] for o in subject_map[d["subject"]].get("observe", [])]:
            fail("dependency observation must belong to its subject")
        if not isinstance(d.get("references", []), list) or any(sid not in subjects for sid in d.get("references", [])):
            fail("references must name subjects for exact trust principal checks")
        if "evidence" in d and not re.fullmatch(r"[a-z0-9][a-z0-9_.-]{0,62}", str(d["evidence"])):
            fail("invalid evidence reference")
        if "baseline" in d:
            b = d["baseline"]
            fields(b, {"format", "complete", "sha256", "raw_sha256", "encryption_identity", "relationships_sha256", "source", "observed_at"})
            if b.get("format") not in ("policy", "configuration", "tags", "role") or not isinstance(b.get("complete"), bool):
                fail("baseline requires format and explicit completeness")
            for k in ("sha256", "raw_sha256", "encryption_identity", "relationships_sha256"):
                if k in b and not re.fullmatch(r"[0-9a-f]{64}", str(b[k])):
                    fail("invalid baseline digest")
            if b["complete"] and "sha256" not in b:
                fail("complete baseline needs a digest")
            text(b, "source")
            # Time validation is also strict for incomplete historical baselines.
            from datetime import datetime
            try:
                datetime.fromisoformat(b["observed_at"].replace("Z", "+00:00"))
            except (KeyError, ValueError, TypeError, AttributeError):
                fail("baseline requires original observed_at")
    dependency_map = {d["id"]: d for d in manifest.get("access_dependencies", [])}
    for d in dependency_map.values():
        if "key_dependency" not in d:
            continue
        key = dependency_map.get(d["key_dependency"]) if isinstance(d["key_dependency"], str) else None
        if not key or key["kind"] != "key-policy" or not key.get("observation"):
            fail("key_dependency must name an observed key-policy dependency")
        queue_observation = next((o for o in subject_map[d["subject"]].get("observe", []) if o["id"] == d.get("observation")), None)
        key_observation = next(o for o in subject_map[key["subject"]]["observe"] if o["id"] == key["observation"])
        if not queue_observation or queue_observation["adapter"] != "aws.sqs_policy" or key_observation["adapter"] != "aws.kms_policy":
            fail("key_dependency must link an SQS read to a KMS policy read")
    seen = set()
    for i in records("interactions"):
        fields(i, {"id", "title", "caller", "identity", "target", "operations", "phases", "dependencies", "context", "context_complete", "analysis_scope", "owners", "next_check", "evidence"})
        identifier(i, seen)
        for k in ("title", "analysis_scope", "next_check"):
            text(i, k)
        owners(i)
        if i.get("caller") not in subjects or i.get("target") not in subjects or i.get("identity") not in set(subjects) | credentials:
            fail("interaction caller, target and identity must reference existing subjects or credentials")
        for key, known in (("phases", phases), ("dependencies", deps)):
            if not isinstance(i.get(key), list) or not i[key] or any(v not in known for v in i[key]):
                fail(key + " must name declared records")
        if not isinstance(i.get("operations"), list) or not i["operations"] or any(not isinstance(v, str) or not re.fullmatch(r"[A-Za-z0-9.-]+:[A-Za-z0-9.-]+", v) for v in i["operations"]):
            fail("operations must be explicit service:operation assertions")
        if "context_complete" in i and not isinstance(i["context_complete"], bool):
            fail("context_complete must be boolean")
        if not isinstance(i.get("context"), dict):
            fail("context must be an object (unknown values must be explicit)")


def validate_receipt(record, error):
    requests = record.get("access_requests", {})
    if not isinstance(requests, dict) or any(not re.fullmatch(r"[a-z0-9][a-z0-9_.-]{0,62}", key) or not re.fullmatch(r"[0-9a-f]{64}", str(value)) for key, value in requests.items()):
        raise error("evidence.access_requests must map interaction ids to current assertion digests")
    if requests and (record.get("provenance", {}).get("kind", "receipt") != "receipt" or not record.get("observed_at") or not isinstance(record.get("scope"), str) or not record["scope"].strip()):
        raise error("access request proof needs a receipt, original observed_at and explicit scope")

    checks = record.get("access_checks", {})
    if not isinstance(checks, dict):
        raise error("evidence.access_checks must map dependency ids to assessments")
    for did, check in checks.items():
        if not re.fullmatch(r"[a-z0-9][a-z0-9_.-]{0,62}", did) or not isinstance(check, dict) or set(check) - {"outcome", "binding_digest", "observer_identity", "version", "facts", "error"}:
            raise error("evidence.access_checks: invalid dependency assessment")
        if check.get("outcome") not in ("ok", "absent", "denied", "error", "unknown") or not isinstance(check.get("version"), str) or not check["version"]:
            raise error("evidence.access_checks: explicit outcome and version required")
        if any(not re.fullmatch(r"[0-9a-f]{64}", str(check.get(k))) for k in ("binding_digest", "observer_identity")):
            raise error("evidence.access_checks: exact binding and observer identity required")
        facts = check.get("facts", {})
        if not isinstance(facts, dict) or set(facts) - {"format", "complete", "sha256", "raw_sha256", "encryption_identity", "relationships_sha256", "kms_key_identity", "policy_identity", "principal_identities", "allow_principal_identities", "deny_principal_identities", "allow_statements", "deny_statements", "condition_operators"}:
            raise error("evidence.access_checks: only safe policy/configuration metadata allowed")
        for key in ("sha256", "raw_sha256", "encryption_identity", "relationships_sha256", "kms_key_identity", "policy_identity"):
            if key in facts and not re.fullmatch(r"[0-9a-f]{64}", str(facts[key])):
                raise error("evidence.access_checks: metadata fingerprints must be digests")
        for key in ("principal_identities", "allow_principal_identities", "deny_principal_identities"):
            if key in facts and (not isinstance(facts[key], list) or any(not re.fullmatch(r"[0-9a-f]{64}", str(v)) for v in facts[key])):
                raise error("evidence.access_checks: principal identities must be digests")
        if any(k in facts and (not isinstance(facts[k], int) or isinstance(facts[k], bool) or facts[k] < 0) for k in ("allow_statements", "deny_statements")):
            raise error("evidence.access_checks: statement counts must be nonnegative integers")
        if "condition_operators" in facts and (not isinstance(facts["condition_operators"], list) or any(not isinstance(v, str) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9:]{0,127}", v) for v in facts["condition_operators"])):
            raise error("evidence.access_checks: condition operators must be names")
        if "error" in check and not isinstance(check["error"], str):
            raise error("evidence.access_checks: error must be text")
        if check["outcome"] == "ok" and (facts.get("format") not in ("policy", "configuration", "tags", "role") or not isinstance(facts.get("complete"), bool) or not re.fullmatch(r"[0-9a-f]{64}", str(facts.get("sha256")))):
            raise error("evidence.access_checks: successful assessment needs format, completeness and digest")
    if checks and (not record.get("observed_at") or not isinstance(record.get("scope"), str) or not record["scope"].strip() or record.get("provenance", {}).get("kind", "receipt") == "manual"):
        raise error("evidence.access_checks: owner receipt/report with original time and scope required")


def adapters(result):
    def unknown(message):
        return result("unknown", error=message)

    def call(runner, service, operation, args):
        data, err = runner.aws_call(service, operation, args)
        return data, result(err[0], error=err[1]) if err else None

    def policy_read(runner, service, operation, args, member):
        data, err = call(runner, service, operation, args)
        if err:
            return err
        if member not in data or data[member] is None:
            return unknown("Policy member missing; no authoritative absence response.")
        try:
            facts = policy_facts(data[member])
        except (ValueError, TypeError, KeyError):
            return unknown("Policy document incomplete or invalid.")
        return result("ok", state="observed", facts=facts, version=facts["sha256"])

    def role(runner, b):
        data, err = call(runner, "iam", "get-role", ["--role-name", b["role_name"], "--query", "Role.{RoleId:RoleId,Arn:Arn,CreateDate:CreateDate,AssumeRolePolicyDocument:AssumeRolePolicyDocument,PermissionsBoundary:PermissionsBoundary}"])
        if err:
            return err
        if not data.get("RoleId") or not data.get("Arn") or not data.get("CreateDate"):
            return unknown("Role identity or creation metadata missing.")
        boundary = data.get("PermissionsBoundary")
        boundary_valid = boundary is None or (isinstance(boundary, dict) and isinstance(boundary.get("PermissionsBoundaryArn"), str) and bool(boundary["PermissionsBoundaryArn"]))
        facts = {"role_identity": digest(data["RoleId"]), "role_arn_identity": digest(data["Arn"]), "created_at": data["CreateDate"],
                 "role_exists": True, "trust_configured": True, "boundary_policy_identity": digest(boundary["PermissionsBoundaryArn"]) if boundary_valid and boundary else None,
                 "boundary": "unknown" if "PermissionsBoundary" not in data or not boundary_valid else "configured" if boundary else "not-configured",
                 "boundary_identity": digest(boundary) if boundary_valid and boundary else None,
                 "propagation": "unobserved", "assumption": "not-demonstrated"}
        if data.get("AssumeRolePolicyDocument") is None:
            return unknown("Trust policy member missing; role existence alone is insufficient.")
        try:
            facts.update(policy_facts(data["AssumeRolePolicyDocument"]))
        except (ValueError, TypeError, KeyError):
            return unknown("Trust policy is incomplete or invalid.")
        if "PermissionsBoundary" not in data or not boundary_valid:
            facts["complete"] = False
        # Enumerate attachment and inline names only; fetch documents through
        # separately configured observations. Fail just this check on partials.
        for op, member in (("list-attached-role-policies", "AttachedPolicies"), ("list-role-policies", "PolicyNames")):
            listing, err = call(runner, "iam", op, ["--role-name", b["role_name"], "--no-paginate"])
            if err:
                facts[op] = {"outcome": err["outcome"], "error": err["error"]}
                facts["complete"] = False
            elif not isinstance(listing, dict) or member not in listing or listing.get("IsTruncated") is not False or listing.get("NextToken") or listing.get("Marker"):
                facts[op] = {"outcome": "unknown", "error": "Incomplete policy inventory; bounded page was not complete."}
                facts["complete"] = False
            else:
                values = listing[member]
                valid = isinstance(values, list) and all(isinstance(v, dict) and isinstance(v.get("PolicyArn"), str) and v["PolicyArn"] for v in values) if member == "AttachedPolicies" else isinstance(values, list) and all(isinstance(v, str) and v for v in values)
                if not valid:
                    facts[op] = {"outcome": "unknown", "error": "Policy inventory entries are incomplete or malformed."}
                    facts["complete"] = False
                    continue
                identities = [digest(v["PolicyArn"]) for v in values] if member == "AttachedPolicies" else [digest({"role": b["role_name"], "policy": v}) for v in values]
                facts[op] = {"outcome": "ok", "count": len(values), "policy_identities": sorted(identities), "sha256": digest(sorted(identities))}
        if facts["complete"]:
            facts["relationships_sha256"] = digest({"attached": facts["list-attached-role-policies"]["sha256"],
                                                    "inline": facts["list-role-policies"]["sha256"],
                                                    "boundary": facts["boundary_identity"]})
        # Identity/trust remains observed while the attached inventory has its
        # own incomplete state. Never infer that all attached documents were read.
        return result("ok", state="observed", facts=facts, version=digest({k: facts[k] for k in ("role_identity", "sha256", "boundary_identity", "list-attached-role-policies", "list-role-policies")}))

    def inline(runner, b):
        value = policy_read(runner, "iam", "get-role-policy", ["--role-name", b["role_name"], "--policy-name", b["policy_name"], "--query", "{PolicyDocument:PolicyDocument}"], "PolicyDocument")
        value["facts"]["policy_identity"] = digest({"role": b["role_name"], "policy": b["policy_name"]})
        return value

    def managed(runner, b):
        data, err = call(runner, "iam", "get-policy", ["--policy-arn", b["policy_arn"], "--query", "Policy.{DefaultVersionId:DefaultVersionId}"])
        if err:
            return err
        if not data.get("DefaultVersionId"):
            return unknown("Default policy version is missing.")
        value = policy_read(runner, "iam", "get-policy-version", ["--policy-arn", b["policy_arn"], "--version-id", data["DefaultVersionId"], "--query", "{PolicyDocument:PolicyVersion.Document}"], "PolicyDocument")
        value["facts"]["policy_identity"] = digest(b["policy_arn"])
        value["facts"]["policy_version"] = data["DefaultVersionId"]
        if value["outcome"] == "ok":
            value["version"] = data["DefaultVersionId"] + ":" + value["version"]
        return value

    def bucket(runner, b):
        return policy_read(runner, "s3api", "get-bucket-policy", ["--bucket", b["bucket"]], "Policy")

    def queue(runner, b):
        data, err = call(runner, "sqs", "get-queue-attributes", ["--queue-url", b["queue_url"], "--attribute-names", "Policy", "KmsMasterKeyId", "SqsManagedSseEnabled"])
        if err:
            return err
        if not isinstance(data.get("Attributes"), dict) or not data["Attributes"].get("Policy"):
            return unknown("Queue policy member missing; empty cannot be assumed.")
        try:
            facts = policy_facts(data["Attributes"]["Policy"])
        except (ValueError, TypeError, KeyError):
            return unknown("Queue policy invalid.")
        facts["encryption_identity"] = digest({k: data["Attributes"].get(k) for k in ("KmsMasterKeyId", "SqsManagedSseEnabled")})
        if data["Attributes"].get("KmsMasterKeyId"):
            facts["kms_key_identity"] = digest(data["Attributes"]["KmsMasterKeyId"])
        return result("ok", state="observed", facts=facts, version=digest({"policy": facts["sha256"], "encryption": facts["encryption_identity"]}))

    def table(runner, b):
        return policy_read(runner, "dynamodb", "get-resource-policy", ["--resource-arn", b["resource_arn"]], "Policy")

    def key(runner, b):
        return policy_read(runner, "kms", "get-key-policy", ["--key-id", b["key_id"], "--policy-name", "default"], "Policy")

    def task(runner, b):
        data, err = call(runner, "ecs", "describe-task-definition", ["--task-definition", b["task_definition"], "--include", "TAGS", "--query", "{taskDefinition:taskDefinition.{taskDefinitionArn:taskDefinitionArn,revision:revision,taskRoleArn:taskRoleArn,executionRoleArn:executionRoleArn,status:status},tags:tags}"])
        if err:
            return err
        taskdef = data.get("taskDefinition")
        if not isinstance(taskdef, dict) or not taskdef.get("taskDefinitionArn") or not isinstance(data.get("tags"), list):
            return unknown("Task identity or requested tags member missing; tag baseline is incomplete.")
        tags = data["tags"]
        if any(not isinstance(t, dict) or set(t) != {"key", "value"} or not isinstance(t["key"], str) or not isinstance(t["value"], str) for t in tags):
            return unknown("Task tags response is incomplete or malformed.")
        # No containers, environment, secret references or nested source config.
        facts = {"format": "tags", "complete": True, "include_tags": True,
                 "sha256": digest(sorted(tags, key=lambda t: (t["key"], t["value"]))), "raw_sha256": digest(tags),
                 "tag_count": len(tags), "task_identity": digest(taskdef),
                 "task_role_identity": digest(taskdef.get("taskRoleArn")), "execution_role_identity": digest(taskdef.get("executionRoleArn"))}
        return result("ok", state="observed", facts=facts, version=digest({"task": taskdef, "tags": facts["sha256"]}))

    return dict(zip(BINDING_FIELDS, (role, inline, managed, bucket, queue, table, key, task)))


def compare_baseline(baseline, observation, queue=False, role=False):
    if not baseline or not baseline.get("complete"):
        return "incomplete-baseline"
    if queue and not baseline.get("encryption_identity"):
        return "incomplete-baseline"
    if role and not baseline.get("relationships_sha256"):
        return "incomplete-baseline"
    facts = observation.get("facts", {})
    if observation.get("outcome") != "ok" or facts.get("complete") is not True or not facts.get("sha256") or baseline.get("format") != facts.get("format"):
        return "insufficient-evidence"
    if queue and not facts.get("encryption_identity"):
        return "insufficient-evidence"
    if role and not facts.get("relationships_sha256"):
        return "insufficient-evidence"
    if baseline["sha256"] != facts["sha256"]:
        return "policy-drift" if facts["format"] == "policy" else "configuration-drift"
    if queue and baseline["encryption_identity"] != facts["encryption_identity"]:
        return "configuration-drift"
    if role and baseline["relationships_sha256"] != facts["relationships_sha256"]:
        return "configuration-drift"
    if baseline.get("raw_sha256") and baseline["raw_sha256"] != facts.get("raw_sha256"):
        return "representation-only"
    return "matches-baseline"


def build_view(manifest, bindings, subjects, evidence, observations, interval, now, parse_time, binding_digest, binding_problem):
    deps = {}
    declarations = {s["id"]: s for s in manifest["components"] + manifest["connections"]}
    records = {e["id"]: e for e in evidence if not e.get("invalid")}
    def same_resource(subject_id, check):
        subject = declarations[subject_id]
        version_id = subject.get("version_from")
        version = next((o for o in subject.get("observe", []) if o["id"] == version_id), None)
        if not version:
            return False
        version_entry = bindings.get("bindings", {}).get(version["binding"])
        check_entry = bindings.get("bindings", {}).get(check["binding"])
        if binding_problem(version["adapter"], version_entry) or binding_problem(check["adapter"], check_entry):
            return False
        first, second = version["adapter"], check["adapter"]
        if first == second:
            return all(version_entry[field] == check_entry[field] for field in BINDING_FIELDS.get(first, {})) if first in BINDING_FIELDS else version_entry == check_entry
        if {first, second} == {"aws.s3_bucket", "aws.s3_policy"}:
            return version_entry["bucket"] == check_entry["bucket"]
        if {first, second} == {"aws.iam_role", "aws.iam_role_access"}:
            return version_entry["role_name"] == check_entry["role_name"]
        scope = bindings.get("scope", {})
        account, region = scope.get("expected_account"), scope.get("region")
        if not account or not region:
            return False
        if first == "aws.sqs_queue" and second == "aws.sqs_policy":
            url = urllib.parse.urlparse(check_entry["queue_url"])
            return (url.scheme == "https" and url.hostname == "sqs.%s.amazonaws.com" % region
                    and url.path == "/%s/%s" % (account, version_entry["queue_name"]))
        if first == "aws.dynamodb_table" and second == "aws.dynamodb_policy":
            return check_entry["resource_arn"] == "arn:aws:dynamodb:%s:%s:table/%s" % (region, account, version_entry["table"])
        return False
    for d in manifest.get("access_dependencies", []):
        obs = observations.get(d.get("observation"))
        imported = False
        named = records.get(d.get("evidence"))
        check = (named or {}).get("access_checks", {}).get(d["id"])
        # A collected result, including denial/unknown, always takes precedence.
        if obs is None and check:
            subject = subjects[d["subject"]]
            identity = subject["resource_identity"]
            if d.get("observation"):
                declaration = next(o for o in declarations[d["subject"]]["observe"] if o["id"] == d["observation"])
                entry = bindings.get("bindings", {}).get(declaration["binding"])
                identity = None if binding_problem(declaration["adapter"], entry) else binding_digest(declaration, bindings)
            version_obs = observations.get(declarations[d["subject"]].get("version_from"), {})
            version_age = now - (parse_time(version_obs.get("checked_at")) or 0)
            version_current = version_obs.get("outcome") == "ok" and 0 <= version_age <= interval * 2
            if version_obs.get("adapter", "").startswith("aws."):
                version_current = version_current and version_obs.get("scope", {}).get("account_verified") is True and bool(version_obs.get("scope", {}).get("collector_identity"))
            age = now - (parse_time(named.get("observed_at")) or 0)
            current = version_current and (not named.get("historical") and 0 <= age <= interval * 2 and identity
                       and check["binding_digest"] == identity and subject["version_state"] == "observed"
                       and subject["layers"]["deployment"]["status"] == "deployed"
                       and named.get("versions", {}).get(d["subject"]) == subject["version"]
                       and named.get("resource_identities", {}).get(d["subject"]) == subject["resource_identity"])
            if current:
                imported = True
                obs = {"outcome": check["outcome"], "facts": check.get("facts", {}), "version": check["version"],
                       "binding_digest": check["binding_digest"], "checked_at": named["observed_at"],
                       "error": check.get("error"), "adapter": "owner.receipt",
                       "scope": {"kind": "imported", "owner_scope": named["scope"], "observer_identity": check["observer_identity"]}}

        state = "unobserved"
        if d.get("applicability") == "not-applicable":
            state = "not-applicable"
        elif obs:
            state = "observed" if obs["outcome"] == "ok" else obs["outcome"]
            age = now - (parse_time(obs.get("checked_at")) or 0)
            if age < 0 or age > interval * 2:
                state = "stale"
            elif state == "observed" and obs.get("adapter", "").startswith("aws.") and (obs.get("scope", {}).get("account_verified") is not True or not obs.get("scope", {}).get("collector_identity")):
                state = "unknown"
        declaration = next((o for o in declarations[d["subject"]].get("observe", []) if o["id"] == d.get("observation")), None)
        queue = bool(declaration and declaration["adapter"] == "aws.sqs_policy")
        role = bool(declaration and declaration["adapter"] == "aws.iam_role_access")
        baseline = "not-applicable" if state == "not-applicable" else compare_baseline(d.get("baseline"), obs or {}, queue, role)
        deps[d["id"]] = dict(d, state=state, comparison=baseline,
                              coverage="not-required" if state == "not-applicable" else "imported" if imported else "observed" if obs else "missing-evidence" if d.get("evidence") else "uncollected" if d.get("observation") else "unmapped",
                              checked_at=(obs or {}).get("checked_at"), scope=(obs or {}).get("scope"),
                              resource_identity=(obs or {}).get("binding_digest"), version=(obs or {}).get("version"),
                              facts=(obs or {}).get("facts", {}), error=(obs or {}).get("error"),
                              source=(obs or {}).get("adapter"), provenance=named.get("provenance") if imported else None)
    for d in deps.values():
        if "key_dependency" not in d or d["state"] != "observed":
            continue
        key = deps[d["key_dependency"]]
        key_declaration = next(o for o in declarations[key["subject"]]["observe"] if o["id"] == key["observation"])
        key_entry = bindings.get("bindings", {}).get(key_declaration["binding"])
        expected = digest(key_entry["key_id"]) if not binding_problem("aws.kms_policy", key_entry) else None
        if d["comparison"] in ("matches-baseline", "representation-only") and (not expected or d["facts"].get("kms_key_identity") != expected or key["state"] != "observed" or key["comparison"] not in ("matches-baseline", "representation-only")):
            d["comparison"] = "insufficient-evidence"
    for d in deps.values():
        declaration = next((o for o in declarations[d["subject"]].get("observe", []) if o["id"] == d.get("observation")), None)
        if declaration and declaration["adapter"] == "aws.sqs_policy" and d["state"] == "observed" and d["facts"].get("kms_key_identity") and "key_dependency" not in d:
            d["comparison"] = "insufficient-evidence"
    # Inventory completeness is separate from role existence and trust. Every
    # policy in the bounded attachment inventory needs its own current read.
    observed_policies = {d["facts"].get("policy_identity") for d in deps.values() if d["kind"] in ("identity-policy", "permissions-boundary") and d["state"] == "observed" and d["comparison"] in ("matches-baseline", "representation-only")}
    for d in deps.values():
        facts = d["facts"]
        inventory = [entry for key, entry in facts.items() if key in ("list-attached-role-policies", "list-role-policies")]
        required = [pid for entry in inventory for pid in entry.get("policy_identities", [])]
        if facts.get("boundary_policy_identity"):
            required.append(facts["boundary_policy_identity"])
        d["unobserved_policy_documents"] = [pid for pid in required if pid not in observed_policies]
        d["reference_states"] = []
        for sid in d.get("references", []):
            role_observations = [observations.get(o["id"], {}) for o in declarations[sid].get("observe", []) if o["adapter"] == "aws.iam_role_access"]
            candidate = next((o for o in role_observations if o.get("outcome") == "ok"), role_observations[0] if role_observations else {})
            state = candidate.get("outcome", "unobserved")
            if state == "ok":
                fresh = 0 <= now - (parse_time(candidate.get("checked_at")) or 0) <= interval * 2
                identity = candidate.get("facts", {}).get("role_arn_identity")
                if not fresh:
                    state = "stale"
                elif not identity or "allow_principal_identities" not in facts or "deny_principal_identities" not in facts:
                    state = "unknown"
                elif identity in facts["allow_principal_identities"]:
                    state = "observed"
                elif identity in facts["deny_principal_identities"]:
                    state = "denied-reference"
                else:
                    state = "wrong-reference"
            d["reference_states"].append({"subject": sid, "state": state, "created_at": candidate.get("facts", {}).get("created_at"), "resource_identity": candidate.get("binding_digest"), "version": candidate.get("version"), "propagation": "unobserved"})
        if d["state"] == "observed" and d["comparison"] in ("matches-baseline", "representation-only") and (d["unobserved_policy_documents"] or any(r["state"] != "observed" for r in d["reference_states"])):
            d["comparison"] = "insufficient-evidence"
    policy_checks = {}
    policy_identities = {}
    for d in deps.values():
        if d["kind"] not in ("identity-policy", "permissions-boundary"):
            continue
        declaration = next((o for o in declarations[d["subject"]].get("observe", []) if o["id"] == d.get("observation")), None)
        entry = bindings.get("bindings", {}).get(declaration["binding"]) if declaration else None
        identity = d["facts"].get("policy_identity")
        if declaration and declaration["adapter"] == "aws.iam_inline_policy" and not binding_problem(declaration["adapter"], entry):
            identity = digest({"role": entry["role_name"], "policy": entry["policy_name"]})
        elif declaration and declaration["adapter"] == "aws.iam_managed_policy" and not binding_problem(declaration["adapter"], entry):
            identity = digest(entry["policy_arn"])
        if identity:
            policy_checks.setdefault((d["kind"], identity), []).append(d["id"])
            policy_identities[d["id"]] = identity
    interactions = []
    gaps = []
    for item in manifest.get("interactions", []):
        identity_observations = [o for o in declarations[item["identity"]].get("observe", []) if o["adapter"] == "aws.iam_role_access"] if item["identity"] in declarations else []
        role_facts = observations.get(identity_observations[0]["id"], {}).get("facts", {}) if len(identity_observations) == 1 else {}
        role_inventory = set()
        for inventory in ("list-attached-role-policies", "list-role-policies"):
            role_inventory.update(role_facts.get(inventory, {}).get("policy_identities", []))
        boundary_identity = role_facts.get("boundary_policy_identity")
        declared = set(item["dependencies"])
        required = set(declared)
        for did in declared:
            d = deps[did]
            if d.get("key_dependency") and d["facts"].get("kms_key_identity"):
                required.add(d["key_dependency"])
            facts = d["facts"]
            for inventory in ("list-attached-role-policies", "list-role-policies"):
                for identity in facts.get(inventory, {}).get("policy_identities", []):
                    required.update(policy_checks.get(("identity-policy", identity), []))
            if facts.get("boundary_policy_identity"):
                required.update(policy_checks.get(("permissions-boundary", facts["boundary_policy_identity"]), []))
        unlinked = sorted(required - declared)
        required_ids = item["dependencies"] + unlinked
        linked = [deps[did] for did in required_ids]
        def participant_match(d):
            slot = d.get("participant")
            if slot not in ("caller", "identity", "target"):
                return False
            subject = item[slot]
            kind = d["kind"]
            declaration = next((o for o in declarations[d["subject"]].get("observe", []) if o["id"] == d.get("observation")), None)
            adapter = declaration["adapter"] if declaration else None
            if d["subject"] == subject and declaration and not same_resource(subject, declaration):
                return False
            if kind in ("role-existence", "trust", "identity-policy", "permissions-boundary", "session-policy", "pass-role") and slot != "identity":
                return False
            if kind == "resource-policy" and slot != "target":
                return False
            if kind == "key-policy" and slot != "target":
                return False
            if kind == "identity-policy":
                if d["subject"] == subject and not adapter:
                    return True
                if adapter not in ("aws.iam_inline_policy", "aws.iam_managed_policy"):
                    return False
                return bool(role_facts.get("complete") and policy_identities.get(d["id"]) in role_inventory)
            if kind == "permissions-boundary":
                if d["subject"] == subject and not adapter:
                    return True
                if adapter != "aws.iam_managed_policy":
                    return False
                return bool(role_facts.get("complete") and boundary_identity and policy_identities.get(d["id"]) == boundary_identity)
            if kind == "key-policy":
                if d["subject"] == subject:
                    return adapter in (None, "aws.kms_policy")
                return any(q["subject"] == item["target"] and participant_match(q) and q.get("key_dependency") == d["id"] and q["facts"].get("kms_key_identity") for q in linked)
            if kind in ("role-existence", "trust"):
                return d["subject"] == subject and adapter in (None, "aws.iam_role_access")
            if kind == "resource-policy":
                return d["subject"] == subject and adapter in (None, "aws.s3_policy", "aws.sqs_policy", "aws.dynamodb_policy")
            if d["subject"] == subject:
                return True
            return False
        matched = {d["id"] for d in linked if participant_match(d)}
        missing_kinds = sorted(REQUIRED_KINDS - {d["kind"] for d in linked if d["id"] in matched})
        if ({"iam:passrole"} | PASS_ROLE_OPERATIONS) & {operation.lower() for operation in item["operations"]} and "pass-role" not in {d["kind"] for d in linked if d["id"] in matched}:
            missing_kinds.append("pass-role")
        missing = [d["id"] for d in linked if d["id"] in unlinked or d["id"] not in matched or (d["state"] != "not-applicable" and (d["state"] != "observed" or d["comparison"] not in ("matches-baseline", "representation-only")))]
        participants = set([item["caller"], item["target"], item["identity"]]) & set(subjects)
        participant_gaps = []
        for sid in sorted(participants):
            version_obs = observations.get(declarations[sid].get("version_from"), {})
            age = now - (parse_time(version_obs.get("checked_at")) or 0)
            fresh_version = version_obs.get("outcome") == "ok" and 0 <= age <= interval * 2
            if version_obs.get("adapter", "").startswith("aws."):
                fresh_version = fresh_version and version_obs.get("scope", {}).get("account_verified") is True and bool(version_obs.get("scope", {}).get("collector_identity"))
            if not fresh_version or subjects[sid]["layers"]["deployment"]["status"] != "deployed":
                participant_gaps.append(sid)
        if item["identity"] not in subjects:
            participant_gaps.append(item["identity"])
        # Include current policy versions and caller identity, but not the time
        # of a repeated identical read. Freshness is checked independently below.
        assertion = digest({"interaction": item, "bindings": bindings,
                            "dependencies": [{k: d.get(k) for k in ("id", "state", "comparison", "resource_identity", "version", "facts", "scope")} for d in linked],
                            "subjects": {sid: {k: subjects[sid].get(k) for k in ("version", "resource_identity")} for sid in sorted(participants)}})
        proof = "not-demonstrated"
        rec = next((r for r in evidence if r.get("id") == item.get("evidence") and not r.get("invalid")), None)
        if rec:
            proof = "stale"
            age = now - (parse_time(rec.get("observed_at")) or 0)
            current = not participant_gaps and not rec.get("historical") and 0 <= age <= interval * 2 and rec.get("access_requests", {}).get(item["id"]) == assertion
            current = current and all(subjects[sid]["version_state"] == "observed" and subjects[sid]["layers"]["deployment"]["status"] == "deployed" and rec.get("versions", {}).get(sid) == subjects[sid]["version"] and rec.get("resource_identities", {}).get(sid) == subjects[sid]["resource_identity"] for sid in participants)
            # A credential reference must itself have current validity evidence.
            if item["identity"] not in subjects:
                current = False
            if current and not missing and not missing_kinds and item.get("context_complete") is True:
                proof = {"pass": "demonstrated", "fail": "failed", "not-run": "not-demonstrated"}[rec["result"]]
        status = "gaps" if missing or missing_kinds or item.get("context_complete") is not True else "declared-baselines-observed"
        interactions.append(dict(item, required_dependencies=required_ids, unlinked_dependencies=unlinked, unmatched_dependencies=sorted(set(required_ids) - matched), static_coverage=status, missing_dependencies=missing,
                                 missing_kinds=missing_kinds, participant_gaps=participant_gaps, assertion_digest=assertion,
                                 request_proof=proof, evidence_record=rec,
                                 effective_access="unknown", propagation="unobserved", context_coverage="declared-complete" if item.get("context_complete") is True else "unobserved"))
        for sid in participant_gaps:
            gaps.append({"interaction": item["id"], "kind": "current-identity-version", "subject": sid, "state": "unqualified", "owners": item["owners"], "next_check": "Observe a fresh current bound deployment and version for " + sid + "; credential metadata alone cannot qualify a request."})
        if item.get("context_complete") is not True:
            gaps.append({"interaction": item["id"], "kind": "request-context", "state": "incomplete", "owners": item["owners"], "next_check": "Supply concrete condition inputs and mark context_complete only after owner review."})
        if proof not in ("demonstrated", "failed"):
            gaps.append({"interaction": item["id"], "kind": "actual-request", "state": proof, "owners": item["owners"], "next_check": "Supply a current exact-version and binding request receipt through the existing owner."})
        for did in missing:
            d = deps[did]
            gaps.append({"interaction": item["id"], "dependency": did, "subject": d["subject"], "state": d["state"], "comparison": d["comparison"], "title": d["title"], "kind": d["kind"], "owners": d["owners"], "next_check": ("Link this required check to the interaction. " if did in unlinked else "Map this check to the correct participant and observed relationship. " if did not in matched else "") + d["next_check"]})
        for kind in missing_kinds:
            gaps.append({"interaction": item["id"], "kind": kind, "state": "unmapped", "owners": item["owners"], "next_check": "Declare " + kind + " coverage or a reasoned not-applicable dependency. " + item["next_check"]})
    phases = [{"id": p["id"], "title": p["title"], "interactions": [i["id"] for i in interactions if p["id"] in i["phases"]]} for p in manifest.get("lifecycle", {}).get("phases", [])]
    for p in phases:
        if not p["interactions"]:
            gaps.append({"phase": p["id"], "state": "unmapped", "next_check": "Declare the required access interactions for this phase."})
    consolidated = {}
    for gap in gaps:
        key = gap.get("dependency") or (gap.get("interaction", gap.get("phase")), gap.get("kind"), gap.get("subject"))
        if key not in consolidated:
            consolidated[key] = dict(gap, interactions=[])
        if gap.get("interaction"):
            consolidated[key]["interactions"].append(gap["interaction"])
    return {"dependencies": list(deps.values()), "interactions": interactions, "gaps": list(consolidated.values()), "phases": phases,
            "limit": "Declared action/target/context baseline comparison only. No IAM simulation, propagation test or effective access conclusion. Original deployment safety preflight remains authoritative."}
