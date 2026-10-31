#!/usr/bin/env python3
"""Read-only validation of the documented 12-byte acquisition UDP profile."""
import argparse
import json
import struct
import sys
from pathlib import Path

MOD = 1 << 32


def integer(text):
    return int(text, 0)


def profile(rate, mask, groups, channels, max_groups, mtu):
    if rate <= 0 or not 1 <= channels <= 32 or mask <= 0 or mask >> channels:
        raise ValueError("positive rate and nonempty in-range channel mask required")
    if not 1 <= groups <= max_groups:
        raise ValueError("groups outside configured range")
    count = mask.bit_count()
    payload = 12 + 2 * count * groups
    if payload + 28 > mtu:
        raise ValueError("payload exceeds unfragmented IPv4 MTU (20-byte IP header)")
    pps = rate / groups
    # Ethernet minimum frame: 64 bytes including FCS, plus 8 preamble and 12 IFG.
    wire_bytes = max(64, 14 + 20 + 8 + payload + 4) + 8 + 12
    return {"rate_sps_per_channel": rate, "mask": hex(mask), "channels": count,
            "groups": groups, "payload_bytes": payload, "packets_per_second": pps,
            "raw_sample_mbps": rate * count * 16 / 1e6,
            "udp_payload_mbps": payload * pps * 8 / 1e6,
            "estimated_ethernet_mbps": wire_bytes * pps * 8 / 1e6,
            "basis": "theory; IPv4 without options/VLAN; Ethernet padding/FCS/preamble/IFG included"}


def check(args):
    seen = set()
    high = low = None
    duplicates = reordered = gap_events = opened_gaps = wraps = valid = scanned = 0
    errors = []
    error_count = 0
    profiles = {}
    truncated = False
    with Path(args.input).open(encoding="utf-8-sig") as source:
        for line_no, line in enumerate(source, 1):
            if args.limit and scanned >= args.limit:
                truncated = True
                break
            scanned += 1
            try:
                raw = bytes.fromhex(json.loads(line)["payload_hex"])
                if len(raw) < 12:
                    raise ValueError("short 12-byte application header")
                seq, rate, mask = struct.unpack_from(">III", raw)
                count = mask.bit_count()
                if count == 0 or (len(raw) - 12) % (2 * count):
                    raise ValueError("body is not an integral number of nonempty groups")
                groups = (len(raw) - 12) // (2 * count)
                item = profile(rate, mask, groups, args.channels, args.max_groups, args.mtu)
                if rate not in args.rates:
                    raise ValueError("rate not in allowed profile")
                for field, expected, actual in [("rate", args.expected_rate, rate),
                                                 ("mask", args.expected_mask, mask),
                                                 ("groups", args.groups, groups)]:
                    if expected is not None and expected != actual:
                        raise ValueError(f"unexpected {field}: {actual}")
                if high is None:
                    extended = seq
                else:
                    delta = (seq - (high % MOD)) % MOD
                    if delta == MOD // 2:
                        raise ValueError("ambiguous half-range serial distance")
                    extended = high + (delta if delta < MOD // 2 else delta - MOD)
                valid += 1
                key = f"{rate}/{mask}/{groups}"
                profiles[key] = item
                if extended in seen:
                    duplicates += 1
                    continue
                seen.add(extended)
                if high is None:
                    high = low = extended
                else:
                    if extended < high:
                        reordered += 1
                    elif extended > high:
                        gap = extended - high - 1
                        if gap:
                            gap_events += 1
                            opened_gaps += gap
                        if seq < high % MOD:
                            wraps += 1
                        high = extended
                    low = min(low, extended)
            except (ValueError, KeyError, TypeError, struct.error) as exc:
                error_count += 1
                if len(errors) < 20:
                    errors.append({"line": line_no, "error": str(exc)})
    if not scanned:
        error_count += 1
        errors.append({"error": "empty input"})
    missing = 0 if high is None else high - low + 1 - len(seen)
    return {"ok": error_count == 0, "input": str(Path(args.input)),
            "scan": {"records": scanned, "limit": args.limit, "complete": not truncated},
            "valid_records": valid, "unique_sequences": len(seen), "duplicates": duplicates,
            "out_of_order_unique": reordered, "forward_gap_events": gap_events,
            "provisionally_opened_gaps": opened_gaps, "forward_wraps": wraps,
            "unobserved_within_sequence_span": missing,
            "sequence_span": None if high is None else [low, high],
            "error_count": error_count, "errors_first_20": errors,
            "profiles": list(profiles.values()),
            "limits": ["single sequence session; no reset inference; serial step must be less than 2^31",
                       "unobserved span positions are capture gaps, not proven link or ADC loss",
                       "valid payload/continuous sequence does not establish uninterrupted ADC cadence",
                       "memory is O(unique sequences); use limit for very large captures"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("check", "budget"):
        p = sub.add_parser(name)
        p.add_argument("--channels", type=int, default=24)
        p.add_argument("--max-groups", type=int, default=30)
        p.add_argument("--mtu", type=int, default=1500)
        if name == "check":
            p.add_argument("--input", required=True, help="JSONL; one payload_hex string per UDP payload")
            p.add_argument("--rates", type=int, nargs="+", default=[250000, 500000, 1000000])
            p.add_argument("--expected-rate", type=int)
            p.add_argument("--expected-mask", type=integer)
            p.add_argument("--groups", type=int)
            p.add_argument("--limit", type=int, default=0, help="0 scans all records")
        else:
            p.add_argument("--rate", type=int, required=True)
            p.add_argument("--mask", type=integer, required=True)
            p.add_argument("--groups", type=int, required=True)
    args = parser.parse_args()
    try:
        if getattr(args, "limit", 0) < 0:
            raise ValueError("limit must be nonnegative")
        result = check(args) if args.command == "check" else {
            "ok": True, **profile(args.rate, args.mask, args.groups,
                                  args.channels, args.max_groups, args.mtu)}
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0 if result["ok"] else 1
    except (OSError, ValueError, UnicodeError) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}))
        return 2


if __name__ == "__main__":
    sys.exit(main())
