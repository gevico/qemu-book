# Inspect KVM memory slots

Status: source-inspection; runtime tracing requires a RISC-V KVM host.

Target release: QEMU `v11.1.0`; source-review baseline `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Relate QEMU's RISC-V `virt` MemoryRegion topology to the kernel memory slots
registered by the KVM backend.

## Prerequisites

- `QEMU_SRC`; runtime extension needs a successful KVM probe.
- Familiarity with `info mtree` output.

## Files

- `README.md`: source and optional runtime procedure.
- `inspect.sh`: listener/source map plus optional KVM slot trace and mtree.
- `results/slot-source.txt`: generated source anchors for the slot table.

## Steps

1. Set `QEMU_SRC`, optionally set `QEMU_SYSTEM_RISCV64`, and run `./inspect.sh`.
2. Follow the recorded memory listeners and slot updates in
   `accel/kvm/kvm-all.c`.
3. Classify RAM, ROM/device-backed regions, aliases, and unmapped holes.
4. On a capable KVM host, the same script captures `info mtree -f` and
   `kvm_set_user_memory`; otherwise it records a runtime skip.

## Expected results

Guest physical RAM is registered in bounded kernel slots, while MMIO dispatch
and aliases do not map one-to-one to independent RAM slots.

## Cleanup

Quit QEMU and remove the local slot map and traces.

## Troubleshooting

- Slot numbers are implementation details; compare ranges and lifecycle.
- A flattened MemoryRegion line does not imply a separate KVM slot.
