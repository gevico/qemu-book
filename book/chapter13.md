# `/dev/kvm` 为什么长成今天的接口

在支持 H 扩展的 RISC-V 主机上，QEMU 仍可能报出 `Could not access KVM kernel module`。这个错误把 KVM 的第一条事实摆在眼前：编译出 `-accel kvm` 只说明 QEMU 含有 KVM 后端；真正运行还需要宿主内核驱动、设备权限、兼容的 UAPI、可创建的 VM 类型和满足要求的 CPU capability。QEMU 不通过一条“启动虚拟机”系统调用把整台机器交给内核，它沿一组文件描述符逐步建立 system、VM 与 vCPU 对象，再把 RAM 区间注册给 KVM。

这组接口看起来琐碎，却把生命周期、并发和扩展性编码进了 ABI。system fd 回答宿主提供什么能力，VM fd 承载共享地址空间与 VM 级资源，vCPU fd 承载每个虚拟 hart 的运行与寄存器，共享 `kvm_run` 页交换高频 exit 数据。理解这些对象以后，`KVM_RUN` 才不会被误读成一个隐藏全部细节的黑盒。

本章继续使用 QEMU [`v11.1.0-rc0`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0)。通用实现集中在 [`accel/kvm/kvm-all.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/kvm/kvm-all.c)，RISC-V 接口集中在 [`target/riscv/kvm/kvm-cpu.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c)。阅读时先画对象关系，再跟函数调用；否则多个 fd、多个地址空间与多份 CPU 状态很容易混在一起。

## 从 API v1 到对象 fd

KVM 初版已经选择 `/dev/kvm`，但今天的对象结构不是一次设计完成。Avi Kivity 在 2006 年 12 月提交 [`KVM: API versioning`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=0b76e20b27d20f7cb240e6b1b2dbebaa1b7f9b60)，为编译期与运行时接口加上版本号，当时的 `KVM_API_VERSION` 是 1。2007 年初的重构让 `KVM_CREATE_VM` 返回 VM fd，随后让 `KVM_CREATE_VCPU` 返回独立 vCPU fd，并把频繁交换的运行结构改为 `mmap` 共享页。API 数字很快演进到 12，当前 Linux 与 QEMU 仍以 12 为基础版本。

这段演进解释了三项现存选择。其一，能力查询与对象操作分离：打开 `/dev/kvm` 可以探测系统，不必先构造整台机器。其二，VM 和 vCPU 的身份由 fd 表达，内核可以使用引用计数管理释放，用户态也能让不同 vCPU 线程各自阻塞在独立 fd 上。其三，高频 exit 参数通过共享页传递，新增联合体字段时可以沿既有 mmap 尺寸和 capability 协议扩展，避免每次退出复制一套不断膨胀的结构。

ABI 稳定也没有被压缩成“版本号相等便全部可用”。基础版本保持不变，新功能主要通过 `KVM_CHECK_EXTENSION`、device attribute 和 one-reg 可用性发现。2007 年加入 `KVM_CHECK_EXTENSION` 时便强调向后兼容；今天同一份 QEMU 二进制需要面对不同内核、不同 RISC-V hart、不同 AIA 实现和发行版配置。代码能看到某个 ioctl 编号，只证明构建时头文件认识它。

早期重构还回应了并发。独立 vCPU fd 避免多个 vCPU 围绕同一个 file object 争用，也让“哪个线程正在运行哪颗 vCPU”有稳定身份。SMP 客户机由多个宿主线程进入 `KVM_RUN`，VM 级内存和 irqchip 又由它们共享；fd 层级没有消除同步问题，却把同步范围标了出来。

:::: {.quick-quiz}
为什么 KVM 保持 API version 12，还能持续加入新功能？

::: {.quick-answer}
基础版本只确认双方采用同一代核心 ABI。后续功能通过 capability、VM/vCPU ioctl、device attribute 和 one-reg 探测独立协商。QEMU 必须先查询再启用，不能把新头文件当作宿主能力证明。
:::
::::

## system、VM 与 vCPU 三种对象

