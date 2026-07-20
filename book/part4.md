\part{为什么要模拟这么多硬件}

QEMU 的硬件目录不是一份越长越好的设备清单。真实 SoC、合成平台、测试设备、virtio、vhost 与 VFIO 分别交换了逼真度、可控性、性能、迁移和安全边界。本篇把这些选择落到 RISC-V：先辨认一台 Machine 向客户机承诺什么，再从寄存器、MMIO、IRQ、reset 和 VMState 建模外设，随后把 CPU、内存、中断拓扑、启动链和 FDT 装配成板卡，最后解释 I/O 数据路径为什么继续分层。
