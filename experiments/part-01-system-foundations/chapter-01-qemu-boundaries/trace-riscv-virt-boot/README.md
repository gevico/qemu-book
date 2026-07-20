# Trace RISC-V `virt` boot

Status: runnable with a RISC-V kernel or bare-metal ELF image.

Target release: QEMU `v11.1.0`; source-review baseline `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Locate the first guest instructions and distinguish reset firmware, machine
construction, and payload entry.

## Prerequisites

- `QEMU_SYSTEM_RISCV64` and a reproducible image in `RISCV_GUEST_IMAGE`.
- The image is disposable and its load convention is known.
- GNU `timeout`; `readelf` is optional for troubleshooting the image header.

## Files

- `README.md`: the manual.
- `run.sh`: bounded TCG reset/instruction tracing.
- `results/boot.log`: generated instruction and reset trace.

## Steps

1. Set `QEMU_SYSTEM_RISCV64` and `RISCV_GUEST_IMAGE`, then run `./run.sh`.
   Set `QEMU_SRC` to include the source revision in the results.
2. Inspect the bounded reset and instruction trace in `results/boot.log`.
3. Identify the reset PC, the first payload PC, and the transition between
   them.
4. Relate the addresses to `hw/riscv/virt.c` and `hw/riscv/boot.c`.

## Expected results

The trace begins at a machine-defined reset path and reaches the supplied
payload; the exact instruction count depends on the image and firmware choice.

## Cleanup

Let the bounded command return, then remove only this project's generated
`results/` directory.

## Troubleshooting

- If no instruction log appears, confirm that the build includes TCG logging.
- If the ELF is not loadable, inspect it with `readelf -h` and verify RISC-V.
