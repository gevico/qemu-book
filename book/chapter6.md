# RISC-V CPU 模型与加速器抽象

第一次在 `riscv64-softmmu` 上切换 `-accel tcg` 与 `-accel kvm` 时，最容易产生一个错觉：命令行只换了一个单词，后面大概也是同一套 CPU 代码，只在执行函数里分个支。真正沿源码走一遍，会看到更细的边界。`RISCVCPU` 仍然是那颗客户机可见的处理器，hart ID、扩展集合、寄存器宽度和复位状态都没有因为加速器改变；但“谁持有最新寄存器”“谁判断一条指令是否合法”“谁完成页表遍历”，答案会随加速器变化。QEMU 必须把这些差异藏在足够稳定的接口后面，同时又不能把性能热路径抽象得层层跳转。

这一章先把坐标系搭起来。后面的 TCG 篇会进入动态翻译，硬件虚拟化篇会进入 RISC-V H 扩展与 KVM，两条路线都从同一个 CPU 对象出发。只要公共模型、加速器状态和设备可见状态混在一起，后面的异常、迁移和调试就很难讲清。

## 本章目标

- 理解 `CPUState`、`CPUClass`、`RISCVCPU` 与 `CPURISCVState` 的职责和组合关系；
- 追踪一颗 RISC-V CPU 从 QOM 创建、属性配置、realize、reset 到进入 vCPU 线程的过程；
- 说明 `AccelClass`、`AccelOpsClass` 与 `TCGCPUOps` 如何隔开机器级、线程级和目标架构级操作；
- 判断 TCG 与 KVM 下 CPU 状态的所有权、新鲜度和同步时机；
- 用 Git 提交和 qemu-devel 审查记录，分辨当前目录布局背后的工程动机。

## 先从一颗 hart 的诞生说起

RISC-V `virt` 机器不会直接分配一块 `CPURISCVState`，填几个寄存器便开始跑。机器模型先建立 hart array，再按 CPU 类型创建 QOM 对象，设置 hart ID、集群标识和扩展相关属性，最后进入 realize。这里的顺序值得留意：用户在命令行指定的 `-cpu` 属性、machine 提供的板级约束、加速器能够支持的能力，都会在 realize 前后汇合。过早把 CPU 放进运行队列，后续才发现扩展组合不合法，错误就会从清晰的启动诊断变成难以复现的运行时故障。

