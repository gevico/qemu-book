\part{让硬件执行：QEMU 与 KVM}

TCG 已经能够完整执行客户机，KVM 仍然出现，是因为同 ISA 虚拟化需要把最热的指令路径交回硬件。这个变化没有消除 QEMU，而是重新划分 CPU、内存、I/O、中断和迁移状态的所有权。本篇先还原 KVM 进入 Linux 与 QEMU 的需求，再用 RISC-V H 扩展、`/dev/kvm`、VM exit 和 one-reg 接口检查这套分层怎样工作，以及硬件加速为什么仍然离不开用户态机器模型。
