#!/usr/bin/env python3
"""Validate synthetic examples; write only the package's validation.json."""
import datetime
import hashlib
import json
import platform
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CASES = [
    ("udp-wrap-reorder-duplicate-gap", "check_udp.py", ["check", "--input", "fixtures/udp-observation.jsonl", "--groups", "2"], 0,
     {"valid_records": 5, "duplicates": 1, "out_of_order_unique": 1, "forward_wraps": 1,
      "unobserved_within_sequence_span": 1, "provisionally_opened_gaps": 2}),
    ("udp-late-gap-recovery", "check_udp.py", ["check", "--input", "fixtures/udp-recovered.jsonl", "--groups", "2"], 0,
     {"out_of_order_unique": 1, "unobserved_within_sequence_span": 0}),
    ("udp-invalid-payloads", "check_udp.py", ["check", "--input", "fixtures/udp-bad.jsonl"], 1,
     {"error_count": 4, "valid_records": 0}),
    ("udp-prefix-explicit", "check_udp.py", ["check", "--input", "fixtures/udp-observation.jsonl", "--limit", "2"], 0,
     {"scan.complete": False, "scan.records": 2, "unobserved_within_sequence_span": 1}),
    ("udp-exact-eof", "check_udp.py", ["check", "--input", "fixtures/udp-observation.jsonl", "--limit", "5"], 0,
     {"scan.complete": True, "scan.records": 5}),
    ("udp-profile-mismatch", "check_udp.py", ["check", "--input", "fixtures/udp-recovered.jsonl", "--expected-rate", "250000"], 1,
     {"error_count": 3}),
    ("budget-full24-1msps", "check_udp.py", ["budget", "--rate", "1000000", "--mask", "0xffffff", "--groups", "30"], 0,
     {"payload_bytes": 1452, "raw_sample_mbps": 384.0, "estimated_ethernet_mbps": 404.8}),
    ("budget-minimum-ethernet-frame", "check_udp.py", ["budget", "--rate", "250000", "--mask", "1", "--groups", "1"], 0,
     {"payload_bytes": 14, "estimated_ethernet_mbps": 168.0}),
    ("budget-mtu-rejection", "check_udp.py", ["budget", "--rate", "1000000", "--mask", "0xffffff", "--groups", "31", "--max-groups", "31"], 2,
     {"ok": False}),
    ("txt-good-with-sequence-gap", "check_txt.py", ["--input", "fixtures/txt-good.txt", "--rate", "500000", "--groups", "2"], 0,
     {"scan.rows": 6, "scan.complete": True, "row_error_count": 0}),
    ("txt-wrap-and-delayed-previous-epoch", "check_txt.py", ["--input", "fixtures/txt-wrap.txt", "--rate", "1000000", "--groups", "2"], 0,
     {"scan.rows": 8, "row_error_count": 0, "nonincreasing_sample_indices": 1}),
    ("txt-bad-time-and-voltage", "check_txt.py", ["--input", "fixtures/txt-bad.txt", "--rate", "500000", "--groups", "2"], 1,
     {"row_error_count": 2}),
    ("txt-prefix-incomplete-group-allowed", "check_txt.py", ["--input", "fixtures/txt-good.txt", "--rate", "500000", "--groups", "2", "--limit", "3"], 0,
     {"scan.complete": False, "scan.scope": "prefix_only", "scan.rows": 3}),
    ("txt-exact-eof", "check_txt.py", ["--input", "fixtures/txt-good.txt", "--rate", "500000", "--groups", "2", "--limit", "6"], 0,
     {"scan.complete": True}),
    ("txt-truncated-eof-rejected", "check_txt.py", ["--input", "fixtures/txt-truncated.txt", "--rate", "500000", "--groups", "2"], 1,
     {"row_error_count": 1}),
    ("build-good", "check_build.py", ["--manifest", "fixtures/build-good.json"], 0,
     {"checks.0.ok": True, "checks.1.ok": True}),
    ("build-crosses-boot-partition", "check_build.py", ["--manifest", "fixtures/build-boundary-bad.json"], 1,
     {"checks.0.ok": False, "checks.0.errors.0": "raw image outside target partition or empty"}),
    ("build-wrong-tool-version", "check_build.py", ["--manifest", "fixtures/build-version-bad.json"], 1,
     {"checks.1.ok": False, "checks.1.errors.0": "report header mismatch: Tool Version"}),
    ("build-wrong-hash", "check_build.py", ["--manifest", "fixtures/build-hash-bad.json"], 1,
     {"checks.0.errors.0": "sha256 mismatch"}),
    ("udp-missing-input", "check_udp.py", ["check", "--input", "fixtures/nonexistent.jsonl"], 2, {"ok": False}),
    ("txt-missing-input", "check_txt.py", ["--input", "fixtures/nonexistent.txt", "--rate", "500000", "--groups", "2"], 2, {"ok": False}),
    ("build-missing-input", "check_build.py", ["--manifest", "fixtures/nonexistent.json"], 2, {"ok": False}),
]


def field(value, dotted):
    for key in dotted.split("."):
        value = value[int(key)] if isinstance(value, list) else value[key]
    return value


def main():
    results = []
    for name, script, argv, code, expectations in CASES:
        command = [sys.executable, str(ROOT / "scripts" / script), *argv]
        completed = subprocess.run(command, cwd=ROOT, capture_output=True, text=True,
                                   encoding="utf-8", timeout=15)
        assertion_errors = []
        if completed.returncode != code:
            assertion_errors.append(f"return code expected {code}, got {completed.returncode}")
        try:
            observed = json.loads(completed.stdout)
            for key, expected in expectations.items():
                actual = field(observed, key)
                if actual != expected:
                    assertion_errors.append(f"{key}: expected {expected!r}, got {actual!r}")
        except (ValueError, KeyError, IndexError, TypeError) as exc:
            observed = {"stdout": completed.stdout, "parse_error": str(exc)}
            assertion_errors.append("output missing expected JSON fields")
        results.append({"name": name, "command": ["python", "scripts/" + script, *argv],
                        "expected_exit": code, "actual_exit": completed.returncode,
                        "expectations": expectations, "passed": not assertion_errors,
                        "assertion_errors": assertion_errors, "observed": observed,
                        "stderr": completed.stderr})
    files = sorted([*ROOT.joinpath("scripts").glob("*.py"), *ROOT.joinpath("fixtures").iterdir()])
    fingerprints = {path.relative_to(ROOT).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in files if path.is_file()}
    report = {"generated_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "python": platform.python_version(), "platform": platform.platform(),
              "evidence_kind": "executed synthetic checker validation; not hardware measurement",
              "cases": len(results), "passed": sum(result["passed"] for result in results),
              "ok": all(result["passed"] for result in results), "results": results,
              "input_and_script_sha256": fingerprints,
              "limits": ["no real captured UDP/TXT files were provided for these checker runs",
                         "no new FPGA synthesis/implementation, Qt execution, flashing or board test",
                         "fixtures are tiny; performance and large-file duration not benchmarked"]}
    target = ROOT / "validation.json"
    target.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"ok": report["ok"], "passed": report["passed"], "cases": len(results),
                      "report": "validation.json"}))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
