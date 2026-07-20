# 怎样建模一块 RISC-V 板卡

一个新外设可以靠 qtest 逐个访问寄存器；一块新板卡通常从“串口能不能打印”开始验收。这个入口很实用，也容易留下误判：CPU 可能从错误地址起步，固件恰好绕开了它；设备树可能声明了尚未实现的控制器，当前镜像没有加载对应驱动；中断号接错，轮询模式仍然能够启动。板卡建模要把一组局部正确的设备，组合成长期稳定的平台契约。

本章以固定 commit `eca2c16212ef9dcb0871de39bb9d1c2efebe76be` 为基线，对照 RISC-V 抽象平台 [`hw/riscv/virt.c`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/riscv/virt.c) 与真实 SoC 兼容模型 [`hw/riscv/k230.c`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/riscv/k230.c)。`virt`回答“操作系统需要怎样一台通用虚拟机”，K230 回答“现有 SDK、固件和软件已经依赖了哪些硬件事实”。两者都叫 machine，设计约束并不相同。

## 先定义这块板卡准备运行什么

建模之前先写工作负载，而非设备清单。目标可能是一个裸机镜像、RTOS、OpenSBI 加 Linux、厂商 U-Boot 与 SDK 内核，或需要 PCIe 热插和迁移的云客户机。不同目标决定启动链、必须实现的外设、允许的占位和兼容成本。

一份可评审的平台契约至少包含：

- CPU 类型、hart 数、hart ID 与可见 ISA；
- reset PC、Boot ROM、固件、kernel、initrd 和 FDT 的装载关系；
- RAM、ROM、MMIO、PCI ECAM/PIO/内存窗口的地址与重叠优先级；
- 中断控制器、timer、clock、UART、存储和网络的连接；
- 由 FDT 或 ACPI 告诉客户机的设备集合；
- accelerator、热插、reset、迁移和安全方面的限制。

`virt`面向通用软件栈，可以随着标准 RISC-V 生态增加 AIA、ACPI、PCIe 与 IOMMU 等能力。K230 的首要兼容对象是 K230 SDK 的小核启动流，地址和私有 CPU 行为必须回到数据手册、SDK DTB 与运行镜像核对。把前者的“方便”复制到后者，往往会制造一块现实中不存在的混合板。

## Machine、SoC、Device 按责任分层

`MachineClass`定义整机入口、默认 CPU/RAM、最大 CPU 数、可热插类型和对外 properties；Machine 实例持有这一次运行的配置。SoC 对象组合处理器簇、片上中断与片上外设；Device 对象实现一个可复用功能块。分层的目的在于确认谁拥有地址、连线和生命周期。

K230 的层次很直观：`K230MachineState`拥有一个 `K230SoCState`；SoC 初始化 C908 hart array 和两个 watchdog child；SoC realize 创建 SRAM、Boot ROM、PLIC、CLINT、UART 与占位区；Machine 再把外部 DDR RAM 映射到系统地址空间，并在 machine-init-done 阶段安排启动。

`virt`没有为了形式统一再包一层单体 SoC。Machine 按 socket 创建 hart array 和每 socket irqchip，再连接全局 UART、RTC、flash、virtio-mmio 与 GPEX PCIe host。对象层级可以不同，责任仍应清楚：设备实现寄存器，machine 选择实例、地址和接线，启动帮助代码建立复位入口。

:::: {.quick-quiz}
为什么不能让一个 UART 模型自己决定 MMIO 基址和 PLIC 中断号？

::: {.quick-answer}
同一 UART IP 可以出现在不同 SoC，基址和中断路由属于平台集成。设备只暴露 MMIO 与 IRQ 端口，machine 或 SoC 负责把它们连接到本板卡的资源图。
:::
::::

## `virt` 的内存图是一份平台 ABI

`virt_memmap[]`把调试区、MROM、test finisher、RTC、CLINT/ACLINT、PLIC/APLIC、UART、virtio-mmio、flash、PCIe ECAM/PIO/MMIO 和 DRAM 放进固定窗口。riscv64 的高 PCIe MMIO 基址会根据 RAM 顶部对齐计算，避免与内存重叠。表中的地址随后被 machine 初始化、FDT 生成和启动代码共同使用。

这种集中表格减少了三个副本漂移，却没有自动保证正确。每个条目还要检查区域大小、地址对齐、重叠优先级、32/64 位可达范围和固件分配策略。`info mtree -f`看到的是 realize 后的地址空间，FDT 是客户机被告知的视图，两者必须描述同一台机器。

Machine property 也属于契约。`virt`允许选择 PLIC 或 APLIC/IMSIC、ACLINT、ACPI 和 system RISC-V IOMMU；TCG 与 KVM 对某些选项的所有者不同。代码在不支持的组合上报错，比创建一台只完成一半连线的机器更可靠。实验报告应保存完整 `-machine` 参数，单写 `-M virt`无法复原可见平台。

