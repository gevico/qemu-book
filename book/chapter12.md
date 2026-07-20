# 当翻译不再划算：TCG 的边界与 KVM 的机会

在一台 x86 笔记本上启动 RISC-V `virt` machine，`-accel tcg` 可以把客户机带到 shell；把同一个镜像移到支持 H 扩展的 RISC-V 服务器，改成 `-accel kvm`，客户机依然看到 RISC-V hart、PLIC 或 AIA、UART、virtio 磁盘和同一片 RAM。命令行只改了一个加速器，CPU 指令的去向却完全不同。TCG 解码客户机指令，生成中间表示，再把它翻译成宿主代码；KVM 让物理 RISC-V hart 在硬件提供的客户机特权态中直接执行，直到出现需要内核或 QEMU 处理的事件。

这个切换容易引出一句过早的判断：有了硬件虚拟化，软件翻译便完成了历史使命。工程现场给出的答案更克制。两条路径服务于不同约束。TCG 能在不同 ISA 之间运行，能让开发者控制翻译、异常和时间推进，还能在新硬件到来前成为体系结构的可执行参照；KVM 用同 ISA、宿主内核和硬件能力换取接近原生的执行路径。理解 KVM 的起点，应当先找出 TCG 无法同时满足的约束，再观察硬件、内核与 QEMU 怎样重新分工。

