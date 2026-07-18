# Review an agent-generated patch

Status: runnable review exercise with a deliberately flawed, non-buildable
QEMU-style fixture.

Baseline: QEMU `v11.1.0`; source-review anchor `v11.1.0-rc0`; RISC-V
`riscv64` device context.

## Purpose

Evaluate a candidate device-model patch produced with agent assistance using
the same evidence, safety, compatibility, and upstream-review standards as
human-written code.

## Prerequisites

- Python 3.10 or newer for the fixture-integrity check.
- Optionally, a disposable QEMU branch containing a candidate patch and its
  input provenance where policy permits.
- QEMU coding style, test, security, licensing, and contribution guidance.

## Files

- `README.md`: review procedure.
- `review-checklist.md`: evidence, safety, lifetime, and compatibility gates.
- `fixtures/flawed-device.c`: deliberately flawed, non-buildable review input.
- `expected-findings.md`: minimum defect ledger for self-checking.
- `check_fixture.py`: verifies that intentional markers remain in the fixture.

## Steps

1. Run `python3 check_fixture.py`, then review the C fixture without opening
   `expected-findings.md`; write one evidence-backed finding per invariant.
2. Compare the result with `expected-findings.md` and explain any additional
   or missing item. Do not compile or copy the fixture into QEMU.
3. Verify every type, register, bit, address, callback, and source path in a
   real candidate patch against
   the `v11.1.0` anchor and cited hardware/ABI evidence.
4. Review guest-controlled lengths, integer overflow, DMA ranges, lifetime,
   thread/BQL, reset, unrealize, error, and migration paths.
5. Build and run focused tests, sanitizers where supported, style checks, and
   negative inputs; reject tests that only mirror the implementation.
6. Compare the patch with relevant Git history and qemu-devel review; record
   unresolved uncertainty instead of filling it with generated rationale.

## Expected results

The fixture check reports five intact markers, and manual review finds at least
the ten independent defects in `expected-findings.md`. A real review yields an
evidence-linked go/revise/reject decision; origin neither excuses defects nor
proves that code is incorrect.

## Cleanup

Delete local review output and untrusted generated artifacts. Discard the
disposable branch unless the patch passes normal review and licensing gates.

## Troubleshooting

- Compiling is only one gate; lifecycle and migration defects can remain.
- Never invent upstream citations or reviewer positions to complete a ledger.
