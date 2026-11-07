#!/usr/bin/env python3
"""Living system map: intended design, read-only observations, evidence, and a local UI.

Run through bin/fm-system-map.sh, which resolves FM_HOME and the interpreter.
That script's header and `fm-system-map.sh help` own the command surface;
docs/system-map.md owns the data contracts and the activation procedure.

Design boundaries this module keeps:

- Opt-in. Without config/system-map every entry point is a silent no-op, so a
  home that never enabled the map behaves exactly as before.
- Read-only observation. Adapters are a fixed table in this file. A manifest or
  binding names an adapter and supplies typed parameters; it never supplies an
  executable string, and every AWS call is a describe/get/list/head operation
  with connect, read and process timeouts.
- Intent is separate from observation. Manifests (intended design), bindings
  (private resource names), annotations, and evidence live under
  data/system-map/<project>/. Snapshots, health, the last successful
  observations, and pending supervisor requests live under
  state/system-map/<project>/. Nothing observed is ever written into intent,
  and intent edits never touch observed records.
- Unknown is not absent. An observation is ok, absent, denied, error, or
  unknown, and a failed read keeps the last successful read in a separate file
  rather than overwriting it or reporting a false green.
- Evidence is version-bound. A record proves a subject only for the exact
  version it names, so proof from an older version never qualifies a newer one.
- No competing supervisor. The collector only writes durable request records;
  a registered watcher check (or the session-start summary) surfaces them to
  the main firstmate, which owns every follow-up.
"""

import argparse
import contextlib
import datetime as _dt
import errno
import fcntl
import glob
import hashlib
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MANIFEST_SCHEMA = "fm-system-map.manifest.v1"
BINDINGS_SCHEMA = "fm-system-map.bindings.v1"
EVIDENCE_SCHEMA = "fm-system-map.evidence.v1"
SNAPSHOT_SCHEMA = "fm-system-map.snapshot.v1"
VIEW_SCHEMA = "fm-system-map.view.v1"
TASK_BINDING_SCHEMA = "fm-system-map.task-binding.v1"
COMPLETION_SCHEMA = "fm-system-map.completion.v1"

CHECK_ID = "system-map"
DEFAULT_PORT = 4790
DEFAULTS = {
    "port": DEFAULT_PORT,
    "active_interval": 300,
    "idle_interval": 3600,
    "review_interval": 86400,
    "collect_timeout": 120,
    "reemit_interval": 21600,
}
ID_RE = re.compile(r"^[a-z0-9][a-z0-9_.-]{0,62}$")
TASK_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
OUTCOMES = ("ok", "absent", "denied", "error", "unknown")
SUCCESS_OUTCOMES = ("ok", "absent")
EVIDENCE_RESULTS = ("pass", "fail", "not-run")
SEVERITIES = ("high", "medium", "low", "info")
# receipt: a machine-written run or test receipt; imported-report: a claim
# transcribed from a human or agent report; manual: an operator assertion.
# None of these is a collector observation, which lives only in snapshots.
PROVENANCE_KINDS = ("receipt", "imported-report", "manual")
# Keys that would carry credential material. Manifests and bindings describe
# credentials (purpose, owner, expiry); they never hold one.
FORBIDDEN_KEY_RE = re.compile(
    r"(secret|password|passwd|private[_-]?key|access[_-]?key|session[_-]?token|"
    r"api[_-]?key|credential[_-]?value|^token$|^value$)",
    re.IGNORECASE,
)
FORBIDDEN_VALUE_RE = re.compile(r"(AKIA|ASIA)[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----")
ACCOUNT_RE = re.compile(r"\b\d{12}\b")
ARN_RE = re.compile(r"arn:aws[a-z-]*:[^\s\"',]+")


class MapError(Exception):
    """A user-facing validation or usage error."""


# ---------------------------------------------------------------------------
# Time and file helpers


def now_ts():
    return time.time()


def iso(ts=None):
    if ts is None:
        ts = now_ts()
    return _dt.datetime.fromtimestamp(ts, _dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def precise_iso():
    return _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


def parse_iso(value):
    if not isinstance(value, str) or not value:
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = _dt.datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=_dt.timezone.utc)
    return parsed.timestamp()


def read_json(path, default=None):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        return default


def write_json_atomic(path, data, mode=0o600, create_only=False):
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, mode)
        if create_only:
            os.link(tmp, path)
            os.unlink(tmp)
        else:
            os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def write_text_atomic(path, text, mode=0o600):
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


