# RISC-V `virt` Machine、FDT、qdev 与总线

启动一台 RISC-V虚拟机时，我们常把命令行理解成设备清单：几颗 CPU、一段内存、一块磁盘和一张网卡。QEMU真正创建的是几张同时存在的图。QOM组合树描述对象所有权，qdev总线树描述设备挂接，MemoryRegion拓扑描述 CPU和 DMA能访问的地址，FDT或 ACPI描述客户机应该发现什么。`virt` machine负责让这些图在同一平台契约下对齐。

本章以 QEMU目标版本 `v11.1.0`为背景，源码事实固定在官方 GitLab [`v11.1.0-rc0`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0) 的提交 `eca2c162`。主要入口是 [`hw/riscv/virt.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/virt.c)、[`include/hw/riscv/virt.h`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/include/hw/riscv/virt.h)、[`hw/riscv/boot.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/boot.c) 与 [`docs/system/riscv/virt.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/system/riscv/virt.rst)。历史提交用于解释平台如何演进，未在固定标签中出现的能力不写成当前实现。

## 本章目标

- 跟踪 `virt` Machine类型注册、属性收敛、板级初始化与 machine-done阶段；
- 分清 QOM组合、qdev总线、MemoryRegion地址图和 FDT客户机描述；
- 解释 hart、RAM、PLIC/AIA、UART、virtio-mmio、GPEX PCIe和 IOMMU的装配顺序；
- 理解自动 FDT、用户 DTB、固件、直接内核启动与 ACPI之间的责任边界；
- 从初始 `virt`、GPEX接入和 `iommu-map`修复中判断平台 ABI如何维护。

## `virt` 是合成平台，也是长期契约

官方文档把 `virt`称为不对应具体真实硬件的通用虚拟平台。这个定位允许 QEMU选择适合虚拟化的地址与设备，不必复现某块开发板的历史包袱。合成并不等于随意。客户机固件和操作系统会依赖 CPU拓扑、内存基址、设备地址、中断号、PCIe窗口和 FDT属性；这些信息一旦发布，就形成平台契约。

初始提交 [`04331d0b`](https://gitlab.com/qemu-project/qemu/-/commit/04331d0b56a0cab2e40a39135a92a15266b37c36) 在 2018年加入 RISC-V `virt`，当时已经包含 device tree、CLINT、PLIC、16550A UART与 virtio-mmio。提交规模不大，选择却奠定了发现机制和基本地址图。后续设备都必须融入这份已有契约。

提交 [`6d56e396`](https://gitlab.com/qemu-project/qemu/-/commit/6d56e39649808696b2321cbd200dd7ccaa7ef7fe) 接入通用 GPEX PCIe host。它没有重新实现 RISC-V专用 PCI总线，而是把可复用 host bridge、ECAM、MMIO/PIO窗口和四条 INTx线接到 `virt`。这说明 machine的职责是板级布线，PCI配置和总线语义留在通用子系统。

当前机器继续加入 AIA、fw_cfg、flash、RTC、platform bus、ACPI与 RISC-V IOMMU。源码不断重构，客户机看到的地址和发现数据仍需保持兼容。由当前实现与历史可作出强推断：`virt`是一份持续维护的平台契约，不是一次性测试板。推断的依据是客体行为和修复历史，不能解释成上游承诺所有默认值永久不变。

:::: {.quick-quiz}
合成平台为什么仍然需要稳定地址和发现信息？

::: {.quick-answer}
固件和操作系统会把 FDT/ACPI中的地址、中断与拓扑当作硬件事实。平台虽然没有实体电路，客户机 ABI已经真实存在；随意改变会破坏驱动、启动和迁移。
:::
::::

## TypeInfo、MachineClass 与 MachineState

`virt_machine_typeinfo`把类型名注册为 `MACHINE_TYPE_NAME("virt")`，父类型是 `TYPE_MACHINE`，实例大小为 `RISCVVirtState`，并声明 RISC-V 32位、64位目标以及 hotplug handler接口。类型注册让 `-machine help`能够发现它，也决定 class与 instance回调何时执行。

`virt_machine_class_init()`设置平台级缺省：描述字符串、`virt_machine_init`板级回调、最大 CPU数、基础 RISC-V CPU类型、缺省块设备总线、RAM标识、NUMA回调和热插处理。它还注册 `aclint`、`aia`、`aia-guests`、`acpi`与 `iommu-sys`等 machine属性。属性出现在 class上，每个 `RISCVVirtState`实例保存最终选择。

`virt_machine_instance_init()`建立实例缺省值和对象属性初态；instance finalize释放未 realize的 flash对象与动态字符串。class描述同类型共享能力，instance承载一次命令行产生的状态。把用户可变值放进 class会污染同进程内其他 machine实例或测试。

通用 `machine_run_board_init()`先验证 CPU类型、SMP/NUMA、内存后端和 accelerator前提，再调用 `MachineClass.init`。因此 `virt_machine_init()`接收到的 `machine->cpu_type`、`ram_size`与 SMP拓扑已经经过一轮收敛。板级代码仍要校验 socket上限、连续 hart ID和 accelerator特有约束。

当前固定源码只注册一个 RISC-V `virt`类型，没有 `virt-11.1`之类按发行版命名的 TypeInfo，也没有本 machine自建的版本链。QEMU通用 MachineClass支持 compatibility properties，其他平台会大量使用；不能据此写成当前 RISC-V `virt`已经提供版本化 machine名称。

这项源码事实带来一条工程推断：RISC-V `virt`的默认值变更更需要谨慎审查，迁移兼容主要依靠稳定平台行为、设备 VMState与显式属性，而不能假定选择旧 machine别名即可冻结全部缺省。若未来加入版本化类型，本书应按新 tag更新。

## 四张拓扑图各回答一个问题

QOM树回答“谁拥有谁”。`RISCVVirtState`通过 `object_initialize_child()`拥有 hart array，flash也被添加为 machine child；SerialMM内部又组合一个 SerialState。对象父子决定生命周期与 canonical path，却不会自动给设备分配地址或中断。

qdev总线树回答“设备连接到哪条硬件总线”。PCI设备挂到 GPEX创建的 PCI bus，virtio设备可以挂到 virtio-mmio bus或 virtio-pci transport，SysBusDevice常用于板载 MMIO设备。总线负责地址约束、枚举和热插接口，也不自动成为对象内存所有者。

MemoryRegion树回答“哪段地址由谁响应”。machine把 RAM放在 `0x80000000`，把串口区域放在 `0x10000000`，把 ECAM与 PCIe MMIO alias加入 system memory。设备可能已经 realize并出现在 qtree，却尚未映射到 CPU AddressSpace；此时客户机仍访问不到。

FDT回答“客户机相信有哪些硬件”。节点描述 compatible、reg、interrupt-parent、interrupts、ranges与 phandle关系。它是固件/OS发现接口，不控制 QEMU对象本身。FDT多一个 UART节点不会创建串口，QEMU多一个设备而 FDT漏节点也不会让 Linux自动知道。

ACPI提供另一种固件描述路径，fw_cfg负责向客户机提供表。`virt`当前可以生成 ACPI，但自动 FDT仍是 RISC-V实验的主线。两者若同时描述平台，应共享同一对象和地址事实，不能各维护一套脱节的常量。

这四张图经常使用相同名称，最容易造成误读。`/soc/uart@10000000`是 FDT路径，QOM canonical path是宿主对象路径，qtree展示 parent bus，mtree显示 MemoryRegion。实验必须同时保存，才能证明它们指向同一设备而非同名对象。

:::: {.quick-quiz}
为什么在 QOM树里看到 UART，仍不能证明客户机能访问它？

::: {.quick-answer}
QOM只证明对象存在和所有权成立。UART还要完成 realize、把 MMIO region映射进 system memory、连接中断，并在 FDT/ACPI中发布，客户机才能按预期发现和访问。
:::
::::

## 固定地址图怎样进入代码

`virt_memmap[]`集中保存板级区域。低地址包含 debug、mask ROM、test和 RTC；CLINT/ACLINT、PCIe PIO、system IOMMU与 platform bus位于其后；PLIC/APLIC占据中断控制器窗口；UART从 `0x10000000`开始，八个 virtio-mmio transport从 `0x10001000`起按固定步长排列。

fw_cfg位于 `0x10100000`，flash窗口从 `0x20000000`开始，IMSIC M/S区分别位于 `0x24000000`和 `0x28000000`附近；PCIe ECAM为 `0x30000000`起的大窗口，低 4G PCIe MMIO从 `0x40000000`开始，DRAM基址固定为 `0x80000000`。具体大小以 `virt.h`宏和 memmap为准。

表集中化减少 FDT与设备创建各自手写数字的风险。`virt_machine_init()`从同一表映射 MemoryRegion，`create_fdt_*()`从同一表生成 `reg`和 `ranges`。共享常量只能降低出错概率，字段含义仍可能写错；后面的 `iommu-map`修复就是例子。

RV64的高 PCIe MMIO窗口基址由 RAM顶端向上按固定窗口大小对齐，窗口大小为 16 GiB。这样大 BAR不会与可变 RAM重叠。RV32使用固定的高窗口并限制过大的 RAM。由此可见，部分地址是固定 ABI，部分地址由 machine配置派生；FDT必须发布最终计算值。

内存图还要处理 socket分布。`create_fdt_socket_memory()`按 NUMA/socket描述相应内存，machine实际 RAM和 FDT节点必须一致。只改设备树的 memory size不会扩大 QEMU RAMBlock，只改 `-m`却使用旧用户 DTB会让客户机访问不存在范围。

板级固定表也定义资源冲突边界。system IOMMU、platform bus和 PCIe PIO紧邻，新增设备前要检查范围、对齐和未来扩展空间。把寄存器模型写对后再随意找空地址，会让 machine patch难以维护；地址与 IRQ属于平台评审内容。

## hart array 与 socket装配

`virt_machine_init()`先取得 socket数量并检查 `VIRT_SOCKETS_MAX`。每个 socket还要通过 `riscv_socket_check_hartids()`确认 hart ID连续，取得 base hart ID和 hart count。错误在创建 CPU前终止，避免一半 socket已经 realize后才发现拓扑无法描述。

每个 socket由一个 `RISCV_HART_ARRAY` child表示。machine设置 `cpu-type`、`hartid-base`与 `num-harts`后 realize，hart array再实例化每个 `RISCVCPU`。这种分层让 socket/NUMA布线留在 board，单个 CPU模型专注 ISA和执行状态。

本地中断和 timer按 accelerator与 machine属性选择。TCG/qtest允许 ACLINT或兼容 CLINT路径，KVM当前不允许 machine模拟 ACLINT。AIA为 `aplic-imsic`时，本地 timer与 MSI拓扑又与 PLIC模式不同。machine先知道 hart范围，才能给每个控制器正确连接 CPU输入。

外部中断控制器同样按 socket创建。`aia=none`选择 PLIC；其他模式调用 `riscv_create_aia()`建立 APLIC以及可选 IMSIC。首几个 socket还承担 mmio、virtio与 PCIe IRQ目标分配。这个策略属于 `virt`平台选择，不能从控制器设备源码单独推断。

KVM且选择内核 AIA时，所有 QEMU前端对象创建后还会调用 `kvm_riscv_aia_create()`。第 14章已经说明状态所有权差异；在本章只需看到 machine是唯一掌握 hart数、地址和 `aia-guests`的层，因此 KVM device必须由 board参数化。

FDT CPU节点、CPU interrupt-controller phandle、本地中断扩展与 PLIC/AIA连接都从同一 socket循环生成。若 hart ID不连续，某些 binding可以表达稀疏布局，当前 machine却明确拒绝；这是实现限制和平台契约，不是 RISC-V ISA禁止稀疏 hart。

## RAM、ROM 与高地址窗口

通用 MachineState已经持有 `machine->ram`，`virt_machine_init()`把它映射到 `VIRT_DRAM.base`。KVM memory listener随后把 RAM投影成 slots，TCG则通过软 MMU访问。同一 machine地址图服务两种 accelerator，设备和 FDT不应因为执行引擎而改变基本 DRAM位置。

mask ROM由 board创建独立 ROM MemoryRegion，映射到 MROM地址。machine-done阶段写入 reset vector，让初始 PC从平台规定位置跳到 firmware或直接加载目标。ROM内容与 RAM不同，reset后可重建，迁移也不需要把 host指针写入流。

两块 CFI flash在 instance阶段先创建并成为 machine child，板级代码设置 sector、宽度、ID与 drive别名，之后映射到 flash窗口。pflash0常放代码，pflash1可保存变量。设备模型可复用通用 CFI实现，`virt`只定义数量、地址与启动约定。

GPEX提供一块内部 ECAM region与一块 PCI memory region，board创建 alias映射到 `virt`规定的 CPU物理窗口。alias offset要注意：低 PCIe MMIO把内部空间某一段映射到低窗口，高窗口又映射另一地址范围。QOM看到同一个 GPEX，mtree会显示多个 alias。

地址计算需要防止 RAM与高 PCIe MMIO重叠。RV64先计算 RAM末端，再按 16 GiB窗口对齐；大内存使基址上移，FDT `ranges`随之改变。实验对比两个 `-m`值时，应预期高窗口变化，不要把它当成随机行为。

## 设备创建顺序体现依赖

完成 CPU与 irqchip后，board映射 RAM和 MROM，创建 fw_cfg、test、八个 virtio-mmio transport、GPEX、platform bus、UART、RTC与 flash。这个顺序并非所有设备都严格依赖前一个，但中断目标必须先存在，FDT必须在最终地址和部分动态设备信息可用时生成。

fw_cfg需要在加载 FDT前准备。源码注释指出，若先把 FDT作为 ROM装载，再尝试通过 fw_cfg修改内容，可能遇到空间不足。这里的设计依据来自实际数据生命周期：FDT在 finalize之前可扩展，装载之后只应按最终 blob使用。

八个 virtio-mmio实例通过 `sysbus_create_simple()`创建，地址按 memmap步长排列，IRQ从 `VIRTIO_IRQ`连续分配。transport此时存在，即使没有具体 virtio设备挂到它。FDT仍列出这些 transport，让客户机驱动可以探测实际 device ID。

GPEX先设置 ECAM、低/高 MMIO与 PIO属性，再 `sysbus_realize_and_unref()`。realize后 board取得 MemoryRegion，创建 alias并连接四条 INTx线。PCI bus由 GPEX内部创建，后续 `-device ...-pci`才能挂接。颠倒顺序会让命令行设备找不到目标 bus。

UART使用通用 `serial_mm_init()`创建 16550A兼容 SerialMM，board给出地址、IRQ、baudbase、chardev与小端属性。RISC-V只体现在平台布线，UART寄存器模型位于 `hw/char/serial*.c`。把它称为“RISC-V UART实现”会误导源码定位。

system IOMMU在 FDT创建之后由 machine属性决定是否实例化。board设置地址、四条连续 IRQ起点、irqchip link与物理地址位数，再 realize。FDT节点在 `finalize_fdt()`阶段补齐。第 18章会说明 PCI与 sysbus两种封装共享同一核心模型。

## FDT 先搭骨架，再在 machine-done收口

没有 `-dtb`时，`create_fdt()`先调用公共 helper创建 root compatible/model，加入 PCI节点骨架、`/chosen`、随机种子与 `/aliases`，再创建 flash、fw_cfg和 PMU节点。PCI骨架提前存在，是为了 machine-done前发生 PCI hotplug时，plug callback仍能添加 IOMMU子节点。

`finalize_fdt()`按当前 machine状态创建 socket/CPU/内存、CLINT/ACLINT、PLIC/APLIC/IMSIC、virtio-mmio、system IOMMU、PCIe、reset、UART与 RTC节点。每类 helper负责自己的 binding，main函数负责顺序与 phandle传递。这样的拆分让 AIA或 IOMMU修改可以单独评审。

phandle是图边，不是装饰数字。CPU interrupt-controller、PLIC/APLIC、IMSIC、PCIe MSI parent与 IOMMU map互相引用。分配顺序可以重构，引用目标必须一致；客户机不应依赖某个具体 phandle数值，却会依赖关系正确。

FDT `reg`描述 MMIO地址，`interrupt-parent`与 `interrupts`描述外部线，PCI `ranges`描述总线地址到 CPU地址映射，`iommu-map`把 requester ID区间映射到 IOMMU specifier。四者各自有 cell编码与长度规则，复用同一 memmap仍不能防止 tuple写错。

提交 [`926a8b8e`](https://gitlab.com/qemu-project/qemu/-/commit/926a8b8e4f11a1b1955f5f46c89069614ea28156) 修正 system IOMMU的 `iommu-map`。[对应邮件](https://lore.kernel.org/qemu-devel/20260608210642.464131-1-daniel.barboza@oss.qualcomm.com/)与最终提交都指出，旧代码多生成一个长度为零的空 tuple，还把 `0xffff`误当末地址；binding实际要求 length，正确覆盖全部 requester ID需要 `0x10000`。错误由另一平台复用 `virt` 代码时暴露，这是上游陈述；由此进一步判断跨 Machine 复用有助于发现复制的 binding 缺陷，则是本书的工程推断。

该修复由另一个平台复用代码时发现。可以作出强推断：共享 FDT helper和跨 machine review能暴露复制粘贴的 binding错误。推断不等于所有重复代码都应立即合并；helper接口必须有稳定语义，过早抽象也可能隐藏平台差异。

若用户提供 `-dtb`，QEMU加载该 blob并跳过自动 finalize。源码注释明确要求用户 DTB包含全部内容，包括动态 sysbus设备。QEMU不会把自己的 UART、PCIe和 CPU节点可靠地补进任意外部树。用户因此承担 `-smp`、`-m`、中断模式和设备布局一致性。

:::: {.quick-quiz}
为什么共享 `virt_memmap`仍没有阻止 `iommu-map`出错？

::: {.quick-answer}
memmap只提供地址和大小，`iommu-map`还要按 binding编码 requester ID、phandle、specifier与 length。数据源正确，tuple含义或 cell数量仍可能写错，必须用生成的 DTB和规范交叉检查。
:::
::::

## machine-done 完成启动契约

`virt_machine_done()`在所有初始设备创建结束后运行。若使用自动 FDT，它先 finalize；用户 DTB则保持用户内容。之后根据 accelerator与命令行处理 firmware、pflash、kernel、initrd和 FDT装载地址，最后建立 reset vector。

TCG可以加载默认 OpenSBI等 M-mode firmware，也可以按约定从 pflash启动。若 pflash存在，代码区与 S-mode payload的组合会影响跳转地址。machine层必须同时理解板级存储窗口和 RISC-V启动协议，通用 flash设备不会决定 CPU reset PC。

KVM当前只支持直接启动 kernel。machine-done在 KVM下拒绝非 `none`的 machine-mode firmware，加载 kernel与 FDT后调用 `riscv_setup_direct_kernel()`，后续 vCPU reset把入口、hart ID和 FDT地址送入寄存器。这个限制是当前实现边界，不是 `virt`平台或 RISC-V架构的永久要求。

FDT地址由 `riscv_compute_fdt_addr()`结合 DRAM、kernel/initrd范围计算，避免镜像重叠。`riscv_load_fdt()`把最终 blob写入 guest memory，reset vector把地址传给固件或内核。直接把 DTB固定在某个高地址会在不同 RAM大小下越界。

reset ROM通过 `riscv_setup_rom_reset_vec()`生成，包含跳转和必要参数。TCG reset从 MROM开始，固件再进入下一级；KVM direct boot路径由架构 reset直接设 PC。比较两种 accelerator启动日志时要把这项协议差异列入环境。

machine-done还构建 SMBIOS并按 machine属性设置 ACPI。ACPI表通过 fw_cfg暴露，FDT仍负责 RISC-V常见启动。两个描述格式的生成晚于设备装配，说明发现数据是已实现平台的投影；不能先写一张理想表，再要求对象勉强匹配。

## qdev 的 create、configure、realize

`qdev_new()`只分配并初始化 QOM/qdev对象。machine随后设置属性、link和父总线；`qdev_realize()`或 sysbus/PCI helper才调用设备 class的 realize。realize可以检查后端、队列数量、地址能力和总线类型，并通过 `Error`失败。

通用 `device_set_realized()`在 realize前检查 hotplug与 `--only-migratable`，调用 hotplug pre-plug，再执行设备 realize。成功后设备 listener收到通知，canonical path与 clock path固定，VMState注册，child bus realize；hotplug设备还要在新 parent reset状态下完成一次 reset，最后调用 hotplug handler plug并发布 `realized=true`。

这段顺序解释了板载设备也要走 qdev。即使 UART永远由 machine创建，它仍需要 property校验、VMState注册、reset和错误回滚。绕开 realize直接调用寄存器 helper，会丢失框架提供的生命周期。

unrealize先发布 `realized=false`并使用内存屏障，让并发访问者知道设备正在拆除；随后 unrealize child bus、注销 VMState、调用设备 unrealize与 listener。对象 finalize发生得更晚，引用仍可能存在。设备实现不能把 unrealize和 C内存释放视为同一时刻。

realize失败路径反向撤销 child bus、VMState和 canonical path，并调用 unrealize清理设备已分配资源。machine大量使用 `error_fatal`，因为固定板载设备失败无法形成可用平台；通用设备仍应把可诊断 Error上送，而非在 realize中随意 `exit()`。

## UART 作为完整装配示例

`virt_machine_init()`调用 `serial_mm_init()`，传入 system memory、`0x10000000`、寄存器间距、irqchip输入、baudbase、串口后端与小端。helper创建 `TYPE_SERIAL_MM`，设置属性并 realize，之后连接 IRQ并把它的 MMIO region加入 system memory。

SerialMM instance内部通过 `object_initialize_child()`组合 `TYPE_SERIAL`。SerialMM负责 MMIO外壳、regshift与端序，SerialState负责 16550寄存器、FIFO、timer、IRQ和 chardev。组合让同一串口语义可用于 ISA、PCI或不同 MMIO包装。

FDT `create_fdt_uart()`再发布 compatible、reg、clock-frequency、interrupt-parent与 interrupts。`/chosen/stdout-path`或 alias把控制台指向该节点。QEMU对象、地址映射、IRQ连接和客户机描述在这里四线汇合。

若修改 UART地址，至少要同步 memmap映射和 FDT reg；修改 IRQ还要同步连接与 `interrupts`；修改 clock/baudbase也要检查客户机声明。只让 Linux打印字符的烟雾测试可能漏掉 IRQ或迁移，实验还应触发接收、FIFO和 reset。

这个例子还说明设备源码不按 machine目录组织。`hw/riscv/virt.c`只做布线，实际串口在 `hw/char/serial-mm.c`与 `serial.c`。阅读板级代码后沿类型名和 realize进入子系统，比在 `hw/riscv/`搜索全部实现可靠。

## sysbus、PCIe 与 virtio transport

SysBusDevice适合固定平台设备。它提供若干 MMIO region和 qemu_irq端点，machine决定映射地址与连接目标。sysbus本身没有客户机枚举协议，FDT/ACPI承担发现。UART、RTC、virtio-mmio transport与 system IOMMU都使用这一模式。

PCIe设备挂在可枚举 PCI bus，客户机从 ECAM读取配置空间、分配 BAR并启用 bus mastering。GPEX把 PCI bus和 CPU物理窗口连接起来，machine无需为每个 PCI设备写 FDT节点；host bridge节点与 ranges足以让固件/内核枚举。特殊 IOMMU节点仍需描述 requester映射。

virtio把 device和 transport分开。同一个 virtio-blk可以挂到 virtio-mmio，也可以由 virtio-blk-pci包装后挂 GPEX。device定义块请求与 feature，transport定义发现、queue配置、notify和 IRQ。`virt`预建八个 mmio transport，同时提供 PCIe，让实验可以比较两种路径。

QOM child与 bus parent可能不同。virtio device通常作为 transport bus的 child，transport又是 machine或 PCI设备的一部分；对象组合决定销毁顺序，bus决定 guest连接。不要把 `info qom-tree`的缩进直接画成硬件总线图。

platform bus为动态 sysbus设备预留一个大 MMIO窗口和连续 IRQ。machine创建 platform bus、连接每条 IRQ并映射它的容器 region。只有 MachineClass允许的动态 sysbus类型可加入，避免任意设备侵占板级地址。

## 热插与动态 FDT 的边界

`virt` MachineClass实现 HotplugHandler，当前 plug callback特别识别 virtio-iommu与 RISC-V IOMMU PCI设备，在自动 FDT中增加相应节点/`iommu-map`。PCIe普通设备通过总线枚举，不需要每个设备的 FDT节点。

动态修改 FDT只在 blob finalize和交给客户机之前自然成立。启动后 PCI hotplug依赖 PCI协议和固件/OS机制，QEMU不会重新把整个 DTB塞给已运行 Linux。源码中“可能在 finalize_fdt前发生的 hotplug”指 machine创建阶段时序，不能泛化为任意运行时 DT overlay。

用户 DTB进一步收紧边界。QEMU不拥有其结构，plug callback不能安全假定节点布局；文档要求用户提供完整树。若需要运行时可变 platform设备，machine还要有明确的 firmware通知协议，单纯 `object_property_add_child()`不够。

hot-unplug也需要设备和总线支持。板载 UART不可热拔，PCIe设备是否可拔由 PCI hotplug controller和 DeviceClass决定，RISC-V IOMMU PCI当前还显式 `hotpluggable=false`。看到 Machine有 hotplug handler不代表所有 child都能拔。

## 兼容性与迁移怎样落到 machine

迁移源目标需要相同客户机可见平台：CPU/hart拓扑、内存地址、irqchip、PCIe窗口、machine属性与设备集合。host对象路径、fd和指针可以不同，FDT描述和设备 VMState语义不能漂移。machine负责在目标启动时重建相同骨架，再加载状态。

通用 compat property用于让新版 QEMU以旧默认实现旧 machine语义。当前 RISC-V `virt`没有版本化 machine名称，用户应显式固定重要属性，管理层还要确保源目标使用兼容 QEMU版本。写成 `-machine virt`并不能自动冻结未来所有缺省。

FDT通常不作为每次运行后动态变化的设备状态迁移，它在启动时放进 guest RAM，RAM迁移会带走客户机实际看到的 blob。目标 QEMU仍要创建与之匹配的硬件。源端 FDT说 PLIC、目标对象却是 AIA，即使旧 blob随 RAM到达，设备语义也不兼容。

PCI BAR地址可能由客户机固件分配，配置空间和设备 VMState保存运行值；host bridge windows属于 machine布局。目标只需重建等价 AddressSpace，不复用源端 host虚拟地址。下一章会详细讨论设备 VMState与 reset。

兼容性审查还应覆盖负面场景：用户 DTB与 `-m/-smp`不匹配、目标缺某 machine属性、AIA模式不同、system IOMMU启用状态不同、high MMIO因 RAM变化而移动。尽早拒绝比客户机恢复后访问错误地址更安全。

:::: {.quick-quiz}
当前 RISC-V `virt`没有版本化 machine名称，是否表示它没有迁移 ABI？

::: {.quick-answer}
迁移 ABI仍由平台布局、设备 VMState和客户机可见默认值构成。缺少版本化别名只意味着不能依赖 `virt-X.Y`冻结行为，开发与部署更需要谨慎维护默认值并显式固定关键属性。
:::
::::

## 历史材料怎样解释当前设计

初始 `04331d0b`直接把 device tree、CLINT、PLIC、UART和 virtio-mmio放进 machine，说明“自动发现的虚拟平台”从第一版就是设计中心。历史事实支持这一点；不能从首版设备列表推断今天所有新增设备也必须板载。

GPEX提交 `6d56e396`选择通用 PCIe host并配套 DT节点。最终代码仍保留这个分层，支持“板级布线复用通用设备”的工程解释。若另一个 RISC-V machine需要不同 PCI host，它可以复用 PCI设备语义而改变 board地址。

`926a8b8e`修复 `iommu-map`表明平台契约包含发现数据的细节。一个长度 cell错误不会在 QEMU object realize时报错，只会让客户机把最后 requester ID留在 IOMMU映射之外。上游 review、生成 DTB检查和客户机测试缺一不可。

当前源码还在把共享 RISC-V FDT逻辑移入 helper。可维护收益是多 machine共用 binding编码；风险是平台特有条件被抽象掉。审查 refactor时应对比生成 DTB，而不只看编译和代码行数。

## 从命令行到第一条客户机指令

一条 `qemu-system-riscv64 -machine virt ...` 命令先经过选项解析与对象创建。machine 类型确定后，通用代码创建 `MachineState`，应用 class 默认值、`-machine` 子选项、`-smp`、`-m`、NUMA 与 accelerator 选择。此时还没有完成板级连线，属性错误可以在昂贵资源建立前报告。

board init 开始后，`virt_machine_init()`先处理 socket、hart 和 irqchip，因为后续设备需要中断接收端。RAM、ROM、flash 与固定 MMIO 随后进入 system memory；virtio-mmio 和 GPEX 提供命令行设备的承载点。自动 FDT 在前段建立可扩展骨架，PCI/IOMMU plug 回调可以写入动态关系。

用户通过 `-device`添加的设备可能在 machine init 前后由通用创建流程 realize，取决于所属总线何时可用。board 必须在命令行 PCI 设备 realize 之前创建 GPEX root bus，也必须为动态 sysbus 预建 platform bus。这里的先后关系由 qdev 创建框架与 board 共同形成，不能只按 `virt_machine_init()`源码行号理解所有对象时序。

machine-done 是收口点。自动 FDT、kernel/initrd、firmware、reset vector、SMBIOS 与 ACPI 在这一步使用已经确定的硬件事实。随后 CPU reset 把 PC、hart ID 和 FDT 地址建立为启动状态，vCPU才可能执行第一条客户机指令。

这条时间线给出一个诊断规则：property校验失败属于配置收敛；找不到bus多半属于装配顺序；MemoryRegion重叠属于地址图；客户机不枚举而对象存在则查发现数据；入口错误或FDT地址错误查machine-done。将所有启动失败归到“machine初始化”会失去可操作边界。

## Machine 属性之间存在组合约束

`aia`不只选择一个中断控制器类型，它会改变外部中断节点、IMSIC区域、MSI parent和每个hart的interrupt file。`aia-guests`又影响可创建的guest interrupt file数量。属性值要在CPU拓扑已知后参与地址与phandle生成。

`aclint`选择影响timer和software interrupt设备。TCG可以使用machine模拟的路径，当前KVM组合有更窄限制；不支持的搭配应在启动时拒绝。拒绝是平台能力声明，自动回退到另一套irqchip会让客户机看到与命令行不同的硬件。

`iommu-sys`决定是否在固定MMIO位置创建system RISC-V IOMMU。PCI IOMMU设备又可通过命令行加入；plug逻辑避免同一默认PCI DMA路径由两个system IOMMU同时接管。这里需要区分“QEMU允许对象同时存在”与“平台为同一bus定义唯一默认IOMMU”两种约束。

`acpi`控制是否构建ACPI表，用户`-dtb`控制FDT所有权，`-bios`/pflash/kernel控制启动链。单个选项语法合法，组合仍可能缺少firmware能够消费的描述或入口。测试表要覆盖组合，而非逐属性孤立验证。

MachineClass中的属性setter适合做局部范围校验，涉及hart数、accelerator、另一属性或已创建对象的规则要在board init前集中校验。太晚失败会留下半装配对象，太早又缺少收敛后的上下文。源码评审应问清每条约束需要哪些输入。

## 中断图从 hart 向外构造

CPU的本地software/timer输入与外部interrupt输入来源不同。CLINT/ACLINT连接本地输入，PLIC把多个设备线汇聚到hart context；AIA模式下APLIC接收wired interrupt，IMSIC以message形式保存pending并向相应hart file投递。FDT要发布与运行时同构的图。

board先为每个socket获得hart范围，再创建对应本地控制器和外部控制器。设备IRQ号是irqchip source index，CPU看到的是privilege context或IMSIC file。把UART的`UART0_IRQ`直接写成RISC-V `mcause`值会混淆两端编号。

GPEX输出四条INTx，PCI core按pin和桥拓扑做swizzle，board再把四条host输出接到连续platform IRQ。MSI路径绕过INTx聚合，目标由IMSIC/AIA和PCI capability共同决定。FDT的`interrupt-map`、`msi-parent`与运行时连接分别描述这两条路径。

virtio-mmio每个slot有一条固定wired IRQ。slot地址与IRQ都按index递增，FDT helper通常逆序创建节点以得到期望输出顺序；节点在blob中的排列不构成硬件优先级。客户机应按`reg`和`interrupts`识别。

审查新增板载设备时，可以从qemu_irq端点反向走到CPU：设备何时assert/deassert，连接到哪个irqchip source，控制器如何选择hart/context，FDT phandle是否指向同一控制器。四步任一断裂都可能表现为“寄存器可读但驱动卡住”。

## FDT cell 编码需要逐字段核算

root的`#address-cells`与`#size-cells`决定`reg`和`ranges`中每个数字占多少32位cell。64位地址通常拆成高低cell；PCI child address还带space code与BDF相关字段。代码写入的是按binding排列的big-endian cell，不是把宿主C结构直接复制进blob。

`reg`的每一项是address与size，`ranges`则由child address、parent address和size组成。`interrupts-extended`把phandle与specifier交替排列，specifier cell数由目标interrupt-controller声明。`iommu-map`又是RID base、IOMMU phandle、specifier base、length。名称相似，tuple结构完全不同。

phandle分配只要求非零且引用一致。重构helper后数值改变通常不会影响客户机；漏掉引用目标、specifier宽度不符或length差一才是ABI错误。因此DTB回归测试宜把树规范化后比较属性关系，避免把phandle数字变化当失败。

节点`compatible`决定驱动匹配，`reg`决定地址，`status`决定可用性。节点名称里的`@address`用于可读性和unit-address规则，不能代替`reg`。实验若只正则匹配节点名，可能放过实际地址错误。

`dtc`能检查部分语法和binding风格，无法知道QEMU的MemoryRegion是否位于同一地址。最有价值的断言来自跨视图：DTB `reg`对`info mtree`，`interrupts`对qdev连接，PCI `ranges`对GPEX alias，CPU节点数对QOM hart对象。

## 多 socket、NUMA 与内存节点

`-smp`把总CPU数展开成socket、core、thread等维度，RISC-V `virt`的hart array按socket建立。hart ID在当前实现中要求每个socket范围连续，base与count成为CPU节点、irqchip context和boot hart选择的共同输入。

NUMA配置把CPU与内存归属映射到nodes。machine既要创建真实RAM backend映射，也要为每个socket/node生成对应memory描述。节点距离、可用范围和hart关联由通用NUMA状态与RISC-V FDT helper组合，不能只改`/memory`总size。

boot hart通常是可用hart集合中的一个，其他hart由firmware或kernel按启动协议唤醒。FDT `cpu-map`与`reg`告诉OS逻辑拓扑；QEMU CPU对象的创建顺序不应成为OS编号的隐藏来源。稀疏hart ID若未来支持，还会影响数组索引与architectural ID的分离。

socket增多也会复制PLIC/APLIC/IMSIC资源。设备IRQ需要选择落在哪个irqchip实例，PCI MSI地址范围要覆盖目标interrupt files。边界条件包括最大socket、最大hart、AIA guest file数量和MMIO窗口容量；仅启动两颗CPU无法覆盖。

验证多socket平台时至少保存三份集合：QOM中的CPU对象与hartid、FDT中的CPU/NUMA节点、guest `/proc/cpuinfo`与NUMA视图。数量相同仍可能映射关系错误，应按hart ID逐项关联。

## PCIe 高窗口是派生 ABI

低PCIe MMIO窗口位于固定的`0x40000000`区间，容量受DRAM起点等低地址布局限制。riscv64的大BAR可使用RAM之上的高窗口。machine根据RAM末端和16 GiB对齐要求计算基址，再把结果写入GPEX属性、MemoryRegion alias和FDT ranges。

假设RAM扩展到跨过原高窗口起点，保持旧基址会重叠，简单把窗口紧贴RAM又可能破坏对齐与PCI地址映射。当前策略用固定窗口大小对齐，牺牲一部分地址空洞，换取清晰的范围和稳定计算规则。这是由源码算法可见的工程取舍。

高窗口的CPU物理地址与PCI bus address不一定相同，alias offset连接二者。客户机写BAR的是PCI地址，CPU访问经过host bridge ranges；设备DMA又从PCI requester AddressSpace向RAM。分析一个大BAR设备时要把三种数值放三列。

迁移目标必须以相同RAM大小和machine算法重建窗口。若管理层改变`-m`，客户机保存的BAR与FDT ranges可能指向目标不存在的alias。拒绝配置不一致比在load后修补BAR更可靠。

回归实验可用两个RAM大小和一个64位大BAR设备比较：检查FDT高range、mtree alias、PCI BAR分配和guest资源树。预期窗口移动是可解释的派生结果；任何重叠或范围端点差一才是缺陷。

## Firmware、kernel 与 FDT 的装载矩阵

TCG加默认firmware时，reset vector先把控制交给M-mode firmware，firmware解析或转交FDT，再进入S-mode payload。`-bios none`配合直接kernel时，machine需要提供相应入口和参数。pflash启动又让ROM内容与变量区由flash设备承载。

当前KVM路径要求direct kernel并拒绝M-mode firmware。它仍需要把kernel、initrd和FDT放到guest RAM的非重叠区域，并为每个vCPU建立启动寄存器。源码事实限定当前实现，不能用来判断RISC-V硬件虚拟化规范是否允许其他固件设计。

kernel ELF与raw image可能有不同加载信息，initrd要放在Linux可发现且不覆盖kernel/FDT的位置。`riscv_compute_fdt_addr()`使用实际内存与镜像范围计算，说明FDT地址属于装载结果，不能写入长期固定表。

用户DTB引入另一维度：machine仍计算装载位置，却不重建内容。若DTB声明内存超出RAM，firmware能够读到blob也可能在后续内存探测崩溃；若chosen bootargs或initrd范围错误，设备拓扑正确仍无法启动。

建议把启动测试分为TCG+默认firmware、TCG+`-bios none`直接kernel、pflash，以及环境支持时的KVM direct kernel。每格记录初始PC、下一跳、FDT物理地址、initrd范围和第一条可见控制台输出。这样能把加载问题与UART发现问题分离。

## 自动 FDT 与 ACPI 要共享硬件事实

自动FDT在machine-done前由board helper生成，ACPI构建也读取machine和设备状态并通过fw_cfg提供。两者面向不同firmware接口，却描述同一hart、memory、GPEX、interrupt与platform设备。

一项新设备先实现QOM/qdev与MemoryRegion，再决定FDT、ACPI或两者的发现方式。若两个表都支持，地址、IRQ、IOMMU关系和可用性需要来自同一配置源。分别复制常量会在后续属性变化时漂移。

客户机实际选择哪套描述取决于firmware与OS启动路径。看到QEMU生成ACPI表不表示当前guest已经消费；看到FDT节点也不表示ACPI模式可以忽略冲突。实验应记录固件日志或OS枚举来源。

ACPI表可以通过fw_cfg在较晚阶段交给firmware，FDT通常作为一个blob装入RAM。更新机制和校验工具不同，兼容目标一致：同一命令行产生确定、可解释的平台。书中的RISC-V源码实例以FDT为主，ACPI作为并行发现路径标出边界。

## Realize 失败需要保持图一致

设备realize可能因缺后端、属性非法、bus资源不足、MemoryRegion重叠、MSI初始化失败或`--only-migratable`而退出。失败前若已经创建child、注册VMState、安装listener或连接fd，必须按逆序撤销。

board设备常用`error_fatal`结束进程，不等于设备实现可以省略cleanup。相同设备可能由测试或另一machine动态创建，realize失败后对象仍会进入unref/finalize。资源泄漏在一次性进程中不明显，在qtest重复创建里会暴露。

地址映射通常由board在设备realize成功后执行。若先把region加入system memory，再让realize失败，mtree会留下没有有效回调状态的区域。GPEX流程先设置属性、realize、取得region并建立alias，体现了这条顺序。

IRQ连接也要在端点初始化后完成。`qdev_get_gpio_in()`取得的是目标输入，`sysbus_connect_irq()`绑定输出；连接对象本身没有客户机可见状态，目标reset时却可能采样电平。设备realize应把输出初态确定，防止连线后出现伪中断。

错误注入测试可以让chardev缺失、PCI bus占满或属性越界，观察QEMU错误是否包含设备path，进程是否干净退出。不要为了制造失败去覆盖共享镜像；这类实验只需要临时对象配置。

## 用差分而非快照维护平台契约

完整DTB与mtree快照容易受节点顺序、phandle、对象路径细节影响。稳定测试应提取语义字段：设备数量、每个reg范围、IRQ映射、PCI ranges、CPU hart ID与IOMMU RID覆盖。内部重排只要保持关系，就不应制造大面积噪声。

对每个machine属性做单变量差分更容易解释。例如只切换AIA时，预期PLIC节点消失、APLIC/IMSIC出现，CPU interrupt引用和MSI parent改变；UART地址与DRAM基址应保持。意外变化提示helper共享状态或默认值泄漏。

源码事实比较也要固定tag。用`git show v11.1.0-rc0:hw/riscv/virt.c`取得基线，再看目标commit，避免工作树中未提交补丁混入。邮件系列解释为什么改，最终tree确认改成什么。

迁移兼容测试需要源目标两份二进制，而DTB差分只能覆盖启动描述。还应在guest运行后保存PCI配置、irqchip状态和设备VMState，执行迁移并核验。machine契约横跨生成数据与运行状态。

## 平台演进的证据等级

固定标签源码可以直接证明类型、属性、地址、调用顺序和显式限制。Git提交能证明某个变化何时进入主线以及提交者写下的问题。邮件review可以记录被拒方案、性能数据与维护者关切，但早期patch函数名和字段可能已在后续版本改变。

从代码分层推断动机时，要给出反证条件。例如“GPEX复用是为了让machine只负责布线”得到当前文件边界与初始提交支持；若未来`virt.c`开始承载大量PCI协议状态，这个判断就要重审。可推翻的推断比泛化口号更适合技术书。

开放问题也要具体。当前没有版本化RISC-V `virt`别名，是可搜索的源码事实；未来是否增加、何时冻结哪些默认值并无固定答案。书中应把部署建议写成“显式固定关键属性并验证源目标”，不代替上游政策。

审查邮件时优先找同一系列的cover letter、最终版本和落地commit，记录Message-ID与commit hash。只引用搜索摘要会丢掉上下文；只读Git log又看不到review中否决的接口。两种证据要在固定源码上会合。

## 把 UART 装配写成资源账本

UART的创建输入包括type、chardev、baudbase、regshift和endianness。realize输出一个MMIO region与一条IRQ，machine把region放到`0x10000000`，把IRQ接到当前PLIC/APLIC source。FDT再发布compatible、reg、clock和interrupt引用。

资源账本的每一行写“生产者、消费者、生命周期”。SerialMM生产region，system memory持有映射引用；SerialState生产IRQ电平，irqchip消费；machine生产FDT属性，firmware/OS消费。unrealize或进程退出时按引用关系撤销，reset只改变运行状态。

这张账本能暴露常见遗漏：region已经init却未map，IRQ已连接但FDT指向另一控制器，chardev handler已注册却在unrealize后残留，UART对象存在但chosen没有控制台路径。每个现象对应一条边。

修改SerialState内部FIFO不应改变machine账本；修改regshift需要同步MMIO大小与发现描述；更换irqchip只改变IRQ消费端和FDT引用。边界稳定后，重构影响范围更容易判断。

## 八个 virtio-mmio slot 的平台含义

`virt`预创建固定数量的virtio-mmio transport，地址和IRQ按slot编号分配。transport的device ID可在未挂device时为零，因此FDT中的八个节点是一组插槽描述，不是八个已经工作的块或网络设备。

命令行加入virtio-mmio device后，qdev把device挂在某个transport bus，transport寄存器开始报告类型与feature。machine无需为每个device动态修改compatible；客户机通过同一节点和device ID发现具体语义。

固定slot数量给FDT和IRQ布局带来上界，也让早期firmware无需枚举复杂总线。代价是扩展数量需要平台ABI决策，空slot仍占地址与IRQ范围。PCIe提供可扩展枚举路径，两者并行满足不同启动与设备规模。

实验区分transport节点、挂接device和backend。`info qtree`能看到bus关系，FDT只见transport，device ID寄存器才说明当前设备。把三者合并会把空slot误报为设备缺backend。

## GPEX 初始化的依赖清单

machine先创建GPEX对象，写入ECAM、PIO、低/高MMIO属性并realize。realize创建root PCI bus和内部address spaces。board随后取得regions，建立CPU system-memory aliases，并把INTx输出接到平台irqchip。

命令行PCI function需要root bus已注册；BAR映射需要PCI memory region存在；guest枚举需要ECAM alias与FDT host bridge节点；中断需要INTx连接或MSI parent。四项分别验证，能定位“lspci看得到但BAR不能访问”之类半通状态。

host bridge节点的`bus-range`、`reg`、`ranges`、`interrupt-map`和可能的`msi-parent`来自最终配置。普通function不需要FDT child，PCI配置空间承担枚举。IOMMU是例外，因为RID到IOMMU的拓扑关系需要platform描述。

GPEX是通用设备，RISC-V machine只决定地址与IRQ。若host bridge修复位于`hw/pci-host/`，应评估所有使用者；若只改`virt.c`的range，则重点回归RISC-V DTB和mtree。文件边界给出测试范围线索。

## system IOMMU 加入 FDT 的时机

自动FDT骨架在早期创建PCI节点，system IOMMU的完整节点与`iommu-map`在finalize阶段按machine属性补入。PCI IOMMU device的plug callback也可能在finalize前修改映射关系，因此PCI节点不能等到最后才首次存在。

IOMMU节点需要compatible、reg、interrupt、capability相关属性与phandle，PCI host需要引用它。创建顺序可以通过先分配phandle再填属性解决，关键是最终图无悬空引用。

用户DTB关闭自动finalize后，这些动态补丁不再可靠。用户既要描述IOMMU自身，也要让PCI host的RID map匹配命令行BDF和选择的wrapper。QEMU运行时hook正确而DTB缺map，guest driver可能完全不启用隔离。

`926a8b8e`说明length端点是安全边界：漏掉最后RID会让一个function不受预期映射。回归应检查首RID、末RID和区间外值，不能只看属性存在。

## 启动故障的分层取证

QEMU在第一条guest指令前退出时，先保存完整错误、machine参数与`-machine help`能力。property或组合校验通常直接报告；不要先修改guest镜像。

CPU运行却无控制台时，确认初始PC和firmware装载，再查FDT地址、chosen/stdout、UART reg与IRQ。能看到早期firmware字符但kernel静默，往往说明下一阶段入口、DTB或driver枚举问题。

kernel启动后设备缺失，比较guest树、反编译DTB与QEMU qtree。对象缺失查命令行/bus，FDT缺失查finalize或用户DTB，地址不通查mtree，IRQ卡住查控制器连接。一次只改变一层。

PCI设备枚举但I/O超时，查BAR enable、bus master、DMA AddressSpace/IOMMU和MSI。它已越过machine发现阶段，继续修改FDT compatible通常没有帮助。

证据包包含QEMU版本hash、命令行、accelerator、DTB、qtree、mtree、PCI视图、guest日志。平台问题可在不共享敏感镜像的情况下复现大半。

## qtest 适合验证哪些 machine 不变量

qtest可以在不运行完整RISC-V软件栈时读写MMIO、检查IRQ与执行system reset，适合UART、RTC、irqchip和地址图测试。它能快速覆盖边界寄存器与失败路径。

DTB生成测试可直接dump并解析语义字段，覆盖RAM大小、SMP、AIA、IOMMU和PCI窗口组合。qtest再验证同地址存在MemoryRegion，形成描述与实现的双断言。

qtest不能替代firmware/OS对binding的真实消费，也不能证明KVM内核设备状态。自动测试应分层：纯machine/qdev测试、TCG启动测试、环境允许时的KVM/guest驱动测试。

测试名称应写出配置差异与预期字段，避免依赖对象创建顺序的脆弱编号。动态QOM path可通过显式device ID稳定，phandle则比较引用关系。

## 地址与对象的所有权不要混合

MemoryRegion可由设备对象创建，由machine或bus映射，AddressSpace再引用整棵拓扑。创建者负责init/destroy，映射者负责add/del subregion；两项生命周期不同。

alias不拥有被指向region的数据，只建立另一地址视图。GPEX低/高窗口和system memory使用alias后，销毁顺序要先移除alias，再释放目标。把alias当第二份内存会导致重复迁移或释放。

RAMBlock承载客户机数据并进入迁移，MMIO region保存回调而不携带数据页，ROM内容可由启动路径重建。FDT中的`reg`不说明迁移类别，只说明客户机地址。

QOM parent提供对象引用与销毁顺序，qdev bus parent提供连接。一个对象可能由machine拥有却挂在PCI bus，也可能由transport组合并在bus上暴露child。设计文档应分别画边。

## Machine 层的安全边界

命令行和管理接口可提供RAM大小、CPU数量、DTB、firmware与设备属性。machine在分配和映射前检查溢出、重叠与最大值，防止恶意配置造成host地址计算错误或资源耗尽。

用户DTB是客户机输入的一部分，QEMU装载时要检查blob有效和内存范围，却无法验证它与所有对象语义一致。信任边界是“用户声明承担描述一致性”，并非“任意blob可以安全指导QEMU创建硬件”。

设备MMIO地址与IRQ由编译时平台表和受校验派生算法产生，普通guest不能重编排。PCI BAR可由guest配置，但PCI core限制到host bridge window；DMA再受bus master与IOMMU约束。

平台默认值也影响安全。IOMMU reset到OFF或BARE、firmware来源、debug设备是否启用都应在部署命令中显式记录。书中的开发配置不能直接视为生产隔离策略。

## 评审一份 `virt.c` 补丁

第一遍只看客户机可见变化：地址、IRQ、FDT/ACPI、CPU拓扑、默认属性和启动入口。把每项标兼容、显式opt-in或潜在破坏。内部函数移动若生成结果相同，可归为重构候选。

第二遍走对象生命周期：child ownership、property设置、realize失败、MemoryRegion映射、IRQ连接、VMState owner、reset与finalize。machine创建的固定设备也要具备完整设备实现。

第三遍跑配置矩阵：TCG/KVM可用组合、firmware/direct kernel、PLIC/AIA、自动/用户DTB、32/64位目标的适用范围、单/多socket、IOMMU和PCI设备。与补丁无关的格子可按影响分析裁剪，但要写理由。

第四遍看上游历史。同一地址或helper是否有兼容背景，邮件review是否提出替代方案，最终commit是否与RFC一致。提交说明引用的是最终行为，作者动机推断另列。

合入标准应包含生成描述、运行地址图、guest启动和必要迁移/reset测试。代码更短不是独立正确性证据，完整图关系才是。

## 可以替换的实现与不可轻改的契约

UART内部FIFO算法、FDT helper组织、MemoryRegion创建helper和对象命名可以重构，只要客户机可见行为与迁移协议保持。GPEX内部实现也可演进，host bridge配置语义与窗口关系需兼容。

DRAM基址、固定MMIO、IRQ编号、compatible、PCI ranges、boot参数和默认irqchip更接近platform ABI。改变它们可能要求新machine版本、显式property或兼容层。当前未版本化类型提高了评审门槛。

性能优化常位于可替换层，例如减少FDT重复、延迟创建cache或改善alias查找；若优化改变设备创建时机、hotplug回调或错误顺序，仍需审查生命周期。

判断边界的办法是问：正在运行的旧guest、保存的迁移流或外部管理配置能否观察变化。能观察就按契约处理；只能影响host内部且没有时序副作用，才更接近纯实现细节。

## 保存一份可复查的平台档案

每次升级QEMU标签时，先用最小riscv64命令生成平台档案。档案包含`-machine help`中`virt`属性、`-device help`的可用设备、自动DTB、`info qom-tree`、`info qtree`、`info mtree -f`和`info pci`。所有输出旁边记录二进制commit与完整命令行。

再选一份代表性配置：多hart、512 MiB RAM、UART、一个virtio-mmio设备、一个virtio-pci设备、AIA或PLIC、可用时的RISC-V IOMMU。它用于观察图关系，不能替代单变量测试。

版本差分先比较语义：Machine类型是否新增版本名，默认属性是否变化，固定reg/IRQ是否移动，FDT compatible/ranges/iommu-map是否改变，QOM对象只是重命名还是客户机行为变化。每项回到Git log和邮件找依据。

档案还应保留启动链：firmware/kernel入口、FDT地址、第一条控制台日志与guest枚举摘要。静态图一致却启动失败时，这部分能定位machine-done变化。

可复查档案避免依赖作者当时的记忆。后续读者可以在新tag重跑，指出哪条源码事实已变化、哪项工程推断仍成立。它也是本书版本与QEMU参考版本绑定的可执行说明。

平台档案还要保存负面能力：当前只有未版本化`virt`类型，KVM启动路径拒绝M-mode firmware，用户DTB不会由QEMU补全，特定IOMMU不可热插或迁移。缺失能力与已有地址同样影响部署。

记录负面结果时附触发命令和错误文本，不用“似乎不支持”。若帮助输出没有选项、源码没有TypeInfo或DeviceClass明确设限制，分别标静态证据；若只在本机因缺依赖失败，标环境限制。

新版本复查先确认这些限制是否解除，再判断正文需要删改。功能增加不会自动改变旧配置，machine默认与compat处理仍要从新tree和迁移测试确认。

档案中的每条路径使用相对源码符号和官方GitLab链接，避免绑定本机目录。运行产物可写生成日期，源码结论始终绑定tag与commit；两种时间维度分开后，读者能判断是构建变化还是上游代码变化。

## 实验一：从生成的 FDT 反查实现

::: {.hands-on}
配套英文实验手册：[`inspect-virt-fdt`](../experiments/part-04-machine-and-device-models/chapter-16-riscv-virt-machine/inspect-virt-fdt/README.md)。

用固定 QEMU二进制执行 `-machine virt,dumpdtb=... -cpu rv64 -m 512M -display none`，再用 `dtc`反编译。列出 CPU、memory、CLINT/ACLINT、PLIC/AIA、UART、八个 virtio-mmio、PCIe与 chosen节点；每个 `reg`和 IRQ回到 `virt_memmap`与 `create_fdt_*()`定位。

改变一个属性再重复：例如 RAM大小、`aia=aplic-imsic`或 `iommu-sys=on`。比较 DT差异并同时查看 `info mtree -f`。预期 FDT与实际映射一致，高 PCIe窗口在 RV64下可能随 RAM变化。实验只证明当前配置，不把 phandle具体数值当 ABI。
:::

## 实验二：跟踪 UART 从创建到客户机可见

::: {.hands-on}
配套英文实验手册：[`trace-device-realization`](../experiments/part-04-machine-and-device-models/chapter-16-riscv-virt-machine/trace-device-realization/README.md)。

从 `virt_machine_init()`的 `serial_mm_init()`开始，追到 `qdev_new(TYPE_SERIAL_MM)`、属性设置、SerialMM realize、内部 Serial child、MMIO映射与 IRQ连接。启动暂停的 `virt`，保存 `info qom-tree`、`info qtree`与 `info mtree -f`，并把 FDT UART节点放在同一张表。

表格分别填写 QOM owner、父总线、canonical path、MemoryRegion范围、irqchip输入与 FDT属性。预期四张图的路径不同，但都指向同一 16550A语义。若只找到 QOM对象而没有地址或 FDT，实验不得标完成。
:::

## 实验三：验证用户 DTB 的责任边界

::: {.hands-on}
本实验复用 [`inspect-virt-fdt`](../experiments/part-04-machine-and-device-models/chapter-16-riscv-virt-machine/inspect-virt-fdt/README.md) 生成基线，设备路径复核使用 [`trace-device-realization`](../experiments/part-04-machine-and-device-models/chapter-16-riscv-virt-machine/trace-device-realization/README.md)；统一入口见[第 16章英文实验索引](../experiments/part-04-machine-and-device-models/chapter-16-riscv-virt-machine/README.md)。

复制自动 DTB，故意只改变一项：把 memory size改小、移除 UART节点或给 PCI `ranges`设置错误基址，再通过 `-dtb`启动最小客户机。QEMU对象和 mtree仍按 machine命令行创建，客户机行为按用户 DTB发现。记录第一个失败点并立即恢复正确 DTB，不在重要镜像上做破坏性实验。

预期结果是 QEMU不会自动修补任意用户树。该实验说明 FDT与硬件对象必须由使用者保持一致；失败现象只支持所改字段，不要用一次启动失败概括所有用户 DTB组合。
:::

## 代码与上游审查清单

新增板载设备时，先确定它属于 reusable device还是 machine布线。寄存器、reset和 VMState进入设备目录；基址、IRQ、phandle、默认启用与固件描述进入 `virt.c`。若实现必须读取 `RISCVVirtState`私有字段才能响应普通寄存器，边界可能放错。

然后检查四张图：QOM owner和 finalize，qdev parent bus与 hotplug，MemoryRegion映射与重叠，FDT/ACPI节点与 binding。再覆盖启动路径：TCG firmware、KVM direct kernel、pflash与用户 DTB。只测一种 Linux直接启动不足以证明 platform contract完整。

修改默认值时确认当前 machine缺少版本化别名，评估旧客户机和迁移影响。必要时增加显式属性、compat机制或拒绝不兼容组合。提交说明要区分客户机 ABI变化与内部重构。

引用历史时把证据等级写清。提交说明可以直接支持“该功能何时合入”，最终源码支持当前调用链；从文件分层得到的设计动机属于作者推断，应给出可推翻条件。未合入邮件不能改写成当前 machine能力。

## 小结

RISC-V `virt`通过 MachineClass和 `RISCVVirtState`收敛 CPU、内存与平台属性，再在 `virt_machine_init()`装配 hart、irqchip、RAM/ROM、virtio-mmio、GPEX、UART、RTC、flash和 IOMMU。machine-done阶段完成 FDT、firmware、kernel、reset vector与 ACPI，使客户机发现信息与实际对象对齐。

QOM组合、qdev总线、MemoryRegion和 FDT各自表达所有权、连接、地址与客户机视图。它们不会互相自动生成，machine就是四者的汇合点。初始 `virt`、GPEX接入和 `iommu-map`修复说明平台契约在持续演进，也说明“虚拟板”依然需要长期 ABI纪律。

当前固定源码只提供未版本化的 `virt` Machine类型。迁移与升级仍要依靠稳定布局、显式属性和设备 VMState，不能假定旧 machine别名自动兜底。下一章沿 UART、RTC、PLIC/AIA等设备进入 create、realize、reset、异步 completion和 VMState，观察单个设备怎样维持同一份客户机可见状态机。
