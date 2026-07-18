# Inspect the K230 machine

Status: source-inspection with runnable machine introspection when configured.

Baseline: QEMU `v11.1.0`; source-review anchor `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Recover QEMU's implemented K230 CPU, memory, interrupt, peripheral, and boot
topology, then identify what the model deliberately does not emulate.

## Prerequisites

- `QEMU_SRC` and a build exposing the K230 machine.
- Official public hardware documentation for claims beyond QEMU source.

## Files

- `README.md`: source/runtime inspection procedure.
- `inspect-k230.sh`: source inventory and optional runtime property capture.
- `results/k230-inventory.md`: generated local implementation matrix.

## Steps

1. Set `QEMU_SRC`; optionally set `QEMU_BUILD` or `QEMU_SYSTEM_RISCV64`.
2. Run `./inspect-k230.sh` and inspect the generated source and property files.
3. If a bootable configuration is available, start it paused and capture
   `info qom-tree` plus `info mtree` as a separate runtime result.
4. Classify implemented, stubbed, firmware-dependent, and absent components;
   cite evidence for every classification.

## Expected results

The inventory distinguishes the QEMU machine's supported boot/use case from a
claim of complete K230 SoC fidelity.

## Cleanup

Quit QEMU and remove the local `results/` directory.

## Troubleshooting

- A board name in source does not imply all silicon blocks are modeled.
- Use exact machine help from the tested build before copying command examples.
