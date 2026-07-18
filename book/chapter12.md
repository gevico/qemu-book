# RISC-V H 扩展的硬件虚拟化原理

TCG 与硬件虚拟化不是同一条执行链上的“慢速模式”和“快速模式”。TCG 把客户机指令翻译成宿主指令，并在 QEMU 内部实现特权架构；KVM 则让宿主处理器直接执行大部分客户机指令，由 Linux 内核在必要时接管 trap、二阶段地址转换和中断注入。两者服务于同一台 RISC-V `virt` 机器，却把 CPU 状态放在完全不同的位置。理解这种分工之前，先要把 H 扩展自身讲清楚。

本章以 `riscv64` 为主线。全书目标版本是 QEMU `v11.1.0`；在正式标签发布前，源码论证固定在 `v11.1.0-rc0`，即提交 [`eca2c16212ef9dcb0871de39bb9d1c2efebe76be`](https://gitlab.com/qemu-project/qemu/-/commit/eca2c16212ef9dcb0871de39bb9d1c2efebe76be)。正文使用四类标记：规范直接规定的行为写作“规范事实”，固定标签中能逐行确认的实现写作“源码事实”，提交说明或邮件作者明确表达的理由写作“上游陈述”，由代码、历史和实验共同支持但上游没有直接下结论的分析写作“强推断”。尚缺内核、硬件或测试闭环的能力一律标成“待验证”，不能因为看见一个扩展位就写成已经完成。

## 本章目标

- 建立 HS、VS、VU 和虚拟化状态 `V` 的精确关系；
- 从隔离、性能和故障归属三个角度解释 VS-stage 与 G-stage；
- 沿 QEMU 的 TCG 实现观察 H 扩展的可执行语义，而不把它误认成 KVM 路径；
- 区分宿主使用 H 加速 L0、向 L1 暴露 H、L1 启动 L2、L2 可迁移四种能力；
- 从 H 支持的多轮补丁和 nested 修复中理解“规范实现完成”为什么不是一个瞬间。

## 先拆开四种经常被混用的能力

讨论嵌套虚拟化时，最危险的句子是“这个平台支持 H 扩展，所以支持 nested”。它把四个不同问题压成了一个布尔值。

第一层是宿主物理处理器具备 H 扩展，Linux KVM 可以利用它运行普通客户机。这里的宿主 hypervisor 是 L0，QEMU 创建的客户机是 L1。H 的二阶段翻译、虚拟化 trap 和中断辅助都服务于 L0 隔离 L1。这个条件是 RISC-V KVM 硬件加速的基础，但它不要求 L1 看见 `h` 扩展。

第二层是 L0 决定把 H 扩展暴露给 L1。此时 L1 的设备树或 ISA 枚举中出现 `h`，L1 可以把自己当作 hypervisor。暴露扩展位还不够：相关 CSR、虚拟指令、trap、guest external interrupt 和二阶段地址翻译状态都必须被虚拟化。任何一项缺失，都可能让 L1 启动后在早期探测或首次进入 L2 时失败。

第三层是 L1 真正创建并运行 L2。这需要 L0 内核对 nested 执行进行支持，也要求 QEMU 通过 KVM UAPI配置和保存 L1 可见的 H 状态。它是一个运行时闭环，不是一个 CPUID 或 ISA 字符串测试。

第四层是 nested migration。源端不仅要运行 L2，还要在任意可迁移时刻停住 L1/L2，导出所有 H/VS/G-stage、中断和定时器状态，在目标端以兼容顺序恢复。普通 L1 可以迁移不代表正在运行 L2 的 L1 可以迁移。

| 能力层 | 直接问题 | 最小证据 | 本书表述规则 |
|---|---|---|---|
| 宿主 H 加速 L0 | Linux KVM 能否用物理 H 运行 L1 | 宿主内核 capability、`KVM_RUN` 实验 | 可以写“宿主硬件加速” |
| 向 L1 暴露 H | L1 的 ISA 与 H 状态是否完整可见 | KVM ISA one-reg、FDT、CSR 行为 | 只写“L1 可见 H” |
| L1 运行 L2 | L1 能否完成 nested 创建、进入、退出 | nested KVM 补丁与真实 L2 启动 | 通过实验后才写“nested 可运行” |
| nested migration | L2 运行状态能否跨主机恢复 | H/VS one-reg、irqchip/timer 状态、迁移测试 | 未闭环时写“演进中” |

这张表会贯穿后面三章。尤其要注意，QEMU `v11.1.0-rc0` 中出现 `KVM_RISCV_ISA_EXT_H` 是第二层的一部分证据，不是第三、第四层的充分条件。

:::: {.quick-quiz}
为什么“宿主处理器有 H 扩展”和“L1 客户机能运行 L2”不是同一件事？

::: {.quick-answer}
宿主 H 只说明 L0 可以使用硬件机制隔离并运行 L1。要让 L1 再运行 L2，L0 还必须虚拟化 H CSR、虚拟指令、二阶段地址翻译和中断状态，并通过 KVM UAPI把这些能力交给 QEMU。前者是物理能力，后者是完整的 nested 接口与实现闭环。
:::
::::

## 为什么仅靠传统 trap-and-emulate 不够

理想的 trap-and-emulate 有一个简洁前提：普通指令直接执行，所有可能破坏隔离的敏感操作都会可靠陷入 hypervisor。现实中的特权架构还要面对地址转换、计时、异步中断和被虚拟化监督态的软件接口。若每次客户机读写 S 级 CSR、切换页表或等待中断都要退回 L0，系统即使正确，性能和延迟也很难接受；若某个敏感状态又不能自然 trap，隔离就可能失效。

H 扩展没有再增加一套完全独立的“第四特权级”，它在原有监督态旁边加入虚拟化视角。宿主 hypervisor 在 HS-mode 运行，客户机内核在 VS-mode 运行，客户机用户程序在 VU-mode 运行。处理器内部的 `V` 状态决定当前 S 级语义属于宿主还是客户机。这样，客户机操作常见的 `sstatus`、`stvec`、`sepc` 和 `satp` 时，可以映射到 VS 对应状态，而无需每次由软件逐条解释。

这种复用有明显的工程收益。已有 S-mode 操作系统不必为了虚拟化改写整个特权接口，处理器实现也能复用监督态执行路径。但复用会带来一项长期成本：读源码时不能只看 `priv == PRV_S`。同一个 S 数值在 `V=0` 时表示 HS，在 `V=1` 时表示 VS；异常路由、CSR 视图、MMU 索引和中断判断都还要结合虚拟化状态。

在 QEMU 的 [`CPURISCVState`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/cpu.h#L250) 中，这个区别由 `priv` 和 `virt_enabled` 共同表达。`virt_enabled` 不是装饰性标志，它参与 MMU index、CSR 选择、trap 路由和状态交换。源码同时保存 `stvec_hs`、`sepc_hs`、`satp_hs` 等 HS 备份字段，以及 `vstvec`、`vsepc`、`vsatp` 等 VS 字段。这个布局把规范中“同一监督态接口的两个视图”变成了可执行数据结构。

## H CSR 不是一张平铺寄存器表

可以按责任而不是按编号理解 H 相关 CSR。

第一组控制执行上下文。`hstatus` 保存上一虚拟化状态、VS 的 XLEN、guest virtual address 标记和对虚拟指令的控制位。`vsstatus` 是客户机看到的监督态状态。进入或离开虚拟化环境时，QEMU 的 TCG 路径通过 [`riscv_cpu_swap_hypervisor_regs()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/tcg/cpu_helper.c#L454) 在当前 S 状态、HS 备份和 VS 状态之间交换。这里不是简单复制一个 `struct`：不同 CSR 有别名、掩码和 WARL 约束，交换后还要让翻译缓存看到新的执行上下文。

第二组控制 trap 路由。`hedeleg` 和 `hideleg` 决定原本会到 HS 的异常或中断是否交给 VS；`hvip`、`hvien`、`hgeip` 和 `hgeie` 参与虚拟中断注入；`htval`、`htinst` 则为 HS 提供处理 guest fault 所需的信息。一个异常发生时，处理器必须回答三个问题：它发生在 VU、VS 还是 HS；它属于客户机页表错误还是 G-stage 映射问题；它应该由 L1 客户机内核处理，还是由 L0/HS 修复后重试。委托位只负责其中一部分，不能脱离异常来源理解。

第三组控制地址翻译。`vsatp` 指向 VS-stage 页表，`hgatp` 指向 G-stage 页表。`HFENCE.VVMA` 和 `HFENCE.GVMA` 分别为 VS-stage 与 G-stage 的地址转换缓存建立失效协议。页表写入只是普通内存写；没有 fence，其他 hart 或本 hart 的 TLB 仍可继续使用旧映射。

第四组控制时间和虚拟中断接口。`htimedelta` 让客户机看到相对时间，AIA 引入的 guest interrupt file 又与 `hstatus.VGEIN`、VS external interrupt 结合。后面讨论 KVM timer 与 IMSIC 时会看到，这些状态没有统一装进一个“虚拟化寄存器包”，而是分别穿过 CPU one-reg、KVM timer group 和 AIA device-control。规范按功能拆分，UAPI也随实现成熟度逐步扩展。

## 两阶段地址转换解决的是责任分离

客户机进程产生一个 guest virtual address。VS-stage 根据 `vsatp` 把它翻译成 guest physical address；G-stage 根据 `hgatp` 再把 guest physical address 翻译成 host physical address。可以把它写成：

$$
\mathrm{GVA} \xrightarrow{\mathrm{VS\mbox{-}stage}} \mathrm{GPA}
\xrightarrow{\mathrm{G\mbox{-}stage}} \mathrm{HPA}
$$

两阶段并不是为了把页表走两遍而走两遍。它把两种所有权分开：L1 客户机内核管理“本进程的虚拟页映射到哪一页客户机内存”，L0 管理“这页客户机内存在宿主上由哪一页承载”。客户机可以频繁换进程页表，不必让 L0重写每个进程映射；L0 可以迁移、回收或写保护客户机物理页，也不必理解客户机进程语义。

性能代价随之出现。一次 TLB miss 可能既要遍历 VS 页表，又要遍历 G-stage 页表；更容易忽略的是，读取 VS 页表中的 PTE 本身也是对 guest physical memory 的访问，因此该 PTE 地址还要经过 G-stage。QEMU TCG 的 [`get_physical_address()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/tcg/cpu_helper.c#L980) 在第一阶段页表遍历中递归进行第二阶段转换，正是这一规则的可执行表达。若 PTE 所在 GPA 没有 G-stage 映射，失败发生在“为了完成第一阶段而进行的第二阶段访问”，其 fault 信息不能按普通叶子访问处理。

G-stage 的根索引比普通 Sv39/Sv48 多两位，这是 GPA 地址宽度与页表格式共同决定的。TCG 实现用 `widened = 2` 区分第二阶段根层索引，并在成功后把两阶段权限相与。只要任一阶段禁止写，最终 TLB 项就不能允许写。A/D 位更新、PBMT、PMP/PMA 检查也要放在正确层次；把“最后得到一个 HPA”当作全部结果，会丢掉 fault 类型、权限来源和可恢复性。

:::: {.quick-quiz}
为什么 VS-stage 页表遍历期间也可能产生 G-stage fault？

::: {.quick-answer}
VS 页表存放在客户机物理内存中。处理器读取某个 VS PTE 时，先要把该 PTE 的 guest physical address 通过 G-stage 转成 host physical address。如果 L0 没有映射这页客户机内存，失败发生在页表遍历的间接访问上，而不是原始 load/store 的叶子地址上。
:::
::::

## fault 的名字体现了故障归属

普通 page fault 通常说明当前监督态管理的页表无法完成地址转换。guest-page fault 则说明 G-stage 或与两阶段相关的访问失败，需要 HS 介入。二者即使最终都由一个缺页触发，处理责任也不同。

QEMU 的 TCG 路径用 `guest_phys_fault_addr`、`two_stage_lookup` 和 `two_stage_indirect_lookup` 保存上下文。[`raise_mmu_exception()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/tcg/cpu_helper.c#L1498) 根据访问类型与失败阶段选择 instruction、load 或 store guest-page fault；trap 入口再据此填写 `htval`、`htinst` 等状态。`two_stage_indirect_lookup` 特别标记 VS 页表遍历中的 G-stage 失败。这个布尔值看似局部，实则决定 hypervisor 收到的故障地址如何解释。

设计上不能把 G-stage fault 伪装成客户机普通 page fault。若 L0 尚未给某个 GPA 分配宿主页，正确动作可能是建立 memory slot/页映射后重试；若把异常注入 L1 的普通缺页处理器，L1 会修改自己的 VS 页表，却无法修复 L0 的 G-stage。反过来，客户机自己清掉了 PTE 有效位时，也不应让 L0替它“修好”页表。精确异常类型就是软硬件之间的责任协议。

## 虚拟指令与可控 trap

即使有 VS CSR 和二阶段地址转换，仍有一些操作不能让客户机无条件直接执行。例如 WFI 可能让物理 hart进入等待，SFENCE 可能影响错误的地址空间，访问某些时间或中断状态可能泄露或破坏宿主资源。H 扩展通过 `hstatus` 控制位和 virtual instruction exception，让 HS 决定哪些操作直接执行、哪些 trap 后模拟。

这类 trap 的价值不只是安全。它还为过量分配和调度提供控制点：L1 执行 WFI 时，L0可以把 vCPU 线程阻塞，等待虚拟中断，而不是让物理 hart 按客户机意图休眠。代价是高频敏感操作可能频繁退出，所以规范尽量为常用路径提供可直接执行的虚拟视图，并把真正需要全局协调的操作留给 hypervisor。

在 TCG 中，`target/riscv/tcg/op_helper.c` 根据 `virt_enabled`、当前 privilege 和 `hstatus.VTW/VTVM/VTSR` 决定 WFI、SFENCE、SRET 等行为。它展示的是架构语义。KVM 模式下相应判断主要位于宿主 Linux KVM 和硬件，QEMU 的 `target/riscv/kvm/kvm-cpu.c` 不会再次解释每条 H 指令。把这两条路径混在一起，会产生“为什么 KVM 文件里找不到二阶段页表遍历”的错误问题。

## 虚拟中断比注入一个 pending 位复杂

外部设备产生中断后，L0首先要决定它属于哪个 L1 vCPU；若 L1 又运行 L2，还要让 L1 决定是否以及何时把它交给某个 virtual CPU。PLIC 的线中断模型可以通过 pending、enable、priority 和 claim/complete 表达，AIA/IMSIC 则把中断消息写入每 hart 的 interrupt file，并为 VS-level guest files 预留索引。

H 扩展提供 guest external interrupt 相关状态，AIA 提供更接近硬件数据面的承载。两者不是互相替代：H 说明 VS 中断如何进入特权架构，IMSIC 说明消息写到哪里、如何选择 guest file。QEMU `virt` 的 `aia-guests` 属性最终会影响 `riscv,guest-index-bits` 和 KVM AIA 的 guest bits，后续章节会沿这条路径说明 L2 中断为什么需要单独的能力与状态。

当宿主没有 IMSIC guest-file 硬件时，内核可以 trap-and-emulate；有硬件支持时可以让消息进入更直接的路径。两种模式对客户机应呈现相同架构语义，但状态存放位置、性能和迁移接口不同。硬件加速会把热路径下沉，配置、错误处理和状态转移协议仍由软件承担。

## QEMU 当前 TCG 实现的分层

在研究 H 原理时，TCG 是一份很有价值的可执行参考，但它不能替代规范文本或 KVM 内核实现。

[`target/riscv/cpu_bits.h`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/cpu_bits.h) 定义 CSR 编号、字段掩码、异常号和中断位。它回答“编码是什么”。

[`target/riscv/tcg/csr.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/tcg/csr.c) 定义访问谓词、WARL 处理、别名和读写副作用。它回答“谁能访问、写入后发生什么”。例如 `hgatp` 写入要经过合法模式过滤，`hstatus` 不能简单保存任意位模式。

[`target/riscv/tcg/cpu_helper.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/tcg/cpu_helper.c) 负责 MMU、trap 和虚拟化状态切换。它回答“状态如何参与执行”。

`target/riscv/tcg/insn_trans/trans_rvh.c.inc` 与 `op_helper.c` 实现 H 指令翻译及需要退出生成代码的复杂语义。它们回答“某条指令如何进入上述机制”。

[`target/riscv/machine.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/machine.c#L76) 的 `vmstate_hyper` 保存 H/VS 状态。它回答“TCG 视角的架构状态如何序列化”。同一份 VMState 也会被 KVM CPU 对象引用，但这并不自动保证 KVM 已把内核中的 H 状态同步回这些字段；第十五章会专门处理这个边界。

::: {.source-path}
建议先从 `CPURISCVState` 的 `virt_enabled`、H CSR、VS CSR 和 `two_stage_lookup` 字段建立状态表，再读 `riscv_cpu_swap_hypervisor_regs()`、`get_physical_address()`、`riscv_cpu_tlb_fill()` 和 trap 入口。不要从 CSR 数字表顺序阅读，否则容易看到很多寄存器，却看不到“切换—翻译—异常”这条因果链。
:::

## 从 35 个补丁开始的实现演进

H 支持进入 QEMU 不是一个提交完成的。2020 年的 [H 扩展 v0.5、35-patch 系列](https://patchew.org/QEMU/cover.1580518859.git.alistair.francis%40wdc.com/) 把 CSR、指令、trap、二阶段翻译和状态迁移拆成多个可审查单元。拆分本身反映了上游的工程判断：H 不是一个孤立 decoder feature，它会同时穿过 CPU state、CSR 权限、MMU、异常和 migration；若以一个大补丁提交，review 很难验证每层边界。

其中，[`ff2cc129`](https://gitlab.com/qemu-project/qemu/-/commit/ff2cc129) 建立 H CSR 相关支持，[`5eb9e782`](https://gitlab.com/qemu-project/qemu/-/commit/5eb9e782) 推进 trap/虚拟化异常路径，[`36a18664`](https://gitlab.com/qemu-project/qemu/-/commit/36a18664) 落实 second-stage translation。阅读这些提交时，不应只记“哪一天支持了 H”，而要比较每个提交改变了哪一层状态，以及后续提交为何仍需修复。二阶段翻译合入不代表 trap 信息已经完美，CSR 可访问不代表状态切换和迁移已经闭环。

H 规范成熟后，[`6ca7155a`](https://gitlab.com/qemu-project/qemu/-/commit/6ca7155a) 解除相关 experimental 标记，[`07cb270a`](https://gitlab.com/qemu-project/qemu/-/commit/07cb270a) 让 `virt` CPU 配置默认包含 H。对应的[上游系列](https://patchew.org/QEMU/20220105213937.1113508-1-alistair.francis%40opensource.wdc.com/)说明，默认开启建立在规范冻结和实现稳定度提高之上，而不是因为 H 从此不再有缺陷。默认值表达的是 machine/CPU model 的产品决策；它仍然受具体加速器、宿主和兼容版本约束。

2022 年的 [nested fixes v9](https://patchew.org/QEMU/20220630061150.905174-1-apatel%40ventanamicro.com/) 又修正了多处只有嵌套负载才容易暴露的问题，对应提交包括 [`b2ef6ab9`](https://gitlab.com/qemu-project/qemu/-/commit/b2ef6ab9)、[`30675539`](https://gitlab.com/qemu-project/qemu/-/commit/30675539) 和 [`8e2aa21b`](https://gitlab.com/qemu-project/qemu/-/commit/8e2aa21b)。这组历史说明：基础 H 指令能通过单元测试后，仍需真实 nested 场景验证 trap 目标、PTE 访问和 fault 信息。嵌套环境把两套监督态和两阶段翻译组合起来，边缘条件呈乘法增长。

::: {.design-note}
“默认开启 H”与“nested KVM 完成”发生在不同层。前者主要描述 QEMU TCG/CPU model 的架构能力；后者依赖 Linux KVM nested UAPI、宿主内核以及 QEMU KVM 状态同步。书中引用 `07cb270a` 时，只能支持“virt CPU model 默认 H”这一结论，不能拿它证明 L2 已可运行或迁移。
:::

## 当前 nested 状态：把上游原话放在功能宣传之前

Linux RISC-V nested virtualization 在 2026 年仍有新的 [27-patch v1 系列](https://lists.infradead.org/pipermail/linux-riscv/2026-January/084034.html)，也可从 [Patchew 镜像](https://patchew.org/linux/20260120080013.2153519-1-anup.patel%40oss.qualcomm.com/)追踪。该系列的上游陈述明确表示当时尚不能运行 L2。这个信息对本书非常关键：即使 QEMU 标签里已经有 H 扩展枚举、TCG H 实现和 KVM RISC-V 后端，也不能越过宿主内核成熟度宣布 nested 已完成。

因此，本书在 `v11.1.0-rc0` 研究锚上采用以下结论：宿主 H 用于 L0 加速是 KVM 的硬件基础；QEMU KVM 后端包含 `KVM_RISCV_ISA_EXT_H` 的能力表达；TCG 能模拟完整 H 语义；Linux nested 补丁仍在演进，而且公开 v1 明说不能运行 L2。至于某个特定开发内核加补丁能走到何处，属于实验结果，不能回写成发布版 QEMU 的默认能力。

## 设计取舍：为什么 QEMU 同时保留 TCG H 与 KVM H 接口

只保留 KVM 看似能减少重复实现，但会失去跨宿主架构运行、架构开发、精确故障注入和没有 H 硬件时的测试环境。只保留 TCG 则无法提供接近原生的执行性能。两条路径共享 `RISCVCPU`、machine、设备树和 VMState 名义上的架构模型，却在执行热路径分开。

共享层必须足够稳定。用户选择的 CPU 扩展、`virt` 地址布局、设备模型和迁移字段不能因加速器不同而随意改变；否则同一命令换一个 `-accel` 就不再是同一台机器。执行层又必须允许差异。TCG 需要 `get_physical_address()` 逐步实现规范，KVM 需要 one-reg、capability 和 `KVM_RUN`，强行抽成一个统一“虚拟化执行函数”只会隐藏状态所有权。

这种分层也给 review 提出明确问题。修改 H CSR 时，要检查 TCG CSR 访问、GDB、VMState 和 KVM可见性；修改 KVM H 能力时，要确认 FDT、用户 CPU 属性和 migration；修改 AIA guest files 时，要同时检查 H guest interrupt 语义。一个补丁只在本地路径编译通过，不能证明跨层契约未被破坏。

## 特权状态转换：沿一次 trap 看清谁在运行

只看模式名称仍然容易抽象过度。可以沿一次具体 trap 把状态变化展开。假设 L1 内核正在 VS-mode 运行，L2 用户程序处于 VU-mode，并执行一条产生 load page fault 的指令。如果 `hedeleg` 允许把该异常留给 VS，处理器保存 VU 的返回位置和原因到 VS 视图，转入 L1 的异常向量；L0不必参与。对 L1 而言，这和裸机 S-mode 处理用户态缺页十分接近，正是 H 扩展降低常见 trap 成本的地方。

如果失败来自 G-stage，情况就不同。G-stage 页表属于 L0，L1 无法凭自己的 `vsatp` 修复。处理器需要把控制权交给 HS，保存能让 L0区分访问地址、GPA 和页表遍历位置的信息。L0建立映射后可以重试原指令；若故障代表真实的客户机错误，也可能由 L0合成适当异常再注入 L1。这个选择不能由硬件只凭 fault 类型完成，因为内存后端、按需分配和设备 MMIO 都是 VMM 策略。

再看 virtual instruction exception。L1 在 VS 中执行了一条被 `hstatus` 控制为需要 trap 的监督态操作。此时指令本身可能在裸机 S-mode 合法，但在 `V=1` 时不能直接改变宿主资源。处理器将它标成虚拟指令异常而不是非法指令，使 L0知道“该指令属于有效的客户机监督态接口，只是需要虚拟化”。若统一报 illegal instruction，L1 可能误判为 CPU 不支持该功能，无法选择正确的模拟或回退路径。

异常返回也有对称约束。HS 的 SRET 可能回到 HS、VS 或 VU，目标由保存的虚拟化状态与前一 privilege 共同决定。QEMU TCG 在 helper 中检查 `hstatus.SPV` 等字段，必要时调用状态交换并刷新翻译上下文。返回前若先恢复 `priv` 后恢复 `virt_enabled`，短暂的不一致虽然只存在于 C 代码几行之间，也可能被日志、helper 或 TB flag 计算观察到。因此实现通常把状态变更集中在受控函数中，而不是允许各处直接写布尔值。

这种状态机还解释了为什么迁移必须保存“当前 V 状态”，而不能只保存两套 CSR。目标端需要知道哪一套是当前活动视图、哪一套是备份，否则恢复后的下一条 SRET 或 trap 会交换错误方向。`vmstate_riscv_cpu` 保存 `priv` 与 `virt_enabled`，`vmstate_hyper` 保存 H、VS 和 HS backup 字段，二者组合才构成 TCG 的完整快照。

## 两阶段页表遍历中的权限、属性与原子性

地址翻译不止返回一个页框号。VS-stage 和 G-stage 都产生读、写、执行权限，最终权限是两层允许集合的交集。L1 可以把某页设成只读，L0也可以为了脏页跟踪把本来可写的 GPA 暂时写保护；任一层拒绝写都必须导致写 fault。若实现只缓存最后一级 PTE 权限，可能在 L0撤销 G-stage 写权限后仍然使用旧的可写 TLB 项。

A/D 位把问题变得更细。硬件或模拟器在页表遍历中发现 accessed 或 dirty 位未设置时，可能按架构规则更新 PTE。更新 VS PTE 是一次针对 guest physical memory 的写，因此不仅要通过 G-stage，还要满足宿主物理保护。QEMU `get_physical_address()` 先求出 PTE 的 HPA，再经过 PMP/PMA 检查，并使用原子比较更新，避免另一个 hart 同时修改 PTE 时覆盖新值。若比较失败，遍历需要从合适状态重启，不能沿用上一轮已经变化的 `base` 或 `ptshift`。

这类担忧已经在实际修复中出现。页表遍历代码长期收到“重启后保留了陈旧局部变量”“大端 hart 读取 PTE 字节序错误”“PMP 检查顺序不对”等修复。二阶段翻译写出公式只是起点，真正的难点是在并发、异常和架构扩展共同作用时维持每一步上下文。写书时引用当前 `get_physical_address()`，应说明它是多年修复后的结果，不把今天的控制流包装成一次设计完成。

PBMT 等页属性也要组合。VS PTE 可以表达客户机希望的内存类型，G-stage 和宿主平台又有自己的限制。H 扩展通过 `henvcfg` 控制某些特性是否向 VS 开放。TCG 代码在第一阶段且启用两阶段时，同时检查 machine 和 hypervisor environment 配置。这样 L1 不能仅凭在自己的 PTE 中写一个属性，就绕过 L0的内存类型策略。

PMP 位于另一条保护边界。即使 VS-stage 和 G-stage 都产生有效地址，最终 HPA 访问仍要满足物理内存保护与平台属性。对真实 KVM，相关检查由硬件和内核配置完成；对 TCG，QEMU必须显式调用 PMP/PMA 逻辑。两条路径的结果应当在客户机可见层一致，但内部失败点和可观测日志不同。

TLB 项还必须携带足够的上下文。相同 GVA 在不同 ASID、VMID、VS/HS 状态下可以映射到不同 HPA。一个只以虚拟页号为 key 的缓存必然串扰。QEMU 的 MMU index 把 privilege、虚拟化状态等编码进 TLB 选择，TB flags 也记录影响指令语义的状态。写 `satp`、`vsatp`、`hgatp` 或执行相应 fence 后，要使正确范围的缓存失效。全部 flush 最容易正确，却会放大多 hart 和频繁上下文切换的成本；精确 flush 更快，但需要严密处理 ASID、VMID 和地址范围。

## `HFENCE` 是跨 hart 协议，不是一条普通清缓存指令

`HFENCE.VVMA` 针对 VS-stage 地址转换，`HFENCE.GVMA` 针对 G-stage。参数可以限定地址和标识符，允许 hypervisor 避免无差别冲刷。但一张页表可能被多个 vCPU/hart 使用，执行 fence 的 hart 只清自己的缓存并不足以完成全局更新。软件还需要向其他 hart 发 IPI 或借助 SBI remote fence，使它们在继续使用映射前完成失效。

对 VMM 来说，这里有两个并行层次。客户机 L1 执行 `HFENCE`，L0可能允许硬件直接完成，也可能 trap 后模拟；QEMU/TCG 自己修改映射时，也要使软件 TLB 和 TB 看见变化。nested 场景再增加一层：L1 认为自己在刷新 L2 的 G-stage，L0实际上虚拟化这套状态，并可能把它映射到真正的硬件二阶段缓存。若把每一层都粗暴实现为全局停机和全 flush，正确性容易获得，扩展到几十个 vCPU 时性能会迅速恶化。

工程设计因此需要明确失效的“命名空间”。地址属于 L2 GVA、L2 GPA 还是 L1 GPA？标识符属于 L1 分配的 VMID 还是 L0真实使用的硬件 VMID？某个 fence 是否只影响当前 nested VM？这些问题也是 Linux nested 补丁难以一次完成的原因。硬件字段宽度有限，L0可能必须把 L1 的虚拟 VMID 映射成自己的资源，并在复用时执行额外 flush。

QEMU TCG 不需要映射真实硬件 VMID，却必须模拟最终语义。它可以用更保守的 flush 保证正确，再逐步优化。KVM 则必须依赖内核实现真正的 VMID 管理与跨 CPU shootdown，QEMU 用户态只通过 capability 和 ioctl 看见抽象结果。两者在“为什么要 flush”上相同，在“谁执行、如何避免停机”上完全不同。

## HLV、HLVX 与 HSV：hypervisor 为什么需要特殊访存

HS 有时需要按照 VS/VU 的地址转换和权限读取客户机地址，例如模拟一条客户机指令、复制参数或检查页表。直接用 HS 自己的普通 load/store 会采用 HS 的 `satp`，得到错误地址。H 扩展提供 hypervisor virtual-machine load/store 指令，让 HS 明确选择虚拟机访存语义。

这些指令还要区分按数据读取和按执行权限读取。HLVX 用执行权限检查读取指令字，适合指令模拟；若用普通 HLV 代替，某页可能允许执行但不允许读，hypervisor 会得到与客户机取指不同的结果。反过来，不能因为 hypervisor 想检查指令就绕过 G-stage 和 PMP，否则它可能访问不属于该客户机的宿主内存。

在 QEMU TCG 中，这些指令通过 helper 构造特定 MMU index，强制两阶段翻译并结合 `hstatus.SPVP` 等字段选择有效 privilege。出错时产生的异常仍要带正确的 guest physical 信息。这个实现展示了一个常见设计技巧：不复制整套页表遍历，而是把“访问来自何种语义”编码成上下文，复用统一的翻译函数。代价是 MMU index 含义变复杂，新增 privilege/扩展时必须审查所有解码路径。

对 KVM nested 而言，HLV/HSV 能否执行是比 `h` 字符串更强的测试。L1 可能成功读取 H CSR，却在第一次用 HLV 访问 L2 时退出或得到错误 fault。完整测试应覆盖成功访问、VS 权限失败、G-stage 失败和跨页访问，而不是只运行 `misa` 探测。

## 中断虚拟化的三个时间点

中断路径可按“产生、选择、呈现”拆开。产生发生在设备或另一个 hart；选择决定目标 vCPU、优先级和 guest file；呈现则把 pending 状态转成 VS 能观察的 interrupt。PLIC 把这些阶段集中在一个线中断控制器模型，IMSIC 把消息接收状态放到每 hart 文件中，APLIC 可以把有线输入转换成 MSI。

L0必须在三个时间点都保留一致性。设备中断到来时，目标 L1 vCPU可能没有运行；L1 又可能把它路由给 L2。若 L0只记录“某个物理 IRQ 发生过”，却没有保存 APLIC target、IMSIC pending/enable 或当前 guest index，暂停恢复后就无法还原客户机所见顺序。若为了性能把 IMSIC 放进内核或硬件 guest file，QEMU 的普通设备对象里甚至没有最新 pending 位。

H 的 `hgeip/hgeie` 与 `hstatus.VGEIN` 为 guest external interrupt 提供架构接口。`VGEIN` 选择当前 VS 上下文对应的 guest interrupt file；零和非零索引有不同含义。`aia-guests` 决定每 hart 为 VS guest files 预留多少页，因而不仅是内存布局选项，也是 nested 能力上限的一部分。配置太少，L1 无法给更多 L2 context 分配硬件文件；配置越多，地址空间、内核状态和迁移数据也越复杂。

中断注入还有竞态。L0检查“vCPU 即将进入客户机”后，另一个线程可能立即设置 pending；若没有正确的内存序和 kick，vCPU 会在应当响应中断时继续睡眠。相反，重复注入 level interrupt 又可能让客户机看到多余边沿。H 规范定义客户机可见结果，QEMU、KVM 和 irqchip 实现必须用锁、原子位和事件通知把异步世界收敛到这个结果。

## 从 patch v1 到合入：怎样读 review 而不是只读 commit

最终 commit 告诉我们“代码变成了什么”，patch series 告诉我们“哪些边界曾被认为不清楚”。阅读 2020 年 35-patch H 系列时，应先看 cover letter 的依赖和已知限制，再选 CSR、trap、second-stage 三条线分别追踪。若 v1 把多项语义放在一个 helper，后续版本拆开，通常说明 reviewer 需要更清晰的责任边界或更小的可验证补丁；若某字段在 v5 才进入 migration，说明早期实现可能只覆盖启动而未覆盖保存恢复。

提交 `ff2cc129`、`5eb9e782` 和 `36a18664` 适合做“当前代码反向考古”的锚。先在当前标签定位相应状态和函数，再用 GitLab 查看提交 diff，最后回到 Patchew 系列找上下文。这样可以避免被旧文件路径困住，也能识别后来重构只是移动代码，还是改变了语义。

解除 experimental 的系列则适合研究默认值决策。规范冻结、测试覆盖和实现稳定是默认开启的前提，但 machine compatibility 仍要求旧机器保持行为。一个扩展从手动 opt-in 变成默认，会改变 FDT ISA 字符串、客户机内核选择的代码路径和迁移兼容集合；review 不只是讨论“测试通过没有”，还要讨论是否影响已有命令行和旧客户机。

nested fixes v9 展示另一种演进：补丁已经反复修改到第九版，说明问题跨越多个子系统或 review 中存在细节争议。正文无需罗列每版差异，却应保留一个能解释当前设计的变化，例如 fault 地址为何需要区分间接 G-stage，或状态交换为何必须在特定 trap 时机发生。没有帮助解释当前代码的版本细节留在研究账本，不用把邮件线程改写成编年史。

## 常见误判与反例

第一种误判是看到 `RVH` 定义就认为所有 CPU 都支持 H。`RVH` 只是位编码；具体 CPU model、用户属性、TCG/KVM 加速器和宿主 capability 共同决定启用结果。

第二种误判是看到 `hgatp` 字段就认为二阶段翻译已运行。字段可以存在但扩展关闭，也可以在 KVM 模式下只是用户态镜像而非最新硬件状态。必须检查执行路径和状态同步时机。

第三种误判是 L1 启动成功就认为 nested 成功。普通 L1 只需 L0使用宿主 H；只有 L1 配置自己的 G-stage、进入 L2 并正确处理 exit，才测试了 nested。

第四种误判是一次 cold migration 成功就认为 nested migration 完成。若测试时 L2从未进入、AIA没有 pending 中断、timer 没有运行，缺失状态可能恰好为零。应在 L2有活动页表、待处理中断和计时器时迁移，并在目标端检查连续性。

第五种误判是 TCG 与 KVM结果不同就断定某一方错误。先确认 CPU model、ISA扩展、AIA类型、timebase 和 firmware 启动路径是否一致。TCG 可以模拟宿主硬件没有的扩展，KVM 则受宿主限制；命令行相似不代表能力集合相同。

第六种误判是把 RFC 或 v1 patch 写成发布版现状。邮件中的结构名和 ioctl 编号可能在 review 中改变，甚至整个方案被替代。正文必须回到 `v11.1.0-rc0` 固定标签确认合入代码；未出现的接口只能作为演进方向。

## CSR 别名为何能减少 exit，又为何容易出错

VS-mode 读取 `sstatus` 时，规范希望它看到的是虚拟监督态状态，而不是 HS 的真实 `sstatus`。一种实现办法是每次 CSR 指令都 trap 给 hypervisor，由软件判断寄存器号再读写影子结构；另一种办法是由硬件在 `V=1` 时自动把常用 S CSR 映射到 VS CSR。H 扩展采用后者为主，因此客户机操作系统的上下文切换和异常入口无需频繁退出。

自动别名并不意味着两组寄存器完全相同。某些位在 VS 中只读、被屏蔽或受 HS 控制；某些 S 级功能只有 H 扩展或相应 supervisor 扩展开启时才存在。QEMU `csr.c` 为每个 CSR配置访问 predicate、读函数和写函数，而不是把编号统一映射到一个数组。predicate 同时检查 privilege、`virt_enabled`、扩展位和控制字段，写函数再做掩码与 WARL 规整。这样的代码较长，却能把“寄存器存在”和“本上下文可访问”分开。

别名也影响调试。GDB 或 monitor 在 vCPU 停止时询问 `sstatus`，究竟应返回当前活动视图、HS 视图还是 VS 视图？普通指令的读语义和管理工具的状态枚举并不总相同。迁移则更严格：它必须同时保存所有隐藏视图，不能只保存当前别名读到的值。`vmstate_hyper` 因此包含 VS 字段和 HS 备份，而不是调用 CSR read helper 导出一张平铺表。

当新增一个 H 相关 CSR 时，完整改动通常至少涉及编号和字段、CPU state、访问 predicate、读写副作用、reset、迁移、GDB/monitor 以及测试。KVM 路径还要确认 UAPI 是否暴露。只在 `cpu_bits.h` 加编号会让 decoder 认识名字，却没有正确状态；只在 `csr.c` 加读写而漏掉 VMState，会出现运行正常、迁移后丢失的延迟故障。

## 委托不是把异常处理权永久交出去

`medeleg/mideleg` 在 M 与 S 之间委托，`hedeleg/hideleg` 在 HS 与 VS 之间继续细分。可以把它理解为针对“当前一次事件”的路由表，而不是所有权转让。HS 仍然控制委托位，可以在创建客户机时选择允许其自治的异常集合；某些必须由更高层处理的事件不能随意委托。

事件路由还受来源模式影响。来自 HS 自身的异常不会因为 `hedeleg` 就交给 VS；来自 VU/VS 的事件才有虚拟化委托语义。中断还要结合 enable、pending、优先级和全局 interrupt-enable。仅检查某个 delegation bit 无法判断最终 trap 目标，这也是 trap 代码需要集中处理而不适合散在每个设备回调中的原因。

对性能而言，把客户机能够自行处理的缺页、系统调用和普通设备中断留在 VS，能避免 L0参与每次事件。对隔离而言，G-stage fault、虚拟指令和宿主资源相关事件必须留给 HS。委托表正是在自治与控制之间做可配置切分。默认策略若过于保守，exit 频率高；过于激进，则可能把 L1无法安全处理的状态暴露出去。

nested 再加入一重同构关系。物理 M-mode/HS 属于宿主平台，L1 看见一个被虚拟化的 H 环境，并为 L2配置自己的 `hedeleg/hideleg`。L0需要把 L1 的意图映射到真实硬件能力，不能让 L1改动 L0本身的委托。某些操作可以直接在硬件运行，某些必须 trap 并在软件影子中更新。nested 内核补丁的大量工作就发生在这层“虚拟 H CSR”上。

## TB flags 与翻译缓存为何必须包含虚拟化状态

TCG 生成一个 TB 时，会假设一组在 TB 生命周期内稳定的执行条件，例如 XLEN、privilege、大小端、扩展和部分 CSR 控制位。同一 PC 在 HS 与 VS 下可能读取不同 CSR、采用不同地址转换并对同一指令产生不同 trap，因此 `virt_enabled` 必须参与翻译上下文。若切换 V 后仍执行旧 TB，代码本身可能没有任何显式访存，却已使用错误的 helper 或权限判断。

最保守的方法是在所有 H 状态变化时清空全部 TB。它容易正确，却把虚拟机频繁切换变成全局性能问题。QEMU倾向把真正影响翻译结果的状态编码进 TB flags，让不同上下文自然得到不同 cache key；只在无法通过 key 区分或旧映射必须回收时失效。这个思路与两阶段 TLB 的 ASID/VMID 类似：缓存可以共享，前提是共享键包含完整身份。

某些 CSR 只影响运行时 helper，不必进入 TB key；某些位会改变指令是否合法或内存访问模式，就必须进入。判定错误有两种代价：漏掉会产生 correctness bug，多放会降低 TB 命中率。review 中经常要求作者说明“这个状态是在翻译时折叠，还是在运行时读取”，正是为了选择正确缓存边界。

KVM 不使用 QEMU TB，但有相似问题。Linux KVM和硬件 TLB 使用 VMID、ASID及虚拟化控制状态识别缓存；L1 修改虚拟 H 状态时，L0必须更新影子/硬件状态并发出适当 fence。两条实现共享缓存身份问题，只是一个在用户态软件翻译器里，一个在内核和处理器里。

## 安全边界：二阶段翻译不是完整安全模型

G-stage 防止 vCPU 直接访问未映射给客户机的宿主页，但虚拟机隔离还依赖设备 DMA、IOMMU、内存后端和 QEMU进程权限。一个 virtio 或直通设备若能 DMA 到错误地址，CPU 的 H 扩展不会自动拦住所有路径；设备地址空间必须经过 IOMMU 或受控映射。把“有二阶段页表”写成“虚拟机内存绝对安全”会忽略非 CPU 主设备。

侧信道也不由 H 自动消除。TLB、cache、分支预测和共享执行资源仍可能泄露信息，缓解策略往往需要固件、内核调度和微架构支持。QEMU 源码主要表达功能语义，不能从一个 fence 或状态位推导出完整侧信道防护。书中涉及安全时应区分架构隔离保证、实现假设和平台缓解。

错误的 fault 信息本身也可能成为隔离漏洞。若 HS 收到未经规整的宿主物理地址，或 L1能够通过 guest fault 推断未分配宿主内存布局，就会暴露不必要信息。规范选择 `htval` 等受定义转换的值，并区分 guest virtual address 标记。模拟器必须按规则截断、移位和选择地址，而不是把内部指针直接塞给客户机。

H 扩展让 L1 拥有更强的特权接口，也扩大了 L0 的攻击面：新的 CSR、指令、页表遍历和中断路径都可能接受客户机输入。生产系统往往会把“宿主有 H”和“允许不受信 L1 使用嵌套虚拟化”分成两个策略开关。QEMU CPU 属性只是一部分，内核 capability 和管理层策略同样重要。

## 可复现性与 machine 兼容

TCG 可以在不同宿主架构上提供相同的 RISC-V H 模型，适合规范测试和教学；KVM CPU 能力通常跟随宿主。若命令行使用最大宿主能力，迁移到另一台机器时可能缺少扩展或 SATP 模式。稳定部署需要选择一组目标主机共同支持的能力，而不是每次启动都把所有探测结果暴露给客户机。

QEMU machine version 负责保持板级和设备默认兼容，CPU model/属性负责 ISA 集合。`virt` 默认开启 H 的历史变化意味着旧 machine 与新 machine 可能生成不同 ISA 描述；管理层如果要求长期迁移，应固定 machine type、CPU 属性和加速器配置。只记录 `qemu-system-riscv64` 版本号不足以复现实验。

本书所有实验因此要求记录：QEMU commit、宿主内核 commit、加速器、machine、CPU 属性、AIA 模式、固件或直接 kernel 路径。对 nested 还要记录 Linux nested patch series 版本。缺少其中一项的“可以启动”报告很难与他人比较，尤其在上游功能快速演进阶段。

正式 `v11.1.0` 标签发布后，本章需要重新核对 `v11.1.0-rc0` 到正式版之间的差异。如果 H/KVM/nested 相关补丁没有进入正式标签，研究锚保持有效；如果进入，应把当前源码链接切到正式标签并更新能力矩阵，但不能删除 rc0期间邮件所揭示的设计约束。

## 为后续 KVM 章节建立状态所有权表

进入 KVM 之前，可以先给状态按拥有者分类。CPU 正在运行时，PC、GPR、S CSR、FP 和 Vector 的最新值通常在内核 vCPU；QEMU 的 `CPURISCVState` 可能是上一次同步的镜像。TCG 下这些字段就是执行真值。相同结构体在两个加速器下承担不同角色，这是后续最重要的阅读前提。

H/VS 状态在 TCG 下明确位于 `CPURISCVState`。在 KVM 下，当前 RISC-V one-reg 代码是否能取得全部 H/VS 状态，需要逐项审查；不能看到字段存在就假定最新。timer 在 KVM 中有独立寄存器组和暂停/恢复回调。AIA 若在内核 irqchip 中，其 pending/enable 状态不在 QEMU IMSIC 数组。RAM 内容位于用户态内存后端，但映射和脏页状态还在 KVM memory slots。

状态所有权会随运行阶段变化。vCPU 退出不一定立即同步全部寄存器；QEMU只有在调试、reset、迁移或用户态修改需要时才拉取。暂停只建立一个可以执行同步协议的时刻，状态不会自动回到 QEMU。把这个表带到第十三章，就能理解 `vcpu_dirty`、`KVM_PUT_RUNTIME_STATE` 和 one-reg 为什么存在。

## 用不变量审查 H 实现

面对跨越数千行的 H 实现，先列不变量更便于组织阅读。第一条不变量是隔离：任何从 VS/VU 发出的 CPU 访存，若要求两阶段转换，就不能绕过 G-stage 到达任意 HPA；用于读取 VS PTE 的间接访问也不例外。第二条是故障归属：VS 页表错误交给客户机能够处理的层，G-stage 与虚拟指令问题交给 HS，相关 CSR 必须足够重建原始事件。第三条是上下文一致：`priv`、`virt_enabled`、活动 S 视图、MMU index 和 TB flags 必须描述同一时刻。第四条是失效完整：修改页表或虚拟化身份后，不得继续使用旧上下文生成的 TLB/TB 结果。

第五条不变量是异步状态不丢失。中断在 vCPU 运行、退出、暂停任一时刻到来，都应最终以一次正确的 pending/level 结果呈现；不能因为状态从 QEMU移到内核就消失。第六条是保存恢复闭包：声明可迁移的客户机可见状态，在源端必须可读取，在目标端必须可写回，且恢复顺序不能暴露中间状态。第七条是能力单调约束：KVM 客户机不能启用宿主和内核无法提供的扩展，关闭能力又不能留下仍然可访问的残余 CSR。

这些不变量可以指导测试生成。隔离不变量对应合法/非法 GPA 和页表间接访问；故障归属对应委托组合与 fault CSR；上下文一致对应频繁 HS/VS 切换后执行同一 PC；失效完整对应改页表后跨 hart 读写；异步不丢失对应暂停边界注入；保存恢复闭包对应带活动 L2 和 pending IMSIC 的迁移。单个 happy-path 启动测试覆盖不了这些维度。

它们也帮助阅读 review。reviewer 要求把某个 helper 移到统一 trap 路径，可能是为了维持故障归属；要求在 CSR 写后 flush，可能是为了上下文和失效；拒绝在没有 UAPI时暴露扩展位，可能是为了能力和保存恢复闭包。这样，review 意见不再是风格偏好，而能回到具体系统不变量。

## 性能讨论必须绑定 workload 与退出原因

H 扩展减少 trap 和软件页表影子，通常有利于性能，但“硬件虚拟化快多少”没有脱离 workload 的固定答案。计算密集型 L1若几乎不做 MMIO，可长期留在 `KVM_RUN`；设备密集型负载仍会因用户态设备访问退出。nested L2 又可能因为虚拟 H CSR、页表操作和中断频繁退出到 L0，其成本取决于内核实现是否能把常见路径留在硬件。

二阶段 TLB 命中时，普通 load/store 近似直接执行；miss 时的复合页表遍历成本受页表层数、缓存局部性和内存延迟影响。大页可能减少遍历和 TLB 压力，却增加内存碎片与迁移脏页粒度。VMID 能减少切换 flush，但数量有限且需要回收协议。AIA guest files 可降低中断注入开销，却把更多状态放入内核/硬件，提升迁移难度。这些都是同一设计在热路径和控制面上的交换。

因此实验报告至少要给出 exit 分类、TLB/fault 计数、vCPU 数和设备配置，不能只贴一个总运行时间。若优化把某类 exit 从一万次降到一百次，却增加了每次暂停的状态同步，吞吐 workload 可能获益，频繁 checkpoint 的场景未必。第十三章会用 `KVM_RUN` 和 one-reg 次数把这套方法落到代码。

## 本章证据的适用边界

本章引用的 H 初始系列和 nested fixes 主要解释 QEMU TCG 架构模型如何形成；它们不能替代 Linux KVM nested 系列。反过来，Linux nested 邮件描述的是内核开发状态，不代表补丁已经进入 QEMU 固定标签或发行版内核。两类材料只有在“QEMU 能表达能力、内核能执行、UAPI能同步、实验能复现”四点闭环时，才能共同支持一项 KVM nested 结论。

`v11.1.0-rc0` 当前代码是事实锚，而不是对未来正式版的预测。GitLab 提交链接用于说明已经合入的 QEMU历史，Patchew 与邮件链接用于还原上游讨论和未合入方向。若邮件中的函数、字段与当前源码不一致，以固定标签为准，并把差异解释为演进，而不是悄悄把旧名称写进调用链。

规范事实同样要与实现状态分开。规范定义 H 扩展应有何语义，不保证某个宿主内核已经实现；QEMU TCG 实现某项语义，也不证明所有硬件行为或性能相同。后续章节若给出“强推断”，会同时列出支持它的源码、历史和实验，并说明还有什么反例可能推翻。这样的限定让读者能够复查结论。

最后还要区分功能正确与工程可用。某个开发分支能让单核 L2执行几条指令，只能证明最小路径贯通；要称为可用，还需覆盖多 vCPU、中断、定时器、内存压力、调试、reset 和错误恢复。要称为可迁移，则必须再验证活动状态的导出、目标能力和恢复顺序。本书不会用较低层的成功替较高层背书。

所有结论还必须注明宿主内核和硬件，因为同一个 QEMU 二进制会在 capability 探测后形成不同客户机能力。没有环境清单的复现结果只能作为线索，不能提升为版本级事实。

一份合格的 H扩展报告还应保存客户机特权层次和触发条件。相同的 CSR访问在 HS、VS与 VU可能产生不同 trap，页故障发生在 VS-stage叶子、G-stage叶子或页表间接访问时也有不同责任。若日志只给出异常编号而没有 `priv`、V状态、`htval`和相关页表根，读者无法判断测试覆盖的是普通 S态虚拟机还是实际 nested路径。

性能结论同样需要分层。TCG实现 H语义适合架构验证，却不代表硬件 H的执行成本；KVM让普通 L1运行得快，也不代表向 L1暴露 H后的 trap、shadow映射和虚拟中断成本。基准报告应写 accelerator、宿主扩展、内核补丁和 L1/L2角色，再比较同一 workload。省略层次会把两个不同问题合并成一个数字。

升级规范版本时也要固定扩展组合。H依赖的基础特权规范、AIA与 timer扩展可能分别演进，同名 `h`位无法表达全部配套版本。复现实验应保存 QEMU CPU属性、客户机设备树与测试程序使用的规范版本，避免把规范差异归成某一条 QEMU回归。

结论更新时先重跑 fault、状态交换和四层能力三组实验，再修改版本说明。

为防止正式版与候选版之间的小改动让行号失效，正文用函数和结构体作为主要定位，固定提交链接作为历史定位。读者复查时先确认标签，再用符号搜索进入当前位置；不要把网页行号当成长期接口。这个方法也适用于后面 KVM 和 AIA 章节。

## 实验一：用 TCG 区分三类 fault

::: {.hands-on}
配套英文实验手册：[`model-two-stage-translation`](../experiments/part-03-riscv-hardware-virtualization/chapter-12-riscv-h-extension/model-two-stage-translation/README.md)。

环境使用 QEMU `v11.1.0-rc0` 的 `qemu-system-riscv64`，加速器选择 TCG，CPU 选择带 H 的 `rv64`，客户代码运行在一个能够进入 HS/VS 的最小固件或现成 hypervisor 测试环境中。构建时启用 debug 符号，并打开 `-d int,mmu -D h-fault.log`；若日志过大，可在 `riscv_cpu_tlb_fill()`、`raise_mmu_exception()` 和 trap 入口设置 GDB 断点。

依次构造三种访问：VS 页表叶子无效、G-stage 对目标 GPA 无映射、G-stage 对“存放 VS PTE 的 GPA”无映射。每次记录 `exception_index`、`badaddr`、`guest_phys_fault_addr`、`two_stage_lookup`、`two_stage_indirect_lookup`、`htval` 与最终 trap 目标。预期第一种属于普通 VS page fault；第二种是叶子访问的 guest-page fault；第三种会标记间接二阶段查找失败。实验支持的结论是 fault 分类承载责任边界，不用于推断 KVM 内核采用相同 C 函数。
:::

## 实验二：观察 HS/VS 状态交换

::: {.hands-on}
配套英文实验手册：[`inspect-h-extension-state`](../experiments/part-03-riscv-hardware-virtualization/chapter-12-riscv-h-extension/inspect-h-extension-state/README.md)。

仍使用 TCG 和同一版本，在 `riscv_cpu_swap_hypervisor_regs()`、SRET helper 及异常入口设置断点。让 HS 初始化一组易识别的 `stvec/sepc/satp`，再给 VS 对应 CSR 写入另一组值，进入 VS 后触发一次委托给 VS 的异常，再触发一次必须返回 HS 的 virtual instruction exception。

每次停下时同时打印 `priv`、`virt_enabled`、当前 S CSR、`*_hs` 备份和 `vs*` 字段。预期 `priv` 都可能显示监督态，但 `virt_enabled` 决定当前视图；跨 V 边界时两组状态按规范交换。若只打印 `priv`，日志会把 HS 和 VS 合并，正好演示为什么 QEMU 不能用单个 privilege 数值描述 H 扩展。
:::

## 实验三：验证四层能力而不是只看 ISA 字符串

::: {.hands-on}
本实验复用前两个手册，入口见[第 12 章英文实验索引](../experiments/part-03-riscv-hardware-virtualization/chapter-12-riscv-h-extension/README.md)。其中 H/VS 状态清单采用 `inspect-h-extension-state`，地址转换与 fault 部分采用 `model-two-stage-translation`。

准备两套环境：一套是任意宿主上的 TCG，另一套是具备 RISC-V H 硬件和 KVM 的 riscv64 宿主。对 TCG 记录 `-cpu rv64` 的 FDT ISA、H CSR 基本测试和一个 L2 测试；对 KVM 记录 `/dev/kvm` capability、QEMU 生成的 `riscv,isa-extensions`、L1 内 H CSR 探测，以及是否能真正进入 L2。

结果表必须分四列填写“宿主 H 加速 L0、L1 可见 H、L2 可运行、nested migration”，每列附内核版本、补丁集和复现命令。预期 TCG 可以在没有宿主 H 的机器上模拟架构语义，却不构成硬件加速；KVM 看到 `h` 也不自动保证 L2 运行。若采用 2026 年 nested v1 系列，应按上游说明把 L2 标为未完成，而不是把启动到 L1 shell 当作成功。
:::

:::: {.quick-quiz}
为什么 QEMU TCG 中完整的 `vmstate_hyper` 不能直接证明 KVM nested migration 可用？

::: {.quick-answer}
TCG 的最新 H/VS 状态就在 `CPURISCVState` 中，VMState 可以直接序列化；KVM 运行时的最新状态可能留在内核和硬件。只有 KVM UAPI能读取并恢复全部 H/VS 状态，而且 QEMU 在迁移阶段实际调用了这些接口，`vmstate_hyper` 中的字段才是有效快照。
:::
::::

## 阅读代码时的检查清单

遇到一个声称“支持 H”或“修复 nested”的提交，可以按以下问题审查。它改变的是规范编码、TCG 执行、KVM capability、Linux 内核还是 machine 默认值？它影响 HS/VS 哪个视图？是否改变 MMU index、TB flags 或 TLB flush？fault 发生在原始访问还是页表遍历？迁移字段是否新增，旧 machine 是否保持兼容？AIA guest interrupt state 是否也需要同步？测试覆盖的是单层 H 指令，还是确实启动了 L2？

这个清单比按文件名判断可靠。H 扩展的实现天然跨文件：一处 CSR mask 修复可能决定客户机能否启动，一处 fault 地址修复可能只在 nested 页表缺页时出现，一处默认 CPU 属性变化可能影响设备树 ABI。历史提交和邮件 review 的作用，是告诉我们某个看似局部的字段曾经破坏了哪条跨层契约。

## 小结

RISC-V H 扩展通过 HS/VS 视图、两阶段地址转换、精确 guest fault、虚拟指令和虚拟中断，为硬件执行客户机提供了架构基础。QEMU TCG 把这些语义显式实现在 CPU state、CSR、MMU 和 trap 路径中；KVM 则把执行交给 Linux 内核与硬件，只保留能力、状态和设备边界。

更重要的是，H 不是一个可以用单个扩展位概括的功能。宿主用 H 加速 L1、向 L1 暴露 H、L1 运行 L2、nested migration 是四个递进但独立的里程碑。`v11.1.0-rc0` 能证明前两条路径中的若干接口和完整的 TCG 模型，Linux nested 上游材料却明确显示 L2 支持仍在演进。下一章将进入 `/dev/kvm`、scratch vCPU、one-reg 和 `KVM_RUN`，观察 QEMU 如何把这个架构边界变成运行时对象。
