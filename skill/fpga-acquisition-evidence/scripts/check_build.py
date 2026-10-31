#!/usr/bin/env python3
"""Read-only manifest/hash/report-header and raw-image partition checks. No FPGA tools."""
import argparse
import hashlib
import json
import re
import sys
from pathlib import Path


def number(value):
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        raise ValueError("address/size must be an integer or a base-prefixed integer string")
    return int(value, 0) if isinstance(value, str) else value


def digest(path):
    sha = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            sha.update(chunk)
    return sha.hexdigest()


def check(path):
    manifest = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(manifest, dict):
        raise ValueError("manifest must be a JSON object")
    if not isinstance(manifest.get("build_id"), str) or not manifest["build_id"]:
        raise ValueError("nonempty build_id required")
    partitions = {}
    if not isinstance(manifest.get("partitions", []), list):
        raise ValueError("partitions must be an array")
    for part in manifest.get("partitions", []):
        if not isinstance(part, dict):
            raise ValueError("partition must be an object")
        name = part["name"]
        start, end = number(part["start"]), number(part["end_exclusive"])
        if start < 0 or end <= start or name in partitions:
            raise ValueError("invalid or duplicate partition")
        for other_start, other_end in partitions.values():
            if start < other_end and other_start < end:
                raise ValueError("partition ranges overlap")
        partitions[name] = (start, end)
    artifacts = manifest.get("artifacts", [])
    if not isinstance(artifacts, list) or not artifacts:
        raise ValueError("at least one artifact required")
    checks = []
    used_ranges = []
    for artifact in artifacts:
        if not isinstance(artifact, dict) or not isinstance(artifact.get("path"), str):
            raise ValueError("artifact must be an object with a path string")
        kind = artifact["kind"]
        if kind not in ("raw_image", "report", "file"):
            raise ValueError("kind must be raw_image/report/file")
        if not isinstance(artifact.get("sha256"), str):
            raise ValueError("explicit SHA256 string required for every artifact")
        expected = artifact["sha256"].lower()
        if not re.fullmatch(r"[0-9a-f]{64}", expected):
            raise ValueError("explicit SHA256 required for every artifact")
        artifact_path = path.parent / artifact["path"]
        size = artifact_path.stat().st_size
        actual = digest(artifact_path)
        errors = []
        if actual != expected:
            errors.append("sha256 mismatch")
        if "size_bytes" in artifact and size != number(artifact["size_bytes"]):
            errors.append("size mismatch")
        item = {"path": artifact["path"], "kind": kind, "size_bytes": size,
                "sha256": actual, "errors": errors}
        if kind == "raw_image":
            if artifact_path.suffix.lower() != ".bin":
                raise ValueError("raw_image accepts .bin only; do not map .bit headers to flash addresses")
            start = number(artifact["start"])
            end = start + size
            part_start, part_end = partitions[artifact["partition"]]
            if not size or start < part_start or end > part_end:
                errors.append("raw image outside target partition or empty")
            for previous_start, previous_end in used_ranges:
                if start < previous_end and previous_start < end:
                    errors.append("raw images overlap")
            used_ranges.append((start, end))
            item["range"] = {"start": hex(start), "end_exclusive": hex(end),
                             "partition": artifact["partition"]}
        elif kind == "report":
            # Match report-header fields, never an arbitrary mention in a report body.
            fields = {}
            with artifact_path.open(encoding="utf-8-sig", errors="strict") as report:
                for _, line in zip(range(80), report):
                    match = re.match(r"\s*\|\s*([^:|]+?)\s*:\s*(.*?)\s*$", line)
                    if match:
                        fields[match[1].strip()] = match[2].strip()
            expected_headers = artifact.get("expected_headers", {})
            if not isinstance(expected_headers, dict) or not expected_headers:
                raise ValueError("report requires expected_headers exact key/value mapping")
            for key, value in expected_headers.items():
                if not isinstance(value, str):
                    raise ValueError("expected report header values must be strings")
                if fields.get(key) != value:
                    errors.append(f"report header mismatch: {key}")
            item["observed_headers"] = fields
        item["ok"] = not errors
        checks.append(item)
    return {"ok": all(item["ok"] for item in checks), "build_id": manifest["build_id"],
            "checks": checks,
            "limits": ["manifest expectations must come from the intended release, not the files being checked",
                       "matching hashes/headers do not prove common synthesis provenance or hardware acceptance",
                       "image bounds do not inspect programming erase policy, MCS addressing or A/B record CRC",
                       "positive WNS or Routed alone does not establish complete I/O constraints or zero DRC warnings"]}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--manifest", required=True)
    args = p.parse_args()
    try:
        result = check(Path(args.manifest))
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0 if result["ok"] else 1
    except (OSError, ValueError, TypeError, KeyError, UnicodeError) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}))
        return 2


if __name__ == "__main__":
    sys.exit(main())
