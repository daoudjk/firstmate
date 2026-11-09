"""Optional private scenario/image projection, collected by the existing map.

This module reads no provider, runs no commands and serves no source files.
Only validated display fields leave the collector. Source paths are used solely
for bounded fingerprint checks; repositories and owner receipts remain authority.
"""

import copy
import datetime
import hashlib
import ipaddress
import json
import os
import re
import stat
import urllib.parse

SCHEMA = "fm-system-map.catalog.v1"
LIMIT = 8 * 1024 * 1024


def require(condition, message):
    if not condition:
        raise ValueError(message)


def text(value, label, limit=4000):
    require(isinstance(value, str) and 0 < len(value) <= limit, label + " must be nonempty text")
    return value


def timestamp(value):
    if value is None:
        return None
    text(value, "checked_at", 80)
    parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    require(parsed.tzinfo is not None, "timestamp needs a timezone")
    require(parsed.timestamp() <= datetime.datetime.now(datetime.timezone.utc).timestamp() + 60, "future evidence time")
    return parsed.timestamp()


def safe_url(value):
    text(value, "source URL", 2048)
    u = urllib.parse.urlsplit(value)
    require(u.scheme == "https" and u.hostname and not u.username and not u.password, "source URLs must be HTTPS without credentials")
    require(not any(c.isspace() or ord(c) < 32 for c in value) and "\\" not in value, "invalid source URL")
    host = u.hostname.lower().rstrip(".")
    require("." in host and host != "localhost" and not host.endswith((".localhost", ".local", ".internal")), "source URL must use a public host")
    try:
        addr = ipaddress.ip_address(host)
    except ValueError:
        require(re.fullmatch(r"(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}", host) is not None, "source URL needs a valid public DNS host")
    else:
        require(addr.is_global, "source URL must use a public host")
    require(u.port in (None, 443), "source URL port must be HTTPS")
    return value


def fingerprint(path):
    # O_NONBLOCK avoids hanging on a FIFO supplied in a private source list.
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as handle:
        info = os.fstat(handle.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_size <= LIMIT, "source must be a bounded regular file")
        data = handle.read(LIMIT + 1)
        require(len(data) <= LIMIT, "source exceeds size limit")
    return hashlib.sha256(data).hexdigest(), data


def links(value):
    require(isinstance(value, list) and len(value) <= 100, "sources must be a list")
    return [{"label": text(v["label"], "source label", 200), "url": safe_url(v["url"])} for v in value]


def assessment(value, allowed, identity=None, source_ids=()):
    require(isinstance(value, dict) and value.get("status") in allowed, "invalid evidence status")
    out = {"status": value["status"], "checked_at": value.get("checked_at"),
           "note": text(value.get("note"), "evidence scope"), "sources": links(value.get("sources", []))}
    refs = value.get("source_ids", [])
    require(isinstance(refs, list) and all(isinstance(v, str) and v in source_ids for v in refs), "invalid receipt source reference")
    out["source_ids"] = refs
    timestamp(out["checked_at"])
    if out["status"] in ("remote-verified", "wired", "passed"):
        require(out["checked_at"] and (out["sources"] or out["source_ids"]), "positive evidence needs time and provenance")
        require(identity and value.get("identity") == identity, "positive evidence needs matching exact identity")
        out["identity"] = identity
    return out


def scenario_identity(value):
    require(isinstance(value, dict), "scenario identity must be an object")
    out = {"scenario_id": text(value.get("scenario_id"), "stable scenario id", 200)}
    for key in ("version", "bundle_fingerprint", "spec_digest"):
        val = value.get(key)
        out[key] = text(val, "scenario " + key, 200) if val is not None else None
        if val is not None and key != "version":
            require(re.fullmatch(r"sha256:[0-9a-f]{64}", val) is not None, "invalid scenario digest")
    return out


def selection_match(record, selected):
    # A version label alone cannot prove an immutable selected bundle/spec.
    keys = ("scenario_id", "version", "bundle_fingerprint", "spec_digest")
    if any(record[k] is not None and selected[k] is not None and record[k] != selected[k] for k in keys):
        return "different"
    if not record["version"] or not selected["version"]:
        return "unknown"
    if not any(selected[k] for k in ("bundle_fingerprint", "spec_digest")):
        return "unknown"
    if any(selected[k] and not record[k] for k in ("bundle_fingerprint", "spec_digest")):
        return "unknown"
    return "exact"