## hart、IRQ 和 clock 构成一张连接图

板卡代码不是按顺序调用若干 `create()`就结束了。它要先确定 hart ID，再为每个 socket 创建本地 timer 和中断控制器，最后把 UART、virtio 与 PCIe 的输出接到正确 irqchip 输入。使用 APLIC/IMSIC 时，MSI 地址、hart 数和 guest interrupt file 数还要一致。

一条 UART 路径可以这样审计：FDT 中的 `reg`对应 MemoryRegion 基址；`interrupt-parent`指向 PLIC/APLIC 节点；中断号对应 machine 传给 `qdev_get_gpio_in()`的输入；设备 property 决定 regshift、端序和 baudbase；chardev 则来自当前串口配置。任一项错位都会让驱动观察到另一台设备。

clock 也要进入连接图。CPU timebase、ACLINT timer frequency、UART baudbase 和 watchdog 计数源可能来自不同规范。QEMU timer 使用何种虚拟时钟只是实现选择，FDT 中报告的频率以及客户机据此换算出的时间才是平台行为。

## 启动链从 reset PC 一直延伸到 FDT

RISC-V CPU reset 后先执行 reset vector。`virt_machine_done()`在所有动态设备和 FDT 准备完成后选择固件，装载可选 kernel，计算 FDT 地址，并通过 [`hw/riscv/boot.c`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/riscv/boot.c) 把跳转代码放进 MROM。通常 OpenSBI 运行在 M-mode，为 S-mode kernel 提供 SBI；U-Boot 可以位于固件与 kernel 之间，负责镜像、设备树和启动参数。

`virt`在 TCG 下可以走固件启动或直接 kernel 启动。当前基线的 KVM 路径只支持直接 kernel 启动，machine 会拒绝 M-mode firmware 组合，并把 kernel entry 与 FDT 地址交给 RISC-V KVM。accelerator 改变启动状态的所有者，却不能改变客户机最终要拿到 hart ID、FDT 和正确特权级入口的要求。

K230 的直接启动使用 SDK 小核布局：OpenSBI 从 `0x08000000`附近装入，kernel 放在 `0x08200000`，FDT 放在 `0x0a000000`；缺少 `-dtb`或显式禁用 firmware 都会报错。另一条 firmware 路径从 DDR 起始地址装载 U-Boot，不接受 `-dtb`和 `-append`，由固件或后续软件提供设备树。两条路径共用同一 SoC，入口和 FDT 所有者不同。

## FDT 必须和已实现硬件同步

`virt`在用户没有传入 DTB 时生成 FDT，CPU、memory、irqchip、UART、virtio、PCIe 与 IOMMU 节点来自同一份 machine 状态。动态 sysbus 和 PCI IOMMU 可能在早期创建后继续修改 FDT，所以代码等到 machine-init-done 才 finalize。若用户传入 DTB，注释明确要求它自行包含全部设备。

K230 不生成一棵“看起来完整”的厂商 DTB。固定基线文档 [`docs/system/riscv/k230.rst`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/docs/system/riscv/k230.rst) 要求直接启动传入派生自 SDK 的 DTB，并禁用当前未模拟的控制器。这样做承认了模型边界：QEMU 尚不能替厂商固件决定每个节点、reserved-memory 和私有属性。

FDT 节点存在会促使驱动探测。若对应区域只是占位，读取零值可能让某些驱动退出，也可能让另一些驱动等待永远不会到来的 ready 位。设备树、模型和目标软件必须一起评审。

:::: {.quick-quiz}
`info mtree`中存在 UART 区域，为什么仍不能证明 Linux 会使用它？

::: {.quick-answer}
客户机还依赖 FDT 的 compatible、reg、clock 和 interrupt 描述。地址空间只证明 QEMU 映射了区域，不能证明客户机获得了匹配的硬件描述和连线。
:::
::::

## K230 用占位明确表达未实现范围

真实 K230 地址图包含 AI、视频、DMA、I2C、GPIO、SD、USB 等大量模块。当前模型实现一颗 C908 小核、CLINT、PLIC、五个 UART 与两个 watchdog，其余窗口多由 `create_unimplemented_device()`覆盖。占位设备以优先级 -1000 映射，真实子区域可以叠加在上面；访问会记录 `LOG_UNIMP`并返回零。

UART 窗口提供一个具体例子。SDK 给每个 UART 留出 0x1000 字节，16550 兼容寄存器只占其中一部分。machine 先用占位覆盖整窗，再把 `serial-mm`以 regshift 2 映射到同一基址并连接 PLIC。已实现寄存器落到 serial，剩余偏移仍能被记录，避免未映射访问直接变成难以定位的异常。