在研究基线 `v11.1.0-rc0`，RISC-V CPU 的公共定义集中在 [`target/riscv/cpu.h`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/cpu.h)，类型注册、模型表和大量 realize 逻辑位于 [`target/riscv/cpu.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/cpu.c)。板级装配则从 `hw/riscv/riscv_hart.c` 与 `hw/riscv/virt.c` 进入。阅读时不要只搜 `riscv_cpu_realize` 一个名字，还要把父类 realize、加速器初始化和 vCPU 线程创建串起来，因为 QOM 的父子类回调会把一条看似连续的路径分散到几层对象中。

一颗 hart 的启动可以先压缩成下面这条逻辑链：machine 决定数量和 CPU 类型，QOM 创建 `RISCVCPU` 实例，属性系统写入配置，realize 检查 ISA 与加速器约束，通用 CPU 层登记 CPU，reset 建立体系结构初态，最后 `qemu_init_vcpu()` 让所选 accelerator 创建执行上下文。这个顺序不是某个架构的偶然写法，它把“对象能否成立”和“对象如何运行”分成了两个阶段。

## 四层结构，各自回答一个问题

`CPUState` 回答的是“QEMU 如何管理这颗可执行对象”。它含有 CPU 索引、线程与阻塞相关状态、停止和退出请求、中断请求、断点列表、运行状态，以及通用代码需要访问的类指针。设备模型向 CPU 拉高中断线，主循环暂停所有 vCPU，调试器要求单步，这些动作首先碰到的是公共层。把它称作“CPU 的全部状态”会误导读者，因为客户机能读到的大量寄存器根本不属于这里。

`CPUClass` 回答“某种目标 CPU 怎样接入公共生命周期”。类回调覆盖 reset、dump、GDB 读写、地址转换、检查是否有可执行工作等能力。公共代码可以拿着 `CPUState *` 发起操作，再由类回调进入 RISC-V 逻辑。类对象在同类型实例之间共享，实例数据则每颗 CPU 独有，这正是 QOM 区分类与实例的价值。当前代码还在 `CPUState` 中缓存 `CPUClass` 指针，提交 [`65339110b7`](https://gitlab.com/qemu-project/qemu/-/commit/65339110b7) 将这个缓存声明为 const，提交说明明确指出多个 `CPUState` 可以共享同一个 `CPUClass`。这是一条源码事实，也提醒我们，类回调表不是每颗 hart 各复制一份的运行时状态。

`RISCVCPU` 回答“这是一颗怎样的 RISC-V CPU”。它通过结构体嵌入继承 `CPUState`，再携带 RISC-V 配置、扩展属性、厂商与架构标识、PMP 或调试等目标相关信息。用户写下 `-cpu rv64,zba=true` 时，真正被调整的是这个层次上的模型配置。`RISCVCPUClass` 则在通用 `CPUClass` 之上补充模型初始化与目标约束。QEMU 使用 C 结构体嵌入和类型转换宏模拟面向对象，目的在于让设备和 CPU 类型运行时注册，并允许 machine 通过字符串选择具体类型。

`CPURISCVState` 回答“客户机此刻能观察到什么体系结构状态”。通用整数寄存器、当前程序计数器、浮点和向量状态、特权级、CSR 相关缓存、异常字段，都围绕这个环境组织。TCG 翻译器通常把 `RISCVCPU` 中的 `env` 作为目标状态入口，生成代码读写其中字段；KVM 执行时，最新寄存器可能暂时停留在内核 vCPU 对象或真实硬件中。结构体名称没变，状态所有者却变了，这就是后面必须反复检查“新鲜度”的原因。

:::: {.quick-quiz}
为什么 RISC-V CPU model 不能把所有状态都塞进通用 `CPUState`？

::: {.quick-answer}
通用结构要被全部目标架构复用，只能承载调度、线程和生命周期所需的公共状态。RISC-V 的寄存器、CSR、扩展依赖与特权规则属于架构语义，若进入 `CPUState`，公共层会被一种 ISA 绑住，其他架构的字段也会不断堆叠。分层后，公共代码通过类回调请求目标能力，目标代码再解释自己的环境。
:::
::::

## `env` 不是一份永远正确的镜像

读 TCG 代码时，`env->gpr[a->rs1]` 一类表达会让人自然地把 `env` 当成权威状态。对于纯 TCG 执行，这个理解大体成立，但仍要注意寄存器值可能被暂存在生成代码使用的 TCG 全局值或宿主寄存器中，只有在退出点按约定完成恢复后，C helper 和调试器才能看到一致状态。精确异常之所以需要 `restore_state_to_opc` 一类机制，正是因为执行中的优化表示与可报告的体系结构状态并非每一条宿主指令后都完整同步。

KVM 把距离拉得更远。`KVM_RUN` 期间，真实寄存器由内核和硬件推进，QEMU 用户态的 `CPURISCVState` 不会在每条指令之后更新。MMIO exit、调试停止、迁移保存或管理命令需要某些寄存器时，目标 KVM 代码通过 one-reg 或相应 UAPI 把状态取回；继续运行前，用户态改过的状态又要推回内核。于是一个字段至少要附带三个问题：当前所有者是谁，最近一次同步方向是什么，调用者是否已经建立了需要的同步点。

这份状态约定会直接影响实现正确性。假设设备回调在 KVM exit 后直接读取 `env` 里的任意 CSR，并推断它已经是客户机最新值，代码很可能只在 TCG 下正确。反过来，公共层若为了保险每次退出都同步全部寄存器，功能或许能跑，KVM 高频退出的成本却会显著上升。合理的接口要允许按需同步，并让调用者明确自己需要哪一类状态。

作者据此做出一个推断：`CPURISCVState` 的价值并不等于“永远保存真值”，它更像公共设备模型、迁移格式和两类加速器之间约定的数据语言。这个推断来自当前 TCG、KVM 路径的对照，不是上游提交原文。后面引用这一结论时，要保留“状态所有权随运行阶段变化”的前提。

## CPU 型号其实是一组约束

RISC-V 的模块化 ISA 让 CPU 模型比一个名称复杂得多。RV64 只是寄存器宽度，I、M、A、F、D、C、V 以及众多 Z 扩展共同决定可执行指令和 CSR；profile 与扩展之间还有蕴含和互斥关系；页表模式、PMP 项数、向量长度等属性继续收紧模型。若把型号理解成一个最终字符串，初始化代码中的依赖求解就会显得啰嗦。换成“用户请求、模型默认、规范约束、加速器能力四者求交”，路径就清楚了。

属性写入阶段允许配置，realize 阶段负责冻结并校验。这样做可以累积来自命令行和 machine 的设置，再一次性报告矛盾。某个扩展意味着另一个扩展时，QEMU 可以在配置归一化阶段补齐；规范禁止的组合则应该启动失败。对于 KVM，宿主内核能够暴露哪些扩展还会形成额外边界，QEMU 不能向客户机承诺硬件和内核无法执行的能力。TCG 的能力集合由翻译器实现决定，也不等于“规范里出现的扩展全都自动可用”。

`v11.1.0-rc0` 前的一组 RISC-V CPU 整理很能说明问题。提交 [`65dbf4bfd2`](https://gitlab.com/qemu-project/qemu/-/commit/65dbf4bfd2) 补上 G 扩展蕴含 `imafd_zicsr_zifencei` 的规则，对应邮件 Message-ID 为 [`20260528054213.678458-2-frank.chang@sifive.com`](https://lore.kernel.org/qemu-devel/20260528054213.678458-2-frank.chang@sifive.com/)。提交 [`7e55cb1581`](https://gitlab.com/qemu-project/qemu/-/commit/7e55cb1581) 又补上标准 B 扩展的 implied rule。这些上游陈述表明，扩展开关并非互不相关的布尔量；遗漏一条蕴含规则，用户看到的 CPU 特征集合就可能与规范定义不一致。

再看提交 [`e499a42786`](https://gitlab.com/qemu-project/qemu/-/commit/e499a42786) 所在的系列，代码开始复用 `isa_edata_arr[]` 创建用户属性，邮件 Message-ID [`20260512032926.1978818-14-daniel.barboza@oss.qualcomm.com`](https://lore.kernel.org/qemu-devel/20260512032926.1978818-14-daniel.barboza@oss.qualcomm.com/) 可以回到审查线程。上游提交说明指出，同一件事此前在不同位置重复实现。作者从这段演进推断，扩展元数据正在被当作单一事实来源：新增扩展时，应尽量让名称、默认值、依赖和属性暴露围绕同一份描述生成，避免 QMP 查询与 CPU 属性悄悄分叉。

## realize 阶段为什么值得单独观察

realize 不只做参数检查，它还是公共 CPU、目标模型、machine 与 accelerator 建立契约的位置。父类可能登记 CPU 和通用状态，RISC-V 层确认扩展与页表能力，TCG 层准备翻译相关配置，KVM 层探测内核能力。任何一层失败，都应在 vCPU 真正运行前释放已经建立的资源，并给出能指向用户配置的错误。这个阶段代码长，恰恰因为它承担跨层失败的收口工作。

扩展状态冻结也与翻译缓存有关。若客户机运行以后还能随意打开一项改变译码或寄存器布局的扩展，已经生成的 TB、GDB 寄存器描述、迁移状态乃至设备树 CPU 节点都可能失效。QEMU 有些属性允许运行前调整，有些状态由客户机 CSR 在运行时切换，两类变化必须分开：前者定义“这颗 CPU 有什么”，后者定义“已有能力当前怎样使用”。将能力和运行状态混用，会让 TB flags 无限膨胀，或者产生缺少失效的旧翻译。

RISC-V 页表模式也提供了好例子。CPU 模型可以声明支持哪些 `satp` mode，客户机运行时再通过 `satp` 选择当前模式。`v11.1.0-rc0` 中提交 [`109856754c`](https://gitlab.com/qemu-project/qemu/-/commit/109856754c) 在 `satp_mode < sv39` 时禁用 `svpbmt`，邮件 [`20260519114858.316532-1-daniel.barboza@oss.qualcomm.com`](https://lore.kernel.org/qemu-devel/20260519114858.316532-1-daniel.barboza@oss.qualcomm.com/) 给出了规范依据；随后提交 [`601c8494c6`](https://gitlab.com/qemu-project/qemu/-/commit/601c8494c6) 对 `svnapot` 做了同类约束。这些事实说明，CPU 属性校验会跨越“指令扩展”和“地址转换能力”两个表面上不同的区域，因为规范本来就把它们联系在一起。

## reset 不是把结构体清零

处理器复位要建立规范规定的初始特权状态、程序计数器、CSR 和中断状态，还要服从 machine 提供的 reset vector、hart ID 与固件布局。直接 `memset(env, 0)` 会抹掉由型号配置阶段确定且跨 reset 保留的数据，也无法表达某些 CSR 的固定复位值。QEMU 的 reset 框架允许父类和子类分阶段参与，CPU 模型在其中恢复可运行初态，machine 再把板级入口组合进来。

reset 还会暴露加速器边界。TCG 专属的 CSR、trigger 或中断缓存不该无条件进入公共 RISC-V reset 路径，KVM 对同一状态可能依赖内核初始化或显式寄存器写入。2026 年 7 月的提交 [`209638d448`](https://gitlab.com/qemu-project/qemu/-/commit/209638d448) 题为“filter TCG only bits in `riscv_cpu_reset_hold()`”，其邮件 Message-ID 是 [`20260703180538.3346781-18-daniel.barboza@oss.qualcomm.com`](https://lore.kernel.org/qemu-devel/20260703180538.3346781-18-daniel.barboza@oss.qualcomm.com/)。上游明确说公共 reset 中仍有大量 TCG-only 初始化，并逐项把边界筛出来。

这一系列对本书很有价值，因为它发生在目标研究锚附近，直接展示“当前布局为何这样形成”。历史代码能工作，不代表分层已经理想；KVM 功能增长后，原先藏在公共目录里的 TCG 假设才逐渐成为维护阻力。作者据此推断，判断一个函数该放公共层还是加速器目录，不能只看今天有几个调用者，还要看它读写的状态由哪个执行引擎拥有，以及另一条执行路线是否能给出相同语义。

## AccelClass 管机器，AccelOps 管运行

QEMU 的 accelerator 抽象不等于一个 `run()` 函数。选择加速器后，系统需要完成机器级初始化、检查兼容性、建立内存监听，再为每颗 vCPU 创建线程和执行资源；运行期间还要处理 kick、暂停、同步、调试和统计。生命周期跨度很大，如果全部塞进一张回调表，machine 级只调用一次的操作会和每 vCPU 高频操作混在一起，接口很快失去边界。

在当前源码中，[`include/qemu/accel.h`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/include/qemu/accel.h)、`accel/accel-system.c`、`include/accel/accel-ops.h` 与 `include/accel/accel-cpu-ops.h` 是理解这层关系的入口。`AccelClass` 更靠近加速器对象和 machine 生命周期，`AccelOpsClass` 聚合系统执行所需的操作，CPU 相关操作又被继续整理。名称在历史上调整过，不能拿旧文章里的头文件名直接套当前版本。

2025 年的一串提交把这种分工写进目录和命名：[`9d01d2e86d`](https://gitlab.com/qemu-project/qemu/-/commit/9d01d2e86d) 让 `AccelState` 显式传给 `AccelClass::init_machine()`，避免初始化函数再依赖 `current_accel()`；[`487b25c9d9`](https://gitlab.com/qemu-project/qemu/-/commit/487b25c9d9) 让 `AccelClass` 保留 `AccelOpsClass` 引用；[`05927e9dc9`](https://gitlab.com/qemu-project/qemu/-/commit/05927e9dc9) 将 `system/accel-ops.h` 改名为 `accel/accel-cpu-ops.h`，提交说明指出这些 handler 并非只有 system emulation 使用。这里的上游陈述很明确：重构目标包括减少隐式全局状态、让接口名称匹配真实使用范围。

作者进一步推断，这类重构并不追求“抽象越多越好”。显式传递 `AccelState` 会让依赖可见，便于多实例和测试；而热路径仍然需要紧凑回调，不能为了形式统一把每次访存都路由到通用对象系统。QEMU 常见的工程选择，是在初始化和控制平面使用可扩展对象边界，在执行与访存数据面保留静态内联、目标专属结构和缓存。

:::: {.quick-quiz}
加速器抽象为什么不只提供一个 `run()` 回调？

::: {.quick-answer}
CPU 执行还涉及 machine 初始化、每 vCPU 创建与销毁、kick、暂停、状态同步、中断、内存拓扑变化、调试和错误回收。只有 `run()`，公共代码仍会到处判断 `tcg_enabled()` 或 `kvm_enabled()`，状态所有权也无法表达。分开的生命周期接口让一次性控制操作与高频执行操作各自拥有清楚的调用约束。
:::
::::

## TCGCPUOps 把目标语义送进翻译器

TCG 是通用动态翻译框架，但它不知道 RISC-V 的 PC 在哪里、什么状态改变翻译结果、异常后怎样恢复目标状态。目标代码通过 `TCGCPUOps` 一类接口提供这些答案，包括初始化目标翻译状态、取得 TB key、同步 PC、处理中断、执行目标特有的 TLB fill 等。公共 TCG 执行循环因此可以复用，ISA 细节仍留在 `target/riscv/tcg/`。

这层边界附近最常见的误读，是把“通用 TCG”理解成“目标无关代码不需要知道 CPU”。实际做法更务实：公共层定义流程和数据结构，目标层提供最少但不可替代的语义。TB 查找需要 PC 和 flags，异常退出需要把宿主执行点还原成客户机指令，SoftMMU miss 需要目标页表规则；这些都不可能靠一个完全不透明的 `execute()` 完成。

当前研究锚刚完成了一次醒目的目录整理。提交 [`d45b9bc655`](https://gitlab.com/qemu-project/qemu/-/commit/d45b9bc655) 将 RISC-V 的 TCG-only 文件移入 `target/riscv/tcg/`，上游提交说明直言，过去有太多只属于 TCG 的代码留在 `target/riscv/`，移动它们既清理目录，也能暴露“埋在 TCG helper 中、其实应被加速器共享”的代码。对应邮件 [`20260703180538.3346781-5-daniel.barboza@oss.qualcomm.com`](https://lore.kernel.org/qemu-devel/20260703180538.3346781-5-daniel.barboza@oss.qualcomm.com/) 还能看到同一系列的上下文。

系列没有机械地一次搬空。提交说明特意留下部分文件，原因是它们需要更谨慎地拆开，避免破坏 KVM。随后 `riscv_cpu_update_mip`、NMI、custom CSR、debug helper、AIA 回调等逐项移动或加门。这样的演进比最终目录更能解释设计：文件位置只是结果，真正的审查问题是某段逻辑是否读取 TCG 私有状态、KVM 是否需要同等能力、调用者来自 CPU 还是设备。书中看到 `tcg/` 子目录时，应把它理解为状态所有权审计后的边界，而非简单整理文件。

## KVMCPU 路径为什么更强调同步

RISC-V KVM 目标代码位于 [`target/riscv/kvm/kvm-cpu.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c)。它要把 QEMU CPU 属性映射到内核能力，创建 vCPU，通过 KVM RISC-V 的寄存器接口读写状态，并处理用户空间需要完成的 exit。这里仍然使用公共 `RISCVCPU`，因为 machine、设备树、GDB、迁移和管理层要面对同一种客户机 CPU；执行语义则尽可能交给内核和硬件。

