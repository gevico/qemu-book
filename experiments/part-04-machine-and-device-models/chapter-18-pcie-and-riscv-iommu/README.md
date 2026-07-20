# Chapter 18: PCIe and RISC-V IOMMU

- [Build a RISC-V MMIO-to-board path](build-riscv-mmio-board-path/): model a
  small device, attach an opt-in instance to `virt`, describe it in FDT, and
  verify the path with host tests, qtest, and a bare-metal probe.
- [Map PCIe topology](map-pcie-topology/): connect QEMU buses, ECAM, MMIO
  windows, and guest enumeration.
- [Trace IOMMU translation](trace-iommu-translation/): observe a controlled DMA
  address translation through the RISC-V IOMMU.
