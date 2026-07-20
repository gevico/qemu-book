# 硬件模型不是清单：RISC-V `virt` 的平台契约

拿到一份能够在某块 RISC-V 开发板启动的 Linux 镜像，把它交给 `qemu-system-riscv64`，再随手选择另一块 machine，最常见的结果是串口没有任何输出。CPU 都执行 RISC-V 指令，内核也没有损坏，问题仍可能出在复位地址、内存起点、中断控制器、时钟、UART 地址或固件接口中的任意一项。

这就是 QEMU 需要大量硬件模型的起点。指令集只规定处理器怎样执行指令，一台可启动的机器还要向固件和操作系统交付一组板级契约。不同模型保存的是不同契约，数量多并不意味着 QEMU 在追求一份硬件百科。

## 同一条指令集不能保证同一份镜像启动

QEMU 的 RISC-V 文档直接提醒用户，RISC-V SoC 和板卡的差异远大于标准 PC。很多 image 只认识编译时选定的内存图和外设，一块板的固件通常无法直接拿到另一块板运行。执行到第一条指令只说明 CPU 入口成立；出现第一行串口输出，还依赖复位代码找到 RAM、timer、中断控制器和 UART。

一台 machine 至少要回答下面这些问题：

- 有多少 hart，每个 hart 实现哪些 ISA 扩展，复位 PC 在哪里；
- RAM、ROM、flash 和 MMIO 窗口位于什么地址；
- timer、软件中断和外部中断怎样送到各个 hart；
- 固件、kernel、initrd 和设备树由谁装载；
- guest 通过 FDT、ACPI 或固定约定发现设备；
- reset、关机、热插拔和迁移时，哪些状态必须保持一致。

这些内容共同形成 guest 可观察的平台。换掉其中一个地址，可能比修改几百行内部代码更容易破坏已有软件。

:::: {.quick-quiz}
两个 machine 使用相同的 `rv64` CPU model，为什么同一个固件仍可能只在其中一台启动？

::: {.quick-answer}
CPU model 只覆盖指令和处理器状态。固件还依赖复位入口、内存图、中断控制器、UART、时钟和发现机制；任何一项板级契约不同，都可能在 CPU 正常执行时让启动失败。
:::
::::

## 模型库中的每一类对象解决不同问题

从一个 MMIO 寄存器到完整 SoC，复杂度只是表面差异。更值得区分的是它们服务的工作。

| 模型形态 | 要解决的问题 | 本书采用的 RISC-V 锚点 | 主动接受的限制 |
| --- | --- | --- | --- |
| CPU 与架构状态 | 运行、测试和调试 RISC-V 指令及特权语义 | `target/riscv/` | 不包含板级设备 |
| 小型 MMIO 或测试设备 | 给固件提供退出、复位、探测或可断言接口 | `hw/misc/sifive_test.c` | 追求可控，不追求商品硬件逼真度 |
| 真实外设、SoC 与板卡 | 运行已有固件，支持 bring-up、回归和缺少硬件时的开发 | SiFive、Microchip Icicle Kit、K230 | 常只实现真实芯片中被软件使用的一部分 |
| 合成 machine | 给通用 OS 和虚拟化提供稳定、可组合的平台 | RISC-V `virt` | 不复现某块真实板的怪癖 |
| 半虚拟化设备与卸载 | 减少昂贵的设备模拟和跨边界交互 | `virtio-mmio`、virtio PCI、vhost | 需要 guest 驱动和明确协议状态 |
| 设备直通 | 使用真实设备能力并缩短数据路径 | `virt` PCIe、IOMMU 与 VFIO | 牺牲可移植性，增加隔离和迁移条件 |

真实模型的价值在于兼容已有软件。合成模型给新软件提供一块干净的共同平台。测试设备用确定行为换掉现实噪声。virtio、vhost 和 VFIO 又在性能压力下改变设备由谁执行。把它们排成一条“越来越高级”的直线，会丢掉各自的使用条件。

## `virt` 选择一台现实中不存在的机器

RISC-V `virt` 不对应任何商品板。用户只想运行 Linux、U-Boot、EDK2 或做 KVM 虚拟化时，复制一块真实 SoC 的容量限制和私有外设没有收益。`virt` 因而选择通用 CPU、标准 UART、flash、RTC、virtio、PCIe，以及可选择的 PLIC 或 AIA 中断拓扑，并通过生成的设备树把实际配置交给 guest。

