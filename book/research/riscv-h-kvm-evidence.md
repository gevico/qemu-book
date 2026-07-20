# RISC-V H extension and KVM evidence

Research anchor: QEMU `v11.1.0-rc0`, commit `eca2c16212ef9dcb0871de39bb9d1c2efebe76be`. Target book version: QEMU `v11.1.0`.

## Mandatory capability distinction

The manuscript must not collapse these milestones:

1. A host RISC-V H extension lets Linux KVM accelerate an ordinary L1 guest.
2. KVM exposes H to that L1 so it can act as a guest hypervisor.
3. The L1 can run an L2 with complete G-stage, HLV/HSV, timer, interrupt, debug, and migration support.

The `v11.1.0-rc0` tree proves the first execution/control path and contains an H capability mapping. It does not, by itself, prove complete nested execution or migration.

## H state machine and two-stage translation

- Specification: [RISC-V H Extension 1.0](https://docs.riscv.org/reference/isa/v20260120/priv/hypervisor.html).
- Current source: [`CPURISCVState`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/cpu.h#L250) stores H/VS state; [`riscv_cpu_swap_hypervisor_regs()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/tcg/cpu_helper.c#L454) changes the HS/VS view; `get_physical_address()` and `riscv_cpu_tlb_fill()` implement VS-stage plus G-stage and guest-page-fault attribution.
- History: initial [H v0.5, 35-patch series](https://patchew.org/QEMU/cover.1580518859.git.alistair.francis%40wdc.com/); CSR commit [`ff2cc129`](https://gitlab.com/qemu-project/qemu/-/commit/ff2cc1294cd8179d87de299b8e7a16bdb1e69523); trap commit [`5eb9e782`](https://gitlab.com/qemu-project/qemu/-/commit/5eb9e782f523d2898e2dacd86c6e41365dae74b3); second-stage commit [`36a18664`](https://gitlab.com/qemu-project/qemu/-/commit/36a18664bafcfafa5e997b47458387f6fe53d537).
- Fault ABI evolution: commits [`b2ef6ab9`](https://gitlab.com/qemu-project/qemu/-/commit/b2ef6ab9fee6948cf016f9e741feecdfb333fcbe), [`30675539`](https://gitlab.com/qemu-project/qemu/-/commit/3067553993ae986b76a92df8a978778134ecdc84), and [`8e2aa21b`](https://gitlab.com/qemu-project/qemu/-/commit/8e2aa21b0a0d434be2f53a9435fec4f63ec192c4), after the [nine-version nested-fix series](https://patchew.org/QEMU/20220630061150.905174-1-apatel%40ventanamicro.com/).
- **Fact:** `htval`, `htinst`, and `stval` are guest-hypervisor-visible trap ABI, not optional debug metadata.
- **Strong inference:** two-stage translation is one fault and permission protocol, not two independent page walks concatenated together.

## Experimental extension to default CPU capability

- Early H drafts were off by default while the specification remained unstable.
- Commit [`6ca7155a`](https://gitlab.com/qemu-project/qemu/-/commit/6ca7155a8c8d88e5372f0ba337c33e86edbcb295) removed the experimental status after ratification.
- Commit [`07cb270a`](https://gitlab.com/qemu-project/qemu/-/commit/07cb270a9ac914431577321b0e3e99d79cf56254) enabled H by default for the generic `virt` CPU; see the [mail series](https://patchew.org/QEMU/20220105213937.1113508-1-alistair.francis%40opensource.wdc.com/).
- **Strong inference:** experimental flags, generic defaults, and named CPU models represent different compatibility commitments.

## RISC-V KVM control path

- Current execution chain: [`kvm_vcpu_thread_fn()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/kvm/kvm-accel-ops.c#L31) → `kvm_init_vcpu()` → [`kvm_arch_init_vcpu()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c#L1517) → [`kvm_cpu_exec()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/kvm/kvm-all.c#L3427) / `KVM_RUN` → [`kvm_arch_handle_exit()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c#L1730).
- Initial RISC-V KVM commits: [`91654e61`](https://gitlab.com/qemu-project/qemu/-/commit/91654e613bf67863f27854a7c8e292a273b50a40), [`0a312b85`](https://gitlab.com/qemu-project/qemu/-/commit/0a312b85cb433386804a2ca79f4a1f7ab75f64a7), and [`4eb47125`](https://gitlab.com/qemu-project/qemu/-/commit/4eb471258bd0e331678bece4c894c477928b3b0b); [v5 mail series](https://lists.nongnu.org/archive/html/qemu-riscv/2022-01/msg00203.html).
- Accelerator separation: commit [`fb80f333`](https://gitlab.com/qemu-project/qemu/-/commit/fb80f33377df221728d6c3c298f19b0da7ba277a), [v3 split discussion](https://lists.nongnu.org/archive/html/qemu-riscv/2023-09/msg00351.html).
- **Fact:** normal guest instructions do not return to QEMU; common exits include MMIO, SBI, CSR, debug, and lifecycle events.
- **Strong inference:** under KVM, QEMU is the policy, device, and state-coordination layer; Linux KVM and hardware execute H/G-stage behavior.

## Host capability projection

- Current source maps `RVH` to `KVM_RISCV_ISA_EXT_H` in `kvm_misa_ext_cfgs`. QEMU may disable a host capability, but cannot enable one the host lacks.
- Scratch vCPU: commit [`492265ae`](https://gitlab.com/qemu-project/qemu/-/commit/492265ae8be70537391c08390cb7c64580c902d9), [v9 review](https://patchew.org/QEMU/20230706101738.460804-1-dbarboza%40ventanamicro.com/).
- `KVM_GET_REG_LIST`: commit [`608bdebb`](https://gitlab.com/qemu-project/qemu/-/commit/608bdebb6075b757e5505f6bbc60c45a54a1390b), [v2 series](https://patchew.org/QEMU/20231003132148.797921-1-dbarboza%40ventanamicro.com/). The old `EINVAL` probing path remains for older kernels.
- **Strong inference:** a scratch vCPU resolves the initialization-order conflict between stable QOM properties and KVM capabilities that are only discoverable through a vCPU fd.

## Direct boot and SBI

- Current source: `virt_machine_done()` rejects M-mode firmware under KVM; `kvm_riscv_reset_vcpu()` installs PC, `a0=hartid`, `a1=FDT`, and S-mode.
- History: direct boot commit [`ad40be27`](https://gitlab.com/qemu-project/qemu/-/commit/ad40be27084536408b47a9209181f776ec2c54a5).
- **Strong inference:** direct boot and SBI define the boundary among QEMU, Linux KVM, and the guest OS. QEMU does not emulate an M-mode firmware boot in this path.

## Memory slots and G-stage ownership

- Current source: MemoryListener updates reach `kvm_set_phys_mem()` in [`accel/kvm/kvm-all.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/kvm/kvm-all.c#L1631), then `KVM_SET_USER_MEMORY_REGION` registers GPA, size, and userspace backing.
- **Fact:** KVM execution does not call TCG's RISC-V `get_physical_address()`.
- **Strong inference:** the Machine/AddressSpace layout defines guest physical resources; KVM/hardware G-stage implements execution-time isolation and translation. These layers must be explained separately.

## AIA implementation and split irqchip

- Current source: [`kvm_riscv_aia_create()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c#L1832), [`hw/riscv/aia.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/aia.c), APLIC, and IMSIC.
- KVM AIA: commit [`9634ef7e`](https://gitlab.com/qemu-project/qemu/-/commit/9634ef7eda5f5b57f03924351a213b776f6b8a23), after a [seven-version series](https://patchew.org/QEMU/20230727102439.22554-1-yongxuan.wang%40sifive.com/).
- Split irqchip: commits [`3fd619db`](https://gitlab.com/qemu-project/qemu/-/commit/3fd619db239fb37557dcd51a4b900417b893d706) and [`ce7320bf`](https://gitlab.com/qemu-project/qemu/-/commit/ce7320bf5641bfcf864c2ad9a31358c41a686c10), [v2 discussion](https://patchew.org/QEMU/20241119191706.718860-1-dbarboza%40ventanamicro.com/).
- **Fact:** in split mode QEMU owns APLIC while the kernel owns IMSIC; QEMU injects MSI into the kernel IMSIC.
- **Strong inference:** an irqchip need not live wholly in userspace or kernel. State access frequency, hardware support, and migration requirements can justify splitting it.

## Runtime state synchronization and timer migration

- Current source: `kvm_arch_get_registers()` and `kvm_arch_put_registers()` synchronize core and supervisor CSR state at runtime; FP/vector are synchronized for full/reset paths, not every exit.
- Optimization: commit [`e2beafde`](https://gitlab.com/qemu-project/qemu/-/commit/e2beafde9e782b051355975f444c986b1b788925), [v3 review](https://patchew.org/QEMU/20260518102118.2768383-1-mengzhuo%40iscas.ac.cn/), avoids dozens of one-reg ioctls per exit.
- Timer history: commits [`27abe66f`](https://gitlab.com/qemu-project/qemu/-/commit/27abe66f31efa8bcd15f0f998db2127b4ffb628a), [`9ad3e016`](https://gitlab.com/qemu-project/qemu/-/commit/9ad3e016ae1ed2f30c39051bc20f1da327bd9400), [`1eb9a5da`](https://gitlab.com/qemu-project/qemu/-/commit/1eb9a5da31abb0a7b613756f5bb7c887b7ef60ea), and [`385e575c`](https://gitlab.com/qemu-project/qemu/-/commit/385e575cd5ab2436c123e4b7f8c9b383a64c0dbe).
- **Fact:** current VMState transfers time, compare, and state, not frequency. A destination frequency mismatch is reported, and current code does not demonstrate a complete conversion protocol.
- **Strong inference:** synchronization should be stratified by runtime, reset, and migration ownership. Full synchronization on every exit is simple but too costly on a hot path.

## Nested virtualization and migration: open boundary

- Current source conflict: the common RISC-V CPU [`vmstate_hyper`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/machine.c#L87) serializes H/VS state; TCG can supply the corresponding `env` fields, while KVM's `kvm_csr_cfgs` exposes only supervisor CSRs and the current [`linux-headers/asm-riscv/kvm.h`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/linux-headers/asm-riscv/kvm.h#L44) has no H/VS CSR group.
- Linux nested KVM [27-patch v1 series](https://lists.infradead.org/pipermail/linux-riscv/2026-January/084034.html), also on [Patchew](https://patchew.org/linux/20260120080013.2153519-1-anup.patel%40oss.qualcomm.com/), explicitly says that v1 cannot yet run L2; G-stage walking, HLV/HSV, Sstc, and other work remained.
- **Fact:** an H extension enum does not prove complete nested execution or migration.
- **Status:** write as **under development / to be verified**, never as supported behavior in the research baseline.

## In-kernel AIA migration: open boundary

- Current source enables APLIC/IMSIC VMState only when the respective state is in userspace; the rc0 KVM AIA path does not show extraction/restoration of all in-kernel runtime state.
- An AIA save/restore [v3 series submitted before rc0](https://patchew.org/QEMU/20260602142709086IsQxEt0LYI9ygtpFnj-XN%40zte.com.cn/), but not merged into that tag, adds KVM AIA register access and pre-save/post-load work.
- **Status:** this is a migration support gap to test and track, not enough evidence by itself to claim a reproducible bug in every configuration.
