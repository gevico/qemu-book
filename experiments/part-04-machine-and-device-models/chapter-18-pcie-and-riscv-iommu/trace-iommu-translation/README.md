# Trace IOMMU translation

Status: runnable positive DMA path with a committed Linux initramfs probe,
fixed-tag trace checks, and a host-independent parser test.

Baseline: QEMU `v11.1.0`; source-review anchor `v11.1.0-rc0`; RISC-V
`riscv64` and the QEMU RISC-V IOMMU model.

## Purpose

Configure one device context and map one IOVA so a controlled DMA request can
be followed through the RISC-V IOMMU translation and fault paths.

## Prerequisites

- QEMU build containing `riscv-iommu-pci` or the supported system IOMMU.
- RISC-V Linux 6.13 or newer with the RISC-V IOMMU, E1000E, DHCP autoconfig,
  and poweroff paths built in; static RISC-V cross compiler and `cpio`.

## Files

- `README.md`: experiment design and trace procedure.
- `guest/iommu-dma-probe.c`: sends 32 fixed UDP datagrams through E1000E.
- `build-initramfs.sh` and `run.sh`: minimal `rdinit` archive and QEMU launch.
- `analyze_iommu_trace.py` and its tests: separate translation and fault facts.
- `check-upstream.sh`: verifies the device docs and trace-event names.

## Steps

1. Set `QEMU_SRC` and run `./check-upstream.sh`. Build the initramfs with
   `./build-initramfs.sh`.
2. Set `GUEST_KERNEL` to a compatible RISC-V Linux `Image`, then run `./run.sh`.
   Linux configures the IOMMU context and page tables; the committed userspace
   probe creates controlled E1000E traffic rather than writing IOMMU tables.
3. Correlate `iommu-probe:sent` with `riscv_iommu_dma` events, grouped by BDF,
   direction, IOVA, and translated address. Record the exact kernel config.
4. Run `python3 -m unittest -v test_analyze_iommu_trace.py`. The synthetic fault
   line tests the parser only; it is not evidence that the live guest faulted.
5. For a live negative case, use a separately reviewed kernel fault-injection
   patch that invalidates one PTE and performs the required IOTLB invalidation,
   then rerun the analyzer with `--require-fault`. Do not corrupt a normal disk
   image or describe the synthetic fixture as a live result.

## Expected results

The positive run contains at least one `riscv_iommu_dma` event and reports the
translated IOVA/physical-address pair. A negative claim is accepted only when
the live trace contains `riscv_iommu_flt`; the analyzer deliberately keeps
translations and faults in separate counters.

## Cleanup

The probe requests poweroff. Remove only this experiment's `build/` and
`results/` directories.

## Troubleshooting

- Check device ID, process context, and queue invalidation before PTE contents.
- Use device types reported by the tested QEMU binary, not older examples.
- If DHCP completes but no translation appears, verify that the IOMMU and
  E1000E drivers are built in rather than modules absent from the initramfs.
