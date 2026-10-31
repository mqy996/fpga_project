#!/usr/bin/env python3
"""Stream-check the current full-24-channel recorder TXT format, never rewriting it."""
import argparse
import csv
import json
import sys
from decimal import Decimal, InvalidOperation
from pathlib import Path

MOD = 1 << 32
HEADER = ["packet_sequence", "sample_index", "time_us"] + [
    f"CH{ch:02}_{suffix}" for ch in range(24) for suffix in ("code", "V")]


def check(args):
    count = failures = regressions = 0
    examples = []
    truncated = False
    epoch = 0
    last_sequence = None
    previous_index = None
    current_seq = base = None

    def fail(line, message):
        nonlocal failures
        failures += 1
        if len(examples) < 20:
            examples.append({"line": line, "error": message})

    with Path(args.input).open(encoding="utf-8-sig", newline="") as source:
        reader = csv.reader(source, delimiter="\t", strict=True)
        header = next(reader, None)
        if header != HEADER:
            return {"ok": False, "error": "header differs from documented 51-column profile",
                    "scan": {"rows": 0, "complete": False}}
        for line, row in enumerate(reader, 2):
            if args.limit and count >= args.limit:
                truncated = True
                break
            position = count % args.groups
            count += 1
            try:
                if len(row) != 51:
                    raise ValueError(f"expected 51 fields, found {len(row)}")
                seq, index, time_us = map(int, row[:3])
                if not 0 <= seq < MOD or index < 0 or time_us < 0:
                    raise ValueError("unsigned metadata outside range")
                if position == 0:
                    packet_epoch = epoch
                    if last_sequence is None:
                        last_sequence = seq
                    else:
                        distance = (seq - last_sequence) % MOD
                        if distance == MOD // 2:
                            raise ValueError("ambiguous half-range serial distance")
                        if 0 < distance < MOD // 2:
                            if seq < last_sequence:
                                epoch += 1
                            last_sequence = seq
                            packet_epoch = epoch
                        elif distance >= MOD // 2 and seq > last_sequence and epoch > 0:
                            packet_epoch = epoch - 1
                    extended = (packet_epoch << 32) | seq
                    base = max(extended - 1, 0) * args.groups
                    current_seq = seq
                if seq != current_seq:
                    raise ValueError("packet_sequence changes within configured group block")
                if index != base + position:
                    raise ValueError(f"sample_index expected {base + position}, got {index}")
                if time_us != index * 1000000 // args.rate:
                    raise ValueError("time_us differs from floor(sample_index * 1000000 / rate)")
                if previous_index is not None and index <= previous_index:
                    regressions += 1
                previous_index = index
                for ch in range(24):
                    code = int(row[3 + 2 * ch])
                    voltage = Decimal(row[4 + 2 * ch])
                    if not -32768 <= code <= 32767 or not voltage.is_finite():
                        raise ValueError(f"CH{ch:02} code/voltage outside domain")
                    ideal = Decimal(code) * args.full_scale / Decimal(32768)
                    if abs(voltage - ideal) > args.tolerance:
                        raise ValueError(f"CH{ch:02} voltage inconsistent with code")
            except (ValueError, InvalidOperation) as exc:
                fail(line, str(exc))
        if not count:
            fail(1, "no sample rows")
        if not truncated and count % args.groups:
            fail(count + 1, "EOF in incomplete packet group block")
    return {"ok": failures == 0, "input": str(Path(args.input)),
            "scan": {"rows": count, "limit": args.limit, "complete": not truncated,
                     "scope": "whole_file" if not truncated else "prefix_only",
                     "last_scanned_line": count + 1},
            "profile": {"channels": 24, "columns": 51, "rate": args.rate,
                        "groups": args.groups, "full_scale_v": str(args.full_scale)},
            "row_error_count": failures, "errors_first_20": examples,
            "nonincreasing_sample_indices": regressions,
            "limits": ["matches recorder serialization, not analog calibration or ADC timing",
                       "sample_index is reconstructed from packet sequence, not a hardware timestamp",
                       "fixed 51-column layout; different recorder formats require an adapter",
                       "sequence epoch starts at zero for each file, matching current recorder"]}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--input", required=True)
    p.add_argument("--rate", type=int, required=True)
    p.add_argument("--groups", type=int, required=True)
    p.add_argument("--full-scale", type=Decimal, default=Decimal("10"))
    p.add_argument("--tolerance", type=Decimal, default=Decimal("0.000051"),
                   help="absolute voltage error; default covers four decimal places")
    p.add_argument("--limit", type=int, default=0, help="maximum sample rows; 0 reads all")
    args = p.parse_args()
    try:
        if args.rate <= 0 or args.groups <= 0 or args.limit < 0:
            raise ValueError("positive rate/groups and nonnegative limit required")
        if not args.full_scale.is_finite() or not args.tolerance.is_finite() or args.full_scale <= 0 or args.tolerance < 0:
            raise ValueError("finite positive full scale and finite nonnegative tolerance required")
        result = check(args)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0 if result["ok"] else 1
    except (OSError, UnicodeError, csv.Error, ValueError, InvalidOperation) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}))
        return 2


if __name__ == "__main__":
    sys.exit(main())