@contextlib.contextmanager
def file_lock(path, blocking=True):
    """Advisory exclusive lock; yields True when held, False when busy."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    handle = open(path, "a+")
    try:
        flags = fcntl.LOCK_EX if blocking else fcntl.LOCK_EX | fcntl.LOCK_NB
        try:
            fcntl.flock(handle.fileno(), flags)
        except OSError as exc:
            if exc.errno in (errno.EAGAIN, errno.EACCES, errno.EWOULDBLOCK):
                yield False
                return
            raise
        try:
            yield True
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
    finally:
        handle.close()


def redact(text, limit=300):
    """Strip account numbers and ARNs from provider text before it is stored."""
    if text is None:
        return None
    clean = ARN_RE.sub("<arn>", str(text))
    clean = ACCOUNT_RE.sub("<account>", clean)
    clean = " ".join(clean.split())
    if len(clean) > limit:
        clean = clean[: limit - 3] + "..."
    return clean


# ---------------------------------------------------------------------------
# Home layout and configuration


class Home:
    def __init__(self, env=None):
        env = env if env is not None else os.environ
        root = env.get("FM_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        self.root = root
        self.home = env.get("FM_HOME") or root
        self.config_dir = env.get("FM_CONFIG_OVERRIDE") or os.path.join(self.home, "config")
        self.data_dir = env.get("FM_DATA_OVERRIDE") or os.path.join(self.home, "data")
        self.state_dir = env.get("FM_STATE_OVERRIDE") or os.path.join(self.home, "state")
        self.config_file = os.path.join(self.config_dir, "system-map")
        self.map_data = os.path.join(self.data_dir, "system-map")
        self.map_state = os.path.join(self.state_dir, "system-map")
        self.ui_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "system-map-ui")

    def enabled(self):
        return os.path.isfile(self.config_file)

    def config(self):
        """Parse config/system-map (key=value lines); raise MapError on bad input."""
        cfg = dict(DEFAULTS)
        cfg["projects"] = []
        if not self.enabled():
            return cfg
        with open(self.config_file, "r", encoding="utf-8") as handle:
            for number, raw in enumerate(handle, 1):
                line = raw.split("#", 1)[0].strip()
                if not line:
                    continue
                if "=" not in line:
                    raise MapError("config/system-map line %d is not key=value" % number)
                key, value = (part.strip() for part in line.split("=", 1))
                if key == "project":
                    if not ID_RE.match(value):
                        raise MapError("config/system-map line %d: invalid project id %r" % (number, value))
                    if value not in cfg["projects"]:
                        cfg["projects"].append(value)
                elif key in DEFAULTS:
                    if not value.isdigit() or int(value) <= 0:
                        raise MapError("config/system-map line %d: %s must be a positive integer" % (number, key))
                    cfg[key] = int(value)
                else:
                    raise MapError("config/system-map line %d: unknown key %r" % (number, key))
        if not (1024 <= cfg["port"] <= 65535):
            raise MapError("config/system-map: port must be between 1024 and 65535")
        if cfg["active_interval"] < 60 or cfg["idle_interval"] < cfg["active_interval"]:
            raise MapError("config/system-map: active_interval must be >= 60 and idle_interval >= active_interval")
        return cfg

    def pdata(self, project, *parts):
        return os.path.join(self.map_data, project, *parts)

    def pstate(self, project, *parts):
        return os.path.join(self.map_state, project, *parts)

    def home_tag(self):
        return hashlib.sha256(os.path.realpath(self.home).encode()).hexdigest()[:8]


def require_project(home, cfg, project):
    if not project:
        if len(cfg["projects"]) == 1:
            return cfg["projects"][0]
        raise MapError("name a project; configured: %s" % (", ".join(cfg["projects"]) or "none"))
    if project not in cfg["projects"]:
        raise MapError("project %r is not listed in config/system-map" % project)
    return project


# ---------------------------------------------------------------------------
# Validation


def _scan_forbidden(obj, where):
    if isinstance(obj, dict):
        for key, value in obj.items():
            if FORBIDDEN_KEY_RE.search(str(key)):
                raise MapError("%s: key %r looks like credential material; record purpose/owner/expiry only" % (where, key))
            _scan_forbidden(value, "%s.%s" % (where, key))
    elif isinstance(obj, list):
        for index, value in enumerate(obj):
            _scan_forbidden(value, "%s[%d]" % (where, index))
    elif isinstance(obj, str) and FORBIDDEN_VALUE_RE.search(obj):
        raise MapError("%s: value looks like credential material" % where)


def _req(obj, key, kind, where, optional=False):
    if key not in obj:
        if optional:
            return None
        raise MapError("%s: missing %r" % (where, key))
    value = obj[key]
    if kind == "id":
        if not isinstance(value, str) or not ID_RE.match(value):
            raise MapError("%s.%s: must be a lowercase id" % (where, key))
    elif kind == "str":
        if not isinstance(value, str):
            raise MapError("%s.%s: must be a string" % (where, key))
    elif kind == "list":
        if not isinstance(value, list):
            raise MapError("%s.%s: must be a list" % (where, key))
    elif kind == "dict":
        if not isinstance(value, dict):
            raise MapError("%s.%s: must be an object" % (where, key))
    elif kind == "int":
        if not isinstance(value, int) or isinstance(value, bool):
            raise MapError("%s.%s: must be an integer" % (where, key))
    return value


def _check_keys(obj, allowed, where):
    for key in obj:
        if key not in allowed and not str(key).startswith("x-"):
            raise MapError("%s: unknown field %r" % (where, key))


SUBJECT_FIELDS = {
    "id", "title", "kind", "group", "description", "owners", "intended", "observe",
    "version_from", "pin", "implementation", "exception", "x", "y", "notes", "from", "to", "lineage",
}


def _validate_owner_list(owners, where):
    if not isinstance(owners, list):
        raise MapError("%s: owners must be a list" % where)
    for index, owner in enumerate(owners):
        w = "%s.owners[%d]" % (where, index)
        if not isinstance(owner, dict):
            raise MapError("%s: must be an object" % w)
        _check_keys(owner, {"role", "name", "task"}, w)
        for key in ("role", "name", "task"):
            if key in owner and not isinstance(owner[key], str):
                raise MapError("%s.%s: must be a string" % (w, key))
        if "task" in owner and not TASK_RE.match(owner["task"]):
            raise MapError("%s.task: invalid task id" % w)


def _unique_manifest_id(item, seen, where):
    item_id = _req(item, "id", "id", where)
    if item_id in seen:
        raise MapError("%s: duplicate id %r" % (where, item_id))
    seen.add(item_id)
    return item_id


def validate_manifest(manifest):
    """Validate a manifest in place-free fashion; return the set of subject ids."""
    if not isinstance(manifest, dict):
        raise MapError("manifest must be a JSON object")
    _scan_forbidden(manifest, "manifest")
    _check_keys(manifest, {
        "schema", "project", "title", "description", "revision", "updated_at", "modes",
        "expected_mode", "groups", "components", "connections", "lifecycle", "acceptance",
        "known_gaps", "credentials", "prerequisites",
    }, "manifest")
    if manifest.get("schema") != MANIFEST_SCHEMA:
        raise MapError("manifest.schema must be %s" % MANIFEST_SCHEMA)
    _req(manifest, "project", "id", "manifest")
    _req(manifest, "title", "str", "manifest")
    revision = _req(manifest, "revision", "int", "manifest")
    if revision < 1:
        raise MapError("manifest.revision must be >= 1")
    modes = _req(manifest, "modes", "list", "manifest")
    if not modes or not all(isinstance(m, str) and ID_RE.match(m) for m in modes):
        raise MapError("manifest.modes must be a non-empty list of ids")
    if manifest.get("expected_mode") not in modes:
        raise MapError("manifest.expected_mode must be one of manifest.modes")
    groups = {}
    group_ids = set()
    for index, group in enumerate(manifest.get("groups", [])):
        w = "manifest.groups[%d]" % index
        _check_keys(group, {"id", "title", "description"}, w)
        groups[_unique_manifest_id(group, group_ids, w)] = group
        _req(group, "title", "str", w)
    ids = {}
    observation_ids = set()
    for collection, kind in (("components", "component"), ("connections", "connection")):
        for index, subject in enumerate(_req(manifest, collection, "list", "manifest")):
            w = "manifest.%s[%d]" % (collection, index)
            if not isinstance(subject, dict):
                raise MapError("%s: must be an object" % w)
            _check_keys(subject, SUBJECT_FIELDS, w)
            sid = _req(subject, "id", "id", w)
            if sid in ids:
                raise MapError("%s: duplicate subject id %r" % (w, sid))
            ids[sid] = kind
            _req(subject, "title", "str", w)
            if "group" in subject and subject["group"] not in groups:
                raise MapError("%s.group: unknown group %r" % (w, subject["group"]))
            _validate_owner_list(subject.get("owners", []), w)
            intended = subject.get("intended", {})
            if not isinstance(intended, dict):
                raise MapError("%s.intended: must be an object of mode -> state" % w)
            for mode, state in intended.items():
                if mode not in modes or not isinstance(state, str) or not state:
                    raise MapError("%s.intended: %r must map a declared mode to a state" % (w, mode))
            for oindex, obs in enumerate(subject.get("observe", [])):
                ow = "%s.observe[%d]" % (w, oindex)
                if not isinstance(obs, dict):
                    raise MapError("%s: must be an object" % ow)
                _check_keys(obs, {"id", "adapter", "binding", "role"}, ow)
                oid = _req(obs, "id", "id", ow)
                if oid in observation_ids:
                    raise MapError("%s: duplicate observation id %r" % (ow, oid))
                observation_ids.add(oid)
                adapter = _req(obs, "adapter", "str", ow)
                if adapter not in ADAPTERS:
                    raise MapError("%s.adapter: unknown adapter %r (known: %s)" % (ow, adapter, ", ".join(sorted(ADAPTERS))))
                _req(obs, "binding", "id", ow)
                if obs.get("role", "runtime") not in ("runtime", "version", "info"):
                    raise MapError("%s.role: must be runtime, version, or info" % ow)
            if "version_from" in subject:
                if subject["version_from"] not in [o["id"] for o in subject.get("observe", [])]:
                    raise MapError("%s.version_from: must name one of this subject's observations" % w)
            if "pin" in subject:
                pin = subject["pin"]
                if not isinstance(pin, dict) or set(pin) - {"binding", "field"} or not ID_RE.match(str(pin.get("binding", ""))):
                    raise MapError("%s.pin: must be {binding, field}" % w)
            impl = subject.get("implementation")
            if impl is not None:
                if not isinstance(impl, dict) or impl.get("state") not in ("built", "partial", "not-started", "unknown"):
                    raise MapError("%s.implementation.state: built, partial, not-started, or unknown" % w)
                _check_keys(impl, {"state", "evidence", "as_of", "note"}, "%s.implementation" % w)
            exc = subject.get("exception")
            if exc is not None:
                if not isinstance(exc, dict) or not isinstance(exc.get("text"), str):
                    raise MapError("%s.exception: must be {text, until?}" % w)
                _check_keys(exc, {"text", "until", "approved_by"}, "%s.exception" % w)
            for coord in ("x", "y"):
                if coord in subject and (not isinstance(subject[coord], (int, float)) or isinstance(subject[coord], bool)):
                    raise MapError("%s.%s: must be a number" % (w, coord))
            if kind == "connection":
                pass
    for index, conn in enumerate(manifest["connections"]):
        w = "manifest.connections[%d]" % index
        for end in ("from", "to"):
            target = _req(conn, end, "id", w)
            if ids.get(target) != "component":
                raise MapError("%s.%s: unknown component %r" % (w, end, target))
    phases = []
    phase_ids = set()
    lifecycle = manifest.get("lifecycle", {})
    if lifecycle:
        _check_keys(lifecycle, {"title", "description", "phases"}, "manifest.lifecycle")
        for index, phase in enumerate(_req(lifecycle, "phases", "list", "manifest.lifecycle")):
            w = "manifest.lifecycle.phases[%d]" % index
            _check_keys(phase, {"id", "title", "description", "subjects", "criterion"}, w)
            phases.append(_unique_manifest_id(phase, phase_ids, w))
            _req(phase, "title", "str", w)
            for sid in phase.get("subjects", []):
                if sid not in ids:
                    raise MapError("%s.subjects: unknown subject %r" % (w, sid))
    criteria = set()
    for index, crit in enumerate(manifest.get("acceptance", [])):
        w = "manifest.acceptance[%d]" % index
        _check_keys(crit, {"id", "title", "description", "subjects", "phase", "group"}, w)
        _unique_manifest_id(crit, criteria, w)
        _req(crit, "title", "str", w)
        for sid in crit.get("subjects", []):
            if sid not in ids:
                raise MapError("%s.subjects: unknown subject %r" % (w, sid))
        if "phase" in crit and crit["phase"] not in phases:
            raise MapError("%s.phase: unknown phase %r" % (w, crit["phase"]))
    for index, phase in enumerate(lifecycle.get("phases", []) if lifecycle else []):
        if "criterion" in phase and phase["criterion"] not in criteria:
            raise MapError("manifest.lifecycle.phases[%d].criterion: unknown criterion" % index)
    for _, subject in subjects_of(manifest).values():
        for item in _req(subject, "lineage", "list", "subject", optional=True) or []:
            if not isinstance(item, dict):
                raise MapError("lineage: must contain objects")
            _check_keys(item, {"stage", "subject", "expected", "note", "evidence"}, "lineage")
            if item.get("stage") not in ("source", "artifact", "installed", "config"):
                raise MapError("lineage.stage: source, artifact, installed, or config")
            if item.get("subject") not in ids:
                raise MapError("lineage.subject: unknown subject")
            for key in ("expected", "note"):
                _req(item, key, "str", "lineage", optional=True)
            _req(item, "evidence", "id", "lineage", optional=True)
    prerequisite_ids = set()
    for item in _req(manifest, "prerequisites", "list", "manifest", optional=True) or []:
        w = "manifest.prerequisites"
        if not isinstance(item, dict):
            raise MapError("prerequisites: must contain objects")
        _check_keys(item, {"id", "title", "producer", "resource", "phases", "baseline", "observation", "evidence", "expected_state", "owners", "next_check", "authorization", "max_age_seconds"}, w)
        _unique_manifest_id(item, prerequisite_ids, w)
        for key in ("title", "resource", "next_check"):
            _req(item, key, "str", w)
        if item.get("producer") not in ids:
            raise MapError("prerequisite.producer: unknown subject")
        phases_for_item = _req(item, "phases", "list", w)
        if not phases_for_item or any(p not in phase_ids for p in phases_for_item):
            raise MapError("prerequisite.phases: name declared lifecycle phases")
        if item.get("baseline") not in ("fresh", "migration", "both"):
            raise MapError("prerequisite.baseline: fresh, migration, or both")
        if "observation" in item:
            producer = subjects_of(manifest)[item["producer"]][1]
            if item["observation"] not in [o["id"] for o in producer.get("observe", [])]:
                raise MapError("prerequisite.observation: must belong to its producer")
        _req(item, "evidence", "id", w, optional=True)
        _req(item, "expected_state", "str", w, optional=True)
        _validate_owner_list(item.get("owners", []), w)
        if item.get("authorization", "unknown") not in ("authorized", "awaiting-authorization", "denied", "unknown", "not-required"):
            raise MapError("prerequisite.authorization: invalid state")
        if "max_age_seconds" in item and _req(item, "max_age_seconds", "int", w) <= 0:
            raise MapError("prerequisite.max_age_seconds: must be positive")
    gap_ids = set()
    for index, gap in enumerate(manifest.get("known_gaps", [])):
        w = "manifest.known_gaps[%d]" % index
        _check_keys(gap, {"id", "title", "detail", "subjects", "severity", "owners", "evidence"}, w)
        _unique_manifest_id(gap, gap_ids, w)
        _req(gap, "title", "str", w)
        if gap.get("severity", "medium") not in SEVERITIES:
            raise MapError("%s.severity: one of %s" % (w, ", ".join(SEVERITIES)))
        for sid in gap.get("subjects", []):
            if sid not in ids:
                raise MapError("%s.subjects: unknown subject %r" % (w, sid))
        _validate_owner_list(gap.get("owners", []), w)
    credential_ids = set()
    for index, cred in enumerate(manifest.get("credentials", [])):
        w = "manifest.credentials[%d]" % index
        _check_keys(cred, {"id", "title", "purpose", "owner", "expires", "rotation", "subjects", "kind", "note", "issuer", "not_before", "expiry_basis", "expected_expires", "observed_at", "evidence", "renewal_group", "renewal_owner", "restart_required", "full_window_seconds"}, w)
        _unique_manifest_id(cred, credential_ids, w)
        _req(cred, "title", "str", w)
        _req(cred, "purpose", "str", w)
        for key in ("issuer", "renewal_group"):
            _req(cred, key, "id", w, optional=True)
        for key in ("renewal_owner", "evidence"):
            _req(cred, key, "str", w, optional=True)
        if "expires" in cred and parse_iso(cred["expires"]) is None:
            raise MapError("%s.expires: must be an ISO-8601 timestamp" % w)
        for key in ("not_before", "expected_expires", "observed_at"):
            if key in cred and parse_iso(cred[key]) is None:
                raise MapError("%s.%s: must be an ISO-8601 timestamp" % (w, key))
        if cred.get("expiry_basis", "unknown") not in ("observed", "inferred", "unknown"):
            raise MapError("credential.expiry_basis: observed, inferred, or unknown")
        if "restart_required" in cred and cred["restart_required"] not in ("yes", "no", "unknown"):
            raise MapError("credential.restart_required: yes, no, or unknown")
        if "full_window_seconds" in cred and _req(cred, "full_window_seconds", "int", w) <= 0:
            raise MapError("credential.full_window_seconds: must be positive")
        for sid in cred.get("subjects", []):
            if sid not in ids:
                raise MapError("%s.subjects: unknown subject %r" % (w, sid))
    for cred in manifest.get("credentials", []):
        if "issuer" in cred and (cred["issuer"] not in credential_ids or cred["issuer"] == cred["id"]):
            raise MapError("credential.issuer: must name another credential")
    return ids


BINDING_FIELDS = {
    "aws.ec2_instance": {"instance_id": "str"},
    "aws.ec2_tagged_instances": {"tag_key": "str"},
    "aws.ec2_image": {"image_id": "str"},
    "aws.ecs_service": {"cluster": "str", "service": "str"},
    "aws.sqs_queue": {"queue_name": "str"},
    "aws.dynamodb_table": {"table": "str"},
    "aws.dynamodb_item": {"table": "str", "key": "dict", "attributes": "list"},
    "aws.s3_bucket": {"bucket": "str"},
    "aws.ecr_image": {"repository": "str", "tag": "str"},
    "git.revision": {"path": "str", "ref": "str"},
    "firstmate.task": {"task": "str"},
    "aws.lambda_configuration": {"function_name": "str"},
    "aws.scheduler_schedule": {"schedule_name": "str", "group_name": "str"},
    "aws.iam_role": {"role_name": "str"},
}
OPTIONAL_BINDING_FIELDS = {"state_map", "state_attribute", "pin", "label"}


def validate_bindings(bindings):
    if not isinstance(bindings, dict):
        raise MapError("bindings must be a JSON object")
    _check_keys(bindings, {"schema", "scope", "bindings", "firstmate_projects"}, "bindings")
    fprojects = bindings.get("firstmate_projects", [])
    if not isinstance(fprojects, list) or not all(isinstance(p, str) and re.match(r"^[A-Za-z0-9._-]{1,128}$", p) for p in fprojects):
        raise MapError("bindings.firstmate_projects must be a list of Firstmate project names")
    if bindings.get("schema") != BINDINGS_SCHEMA:
        raise MapError("bindings.schema must be %s" % BINDINGS_SCHEMA)
    scope = bindings.get("scope", {})
    _check_keys(scope, {"region", "account_label", "expected_account", "profile"}, "bindings.scope")
    if "region" in scope and not re.match(r"^[a-z]{2}(-gov)?-[a-z]+-\d$", str(scope["region"])):
        raise MapError("bindings.scope.region: not an AWS region name")
    if "expected_account" in scope and not re.match(r"^\d{12}$", str(scope["expected_account"])):
        raise MapError("bindings.scope.expected_account: 12 digits")
    if "profile" in scope and not re.match(r"^[A-Za-z0-9_.-]{0,64}$", str(scope["profile"])):
        raise MapError("bindings.scope.profile: invalid profile name")
    entries = bindings.get("bindings", {})
    if not isinstance(entries, dict):
        raise MapError("bindings.bindings must be an object")
    for name, entry in entries.items():
        if not ID_RE.match(name) or not isinstance(entry, dict):
            raise MapError("bindings.bindings.%s: invalid binding" % name)
    # Credential-material scan, excluding the deliberately private account id.
    scrubbed = dict(bindings)
    scrubbed["scope"] = {k: v for k, v in scope.items() if k != "expected_account"}
    _scan_forbidden(scrubbed, "bindings")


def binding_problem(adapter, entry):
    """Return a human reason the binding cannot drive the adapter, or None."""
    if entry is None:
        return "binding is missing from bindings.json"
    for field, kind in BINDING_FIELDS[adapter].items():
        if field == "ref" and adapter == "git.revision" and field not in entry:
            continue
        if field not in entry:
            return "binding lacks %r" % field
        value = entry[field]
        if kind == "str" and (not isinstance(value, str) or not value or len(value) > 512):
            return "binding field %r must be a non-empty string" % field
        if kind == "dict" and not isinstance(value, dict):
            return "binding field %r must be an object" % field
        if kind == "list" and (not isinstance(value, list) or not all(isinstance(v, str) for v in value)):
            return "binding field %r must be a list of names" % field
    for field in entry:
        if field not in BINDING_FIELDS[adapter] and field not in OPTIONAL_BINDING_FIELDS:
            return "binding has unexpected field %r" % field
    return None


# ---------------------------------------------------------------------------
# Project data access


def load_manifest(home, project):
    manifest = read_json(home.pdata(project, "manifest.json"))
    if manifest is None:
        raise MapError("no manifest at data/system-map/%s/manifest.json" % project)
    validate_manifest(manifest)
    if manifest["project"] != project:
        raise MapError("manifest.project %r does not match %r" % (manifest["project"], project))
    return manifest


def load_bindings(home, project):
    bindings = read_json(home.pdata(project, "bindings.json"), {"schema": BINDINGS_SCHEMA, "scope": {}, "bindings": {}})
    validate_bindings(bindings)
    return bindings


def bindings_digest(bindings):
    return hashlib.sha256(json.dumps(bindings, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()


def observation_binding_digest(observation, bindings):
    identity = {
        "adapter": observation["adapter"],
        "binding": observation["binding"],
        "entry": bindings.get("bindings", {}).get(observation["binding"]),
        "scope": bindings.get("scope", {}),
    }
    return bindings_digest(identity)


def subjects_of(manifest):
    out = {}
    for comp in manifest["components"]:
        out[comp["id"]] = ("component", comp)
    for conn in manifest["connections"]:
        out[conn["id"]] = ("connection", conn)
    return out


def load_evidence(home, project):
    records = []
    for path in sorted(glob.glob(home.pdata(project, "evidence", "*.json"))):
        try:
            record = read_json(path)
            validate_evidence(record)
        except (MapError, ValueError) as exc:
            records.append({"id": os.path.basename(path)[:-5], "invalid": str(exc)})
            continue
        records.append(record)
    return records


def record_evidence(home, project, record):
    target = home.pdata(project, "evidence", record["id"] + ".json")
    record = dict(record, received_at=precise_iso())
    try:
        write_json_atomic(target, record, create_only=True)
    except FileExistsError:
        raise MapError("evidence id %r already exists; records are append-only" % record["id"])


def validate_evidence(record, subject_ids=None, prerequisite_ids=None):
    if not isinstance(record, dict):
        raise MapError("evidence must be a JSON object")
    _scan_forbidden(record, "evidence")
    _check_keys(record, {
        "schema", "id", "subjects", "criterion", "phase", "run_id", "versions", "result",
        "recorded_at", "observed_at", "received_at", "summary", "historical", "provenance", "resource_identities", "prerequisites", "scope",
    }, "evidence")
    if record.get("schema") != EVIDENCE_SCHEMA:
        raise MapError("evidence.schema must be %s" % EVIDENCE_SCHEMA)
    _req(record, "id", "id", "evidence")
    subjects = _req(record, "subjects", "list", "evidence")
    if not subjects and not record.get("criterion") and not record.get("phase"):
        raise MapError("evidence: name at least one subject, criterion, or phase")
    if record.get("result") not in EVIDENCE_RESULTS:
        raise MapError("evidence.result must be pass, fail, or not-run")
    if parse_iso(record.get("recorded_at")) is None:
        raise MapError("evidence.recorded_at must be an ISO-8601 timestamp")
    if "observed_at" in record and parse_iso(record["observed_at"]) is None:
        raise MapError("evidence.observed_at must be an ISO-8601 timestamp")
    if "received_at" in record and parse_iso(record["received_at"]) is None:
        raise MapError("evidence.received_at must be an ISO-8601 timestamp")
    versions = record.get("versions", {})
    if not isinstance(versions, dict) or not all(isinstance(v, str) for v in versions.values()):
        raise MapError("evidence.versions must map subject ids to version strings")
    identities = record.get("resource_identities", {})
    if not isinstance(identities, dict) or not all(isinstance(v, str) and re.fullmatch(r"[0-9a-f]{64}", v) for v in identities.values()):
        raise MapError("evidence.resource_identities must map subject ids to binding digests")
    _req(record, "summary", "str", "evidence")
    prov = _req(record, "provenance", "dict", "evidence")
    _check_keys(prov, {"source", "kind", "path", "url", "by"}, "evidence.provenance")
    _req(prov, "source", "str", "evidence.provenance")
    if prov.get("kind", "receipt") not in PROVENANCE_KINDS:
        raise MapError("evidence.provenance.kind must be one of %s" % ", ".join(PROVENANCE_KINDS))
    if "url" in prov and not str(prov["url"]).startswith("https://"):
        raise MapError("evidence.provenance.url must be an https URL")
    if subject_ids is not None:
        for sid in list(subjects) + list(versions) + list(identities):
            if sid not in subject_ids:
                raise MapError("evidence names unknown subject %r" % sid)
    if "run_id" in record and not TASK_RE.match(str(record["run_id"])):
        raise MapError("evidence.run_id: invalid id")
    checks = _req(record, "prerequisites", "dict", "evidence", optional=True) or {}
    for pid, state in checks.items():
        if not ID_RE.fullmatch(pid) or state not in ("present", "absent", "denied", "unknown", "not-tested"):
            raise MapError("evidence.prerequisites: map prerequisite ids to present, absent, denied, unknown, or not-tested")
        if prerequisite_ids is not None and pid not in prerequisite_ids:
            raise MapError("evidence names unknown prerequisite %r" % pid)
    if checks:
        _req(record, "scope", "str", "evidence")


def load_annotations(home, project):
    return read_json(home.pdata(project, "annotations.json"), {"annotations": []}).get("annotations", [])


def load_task_bindings(home, project):
    out = []
    for path in sorted(glob.glob(home.pdata(project, "tasks", "*.json"))):
        record = read_json(path)
        if isinstance(record, dict):
            out.append(record)
    return out


def load_completions(home, project):
    out = []
    for path in sorted(glob.glob(home.pdata(project, "completions", "*.json"))):
        record = read_json(path)
        if isinstance(record, dict):
            out.append(record)
    return out


# ---------------------------------------------------------------------------
# Observation adapters


class Runner:
    """Bounded subprocess runner for adapters; injectable for tests via env."""

    def __init__(self, home, scope, deadline):
        self.home = home
        self.scope = scope
        self.deadline = deadline
        self.aws = os.environ.get("FM_SYSTEM_MAP_AWS") or shutil.which("aws")
        self.git = shutil.which("git")
        self.call_timeout = 25

    def remaining(self):
        return self.deadline - time.monotonic()

    def aws_call(self, service, operation, args):
        if not self.aws:
            return None, ("error", "aws CLI is not installed")
        budget = min(self.call_timeout, self.remaining())
        if budget <= 1:
            return None, ("unknown", "collection deadline reached before this read")
        cmd = [self.aws, service, operation] + list(args) + [
            "--output", "json", "--no-cli-pager",
            "--cli-connect-timeout", "5", "--cli-read-timeout", str(int(max(budget - 2, 3))),
        ]
        region = self.scope.get("region")
        if region:
            cmd += ["--region", region]
        if self.scope.get("profile"):
            cmd += ["--profile", self.scope["profile"]]
        env = dict(os.environ)
        env["AWS_PAGER"] = ""
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=budget, env=env, stdin=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            return None, ("error", "timed out after %ds" % int(budget))
        except OSError as exc:
            return None, ("error", "aws CLI could not start: %s" % exc.strerror)
        if proc.returncode != 0:
            return None, classify_aws_error(proc.stderr)
        try:
            return json.loads(proc.stdout or "{}"), None
        except ValueError:
            return None, ("error", "aws CLI returned unparseable output")


def classify_aws_error(stderr):
    text = stderr or ""
    if re.search(r"AccessDenied|UnauthorizedOperation|not authorized|Forbidden|\(403\)", text):
        return ("denied", redact(text))
    if re.search(r"NotFound|does not exist|NonExistentQueue|ResourceNotFound|NoSuchEntity|NoSuchBucket|\(404\)|RepositoryNotFound|ImageNotFound", text):
        return ("absent", redact(text))
    if re.search(r"Unable to locate credentials|ExpiredToken|token.*expired|InvalidClientTokenId|SSO", text, re.IGNORECASE):
        return ("error", "credentials unavailable or expired: " + redact(text, 200))
    return ("error", redact(text) or "aws CLI failed")


def _result(outcome, state=None, facts=None, version=None, error=None):
    if outcome == "absent" and state is None:
        state = "absent"
    return {"outcome": outcome, "state": state, "facts": facts or {}, "version": version, "error": error}


def adapt_ec2_instance(runner, b):
    data, err = runner.aws_call("ec2", "describe-instances", ["--instance-ids", b["instance_id"]])
    if err:
        return _result(err[0], error=err[1])
    instances = [i for r in data.get("Reservations", []) for i in r.get("Instances", [])]
    if not instances:
        return _result("absent", state="absent")
    inst = instances[0]
    state = inst.get("State", {}).get("Name", "unknown")
    facts = {"state": state, "type": inst.get("InstanceType"), "launched": inst.get("LaunchTime")}
    if state == "terminated":
        return _result("absent", facts=facts)
    norm = {"shutting-down": "stopping"}.get(state, state)
    return _result("ok", state=norm, facts=facts, version=inst.get("ImageId"))


def adapt_ec2_tagged(runner, b):
    data, err = runner.aws_call("ec2", "describe-instances", [
        "--filters", "Name=tag-key,Values=%s" % b["tag_key"],
        "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down",
    ])
    if err:
        return _result(err[0], error=err[1])
    counts = {}
    for res in data.get("Reservations", []):
        for inst in res.get("Instances", []):
            name = inst.get("State", {}).get("Name", "unknown")
            counts[name] = counts.get(name, 0) + 1
    total = sum(counts.values())
    # The count covers only instances carrying this tag key; it is not an
    # account-wide absence census, and the fact says so wherever it is shown.
    facts = {"instances": total, "by_state": counts, "scope": "only instances tagged with key %s" % b["tag_key"]}
    state = next((name for name in ("running", "pending", "stopping", "stopped", "shutting-down", "unknown") if counts.get(name)), "zero")
    return _result("ok", state=state, facts=facts)


def adapt_ec2_image(runner, b):
    data, err = runner.aws_call("ec2", "describe-images", ["--image-ids", b["image_id"]])
    if err:
        return _result(err[0], error=err[1])
    images = data.get("Images", [])
    if not images:
        return _result("absent", state="absent")
    img = images[0]
    return _result("ok", state=img.get("State", "unknown"), facts={"created": img.get("CreationDate")}, version=img.get("ImageId"))


def adapt_ecs_service(runner, b):
    data, err = runner.aws_call("ecs", "describe-services", ["--cluster", b["cluster"], "--services", b["service"]])
    if err:
        return _result(err[0], error=err[1])
    services = data.get("services", [])
    if not services or services[0].get("status") == "INACTIVE":
        return _result("absent", state="absent")
    svc = services[0]
    desired, running, pending = svc.get("desiredCount", 0), svc.get("runningCount", 0), svc.get("pendingCount", 0)
    if desired == running == pending == 0:
        state = "zero"
    elif running > 0 and running == desired:
        state = "running"
    else:
        state = "scaling"
    task_def = str(svc.get("taskDefinition", ""))
    version = task_def.rsplit("/", 1)[-1] if task_def else None
    return _result("ok", state=state, facts={"desired": desired, "running": running, "pending": pending}, version=version)


def adapt_sqs_queue(runner, b):
    data, err = runner.aws_call("sqs", "get-queue-url", ["--queue-name", b["queue_name"]])
    if err:
        return _result(err[0], error=err[1])
    url = data.get("QueueUrl")
    data, err = runner.aws_call("sqs", "get-queue-attributes", [
        "--queue-url", url, "--attribute-names", "ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible",
    ])
    if err:
        return _result(err[0], error=err[1])
    attrs = data.get("Attributes", {})
    visible = int(attrs.get("ApproximateNumberOfMessages", 0))
    hidden = int(attrs.get("ApproximateNumberOfMessagesNotVisible", 0))
    return _result("ok", state="empty" if visible + hidden == 0 else "holding", facts={"messages": visible, "in_flight": hidden})


def adapt_dynamodb_table(runner, b):
    data, err = runner.aws_call("dynamodb", "describe-table", ["--table-name", b["table"]])
    if err:
        return _result(err[0], error=err[1])
    table = data.get("Table", {})
    status = table.get("TableStatus", "unknown")
    return _result("ok", state="present" if status == "ACTIVE" else status.lower(), facts={"status": status, "items_approx": table.get("ItemCount")})


def _ddb_scalar(value):
    if not isinstance(value, dict) or len(value) != 1:
        return None
    kind, raw = next(iter(value.items()))
    if kind == "BOOL":
        return bool(raw)
    if kind == "N":
        return raw
    if kind == "S":
        return raw[:200]
    return None


def adapt_dynamodb_item(runner, b):
    names = [a for a in b["attributes"] if re.match(r"^[A-Za-z0-9_]{1,64}$", a)][:12]
    if not names:
        return _result("unknown", error="binding names no readable attributes")
    placeholders = {"#a%d" % i: name for i, name in enumerate(names)}
    data, err = runner.aws_call("dynamodb", "get-item", [
        "--table-name", b["table"], "--key", json.dumps(b["key"]), "--consistent-read",
        "--projection-expression", ",".join(placeholders),
        "--expression-attribute-names", json.dumps(placeholders),
    ])
    if err:
        return _result(err[0], error=err[1])
    item = data.get("Item")
    if not item:
        return _result("absent", state="absent")
    facts = {name: _ddb_scalar(item.get(name)) for name in names if name in item}
    state = "present"
    attr = b.get("state_attribute")
    if attr and attr in facts:
        mapping = b.get("state_map") or {}
        key = str(facts[attr]).lower()
        state = mapping.get(key, "%s=%s" % (attr, key))
    return _result("ok", state=state, facts=facts)


def adapt_s3_bucket(runner, b):
    _, err = runner.aws_call("s3api", "head-bucket", ["--bucket", b["bucket"]])
    if err:
        return _result(err[0], error=err[1])
    data, err = runner.aws_call("s3api", "get-bucket-versioning", ["--bucket", b["bucket"]])
    facts = {}
    if not err:
        facts["versioning"] = data.get("Status", "Disabled")
    return _result("ok", state="present", facts=facts)


def adapt_ecr_image(runner, b):
    ref = b["tag"]
    selector = ("imageDigest=%s" if ref.startswith("sha256:") else "imageTag=%s") % ref
    data, err = runner.aws_call("ecr", "describe-images", [
        "--repository-name", b["repository"], "--image-ids", selector,
    ])
    if err:
        return _result(err[0], error=err[1])
    details = data.get("imageDetails", [])
    if not details:
        return _result("absent", state="absent")
    image = details[0]
    return _result("ok", state="available", facts={"pushed": str(image.get("imagePushedAt", ""))}, version=image.get("imageDigest"))


def adapt_git_revision(runner, b):
    path = b["path"]
    if not os.path.isabs(path):
        path = os.path.join(runner.home.home, path)
    if not os.path.isdir(path):
        return _result("absent", state="absent", error="local clone not found")
    if not runner.git:
        return _result("error", error="git is not installed")
    ref = b.get("ref", "HEAD")
    if not re.match(r"^[A-Za-z0-9_./@{}-]{1,200}$", ref) or ref.startswith("-"):
        return _result("error", error="invalid ref in binding")
    try:
        proc = subprocess.run(
            [runner.git, "-C", path, "log", "-1", "--format=%H%x09%cI%x09%s", ref, "--"],
            capture_output=True, text=True, timeout=10, stdin=subprocess.DEVNULL,
        )
    except subprocess.TimeoutExpired:
        return _result("error", error="git read timed out")
    if proc.returncode != 0:
        return _result("error", error=redact(proc.stderr) or "git read failed")
    parts = proc.stdout.strip().split("\t", 2)
    if len(parts) < 2:
        return _result("error", error="git returned no revision")
    return _result("ok", state="present", facts={"committed": parts[1], "subject": (parts[2] if len(parts) > 2 else "")[:160]}, version=parts[0])


def adapt_firstmate_task(runner, b):
    task = b["task"]
    if not TASK_RE.match(task):
        return _result("error", error="invalid task id in binding")
    state_dir = os.environ.get("FM_STATE_OVERRIDE") or os.path.join(runner.home.home, "state")
    status_path = os.path.join(state_dir, task + ".status")
    meta_path = os.path.join(state_dir, task + ".meta")
    live = os.path.isfile(meta_path)
    last = None
    try:
        with open(status_path, "rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - 8192))
            lines = handle.read().decode("utf-8", "replace").strip().splitlines()
            last = lines[-1] if lines else None
    except FileNotFoundError:
        pass
    stamp = re.search(r"\[at=(\d+)\]", last or "")
    facts = {"live": live}
    if last:
        facts["last_event"] = last[:240]
    if stamp:
        facts["last_event_at"] = iso(int(stamp.group(1)))
    return _result("ok", state="live" if live else "ended", facts=facts)


def adapt_lambda_configuration(runner, b):
    # Filter at the CLI boundary too: environment variables, code URLs, and
    # payloads never enter the adapter result or persisted snapshot.
    data, err = runner.aws_call("lambda", "get-function-configuration", [
        "--function-name", b["function_name"], "--query",
        "{State:State,LastUpdateStatus:LastUpdateStatus,CodeSha256:CodeSha256,Runtime:Runtime,Timeout:Timeout,Role:Role}",
    ])
    if err:
        return _result(err[0], error=err[1])
    return _result("ok", state=str(data.get("State") or "unknown").lower(),
                   version=data.get("CodeSha256"), facts={
                       "update_status": data.get("LastUpdateStatus"), "runtime": data.get("Runtime"),
                       "timeout_seconds": data.get("Timeout"),
                       "role_identity": hashlib.sha256(str(data.get("Role", "")).encode()).hexdigest() if data.get("Role") else None,
                   })


def adapt_scheduler_schedule(runner, b):
    data, err = runner.aws_call("scheduler", "get-schedule", [
        "--name", b["schedule_name"], "--group-name", b["group_name"], "--query",
        "{State:State,ScheduleExpression:ScheduleExpression,ScheduleExpressionTimezone:ScheduleExpressionTimezone,LastModificationDate:LastModificationDate,TargetArn:Target.Arn,RoleArn:Target.RoleArn}",
    ])
    if err:
        return _result(err[0], error=err[1])
    facts = {"expression": data.get("ScheduleExpression"), "timezone": data.get("ScheduleExpressionTimezone"),
             "modified": str(data.get("LastModificationDate", ""))}
    for key in ("TargetArn", "RoleArn"):
        facts[key + "_identity"] = hashlib.sha256(str(data[key]).encode()).hexdigest() if data.get(key) else None
    version = hashlib.sha256(json.dumps(dict(facts, state=data.get("State")), sort_keys=True).encode()).hexdigest()
    return _result("ok", state=str(data.get("State") or "unknown").lower(), facts=facts, version=version)


def adapt_iam_role(runner, b):
    data, err = runner.aws_call("iam", "get-role", ["--role-name", b["role_name"], "--query",
                                                    "Role.{RoleId:RoleId,CreateDate:CreateDate,MaxSessionDuration:MaxSessionDuration}"])
    if err:
        return _result(err[0], error=err[1])
    return _result("ok", state="present", version=data.get("RoleId"), facts={
        "created": str(data.get("CreateDate", "")), "max_session_seconds": data.get("MaxSessionDuration"),
        "limit": "Role existence only; trust and effective permissions are not tested.",
    })


ADAPTERS = {
    "aws.ec2_instance": adapt_ec2_instance,
    "aws.ec2_tagged_instances": adapt_ec2_tagged,
    "aws.ec2_image": adapt_ec2_image,
    "aws.ecs_service": adapt_ecs_service,
    "aws.sqs_queue": adapt_sqs_queue,
    "aws.dynamodb_table": adapt_dynamodb_table,
    "aws.dynamodb_item": adapt_dynamodb_item,
    "aws.s3_bucket": adapt_s3_bucket,
    "aws.ecr_image": adapt_ecr_image,
    "git.revision": adapt_git_revision,
    "firstmate.task": adapt_firstmate_task,
    "aws.lambda_configuration": adapt_lambda_configuration,
    "aws.scheduler_schedule": adapt_scheduler_schedule,
    "aws.iam_role": adapt_iam_role,
}


# ---------------------------------------------------------------------------
# Collection


def verify_scope(runner, scope):
    """Return (verified, error). Verified is None when no account is pinned."""
    expected = scope.get("expected_account")
    if not expected:
        return None, None
    data, err = runner.aws_call("sts", "get-caller-identity", [])
    if err:
        return False, "account scope could not be verified: %s" % err[1]
    if str(data.get("Account")) != str(expected):
        return False, "credentials resolve to a different account than the bound scope; AWS reads skipped"
    return True, None


def ingest_inbox(home, project, manifest):
    """Validate and move dropped receipts from the inbox into evidence/."""
    inbox = home.pdata(project, "inbox")
    ids = set(subjects_of(manifest))
    moved, rejected = [], []
    for path in sorted(glob.glob(os.path.join(inbox, "*.json"))):
        name = os.path.basename(path)
        try:
            record = read_json(path)
            validate_evidence(record, ids, {p["id"] for p in manifest.get("prerequisites", [])})
            record_evidence(home, project, record)
            os.unlink(path)
            moved.append(record["id"])
        except (MapError, ValueError, OSError) as exc:
            rejected.append({"file": name, "error": str(exc)[:300]})
            os.makedirs(os.path.join(inbox, "rejected"), exist_ok=True)
            with contextlib.suppress(OSError):
                os.replace(path, os.path.join(inbox, "rejected", name))
    return moved, rejected


def collect(home, cfg, project, reason="manual"):
    """Run every observation once and publish the snapshot atomically.

    Returns the published snapshot, or a dict with status "busy" when another
    collection holds the lock. Health is always recorded; a failure keeps the
    previous snapshot and the separate last-success records untouched.
    """
    lock_path = home.pstate(project, ".collect.lock")
    with file_lock(lock_path, blocking=False) as held:
        if not held:
            return {"status": "busy"}
        started = now_ts()
        health_path = home.pstate(project, "health.json")
        health = read_json(health_path, {}) or {}
        health["last_attempt_at"] = iso(started)
        health["last_reason"] = reason
        try:
            snapshot = _collect_locked(home, cfg, project, started)
        except Exception as exc:  # noqa: BLE001 - recorded as collector failure
            health["last_status"] = "failed"
            health["last_error"] = redact("%s: %s" % (type(exc).__name__, exc))
            health["consecutive_failures"] = int(health.get("consecutive_failures", 0)) + 1
            health["last_duration_ms"] = int((now_ts() - started) * 1000)
            write_json_atomic(health_path, health)
            update_discrepancies(home, cfg, project)
            raise
        health["last_status"] = snapshot["collector"]["status"]
        health["last_error"] = snapshot["collector"].get("error")
        health["last_duration_ms"] = int((now_ts() - started) * 1000)
        health["consecutive_failures"] = 0
        if snapshot["collector"]["total_observations"] > snapshot["collector"]["failed_observations"]:
            health["last_success_at"] = snapshot["finished_at"]
        write_json_atomic(health_path, health)
        update_discrepancies(home, cfg, project)
        return snapshot


def _collect_locked(home, cfg, project, started):
    manifest = load_manifest(home, project)
    bindings = load_bindings(home, project)
    digest = bindings_digest(bindings)
    moved, rejected = ingest_inbox(home, project, manifest)
    scope = dict(bindings.get("scope", {}))
    deadline = time.monotonic() + cfg["collect_timeout"]
    runner = Runner(home, scope, deadline)
    needs_aws = any(o["adapter"].startswith("aws.") for _, s in subjects_of(manifest).values() for o in s.get("observe", []))
    verified, scope_error = (None, None)
    if needs_aws:
        verified, scope_error = verify_scope(runner, scope)
    public_scope = {"region": scope.get("region"), "account_label": scope.get("account_label"), "account_verified": verified}
    # A test or preview run that substitutes a stand-in for the AWS CLI must say
    # so, so its output can never be mistaken for a live read.
    fixture = os.environ.get("FM_SYSTEM_MAP_FIXTURE") == "1"
    if fixture:
        public_scope["fixture"] = True
    observations = {}
    last_path = home.pstate(project, "last-success.json")
    last_success = {key: value for key, value in (read_json(last_path, {}) or {}).items()
                    if value.get("manifest_revision") == manifest["revision"] and value.get("bindings_digest") == digest}
    entries = bindings.get("bindings", {})
    for sid, (kind, subject) in subjects_of(manifest).items():
        for obs in subject.get("observe", []):
            adapter = obs["adapter"]
            entry = entries.get(obs["binding"])
            t0 = time.monotonic()
            problem = binding_problem(adapter, entry)
            if problem:
                result = _result("unknown", error=problem)
                result["binding_missing"] = True
            elif adapter.startswith("aws.") and verified is False:
                result = _result("unknown", error=scope_error)
            else:
                try:
                    result = ADAPTERS[adapter](runner, entry)
                except Exception as exc:  # noqa: BLE001 - adapter bug must not abort the sweep
                    result = _result("error", error=redact("adapter failed: %s" % exc))
            result.update({
                "id": obs["id"], "subject": sid, "subject_type": kind, "adapter": adapter,
                "role": obs.get("role", "runtime"), "binding": obs["binding"],
                "binding_digest": observation_binding_digest(obs, bindings),
                "checked_at": iso(), "duration_ms": int((time.monotonic() - t0) * 1000),
                "scope": public_scope if adapter.startswith("aws.") else {"kind": "local"},
            })
            if adapter.startswith("aws.") and isinstance(entry, dict) and entry.get("label"):
                result["resource_label"] = str(entry["label"])[:80]
            observations[obs["id"]] = result
            if result["outcome"] in SUCCESS_OUTCOMES:
                last_success[obs["id"]] = dict(result, manifest_revision=manifest["revision"], bindings_digest=digest)
    outcomes = [o["outcome"] for o in observations.values()]
    failed = [o for o in outcomes if o not in SUCCESS_OUTCOMES]
    if not outcomes:
        status = "ok"
    elif len(failed) == len(outcomes):
        status = "failed"
    elif failed:
        status = "partial"
    else:
        status = "ok"
    snapshot = {
        "schema": SNAPSHOT_SCHEMA,
        "project": project,
        "manifest_revision": manifest["revision"],
        "bindings_digest": digest,
        "started_at": iso(started),
        "finished_at": iso(),
        "collector": {"status": status, "error": scope_error, "failed_observations": len(failed), "total_observations": len(outcomes), "fixture": fixture},
        "scope": public_scope,
        "observations": observations,
        "ingested_evidence": moved,
        "rejected_receipts": rejected,
    }
    # last-success first: a crash between the two writes then loses only the
    # newest snapshot, never a successful read the snapshot already reported.
    write_json_atomic(last_path, last_success)
    write_json_atomic(home.pstate(project, "snapshot.json"), snapshot)
    return snapshot


# ---------------------------------------------------------------------------
# Derived view


def _subject_version(subject, observations):
    vf = subject.get("version_from")
    if not vf:
        return None, "untracked"
    obs = observations.get(vf)
    if not obs or obs["outcome"] != "ok" or not obs.get("version"):
        return None, "unknown"
    return obs["version"], "observed"


def _pin_value(subject, bindings):
    pin = subject.get("pin")
    if not pin:
        return None
    entry = bindings.get("bindings", {}).get(pin["binding"], {})
    value = entry.get(pin.get("field", "pin")) if isinstance(entry, dict) else None
    return value if isinstance(value, str) else None


def evidence_qualifies(record, subject_id, current_version, tracked, resource_identity, deployment_status):
    """Return (qualifies, reason)."""
    if record.get("historical"):
        return False, "historical"
    rv = record.get("versions", {}).get(subject_id)
    if tracked == "untracked":
        return True, "not version-bound"
    if deployment_status != "deployed":
        return False, "deployment %s" % deployment_status
    if current_version is None:
        return False, "current version unobserved"
    if rv is None:
        return False, "record names no version"
    if rv != current_version:
        return False, "older or different version"
    if not resource_identity or record.get("resource_identities", {}).get(subject_id) != resource_identity:
        return False, "different or unspecified resource identity"
    return True, "applies to the current deployment"


def _runtime_status(subject, observations, expected_mode):
    runtime = [o for o in (observations.get(ob["id"]) for ob in subject.get("observe", [])) if o and o.get("role") == "runtime"]
    intended = subject.get("intended", {}).get(expected_mode)
    if not runtime:
        return {"status": "unobserved" if subject.get("observe") else "not-observed", "observed": None, "intended": intended}
    outcomes = [o["outcome"] for o in runtime]
    states = sorted({o["state"] for o in runtime if o["outcome"] in SUCCESS_OUTCOMES and o.get("state")})
    observed = ", ".join(states) if states else None
    if all(o in SUCCESS_OUTCOMES for o in outcomes):
        if intended is None:
            status = "observed"
        elif states == [intended]:
            status = "as-intended"
        else:
            status = "deviation"
    elif any(o in SUCCESS_OUTCOMES for o in outcomes):
        status = "partial"
    elif "denied" in outcomes:
        status = "denied"
    elif "error" in outcomes:
        status = "error"
    else:
        status = "unknown"
    return {"status": status, "observed": observed, "intended": intended}


def live_verification(evidence, sid, version, vstate, completed_at, resource_identity, deployment_status):
    qualifying = [r for r in evidence if not r.get("invalid") and r["result"] in ("pass", "fail")
                  and (sid in r.get("subjects", []) or sid in r.get("versions", {}))
                  and evidence_qualifies(r, sid, version, vstate, resource_identity, deployment_status)[0]
                  and (parse_iso(r["recorded_at"]) or 0) > completed_at
                  and (parse_iso(r.get("received_at")) or 0) > completed_at]
    if not qualifying:
        return False
    latest = max(qualifying, key=lambda r: (parse_iso(r["recorded_at"]) or 0, r["result"] == "fail"))
    if latest["result"] == "fail":
        return False
    return "unversioned" if vstate == "untracked" else True


def prerequisite_view(manifest, bindings, subjects, evidence, observations, interval):
    records = {r["id"]: r for r in evidence if not r.get("invalid")}
    items = []
    for item in manifest.get("prerequisites", []):
        subject = subjects[item["producer"]]
        obs = observations.get(item.get("observation"))
        rec = records.get(item.get("evidence"))
        state, coverage, checked, scope, provenance, detail = "unknown", "uncovered", None, None, None, "No observation or owner receipt declared."
        if item.get("observation"):
            coverage = "observed" if obs else "uncollected"
            detail = "Observation has not been collected for the current manifest and bindings."
        if obs:
            state = "present" if obs["outcome"] == "ok" else obs["outcome"]
            checked, scope = obs.get("checked_at"), obs.get("scope")
            provenance = {"kind": "collector", "source": obs["adapter"]}
            detail = obs.get("error") or "Observed state: %s" % obs.get("state")
            if state == "present" and item.get("expected_state") and obs.get("state") != item["expected_state"]:
                state = "mismatch"
        elif rec and item["id"] in rec.get("prerequisites", {}):
            identity = subject["resource_identity"]
            if item.get("observation"):
                producer = subjects_of(manifest)[item["producer"]][1]
                declared = next(o for o in producer.get("observe", []) if o["id"] == item["observation"])
                entry = bindings.get("bindings", {}).get(declared["binding"])
                identity = observation_binding_digest(declared, bindings) if not binding_problem(declared["adapter"], entry) else None
            scope = rec.get("scope")
            provenance, detail = rec["provenance"], rec["summary"]
            if identity and rec.get("resource_identities", {}).get(item["producer"]) == identity:
                state = rec["prerequisites"][item["id"]]
                coverage, checked = "imported", rec.get("observed_at", rec["recorded_at"])
                if rec.get("historical"):
                    state = "stale"
            else:
                coverage, detail = "missing-evidence", "Named receipt has no assessment for the current bound resource."
        elif item.get("evidence"):
            coverage, detail = "missing-evidence", "Named receipt is missing or contains no assessment of this prerequisite."
        observed_state = state
        age = now_ts() - (parse_iso(checked) or 0) if checked else None
        if age is not None and age > item.get("max_age_seconds", interval * 2):
            state = "stale"
        items.append(dict(item, state=state, observed_state=observed_state, coverage=coverage, checked_at=checked,
                          scope=scope, provenance=provenance, detail=detail,
                          authorization=item.get("authorization", "unknown"),
                          owners=item.get("owners") or subject["owners"], layers=subject["layers"], lineage=subject.get("lineage", [])))
    phases = []
    for phase in manifest.get("lifecycle", {}).get("phases", []):
        checks = [p for p in items if phase["id"] in p["phases"]]
        phases.append(dict(phase, prerequisites=[p["id"] for p in checks], coverage="declared" if checks else "uncovered"))
    return {"prerequisites": items, "phases": phases}


def credential_view(manifest):
    credentials = {c["id"]: c for c in manifest.get("credentials", [])}
    result = []
    for cred in credentials.values():
        chain, current, seen = [], cred, set()
        while current and current["id"] not in seen:
            seen.add(current["id"])
            chain.append(current)
            current = credentials.get(current.get("issuer"))
        cycle = current is not None
        known = [parse_iso(c.get("expires")) for c in chain]
        issuer_complete = all(c.get("kind") != "tls-leaf" or c.get("issuer") for c in chain)
        validity_known = all(c.get("kind") not in ("tls-leaf", "ca") or parse_iso(c.get("not_before")) is not None for c in chain)
        observed = not cycle and issuer_complete and validity_known and all(t is not None and c.get("expiry_basis") == "observed" for c, t in zip(chain, known))
        window = cred.get("full_window_seconds")
        safe = min(known) - window if observed and window else None
        valid_from = max([parse_iso(c.get("not_before")) or 0 for c in chain])
        feasibility = "unknown"
        if safe is not None:
            feasibility = "fits" if valid_from <= now_ts() < safe else "does-not-fit"
        result.append(dict(cred, issuer_chain=[c["id"] for c in chain[1:]], issuer_cycle=cycle,
                           remaining_seconds=int(min(known) - now_ts()) if observed else None,
                           latest_safe_start=iso(safe) if safe is not None else None,
                           full_window=feasibility))
    return result


def build_view(home, cfg, project):
    manifest = load_manifest(home, project)
    bindings = load_bindings(home, project)
    digest = bindings_digest(bindings)
    snapshot = read_json(home.pstate(project, "snapshot.json"))
    last_success = read_json(home.pstate(project, "last-success.json"), {}) or {}
    health = read_json(home.pstate(project, "health.json"), {}) or {}
    snapshot_current = bool(snapshot and snapshot.get("manifest_revision") == manifest["revision"] and snapshot.get("bindings_digest") == digest)
    observations = snapshot.get("observations", {}) if snapshot_current else {}
    last_success = {key: value for key, value in last_success.items()
                    if value.get("manifest_revision") == manifest["revision"] and value.get("bindings_digest") == digest} if snapshot_current else {}
    evidence = load_evidence(home, project)
    annotations = load_annotations(home, project)
    task_bindings = load_task_bindings(home, project)
    completions = load_completions(home, project)
    ledger = read_json(home.pdata(project, "discrepancies.json"), {"discrepancies": {}}).get("discrepancies", {})
    requests = read_json(home.pstate(project, "requests.json"), {"requests": {}}).get("requests", {})
    expected_mode = manifest["expected_mode"]
    subjects = {}
    for sid, (kind, subject) in subjects_of(manifest).items():
        version, vstate = _subject_version(subject, observations)
        version_observation = observations.get(subject.get("version_from"))
        resource_identity = version_observation.get("binding_digest") if version_observation else None
        pin = _pin_value(subject, bindings)
        pin_missing = bool(subject.get("pin") and not pin)
        # Implementation layer
        comps = [c for c in completions if sid in c.get("subjects", [])]
        live_tasks = [t for t in task_bindings if sid in t.get("subjects", []) and t["task"] not in {c["task"] for c in comps}]
        declared = subject.get("implementation")
        if comps:
            impl = {"status": "complete", "detail": "landed via %s" % ", ".join(c["task"] for c in comps), "completions": comps}
        elif live_tasks:
            impl = {"status": "in-progress", "detail": "bound to %s" % ", ".join(t["task"] for t in live_tasks)}
        elif declared:
            impl = {"status": declared["state"], "detail": declared.get("note", "declared in the intended design"), "evidence": declared.get("evidence"), "as_of": declared.get("as_of")}
        else:
            impl = {"status": "unknown", "detail": "no completion record or declaration"}
        # Deployment layer
        if not subject.get("version_from"):
            deploy = {"status": "untracked", "detail": "no version observation declared"}
        elif vstate == "unknown":
            vobs = observations.get(subject["version_from"])
            if vobs and vobs["outcome"] == "absent":
                deploy = {"status": "absent", "detail": "the versioned resource was not found"}
            else:
                deploy = {"status": "unknown", "detail": (vobs or {}).get("error") or "version not observed yet"}
        elif pin_missing:
            deploy = {"status": "unknown", "detail": "declared pin has no binding value"}
        elif pin and version != pin:
            deploy = {"status": "mismatch", "detail": "observed %s, pinned %s" % (version, pin), "version": version, "pin": pin}
        else:
            deploy = {"status": "deployed", "detail": "observed %s%s" % (version, " (matches pin)" if pin else ""), "version": version, "pin": pin}
        if pin_missing:
            deploy["pin_missing"] = True
        runtime = _runtime_status(subject, observations, expected_mode)
        # Proof layer
        recs = [r for r in evidence if not r.get("invalid") and (sid in r.get("subjects", []) or sid in r.get("versions", {}))]
        qualifying, stale = [], []
        for rec in recs:
            ok, why = evidence_qualifies(rec, sid, version, vstate, resource_identity, deploy["status"])
            (qualifying if ok else stale).append(dict(rec, qualification=why))
        # On a timestamp tie the failure wins, so a simultaneous pass never hides it.
        qualifying.sort(key=lambda r: (parse_iso(r["recorded_at"]) or 0, r["result"] == "fail"))
        decisive = [r for r in qualifying if r["result"] in ("pass", "fail")]
        if decisive:
            latest = decisive[-1]
            if latest["result"] == "fail":
                status = "failed"
            else:
                # A subject without a version source can show a pass, but never
                # version-bound proof: deployments can change under it unseen.
                status = "proven" if vstate == "observed" else "unversioned"
            proof = {"status": status, "detail": latest["summary"], "record": latest["id"], "at": latest["recorded_at"]}
            if vstate == "untracked":
                proof["detail"] += " (not version-bound: this subject declares no version source)"
        elif vstate == "unknown" and recs:
            proof = {"status": "unknown", "detail": "current version is unobserved, so no record can qualify"}
        elif any(r["result"] in ("pass", "fail") for r in stale):
            reasons = sorted({r["qualification"] for r in stale if r["result"] in ("pass", "fail")})
            proof = {"status": "stale", "detail": "pass/fail records do not apply to the current deployment (%s)" % "; ".join(reasons)}
        else:
            proof = {"status": "not-demonstrated", "detail": "no qualifying evidence"}
        # Completion verification: implementation-complete is not live-verified.
        live_verified = None
        if comps:
            completed_at = max(parse_iso(c["completed_at"]) or 0 for c in comps)
            live_verified = live_verification(evidence, sid, version, vstate, completed_at, resource_identity, deploy["status"])
        obs_list = []
        for ob in subject.get("observe", []):
            cur = observations.get(ob["id"])
            obs_list.append({
                "id": ob["id"], "adapter": ob["adapter"], "role": ob.get("role", "runtime"),
                "current": cur, "last_success": last_success.get(ob["id"]) if (not cur or cur["outcome"] not in SUCCESS_OUTCOMES) else None,
            })
        subjects[sid] = {
            "id": sid, "type": kind, "title": subject["title"], "kind": subject.get("kind"),
            "group": subject.get("group"), "description": subject.get("description", ""),
            "owners": subject.get("owners", []), "intended": subject.get("intended", {}),
            "exception": subject.get("exception"), "from": subject.get("from"), "to": subject.get("to"),
            "x": subject.get("x"), "y": subject.get("y"), "notes": subject.get("notes"),
            "version": version, "version_state": vstate, "resource_identity": resource_identity,
            "layers": {"implementation": impl, "deployment": deploy, "runtime": runtime, "proof": proof},
            "live_verified": live_verified,
            "observations": obs_list,
            "evidence": [dict(r) for r in qualifying] + stale,
            "tasks": [t for t in task_bindings if sid in t.get("subjects", [])],
            "annotations": [a for a in annotations if a.get("target") == sid],
            "credentials": [c for c in manifest.get("credentials", []) if sid in c.get("subjects", [])],
            "discrepancies": sorted(k for k, d in ledger.items() if d.get("subject") == sid and d.get("status") == "open"),
        }
    acceptance = []
    for crit in manifest.get("acceptance", []):
        recs = [r for r in evidence if not r.get("invalid") and r.get("criterion") == crit["id"]]
        quals, olds = [], []
        for rec in recs:
            ok = not rec.get("historical")
            why = "applies to the current version"
            for sid in crit.get("subjects", []):
                s = subjects.get(sid)
                if not s:
                    ok, why = False, "subject %s missing" % sid
                    break
                subject_ok, why = evidence_qualifies(rec, sid, s["version"], s["version_state"], s["resource_identity"], s["layers"]["deployment"]["status"])
                if not subject_ok:
                    ok = False
                    why = "%s: %s" % (sid, why)
                    break
            if rec.get("historical"):
                why = "historical"
            (quals if ok else olds).append(dict(rec, qualification=why))
        decisive = sorted([r for r in quals if r["result"] in ("pass", "fail")], key=lambda r: (parse_iso(r["recorded_at"]) or 0, r["result"] == "fail"))
        untracked = [sid for sid in crit.get("subjects", []) if subjects.get(sid, {}).get("version_state") == "untracked"]
        if decisive:
            status = "passed" if decisive[-1]["result"] == "pass" else "failed"
            if status == "passed" and untracked:
                status = "unversioned"
        elif any(r["result"] in ("pass", "fail") for r in olds):
            status = "stale"
        else:
            status = "not-demonstrated"
        mismatched = [sid for sid in crit.get("subjects", []) if subjects.get(sid, {}).get("layers", {}).get("deployment", {}).get("status") == "mismatch"]
        unresolved_pins = [sid for sid in crit.get("subjects", []) if subjects.get(sid, {}).get("layers", {}).get("deployment", {}).get("pin_missing")]
        if mismatched:
            status = "failed"
        acceptance.append(dict(crit, status=status, evidence=quals + olds, unversioned_subjects=untracked, deployment_mismatches=mismatched, unresolved_pins=unresolved_pins))
    for sid, (_, subject) in subjects_of(manifest).items():
        lineage = []
        for item in subject.get("lineage", []):
            target = subjects[item["subject"]]
            state = "unknown" if target["version_state"] != "observed" else "mismatch" if item.get("expected") and item["expected"] != target["version"] else "observed"
            rec = next((r for r in evidence if r["id"] == item.get("evidence") and not r.get("invalid")), None)
            reported = rec.get("versions", {}).get(item["subject"]) if rec else None
            if reported and state == "unknown":
                state = "stale" if rec.get("historical") else "reported"
                if item.get("expected") and reported != item["expected"]:
                    state = "mismatch"
            lineage.append(dict(item, status=state, version=target["version"], reported_version=reported,
                                provenance=rec.get("provenance") if rec else None, recorded_at=rec.get("recorded_at") if rec else None,
                                resource_identity=target["resource_identity"],
                                observations=target["observations"], layers=target["layers"]))
        subjects[sid]["lineage"] = lineage
    timeline = build_timeline(manifest, evidence)
    activity = activity_view(home)
    interval = cfg["active_interval"] if activity["active"] else cfg["idle_interval"]
    last_ok = parse_iso(health.get("last_success_at"))
    collector = dict(health)
    collector["stale"] = not snapshot_current or last_ok is None or (now_ts() - last_ok) > interval + cfg["active_interval"]
    collector["activity"] = activity
    collector["interval_seconds"] = interval
    collector["snapshot_status"] = snapshot.get("collector", {}).get("status") if snapshot_current else None
    collector["fixture"] = bool((snapshot or {}).get("collector", {}).get("fixture"))
    collector["snapshot_at"] = (snapshot or {}).get("finished_at")
    collector["manifest_revision_at_snapshot"] = (snapshot or {}).get("manifest_revision")
    return {
        "schema": VIEW_SCHEMA,
        "project": project,
        "generated_at": iso(),
        "manifest": {k: manifest.get(k) for k in ("title", "description", "revision", "updated_at", "modes", "expected_mode", "groups", "lifecycle", "known_gaps", "credentials")},
        "scope": (snapshot.get("scope") if snapshot_current else None) or {"region": bindings.get("scope", {}).get("region"), "account_label": bindings.get("scope", {}).get("account_label"), "account_verified": None},
        "collector": collector,
        "subjects": subjects,
        "order": {"components": [c["id"] for c in manifest["components"]], "connections": [c["id"] for c in manifest["connections"]]},
        "acceptance": acceptance,
        "timeline": timeline,
        "readiness": prerequisite_view(manifest, bindings, subjects, evidence, observations, interval),
        "credentials": credential_view(manifest),
        "discrepancies": sorted(ledger.values(), key=lambda d: (d.get("status") != "open", SEVERITIES.index(d.get("severity", "info")), d.get("first_seen", ""))),
        "requests": requests,
        "annotations": annotations,
        "invalid_evidence": [r for r in evidence if r.get("invalid")],
        "config": {k: cfg[k] for k in DEFAULTS},
    }


def build_timeline(manifest, evidence):
    phases = (manifest.get("lifecycle") or {}).get("phases", [])
    runs = {}
    for rec in evidence:
        if rec.get("invalid") or not rec.get("run_id"):
            continue
        run = runs.setdefault(rec["run_id"], {"run_id": rec["run_id"], "cells": {}, "first": rec["recorded_at"], "last": rec["recorded_at"], "historical": False, "notes": []})
        if parse_iso(rec["recorded_at"]) < parse_iso(run["first"]):
            run["first"] = rec["recorded_at"]
        if parse_iso(rec["recorded_at"]) > parse_iso(run["last"]):
            run["last"] = rec["recorded_at"]
        run["historical"] = run["historical"] or bool(rec.get("historical"))
        phase = rec.get("phase")
        if phase:
            prev = run["cells"].get(phase)
            if prev is None or (parse_iso(rec["recorded_at"]), rec["result"] == "fail") > (parse_iso(prev["recorded_at"]), prev["result"] == "fail"):
                run["cells"][phase] = {"result": rec["result"], "summary": rec["summary"], "record": rec["id"], "recorded_at": rec["recorded_at"]}
        else:
            run["notes"].append({"summary": rec["summary"], "record": rec["id"], "result": rec["result"]})
    ordered = sorted(runs.values(), key=lambda r: parse_iso(r["last"]), reverse=True)
    return {"phases": [{"id": p["id"], "title": p["title"], "description": p.get("description", ""), "criterion": p.get("criterion")} for p in phases], "runs": ordered}


# ---------------------------------------------------------------------------
# Discrepancies and supervisor requests


def discrepancy_id(project, kind, subject, key):
    digest = hashlib.sha256(("%s|%s|%s|%s" % (project, kind, subject, key)).encode()).hexdigest()
    return "d-" + digest[:10]


def derive_discrepancies(home, cfg, project):
    """Return (found, resolvable_subjects): current discrepancies, and which
    subjects were observed well enough this round to resolve old ones."""
    view = build_view(home, cfg, project)
    manifest = load_manifest(home, project)
    found = {}
    observed_ok = set()

    def add(kind, subject, key, title, detail, severity, owners=None):
        did = discrepancy_id(project, kind, subject, key)
        found[did] = {"id": did, "kind": kind, "subject": subject, "title": title, "detail": detail, "severity": severity, "owners": owners or []}

    for sid, s in view["subjects"].items():
        owners = s["owners"]
        rt = s["layers"]["runtime"]
        obs = [o["current"] for o in s["observations"] if o["current"]]
        if obs and all(o["outcome"] in SUCCESS_OUTCOMES for o in obs):
            observed_ok.add(sid)
        if rt["status"] == "deviation":
            exc = s.get("exception")
            add("runtime", sid, "intended=%s" % rt["intended"],
                "%s is %s; intended %s while %s" % (s["title"], rt["observed"], rt["intended"], manifest["expected_mode"]),
                ("Accepted exception: %s" % exc["text"]) if exc else "Observed runtime state differs from the intended design.",
                "low" if exc else "high", owners)
        dep = s["layers"]["deployment"]
        if dep["status"] == "mismatch":
            add("version", sid, "pin=%s" % dep.get("pin"), "%s runs a version other than its pin" % s["title"], dep["detail"], "high", owners)
        elif dep.get("pin_missing"):
            add("version", sid, "pin-missing", "%s has no value for its declared pin" % s["title"], "Declared pin has no binding value.", "high", owners)
        for o in s["observations"]:
            cur = o["current"]
            if not cur:
                continue
            if cur.get("binding_missing"):
                add("binding", sid, o["id"], "%s observation %s has no usable binding" % (s["title"], o["id"]), cur.get("error") or "", "medium", owners)
            elif cur["outcome"] in ("denied", "error"):
                add("observation", sid, "%s:%s" % (o["id"], cur["outcome"]), "%s observation %s %s" % (s["title"], o["id"], "was denied" if cur["outcome"] == "denied" else "failed"), cur.get("error") or "", "medium", owners)
        if s["layers"]["proof"]["status"] == "stale":
            add("proof", sid, "stale", "%s has no proof for its current deployment" % s["title"], s["layers"]["proof"]["detail"], "low", owners)
        if s["live_verified"] == "unversioned":
            add("completion", sid, "unversioned", "%s is implementation-complete with only unversioned proof" % s["title"], "Passing evidence exists, but the subject declares no version source, so it cannot be live-verified across deployments.", "low", owners)
        if s["live_verified"] is False:
            add("completion", sid, "unverified", "%s is implementation-complete but not live-verified" % s["title"], "A bound task landed; no passing evidence at the current version was recorded after it.", "medium", owners)
    for gap in manifest.get("known_gaps", []):
        subject = (gap.get("subjects") or ["design"])[0]
        add("gap", subject, gap["id"], gap["title"], gap.get("detail", ""), gap.get("severity", "medium"), gap.get("owners", []))
    for cred in manifest.get("credentials", []):
        expires = parse_iso(cred.get("expires"))
        if expires is None:
            continue
        left = expires - now_ts()
        subject = (cred.get("subjects") or ["credentials"])[0]
        if left <= 0:
            add("credential", subject, cred["id"] + ":expired", "%s has expired" % cred["title"], "Expired %s. Purpose: %s" % (cred["expires"], cred["purpose"]), "high")
        elif left <= 7 * 86400:
            add("credential", subject, cred["id"] + ":expiring", "%s expires within 7 days" % cred["title"], "Expires %s. Purpose: %s" % (cred["expires"], cred["purpose"]), "medium")
    fprojects = set(load_bindings(home, project).get("firstmate_projects", []))
    if fprojects:
        bound = {t["task"] for t in load_task_bindings(home, project)}
        for task, values in task_records(home):
            if task_project_name(values) in fprojects and task not in bound:
                add("coverage", "coverage", task, "Task %s changes %s but has no map reference" % (task, task_project_name(values)),
                    "Bind it with bin/fm-system-map.sh bind %s --project %s --subject <ids>, or --no-subjects --note <why>." % (task, project), "medium")
    health = view["collector"]
    if health.get("last_status") == "failed":
        add("collector", "collector", "failed", "The map collector failed its last run", health.get("last_error") or "", "medium")
    elif health.get("stale") and health.get("last_attempt_at"):
        add("collector", "collector", "stale", "Map observations are stale", "No successful collection inside the expected interval.", "medium")
    return found, observed_ok


def update_discrepancies(home, cfg, project):
    """Merge current discrepancies into the durable ledger and queue requests."""
    with file_lock(home.pdata(project, ".ledger.lock")):
        found, observed_ok = derive_discrepancies(home, cfg, project)
        path = home.pdata(project, "discrepancies.json")
        ledger = read_json(path, {"discrepancies": {}})
        entries = ledger.setdefault("discrepancies", {})
        stamp = iso()
        new_ids = []
        for did, item in found.items():
            prev = entries.get(did)
            if prev is None or prev.get("status") != "open":
                item["first_seen"] = stamp if prev is None else prev.get("first_seen", stamp)
                item["opened_at"] = stamp
                item["occurrences"] = int((prev or {}).get("occurrences", 0)) + 1
                item["links"] = (prev or {}).get("links", [])
                new_ids.append(did)
            else:
                item["first_seen"] = prev.get("first_seen", stamp)
                item["opened_at"] = prev.get("opened_at", stamp)
                item["occurrences"] = prev.get("occurrences", 1)
                item["links"] = prev.get("links", [])
            item["status"] = "open"
            item["last_seen"] = stamp
            entries[did] = item
        for did, prev in entries.items():
            if did in found or prev.get("status") != "open":
                continue
            if prev["kind"] in ("runtime", "version", "observation", "binding") and prev["subject"] not in observed_ok and prev["kind"] != "binding" and did != discrepancy_id(project, "version", prev["subject"], "pin-missing"):
                continue
            prev["status"] = "resolved"
            prev["resolved_at"] = stamp
        write_json_atomic(path, ledger)
    severe = [d for d in new_ids if found[d]["severity"] in ("high", "medium")]
    if severe:
        queue_request(home, project, "discrepancies", "new or reopened discrepancies: %s" % ", ".join(sorted(severe)), ids=sorted(severe))
    return found, new_ids


def queue_request(home, project, kind, detail, ids=None, key=None):
    path = home.pstate(project, "requests.json")
    with file_lock(home.pstate(project, ".requests.lock")):
        data = read_json(path, {"requests": {}})
        requests = data.setdefault("requests", {})
        key = key or kind
        prev = requests.get(key)
        merged_ids = sorted(set((prev or {}).get("ids", [])) | set(ids or []))
        requests[key] = {
            "kind": kind, "detail": detail if not merged_ids else "%s: %s" % (kind, ", ".join(merged_ids)),
            "ids": merged_ids, "created_at": (prev or {}).get("created_at", iso()), "updated_at": iso(),
            "emitted_at": None if (prev is None or set(ids or []) - set(prev.get("ids", []))) else prev.get("emitted_at"),
        }
        write_json_atomic(path, data)


def ack_requests(home, project, keys):
    path = home.pstate(project, "requests.json")
    with file_lock(home.pstate(project, ".requests.lock")):
        data = read_json(path, {"requests": {}})
        requests = data.setdefault("requests", {})
        removed = []
        for key in list(requests):
            if not keys or key in keys:
                removed.append(key)
                del requests[key]
        write_json_atomic(path, data)
    return removed


def maybe_queue_review(home, cfg, project):
    sched_path = home.pstate(project, "schedule.json")
    sched = read_json(sched_path, {}) or {}
    last = parse_iso(sched.get("last_review_requested_at"))
    if last is not None and now_ts() - last < cfg["review_interval"]:
        return False
    queue_request(home, project, "review-due", "review-due: daily system-map review is due", key="review-due")
    sched["last_review_requested_at"] = iso()
    write_json_atomic(sched_path, sched)
    return True


def task_records(home, include_secondmates=False):
    """Yield (task_id, meta-dict) for this home's ship and scout task records.

    Persistent secondmates are excluded by default; activity_view separately
    reconciles their parent records without treating existence as activity.
    """
    for meta in sorted(glob.glob(os.path.join(home.state_dir, "*.meta"))):
        values = {}
        try:
            with open(meta, "r", encoding="utf-8", errors="replace") as handle:
                for line in handle:
                    if "=" in line:
                        key, value = line.rstrip("\n").split("=", 1)
                        values.setdefault(key, value)
        except OSError:
            continue
        if values.get("kind") == "secondmate" and not include_secondmates:
            continue
        yield os.path.basename(meta)[:-5], values


def activity_view(home):
    """Use only this home's task records, parent status, and pending replies.

    A persistent mate's existence is not activity. A working parent report or
    a delivered, open request is; a subsequent pause/terminal report parks it.
    No endpoint, chat, child home, or backend inventory is consulted.
    """
    reasons = []
    mates = {}
    for task, values in task_records(home, include_secondmates=True):
        if values.get("kind") != "secondmate":
            reasons.append({"task": task, "source": "local-task"})
            continue
        last = None
        try:
            with open(os.path.join(home.state_dir, task + ".status"), "rb") as handle:
                handle.seek(0, os.SEEK_END)
                handle.seek(max(0, handle.tell() - 32768))
                for line in handle.read().decode("utf-8", "replace").splitlines():
                    match = re.match(r"^(working|paused|done|failed|blocked|needs-decision) \[at=(\d+)\]", line)
                    if match:
                        last = (match[1], int(match[2]))
        except OSError:
            pass
        mates[task] = last
        if last and last[0] == "working":
            reasons.append({"task": task, "source": "parent-report", "at": iso(last[1])})
    if not mates:
        return {"active": bool(reasons), "reasons": reasons, "scope": "this home's task and parent records only"}
    for path in sorted(glob.glob(os.path.join(home.state_dir, "pending-replies", "*"))):
        if not os.path.isfile(path) or os.path.islink(path):
            continue
        try:
            with open(path, encoding="utf-8") as handle:
                values = dict(line.rstrip("\n").split("=", 1) for line in handle.read(32768).splitlines() if "=" in line)
        except OSError:
            continue
        task = values.get("task_id")
        delivered = values.get("delivered_epoch", "")
        if values.get("schema") != "fm-pending-reply.v1" or task not in mates or values.get("phase") == "resolved" or not delivered.isdigit():
            continue
        last = mates[task]
        if last and last[1] >= int(delivered) and last[0] != "working":
            continue
        if not any(r["task"] == task for r in reasons):
            reasons.append({"task": task, "source": "pending-parent-request", "at": iso(int(delivered))})
    return {"active": bool(reasons), "reasons": reasons, "scope": "this home's task and parent records only"}


def fleet_active(home):
    return activity_view(home)["active"]


def task_project_name(values):
    project = values.get("project", "")
    return os.path.basename(project.rstrip("/")) if project else ""


# ---------------------------------------------------------------------------
# Commands


def cmd_tick(home, cfg, args):
    active = fleet_active(home)
    interval = cfg["active_interval"] if active else cfg["idle_interval"]
    lines = []
    for project in cfg["projects"]:
        health = read_json(home.pstate(project, "health.json"), {}) or {}
        last = parse_iso(health.get("last_attempt_at"))
        if last is None or now_ts() - last >= interval:
            try:
                snap = collect(home, cfg, project, reason="scheduled-%s" % ("active" if active else "idle"))
                lines.append("%s: %s" % (project, snap.get("status") or snap["collector"]["status"]))
            except MapError as exc:
                lines.append("%s: failed (%s)" % (project, exc))
            except Exception as exc:  # noqa: BLE001
                lines.append("%s: failed (%s)" % (project, redact(str(exc), 160)))
        else:
            lines.append("%s: not due (%s cadence)" % (project, "active" if active else "idle"))
        try:
            if maybe_queue_review(home, cfg, project):
                lines.append("%s: review requested" % project)
        except MapError:
            pass
    print("\n".join(lines))
    return 0


def cmd_collect(home, cfg, args):
    project = require_project(home, cfg, args.project)
    snap = collect(home, cfg, project, reason="manual")
    if snap.get("status") == "busy":
        print("busy: another collection for %s is running" % project)
        return 75
    c = snap["collector"]
    print("collected %s: %s (%d/%d observations failed)" % (project, c["status"], c["failed_observations"], c["total_observations"]))
    return 0


def _age(ts_iso):
    ts = parse_iso(ts_iso)
    if ts is None:
        return "never"
    secs = int(now_ts() - ts)
    if secs < 120:
        return "%ds ago" % secs
    if secs < 7200:
        return "%dm ago" % (secs // 60)
    if secs < 172800:
        return "%dh ago" % (secs // 3600)
    return "%dd ago" % (secs // 86400)


def cmd_summary(home, cfg, args):
    """Bounded, local-only startup summary: at most a few lines per project."""
    out = []
    for project in cfg["projects"][:4]:
        try:
            view = build_view(home, cfg, project)
        except MapError as exc:
            out.append("%s: map unreadable - %s" % (project, exc))
            continue
        col = view["collector"]
        opened = [d for d in view["discrepancies"] if d.get("status") == "open"]
        high = [d for d in opened if d.get("severity") == "high"]
        state = col.get("last_status") or "never collected"
        out.append("%s: %sobservations %s, last success %s%s; %d open discrepancies (%d high); manifest r%s" % (
            project, "TEST DATA, not live - " if col.get("fixture") else "", state, _age(col.get("last_success_at")), " (STALE)" if col.get("stale") else "",
            len(opened), len(high), view["manifest"]["revision"]))
        for item in (high or opened)[:3]:
            out.append("  - %s %s: %s" % (item["id"], item["severity"], item["title"][:110]))
    pending = []
    for project in cfg["projects"]:
        requests = read_json(home.pstate(project, "requests.json"), {"requests": {}}).get("requests", {})
        if requests:
            pending.append("%s: %s" % (project, ", ".join(sorted(requests))))
    out = out[:14 if pending else 15]
    if pending:
        out.append("pending review requests: %s (load system-map-review)" % "; ".join(pending))
    if cfg["projects"]:
        out.append("map UI: http://127.0.0.1:%d/ (bin/fm-system-map.sh status for scheduler health)" % cfg["port"])
    print("\n".join(out))
    return 0


def cmd_check(home, cfg, args):
    """Watcher check: print one line when requests are due for the supervisor."""
    pending = []
    for project in cfg["projects"]:
        path = home.pstate(project, "requests.json")
        if not os.path.exists(path):
            continue
        with file_lock(home.pstate(project, ".requests.lock")):
            data = read_json(path, {"requests": {}})
            changed = False
            for key, req in sorted(data.get("requests", {}).items()):
                emitted = parse_iso(req.get("emitted_at"))
                if emitted is None or now_ts() - emitted >= cfg["reemit_interval"]:
                    pending.append("%s %s" % (project, req["detail"]))
                    req["emitted_at"] = iso()
                    changed = True
            if changed:
                write_json_atomic(path, data)
    if pending:
        print("system-map: %s - load system-map-review" % "; ".join(pending)[:600])
    return 0


def cmd_view(home, cfg, args):
    project = require_project(home, cfg, args.project)
    json.dump(build_view(home, cfg, project), sys.stdout, indent=None if args.compact else 2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


def cmd_status(home, cfg, args):
    for project in cfg["projects"]:
        health = read_json(home.pstate(project, "health.json"), {}) or {}
        print("%s: last attempt %s, last success %s, status %s%s" % (
            project, _age(health.get("last_attempt_at")), _age(health.get("last_success_at")),
            health.get("last_status", "never"), (" - " + health["last_error"]) if health.get("last_error") else ""))
    sched = scheduler_paths(home)
    for name, path in sched.items():
        print("unit %s: %s" % (name, "installed" if os.path.exists(path) else "not installed"))
    check = os.path.join(home.state_dir, CHECK_ID + ".check.sh")
    print("watcher check: %s" % ("registered" if os.path.exists(os.path.join(home.state_dir, CHECK_ID + ".check-trust")) else ("present, unregistered" if os.path.exists(check) else "not installed")))
    return 0


def cmd_validate(home, cfg, args):
    project = require_project(home, cfg, args.project)
    manifest = load_manifest(home, project)
    bindings = load_bindings(home, project)
    problems = []
    for sid, (_, subject) in subjects_of(manifest).items():
        for obs in subject.get("observe", []):
            problem = binding_problem(obs["adapter"], bindings.get("bindings", {}).get(obs["binding"]))
            if problem:
                problems.append("%s/%s (%s): %s" % (sid, obs["id"], obs["binding"], problem))
    for rec in load_evidence(home, project):
        if rec.get("invalid"):
            problems.append("evidence %s: %s" % (rec["id"], rec["invalid"]))
    print("manifest %s r%d: valid; %d subjects" % (project, manifest["revision"], len(subjects_of(manifest))))
    for problem in problems:
        print("binding: " + problem)
    return 1 if problems else 0


def cmd_evidence_add(home, cfg, args):
    project = require_project(home, cfg, args.project)
    manifest = load_manifest(home, project)
    with open(args.file, "r", encoding="utf-8") as handle:
        try:
            record = json.load(handle)
        except ValueError as exc:
            raise MapError("evidence file is not JSON: %s" % exc)
    validate_evidence(record, set(subjects_of(manifest)), {p["id"] for p in manifest.get("prerequisites", [])})
    record_evidence(home, project, record)
    print("recorded evidence %s" % record["id"])
    return 0


def add_annotation(home, project, target, text, author):
    manifest = load_manifest(home, project)
    ledger = read_json(home.pdata(project, "discrepancies.json"), {"discrepancies": {}}).get("discrepancies", {})
    valid_targets = set(subjects_of(manifest)) | set(ledger) | {c["id"] for c in manifest.get("acceptance", [])} | {"design"}
    if target not in valid_targets:
        raise MapError("unknown annotation target %r" % target)
    text = (text or "").strip()
    if not text or len(text) > 4000:
        raise MapError("annotation text must be 1-4000 characters")
    author = (author or "captain").strip()[:80]
    _scan_forbidden({"text": text}, "annotation")
    path = home.pdata(project, "annotations.json")
    with file_lock(home.pdata(project, ".annotations.lock")):
        data = read_json(path, {"annotations": []})
        record = {"id": "a-" + secrets.token_hex(5), "target": target, "text": text, "author": author, "created_at": iso(), "resolved_at": None}
        data.setdefault("annotations", []).append(record)
        write_json_atomic(path, data)
    return record


def resolve_annotation(home, project, annotation_id):
    path = home.pdata(project, "annotations.json")
    with file_lock(home.pdata(project, ".annotations.lock")):
        data = read_json(path, {"annotations": []})
        for record in data.get("annotations", []):
            if record.get("id") == annotation_id:
                record["resolved_at"] = record.get("resolved_at") or iso()
                write_json_atomic(path, data)
                return record
    raise MapError("unknown annotation %r" % annotation_id)


EDITABLE_FIELDS = ("title", "description", "notes")


def edit_intent(home, project, subject_id, field, value, base_revision, reason, author):
    """Apply one validated intended-design edit; never touches observed records."""
    with file_lock(home.pdata(project, ".manifest.lock")):
        manifest = load_manifest(home, project)
        if base_revision is not None and int(base_revision) != manifest["revision"]:
            raise MapError("manifest changed (now r%d); reload and retry" % manifest["revision"])
        target = None
        for coll in ("components", "connections"):
            for subject in manifest[coll]:
                if subject["id"] == subject_id:
                    target = subject
        if target is None:
            raise MapError("unknown subject %r" % subject_id)
        if not isinstance(value, str) or len(value) > 4000:
            raise MapError("value must be a string of at most 4000 characters")
        if field in EDITABLE_FIELDS:
            if field == "title" and not value.strip():
                raise MapError("title cannot be empty")
            target[field] = value
        elif field.startswith("intended."):
            mode = field.split(".", 1)[1]
            if mode not in manifest["modes"]:
                raise MapError("unknown mode %r" % mode)
            if value.strip():
                target.setdefault("intended", {})[mode] = value.strip()
            else:
                target.get("intended", {}).pop(mode, None)
        else:
            raise MapError("field %r is not editable here; use intent replace for structural changes" % field)
        _commit_manifest(home, project, manifest, reason or "edit %s.%s" % (subject_id, field), author)
        return manifest["revision"]


def _commit_manifest(home, project, manifest, reason, author):
    current = read_json(home.pdata(project, "manifest.json"))
    manifest["revision"] = (current or {}).get("revision", 0) + 1
    manifest["updated_at"] = iso()
    validate_manifest(manifest)
    if current is not None:
        write_json_atomic(home.pdata(project, "history", "manifest-r%d.json" % current["revision"]), current)
    write_json_atomic(home.pdata(project, "manifest.json"), manifest)
    log = home.pdata(project, "history", "changes.jsonl")
    os.makedirs(os.path.dirname(log), exist_ok=True)
    with open(log, "a", encoding="utf-8") as handle:
        handle.write(json.dumps({"revision": manifest["revision"], "at": manifest["updated_at"], "reason": reason[:400], "author": (author or "")[:80]}) + "\n")


def cmd_intent(home, cfg, args):
    project = require_project(home, cfg, args.project)
    if args.intent_cmd == "set":
        rev = edit_intent(home, project, args.subject, args.field, args.value, args.base_revision, args.reason, args.author)
        print("manifest %s now r%d" % (project, rev))
    elif args.intent_cmd == "replace":
        with open(args.file, "r", encoding="utf-8") as handle:
            new = json.load(handle)
        if not args.reason:
            raise MapError("intent replace needs --reason")
        with file_lock(home.pdata(project, ".manifest.lock")):
            validate_manifest(dict(new, revision=max(int(new.get("revision", 1) or 1), 1)))
            if new.get("project") != project:
                raise MapError("manifest.project must be %r" % project)
            _commit_manifest(home, project, new, args.reason, args.author)
        print("manifest %s replaced; now r%d" % (project, new["revision"]))
    elif args.intent_cmd == "init":
        if os.path.exists(home.pdata(project, "manifest.json")):
            raise MapError("manifest already exists; use intent replace")
        with open(args.file, "r", encoding="utf-8") as handle:
            new = json.load(handle)
        new["revision"] = 1
        new["project"] = project
        validate_manifest(new)
        write_json_atomic(home.pdata(project, "manifest.json"), new)
        print("manifest %s installed at r1" % project)
    return 0


def find_task_binding(home, cfg, task):
    for project in cfg["projects"]:
        path = home.pdata(project, "tasks", task + ".json")
        if os.path.exists(path):
            return project, read_json(path)
    return None, None


def cmd_bind(home, cfg, args):
    if not TASK_RE.match(args.task):
        raise MapError("invalid task id")
    project = require_project(home, cfg, args.project)
    manifest = load_manifest(home, project)
    ids = subjects_of(manifest)
    subjects = []
    for raw in args.subject:
        for sid in raw.split(","):
            sid = sid.strip()
            if not sid:
                continue
            if sid not in ids:
                raise MapError("unknown component or connection %r in %s" % (sid, project))
            subjects.append(sid)
    if args.no_subjects:
        if subjects or not (args.note or "").strip():
            raise MapError("--no-subjects records a reviewed exemption: pass --note with the reason and no --subject")
    elif not subjects:
        raise MapError("name at least one --subject (or --no-subjects --note REASON)")
    other, _ = find_task_binding(home, cfg, args.task)
    if other and other != project:
        raise MapError("task %s is already bound in project %s" % (args.task, other))
    record = {"schema": TASK_BINDING_SCHEMA, "task": args.task, "project": project, "subjects": sorted(set(subjects)), "bound_at": iso(), "note": (args.note or "")[:400]}
    write_json_atomic(home.pdata(project, "tasks", args.task + ".json"), record)
    print("bound %s to %s: %s" % (args.task, project, ", ".join(record["subjects"])))
    print("brief line: This task changes system-map subjects %s in %s; landing records implementation-complete only, live verification needs version-bound evidence." % (", ".join(record["subjects"]), project))
    return 0


def cmd_complete(home, cfg, args):
    """Called by fm-teardown.sh after a task's record is gone. Advisory only."""
    if not TASK_RE.match(args.task):
        return 0
    project, binding = find_task_binding(home, cfg, args.task)
    if not binding:
        return 0
    kind = args.kind or "ship"
    status = "implementation-complete" if kind == "ship" else "investigated"
    record = {
        "schema": COMPLETION_SCHEMA, "task": args.task, "project": project, "subjects": binding.get("subjects", []),
        "kind": kind, "mode": args.mode or "", "pr": args.pr or "", "status": status, "completed_at": precise_iso(),
    }
    if kind == "ship":
        path = home.pdata(project, "completions", args.task + ".json")
        with file_lock(path + ".lock"):
            existing = read_json(path)
            if existing is not None:
                record = existing
            else:
                write_json_atomic(path, record)
    print("System map: %s recorded %s for %s in %s; live verification stays separate - see bin/fm-system-map.sh verify %s." % (
        args.task, status, ", ".join(record["subjects"]), project, args.task))
    return 0