def proof_history(value, source_ids):
    require(isinstance(value, dict) and value.get("review_status") in ("pending", "complete"), "invalid proof review status")
    require(type(value.get("fixture", False)) is bool, "invalid proof fixture flag")
    out = {"review_status": value["review_status"], "fixture": value.get("fixture", False),
           "selected": scenario_identity(value.get("selected")), "records": [],
           "note": text(value.get("note"), "proof scope")}
    records = value.get("records")
    require(isinstance(records, list) and len(records) <= 500, "invalid proof records")
    seen = set()
    for index, record in enumerate(records):
        require(isinstance(record, dict), "proof record must be an object")
        row = scenario_identity(record)
        require(row["scenario_id"] == out["selected"]["scenario_id"], "proof must bind the stable scenario id")
        require(record.get("agent_kind") in ("scripted-reference", "model", "human", "mock-offline", "unit-test", "unknown"), "invalid proof agent kind")
        require(record.get("objective_result") in ("win", "loss", "failure", "no-result", "not-observed", "unknown", "partial", "scored", "complete", "admitted", "constructor", "mocked"), "invalid objective result")
        require(record.get("platform") in ("local", "old-aws", "new-aws", "unknown"), "invalid proof platform")
        row.update(record_id=text(record.get("record_id", str(index + 1)), "proof record id", 200),
                   agent_kind=record["agent_kind"], objective_result=record["objective_result"], platform=record["platform"],
                   agent_identity=text(record.get("agent_identity"), "agent identity", 500),
                   run_id=text(record.get("run_id"), "run identity", 500), occurred_at=record.get("occurred_at"),
                   limitations=text(record.get("limitations"), "proof limitations"), sources=links(record.get("sources", [])))
        timestamp(row["occurred_at"])
        refs = record.get("source_ids", [])
        require(isinstance(refs, list) and all(isinstance(v, str) and v in source_ids for v in refs), "invalid proof source reference")
        row["source_ids"] = refs
        offline = record.get("offline_access")
        require(offline in (None, "declared-winnable", "not-demonstrated", "unknown"), "invalid offline access check")
        row["offline_access"] = offline
        if offline == "declared-winnable":
            require(row["agent_kind"] in ("mock-offline", "unit-test") and row["objective_result"] == "no-result" and (row["sources"] or refs), "offline access check needs provenance and cannot be an objective win")
        if row["objective_result"] == "win":
            require(row["agent_kind"] in ("scripted-reference", "model", "human"), "mock/unknown agents cannot establish an objective win")
            require(row["occurred_at"] and (row["sources"] or refs), "objective win needs original time and retained provenance")
        require(row["record_id"] not in seen, "duplicate proof record id")
        seen.add(row["record_id"])
        row["selected_match"] = selection_match(row, out["selected"])
        out["records"].append(row)
    wins = [r for r in out["records"] if r["objective_result"] == "win"]
    out["summary"] = {
        "historical_wins": len(wins),
        "proven_versions": sorted({r["version"] for r in wins if r["version"]}),
        "unversioned_wins": sum(r["version"] is None for r in wins),
        "scripted_reference_wins": sum(r["agent_kind"] == "scripted-reference" for r in wins),
        "model_wins": sum(r["agent_kind"] == "model" for r in wins),
        "selected_version_wins": sum(r["selected_match"] == "exact" for r in wins),
        "selected_reference_wins": sum(r["selected_match"] == "exact" and r["agent_kind"] == "scripted-reference" for r in wins),
        "selected_new_aws_wins": sum(r["selected_match"] == "exact" and r["platform"] == "new-aws" for r in wins),
        "offline_declared_versions": sorted({r["version"] for r in out["records"] if r["offline_access"] == "declared-winnable" and r["version"]}),
        "offline_declared": any(r["offline_access"] == "declared-winnable" for r in out["records"]),
        "selected_offline_declared": any(r["offline_access"] == "declared-winnable" and r["selected_match"] == "exact" for r in out["records"]),
    }
    return out


