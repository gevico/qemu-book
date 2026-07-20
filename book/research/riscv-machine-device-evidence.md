# RISC-V Machine and device evidence

Research anchor: QEMU `v11.1.0-rc0`, commit `eca2c16212ef9dcb0871de39bb9d1c2efebe76be`.

## RISC-V `virt` as a maintained platform contract

- Initial machine: commit [`04331d0b`](https://gitlab.com/qemu-project/qemu/-/commit/04331d0b56a0cab2e40a39135a92a15266b37c36) introduced a device-tree-described `virt` machine with CLINT, PLIC, 16550A UART, and virtio-mmio.
- PCIe growth: commit [`6d56e396`](https://gitlab.com/qemu-project/qemu/-/commit/6d56e39649808696b2321cbd200dd7ccaa7ef7fe) connected the generic PCIe host (`gpex`).
- Current source: [`hw/riscv/virt.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/virt.c), [`include/hw/riscv/virt.h`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/include/hw/riscv/virt.h), [`hw/riscv/boot.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/boot.c), and [`docs/system/riscv/virt.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/system/riscv/virt.rst).
- The current tree also contains explicit fixes for FDT layout, including commit [`926a8b8e`](https://gitlab.com/qemu-project/qemu/-/commit/926a8b8e4f) for the `iommu-map` entry, plus refactors that move shared RISC-V FDT construction into helpers.
- **Strong inference:** `virt` is not a one-time synthetic board. Its address map, discovery data, defaults, and versioned behavior form a maintained guest contract while the implementation is continuously refactored.

## Machine assembly versus reusable devices

- Current source assembles harts, RAM/ROM, interrupt controllers, UART, RTC, fw_cfg, virtio-mmio, PCIe, IOMMU, and optional platform devices in the Machine layer; the devices live in their reusable subsystem directories.
- QOM/qdev lifecycle, bus connections, MemoryRegion ownership, and reset behavior remain separate contracts even when `virt.c` creates all instances.
- **Strong inference:** keeping board wiring out of reusable devices lets the same model serve a different Machine and makes review failures local: register behavior belongs to the device patch, addresses and IRQ wiring belong to the Machine patch.

## AIA as a state-ownership example

- Initial emulation: APLIC commit [`e8f79343`](https://gitlab.com/qemu-project/qemu/-/commit/e8f79343cfc886aaa225cec9faf6881f75945209) and IMSIC commit [`9746e583`](https://gitlab.com/qemu-project/qemu/-/commit/9746e583fe6ca67d9645448989535bc19adb6150).
- KVM support and split ownership are tracked in [`riscv-h-kvm-evidence.md`](riscv-h-kvm-evidence.md).
- Current reset work includes explicit APLIC and IMSIC Resettable API conversions, commits [`99bfcd32`](https://gitlab.com/qemu-project/qemu/-/commit/99bfcd329aa2441f3a08554659d2c3ee6453f9df) and [`76639148`](https://gitlab.com/qemu-project/qemu/-/commit/766391483bdccb66e392e71769bc85839569857d).
- **Strong inference:** reset and migration must follow the active implementation owner. Resetting a userspace shadow while the kernel owns the live irqchip is not equivalent to resetting the device.

## RISC-V IOMMU

- Base model: commit [`0c54acb8`](https://gitlab.com/qemu-project/qemu/-/commit/0c54acb8243dfc51a021d108ffef794c89c84f72), Message-ID [`20241016204038.649340-4-dbarboza@ventanamicro.com`](https://lore.kernel.org/qemu-devel/20241016204038.649340-4-dbarboza@ventanamicro.com/), explicitly started with S-stage and G-stage translation after specification ratification.
- Incremental capabilities: address translation cache commit [`9d085a1c`](https://gitlab.com/qemu-project/qemu/-/commit/9d085a1c3cb2b6a1ee77d5f6e0ca20241208acd8), ATS commit [`69a9ae48`](https://gitlab.com/qemu-project/qemu/-/commit/69a9ae483696e185889edaeddacf46afd9110bc6), and debug translation commit [`a7aa525b`](https://gitlab.com/qemu-project/qemu/-/commit/a7aa525b93c3f7a847cd2185b71aef97a17ec3d5), all in the same reviewed series.
- Platform form: commit [`5b128435`](https://gitlab.com/qemu-project/qemu/-/commit/5b128435dcf1e6545b544e3e402470ecf5b45ac7), Message-ID [`20241106133407.604587-4-dbarboza@ventanamicro.com`](https://lore.kernel.org/qemu-devel/20241106133407.604587-4-dbarboza@ventanamicro.com/), added a SysBus form while preserving decisions shared with the PCI device.
- Reset protocol: commit [`9afd2671`](https://gitlab.com/qemu-project/qemu/-/commit/9afd26715ef4f887f5eaf2ecfe365a7837f2e500), Message-ID [`20241106133407.604587-7-dbarboza@ventanamicro.com`](https://lore.kernel.org/qemu-devel/20241106133407.604587-7-dbarboza@ventanamicro.com/).
- Current source: `hw/riscv/riscv-iommu.c`, `riscv-iommu-pci.c`, `riscv-iommu-sys.c`, and the `virt` integration.
- **Strong inference:** the history illustrates deliberate incremental modeling: establish translation and fault semantics first, then caches, ATS, debug, packaging, reset, and performance counters. The reviewable unit is a protocol boundary, not a raw line-count target.

## virtio and vhost boundary

- Current source should be read in layers: `hw/virtio/` for transport/common queues, `hw/block/virtio-blk.c` and `hw/net/virtio-net.c` for device semantics, and `hw/virtio/vhost*.c` for a backend that owns the data plane.
- The RISC-V `virt` machine exposes virtio-mmio and PCIe, allowing the same device semantics to use different transports.
- The migration history contains both blockers and explicit backend state-transfer protocols. A backend being able to process vrings does not imply it can export every in-flight state needed for migration.
- **Strong inference:** virtio separates a stable guest protocol from transport and backend placement; vhost changes who consumes the queue, but QEMU retains feature negotiation, memory mapping, lifecycle, error, and compatibility responsibilities.

## K230 as a review-driven SoC case

- Initial upstream Machine: commit [`6cf0d08c`](https://gitlab.com/qemu-project/qemu/-/commit/6cf0d08c3953ee447cb215edc3a384834cbe48db), Message-ID [`a161697a249b896e44e2748435f6c0caec12c9f4.1781246408.git.chao.liu@processmission.com`](https://lore.kernel.org/qemu-devel/a161697a249b896e44e2748435f6c0caec12c9f4.1781246408.git.chao.liu@processmission.com/).
- K230 watchdog: commit [`dace3986`](https://gitlab.com/qemu-project/qemu/-/commit/dace398674df8af11df13f2554e8566e9de3f8c7).
- Functional boot coverage: commit [`a539bb91`](https://gitlab.com/qemu-project/qemu/-/commit/a539bb911ee1085c69ce00781acd2f13bd3cb82b), Message-ID [`20260711125320.72319-1-caojunze424@gmail.com`](https://lore.kernel.org/qemu-devel/20260711125320.72319-1-caojunze424@gmail.com/), pins assets and hashes and covers direct-kernel and U-Boot paths.
- Current source: `hw/riscv/k230.c`, `include/hw/riscv/k230.h`, `hw/watchdog/k230_wdt.c`, `tests/qtest/k230-wdt-test.c`, `tests/functional/riscv64/test_k230.py`, and `docs/system/riscv/k230.rst`.
- Review evolution: the series reached v8 and changed CPU extensions, PLIC/CLINT layout, reset vector handling, unimplemented UART behavior, hart count, direct boot, watchdog IRQ, and Machine interfaces.
- **Strong inference:** the most useful K230 lesson is not its final device list. It is how firmware behavior, review evidence, and tests corrected a board model that looked plausible at earlier revisions.