def cmd_verify(home, cfg, args):
    project, binding = find_task_binding(home, cfg, args.task)
    if not binding:
        print("task %s has no system-map binding" % args.task)
        return 0
    view = build_view(home, cfg, project)
    completion = read_json(home.pdata(project, "completions", args.task + ".json"))
    completed = completion is not None
    evidence = load_evidence(home, project) if completed else []
    print("task %s (%s): %s" % (args.task, project, "implementation-complete" if completed else "not landed yet"))
    unverified = 0
    for sid in (completion if completed else binding).get("subjects", []):
        s = view["subjects"].get(sid)
        if not s:
            print("  %s: no longer in the manifest" % sid)
            unverified += 1
            continue
        live = live_verification(evidence, sid, s["version"], s["version_state"], parse_iso(completion["completed_at"]) or 0, s["resource_identity"], s["layers"]["deployment"]["status"]) if completed else None
        if live is not True:
            unverified += 1
        print("  %s: deployment %s, runtime %s, proof %s, live-verified %s" % (
            sid, s["layers"]["deployment"]["status"], s["layers"]["runtime"]["status"],
            s["layers"]["proof"]["status"], {True: "yes", False: "no", None: "n/a", "unversioned": "no (proof not version-bound)"}[live]))
    return 3 if completed and unverified else 0


