# RISC-V CPU and TCG evidence

Research anchor: QEMU `v11.1.0-rc0`, commit `eca2c16212ef9dcb0871de39bb9d1c2efebe76be`.

This ledger keeps evidence outside the narrative. A row marked **inference** is the authors' interpretation, not a statement attributed to QEMU maintainers.

## CPU model and accelerator boundary

- Current source: [`target/riscv/cpu.h`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/cpu.h) combines `CPUState`, `CPURISCVState`, and `RISCVCPUConfig`; [`target/riscv/cpu.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/cpu.c) registers generic and named CPU models.
- Accelerator-specific hooks: [`target/riscv/tcg/tcg-cpu.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/tcg/tcg-cpu.c) and [`target/riscv/kvm/kvm-cpu.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c).
- Evolution: commit [`d45b9bc6`](https://gitlab.com/qemu-project/qemu/-/commit/d45b9bc65515e376f360cc8c2877cc94f22d4e49) moved TCG-only code under its own directory. The related [24-patch v4 series](https://patchwork.ozlabs.org/project/qemu-devel/list/?series=511999) also added KVM-only build coverage.
- **Strong inference:** the directory change enforces the dependency boundary between common architectural state and accelerator-private implementation; it is not merely cosmetic source organization.

## Translation Blocks

- Current source: [`target/riscv/tcg/translate.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/tcg/translate.c) constructs `DisasContext` and enters `translator_loop()`; [`accel/tcg/cpu-exec.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/tcg/cpu-exec.c) finds and executes TBs; [`accel/tcg/tb-maint.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/tcg/tb-maint.c) owns linking, invalidation, and flush.
- Evolution: the [11-version big-endian series](https://patchwork.ozlabs.org/project/qemu-devel/list/?series=506301) culminated in commit [`56db2b7e`](https://gitlab.com/qemu-project/qemu/-/commit/56db2b7eac0b00149d8996f8575e7f389a0056b4), which placed data endianness in extended TB flags after normal flags ran out of space.
- **Strong inference:** the TB key is a translation-semantics contract. State that changes generated-code meaning must enter the key or cause invalidation.

## Decodetree and TCG IR

- Current source: [`target/riscv/insn32.decode`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/insn32.decode), `insn16.decode`, generated translators under `target/riscv/tcg/insn_trans/`, [`tcg/optimize.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/tcg/optimize.c), and the [`tcg/riscv64/`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/tcg/riscv64) host backend.
- Evolution: RISC-V moved to Decodetree over at least nine revisions. The [final series](https://patchwork.ozlabs.org/project/qemu-devel/list/?series=96903) migrated 32-bit instructions, compressed instructions, removed the handwritten decoder, and reused 32-bit translators. Initial commit [`2a53cff4`](https://gitlab.com/qemu-project/qemu/-/commit/2a53cff418335ccb4719e9a94fde55f6ebcc895d) retained a fallback when Decodetree did not match.
- **Strong inference:** the encoding/semantics/IR/backend split primarily improves reviewability, extension reuse, and incremental migration, not just decoder size.

## SoftMMU and two-stage translation

- Current source: `get_physical_address()`, `riscv_cpu_tlb_fill()`, and `MMU_2STAGE_BIT` in [`target/riscv/tcg/cpu_helper.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/tcg/cpu_helper.c); generic SoftTLB in [`accel/tcg/cputlb.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/tcg/cputlb.c).
- Evolution: H-extension emulation evolved through drafts to the [35-patch v0.5 v2 series](https://patchwork.ozlabs.org/project/qemu-devel/list/?series=156277). Commit [`36a18664`](https://gitlab.com/qemu-project/qemu/-/commit/36a18664bafcfafa5e997b47458387f6fe53d537) introduced second-stage MMU support. The [2023 v6 MMU refactor](https://patchwork.ozlabs.org/project/qemu-devel/list/?series=347953), commit [`02369f79`](https://gitlab.com/qemu-project/qemu/-/commit/02369f790676f8118b8f0769f58d5890e15fcd25), reclaimed TB flags and introduced `mmuidx_2stage`.
- **Strong inference:** `mmu_idx` names a translation and permission domain, not merely a privilege level. Two-stage state must span instruction fetch, data access, fault attribution, and TLB identity.

## Interrupts and AIA ownership

- Current source: `riscv_cpu_exec_interrupt()` and `riscv_cpu_do_interrupt()` in `target/riscv/tcg/cpu_helper.c`; [`hw/riscv/aia.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/aia.c), [`hw/intc/riscv_aplic.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/intc/riscv_aplic.c), and [`hw/intc/riscv_imsic.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/intc/riscv_imsic.c).
- Evolution: KVM AIA arrived through a [v7 series](https://patchwork.ozlabs.org/project/qemu-devel/list/?series=366001), including irqfd, kernel irqchip, and split mode; core commit [`95a97b3f`](https://gitlab.com/qemu-project/qemu/-/commit/95a97b3fd25ee1c73a6bbfe0d47ac31864a95a4c). A later migration crash led to the [v3 fix series](https://patchwork.ozlabs.org/project/qemu-devel/list/?series=461069) and commit [`bc220013`](https://gitlab.com/qemu-project/qemu/-/commit/bc2200134c1229a83bbcd8e75ab541ca110609f6), adding `.needed` predicates to APLIC/IMSIC VMState.
- **Strong inference:** interrupt virtualization is also a state-ownership problem. Migration fields must follow the active userspace/kernel implementation.

## MTTCG

- Current source: RISC-V advertises `.mttcg_supported = true`; [`accel/tcg/tcg-accel-ops-mttcg.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/tcg/tcg-accel-ops-mttcg.c) provides one host thread per vCPU; [`docs/devel/multi-thread-tcg.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/devel/multi-thread-tcg.rst) records the design constraints.
- Evolution: commit [`c6489dd9`](https://gitlab.com/qemu-project/qemu/-/commit/c6489dd921e7450bced1816013eb22cc100ed07c) established the MTTCG design. Commit [`194125e3`](https://gitlab.com/qemu-project/qemu/-/commit/194125e3ebd553acb02aaf3797a4f0387493fe94) chose per-target TB locks based on incoming-jump distribution. Commit [`0ac20318`](https://gitlab.com/qemu-project/qemu/-/commit/0ac20318ce16f4de288969b2007ef5a654176058) removed the global `tb_lock` with performance evidence. The 2025 [19-patch v3 exit-request series](https://patchwork.ozlabs.org/project/qemu-devel/list/?series=472671), commit [`ac6c8a39`](https://gitlab.com/qemu-project/qemu/-/commit/ac6c8a390b451913995ee784ef7261b8928e5ace), added release/acquire semantics.
- **Strong inference:** MTTCG is governed by ownership, atomic publication, safe points, and reclamation protocols. BQL presence is not a substitute for a memory-order proof.