本篇的当前源码基线固定为 QEMU [`v11.1.0-rc0`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0)，RISC-V 特权语义以官方 [Hypervisor 扩展规范](https://docs.riscv.org/reference/isa/v20260120/priv/hypervisor.html)为准。历史材料只在解释一个现存设计选择时出现；每个结论最终都要回到当前代码和可运行实验。

## TCG 保留下来的价值

TCG 解决的第一项约束是主客 ISA 可以不同。开发者不必先拥有 RISC-V 服务器，就能在 x86 或 Arm 主机上启动 RISC-V 固件、内核和设备模型。新扩展进入 QEMU 时，翻译器还能明确写出指令语义、异常条件和特权检查。硬件虚拟化要求宿主能直接执行客户机 ISA；即使同为 RISC-V，宿主 CPU、内核 KVM 与 QEMU 也要共同支持客户机要求的扩展和运行模式。

第二项约束是控制。TCG 的 translation block、helper、软件 TLB 与 `icount` 等机制，使执行过程可以插桩、单步、记录重放或在缺少真实硬件时观察边界条件。KVM 的热路径位于内核和硬件中，QEMU 只在退出点重新取得控制。想统计每条客户机指令、改变某条特权指令的语义，或复现与宿主调度无关的指令时间线，TCG 往往提供更合适的观察面。

第三项约束是可移植的设备平台。QEMU 的 `virt` machine、地址空间、固件装载和设备模型不会随着 CPU 执行引擎一起消失。TCG 让这些组件在没有 KVM 的机器上可用，也为 KVM 路径提供对照。一次 KVM bring-up 若能启动，却与 TCG 下的客户机可见状态不同，问题可能位于 CPU 寄存器同步、内核 ABI 或 machine 接线；对照路径能把搜索范围缩小。

TCG 自己也经历过从宿主编译器辅助生成代码到独立代码生成器的演进。现有一手材料只能确认它源于一个通用 C 编译器后端，并受到 QOP code generator 的影响，不能据此把它等同于 TinyCC。进入 QEMU 后，它逐步形成内部 IR、优化和后端接口。这里值得保留的判断是：IR 把“目标 ISA 的语义”与“宿主 ISA 的编码”隔开，让多目标、多宿主的组合不必两两实现；优化保持收敛，则是因为 QEMU 还要维护精确异常、内存模型、可中断性和大量后端。第二篇已经展开这条演进，本章只关心它留下的性能边界。

:::: {.quick-quiz}
一台支持 RISC-V H 扩展的宿主，是否足以运行任意 RISC-V 客户机 CPU model？

::: {.quick-answer}
不够。H 扩展提供客户机特权态和二阶段地址转换；客户机要求的 ISA 扩展、内核 KVM 能力、QEMU CPU 属性、irqchip 与设备配置仍须逐项兼容。编译时头文件出现某个扩展，也不能证明当前宿主实现了它。
:::
::::

## 同 ISA 性能边界从哪里出现

翻译执行的固定工作包括取指、解码、生成 IR、优化、生成宿主代码，以及维护软件 TLB、异常恢复和 translation block 缓存。缓存能让热点代码摊薄翻译成本，却无法消除全部边界检查。客户机修改页表、切换地址空间、执行特权指令或触发设备访问时，翻译器还要保持体系结构精确性。对于短命进程、频繁自修改代码和大工作集，缓存命中也不稳定。

同 ISA 场景给了工程师另一条路：让真实处理器完成普通指令、流水线、缓存和大部分地址转换，仅在越过隔离边界时退出。这样获得的性能并非“去掉 QEMU”。QEMU 仍然创建 machine、装载固件和内核、配置内存、实现用户态设备、参与中断与迁移。改变的是高频 CPU 循环的执行者。

性能边界还取决于 workload。一个长时间做整数计算、很少访问设备的 vCPU，可以在一次 `KVM_RUN` 中执行很久；一个逐字节访问模拟 UART 的客户机，会频繁从硬件回到内核，再回到 QEMU。前者接近硬件执行的理想形态，后者的成本受退出次数支配。后续两章会把这一点落实到 `struct kvm_run`、MMIO exit、virtio、irqfd 与 vhost。

## 2006 年的接口选择留下了什么

2006 年 10 月，Avi Kivity 在 LKML 发布最初的 [KVM patch series](https://lkml.iu.edu/hypermail/linux/kernel/0610.2/1369.html)。邮件提出一个字符设备 `/dev/kvm`，由用户态创建 VM 和 vCPU；每台 VM 是宿主进程，每个 vCPU 是线程，Linux 现有的调度、`nice`、`top`、信号与内存管理都可继续使用。客户机 I/O 被截获后交给用户态，一个经过修改的 QEMU 提供 BIOS 和设备模拟。这个现场解释了今天最重要的一条分界：Linux 管理可运行实体和硬件隔离，QEMU 管理客户机平台与设备语义。

原始邮件还诚实记录了性能缺口。早期 MMU 实现会在地址空间切换时丢弃 shadow page table，作者计划缓存影子映射，并等待硬件提供 nested page table。Windows 镜像当时已经可以运行；安装失败涉及虚拟 APIC，64 位问题也被指向 QEMU 设备模型。因此，KVM 的诞生不能归结为“Xen 不能运行 Windows”。当年的 Xen 已从半虚拟化继续发展到借助 VT-x/AMD-V 的全虚拟化，KVM 选择的是另一种工程组织：把虚拟机纳入 Linux 进程、线程和文件描述符体系，并复用 QEMU 的用户态 VMM。

这套设计也受到社区 review 的塑形。最初的 Intel VT 代码中，一部分定义来自 Xen；Steven Rostedt 在 review 中要求把架构相关内容与通用层拆开，为后续端口预留空间，Avi Kivity [回应并接受了方向](https://lkml.iu.edu/hypermail/linux/kernel/0610.2/2323.html)。Yaniv Kamay 与 Avi 在早期数据结构 patch 中明确区分 GVA、GPA、HVA、HPA 以及 VM、vCPU、MMU、memory slot。今天通用 `accel/kvm/` 与 `target/riscv/kvm/` 的分层远比当时完整，但问题轮廓已经出现：跨架构公共生命周期应当稳定，地址和寄存器的所有者必须命名清楚。

## Type-1 与 Type-2 为什么解释不了这条边界

有些资料把 KVM 称为 Type-2 hypervisor，因为 QEMU 是宿主 Linux 上的用户进程；另一些资料把它称为 Type-1，因为 vCPU 的客户机模式由内核和硬件直接控制。两个说法各自选取了不同观察边界。若问题是“谁调度物理 CPU、建立二阶段页表并隔离内存”，答案落在 Linux KVM 与硬件；若问题是“谁解析命令行、构造主板并实现大部分设备”，答案落在 QEMU 用户态。

固定标签常把一个协作系统压成单层。更有用的分析方式是逐项追问责任：客户机普通指令由谁执行，GPA 到 HPA 由谁建立，MMIO 由谁解释，中断由谁注入，最新寄存器在哪里，迁移时谁把状态交出来。KVM 2007 年论文把它描述为 Linux 子系统，为 Linux 增加 hypervisor 能力；这个表述与当前工程边界更贴近。

本书后续沿用“QEMU/KVM 虚拟化栈”或“KVM accelerator”。提到 Type-1/Type-2 时会同时说明分类口径，避免从标签推导不存在的职责。读源码时也应保持同样习惯：`-accel kvm` 只选择 CPU 与内存热路径的主要执行方式，machine 和设备并未换成另一个程序。

:::: {.quick-quiz}
为什么“QEMU 是用户进程”无法单独证明 KVM 属于 Type-2？

::: {.quick-answer}
分类取决于观察边界。用户态 QEMU 负责 VMM 与设备，客户机模式、vCPU 调度入口和二阶段映射位于内核与硬件。标签不会告诉我们一次 MMIO、一次页表缺页或一次迁移分别经过哪些组件，逐项画出责任边界更可靠。
:::
::::

## 只有客户机模式还不够

VT-x、AMD-V 和 RISC-V H 都提供受控的客户机执行模式，使敏感事件能陷入更高特权层。CPU 隔离只是第一步。客户机操作系统认为自己管理“物理内存”，宿主却要把这片 guest physical address（GPA）映射到进程中的 host virtual address（HVA），最终落到 host physical address（HPA）。若硬件只完成客户机页表的 GVA 到 GPA 转换，宿主仍要在同一套 MMU 上维护隔离。

早期 KVM 用 shadow MMU 合成 GVA 到 HPA 的映射。客户机页表页受到写保护，更新时发生 trap，KVM 验证并更新影子页表；反向映射、角色缓存、失效和大页让这套机制迅速复杂起来。Avi Kivity 在 2007 年 KVM Forum 的 [MMU 演讲](https://gitlab.com/qemu-project/kvm-forum/-/raw/main/_attachments/2007/KvmForum2007%24shadowy-depths-of-the-kvm-mmu.pdf)把目标列为正确性、性能、可接受的最坏情况和可维护性，说明“让 CPU 直接执行”并没有自动解决内存虚拟化。

随后 EPT/NPT 把第二阶段地址转换交给硬件。RISC-V H 从接口上直接区分 VS-stage 与 G-stage：客户机在 VS/VU 中执行时，VS-stage 把 GVA 转成 GPA，G-stage 再把 GPA 转成宿主物理地址。`hgatp` 选择 G-stage 根页表，`vsatp` 管理客户机监督态看到的第一阶段。两阶段相关 fault 携带不同信息，供 HS-mode 的 KVM 判断它面对的是客户机页表问题、尚未映射的 RAM，还是应该交给 QEMU 的设备地址。

二阶段硬件减少了 shadow page table 的维护，却没有取消 memory slot。QEMU 仍需告诉 KVM：哪段 GPA 对应哪片用户态 RAM、是否只读、是否启用 dirty logging。硬件页表能走到哪里，取决于内核根据这些注册信息建立的映射。第 13 章会从 `KVM_SET_USER_MEMORY_REGION` 追踪这条关系。

## 回到当前 RISC-V：三层怎样接住一次运行

QEMU `v11.1.0-rc0` 的通用入口位于 [`accel/kvm/kvm-all.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/kvm/kvm-all.c)，RISC-V 架构接线位于 [`target/riscv/kvm/kvm-cpu.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c)。`kvm_init()` 打开 `/dev/kvm`、检查 API 与 capability、创建 VM，并注册内存监听器；每个 vCPU 线程通过 vCPU fd 进入 `KVM_RUN`。RISC-V 文件定义 one-reg ID、ISA 属性、timer、AIA、reset 和架构特有 exit。

硬件一侧，H 扩展让物理 hart 在 VS/VU 中执行客户机，G-stage 隔离客户机物理地址。内核一侧，KVM 创建并调度 vCPU，维护 G-stage 映射、寄存器和中断控制状态，决定某次 trap 可以在内核完成还是要返回用户态。QEMU 一侧，`virt` machine 创建 RAM、UART、virtio、PLIC/AIA 与 FDT，注册 memory slot，并在用户态处理通用 MMIO 或架构特有的 SBI 等退出。

可以把一次运行压缩成下面这条闭环：

```text
QEMU configures machine and vCPU state
        | KVM_RUN
        v
Linux KVM loads state and enters RISC-V VS/VU
        | regular instructions and two-stage translation stay in hardware
        +-- kernel-handled faults/interrupts --> re-enter
        `-- MMIO/SBI/debug/signals --> return to QEMU
                                      | finish semantics and update state
                                      `-- KVM_RUN again
```

这也是第六章 accelerator 抽象的具体落点。`CPUState`、machine 和 AddressSpace 仍属于公共 QEMU 对象，TCG 与 KVM 提供不同执行后端；目标架构回调负责把 RISC-V 状态接到各自后端。抽象的价值在于让设备与管理层复用，代价是状态新鲜度必须显式管理：KVM 运行时，最新寄存器可能在内核或硬件，用户态 `env` 只是待同步镜像。

## 一次 trap 怎样穿过三层

设想客户机在 VS-mode 执行一条普通加法。寄存器、流水线和缓存访问都留在物理 hart；若取数地址经 VS-stage 和 G-stage 成功落到已注册 RAM，这次访存也无需通知 QEMU。客户机发生自身可处理的 page fault 时，硬件按虚拟化规则把异常交给 VS-mode 的客户机内核。这里看不到 `KVM_RUN` 返回，因为隔离边界没有被越过。

若 G-stage 找不到有效映射，CPU 陷入 HS-mode。Linux KVM 读取 trap 原因和地址，检查 GPA 是否属于已有 memory slot。普通 RAM 的缺页可以在内核补齐映射并继续执行；涉及内核可处理的虚拟中断或计时事件，也可能在这个层次闭合。vCPU 线程仍停留在同一次 ioctl 中，QEMU 不会因每个硬件 trap 都被唤醒。

若 GPA 对应 UART 等用户态 MMIO，KVM 无法凭一个地址得知设备寄存器语义。它在共享 `kvm_run` 页写入退出原因、地址、宽度和读写数据，`KVM_RUN` 返回。QEMU 的 AddressSpace 分派找到设备 `MemoryRegionOps`，执行寄存器读写；若是读操作，结果还要写回共享页。QEMU 再次调用 `KVM_RUN`，内核才能完成导致退出的那条访存并继续客户机。一次退出由硬件 trap、内核分类和用户态设备语义串成闭环，漏掉任何一层都会误判成本或状态所有权。

架构特有事件走相同原则，但数据格式不同。当前 RISC-V KVM 的 [`kvm_arch_handle_exit()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c#L1730)处理 SBI、`CSR_SEED` 与 debug 等 RISC-V exit；通用 MMIO 和系统事件由 `kvm-all.c` 的公共 switch 处理。分层让其他架构复用运行循环，也保留了 RISC-V 对特权接口的解释权。

这条路径提示一个常见调试误区。看到 vCPU 利用率下降，不能直接归因于“硬件虚拟化慢”。先统计 `KVM_RUN` 停留时间和 exit reason，再区分内核内闭合的事件、返回 QEMU 的 MMIO、宿主信号与调度等待。只有最后两类真正把执行带回用户态；它们还可能分别受设备实现、锁竞争、IOThread 和宿主负载影响。

## 四层能力必须分别验证

RISC-V H/KVM 的讨论经常把四件事混成“支持虚拟化”。第一层是宿主物理 hart 实现 H，Linux 才可能进入 VS/VU 并使用 G-stage。第二层是宿主内核 KVM 驱动实现相应 UAPI、ISA extension、timer 与 irqchip 能力。第三层是 QEMU KVM accelerator 能发现这些能力，把它们呈现为可配置 CPU 和 machine。第四层才是客户机看到的虚拟硬件组合。

这四层还不足以推出嵌套虚拟化。宿主 H 能运行一个 L1 客户机，只说明 L0 的加速条件成立；向 L1 暴露 H CSR 需要额外状态虚拟化；让 L1 真正进入 L2 又需要 nested KVM 执行路径；迁移一个正在运行 L2 的系统，还要序列化嵌套控制块、H/VS CSR、二阶段映射相关状态与 irqchip 状态。第 15 章会用固定基线逐层审计，不从一个 `H=true` 属性推导整条链路。

同样的分层适用于普通扩展。QEMU 源码中存在 `KVM_RISCV_ISA_EXT_H` 映射，证明程序知道如何询问或配置该扩展；宿主内核是否支持对应 one-reg 仍需运行时探测；用户请求的 CPU model 是否允许启用，还受 machine、其他扩展依赖和迁移兼容约束。源码、头文件、宿主 capability 与运行结果是四种证据，强度不同。

选择 TCG 时，这张矩阵会变化。宿主无需 H，目标指令和特权语义由 QEMU 翻译器实现；客户机仍受 QEMU 当前模型完备度限制。开发早期 RISC-V 扩展时，可以先用 TCG 验证 ISA 与 machine，再用 KVM 验证硬件、内核 UAPI 和状态同步。两个后端给出的差异经常比单独阅读任一实现更能暴露边界错误。

## 实验：先观察 H，再建立两阶段心智模型

::: {.hands-on}
本章保留两个很小的实验入口。它们不要求先把整套 KVM 跑起来，目标是把“硬件能力”“内核能力”“QEMU 选择”分开验证。

第一步运行 [`inspect-h-extension-state`](../experiments/part-03-riscv-hardware-virtualization/chapter-12-riscv-h-extension/inspect-h-extension-state/README.md)。记录宿主 ISA 是否包含 H、`/dev/kvm` 是否存在、QEMU 是否列出 KVM accelerator，以及客户机 CPU model 请求了哪些扩展。若某一层缺失，不要用下一层的错误消息替它下结论。

第二步运行 [`model-two-stage-translation`](../experiments/part-03-riscv-hardware-virtualization/chapter-12-riscv-h-extension/model-two-stage-translation/README.md)。为一个地址分别写下 GVA、GPA、HVA/HPA，标出 VS-stage 与 G-stage 的页表所有者，再构造 RAM 和 MMIO 两种 GPA。前者应能由 memory slot 支撑映射，后者需要形成可交给设备模型的退出。这个纸面模型会在第 13、14 章变成真实 ioctl 与 trace。

实验记录至少回答四个问题：当前机器能否直接执行 RISC-V 客户机；缺少 H 时是否仍可用 TCG；两阶段中的每一级由谁配置；一次设备 GPA 为什么不会被当作普通 RAM。能给出这四个答案，才算把“硬件加速”拆成了可验证条件。
:::

## 用约束选择 accelerator

开发者为 RISC-V 内核做早期 bring-up 时，目标往往是尽快看见异常、页表和设备访问。TCG 可在常见工作站上运行，能打开翻译日志和插件，并允许修改目标语义后立即重试；此时峰值吞吐通常排在可观察性之后。验证真实部署性能、调度、NUMA 或宿主中断时，则要使用 KVM，因为这些行为依赖 Linux 与物理 hart，TCG 结果无法替代。

持续集成也适合双轨。TCG job 覆盖跨 ISA 构建、固件启动和确定的功能回归，KVM job 覆盖 UAPI、硬件 capability、状态同步和设备旁路。KVM job 还应记录宿主 CPU 与内核，避免不同 runner 能力让测试结果漂移。只有 KVM 测试会漏掉无硬件环境，只有 TCG 测试又看不到真实 one-reg、G-stage 与 irqchip 问题。

安全分析需要区分攻击面。TCG 把不可信指令送入解码器、IR 和 helper；KVM 把普通执行送入硬件与内核，设备 exit 仍进入 QEMU。切换 accelerator 改变了 CPU 路径，没有移除设备模型和镜像输入。模糊测试可以分别瞄准 TCG 指令语义、KVM UAPI、MMIO 设备与迁移 stream，再用相同客户机行为做差分。

选择结果最后写成可复现配置：QEMU 标签、machine、CPU model、accelerator 属性、宿主 ISA/内核、固件与设备后端。单写“使用 KVM”无法说明 H、AIA、timer 和可迁移 feature 的实际组合。这样的记录也为性能回归提供基线，下一次 capability 或默认值变化时可以定位差异来自哪一层。

这份配置还应保留失败条件和回退路径，让读者知道某项能力缺失时，系统会切回 TCG、关闭可选功能，还是在启动前明确拒绝。

这样才能复查每项判断。

:::: {.quick-quiz}
RISC-V H 已经提供 G-stage，QEMU 为什么还要注册 memory slot？

::: {.quick-answer}
G-stage 是硬件转换机制，memory slot 提供映射政策和后端：某段 GPA 对应哪片用户态内存、权限怎样、是否跟踪脏页。KVM 依据这些信息建立和维护硬件可用的第二阶段映射；未注册的设备区间则可能产生 MMIO exit。
:::
::::

## 从执行器之争转向责任边界

TCG 与 KVM 没有构成一条“旧技术被新技术淘汰”的直线。TCG 承担跨 ISA、可控制和硬件独立的执行，KVM 承担同 ISA 下的硬件热路径；两者复用 QEMU 的 machine、设备和管理能力。用户选择 accelerator 时，实际选择的是一组约束和可观察面。

KVM 的早期决策把 VM 放进 Linux 进程，把 vCPU 放进线程，把设备留给 QEMU，并让 `/dev/kvm` 成为控制接口。硬件从 shadow paging 时代继续演进到二阶段页表，RISC-V H 用 VS-stage/G-stage 给出了当代实现。下一章将沿 `/dev/kvm` 进入当前代码，回答这些对象为什么表现为 system fd、VM fd、vCPU fd、共享运行页和 memory slot，以及一次 `KVM_RUN` 究竟在哪里结束。