def cmd_ack(home, cfg, args):
    project = require_project(home, cfg, args.project)
    removed = ack_requests(home, project, args.key)
    print("acknowledged: %s" % (", ".join(removed) or "nothing pending"))
    return 0


def cmd_review_done(home, cfg, args):
    project = require_project(home, cfg, args.project)
    ack_requests(home, project, [])
    sched_path = home.pstate(project, "schedule.json")
    sched = read_json(sched_path, {}) or {}
    sched["last_review_at"] = iso()
    sched["last_review_note"] = (args.note or "")[:400]
    write_json_atomic(sched_path, sched)
    print("review of %s recorded; pending requests cleared" % project)
    return 0


def cmd_link(home, cfg, args):
    project = require_project(home, cfg, args.project)
    if not TASK_RE.match(args.task):
        raise MapError("invalid task id")
    with file_lock(home.pdata(project, ".ledger.lock")):
        path = home.pdata(project, "discrepancies.json")
        ledger = read_json(path, {"discrepancies": {}})
        item = ledger.get("discrepancies", {}).get(args.discrepancy)
        if not item:
            raise MapError("unknown discrepancy %r" % args.discrepancy)
        links = set(item.get("links", []))
        links.add(args.task)
        item["links"] = sorted(links)
        write_json_atomic(path, ledger)
    print("linked %s to existing task %s" % (args.discrepancy, args.task))
    return 0


