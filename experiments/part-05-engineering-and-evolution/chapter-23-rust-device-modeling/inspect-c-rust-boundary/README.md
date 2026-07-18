# Inspect the C/Rust boundary

Status: source-inspection with runnable Rust unit tests when configured.

Baseline: QEMU `v11.1.0`; source-review anchor `v11.1.0-rc0`; RISC-V
`riscv64` remains the device-modeling context.

## Purpose

Audit one path where Rust QOM/device code calls C or receives a C callback and
state the safety invariant that cannot be checked by the Rust type system.

## Prerequisites

- `QEMU_SRC`, a Rust-enabled build in `QEMU_BUILD`, and Rust toolchain.
- Basic FFI, ownership, and QOM lifecycle knowledge.

## Files

- `README.md`: audit and optional test procedure.
- `inspect.sh`: QOM ownership, sysbus FFI, qdev callback, BQL, and binding
  source inventory.
- `results/ffi-audit.txt`: generated boundary evidence.

## Steps

1. Set `QEMU_SRC` and run `./inspect.sh`, then select one recorded FFI callback
   path relevant to a sysbus device.
2. Follow generated bindings, wrapper type, unsafe block, and C implementation.
3. Record pointer validity, thread/BQL, aliasing, error, and lifetime
   assumptions.
4. Run available focused Rust tests with `meson test -C "$QEMU_BUILD" --list`
   as the authoritative name source.

## Expected results

The audit identifies a small unsafe boundary with explicit invariants and shows
which invariants have tests versus review-only enforcement.

## Cleanup

Remove local notes and test-output copies; keep the build tree intact.

## Troubleshooting

- Generated bindings can live in the build tree as well as source wrappers.
- Do not claim memory safety for assumptions that rely on external C code.