它仍然是一台有固定事实的机器。`v11.1.0-rc0` 的 [`virt_memmap`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/virt.c) 明确列出 MROM、test device、RTC、CLINT/ACLINT、PLIC/APLIC、UART、virtio、flash、PCIe ECAM/MMIO 和 DRAM：

```c
static const MemMapEntry virt_memmap[] = {
    [VIRT_MROM]  = {       0x1000,       0xf000 },
    [VIRT_TEST]  = {     0x100000,       0x1000 },
    [VIRT_CLINT] = {    0x2000000,      0x10000 },
    [VIRT_PLIC]  = {    0xc000000,
                        VIRT_PLIC_SIZE(VIRT_CPUS_MAX * 2) },
    [VIRT_UART0] = {   0x10000000,        0x100 },
    [VIRT_VIRTIO]= {   0x10001000,       0x1000 },
    [VIRT_DRAM]  = {   0x80000000,          0x0 },
};
```

这张表会进入 MemoryRegion 映射、设备初始化和 FDT。它对 guest 的意义远高于数组放在哪个 C 文件里。固件如果把 UART 写死为 `0x10000000`，QEMU 内部重构可以移动函数，却不能随意移动这个窗口。

## MachineClass 描述能力，MachineState 保存本次实例

`virt_machine_class_init()` 设置 machine 描述、初始化入口、最大 CPU 数、默认 CPU 类型、NUMA 与动态 sysbus 规则，还注册 `aclint`、`aia`、`aia-guests`、`acpi` 和 `iommu-sys` 等属性。这些内容说明“这类机器允许怎样配置”。

用户真正启动一次 QEMU 后，`RISCVVirtState` 保存本次实例选择的 hart、内存图、flash、FDT、中断模式和设备引用。`virt_machine_init()` 根据 MachineState 逐步创建对象、设置属性、realize、映射 MMIO、连接 IRQ，最后准备固件和发现数据。

Class 与实例的分离让两个需求同时成立：一种 machine 可以声明稳定能力；每次运行又能根据 `-smp`、`-m`、`-machine aia=...` 等参数得到不同拓扑。设备模型自身不应该偷偷读取全局命令行来决定地址，这类选择属于 machine 装配层。

:::: {.quick-quiz}
为什么 UART 模型不应把 RISC-V `virt` 的 `0x10000000` 写进自己的实现？

::: {.quick-answer}
UART 寄存器语义可以被多块板复用，板级地址属于 machine 契约。把地址留在 `virt.c`，同一 UART 才能出现在其他 machine 的不同窗口，设备补丁和板级布线也能分别审查。
:::
::::

## FDT 让运行时配置成为 guest 输入

`virt` 支持不同 hart 数量、RAM 大小、中断控制器和可选设备，guest 不能只靠编译时常量猜测。QEMU 创建 FDT 节点，把 CPU、memory、UART、interrupt parent、PCI ranges、chosen 和 bootargs 等信息交给固件或内核。

FDT 不是调试输出。地址 cell 的宽度、`reg`、interrupt specifier、phandle 和 PCI `ranges` 都是 ABI。对象已经 realize，却漏掉对应 FDT 节点时，QEMU 进程里的设备确实存在，guest 仍然无法发现它；FDT 声明一个未实现设备时，驱动会访问空洞并产生更难定位的错误。

因此新增设备需要同时审查四张图：QOM containment、bus 连接、MemoryRegion 地址图和 guest 发现图。它们描述同一台机器的不同关系，任何一张都不能替代另外三张。

## 真实板模型保存的是可验证的硬件事实

选择 `-machine k230` 时，目标变成运行 Kendryte K230 相关固件与内核。当前上游模型提供 RISC-V core、CLINT、PLIC、watchdog 和 UART，并明确列出尚未模拟的存储路径及 SDK kernel 的页表属性限制。这样的“不完整”并不等于模型无效；关键是已经实现的部分与硬件、固件和测试一致，未实现部分不会被包装成承诺。