def cmd_annotate(home, cfg, args):
    project = require_project(home, cfg, args.project)
    record = add_annotation(home, project, args.target, args.text, args.author)
    print("annotation %s on %s" % (record["id"], record["target"]))
    return 0


# ---------------------------------------------------------------------------
# Scheduler (systemd user units) and the watcher check


def scheduler_paths(home):
    unit_dir = os.environ.get("FM_SYSTEM_MAP_UNIT_DIR") or os.path.join(os.path.expanduser("~"), ".config", "systemd", "user")
    tag = home.home_tag()
    base = "fm-system-map-%s" % tag
    return {
        "collector.service": os.path.join(unit_dir, base + "-collect.service"),
        "collector.timer": os.path.join(unit_dir, base + "-collect.timer"),
        "ui.service": os.path.join(unit_dir, base + "-ui.service"),
    }


def _quote_unit(value):
    if re.search(r"[\s\"'\\$%]", value):
        raise MapError("path %r contains characters this installer will not quote into a unit file" % value)
    return value


def service_path():
    """A bounded PATH for user services, which do not inherit the login PATH.

    It names the directories of the tools the collector actually runs, resolved
    at install time, followed by the standard system directories.
    """
    dirs = []
    for tool in ("python3", "git", "aws"):
        found = os.environ.get("FM_SYSTEM_MAP_AWS") if tool == "aws" and os.environ.get("FM_SYSTEM_MAP_AWS") else shutil.which(tool)
        if found:
            directory = os.path.dirname(os.path.realpath(found)) if tool == "python3" else os.path.dirname(os.path.abspath(found))
            if directory not in dirs:
                dirs.append(directory)
    for directory in ("/usr/local/bin", "/usr/bin", "/bin"):
        if directory not in dirs:
            dirs.append(directory)
    return ":".join(_quote_unit(d) for d in dirs)


