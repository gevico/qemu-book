# 一台虚拟机要承诺什么

一次 QEMU 升级后，固件仍能打印，Linux 却停在设备探测。开发者比较了两份日志，没有发现非法指令，也没有看到设备模型报错。最后的差异落在 DTB：中断控制器节点的连接方式变了，内核按旧平台假设等待一条永远不会到来的中断。

这类故障提醒我们，Machine 的价值不在于“把若干设备创建出来”。它要向客户机交付一组能够互相印证的事实：CPU 拓扑与 hartid，物理地址与设备寄存器，中断连线，固件入口，硬件描述，复位值和可选功能。客户机把这些事实当成平台来编程。QEMU 内部可以重构，平台暴露出去的行为却要经过兼容性审查。

本章选择 RISC-V `virt`。它不复刻任何一块实体开发板，反而更容易看清 Machine 的工程职责：当硬件照片退场以后，剩下的每一项细节都来自一份显式的虚拟机契约。

## `virt` 解决的是“先给软件一个共同平台”

RISC-V 允许厂商组合扩展和 SoC，各块开发板的 UART、PLIC、内存地址与启动固件都可能不同。操作系统开发者若只想验证通用内核，不希望先适配某家板卡的限制，需要一套稳定、可发现、适合虚拟设备的环境。`virt` 正是为这种需求准备的合成平台。

当前 [`virt` 文档](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/system/riscv/virt.rst)明确说明它不对应真实硬件，并推荐给只想运行 Linux 等客户机、无需复现实板特性的用户。平台提供通用 RISC-V CPU、内存、本地与外部中断控制器、NS16550A UART、RTC、flash、virtio-mmio、PCIe 和 fw_cfg 等能力。具体实例还受 `-smp`、`-m`、`aia=`、`iommu-sys=`、设备选项与加速器约束影响。

合成平台减少了厂商偶然差异，也会形成自己的约束。Linux 依赖 DTB 中的 `compatible`、`reg` 和 `interrupts`，OpenSBI 依赖启动寄存器与 CLINT/ACLINT 选择，PCIe 设备依赖 ECAM 和 MMIO 窗口，迁移与快照还依赖设备状态。平台没有焊在电路板上，不等于它可以随一次代码整理任意改动。

:::: {.quick-quiz}
RISC-V `virt` 不对应真实开发板，是否可以把 UART 地址从 `0x10000000` 调到空闲位置而不做兼容性分析？

::: {.quick-answer}
不可以直接这样做。固件、内核、裸机程序、DTB 处理和测试都可能观察该地址。虚拟平台同样会形成 ABI；修改前要识别受影响软件、是否有显式选择机制，以及旧配置如何继续运行。
:::
::::

## 2018 年的最小平台已经写出了边界