当前 QEMU 的 [`kvm_init()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/kvm/kvm-all.c#L2893)先打开 `/dev/kvm`，用 `KVM_GET_API_VERSION` 检查精确版本，再读取 vCPU mmap 大小和通用 capability。随后 `KVM_CREATE_VM` 返回 VM fd，QEMU 建立 `KVMState`，注册 memory listener，并按 machine 配置创建 irqchip 或其他 VM 级设备。每颗 `CPUState` 初始化 KVM 后端时，再从 VM fd 创建自己的 vCPU fd。

三个对象可以用责任范围来记忆：

| 对象 | 当前接口中的主要问题 | 生命周期边界 |
|---|---|---|
| `/dev/kvm` system fd | 这台宿主的 KVM API 与全局 capability 是什么 | QEMU KVM 后端实例 |
| VM fd | 哪些 GPA 属于 RAM，VM 级 irqchip、dirty log 与 capability 怎样配置 | 一台 QEMU machine |
| vCPU fd | 这颗 hart 的寄存器、MP state、运行页和 `KVM_RUN` 状态是什么 | 一个 vCPU 线程/对象 |

每个 vCPU fd 还映射一块由 `KVM_GET_VCPU_MMAP_SIZE` 决定大小的 `struct kvm_run` 区域。进入前，QEMU 写入本次运行所需的输入字段；退出后，内核写 `exit_reason` 以及 MMIO、system event、debug 或架构特有数据。共享页只降低参数交换成本，不意味着双方能同时任意修改。字段在进入前、退出后和重新进入时各有所有权，UAPI 文档中关于“完成 I/O 后必须再次进入”的约定属于执行语义。

关闭 fd 是资源释放协议的一部分。vCPU 的共享页要先解除映射，再关闭 vCPU fd；VM 销毁要等待相关 vCPU 与设备停止。QEMU 的对象生命周期还要处理初始化半途失败、热拔、reset 和迁移取消。把 fd 当成普通整数缓存，容易在错误路径留下内核对象或悬空映射。

## 为什么 RISC-V 要创建 scratch vCPU

用户在 machine 完成 realize 以前就可以指定 `-cpu` 属性，QEMU 需要尽早判断 ISA 扩展、SATP 模式、vendor/arch/imp ID、Vector 长度、SBI extension 与 CSR 是否可用。很多 RISC-V 能力却只能对真实 KVM vCPU 执行 one-reg 查询；system fd 的布尔 capability 无法表达一颗 hart 的全部属性。若等 vCPU 线程启动后才发现配置不兼容，RAM、设备和 FDT 可能已经创建，错误回滚会跨越更多对象。

当前代码因此使用 [`KVMScratchCPU`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c#L956)。`kvm_riscv_create_scratch_vcpu()` 临时打开 `/dev/kvm`，创建 VM 和 vCPU，查询所需属性后关闭三层 fd。它不执行客户机，只把“询问一颗内核 vCPU”提前到 CPU model 构造阶段。探测走真实 UAPI，QEMU 无需维护一份根据处理器型号猜能力的旁路数据库。

scratch vCPU 也说明 capability 有层次。`KVM_CAP_*` 可以回答某类通用接口是否存在；RISC-V ISA extension 映射可以回答内核 vCPU 是否接受某个扩展；用户最终选择还受 QEMU 模型依赖、machine 约束和迁移策略影响。当前 [`kvm_riscv_extension_supported()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c)一类逻辑将探测结果变成 QOM 属性，构建期 UAPI、运行期内核与用户可见 CPU model 在这里相遇。

这种设计有成本。初始化会临时创建内核对象，多个属性查询要共享一致结果，宿主环境在探测后发生变化时仍需防御。它仍优于延迟失败，因为 QEMU 可以在客户机执行前给出明确错误，并把不支持的属性标记为 unavailable。阅读其他架构的 KVM CPU model 时，也应寻找等价的能力发现阶段，不能假设都使用相同 scratch 机制。

## 从 `-accel kvm` 到第一条客户机指令

