# Run RISC-V qtests

Status: runnable from a configured QEMU build.

Target release: QEMU `v11.1.0`; source-review baseline `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Run focused RISC-V qtests and connect each test's observable contract to the
source it protects.

## Prerequisites

- `QEMU_SRC` and `QEMU_BUILD` from the same exact revision.
- A build configured with RISC-V system emulation and qtests.
- Python 3 and the `meson` command used by that configured build.

## Files

- `README.md`: test selection and review procedure.
- `run_qtests.py`: configured-name discovery, focused selection, and verbose
  Meson execution.
- `test_run_qtests.py`: Meson suite-prefix parsing regression tests.
- `results/testlog.txt`: generated Meson test log.

## Steps

1. Run `python3 -m unittest -v test_run_qtests.py`. Set `QEMU_BUILD` and run
   `./run_qtests.py`; optionally constrain the exact configured names with
   `TEST_PATTERN` and `MAX_TESTS`.
2. Inspect `results/all-tests.txt` and `results/selected-tests.txt`; the script
   falls back to configured RISC-V names only when no CSR/IOMMU name matches.
3. Review the verbose `--print-errorlogs` output in `results/testlog.txt`.
4. Read each test source and record the interface, failure assertion, and
   untested boundary.

## Expected results

Both name-parsing tests and the configured focused tests pass, and each result
can be tied to explicit assertions; unavailable tests are recorded as
configuration skips.

## Cleanup

Remove copied result logs; Meson's own build-tree logs may remain.

## Troubleshooting

- Test names are configuration-dependent; always begin with `--list`.
- A skipped test is not a pass and should retain its skip reason.