def render_units(home, cfg):
    wrapper = _quote_unit(os.path.join(home.root, "bin", "fm-system-map.sh"))
    fm_home = _quote_unit(os.path.realpath(home.home))
    tick_minutes = max(1, cfg["active_interval"] // 60)
    tag = home.home_tag()
    env_lines = ["Environment=FM_HOME=%s" % fm_home, "Environment=PATH=%s" % service_path()]
    aws = os.environ.get("FM_SYSTEM_MAP_AWS") or shutil.which("aws")
    if aws:
        env_lines.append("Environment=FM_SYSTEM_MAP_AWS=%s" % _quote_unit(os.path.abspath(aws)))
    return {
        "collector.service": "\n".join([
            "# Managed by bin/fm-system-map.sh install (home %s). Remove with uninstall." % tag,
            "[Unit]", "Description=Firstmate system map collector (%s)" % tag, "",
            "[Service]", "Type=oneshot"] + env_lines + [
            "ExecStart=%s tick" % wrapper, "TimeoutStartSec=%d" % (cfg["collect_timeout"] + 60),
            "Nice=10", "",
        ]),
        "collector.timer": "\n".join([
            "# Managed by bin/fm-system-map.sh install (home %s). Remove with uninstall." % tag,
            "[Unit]", "Description=Firstmate system map collection cadence (%s)" % tag, "",
            "[Timer]", "OnBootSec=2min", "OnUnitActiveSec=%dmin" % tick_minutes, "Persistent=true", "",
            "[Install]", "WantedBy=timers.target", "",
        ]),
        "ui.service": "\n".join([
            "# Managed by bin/fm-system-map.sh install (home %s). Remove with uninstall." % tag,
            "[Unit]", "Description=Firstmate system map UI on 127.0.0.1:%d (%s)" % (cfg["port"], tag), "",
            "[Service]"] + env_lines + [
            "ExecStart=%s serve" % wrapper, "Restart=on-failure", "RestartSec=10", "",
            "[Install]", "WantedBy=default.target", "",
        ]),
    }


def _systemctl(args, dry_run):
    cmd = [os.environ.get("FM_SYSTEM_MAP_SYSTEMCTL") or "systemctl", "--user"] + args
    if dry_run:
        print("would run: " + " ".join(cmd))
        return 0
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise MapError("systemctl --user %s failed: %s" % (" ".join(args), exc))
    if proc.returncode != 0:
        raise MapError("systemctl --user %s failed: %s" % (" ".join(args), (proc.stderr or proc.stdout).strip()[:300]))
    return 0


def check_shim(home):
    wrapper = os.path.join(home.root, "bin", "fm-system-map.sh")
    return "#!/usr/bin/env bash\n# Registered by bin/fm-system-map.sh install; retire with uninstall.\nFM_HOME=%s exec %s check\n" % (
        _shell_quote(os.path.realpath(home.home)), _shell_quote(wrapper))


def _shell_quote(value):
    return "'" + value.replace("'", "'\\''") + "'"


def _run_root_script(home, script, args):
    cmd = [os.path.join(home.root, "bin", script)] + args
    env = dict(os.environ, FM_HOME=home.home)
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30, env=env, stdin=subprocess.DEVNULL)
    if proc.returncode != 0:
        raise MapError("%s failed: %s" % (script, (proc.stderr or proc.stdout).strip()[:300]))
    return proc.stdout.strip()