命令行解析先创建 accelerator 与 machine 对象。KVM accelerator 的 machine 初始化打开 system fd、确认 API、创建 VM fd；此时客户机主板尚未完整 realize，内核也不知道最终 RAM 布局。`virt` machine 随后创建系统内存、hart、UART、virtio transport、中断控制器和 FDT。AddressSpace 的变化通过 memory listener 送到 KVM，RAM 才逐段成为 slot。这个先后关系解释了为什么 `kvm_init()` 无法一次提交整张物理地址图。

CPU model 的能力发现与真实 vCPU 生命周期交错进行。scratch vCPU 为属性探测提供内核对象，完成后立即销毁；真实 vCPU 则在 QEMU CPU 对象和 vCPU 线程准备好后从目标 VM fd 创建。QEMU 获取 vCPU mmap 大小，映射各自 `kvm_run`，执行 RISC-V 架构初始化，并把复位状态放入内核。scratch 和真实 vCPU 若被混为同一个对象，日志里会出现“创建过 vCPU”却找不到对应运行线程的假线索。

当前 RISC-V `virt` 在 KVM 下采用 direct kernel boot。machine 把 kernel 与 FDT 放到约定的客户机地址；reset 时目标 KVM 代码设置 PC 为 kernel entry，`a0` 为 vCPU 对应 hart ID，`a1` 为 FDT 地址。TCG 路径可以从更完整的固件流程进入，KVM 当前实现对此施加了更窄的启动约束。由此可见，accelerator 抽象复用了 machine，并不保证每种固件启动路径在所有后端上都已实现。

开始运行前，QEMU 还要协调 vCPU 的初始 MP state、timer、pending interrupt 与用户态 CPU 镜像。随后 vCPU 线程进入 `kvm_cpu_exec()`，状态所有权第一次从 QEMU 转向内核和硬件。若启动在首条指令前失败，应按时序定位：system fd/API、VM 创建、CPU capability、slot 注册、direct boot 布局、寄存器写入、`KVM_RUN`。把所有失败都归为“KVM 不支持”会丢失可修复的层次。

一次最小启动可以写成七个检查点：

1. system fd 的 API 与必需 capability 通过；
2. VM fd 创建成功，machine 类型可被当前内核接受；
3. scratch vCPU 认可用户请求的 ISA 与属性；
4. AddressSpace 中的 RAM 成功注册为 slot；
5. 真实 vCPU fd 与 `kvm_run` 映射完成；
6. PC、`a0`、`a1`、timer 和必要状态写入内核；
7. `KVM_RUN` 进入 VS/VU，首个退出原因符合启动路径。

每个检查点都能用日志、trace、ioctl 返回值或 FDT/寄存器检查验证。这种分段方式比直接盯着客户机串口更有信息量：串口沉默可能发生在执行前，也可能是客户机已运行却访问了错误 UART 地址。

## memory slot 把 GPA 接到宿主页