def validate(data):
    require(isinstance(data, dict) and data.get("schema") == SCHEMA, "invalid catalog schema")
    timestamp(data.get("generated_at"))
    require(data.get("generated_at"), "catalog needs generated_at")
    age = data.get("max_age_seconds", 86400)
    require(type(age) is int and 60 <= age <= 2592000, "max_age_seconds must be 60..2592000")
    out = {"schema": SCHEMA, "title": text(data.get("title"), "catalog title", 200),
           "generated_at": data["generated_at"], "max_age_seconds": age,
           "scope": text(data.get("scope"), "catalog scope"), "sources": [], "scenarios": [], "images": []}
    require(isinstance(data.get("sources"), list) and 0 < len(data["sources"]) <= 500, "catalog needs declared sources")
    for src in data["sources"]:
        require(isinstance(src, dict), "source must be an object")
        digest = src.get("sha256", "")
        require(re.fullmatch(r"[0-9a-f]{64}", digest) is not None, "invalid source fingerprint")
        path = text(src.get("path"), "source path")
        require(os.path.isabs(path), "source path must be absolute")
        observed, _ = fingerprint(path)
        require(observed == digest, "source changed: " + text(src.get("label"), "source label", 200))
        public = {"label": text(src.get("label"), "source label", 200), "sha256": digest}
        require(public["label"] not in [s["label"] for s in out["sources"]], "duplicate source label")
        if src.get("url"):
            public["url"] = safe_url(src["url"])
        out["sources"].append(public)
    require(isinstance(data.get("scenarios"), list) and len(data["scenarios"]) <= 200, "invalid scenarios")
    require(isinstance(data.get("images"), list) and len(data["images"]) <= 1000, "invalid images")
    ids = {"scenarios": set(), "images": set()}
    for kind in ids:
        for item in data[kind]:
            require(isinstance(item, dict), "catalog row must be an object")
            ident = item.get("id", "")
            require(isinstance(ident, str) and re.fullmatch(r"[A-Za-z0-9_.-]{1,100}", ident), "invalid catalog id")
            require(ident not in ids[kind], "duplicate catalog id")
            ids[kind].add(ident)
    for item in data["images"]:
        identity = text(item.get("identity", "unknown"), "image identity", 1000)
        require(item.get("category") in ("selected-binding", "unbound-candidate", "platform-support"), "invalid image category")
        require(isinstance(item.get("families"), list) and all(s in ids["scenarios"] for s in item["families"]), "invalid image families")
        out["images"].append({"id": item["id"], "title": text(item.get("title"), "image title", 200),
                              "category": item["category"], "identity": identity,
                              "platform": text(item.get("platform", "unknown"), "platform", 200),
                              "families": item["families"], "sources": links(item.get("sources", [])),
                              "storage": assessment(item.get("storage"), ("remote-verified", "local-only", "missing", "unknown"), identity if re.search(r"sha256:[0-9a-f]{64}$", identity) else None, [s["label"] for s in out["sources"]]),
                              "note": text(item.get("note"), "image limits")})
    for item in data["scenarios"]:
        require(isinstance(item.get("images"), list) and all(i in ids["images"] for i in item["images"]), "invalid required images")
        candidate = text(item.get("candidate"), "candidate identity", 1000)
        out["scenarios"].append({"id": item["id"], "title": text(item.get("title"), "family title", 200),
                                 "candidate": candidate, "objective": text(item.get("objective"), "objective"),
                                 "topology": text(item.get("topology"), "topology"), "images": item["images"],
                                 "binding_note": text(item.get("binding_note"), "binding limits"),
                                 "sources": links(item.get("sources", [])),
                                 "wiring": assessment(item.get("wiring"), ("wired", "unresolved", "unknown"), candidate, [s["label"] for s in out["sources"]]),
                                 "validation": assessment(item.get("validation"), ("passed", "failed", "not-demonstrated", "unknown"), candidate, [s["label"] for s in out["sources"]])})
        if "proof" in item:
            out["scenarios"][-1]["proof"] = proof_history(item["proof"], [s["label"] for s in out["sources"]])
    # Both directions are derived from the same membership, never two catalogs.
    for s in out["scenarios"]:
        for i in s["images"]:
            require(s["id"] in next(v for v in out["images"] if v["id"] == i)["families"], "image/scenario membership mismatch")
    return out


def collect(path, checked_at):
    if not os.path.lexists(path):
        return {"status": "disabled", "checked_at": checked_at}
    try:
        digest, raw = fingerprint(path)
        out = validate(json.loads(raw))
        out.update(status="ok", checked_at=checked_at, projection_sha256=digest)
        return out
    except (OSError, ValueError, TypeError, KeyError, OverflowError) as exc:
        # Do not return raw provider/file data or private absolute paths.
        note = str(exc) if isinstance(exc, ValueError) and not isinstance(exc, json.JSONDecodeError) else "catalog or declared source could not be read/validated"
        return {"status": "error", "checked_at": checked_at, "error": note[:300]}


def view(snapshot, path, now):
    out = copy.deepcopy(snapshot or {"status": "uncollected" if os.path.lexists(path) else "disabled"})
    if out["status"] == "disabled" and os.path.lexists(path):
        return {"status": "uncollected"}
    if out["status"] != "ok":
        return out
    changed = False
    try:
        changed = fingerprint(path)[0] != out["projection_sha256"]
    except (OSError, ValueError):
        changed = True
    stale = changed or now - timestamp(out["checked_at"]) > out["max_age_seconds"] or now - timestamp(out["generated_at"]) > out["max_age_seconds"]
    out["status"] = "stale" if stale else "ok"
    out["refresh_needed"] = changed
    for kind, fields in (("scenarios", ("wiring", "validation")), ("images", ("storage",))):
        for row in out[kind]:
            for field in fields:
                evidence = row[field]
                t = timestamp(evidence["checked_at"])
                evidence["freshness"] = "stale" if stale or (t is not None and now - t > out["max_age_seconds"]) else "undated" if t is None else "fresh"
    return out
