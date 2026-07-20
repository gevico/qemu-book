# Test a migration boundary

Status: two-host RISC-V KVM migration procedure with committed preflight
collectors and comparator; the live switchover remains an explicit QMP step.

Target release: QEMU `v11.1.0`; source-review baseline `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Test one live-migration path and one deliberately incompatible path to expose
the contract among machine type, CPU features, KVM state, and destination host.

## Prerequisites

- Two isolated RISC-V KVM hosts with matching QEMU binaries and network policy.
- A checksum-producing guest and explicit migration transport.

## Files

- `README.md`: manual QMP orchestration procedure.
- `collect_host.py`: hashes and records conservative host/QEMU inputs.
- `compare_manifests.py` and `test_compare_manifests.py`: fail-closed preflight
  comparison without pretending to certify migration.
- `results/source/` and `results/destination/`: local logs and source reports.

## Steps

1. On each host run `./collect_host.py --qemu /path/to/qemu-system-riscv64
   --label HOST --output results/HOST/manifest.json`.
2. Run `./compare_manifests.py SOURCE.json DESTINATION.json`. Resolve every
   mismatch, then record CPU feature expansion and host-kernel KVM capability.
3. Start matching source and incoming destination guests; migrate via QMP.
4. Verify guest continuity and checksum after switchover.
5. Change exactly one supported CPU or machine property and repeat, expecting
   either a compatibility rejection or a documented constrained outcome.

## Expected results

The comparator reports no preflight mismatches before the matching case. That
is necessary evidence only; the live case must still preserve guest-visible
state. The incompatible run fails explicitly or demonstrates a precisely
documented compatibility rule.

## Cleanup

Quit both QEMU instances and remove only overlays, sockets, and result files
created for this lab.

## Troubleshooting

- Never use a production disk; use overlays and verify their backing files.
- Network failure and compatibility failure need separate evidence.