KVM 的边界还受宿主环境限制。没有 RISC-V H 扩展或内核没有对应 KVM capability，`-accel kvm` 不能靠软件翻译补齐；某个宿主支持的扩展集合也可能小于 QEMU TCG。CPU realize 必须把这些差异尽早转成诊断。若静默降级，客户机读到的 ISA 字符串、设备树和实际执行能力会不一致，故障通常拖到内核启用某项特性才出现。

另一方面，公共 CPU 层不能充斥 KVM ioctl。设备模型需要表达“注入中断”“请求停止”“同步状态”，目标 KVM 层再决定是 one-reg、run 结构字段还是 irqchip 路径。抽象允许内核 UAPI 演进，也让 TCG 以自己的方式提供同一上层语义。它并不保证两条路径每个内部步骤相同，保证的是客户机可观察结果和管理接口能够对齐。

## vCPU 线程与 kick：执行不是孤岛

CPU realize 完成以后，`qemu_init_vcpu()` 让 accelerator 建立 vCPU 执行线程。MTTCG 通常每颗 vCPU 有自己的线程，单线程 round-robin TCG 则按不同调度方式复用执行上下文，KVM 也让每个 vCPU 围绕 `KVM_RUN` 循环。无论哪条路径，线程都要响应暂停、关机、调试、TLB flush、跨 CPU work 与设备中断，不能一直沉在客户机代码里。

