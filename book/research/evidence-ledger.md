# 全书证据账本

- 目标源码基线：QEMU `v11.1.0`
- 当前研究基线：QEMU `v11.1.0-rc0`，commit `eca2c16212ef9dcb0871de39bb9d1c2efebe76be`
- 主体系结构：`riscv64`

| 章 | 研究主题 | 当前源码入口 | Git／邮件审查重点 | 状态 |
| --- | --- | --- | --- | --- |
| 1 | QEMU 边界与 RISC-V `virt` | `system/`、`hw/riscv/virt.c` | system emulation 与 accelerator 边界 | 正文已建源码、历史与邮件证据 |
| 2 | 启动与配置 | `system/vl.c`、`system/main.c` | 参数解析和初始化阶段拆分 | 正文已建源码、历史与邮件证据 |
| 3 | 主循环与线程 | `util/main-loop.c`、`util/aio-*` | BQL、AioContext 与 iothread 演进 | 正文已建源码、历史与邮件证据 |
| 4 | QOM | `qom/object.c` | 类型、属性和 realize 约定形成过程 | 正文已建源码、历史与邮件证据 |
| 5 | MemoryRegion | `system/memory.c`、`system/physmem.c` | FlatView、listener 与 RCU | 正文已建源码、历史与邮件证据 |
| 6 | RISC-V CPU 与 accelerator | `target/riscv/cpu.c`、`accel/` | CPUState／AccelOps 分层 | 已建证据矩阵 |
| 7 | TB 与动态翻译 | `accel/tcg/` | TB 缓存、链接和失效 | 已建证据矩阵 |
| 8 | RISC-V 译码 | `target/riscv/insn*.decode` | Decodetree 和扩展指令接入 | 已建证据矩阵 |
| 9 | TCG IR 与后端 | `tcg/`、`target/riscv/tcg/` | helper 边界与后端约束 | 已建证据矩阵 |
| 10 | SoftMMU | `accel/tcg/cputlb.c`、`target/riscv/tcg/cpu_helper.c` | TLB 快慢路径和两阶段转换 | 已建证据矩阵 |
| 11 | 异常、中断与 MTTCG | `target/riscv/tcg/`、`accel/tcg/` | 安全点、退出与并行执行 | 已建证据矩阵 |
| 12 | RISC-V H 扩展 | `target/riscv/cpu_bits.h`、`target/riscv/tcg/csr.c` | H 扩展、HS/VS 状态和规范演进 | 已建证据矩阵 |
| 13 | RISC-V KVM | `target/riscv/kvm/kvm-cpu.c`、`accel/kvm/` | KVM RISC-V 初始支持与 capability | 已建证据矩阵 |
| 14 | KVM 内存、I/O 与中断 | `accel/kvm/kvm-all.c`、`hw/intc/` | memory slot、AIA、irqfd/ioeventfd | 已建证据矩阵 |
| 15 | KVM 状态与迁移 | `target/riscv/kvm/`、`target/riscv/machine.c` | one-reg、迁移与嵌套约束 | 已建证据矩阵；nested 标为演进中 |
| 16 | RISC-V `virt` Machine | `hw/riscv/virt.c`、`hw/riscv/riscv_hart.c` | machine version 与板级装配 | 已建证据矩阵 |
| 17 | 外设、时钟与 reset | `hw/riscv/`、`hw/intc/`、`hw/timer/` | ACLINT、PLIC/AIA 和设备生命周期 | 已建证据矩阵 |
| 18 | PCIe、IOMMU 与设备地址空间 | `hw/riscv/virt.c`、`hw/riscv/riscv-iommu*` | RISC-V IOMMU 与 PCI host bridge | 已建证据矩阵 |
| 19 | virtio 与 I/O | `hw/virtio/`、`block/`、`net/` | transport、vhost 与数据面下沉 | 已建证据矩阵 |
| 20 | 调试与观测 | `monitor/`、`trace/`、`target/riscv/gdbstub.c` | 可观测接口稳定性 | 已建证据矩阵 |
| 21 | 测试、迁移与兼容 | `tests/`、`migration/` | qtest、migration ABI 与 machine compat | 已建证据矩阵 |
| 22 | 上游演进研究方法 | `MAINTAINERS`、Git log、qemu-devel | 从 patch v1 到最终提交 | 已建立方法 |
| 23 | Rust 建模 | `rust/`、相关设备目录 | Rust API 边界与渐进式接入 | 已建证据矩阵 |
| 24 | RISC-V GPGPU | PCIe 设备、DMA、IOMMU 相关目录 | 通用设备模型与计算模型边界 | 已建通用机制证据；概念模型明确标为树外 |
| 25 | K230 与教学 SoC | `hw/riscv/k230.c` | K230 上游建模与板级约束 | 已建 K230/G233 证据边界 |
| 26 | AI 加速器与 Agent 辅助建模 | QOM、PCIe、DMA、qtest 相关目录 | 生成代码的评审、溯源和验证边界 | 已建通用机制证据；生成模型明确标为树外 |