def managed_unit(path, tag):
    if not os.path.exists(path):
        return False
    with open(path, "r", encoding="utf-8") as handle:
        return handle.readline().rstrip("\n") == "# Managed by bin/fm-system-map.sh install (home %s). Remove with uninstall." % tag


def cmd_install(home, cfg, args):
    if os.environ.get("FM_SYSTEM_MAP_FIXTURE") == "1":
        raise MapError("cannot install the system map from a fixture run")
    if not cfg["projects"]:
        raise MapError("config/system-map lists no project")
    for project in cfg["projects"]:
        load_manifest(home, project)
        load_bindings(home, project)
    units = render_units(home, cfg)
    paths = scheduler_paths(home)
    for path in paths.values():
        if os.path.exists(path) and not managed_unit(path, home.home_tag()):
            raise MapError("%s exists and is not managed by this installer; refusing to overwrite" % path)
    shim_path = os.path.join(home.state_dir, CHECK_ID + ".check.sh")
    trust_path = os.path.join(home.state_dir, CHECK_ID + ".check-trust")
    shim = check_shim(home)
    if os.path.exists(shim_path):
        with open(shim_path, "r", encoding="utf-8") as handle:
            current_shim = handle.read()
        if current_shim != shim:
            raise MapError("%s exists and is not managed by this installer; refusing to overwrite" % shim_path)
    else:
        if os.path.exists(trust_path):
            raise MapError("%s exists without a managed check; refusing to replace" % trust_path)
        current_shim = None
    changed = False
    for name, path in paths.items():
        current = None
        if os.path.exists(path):
            with open(path, "r", encoding="utf-8") as handle:
                current = handle.read()
        if current != units[name]:
            changed = True
            if args.dry_run:
                print("would write %s" % path)
            else:
                write_text_atomic(path, units[name], mode=0o644)
                print("wrote %s" % path)
        else:
            print("unchanged %s" % path)
    if args.dry_run:
        print("would %s %s and register it" % ("keep" if current_shim == shim else "write", shim_path))
    else:
        if current_shim != shim:
            write_text_atomic(shim_path, shim, mode=0o700)
        print(_run_root_script(home, "fm-check-register.sh", [CHECK_ID]))
    if changed:
        _systemctl(["daemon-reload"], args.dry_run)
    _systemctl(["enable", "--now", os.path.basename(paths["collector.timer"])], args.dry_run)
    _systemctl(["enable", "--now", os.path.basename(paths["ui.service"])], args.dry_run)
    if changed:
        _systemctl(["restart", os.path.basename(paths["ui.service"])], args.dry_run)
    print("system map installed for %s; UI http://127.0.0.1:%d/" % (", ".join(cfg["projects"]), cfg["port"]))
    return 0


