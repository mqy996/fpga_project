---
name: fpga-acquisition-evidence
description: Diagnose and check FPGA ADC-to-UDP acquisition evidence, 24-channel TXT recordings, and build/flash partition manifests. Use for channel alignment, capture integrity, delivery consistency, and evidence-bounded reporting; adapt fixed protocol layouts before using other formats.
---

# FPGA acquisition evidence

Use this skill when a request concerns ADC frame alignment, acquisition CDC/backpressure, recorded UDP/TXT consistency, or matching build artifacts to reported results. The submitted entrypoint is lowercase for contest packaging; installation requires an `SKILL.md` copy as explained in `../readme.md`.

Establish the actual contract before applying a checker: ADC model/interface and frame-start semantics, channel numbering, sample-rate definition, packet byte order/layout, recorder layout, build identifier and flash address units. Preserve the user's task, existing project task rules and hardware authorization.

Read only the reference needed for the current failure:

- Fixed channel rotation, frame boundaries or pipelined conversion: [adc-frame.md](references/adc-frame.md).
- FIFO/CDC/reset/backpressure or configuration persistence: [cdc-flash.md](references/cdc-flash.md).
- Packet sequence statistics, TXT interpretation, theoretical bandwidth and build evidence: [udp-txt-build.md](references/udp-txt-build.md).

Run the matching standard-library script only when the input has the documented format:

```text
python scripts/check_udp.py check --input capture.jsonl --expected-rate 500000 --expected-mask 0xffffff --groups 30
python scripts/check_udp.py budget --rate 1000000 --mask 0xffffff --groups 30
python scripts/check_txt.py --input capture.txt --rate 500000 --groups 30
python scripts/check_build.py --manifest release-manifest.json
```

Paths above are relative to this skill directory; use absolute paths from other working directories. JSON output goes to stdout. Exit codes: 0 pass within reported scope, 1 detected inconsistency, 2 unavailable/malformed input or invocation. Missing input must remain a failure. Do not treat process return code alone as proof: read the observed failures, scan scope and limits. A sequence gap is reported separately from payload validity, so a syntactically valid capture with gaps may return 0; inspect `unobserved_within_sequence_span` and duplicates explicitly.

`check_udp.py` expects one JSON object with `payload_hex` per line, containing a 12-byte big-endian seq/rate/mask header followed by signed16 samples ordered by group, then enabled channel. It is not a PCAP parser. The sample values need a golden reference to prove channel identity. Its sequence set uses O(unique sequences) memory; `--limit` bounds the observation and must be disclosed.

`check_txt.py` streams the current 51-column full24 recorder format with constant row memory. Its sample/time checks reproduce the documented recorder serialization, including wrap handling; these are sequence-derived coordinates, not independent hardware timestamps. `--limit` validates only a prefix if additional rows exist. A format match does not establish analog accuracy or disk throughput.

`check_build.py` reads explicit expected hashes, raw-BIN target partitions and exact report-header values from a JSON manifest. It performs no synthesis, implementation or programming. Expectations created from the same files only establish snapshot self-consistency, not release provenance.

Report the input/version, scanned scope, actual result and claim boundary. Keep source design, simulation, routed tool report, user-confirmed hardware function and raw measured board results distinct. A user confirmation may establish functional acceptance, but does not supply an unreported duration, quantified loss rate, fault-injection result or analog accuracy. Positive WNS under existing constraints does not prove all I/O constraints are complete. Parameter A/B does not imply bitstream A/B or rollback boot.

For reproducible tool examples, run `python scripts/validate_examples.py`; it overwrites only this package's `validation.json`. Fixtures are synthetic and must never be presented as board recordings. Hardware changes, flashing, tool builds, installations and publication are outside these read-only checkers and need the task's own authorization.
