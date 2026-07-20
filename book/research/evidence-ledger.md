# 全书证据账本

- 目标发布线：QEMU `v11.1.0`；截至 2026-07-19 的源码审查基线：`v11.1.0-rc0`
- 当前研究锚点：QEMU `v11.1.0-rc0`，commit `eca2c16212ef9dcb0871de39bb9d1c2efebe76be`
- 实现主线：`riscv64`
- 状态含义：`待重写`、`重写中`、`待核验`、`完成`

| 章 | 要回答的问题 | RISC-V 当前源码入口 | 历史或 review 锚点 | 状态 |
| --- | --- | --- | --- | --- |
| 1 | QEMU 最早解决了什么问题，问题边界如何扩大 | `linux-user/`、`target/riscv/` | 2003 早期文档、QEMU 0.4、Bellard 2005 | 完成 |
| 2 | 从进程到完整机器需要补齐哪些契约 | `system/`、`hw/riscv/virt.c` | 早期 full-system、RISC-V `virt` 引入 | 完成 |
| 3 | 一台虚拟机器向固件和 OS 承诺什么 | `hw/riscv/virt.c`、设备树生成 | machine/board 演进和 guest ABI review | 完成 |
| 4 | 模型数量扩大后为何需要对象与生命周期 | `qom/`、`hw/riscv/` | QOM 引入、realize/reset review | 完成 |
| 5 | MMIO、DMA 和 IOMMU 为什么需要地址空间图 | `system/memory.c`、`hw/riscv/` | MemoryRegion/FlatView/RCU 演进 | 完成 |
| 6 | TCG/KVM 如何共享状态又分开执行 | `target/riscv/cpu.c`、`accel/` | accelerator 抽象与 RISC-V 接入 | 完成 |
| 7 | dyngen 解决了什么，又留下什么依赖 | `target/riscv/tcg/`（当前对照） | Bellard 2005、dyngen 源码 | 完成 |
| 8 | 为什么 2008 年要把代码生成收回 QEMU | `tcg/` | TCG 公告、GCC 版本问题、渐进迁移 | 完成 |
| 9 | TCG IR 为什么采用当前粒度和类型 | `tcg/`、`target/riscv/tcg/translate.c` | 初始 TCG README 与类型 review | 完成 |
| 10 | 为什么优化器保持收敛 | `tcg/optimize.c`、RISC-V helper | 优化规则、翻译时延与 helper 讨论 | 完成 |
| 11 | TB、SoftMMU、异常和 MTTCG 如何守住语义 | `accel/tcg/`、`target/riscv/tcg/` | MTTCG 与内存模型 review | 完成 |
| 12 | TCG 之后为什么出现 KVM 分层 | `target/riscv/kvm/` | 2006 KVM、2007 论文 | 完成 |
| 13 | `/dev/kvm` 为什么采用 system/VM/vCPU fd | `accel/kvm/`、Linux RISC-V KVM | 2007 UAPI 重构与 RISC-V 接入 | 完成 |
| 14 | 硬件执行之后 I/O 为什么仍是瓶颈 | `accel/kvm/`、`hw/virtio/` | exit、virtio、irqchip/vhost 演进 | 完成 |
| 15 | 多层状态如何迁移并保持兼容 | `target/riscv/kvm/`、`migration/` | dirty log、qemu-kvm 回流、RISC-V 状态 review | 完成 |
| 16 | 模型库中的不同机器分别承诺什么 | `hw/riscv/` | `virt`、真实 SoC、machine versioning | 完成 |
| 17 | 一页寄存器规范怎样变成可维护的 RISC-V 外设模型 | `hw/misc/sifive_test.c`、`hw/char/sifive_uart.c` | QOM、reset、VMState 与设备 review | 完成 |
| 18 | CPU、内存、IRQ、启动和 FDT 怎样组成一块 RISC-V 板 | `hw/riscv/virt.c`、`hw/riscv/k230.c` | K230 v1→v8 与 `virt` 演进 | 完成 |
| 19 | virtio、vhost、VFIO 如何改变数据路径 | `hw/virtio/`、RISC-V PCI/IOMMU | virtio/vhost/VFIO 关键演进 | 完成 |
| 20 | 怎样用 monitor、log、trace 与 gdb 还原 guest 行为 | RISC-V trace、gdbstub、monitor | 调试接口演进与 RISC-V 运行证据 | 完成 |
| 21 | 为什么兼容、安全和迁移约束重构 | RISC-V machine compat、`migration/` | machine versioning 与安全政策 | 完成 |
| 22 | 补丁如何在公开审查中收敛 | RISC-V 代表性 v1→vN series | qemu-riscv、MAINTAINERS、KVM Forum | 完成 |
| 23 | QEMU 为什么渐进引入 Rust | `rust/`、RISC-V 可复用设备边界 | PL011 v1→v11、QEMU/Linux Rust | 完成 |