RISC-V `virt` 的引入提交是 Michael Clark 的 [`04331d0b`](https://gitlab.com/qemu-project/qemu/-/commit/04331d0b56a0cab2e40a39135a92a15266b37c36)。提交说明只列出 device tree、CLINT、PLIC、16550A UART 和 virtio-mmio，Richard Henderson 给出 `Acked-by`，Palmer Dabbelt 与 Michael Clark 留下 `Signed-off-by`。这份角色信息足以说明补丁经过架构与实现侧协作；它没有告诉我们所有地址选择为何如此，正文也不替当时的参与者补充未记录的讨论。

这个历史现场有一个值得保留的转折：第一版就同时提交 Machine 代码和设备树生成。创建 UART 只解决 QEMU 内部有一个对象；把 UART 的地址、兼容串和中断告诉客户机，平台才具备可用性。后来 PCIe、flash、OpenSBI 启动、多 socket、AIA 与 IOMMU 逐步加入，仍要同时维护对象连接和客户机硬件描述。

今天的实现已经远大于最初 494 行。本章不沿提交列表逐项回放，而是回到 `v11.1.0-rc0`，用当前代码回答 Machine 必须保持哪些关系。

## 当前源码里有三份互相校验的平台描述

第一份是 [`hw/riscv/virt.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/virt.c) 中的 `virt_memmap[]`。它给 MROM、test device、RTC、CLINT/ACLINT、PLIC/AIA、UART、virtio、flash、PCIe ECAM/MMIO 和 DRAM 预留客户机物理范围。数组只是地址骨架，不能单独推出本次启动一定创建哪些对象。

第二份来自 `virt_machine_init()` 的装配。函数读取 Machine 与加速器属性，创建 hart array 和 RAM，根据 PLIC/AIA、ACLINT、IOMMU 等选项选择分支，再把 sysbus 设备、PCIe、virtio 与中断连接起来。设备内部寄存器行为留在各自模型中，Machine 负责它们在这块平台上的位置和连线。

第三份是动态生成的 FDT。`create_fdt()` 建立基础树，设备和中断拓扑确定后由 `finalize_fdt()` 补齐 CPU、memory、virtio、PCIe、UART、RTC 与 reset 节点，随后 [`hw/riscv/boot.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/boot.c) 把 DTB 放入客户机内存并把地址交给下一启动阶段。当前文档要求客户机通过生成的 DTB 发现设备；用户也可以用 `-dtb` 提供自己的描述，但 CPU 数、内存大小和启动所需节点要与真实 Machine 对上。

三份描述应当一致。`virt_memmap[]` 说 UART 在一个地址，MemoryRegion 却映到另一个地址，客户机按 DTB 访问就会落空；对象创建了 AIA，DTB 仍描述 PLIC，驱动会选错控制器；`-m` 改了 RAM 大小而自定义 DTB 没更新，内核可能访问不存在的内存。Machine review 的重点经常落在这些跨表示关系上。

:::: {.quick-quiz}
`info qom-tree` 已经显示一个 `riscv-iommu` 对象，能否据此确认客户机驱动一定能发现并使用它？

::: {.quick-answer}
还要检查该对象是否 realize、MemoryRegion 是否映入正确 AddressSpace、中断和 PCIe/IOMMU 关系是否接好，以及 DTB/ACPI 是否描述了同一实例。对象存在只覆盖平台契约的一部分。
:::
::::

## Machine 承诺的是关系，不是一张设备清单

一台机器至少有五组关系。启动关系规定 reset vector、固件、内核和 DTB 的交接；地址关系把 CPU 与 DMA 请求导向 RAM 或设备；中断关系把设备事件送到目标 hart；发现关系让固件和操作系统知道前面三组事实；生命周期关系规定 reset、暂停、迁移和关机时状态怎样变化。

这些关系彼此制约。UART 的 `reg` 与 MemoryRegion 映射要一致，`interrupt-parent` 要指向实际控制器，控制器的 hart context 又要匹配 CPU 拓扑。PCIe host bridge 的 ECAM 与 MMIO 窗口既出现在 Machine 地址图，也出现在 DTB `ranges`；启用 IOMMU 后，`iommu-map` 还要覆盖实际 requester。只介绍每个设备“支持哪些寄存器”，读者仍无法解释平台为何启动。

默认值也属于关系。省略 `-cpu` 时选哪种模型，省略固件时装入什么，`aia=` 默认落到哪条路径，是否创建默认串口或 virtio transport，都会改变客户机观察。QEMU 命令行短，并不代表配置少；许多选择已由 MachineClass 和板级代码替用户完成。可复现实验要显式记录影响结论的默认值，不能依赖另一台构建树恰好相同。

Machine 还承担拒绝非法组合的责任。内存范围越过平台上限、hart 数超出能力、KVM 不支持某种中断模式、自定义 DTB 与配置明显冲突，都应尽量在运行前给出可理解错误。等客户机驱动访问以后才暴露，故障会从配置错误变成黑屏或超时。

## 复位、时间和错误也属于平台行为

地址和设备树容易截图，reset 语义却同样会被客户机观察。系统复位后，CPU 回到 Machine 规定的 reset vector，PLIC/AIA、UART、RTC 与 virtio 设备要恢复各自规范初态；命令行配置、对象连接和后端通常继续保留。用 `memset()` 清整台机器会破坏锁、引用和不可为零的寄存器，也会把“本次配置”与“运行状态”混在一起。

复位还有顺序。设备中断线可能在 CPU reset 前后变化，level-triggered 中断的条件若仍成立，CPU 恢复后应再次看见；MROM 与 FDT 要在 vCPU 放行前完成；incoming migration 目的端则要先装入源端状态，再允许任意 hart 执行。Machine、设备 reset framework、runstate 和 accelerator 各负责一段，客户机最终看到的是组合结果。

时间也是一种平台输入。`virt` 的 timer frequency、RTC、mtime 与中断触发方式要和 DTB/ACPI 描述对上。QEMU 的虚拟时钟会随客户机暂停而停止，宿主 realtime 又有不同语义。驱动若根据声明频率计算 deadline，设备模型却用另一频率推进，启动可能表现为随机超时。功能测试应控制虚拟时间或给出容忍区间，不能把宿主墙钟当成设备规范。

未映射访问与设备错误构成另一面契约。客户机访问空洞、非法寄存器宽度或无效 IOMMU 映射时，QEMU要按平台与设备规则返回读值、总线错误或 fault 记录。宿主断言和进程崩溃只适合内部不变量被破坏；客户机可控输入必须留在虚拟硬件边界内。Machine review 因而也要检查地址空洞和错误路由，不能只验证正常启动。

这些行为不一定全部写进 `virt_memmap[]` 或 DTB。迁移字段、reset callback、MemoryRegionOps 与 timer 创建共同完成它们。平台契约是一组可以被客户机和管理层观察的行为，源码中的“板级文件”只是其中一个入口。

## Machine、CPU、设备和加速器各守一段

`MachineClass` 决定怎样装配平台，`MachineState` 保存本次内存、CPU 拓扑、固件和选项。`RISCVCPU` 负责客户机处理器能力与架构状态；UART、PLIC、AIA、virtio 等设备负责局部协议；TCG 或 KVM 则推进 vCPU。四者会互相校验，却不应复制对方的工作。

以 H 扩展为例。扩展是否存在属于 CPU 能力；TCG 是否实现、KVM 宿主是否支持属于 accelerator 能力；`virt` 是否提供适合客户机 hypervisor 的中断与 IOMMU 环境属于 Machine 选择。打开 H 扩展不会自动启用 KVM，选择 KVM也不会替 Machine 生成另一套地址图。

类似地，Machine 不应实现 NS16550A 寄存器。它选择 UART 类型，设置基址和 IRQ，再让设备 class 处理 read/write、FIFO、reset 和迁移。设备也不应在内部猜测自己位于 RISC-V `virt` 的固定地址，否则放到其他 Machine 时会失去复用。边界清楚以后，新增平台可以重用设备，新设备也能在多个平台上连接。

:::: {.quick-quiz}
同一条 `-machine virt -device virtio-net-device` 命令从 TCG 切到 KVM，哪些承诺应保持，哪些能力允许不同？

::: {.quick-answer}
设备类型、主要地址、中断和发现协议应由同一 Machine 配置维持。vCPU 执行位置、可暴露 CPU 扩展、计时细节与部分 irqchip 实现可能受加速器和宿主能力影响。相同命令行也不能推出两次执行逐位相同。
:::
::::

## 兼容性从观察者出发

判断一项 Machine 改动能否接受，可以列出观察者。固件观察 reset PC、flash、fw_cfg 和 DTB；内核观察 CPU、地址、中断与设备协议；管理工具观察 QMP、对象属性和默认配置；迁移目标观察机器类型、设备集合与 VMState。改内部帮助函数通常不会触及这些表面，改一项默认属性却可能同时影响四类观察者。

QEMU 对部分架构提供带版本号的 Machine 类型，用 compat property 保留旧默认。[迁移兼容文档](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/devel/migration/compatibility.rst)说明源端和目标端需要相同 Machine 类型及硬件配置。RISC-V `virt` 在本书基线中没有公开的逐版本类型名，因此不能套用 `pc-q35-<version>` 那套选择方式。它仍受通用功能弃用政策和客户机兼容约束，只是缺少一组公开版本机型来承载每次默认差异。

兼容也不要求冻结全部实现。可以新增默认关闭的属性，让用户显式选择；可以在确认没有稳定用户后按弃用流程移除功能；内部数据结构可以重写，只要外部可见语义和迁移格式得到处理。审查时需要提交说明、邮件讨论、现有测试与实际用户共同划边界，不能仅按 diff 大小判断风险。

## 审查一次 Machine 改动要沿四条线

假设补丁要给 `virt` 增加一种中断模式。第一条线是创建：Machine property 在哪里注册，默认值是什么，TCG 与 KVM 哪些组合能 realize，失败是否发生在 vCPU 启动前。第二条线是连接：控制器的 MMIO、IRQ、MSI 与每颗 hart 怎样接通，已有 PLIC/AIA 分支是否共享了不适用的假设。

第三条线是发现：FDT/ACPI 如何描述新模式，compatible、`reg`、`interrupts-extended` 和 phandle 是否与实际对象一致，用户自定义 DTB 时谁承担校验。第四条线是生命周期：reset、迁移、热插拔和关机如何保存或撤销状态，旧默认与管理命令是否受影响。

测试应贴着四条线分层。qtest 可以直接访问寄存器和错误范围；最小固件可以验证中断送达目标 hart；Linux 启动验证驱动发现；迁移测试检查运行中 pending 状态。一个完整客户机测试通过，仍不能替代非法属性、旧模式与错误注入。反过来，纯单元测试也不能证明 FDT 和 Machine 已经连起来。

邮件 review 的价值在于让不同维护域共同检查这些线。RISC-V reviewer 熟悉 ISA、hart 与平台规范，设备 maintainer 熟悉局部模型，迁移和 KVM reviewer 会指出状态与 UAPI 边界。补丁最后的 `Reviewed-by` 对应某个版本和具体 diff，不能扩展成所有参与者赞同作者后来对平台的每项解释。

当上游材料没有给出某个地址选择的理由，正文应停在可验证事实：它在哪个提交出现，当前客户机怎样观察，修改会影响谁。一个顺耳的“为了性能”不能补足决策记录。证据不足本身也会转化为后续实验或邮件检索任务。

`virt` 的停止边界同样清楚。它适合通用客户机和虚拟化开发，不承诺复现某块芯片的启动 ROM、外设勘误、时钟树和周期级时序。需要验证厂商固件时，应选择对应真实板模型；需要测真实设备性能时，软件设备的功能一致也不足以替代硬件。第四篇会按这些需求重新组织 QEMU 的硬件模型。

## 实验：把三份平台描述逐项对齐

::: {.hands-on}
运行 [Trace RISC-V `virt` boot](../experiments/part-01-system-foundations/chapter-01-qemu-boundaries/trace-riscv-virt-boot/README.md)，并结合 [Inspect CLI to machine](../experiments/part-01-system-foundations/chapter-02-startup-path/inspect-cli-to-machine/README.md) 固定一条 `-machine virt -S` 命令。导出生成的 DTB、`info qom-tree` 和 `info mtree -f`，选择 UART、一个中断控制器、DRAM 与 PCIe 四项做表格。

每一行记录五列：`virt_memmap[]` 的候选范围，`virt_machine_init()` 的创建分支，运行时对象路径，FlatView 中的实际区间，DTB 节点与中断父节点。随后只改变 `aia=` 或 `iommu-sys=` 一项，再比较新增、删除和保持不变的关系。若宿主不支持某个 KVM 组合，使用 TCG 完成 Machine 实验并保留能力限制。

验收标准不是导出三份大文本。四个对象都要能沿“配置—对象—地址/中断—发现”闭环；任何不一致都先核对命令和版本，再判断是实验读取错误还是平台缺陷。
:::

## 小结

RISC-V `virt` 把一组虚拟硬件组织成固件和操作系统可以依赖的平台。它的契约同时存在于 Machine 配置、运行对象与地址连接、FDT/ACPI 发现信息，以及 reset 和迁移等生命周期行为中。`virt` 没有实体板卡，客户机依赖反而让这些软件定义的关系更加显眼。

Machine 负责连接，CPU 和设备负责各自语义，加速器负责执行。下一章会继续追问：当 QEMU 要在运行时创建不同 Machine、CPU、设备和后端时，普通 C 结构体为什么逐渐不够用；QOM 又如何把类型、配置、失败和销毁放进一套可以共同审查的生命周期。