def cmd_uninstall(home, cfg, args):
    paths = scheduler_paths(home)
    for name in ("collector.timer", "ui.service"):
        if managed_unit(paths[name], home.home_tag()):
            try:
                _systemctl(["disable", "--now", os.path.basename(paths[name])], args.dry_run)
            except MapError as exc:
                print("warning: %s" % exc)
    removed = False
    for path in paths.values():
        if os.path.exists(path):
            if not managed_unit(path, home.home_tag()):
                print("skipped unmanaged %s" % path)
                continue
            removed = True
            if args.dry_run:
                print("would remove %s" % path)
            else:
                os.unlink(path)
                print("removed %s" % path)
    if removed:
        _systemctl(["daemon-reload"], args.dry_run)
    shim_path = os.path.join(home.state_dir, CHECK_ID + ".check.sh")
    if os.path.exists(shim_path):
        with open(shim_path, "r", encoding="utf-8") as handle:
            owned_shim = handle.read() == check_shim(home)
    else:
        owned_shim = False
    if owned_shim:
        if args.dry_run:
            print("would unregister the watcher check")
        else:
            print(_run_root_script(home, "fm-check-unregister.sh", [CHECK_ID]) or "unregistered watcher check")
    elif os.path.exists(shim_path):
        print("skipped unmanaged %s" % shim_path)
    print("system map scheduler and check removed; data/system-map and state/system-map are kept")
    return 0


# ---------------------------------------------------------------------------
# Local UI server

UI_FILES = {"/app.js": ("app.js", "text/javascript; charset=utf-8"), "/app.css": ("app.css", "text/css; charset=utf-8")}


class MapServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, handler, home, port):
        super().__init__(address, handler)
        self.home = home
        self.port = port
        self.collect_threads = {}
        self.lock = threading.Lock()


class MapHandler(BaseHTTPRequestHandler):
    server_version = "fm-system-map"
    sys_version = ""

    def log_message(self, fmt, *args):  # quiet by default
        if os.environ.get("FM_SYSTEM_MAP_HTTP_LOG"):
            sys.stderr.write("%s\n" % (fmt % args))

    def _host_ok(self):
        host = (self.headers.get("Host") or "").strip()
        return host in ("127.0.0.1:%d" % self.server.port, "localhost:%d" % self.server.port)

    def _send(self, status, body, ctype="application/json; charset=utf-8"):
        data = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _json(self, status, obj):
        self._send(status, json.dumps(obj))

    def _context(self):
        home = self.server.home
        cfg = home.config()
        return home, cfg

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        if not self._host_ok():
            return self._json(HTTPStatus.FORBIDDEN, {"error": "unexpected Host header"})
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        try:
            home, cfg = self._context()
            if parsed.path == "/":
                with open(os.path.join(home.ui_dir, "index.html"), "r", encoding="utf-8") as handle:
                    page = handle.read()
                return self._send(HTTPStatus.OK, page, "text/html; charset=utf-8")
            if parsed.path in UI_FILES:
                name, ctype = UI_FILES[parsed.path]
                with open(os.path.join(home.ui_dir, name), "rb") as handle:
                    return self._send(HTTPStatus.OK, handle.read(), ctype)
            if parsed.path == "/api/projects":
                return self._json(HTTPStatus.OK, {"projects": cfg["projects"], "enabled": home.enabled()})
            if parsed.path == "/api/state":
                project = require_project(home, cfg, (query.get("project") or [""])[0])
                view = build_view(home, cfg, project)
                with self.server.lock:
                    thread = self.server.collect_threads.get(project)
                    view["collecting"] = bool(thread and thread.is_alive())
                return self._json(HTTPStatus.OK, view)
            return self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})
        except MapError as exc:
            return self._json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
        except Exception as exc:  # noqa: BLE001
            return self._json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": redact(str(exc))})

    def do_POST(self):
        if not self._host_ok():
            return self._json(HTTPStatus.FORBIDDEN, {"error": "unexpected Host header"})
        origin = self.headers.get("Origin")
        if origin is not None and origin not in (
            "http://127.0.0.1:%d" % self.server.port,
            "http://localhost:%d" % self.server.port,
        ):
            return self._json(HTTPStatus.FORBIDDEN, {"error": "unexpected Origin header"})
        if self.headers.get("Sec-Fetch-Site", "").lower() == "cross-site":
            return self._json(HTTPStatus.FORBIDDEN, {"error": "cross-site request"})
        if self.headers.get_content_type() != "application/json":
            return self._json(HTTPStatus.UNSUPPORTED_MEDIA_TYPE, {"error": "Content-Type must be application/json"})
        length = int(self.headers.get("Content-Length") or 0)
        if length > 65536:
            return self._json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"error": "request too large"})
        try:
            body = json.loads(self.rfile.read(length).decode("utf-8") or "{}") if length else {}
            if not isinstance(body, dict):
                raise MapError("request body must be an object")
            home, cfg = self._context()
            project = require_project(home, cfg, str(body.get("project") or ""))
            path = urllib.parse.urlparse(self.path).path
            if path == "/api/collect":
                with self.server.lock:
                    thread = self.server.collect_threads.get(project)
                    if thread and thread.is_alive():
                        return self._json(HTTPStatus.CONFLICT, {"error": "a collection is already running"})
                    thread = threading.Thread(target=self._collect_bg, args=(home, cfg, project), daemon=True)
                    self.server.collect_threads[project] = thread
                    thread.start()
                return self._json(HTTPStatus.ACCEPTED, {"status": "started"})
            if path == "/api/annotate":
                record = add_annotation(home, project, str(body.get("target") or ""), str(body.get("text") or ""), str(body.get("author") or "captain"))
                return self._json(HTTPStatus.CREATED, record)
            if path == "/api/annotation/resolve":
                record = resolve_annotation(home, project, str(body.get("id") or ""))
                return self._json(HTTPStatus.OK, record)
            if path == "/api/intent":
                rev = edit_intent(home, project, str(body.get("subject") or ""), str(body.get("field") or ""), body.get("value"), body.get("base_revision"), str(body.get("reason") or ""), str(body.get("author") or "captain"))
                return self._json(HTTPStatus.OK, {"revision": rev})
            return self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})
        except MapError as exc:
            status = HTTPStatus.CONFLICT if "changed" in str(exc) else HTTPStatus.BAD_REQUEST
            return self._json(status, {"error": str(exc)})
        except ValueError:
            return self._json(HTTPStatus.BAD_REQUEST, {"error": "request body is not JSON"})
        except Exception as exc:  # noqa: BLE001
            return self._json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": redact(str(exc))})

    @staticmethod
    def _collect_bg(home, cfg, project):
        with contextlib.suppress(Exception):
            collect(home, cfg, project, reason="ui")


def cmd_serve(home, cfg, args):
    port = cfg["port"]
    server = MapServer(("127.0.0.1", port), MapHandler, home, port)
    print("system map UI: http://127.0.0.1:%d/" % port, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


def cmd_open(home, cfg, args):
    print("http://127.0.0.1:%d/" % cfg["port"])
    return 0


# ---------------------------------------------------------------------------
# Entry point


def build_parser():
    parser = argparse.ArgumentParser(prog="fm-system-map.sh", description="Living system map (see docs/system-map.md).")
    sub = parser.add_subparsers(dest="cmd")
    sub.add_parser("tick", help="scheduled entry: collect when due, queue the daily review request")
    p = sub.add_parser("collect", help="collect observations now")
    p.add_argument("project", nargs="?")
    sub.add_parser("summary", help="bounded local summary for session start")
    sub.add_parser("check", help="watcher check: print due supervisor requests")
    sub.add_parser("status", help="collector and scheduler health")
    p = sub.add_parser("view", help="print the derived map view as JSON (read-only)")
    p.add_argument("project", nargs="?")
    p.add_argument("--compact", action="store_true")
    p = sub.add_parser("validate", help="validate manifest, bindings and evidence")
    p.add_argument("project", nargs="?")
    sub.add_parser("serve", help="serve the local UI on 127.0.0.1")
    sub.add_parser("open", help="print the owner-only local UI URL")
    p = sub.add_parser("evidence", help="record version-bound evidence")
    p.add_argument("evidence_cmd", choices=["add"])
    p.add_argument("project")
    p.add_argument("file")
    p = sub.add_parser("annotate", help="add a human annotation")
    p.add_argument("project")
    p.add_argument("target")
    p.add_argument("text")
    p.add_argument("--author", default="captain")
    p = sub.add_parser("intent", help="edit the intended design (validated, versioned)")
    isub = p.add_subparsers(dest="intent_cmd")
    q = isub.add_parser("set")
    q.add_argument("project")
    q.add_argument("subject")
    q.add_argument("field")
    q.add_argument("value")
    q.add_argument("--base-revision", type=int)
    q.add_argument("--reason", default="")
    q.add_argument("--author", default="captain")
    q = isub.add_parser("replace")
    q.add_argument("project")
    q.add_argument("file")
    q.add_argument("--reason", default="")
    q.add_argument("--author", default="firstmate")
    q = isub.add_parser("init")
    q.add_argument("project")
    q.add_argument("file")
    p = sub.add_parser("bind", help="bind a task to map subjects")
    p.add_argument("task")
    p.add_argument("--project")
    p.add_argument("--subject", action="append", default=[])
    p.add_argument("--no-subjects", action="store_true")
    p.add_argument("--note")
    p = sub.add_parser("complete", help="record a landed task (called by fm-teardown.sh)")
    p.add_argument("task")
    p.add_argument("--kind")
    p.add_argument("--mode")
    p.add_argument("--pr")
    p = sub.add_parser("verify", help="implementation-complete vs live-verified for a bound task")
    p.add_argument("task")
    p = sub.add_parser("link", help="link a discrepancy to an existing task")
    p.add_argument("project")
    p.add_argument("discrepancy")
    p.add_argument("task")
    p = sub.add_parser("ack", help="acknowledge pending supervisor requests")
    p.add_argument("project")
    p.add_argument("key", nargs="*")
    p = sub.add_parser("review-done", help="record a completed review and clear requests")
    p.add_argument("project")
    p.add_argument("--note")
    for name in ("install", "uninstall"):
        p = sub.add_parser(name, help="%s the scheduler units and watcher check" % name)
        p.add_argument("--dry-run", action="store_true")
    return parser


COMMANDS = {
    "tick": cmd_tick, "collect": cmd_collect, "summary": cmd_summary, "check": cmd_check,
    "status": cmd_status, "view": cmd_view, "validate": cmd_validate, "serve": cmd_serve, "open": cmd_open,
    "evidence": cmd_evidence_add, "annotate": cmd_annotate, "intent": cmd_intent, "bind": cmd_bind,
    "complete": cmd_complete, "verify": cmd_verify, "link": cmd_link, "ack": cmd_ack,
    "review-done": cmd_review_done, "install": cmd_install, "uninstall": cmd_uninstall,
}
# Commands that stay silent no-ops when the map is not enabled, so wiring them
# into session start, the watcher, or teardown changes nothing for such homes.
PASSIVE = {"tick", "summary", "check", "complete"}


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if not args.cmd:
        parser.print_help()
        return 2
    home = Home()
    if not home.enabled():
        if args.cmd in PASSIVE:
            return 0
        print("error: the system map is not enabled for this home (create config/system-map; see docs/system-map.md)", file=sys.stderr)
        return 1
    try:
        cfg = home.config()
        return COMMANDS[args.cmd](home, cfg, args)
    except MapError as exc:
        if args.cmd in PASSIVE:
            print("system map: %s" % exc, file=sys.stderr)
            return 0
        print("error: %s" % exc, file=sys.stderr)
        return 1
    except (OSError, ValueError) as exc:
        # An unreadable or malformed map file must never fail a caller that
        # only consults the map (session start, the watcher, teardown).
        if args.cmd in PASSIVE:
            print("system map: unreadable map data: %s" % redact(str(exc), 200), file=sys.stderr)
            return 0
        print("error: %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