占位只提供地址探针和日志。它没有 IRQ、DMA、时序、reset 语义，也不能算成“支持该设备”。文档的 supported devices 应只列完成功能闭环的模块；实验若依赖某个占位区，需要标成待实现条件。

## 一次 K230 评审怎样收紧平台契约

K230 series 从 v1 走到 v8，正文只保留一个与本章直接相关的现场。[v8 最终补丁](https://patchew.org/QEMU/cover.1781246408.git.chao.liu%40processmission.com/a161697a249b896e44e2748435f6c0caec12c9f4.1781246408.git.chao.liu%40processmission.com/)仍以“U-Boot 和 Linux 能运行”为目标，前几轮却连续暴露出平台级约束：v3按数据手册修正 PLIC/CLINT 地址，v5修复 reset vector ROM 跳入 trap handler 的错误，v7处理未实现 UART 偏移导致的 Oops、把 hart 数收敛到已支持的一颗小核，补上直接 Linux 启动，并已明确这条启动流的 DTB 由 K230 软件链提供、QEMU 不生成。v8主要完成 rebase、M-mode 检查与 riscv64 Machine interface 注册等收尾，不能把 DTB 决策推迟归因到这一版。

最终提交 [`6cf0d08c3953ee447cb215edc3a384834cbe48db`](https://gitlab.com/qemu-project/qemu/-/commit/6cf0d08c3953ee447cb215edc3a384834cbe48db)记录 Chao Liu 为作者，Peng Jiang 提供 `Tested-by`，Alistair Francis 给出 `Acked-by`并签入，Nutty Liu 给出 `Reviewed-by`；同一提交把 K230 machine 的维护责任写入 `MAINTAINERS`。这些角色说明的是可追溯责任范围，无法代替地址表、启动镜像和测试结果。

这个现场带回一条当前开发规则：启动日志只能证明被走到的路径。评审需要主动触碰 reset、未实现偏移、实际 hart 拓扑和另一条 boot flow，才能发现平台契约里尚未显现的空洞。

## 从最小 machine 逐步长成一块板

新 machine 的第一步可以很小：注册 `TypeInfo`和 `MachineClass`，创建一个 hart、一段 RAM 与一段只读 reset vector，让几条裸机指令从已知 PC 执行。此时就应加入 qtest，检查 CPU 类型、hart ID、RAM 边界和 reset PC。若这四项还在变动，提前堆入几十个外设只会扩大排查范围。

第二步加入本地 timer、中断控制器和一只 UART。每加一条 IRQ，都同时检查设备输出、控制器输入、FDT interrupt specifier 和客户机 handler；每加一个 MMIO window，都比较 memmap、`info mtree`和 FDT `reg`。串口出现字符后，再让 timer 产生中断、UART 在收发状态下复位，确认启动通路没有依赖轮询或偶然初值。

第三步再接 firmware、kernel、initrd 与完整 FDT。启动帮助代码应在镜像装载前检查地址范围和重叠，必需输入缺失时报告可操作的错误。machine-init-done 适合处理必须等待动态设备确定后才能完成的内容，却不能掩盖初始化次序混乱；对象所有权、notifier 撤销和失败回滚仍要清楚。

真实 SoC 可以随后把处理器簇和片上外设下沉到 SoC child，machine 保留板级 RAM、flash、插槽和启动策略。尚未实现的窗口用占位和文档明确标出，软件树中相应节点默认禁用。每个阶段都应有能独立说明新增契约的测试、文档和 `MAINTAINERS`范围，review 才能判断这次变化究竟扩展了哪一部分平台。

## 实验：把外设状态机连续接到 RISC-V 板卡

::: {.hands-on}
配套手册：[`build-riscv-mmio-board-path`](../experiments/part-04-machine-and-device-models/chapter-18-pcie-and-riscv-iommu/build-riscv-mmio-board-path/README.md)。

这个实验不另造一套孤立示例，而是把第 17 章的寄存器合同继续向外推进：先用 Python 状态机验证 mask、pending、W1C、reset 与派生 IRQ，再检查一份固定到 `v11.1.0-rc0` 的教学 patch，沿 QOM、SysBus、MemoryRegion、VMState 走到 `virt` 的地址、PLIC 输入和 FDT。设备默认关闭，未启用时不出现 MMIO 与 DTB 节点，避免把教学接口偷偷变成既有 `virt` 的默认 ABI。

具备隔离源码树和 RISC-V 工具链时，再实际编译 tree-out QEMU，运行 qtest、FDT 对照与裸机探针。报告必须把 host 单元测试、源码/补丁检查、TCG live 结果和未完成的 KVM/AIA/迁移验证分栏；补丁中的虚构 binding 不是上游设备规范。重点是看清同一个行为怎样跨过“设备内部状态—板级资源—固件发现—客户机访问”四道边界，而不是把 patch 行数当作建模完成度。
:::

## PCIe 与 RISC-V IOMMU 把板卡扩展成可变拓扑

`virt`通过 GPEX host bridge提供 PCIe。ECAM承载配置空间，PIO与低/高 MMIO窗口承载 BAR，四根 INTx 或 MSI路径接入 RISC-V irqchip。BDF 是 PCI 拓扑身份，BAR 是设备资源，ECAM 地址是 CPU 访问配置空间的窗口；三者不能混成一个“设备地址”。

挂入 [`riscv-iommu-pci`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/riscv/riscv-iommu-pci.c) 后，machine 在 FDT 的 PCI 节点写入 `iommu-map`，把 requester ID映射到 IOMMU context。`iommu-sys=on`则创建 platform IOMMU，并用四根有线中断或 MSI报告 command/fault/page-request事件。设备发出的 IOVA 经过 context、页表权限与 IOTLB 后落到 GPA；PCI BDF 始终参与隔离身份。

板卡层要决定 IOMMU 位于哪条 bus、覆盖哪些 requester、怎样送中断以及 reset 时谁先停 DMA。IOMMU 文件能独立编译不代表接线完成。当前 PCI IOMMU 还明确阻止迁移，system 形式也缺少足以证明完整迁移的 VMState；这两项限制应出现在 machine 文档和测试预期中。

## “能启动”之后还要验证什么

板卡验证可以分成五层。第一层用 `info qom-tree`、`info qtree`、`info mtree -f`和 FDT 检查对象、bus、地址与描述；第二层用 qtest 验证 reset vector、MMIO 边界和 IRQ；第三层运行 OpenSBI、U-Boot、bare metal、RTOS 与 Linux 的目标路径；第四层覆盖 system reset、多 hart、中断风暴、DMA fault 和后端失败；第五层才讨论迁移、热插与性能。

兼容审查要记录客户机可见的地址、IRQ、hart ID、FDT compatible、默认设备、boot 地址和 property 默认值。更新一个默认值可能使新客户机更方便，也会改变旧镜像和迁移两端看到的平台。真实硬件模型还要区分“修正文档不一致”和“改变已经发布的 QEMU 行为”，两者的版本处理不同。

:::: {.quick-quiz}
一块 K230 machine 已经启动到 Linux shell，为什么仍需测试未实现 UART 偏移和 system reset？

::: {.quick-answer}
当前启动路径可能只访问已实现寄存器，且从未再次复位。驱动探测、异常路径和重启会触碰另一组地址与生命周期；它们同样属于客户机可观察的平台行为。
:::
::::

## 实验：把 PCIe 的四种视图对齐

::: {.hands-on}
配套手册：[`map-pcie-topology`](../experiments/part-04-machine-and-device-models/chapter-18-pcie-and-riscv-iommu/map-pcie-topology/README.md)。

在 RISC-V `virt`上挂一个固定 BDF 的 `virtio-blk-pci`或实验环境支持的 PCI 设备，保存 `info pci`、`info qtree`、`info mtree -f`与 FDT。把 BDF、配置空间、BAR、ECAM、低/高 MMIO窗口和中断路径画在同一张表中；有 Linux 客户机时再用 `lspci -vv`核对。

预期四种视图指向同一 realized fabric，但表示层次不同。BAR 的具体分配值可能由 firmware 或 kernel 决定，报告要注明分配者，不能把一次运行值写成 machine 固定常量。
:::

## 实验：跟踪一笔经过 RISC-V IOMMU 的 DMA

::: {.hands-on}
配套手册：[`trace-iommu-translation`](../experiments/part-04-machine-and-device-models/chapter-18-pcie-and-riscv-iommu/trace-iommu-translation/README.md)。

实验使用兼容的 RISC-V Linux配置 device context 和 IOVA 映射，再让 E1000E 发送固定数量数据报。把 guest 探针计数、BDF、IOVA、翻译后的物理地址与 `riscv_iommu_dma` trace event关联。仓库附带的合成 fault 只验证解析器；只有 live trace 出现 `riscv_iommu_flt`，才能声称客户机进入了故障路径。

运行条件不足时，沿 `riscv_iommu_memory_region_translate()`、context fetch、页表翻译和 fault record做固定源码审计，并明确结果没有覆盖真实 DMA。正向映射、权限拒绝、IOTLB失效和 reset分别保存证据，避免用一条成功 trace替代整个隔离协议。
:::

当这些检查都能回答时，板卡模型才从“设备可以拼起来”走到“平台可以被软件长期依赖”。启动成功仍然值得庆祝，它是后续验证的起点。