machine 创建 RAM 后，QEMU 的 AddressSpace 中同时存在 RAM、ROM、alias、I/O 与重叠优先级。KVM 只需要能直接访问的内存区间。通用 KVM memory listener 接收区域变化，[`kvm_set_phys_mem()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/kvm/kvm-all.c#L1631)筛选 RAM 与可直接访问的 ROMD 区域，分配 slot，再由 [`kvm_set_user_memory_region()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/kvm/kvm-all.c#L369)把 slot 编号、GPA 起点、大小、用户态地址和 flags 交给内核。

这里同时出现三个地址域。`guest_phys_addr` 是客户机认为的物理地址；`userspace_addr` 是 QEMU 进程映射 RAM 的 HVA；内核再把 HVA 解析到宿主页，并建立 RISC-V G-stage 可使用的映射。客户机 VS-stage 的页表只负责 GVA 到 GPA。任何调试图若只写“虚拟地址到物理地址”，都会丢失至少一层所有者。

slot 是区间注册协议，不等同于客户机页表项。内存热插拔、memory backend 变化、只读属性和 dirty logging 都可能导致更新；删除通常以 size 为零注销区间。KVM 对 slot 数量、对齐和重叠有约束，QEMU 还要把复杂 MemoryRegion 拓扑压成内核能接受的平坦区间。RAM 与 MMIO 的分界在这里决定：RAM 让硬件经过 G-stage 直接访问，未注册的设备 GPA 形成可分类的 fault，并可能返回用户态。

当前代码在支持 guest memory fd 的配置上会选择新的 region 接口，但责任没有变化：QEMU 描述客户机 GPA 后端，KVM 建立隔离映射。机密虚拟化或专用 memory backend 会改变页面由谁可见，却仍要回答 slot 生命周期、失效和迁移如何协调。

slot 更新还要和 vCPU 并发执行协调。QEMU 不能在一颗 vCPU 正沿旧 G-stage 映射访问页面时，无协议地回收对应宿主页。内存监听器提交拓扑变化，KVM 负责使内核映射失效，QEMU 的全局运行状态与 memory transaction 决定变更何时可见。内存热插拔看似设备管理动作，最终会触及硬件正在使用的转换缓存。

dirty logging 给 slot 增加另一层语义。开始迁移时，QEMU 把相应 slot 标记为记录写入；KVM 在页表或 dirty ring 中积累变化，QEMU 周期性读取并合并到迁移位图。关闭记录也必须经过 slot 更新。第 15 章会展开脏页所有权；此处先记住，slot 同时承载地址后端、访问属性和迁移观察策略。

:::: {.quick-quiz}
为什么不能把 QEMU AddressSpace 中的每个 `MemoryRegion` 原样注册成 KVM slot？

::: {.quick-answer}
AddressSpace 还包含 MMIO、alias、重叠优先级和动态拓扑，KVM slot 描述可直接访问的 GPA 到内存后端区间。QEMU 要先把视图扁平化并筛出 RAM/ROMD；设备区域保留为 trap，由 QEMU 或内核设备后端解释。
:::
::::

## `KVM_RUN` 是一个三层循环

vCPU 线程进入 [`kvm_cpu_exec()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/kvm/kvm-all.c#L3427)前，要处理待注入事件，并按状态所有权规则把用户态修改推入内核。QEMU 随后释放 Big QEMU Lock，调用 vCPU fd 上的 `KVM_RUN`。内核装载 vCPU 状态并进入 RISC-V VS/VU；普通指令、可由客户机处理的异常和已映射 RAM 访问不会返回用户态。

退出硬件后，KVM 先判断事件能否在内核闭合。宿主中断可能只要求调度后继续，G-stage RAM fault 可以补映射，内核 irqchip 可以吸收部分中断控制。需要 QEMU 的事件被编码到 `kvm_run`，ioctl 返回。通用 switch 处理 MMIO、系统事件和关机等原因，RISC-V [`kvm_arch_handle_exit()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c#L1730)处理 SBI、`CSR_SEED`、debug 等架构事件。

一次 MMIO exit 可能尚未完成导致退出的客户机指令。读操作要由 QEMU 填回数据，写操作也可能需要内核在下次进入时提交完成状态。QEMU 处理后重新调用 `KVM_RUN`，内核先完成挂起语义再继续。调试时若只统计 ioctl 返回次数，仍要区分“完成上次 I/O 的重新进入”和“开始新的客户机执行”。

信号与线程控制也穿过循环。暂停虚拟机、迁移 stop、调试器和宿主调度需要把阻塞在 `KVM_RUN` 的 vCPU 拉回用户态。原始 KVM 设计选择 VM 进程/vCPU 线程，带来了 Linux 调度工具，也要求 QEMU 正确协调信号掩码、kick、BQL 和运行状态。`KVM_RUN` 很快，不代表 vCPU 可以绕过 QEMU 的生命周期协议。

可以用四个问题审计任一 exit：谁触发了它；最新 CPU 状态此刻在哪里；内核能否完成；若返回用户态，哪段设备或管理代码消费数据。四项都有 trace 证据，才足以提出优化或修复。

## one-reg 把架构状态变成可寻址 ABI

RISC-V 寄存器种类会随 ISA extension、特权规范和 KVM 功能增长。若 UAPI 固定暴露一个包含全部 CSR 的 C 结构体，任何新增字段都要处理结构大小、对齐、旧内核和可选扩展，用户态也难以只同步需要的部分。one-reg 接口用一个编码后的 ID 指定大小、架构与寄存器组，再由指针传入或取出值。QEMU 可以逐项探测，缺失的可选寄存器不会迫使基础 ABI 整体换代。

当前 RISC-V 代码把 core、CSR、FP、Vector、timer、ISA config 等状态映射到相应 ID。客户机停止、reset、迁移或调试时，需要的同步集合不同；one-reg 允许架构代码根据运行阶段选择范围。它并未自动提供事务一致性：若读取几十个寄存器期间 vCPU 仍在运行，得到的组合可能来自不同时间点。因此 QEMU 必须先建立停止或内核同步点，再进行 get/put。

one-reg 的可探测性也解释了 scratch vCPU。很多 ID 只有在某个 extension 或内核实现存在时有效，查询真实临时 vCPU 比维护“内核版本到寄存器表”的映射可靠。错误返回仍需分类：接口完全未知、当前寄存器不支持、用户 buffer 有问题和 vCPU 状态不允许访问，分别对应回退、禁用属性或启动失败。

状态 ID 稳定只解决编码兼容，迁移兼容还要再加一层。源端能读出某个寄存器，目标端未必能写入；两个宿主都支持 H，也可能支持不同子扩展或 timer frequency。QEMU CPU model 与 machine version 要把可迁移集合固定下来，并在启动或迁移前拒绝无法兑现的配置。第 15 章会把 one-reg 与 VMState、`vcpu_dirty` 连接起来。

## RISC-V 接入如何通过 review 收敛

RISC-V KVM 并非一次把全部功能塞进 QEMU。Yifei Jiang 在 2021 年末发布初版，2022 年 1 月合入的 [v5 系列](https://patchwork-proxy.ozlabs.org/project/kvm-riscv/list/?order=name&series=280661&state=%2A)拆成 UAPI header、公共 KVM 接口、寄存器 get/put、direct kernel boot、timer 和 accelerator enable 等 13 个 patch。Mingwang Li 共同签署，Alistair Francis review 并经维护路径签入，Anup Patel 参与 review。角色分工让每一步都能单独回答 ABI、状态和 machine 接线问题。

这组提交的顺序很有工程含义。先引入接口定义和最小 CPU 操作，再建立寄存器双向同步；direct boot 明确 reset 时 PC 指向 kernel、`a0` 携带 hart ID、`a1` 携带 FDT；timer 独立处理，最后才把 accelerator 对用户启用。若先加一个总开关，启动失败时很难判断缺的是 UAPI、reset 约定还是计时状态。

当前代码已经在初始版本上继续演进：能力探测使用 scratch vCPU，ISA 属性增多，AIA 有 full/split 模式，FP/Vector 同步会区分运行阶段。回看初始 series 的价值在于解释模块边界，并不意味着今天仍照搬当年的函数。研究历史 patch 时必须把结论重新落到固定源码标签。

这也展示了 Maintainer、Reviewer 与 Contributor 的不同关注面。Contributor 提供可运行路径和拆分；Reviewer 检查 ABI、错误路径、架构语义及与内核的匹配；Maintainer 还要判断它能否长期进入公共 accelerator 生命周期、是否给后续功能留下演进位置。`Reviewed-by` 与 `Signed-off-by` 只能证明参与链路，具体判断仍应以邮件正文和 patch 变化为证。

:::: {.quick-quiz}
RISC-V 初始 KVM series 为什么把寄存器、timer 和 direct boot 分开提交？

::: {.quick-answer}
三者跨越不同契约：one-reg 决定 CPU 状态同步，timer 有独立时间与迁移语义，direct boot 约定 reset PC 和参数寄存器。拆开后 review 能逐项验证 UAPI 与失败边界，也便于定位 bring-up 问题。
:::
::::

## 实验：从 capability 走到一次 exit

::: {.hands-on}
先运行 [`probe-riscv-kvm`](../experiments/part-03-riscv-hardware-virtualization/chapter-13-linux-kvm-riscv/probe-riscv-kvm/README.md)。记录 `/dev/kvm` 的存在与权限、API version、QEMU accelerator 列表、RISC-V capability 和 CPU 属性。把结果分成“构建时认识”“system fd 报告”“scratch vCPU 报告”“用户配置接受”四列。某列为空时，停止向下一列推断。

随后运行 [`trace-kvm-run-loop`](../experiments/part-03-riscv-hardware-virtualization/chapter-13-linux-kvm-riscv/trace-kvm-run-loop/README.md)。选择能启动到串口的最小客户机，标记 vCPU 线程每次进入和离开 `KVM_RUN` 的时间、exit reason 与返回处理函数。至少找出一次用户态 MMIO 或架构 exit，并判断它是否需要重新进入来完成指令。

若宿主没有 RISC-V KVM，仍可完成静态部分：从固定标签定位 `kvm_init()`、`kvm_set_user_memory_region()`、`kvm_cpu_exec()` 与 `kvm_arch_handle_exit()`，画出 system fd、VM fd、vCPU fd、`kvm_run` 和 memory slot 的所有权。动态结论明确标记“未验证”，再用 TCG 启动同一 machine 观察设备侧语义。缺少硬件不应被伪装成一次成功的 KVM 实验。

实验报告最后回答：VM fd 与 vCPU fd 分别由谁创建和关闭；一个 RAM `MemoryRegion` 怎样变成 slot；普通客户机执行为何不返回 QEMU；一次 MMIO 数据在哪个共享结构交接。四个答案共同构成最小 KVM UAPI 心智模型。

还可以有意制造四类失败。撤掉 `/dev/kvm` 访问权限，验证错误停在 system fd；请求宿主没有的 ISA extension，验证 scratch vCPU 阶段拒绝；让 RAM 布局触碰 slot 约束，观察 memory listener 报错；给客户机访问一个未注册 GPA，确认它形成 MMIO 或内部错误。每次失败只改一个条件，并保留 ioctl 返回值和 QEMU 处理函数。

故障注入能检验对象清理。VM 创建后、首颗 vCPU 创建前失败，system/VM fd 应按引用关系关闭；vCPU mmap 后初始化失败，共享页应解除映射；slot 注册部分完成后失败，不能让后续同进程测试继承残留对象。工具通常在进程退出时由内核兜底释放，长期运行的管理进程和热插拔路径却不能依赖退出清场。

权限问题也属于接口设计。能够打开 `/dev/kvm` 的进程会请求硬件虚拟化资源，仍受普通文件权限、cgroup、rlimit、SELinux 等宿主政策约束；客户机 RAM 又来自该进程地址空间。排障时应区分设备节点权限、内核功能缺失与 QEMU 配置错误，避免用放宽全部权限掩盖真正原因。

把这些失败点写进自动化测试后，UAPI 演进才有护栏：旧内核应在 capability 阶段得到可理解的拒绝，可选功能应落到经过测试的回退，资源不足应释放已经创建的对象。一次成功启动只覆盖主路径，稳定接口还要经得住半途失败。

这也是长期兼容所需的证据。
:::

## 文件描述符背后的设计承诺

`/dev/kvm` 的形态记录了 KVM 对 Linux 的复用：VM 依附进程地址空间，vCPU 依附线程调度，对象通过 fd 建立生命周期，能力通过可查询 ABI 演进。QEMU 在这套接口之上保留 machine、设备和管理层，再以 memory slot 把 AddressSpace 中的 RAM 接入 RISC-V G-stage。

这一章建立的循环仍只说明“CPU 怎样跑起来”。当普通指令已经留在硬件，性能热点会转移到退出：一个串口字节、一次 virtio kick、一次中断注入分别要穿过多少层；把数据面移向 irqfd 或 vhost 后，谁又负责迁移和调试。第 14 章将用 exit 经济学回答这些问题。