真实板开发通常从可观察的启动闭环开始：复位向量能够取指，UART 能输出，timer 和中断足以推进固件，RAM 与 FDT 允许 kernel 启动。随后再按真实软件需求增加 watchdog、存储或其他外设。一次提交把整份芯片手册翻成空壳设备，会扩大维护面，却不能证明任何 guest 路径有效。

K230 patch series 经历多轮 review，CPU 扩展、hart 数量、PLIC/CLINT 布局、直接启动、watchdog IRQ 和测试随证据调整。正文在第十八章会沿其中一条启动路径讲板卡建模；完整版本记录留在研究账本。

## 模型数量也扩大兼容和安全责任

设备模型处理来自 guest 的寄存器值、描述符和 DMA 地址。模型越多，待维护的输入面越大。QEMU 的安全文档只对指定 machine 与硬件虚拟化 Accelerator 组合提供虚拟化安全支持；RISC-V 列出的 machine 是 `virt`。这不表示其他 RISC-V 板模型质量低，它说明板级 bring-up 与恶意 guest 隔离采用不同的支持承诺。

迁移也需要逐项判断。一个 machine 能启动 guest，不会自动获得跨版本迁移保证。客户机可观察状态、machine 默认值、CPU 特性、设备 VMState 和 backend 能力都要进入兼容设计。真实硬件模型经常服务固件开发，未必承诺云平台需要的长期 migration ABI；书中遇到这类情况会明确写出边界。

:::: {.quick-quiz}
QEMU 已经能够模拟某块 RISC-V 板，能否据此认为它适合运行不可信云租户并支持跨版本迁移？

::: {.quick-answer}
不能。功能模拟、虚拟化安全支持和迁移兼容是三项独立承诺，需要分别核对安全文档、machine/accelerator 组合、设备状态以及版本兼容策略。
:::
::::

## 从问题选择 machine

面对一个新的任务，可以先问现有软件依赖什么：

- 已有固件或厂商 SDK 需要复现板级地址和设备时，选择对应真实 machine；
- 只想运行通用 Linux、做内核开发或虚拟化时，优先选择 `virt`；
- 编写驱动或验证 IOMMU、IRQ、reset 等协议时，选择可控制的设备和 qtest；
- 研究 I/O 性能时，从 virtio 的协议路径开始，再判断 vhost 或 VFIO 是否满足迁移与隔离条件；
- 找不到对应 machine 时，先确认能否换用适配 `virt` 的 kernel 和原 rootfs，再决定是否真的需要新增板卡模型。

这个选择过程也解释了 QEMU 模型库为什么长期增长：软件依赖、测试目标和部署边界不断增加，旧契约又不能仅因新硬件出现就被删除。

## 实验：从 FDT 和运行对象反查平台契约

::: {.hands-on}
运行[检查 RISC-V `virt` FDT](../experiments/part-04-machine-and-device-models/chapter-16-riscv-virt-machine/inspect-virt-fdt/README.md)，保存 QEMU 生成的 DTB，将 CPU、memory、UART、中断控制器、PCIe 和 `chosen` 节点逐项对应到 `hw/riscv/virt.c`。随后改变一个 machine 属性，观察 FDT 哪些字段变化。这个实验验证运行时配置怎样成为 guest ABI。
:::

::: {.hands-on}
运行[跟踪 UART realize 与布线](../experiments/part-04-machine-and-device-models/chapter-16-riscv-virt-machine/trace-device-realization/README.md)，比较 `info qom-tree`、`info qtree` 与 `info mtree -f`。记录 UART 的 containment 路径、bus、MMIO 窗口和 IRQ 连接，避免把“对象存在”误写成“guest 已经可访问”。
:::

## 小结

QEMU 的硬件模型数量来自不同的软件和工程问题。真实板为既有固件保存硬件事实，`virt` 给通用 guest 提供合成平台，测试设备追求可控断言，virtio、vhost 和 VFIO处理性能与执行位置。它们共享 QOM、MemoryRegion、IRQ、reset 和迁移框架，却承担不同承诺。

RISC-V `virt` 提供了观察这套关系的入口：MachineClass 定义能力，MachineState 保存一次配置，machine 负责创建和连接可复用设备，FDT 把实际拓扑交给 guest。下一章会继续向内走，完整拆开一个 RISC-V 外设怎样表达寄存器、IRQ、DMA、reset 和长期状态。