kick 是把外部请求送到 vCPU 安全点的手段之一。调用者先发布请求状态，再唤醒或打断 vCPU，执行线程观察到请求后退出当前运行段。这里的先后关系涉及内存序：若唤醒可见、请求字段却仍不可见，vCPU 可能醒来后继续睡，形成罕见的挂起。提交 [`ac6c8a390b`](https://gitlab.com/qemu-project/qemu/-/commit/ac6c8a390b) 为跨线程 `exit_request` 使用 store-release/load-acquire，提交说明明确承认此前可能依赖 BQL 获得间接保护，但关系“不够清楚”，因而统一为显式内存序。

随后提交 [`9cf342b491`](https://gitlab.com/qemu-project/qemu/-/commit/9cf342b491) 为 TCG 建立 thread-kick 函数，既服务多线程模式，也把 round-robin 情况收拢到统一操作中。上游陈述是为未来让 `cpu_exit()` 可供所有 accelerator 使用做准备。作者从两条提交的组合推断，kick 的抽象目标不只是去掉重复代码，它还把“发布退出请求—打断运行线程”绑定成可审查的并发协议，减少调用者只做一半动作的机会。

## 中断请求为什么跨越三层

设备把 IRQ line 拉高，并不等于 CPU 立即跳入 trap vector。板级中断控制器先更新 pending 状态，公共 CPU 层通过中断请求或 work 判定唤醒 vCPU，RISC-V 目标逻辑再结合 `mip`、`mie`、delegation、特权级和虚拟化状态判断是否接受。TCG 在软件中完成整个判定；KVM 可能把部分中断控制和注入交给内核。这里同时存在设备电平、QEMU 调度请求和体系结构 CSR 三种状态，混成一个布尔值会丢失信息。

`has_work` 回调尤其容易被低估。halted CPU 是否应被唤醒，取决于目标架构是否存在可接受事件；公共主循环不能只看 `interrupt_request != 0`，因为某些 pending 事件尚被屏蔽，某些跨线程工作又不属于客户机中断。2026 年 7 月的 RISC-V 分层系列把若干 IRQ pending helper 移回公共 CPU 文件，提交 [`e49b1e25fa`](https://gitlab.com/qemu-project/qemu/-/commit/e49b1e25fa) 说明这些 helper 被 `riscv_cpu_has_work()` 使用，而该函数同时服务 KVM 关心的中断控制器文件。这个上游理由直接反驳了“涉及 IRQ 就一律属于 TCG helper”的简单分类。

作者在这里采用一条判断规则：看函数表达的是客户机体系结构事实，还是某个执行引擎实现该事实的办法。`mie` 与 pending 关系属于 RISC-V 语义，两种 accelerator 都需要；把 pending 状态写进哪份软件缓存，或者怎样通过 ioctl 注入，则属于执行引擎。这个规则不是绝对目录规范，但用于审查新代码很有效。

## 调试、dump 与迁移会迫使边界显形

正常执行可以依靠缓存和延迟同步，调试停止却要求给出准确寄存器；迁移保存要求形成可传输的一致快照；崩溃 dump 又希望在错误路径少做额外工作。这三个场景会把隐含状态所有权全部拉到台面上。若某个 CSR 只在 TCG helper 中存在，KVM dump 是否应展示它；若 KVM 内核持有最新寄存器，迁移何时拉回；若扩展属性改变 GDB XML，客户端怎样保持兼容，这些都不能由通用 `CPUState` 自动解决。

提交 [`5fa9e8597b`](https://gitlab.com/qemu-project/qemu/-/commit/5fa9e8597b) 处理 `riscv_cpu_dump_state` 中的 TCG 位，邮件 [`20260703180538.3346781-16-daniel.barboza@oss.qualcomm.com`](https://lore.kernel.org/qemu-devel/20260703180538.3346781-16-daniel.barboza@oss.qualcomm.com/) 的提交说明指出 `riscv_dump_csr()` 是 TCG-only，但 KVM 未来仍要实现对应能力，所以先用 `tcg_enabled()` 隔开。这里没有假装两个加速器已经完全对称，而是让当前能力边界显式可见，并留下可以继续演进的位置。

迁移还要求区分 CPU 型号配置和运行状态。型号决定目的端是否能接收这台虚拟机，运行状态决定恢复后从哪里继续。只保存 `env` 的内存镜像既会把内部缓存当 ABI，也无法覆盖 KVM 内核状态。QEMU 通过 VMState 描述稳定字段和版本条件，目标代码在保存前同步需要的数据。后文讨论迁移时会继续使用本章的三个问题：状态所有者是谁、何时同步、哪些字段属于外部兼容契约。

## 性能与可维护性之间没有免费抽象

把 TCG 和 KVM 统一到公共 CPU 模型，最大的收益是 machine 与设备不必复制，管理接口也能共享。代价是接口设计必须处理能力不对称，状态同步也可能进入热点。一个看起来整洁的 getter，如果内部每次都触发 KVM ioctl，放进高频 MMIO 路径会非常昂贵；直接读取 `env` 虽快，却可能拿到旧值。工程实现通常让调用者选择同步级别，或只在明确的退出、调试和迁移边界同步。

公共字段的数量要服从协作需要。中断、停止和线程状态若完全藏在 accelerator 私有对象，主循环与设备将无法以统一方式协调；目标寄存器若全放公共层，架构扩展会污染核心结构。QEMU 的分层在共享控制面和专属数据面之间寻找稳定线，无意追求类型理论上的纯粹。历史重构频繁移动头文件和 helper，恰好说明这条线会随新 accelerator、新架构能力和并发要求修正。

阅读源码时，可以用“变化频率”帮助判断。ISA 扩展列表随规范演进，适合由目标元数据驱动；vCPU kick 的并发语义跨架构复用，适合公共 accelerator 接口；一条 RISC-V 指令如何翻译，变化紧跟目标实现，应该留在 `target/riscv/tcg/`；KVM one-reg 编号由 UAPI 约束，放在 KVM 目标层。边界清楚后，提交影响范围往往也更可预测。

## 顺着 QOM 类型注册读一遍 CPU 模型

`RISCVCPU` 并不是一个单独注册的最终型号。目标代码先注册抽象或基础类型，再为 `rv64`、`max`、厂商核心等模型提供 type info 和 instance/class init。class init 安装公共 CPU 回调，具体型号的 instance init 填默认扩展与参数，用户属性随后覆盖，realize 再统一校验。把这几步混成“构造函数”，会误判某个默认值到底能否被命令行覆盖。

阅读一个型号时，可以做三列记录。第一列是类型注册时固定、用户不能改变的身份，例如模型名与父类型；第二列是 instance init 给出的默认能力，例如默认启用的扩展；第三列是 realize 后从宿主或加速器探测得到的最终限制。相同字段在不同阶段被写，不一定是重复，有时代表“候选值逐步收敛”。真正值得警惕的是多个阶段各维护一份扩展列表，却没有共同元数据或覆盖顺序说明。

RISC-V 的 `max` CPU 适合功能探索，不应直接等同于稳定迁移型号。它会随 QEMU 新增已实现扩展而增长，今天保存的客户机能力，未来版本可能不同。具名 CPU 模型则更接近兼容契约，仍要看 machine version 与属性默认是否固定。本书实验若使用 `max`，必须记录完整扩展开关；需要可重复迁移时，应显式选择模型和属性，不用“当前最大集合”代替配置。

类型系统还允许 board 只持有 `CPUState *` 或 `DeviceState *`，运行时通过 dynamic cast 进入 `RISCVCPU`。这为通用 machine helper 带来复用，也让错误类型在运行时暴露。类型转换宏通常带断言，热路径不会随意反复做字符串查找；初始化阶段的动态性与执行阶段的静态结构，再次体现控制面和数据面的不同取向。

## realize 的失败路径也是接口的一部分

启动一台有八颗 hart 的虚拟机，前四颗已经创建，第五颗因扩展组合或 KVM capability 失败，QEMU 必须释放先前对象、线程和加速器资源。只测试一颗 CPU 的成功路径，很难发现部分 realize 后的泄漏。QOM 的 realize/unrealize 与父类 chaining 为此提供框架，目标实现仍需记录自己完成到哪一步。

错误诊断应靠近约束来源。扩展依赖不成立，应指出 CPU 属性；KVM 不支持请求扩展，应指出 accelerator 与宿主能力；hart ID 冲突，应指向 machine 装配。统一返回“CPU realize failed”虽然省代码，用户只能靠 trace 或 GDB找原因。上游 review 常要求使用 `Error **errp` 传播上下文，就是为了让对象层层装配仍保留最初原因。

unrealize 不能假定虚拟机已经完整运行。动态 debug trigger数组的系列先加入 CPU unrealize callback，再进行分配方式变更，正是典型顺序：先建立资源回收点，再引入新生命周期。提交 [`820552a92e`](https://gitlab.com/qemu-project/qemu/-/commit/820552a92e) 对应邮件 [`20260617131710.1855353-2-daniel.barboza@oss.qualcomm.com`](https://lore.kernel.org/qemu-devel/20260617131710.1855353-2-daniel.barboza@oss.qualcomm.com/)。上游陈述是为下一提交动态分配 trigger数组做准备，作者推断则是“资源模型改变应先补齐逆向路径”，这是可以迁移到设备模型的审查习惯。

## hart ID、CPU index 与线程身份不要混用

RISC-V hart ID 是客户机可见的体系结构身份，固件和设备树用它描述处理器。`CPUState::cpu_index` 是 QEMU管理多个CPU的内部索引，vCPU thread还有宿主线程ID。这三个数在简单 `virt -smp 4` 中可能恰好同序，不能据此视为同一个字段。

machine 可以构造稀疏hart ID或多socket/cluster拓扑，管理层CPU index仍可能连续。SBI发送IPI按hart mask工作，QMP查询可能按CPU index定位，宿主性能工具又按thread ID记录。实验时若日志只写“CPU 2”，必须注明是哪种身份，否则跨层对齐会错。

`riscv_hart_array` 的职责之一，是让板级模型按数量创建hart并设置对应属性。设备树CPU节点、interrupt controller context和reset vector随后引用这些身份。CPU公共层不应自行猜板级hart布局，这也是machine与CPU model分开的理由。

线程迁移或重新创建不会改变hart ID。反过来，热插拔或对象unrealize可能让某个CPU index生命周期结束。把host thread绑定策略写进客户机拓扑，会让调度优化污染架构接口；把hart ID仅当数组下标，又会限制非连续平台模型。

## 状态所有权可以做成一张时间表

为了避免“TCG直接、KVM同步”停留在口号，可以按运行阶段列出具体状态。CPU尚未启动时，型号属性和reset初值由QEMU对象持有；TCG进入TB后，GPR值可能在宿主寄存器和 `env` 间按生成代码约定流动；TB正常退出后，供C代码使用的必要状态完成同步；KVM进入 `KVM_RUN` 后，通用寄存器和大部分CSR由内核/硬件推进；发生exit时，run结构只自动带回UAPI定义的信息，其余寄存器按需求读取。

中断状态又不同。设备线和控制器pending始终在设备模型或内核irqchip相应位置，TCG的 `mip` 软件视图由目标代码更新，KVM可能把注入交给内核。迁移前要求形成统一快照，调试停止只需要调试器将读取的集合，普通MMIO exit可能根本不需要拉回全部CSR。所谓同步点，实际带有“为了哪个消费者”的范围。

可以用脏位或同步函数减少ioctl，却要防止双向覆盖。用户态修改PC准备单步，若继续运行前误用“从内核同步到用户态”，修改会被旧内核值冲掉；内核刚执行后，若无条件“用户态写回内核”，客户机进度会倒退。接口命名应体现 get/put方向，调用顺序由run state保证。

TCG也有相似问题，只是边界藏在JIT内。helper声明读写哪些global、TB退出是否恢复PC、异常回溯如何找到当前op，决定 `env`何时可读。把KVM的新鲜度问题讲清，再回看TCG，会发现“用户态字段始终最新”同样需要限定在安全点。

## CPU reset 分为冷启动、系统复位和局部状态

虚拟机启动时CPU第一次进入reset，管理层发出system_reset时所有设备按reset domain重新初始化，某些设备或hart还可能接受局部reset。客户机软件看到的效果由平台规定，QEMU reset框架则要安排依赖顺序。CPU先清状态、固件入口再建立，还是板级设备先复位，会影响中断线和启动PC。

RISC-V CPU reset应保留型号配置，清除运行产生的CSR与reservation，设置初始privilege和reset vector。扩展能力数组属于“这颗CPU是什么”，不能每次reset回到编译默认；`mstatus`、pending exception属于“它现在怎样”，需要重建。区分配置和状态也让迁移格式更清楚。

TCG reset还要使旧TB不能按旧状态继续执行。若reset改变PC和特权，下一次lookup自然使用新key；某些全局状态或trigger变化还需flush。KVM reset则要把规定寄存器写入内核vCPU，不能只改 `env`。提交 `209638d448` 过滤公共reset中的TCG-only位，正是在逐项建立这些边界。

reset期间设备IRQ可能仍在变化。CPU reset代码如果清pending后，level-triggered设备线保持高，连接层应重新反映；否则客户机启动后丢中断。反过来，旧软件pending不应跨system reset幽灵般出现。CPU、中断控制器和machine reset顺序需要实验覆盖，单独调用CPU reset unit test不够。

## `has_work` 是电源状态和中断语义的交点

`has_work` 看似只回答“CPU要不要醒”，实际连接WFI、halted线程、interrupt pending与管理work。RISC-V可能有pending但被当前enable屏蔽的中断，WFI语义又允许在特定条件下继续；QEMU还要处理不属于客户机中断的stop和queued work。公共线程循环调用目标 `has_work`，目标函数不能替代管理请求检查。

高频轮询所有CSR会增加halt/wakeup成本，过度缓存则要求所有pending变化及时更新。`riscv_cpu_has_work()` 使用目标IRQ helper，设备拉线后通用interrupt request负责kick。当前拆分系列把真正共享的pending判断留在公共RISC-V层，把软件 `mip`更新保留TCG边界，形成一条可解释路径。

调试halt和客户机WFI也不能共用一个原因位。前者由管理层控制，恢复需要continue命令；后者有可接受事件就应醒。若只看 `halted=true`，管理线程可能意外让调试停止的CPU因timer继续执行。runstate与CPU stop状态共同约束线程循环。

## 加速器能力报告为何属于控制面

用户需要知道当前选择的accelerator、可用能力和统计，但查询不应让machine代码直接读取TCG或KVM私有结构。2025 年提交 [`c10eb74010`](https://gitlab.com/qemu-project/qemu/-/commit/c10eb74010) 增加HMP `info accel`，通过 `AccelOpsClass::get_stats()`分派；此前 [`1861993f1f`](https://gitlab.com/qemu-project/qemu/-/commit/1861993f1f) 加入实验性QMP `x-accel-stats`。上游事实是统计入口走accelerator操作类，接口前缀也明确其不稳定性。

统计查询可能跨vCPU线程读取计数，需要原子快照或安全点，不能为展示方便破坏热路径。某些计数可近似，管理接口要说明；迁移兼容所需状态则不能近似。把telemetry与迁移状态分开，可避免为了统计字段建立昂贵同步。

作者推断，`get_stats` 的位置进一步验证AccelOps承担运行相关能力，而AccelClass偏机器生命周期。这个推断来自当前接口布局；未来上游可能继续重命名，书中应以功能和调用阶段为主，不把类名当永恒设计。

## 反向审查：如果取消 accelerator 抽象会怎样

设想machine在创建CPU时直接判断 `if (kvm_enabled())`，设备注入中断时也各写一套分支。短期少一层回调，长期每项新功能都要在machine、CPU、GDB、迁移中复制判断。第三种accelerator加入时，组合继续增长；RISC-V扩展支持不对称又让分支嵌套。

另一个极端，是把所有操作放进完全统一的虚函数，连每次寄存器读和内存访问都动态分派。接口表会巨大，TCG内联优化受阻，KVM ioctl成本也被隐藏。当前设计允许控制面统一，数据面专属，并用明确同步函数跨边界。形式上少了一点整齐，却更符合虚拟化执行的成本结构。

当 `tcg_enabled()` 或 `kvm_enabled()` 判断四处散落，又说不清状态所有权时，坏味道才真正出现。reset暂时用 `tcg_enabled()`隔开尚未重构能力，可以接受；公共设备热路径反复判断并直接碰私有字段，通常意味着接口缺失。历史邮件能帮助区分过渡代码和有意设计。

## 为源码改动设计最小回归面

修改CPU属性依赖，至少测试 `-cpu help`、合法/非法组合、设备树ISA字符串和迁移配置；修改reset，测试冷启动、system reset、多hart与两种accelerator；修改kick或interrupt，测试运行、WFI、暂停和debug；移动TCG helper，至少构建TCG-only与KVM-enabled配置，防止头文件依赖反向渗漏。

静态构建矩阵很重要。开发者机器若只启用TCG，公共文件无意引用TCG符号不会暴露；只在KVM宿主运行，又可能漏TCG translator。`d45b9bc655` 系列一边搬文件、一边留下需要谨慎处理的公共调用，正是因为编译配置组合能揭示边界。

运行测试也应验证失败路径。请求宿主不支持扩展时应启动失败，不应静默删能力；暂停halted CPU应及时完成；调试器读取寄存器应触发正确同步；reset后旧TB或旧KVM状态不能继续。把这些用例与状态所有权表对应，回归范围会比“启动Linux成功”更有针对性。

## 一次启动调用链的逐段核对

从 `virt_machine_init()` 开始，先确认machine怎样根据socket、cluster、core与thread参数计算hart数量，再进入hart array创建CPU。这里提供的是板级拓扑和启动地址，CPU型号自身不应反向遍历machine猜这些信息。设备树CPU节点稍后根据已realize对象输出，若realize失败，不应留下半个节点。

QOM创建后，instance init只建立可配置对象。命令行property由对象属性系统写入，machine也可在realize前设置默认。此时打印CPU状态，看到的只是候选配置；只有扩展dependency、accelerator capability和目标检查完成，才是客户机最终能力。测试脚本应把“property accepted”和“CPU realized”分成两个断言。

父类 `cpu_exec_realizefn` 负责通用登记，RISC-V realize负责ISA，TCG/KVM初始化再建立执行资源。调用次序可能随版本重构，审查重点是失败回滚和前置条件：加速器不应在CPU扩展尚可变时缓存能力，公共CPU也不应在目标拒绝后继续出现在遍历列表。

reset callback第一次运行后，PC指向machine提供的reset vector，privilege与CSR回到规范初态。设备模型此时可能尚未让固件可执行，machine完整init结束才启动vCPU。把“CPU对象realized”误作“线程已经执行”，调试断点会放错阶段。

`qemu_init_vcpu()` 进入accelerator thread创建，线程启动后通常先等待全局runstate，而不是立即跑客户机。管理层完成machine初始化、reset和incoming migration后再放行。这个等待点保证迁移目的端可以先装载CPU状态，避免reset初值抢跑。

第一次 `cpu_exec()` 或 `KVM_RUN` 是状态所有权真正切换的分界。调用前可由用户态设置，调用中执行引擎推进，返回后按exit类型同步。时序图若只画函数嵌套而不标所有权切换，无法解释为何同一 `env`字段在断点处有时旧。

## 版本化 CPU 模型的兼容责任

QEMU升级会实现更多RISC-V扩展，默认CPU若自动增长，客户机迁移到旧端会失败，软件也可能按新能力选择代码。machine type版本和具名CPU模型用于稳定暴露集合，`max`更多承担开发测试。书中目标 `v11.1.0` 不是说所有未来QEMU都应呈现相同 `max`。

兼容属性可以在新machine版本调整默认，在旧machine版本保留历史行为。CPU扩展本身ratified也不代表可无条件加入旧模型，迁移VMState、设备树字符串和KVM目的端能力都要考虑。工程审查常宁愿要求用户显式打开新能力，也不静默改变长期模型。

KVM下兼容又受宿主硬件限制。源宿主有扩展、目的宿主没有，QEMU模型名字相同也不能迁移。管理栈需要基线CPU或能力交集，QEMU启动时拒绝不满足配置。静默模拟缺失的一两条指令会把硬件虚拟化与TCG混合，状态和性能边界都不可控。

TCG可以实现宿主没有的RISC-V扩展，仍要保证迁移版本。helper内部数据结构不应直接成为VMState，保存架构可见状态与必要版本字段，目的端再重建缓存。CPU模型、加速器和迁移是三条相交但不同的兼容线。

## 一份可执行的状态所有权检查表

新增RISC-V CPU字段时，先分类为型号配置、架构状态、执行缓存、设备连接或调试状态。型号配置决定属性与兼容；架构状态考虑reset、GDB、dump和迁移；执行缓存通常不迁移，却需在reset和状态写后重建；设备连接由machine/QOM拥有；调试状态还要区分客户机trigger与外部GDB。

然后逐accelerator回答谁在运行时更新。TCG若由生成代码直接写，要创建TCG global或helper同步；KVM若由内核持有，要找到UAPI get/put和capability；两边都不用的公共字段可能是冗余。任何“先放env，后面再说”的字段都会让用户态读到似是而非的副本。

再列动态变化点：CSR指令、trap、reset、migration load、GDB写寄存器、machine热插拔。每个变化后，哪些TB、TLB、KVM寄存器或设备派生状态失效。缓存更新遗漏通常不会在字段写瞬间出错，而在下一次命中旧路径时出现。

最后列观测者：客户机指令、QMP/HMP、GDB、migration、dump和trace。不同观测者需要的同步范围不同，接口不应为低频dump拖慢每次执行，也不能给管理层返回未标注的旧值。把这张表放进patch cover letter，reviewer更容易验证边界。

## 从本章过渡到两条执行主线

TCG篇会假定 `RISCVCPU` 已realize，直接取得 `DisasContext`、TB state和软件MMU；硬件虚拟化篇会假定同一个CPU模型已与宿主capability求交，通过KVM UAPI创建vCPU。两边都依赖本章的扩展集合、reset和interrupt连接。

对照时保持相同观察点：第一条指令在哪里执行，PC最新值在哪里，MMIO如何退出，中断由谁判断，调试如何停，迁移怎样取状态。不要用“TCG全软件、KVM全硬件”结束分析，设备和管理控制面一直在QEMU用户态汇合。

本章建立的事实边界也要延续。当前源码路径和调用是事实，commit正文解释的重构目的属于上游陈述，状态所有权表和“控制面/数据面”是作者归纳。后面发现反例时更新归纳，不改写历史证据。

## 阅读复核：别让类型图替代运行时序

画完 `CPUState -> RISCVCPU -> CPURISCVState` 的结构图，还要任选一个动作沿时序验证。比如GDB改PC：管理线程先让vCPU停止，TCG在安全点恢复状态或KVM从内核取回，GDB写入公共RISC-V表示，恢复前accelerator把修改送到真正执行位置，旧TB key或KVM运行状态随之更新。任何一步缺失，类型继承再整齐也无助于正确。

再选设备中断做反向验证。UART或IMSIC产生事件，machine连接把它送CPU，公共线程机制负责唤醒，TCG软件pending或KVM注入负责执行引擎，RISC-V privilege规则最终选择trap。若源码出现设备直接写 `env->pc` 或公共machine直接发KVM ioctl，就是边界异常，应查历史说明。

最后选失败路径：请求一个TCG已实现、宿主KVM不支持的扩展。CPU型号层应给出一致客户机承诺，KVM realize明确拒绝，TCG可以成功；管理层不应看到同一命令静默启动两种不同ISA。这个用例把能力、accelerator和错误传播三条线放在一起。

完成三条时序后，本章抽象才从类名变成可执行合同。后续遇到新字段、新扩展或目录搬迁，都可用状态所有者、同步点、观测者重新定位，不依赖某个版本恰好的文件布局。

还有一个容易遗漏的检查：同一动作在unrealized、stopped、running三种阶段是否合法。属性只应在realize前写，寄存器同步通常要求stopped，kick只对已有线程有意义。接口若没有阶段前置条件，调用者会在偶发启动/销毁窗口碰到空线程或半配置CPU。把阶段写进注释与断言，错误会从随机崩溃变成清晰诊断。

因此，CPU抽象的质量不只看回调数量，还看错误调用能否尽早失败、正确调用是否避免无谓同步。这个尺度会贯穿后续加速器对照。

:::: {.quick-quiz}
为什么同一个 `CPURISCVState` 字段在 TCG 和 KVM 下可能具有不同的“新鲜度”？

::: {.quick-answer}
TCG 通常直接围绕用户态环境生成和执行代码，但执行中的值仍可能暂存在宿主寄存器，只有约定的退出点才形成可供 C 代码读取的一致状态。KVM 运行时的最新寄存器主要由内核 vCPU 与硬件持有，用户态字段只有在显式 get-reg、退出同步或迁移同步后才可靠。调用者必须先确认所有权与同步时机。
:::
::::

## 从 Git 与邮件列表重建分层动机

本章采用的研究方法可以复用到后面各章。先固定事实锚：目标版本是 QEMU `v11.1.0`，当前写作使用 `v11.1.0-rc0` 的 `eca2c16212ef9dcb0871de39bb9d1c2efebe76be`。随后从当前调用关系提出问题，例如“为何 debug helper 在 `tcg/`”“为何 `has_work` 又留在公共层”，再用 `git log --follow`、`git blame` 和提交正文寻找引入或搬迁原因。最后到 qemu-devel 线程核对 patch 版本、reviewer 的反对意见和最终取舍。

事实、上游陈述和作者推断要分开写。事实是 `d45b9bc655` 把文件移入 `target/riscv/tcg/`；上游陈述是提交说明希望清理 TCG-only 代码，并暴露被 helper 掩盖的公共逻辑；作者推断则是“目录整理实际承担了一次状态所有权审计”。前两项可以由源码和邮件直接验证，第三项是对一串改动的解释，读者完全可以根据证据提出不同判断。

邮件列表还帮助我们看到最终提交没有保留的信息。一个系列从 v1 到 vN，可能因 KVM 构建失败而拆分，因 reviewer 指出命名误导而改头文件，或因迁移兼容性而留下桥接函数。只看最终树会误以为方案从一开始就很整齐。工程设计的价值恰恰藏在这些被否决的捷径中。

::: {.source-path}
本章固定源码入口为 `include/hw/core/cpu.h`、`target/riscv/cpu.h`、`target/riscv/cpu.c`、`target/riscv/tcg/tcg-cpu.c`、`target/riscv/kvm/kvm-cpu.c`、`include/qemu/accel.h`、`include/accel/accel-ops.h`、`accel/accel-system.c` 与 `system/cpus.c`。所有源码和提交链接均指向 QEMU 官方 GitLab；邮件证据使用 qemu-devel 的 Message-ID 归档。
:::

## 实验：比较两种 RISC-V CPU 模型配置

::: {.hands-on}
实验名称：`compare-riscv-cpu-models`。使用英文手册 [`compare-riscv-cpu-models`](../experiments/part-01-system-foundations/chapter-06-cpu-and-accelerator-models/compare-riscv-cpu-models/README.md)。先用 `qemu-system-riscv64 -cpu help` 保存可用型号，再选择通用 RV64 型号，分别查询默认扩展、显式关闭一项被其他扩展蕴含的能力、设置不合法页表能力。记录 QEMU 的属性归一化结果与启动错误，并在 `target/riscv/tcg/tcg-cpu.c` 中标出模型默认、implied rule、realize 校验三个阶段。实验报告必须区分命令行请求和最终客户机可见能力，不能只截图一条成功启动日志。
:::

这个实验关注“型号是一组约束”。建议把每次命令、QEMU 完整版本、宿主架构和预期结果写入报告，随后用 `git show 65dbf4bfd2` 对照 G 扩展蕴含规则。若当前发行构建尚未带到目标提交，应明确记录差异，不用手工修改结果去迎合书稿。

## 实验：画出 accelerator contract

::: {.hands-on}
实验名称：`inspect-accelerator-contract`。使用英文手册 [`inspect-accelerator-contract`](../experiments/part-01-system-foundations/chapter-06-cpu-and-accelerator-models/inspect-accelerator-contract/README.md)。在同一份 `riscv64` QEMU 源码上准备 TCG 环境，并在具备 RISC-V H 扩展与 KVM 的宿主上补做 KVM 路径；若宿主不具备 KVM，只做静态调用图并把限制写清。跟踪 CPU 对象创建、realize、reset、`qemu_init_vcpu()`、第一次进入执行引擎和一次退出，输出两张时序图。公共节点、TCG 专属节点、KVM 专属节点分别标色，每个跨层箭头都注明状态所有者和同步方向。
:::

实验不能用函数名堆成一棵巨树。至少选整数寄存器、PC、中断 pending 三类状态，回答它们在执行前、执行中和退出后的最新副本在哪里。若能运行 KVM，可在一次调试停止前后读取寄存器，验证同步点；不能运行时，则以 UAPI 调用点和源码注释形成静态证据，并明确它不是动态验证。

## 实验结果怎样反证设计理解

一份有价值的实验记录，应允许结论失败。比如我们预期某个扩展会由 implied rule 自动启用，实际命令却报错，先核对使用的 QEMU 版本、CPU 型号和 accelerator，再检查该规则是否只在 TCG 模型生效。又如静态调用图显示 `riscv_cpu_has_work()` 位于公共文件，不能据此宣布它与 TCG 无关，还要看它调用的 helper 与状态来源。

实验数据也不要拿一次耗时比较 TCG 和 KVM。两者的目标和运行条件不同，本章测试的是抽象边界，不是性能排名。真正要核对的是对象是否相同、配置何处收敛、状态何时跨边界、失败在何时报告。性能问题留到掌握 TB、SoftMMU 和 KVM exit 后再讨论，结论会可靠得多。

## 小结

CPU 模型定义客户机看到的处理器，accelerator 决定它在哪里执行，以及运行期间谁拥有最新状态。`CPUState` 管公共生命周期，`RISCVCPU` 与 `CPURISCVState` 承载 RISC-V 模型和体系结构环境，`AccelClass`、运行操作与目标专属接口再把 TCG、KVM 接到同一台 machine 上。

当前分层不是静止的。`v11.1.0-rc0` 附近那组 RISC-V TCG 文件搬迁，展示了上游如何沿 KVM 需求重新审计公共代码，逐步拆出真正共享的架构语义。带着状态所有权、同步点和能力约束这三条线，下一章进入 Translation Block 时，就不会把 TCG 当成一个孤立的“翻译库”，而会看到它怎样接管这颗公共 RISC-V CPU 的执行。
