# KVM 状态同步、迁移与嵌套边界

KVM运行得快，部分原因是最新状态停留在处理器和内核里。迁移提出相反要求：在一个明确时刻，把 CPU、内存、定时器、中断控制器、设备和未完成 I/O组成一致快照，再在另一进程或另一台机器上按兼容语义恢复。只读出 PC和通用寄存器远远不够；只传完 RAM也无法解释恢复后的第一个中断为什么提前或丢失。

本章以 RISC-V `virt` machine为唯一体系结构主线，目标 QEMU版本为 `v11.1.0`，当前源码锚定官方 GitLab [`v11.1.0-rc0`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0) 的 `eca2c162`。CPU同步以 [`target/riscv/kvm/kvm-cpu.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c) 为准，序列化结构以 [`target/riscv/machine.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/machine.c) 为准，UAPI以随该标签携带的 [`linux-headers/asm-riscv/kvm.h`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/linux-headers/asm-riscv/kvm.h) 为准。后续邮件系列只用于说明演进方向，未合入内容统一标为待验证。

## 本章目标

- 建立一份按所有者分类的 RISC-V KVM迁移状态清单；
- 跟踪 vCPU退出 `KVM_RUN`、one-reg同步、VMState序列化和目标端写回；
- 解释 KVM timer为何独立于普通寄存器同步，以及频率差异带来的限制；
- 审查 PLIC、模拟 AIA、split AIA和完整 in-kernel AIA的恢复边界；
- 分开判断宿主 H加速、向 L1暴露 H、L1运行 L2与 active nested migration。

## 迁移首先是一致性问题

假设源端暂停时，CPU已经执行完一次 virtio MMIO写，后端尚未消费队列；RAM中的 descriptor是新值，设备 used index还是旧值。若只保存 RAM和 CPU，目标端可能重复提交或丢掉这项请求。再假设定时器 compare已经到期，pending中断位在内核 AIA，CPU尚未取中断；若中断状态没有迁移，目标端恢复后客户机时间继续前进，却永远等不到原本已经产生的事件。

一致快照要求所有能改变客户机可见状态的执行者进入共同边界。vCPU线程要离开 KVM，设备后端要停止产生新的 DMA或把 in-flight工作纳入协议，dirty log要收集最后一轮写，中断和定时器要冻结并导出。QEMU迁移框架把这些工作分散在 runstate、VMState、RAM迁移和设备钩子中，不能靠一个全局 `memcpy`完成。

“暂停”不能用单个布尔值概括。主线程发布停止请求，kick每个 vCPU，vCPU从 `KVM_RUN`返回并处理可能未完成的 I/O exit，之后才可同步寄存器。设备可能还有自己的工作线程；vhost或直通设备还可能在内核。只有当所有参与者都确认不再产生未记录变化时，最终快照才有稳定含义。

迁移正确性因此包含值和顺序。相同字段按错误顺序恢复，也会制造源端没有发生过的中间状态。例如先启动 timer和 vCPU，后写回 IMSIC pending，客户机可能越过原中断时刻；先开放 DMA、后恢复 IOMMU或队列状态，设备可能写入错误 GPA。恢复协议本身属于迁移 ABI。

:::: {.quick-quiz}
为什么 vCPU已经返回用户态，仍不能立即宣布“CPU状态已冻结”？

::: {.quick-answer}
返回可能对应尚需 re-entry完成的 MMIO/I/O协议，QEMU镜像也可能仍是旧值。暂停流程还要处理退出结果、同步内核寄存器并确认不会再次进入 KVM；这些步骤完成后，用户态字段才构成可序列化快照。
:::
::::

## 按状态所有者建立清单

第一类是 QEMU始终拥有的配置状态，包括 machine布局、设备配置、MemoryRegion拓扑和部分模拟设备寄存器。它们通常直接进入 VMState，但仍可能与内核注册对象对应，例如 memory slot和 ioeventfd。目标端恢复字段后要重新创建宿主资源，不能迁移源端 fd号码。

第二类是 KVM运行期间拥有的 vCPU状态。当前 RISC-V显式 get/put覆盖 PC、x1至 x31、支持的 S级 CSR、浮点和 Vector寄存器。QEMU的 `CPURISCVState`保留镜像，只有 synchronize后才是最新值。MP state也由 KVM capability控制，决定次级 hart是 runnable还是 stopped。

第三类是通过独立路径同步的架构状态。RISC-V KVM timer有 time、compare、state与 frequency one-reg，当前 VMState只序列化 time、compare和 state；runstate handler在 VM停止和继续时执行 get/put。它没有被普通 `kvm_arch_get_registers()`统一处理，因为虚拟时间是否推进与 VM运行状态直接相关。

第四类是 irqchip状态。用户态 PLIC与模拟 AIA把 pending、enable、priority、路由等保存在 QEMU对象；in-kernel AIA的权威值在 KVM device。split模式又把 APLIC和 IMSIC分在两边。每种模式需要不同的保存协议，不能用一个 `aia=on`概括。

第五类是 RAM与脏页。RAM内容可能由 CPU、QEMU设备、vhost和直通 DMA共同修改。KVM dirty bitmap/ring只覆盖其负责的写路径，迁移层要合并其他来源。memory slot描述宿主映射，不直接进入迁移；目标端按相同 GPA布局重新注册自己的 host地址。

第六类是暂态协议，包括 `kvm_run`中的未完成 I/O、eventfd计数、virtqueue后端请求、block层请求和网络包。它们未必有独立 VMState字段，设备必须排空、回滚或以专用 in-flight格式保存。把这些暂态全部假定为“暂停时自然消失”会产生最难复现的数据一致性错误。

第七类是宿主能力与派生状态。CPU扩展集合、Vector长度、CBO block size、timebase frequency、AIA模式和 `aia-guests`决定目标能否重建源端语义。它们有些写进 FDT或 CPU model，有些只在启动检查。迁移握手必须把这些约束变成明确失败，而不是等客户机执行到不兼容路径。

## 从 stop 请求到寄存器快照

QEMU请求停止时，通用 CPU层给每个 vCPU设置退出标志并 kick。正在 `KVM_RUN`中的线程通过信号和 `immediate_exit`尽快返回；尚未进入的线程在循环边界看到请求。原子顺序保证 vCPU观察到 wakeup时也能观察到停止原因。多 vCPU必须逐一确认，单个 hart退出不代表其他 hart不再写共享 RAM。

如果本次返回是 MMIO读或写，run loop先完成用户态设备语义。某些 KVM exit要求再进入一次内核提交原指令，QEMU可在 re-entry时保持 immediate exit，使其完成后立即返回。迁移边界要落在已完成指令上；直接丢弃共享页中的返回数据，会让源端和目标端对 PC是否前进产生分歧。

vCPU停止后，`kvm_cpu_synchronize_state()`把同步工作放到正确的 CPU线程，调用 RISC-V `kvm_arch_get_registers()`。成功后 `vcpu_dirty`表示 QEMU镜像有效，并可能由调试、reset或迁移代码修改。迁移保存读取该镜像；恢复后 full put把值写入新 KVM vCPU，随后所有权才重新交回内核。

同步不必在每次普通 exit后执行。MMIO设备模型通常只需要 GPA和数据，不读 PC/GPR；让状态继续留在内核可以减少 one-reg ioctl。暂停、调试和迁移需要完整观察，才支付 get成本。这个按需策略依赖调用者严格使用 synchronize helper，直接读取 `env->pc`可能拿到很久以前的值。

reset与迁移恢复使用不同语义。reset构造架构初始状态：PC指向直接启动 kernel，`a0`是 hart ID，`a1`是 FDT地址，次级 hart依据 MP state停止。迁移恢复要重建源端任意执行点，不能重用 reset默认值。通用 `KVM_PUT_RESET_STATE`与 `KVM_PUT_FULL_STATE`让 target区分两者。

恢复前还要保证真实 vCPU已按兼容 CPU属性创建。先写寄存器、后关闭目标宿主多出的扩展可能被内核拒绝；先运行、后写寄存器则更严重。目标启动流程应先完成 machine/CPU capability收敛和 KVM device创建，再加载 VMState，最后允许 vCPU进入 `KVM_RUN`。

## 当前 RISC-V get/put 到底覆盖什么

[`kvm_arch_get_registers()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c#L1341) 依次读取 core、支持的 CSR、浮点和 Vector。core包括 PC及 x1至 x31，x0不需要保存，因为架构固定为零。CSR配置表覆盖当前 KVM暴露的 S级状态，例如 `sstatus`、`sie`、`stvec`、`sscratch`、`sepc`、`scause`、`stval`、`sip`、`satp`、`scounteren`与 `senvcfg`；实际访问还受 register list探测结果约束。

浮点状态按宿主支持的 F/D扩展读取，Vector路径保存向量寄存器和相关控制状态。Vector长度是数据布局的一部分，目标端 `vlen`不兼容时不能简单截断或补零。QEMU在 CPU realize阶段检查宿主 vlen，迁移部署还要保证源目标选择相同客户机模型。

[`kvm_arch_put_registers()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c#L1386) 根据 put级别决定范围。runtime在当前实现中写 core和 CSR后返回，跳过 FP/Vector；完整初始化和恢复仍写这些扩展状态。提交 [`e2beafde`](https://gitlab.com/qemu-project/qemu/-/commit/e2beafde9e782b051355975f444c986b1b788925) 的 [v3系列](https://patchew.org/QEMU/20260518102118.2768383-1-mengzhuo%40iscas.ac.cn/) 用“用户态 exit不改 FP/Vector”作为安全前提，减少约 68次 one-reg写。

这项优化说明同步级别属于正确性协议。runtime可以复用刚从 KVM退出时仍正确的内核 FP/Vector；目标迁移 vCPU没有这份历史，full put必须写回。未来若 RISC-V exit handler开始修改向量状态，runtime假设也要更新。性能补丁的注释和 review应与状态所有权一起阅读。

MP state不在上述寄存器组中。支持 `KVM_CAP_MP_STATE`时，QEMU通过专门 ioctl读取和设置 vCPU可运行状态。多 hart迁移若只恢复 PC/GPR，却让所有 hart同时 runnable，会破坏 SBI HSM与次级 CPU启动语义。CPU清单必须包括执行状态，而不只是数据寄存器。

当前代码还没有把 timer塞进 get/put主路径。VM停止事件先触发 timer get，CPU VMState通过 `cpu/kvmtimer` subsection保存相应字段；目标 post-load把 timer标为 dirty，恢复运行时再 put。由此可见，一个函数列表不能代表全部可迁移 CPU状态，审查必须同时搜索 runstate handler与 VMState subsections。

:::: {.quick-quiz}
为什么 runtime跳过 Vector写回不代表 Vector不需要进入迁移流？

::: {.quick-answer}
runtime重入可以依赖同一 vCPU内核对象仍保留刚退出时的最新值；迁移目标是新对象，没有这份隐含状态。源端仍要读取 Vector，目标端 full put仍要完整恢复，并验证相同 vlen与扩展能力。
:::
::::

## VMState 是版本化描述，不是内存镜像

[`vmstate_riscv_cpu`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/machine.c#L458) 描述公共 CPU迁移结构，并通过 subsections按扩展和 accelerator条件加入额外状态。VMState逐字段编码，带 version、minimum version、needed、pre-save或 post-load钩子。它不保存 `RISCVCPU` C结构中的指针、锁、fd或 padding，也不要求目标进程地址布局相同。

subsection解决可选扩展。只有启用 Vector时才需要相应字段，H扩展使用 `vmstate_hyper`，KVM timer只在 KVM加速时需要。目标端读取 subsection前已经根据 CPU model构造对象；若源端发送目标模型不存在的必要状态，迁移应失败。静默忽略会让客户机看到扩展消失。

version允许字段演进，但不能随意改变旧字段语义。增加字段可提升版本并给旧流提供默认值，删除或重解释字段需要兼容代码与 machine约束。RISC-V扩展增长很快，单靠“当前两端同一 QEMU版本”会掩盖长期问题；自动化测试应覆盖旧 machine与跨版本流。

needed predicate必须基于稳定的客户机配置，而非瞬时宿主探测。若源端 `-cpu host`碰巧启用扩展、目标端 host模型不同，源端会发送 subsection而目标端无法接受。更可控的 CPU model让两端在迁移前就达成交集。对 in-kernel设备，needed还要反映实际 irqchip模式，否则用户态字段可能保存一份非权威镜像。

post-load负责把序列化字段转成目标运行状态。KVM timer的 post-load没有直接假定 vCPU正在运行，而是标记 dirty，待 runstate继续时写入内核。这种延迟避免恢复过程中 timer先走。其他内核设备也应有明确的“对象已创建、属性已配置、状态已加载、允许运行”阶段。

VMState字段存在只能证明 QEMU知道如何编码某个用户态值。若最新值仍在 KVM且 pre-save没有拉取，编码的是陈旧镜像。`vmstate_hyper`与当前 KVM H/VS缺口正好展示这一区别；迁移审查必须先确认状态来源，再看字段格式。

## KVM timer 的四次历史切片

提交 [`27abe66f`](https://gitlab.com/qemu-project/qemu/-/commit/27abe66f) 增加 `kvm_riscv_get/put_regs_timer`，把 time、compare、state和 frequency从 KVM one-reg同步到 `CPURISCVState`。提交说明已经指出不同宿主 timer frequency不能直接迁移，并在 put阶段读取目标频率比较。当前实现的错误处理只调用 `error_report`，没有形成强制协商协议，因此部署层仍应提前校验，而不能依赖运行中警告。

紧随其后的 [`9ad3e016`](https://gitlab.com/qemu-project/qemu/-/commit/9ad3e016) 把 timer同步接到 VM runstate变化：VM停止时 get，继续时 put。提交动机明确要求客户机虚拟时间随 VM停止而停止，恢复后继续。timer若只在迁移命令瞬间读取，普通 QMP `stop`期间仍向前走，客户机会看到暂停造成的大幅时间跳变。

[`1eb9a5da`](https://gitlab.com/qemu-project/qemu/-/commit/1eb9a5da) 增加 `vmstate_kvmtimer` subsection，保存 time、compare和 state，并在 post-load把 timer标记为需要写回。frequency没有进入该 subsection，目标端继续从自身 KVM读取并比较。这是固定源码可确认的字段边界。

2024年的 [`385e575c`](https://gitlab.com/qemu-project/qemu/-/commit/385e575c) 又修正 KVM模式下 FDT的 `timebase-frequency`：客户机设备树应使用 hypervisor提供的频率，而不是 TCG/ACLINT默认常量。这项改动说明频率同时影响运行时换算和客户机 ABI；FDT声明错误时，即使 timer寄存器本身同步，客户机时钟仍会按错误比例解释 tick。

四个提交连起来，能够回答当前设计为何分散在三处。KVM one-reg负责取得权威上下文，runstate handler负责暂停/继续时刻，VMState负责跨进程序列化，`virt.c`负责把频率发布给客户机。将它们合并进普通 CSR表会丢失运行状态和 FDT两个维度。

timer迁移测试必须检查数值和行为。源端暂停前记录 guest monotonic time与下一个 timer事件，暂停一段宿主时间后恢复，客户机时间不应把暂停时长当作运行时长；迁移到同频宿主后，中断应在预期虚拟时间发生。异频目标当前应视为不兼容，日志提示不能替代管理层拒绝。

## 内存、设备与未完成 I/O 的停止顺序

预拷贝阶段，QEMU可在 vCPU运行时发送 RAM轮次，dirty logging记录重新写脏的页。设备也可能通过 DMA修改 RAM，因此 vhost、块层和网络后端要加入脏页协议。最后停机阶段先阻止新的执行者，再收集尾部 dirty页；反过来先关闭日志会留下不可见写入。

设备 quiesce并不总是等于排空。某些块请求可以等完成，某些网络包可以丢弃并由协议重传，某些设备支持保存 in-flight队列。选择由设备语义和迁移协议决定。QEMU设备 VMState通常保存寄存器与队列索引，后端层负责确保这些索引与已经提交的外部副作用一致。

ioeventfd注册本身无需迁移，目标端按设备配置重新创建；但源端在停止前要禁止新 doorbell并处理已经计入 eventfd的通知。eventfd计数不是完整 virtio请求，直接保存整数会丢失 descriptor语义。irqfd同理，真正需要恢复的是设备 pending条件、irqchip状态与路由，目标 fd编号可以不同。

一次 `KVM_EXIT_MMIO`处于用户态处理阶段时，迁移不能只保存 PC。写回调可能已经修改设备状态，内核尚未提交原指令；读回调可能已经生成数据，结果尚未交给 vCPU。run loop应先完成协议或把未决状态纳入明确格式。当前通用路径倾向完成再停，这让 CPU快照落在可解释的指令边界。

RAM slot也不进入迁移流。目标端根据 machine与 RAMBlock创建自己的映射，再接收页内容。slot flags中的 dirty logging是迁移执行机制，不是客户机状态；恢复完成后是否继续记录取决于目标当前迁移阶段。把源端 slot编号或 host pointer写进流既无意义也不安全。

## 中断控制器必须按模式审查

用户态 PLIC的 priority、pending、enable、threshold与 context状态由 `vmstate_sifive_plic`保存。目标端先恢复 PLIC与设备，再允许 vCPU运行，外部 irq电平会根据恢复状态重新计算。测试要覆盖未 claim、已 claim未 complete以及多个优先级源，单纯 idle迁移看不出 pending丢失。

模拟 AIA同样依靠 QEMU APLIC/IMSIC VMState。APLIC有 source配置和 target，IMSIC有每 hart文件的 pending与 enable。恢复顺序应先建立 machine地址与 hart拓扑，再加载设备字段，最后连接/更新 CPU中断输出。若先让设备事件进入，可能与恢复的 pending重复。

完整 in-kernel AIA不同。当前 `kvm_riscv_aia_create()`创建并配置 KVM device，却没有在固定标签中展示完整运行状态 get/set；APLIC/IMSIC设备的用户态 VMState在内核 irqchip路径下又不是权威值。源码能够支持的结论是 `v11.1.0-rc0`没有建立可见的 in-kernel AIA迁移闭环，不能从“设备可创建”推出“设备可迁移”。

split模式保留 QEMU APLIC，KVM拥有 IMSIC。APLIC部分可进入用户态 VMState，IMSIC pending/enable仍需要内核接口。split降低了缺口范围，却没有让它消失。迁移文档和测试结果必须写具体模式，不能将 emul通过的结果套到 split或 hwaccel。

2026年6月的 [AIA save/restore补丁系列](https://patchew.org/QEMU/20260602142709086IsQxEt0LYI9ygtpFnj-XN%40zte.com.cn/) 晚于当前候选标签，说明上游正在补充这类接口。该系列属于演进证据，未经固定 tag和对应内核验证前不能写成现状。未来更新本书时，应核对最终字段、内核 UAPI和 migration test是否全部合入。

:::: {.quick-quiz}
为什么模拟 AIA迁移通过，不能证明 `riscv-aia=hwaccel`也能迁移？

::: {.quick-answer}
模拟模式的权威 pending、enable和路由位于 QEMU VMState；hwaccel模式的权威值位于 KVM AIA device，需要独立 get/set接口和恢复顺序。两种模式共享客户机设备外观，却不共享状态来源。
:::
::::

## 目标主机兼容不是“同为 riscv64”

目标 CPU需要支持源端暴露的全部客户机 ISA扩展及参数。普通整数扩展是集合问题，Vector还带 `vlen`，cache block操作带 block size，AIA带 guest file数量和 irqchip模式，timer带 timebase frequency。内核版本也决定 one-reg与 device control接口是否存在。

`-cpu host`把源宿主能力直接带进客户机模型，方便获得本机全部性能，却扩大迁移异质性。较稳妥的集群配置是在所有目标宿主上探测能力，选择明确交集，并把差异扩展关闭。这个过程需要 QEMU属性和管理层策略配合；QEMU能关闭某一位，不代表自动知道集群的长期交集。

客户机启动时已经从 FDT读到 ISA、timebase与 AIA拓扑。迁移目标不能在恢复后悄悄生成另一份能力描述，即使 Linux不重新解析 FDT，驱动已经按源端配置运行。目标端应验证兼容并拒绝，不能靠“客户机也许不会用到”维持表面成功。

machine version控制设备布局和默认值，CPU model控制指令能力。跨 QEMU版本迁移要同时固定两者，并运行双向兼容测试。新版本认识更多宿主扩展时，旧 machine不应无条件暴露；新增 VMState subsection也要能与旧流协商。

frequency差异展示了“能恢复字段”与“语义相同”的距离。当前 timer VMState没有保存 frequency作为可变客户机状态，而是要求目标环境匹配并打印不一致。管理层若忽略警告，迁移可能完成，客户机时钟比例却改变。正确策略是迁移前比较并明确拒绝。

## H 扩展把状态清单再展开一层

普通 L1由 KVM运行时，宿主 H用于让其 VS态执行和 G-stage转换；QEMU只需同步客户机看到的 S级状态。向 L1暴露 H后，L1本身成为 guest hypervisor，它会维护虚拟 H CSR、VS CSR、`hgatp`、虚拟中断、二阶段 fault上下文与用于进入 L2的执行状态。状态面发生了质变。

TCG在 [`target/riscv/machine.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/machine.c#L76) 定义 `vmstate_hyper`，按 RVH启用，保存 QEMU `CPURISCVState`中的 H/VS相关字段。TCG执行路径直接更新这些字段，所以 pre-save看到的是权威值。这可以证明 QEMU软件模拟已经设计了 H状态序列化结构。

RISC-V KVM `kvm_arch_get_registers()`当前只显式读取 core、S CSR、FP和 Vector，表中没有完整 H/VS CSR组；随标签携带的 KVM UAPI头文件也没有一组能让 QEMU取得全部 L1虚拟化运行上下文的 H/VS one-reg。源码事实因此是：当前用户态 KVM同步路径未展示 `vmstate_hyper`所需状态如何从内核刷新。

由此可作出强推断：即使某宿主能让 L1看到 `h`，`vmstate_hyper`字段也不能自动构成 active nested快照。推断仍有限定：它不否认未来内核、厂商分支或后续 UAPI可能实现；它只说明固定 QEMU标签与随附 UAPI没有闭环。书中应标“nested migration未建立”，而非声称架构永远不可能。

L2运行还需要虚拟化 H指令和 CSR、维护 L1的 VS/G-stage语义、处理 nested fault与 TLB失效，并把中断和 timer投递到正确层。L1能够读取 H CSR测试，只证明接口表面；真正让 L2执行用户程序、处理中断和页故障才接近运行闭环。

active L2迁移要求更多：源端导出 L1可见的全部 H/VS状态、L2执行点、嵌套地址转换上下文、pending nested interrupt和 timer；目标端重建兼容能力与缓存失效语义。G-stage TLB本身可重建，`hgatp`等架构根状态必须保存。任何不可见内核 shadow状态都要能从架构状态重建或通过 UAPI迁移。

## Linux nested 上游状态提供了什么证据

2026年1月发布的 Linux RISC-V KVM nested v1包含 27个补丁，可从 [linux-riscv邮件归档](https://lists.infradead.org/pipermail/linux-riscv/2026-January/084034.html) 与 [Patchew系列](https://patchew.org/linux/20260120080013.2153519-1-anup.patel%40oss.qualcomm.com/) 查看。cover letter明确说明该版本还不能运行 L2。这是上游作者对该系列范围的直接陈述。

它出现于 QEMU `v11.1.0-rc0`之后，该系列尚未成为发行版内核中的稳定承诺。正文引用它的目的，是确认 nested内核支持仍在分阶段推进，并指出“向 L1暴露 H”与“运行 L2”之间确有待补路径。它不能作为用户已经可以启用的命令行说明。

固定 QEMU源码缺少完整 H/VS同步，Linux nested v1又明确不能运行 L2，两条独立证据共同支持保守结论：当前书稿版本把 L2运行标为演进中，把 nested migration标为未闭环。若后续 v2/v3改变范围，结论也要随新 tag更新，不能用邮件时间自动覆盖固定源码。

测试报告应列四项。第一项，宿主 H是否让普通 L1通过 KVM运行；第二项，L1 FDT与 CSR是否看到 H；第三项，L1能否创建、进入并稳定运行 L2；第四项，带活动 L2、pending中断和 timer的 VM能否迁移。前一项成功只为后一项提供前提，不提供结论。

:::: {.quick-quiz}
为什么 L1设备树出现 `h`，仍不足以声称 nested KVM可用？

::: {.quick-answer}
设备树只声明客户机可见能力。内核还要虚拟化 H/VS状态和指令，L1才能运行 L2；迁移又要求这些状态可完整导出与恢复。四个层次需要独立源码、邮件和实验依据。
:::
::::

## 嵌套迁移的恢复顺序

目标端先验证宿主硬件和内核是否能提供与源端相同的 L1虚拟 H能力。随后创建 L0 KVM VM和 vCPU，配置 CPU扩展与 AIA模式；在 vCPU尚未运行时恢复 L1普通寄存器、虚拟 H/VS状态、timer与 irqchip。之后刷新或重建所有派生的 nested映射，最后才允许 L1/L2继续。

地址转换需要区分架构根与缓存。L1写入的 `vsatp`、`hgatp`和相关状态属于客户机可见寄存器，必须迁移；硬件 TLB、KVM shadow页表和缓存可以在目标端失效后重建。若某个内核优化产生无法从架构状态重建的隐含映射，它就需要额外 UAPI或迁移时禁用。

中断恢复要保持层次。L0物理/虚拟设备的事件进入 L1 AIA，L1又可能把 guest interrupt注入 L2。源端 pending位可能分别位于 QEMU APLIC、KVM IMSIC和虚拟 H CSR。恢复顺序错误会把属于 L2的事件送给 L1，或在 L1尚未建立路由前丢失。

timer也可能有层次偏移。L1看到的时间由 L0 KVM timer控制，L1再为 L2提供虚拟时间和比较值。迁移若只恢复外层 time/compare，L2的 offset或 pending timer事件可能改变。当前 fixed tag没有提供足以证明这套 nested timer闭环的接口，因此只能列为未来验收项。

调试与性能计数器也要纳入范围。一个只跑计算循环的 L2测试可能不触发虚拟中断、页故障、debug或 PMU路径。称为可用前，应覆盖多 vCPU、SBI HSM、二阶段缺页、AIA、timer、reset、暂停继续和错误注入；称为可迁移还需在每种活动状态中跨主机恢复。

## 机密虚拟化带来的相反约束

机密虚拟化希望宿主 QEMU不能任意读取客户机私有 RAM和寄存器，而传统迁移恰恰要求 VMM取得状态。两者要同时成立，通常需要受信执行环境或内核/固件提供加密导出、目标证明和密钥转移协议。普通 `KVM_GET_ONE_REG`与读取 RAMBlock不能直接沿用。

设备 DMA也会被重新划分。virtio描述符和共享缓冲区可能位于显式 shared区域，私有页需要 bounce、受保护 IOMMU或设备可信路径。memory slot只表达 GPA到内存后端还不够，还要表达 private/shared属性及转换生命周期。迁移脏页、热插和 discard都必须理解这种属性。

调试接口可能被有意限制。GDB读取寄存器、QEMU monitor查看内存和设备后端DMA都需要新的授权语义。书中不能一边声称状态对 QEMU不可见，一边默认现有迁移代码可直接序列化。安全目标会改变可观测性和故障处理设计。

截至本章固定的 QEMU RISC-V源码锚，本书没有发现一条可以宣称完成的 RISC-V confidential KVM machine、内存、设备和迁移闭环。因此这里讨论的是接口压力与审查问题，不是可执行功能说明。通用 KVM结构或其他架构已有实现，都不能替 RISC-V背书。

## 失败应该发生在什么时候

最理想的兼容错误发生在迁移开始前。管理层查询两端 CPU扩展、vlen、block size、timebase、AIA模式与内核 capability，发现不兼容便拒绝。这样源端 VM继续运行，用户获得具体原因。等到目标加载一半 VMState才失败，回滚和诊断都更复杂。

第二道防线是目标对象创建和 pre-load校验。KVM vCPU或 AIA device属性不支持时，应在接收大量 RAM前报告。one-reg ID缺失要指出具体寄存器组，不能只显示 `EINVAL`。CPU subsection与目标 CPU model不匹配，也应给出扩展名。

post-load失败必须阻止 vCPU运行。部分寄存器已经写回、timer或 irqchip失败时，继续执行会产生无法解释的客户机状态。迁移框架应将 VM留在失败/暂停状态，并保留足够日志。不能为追求“迁移命令返回成功”忽略恢复错误。

timer frequency当前只 `error_report`的行为提示管理层不能完全依赖 QEMU硬失败。部署检查应把它提升为策略错误。类似地，`riscv-aia=auto`可能在目标选择不同实现，管理层应显式固定模式并验证状态接口。

未知或未验证能力要用准确标签。“源码已实现”需要固定 tag中的路径；“上游计划”需要邮件链接；“强推断”要说明支持证据和反例；“待验证”要给复现实验。把所有不确定性写成“可能支持”对工程使用没有帮助。

## 迁移测试要制造有意义的状态

CPU测试应让每类寄存器都偏离 reset值。通用寄存器写入可识别模式，S CSR设置合法非默认值，浮点和 Vector装入不同数据，多个 hart处于不同 MP state。迁移后由客户机自检，并在 QEMU侧比较同步前后 one-reg。只启动到 shell主要测试 PC和少量状态。

timer测试在未来 compare之前迁移，并在源端暂停一段明显宿主时间。目标恢复后记录第一次 timer interrupt的虚拟时间，验证暂停时段未计入。另做 timebase不匹配的负面测试，确认管理层在传输前拒绝，而不是只依靠日志。

中断测试制造 pending但未 claim的 PLIC/APLIC源、已 claim未 complete状态、被 mask的 IMSIC pending以及多 hart目标。分别在 emul、split和 hwaccel模式运行；不能导出内核状态的模式应预期失败或标为未支持。迁移后检查次数、目标 hart和优先级顺序。

I/O测试让 virtio队列包含 in-flight请求，并选择具有可校验副作用的块写。迁移后验证数据只提交一次，used ring与磁盘内容一致。网络测试要区分允许丢包和设备状态错误，不能把 TCP重传掩盖的问题当作设备正确。

nested测试先验证 L1看见 H，再让 L2执行计算、触发 VS-stage和 G-stage fault、接收 timer与外部中断。若上游内核系列明确不能运行 L2，测试应在预期失败点停止并记录；不要通过跳过 L2步骤把结果改名为成功。未来支持成熟后，再在活动 L2各状态点迁移。

每份报告保存 QEMU tag与完整 commit、宿主 Linux commit、硬件型号、固件/guest kernel、命令行、CPU属性、FDT、AIA模式和迁移 transport。RISC-V KVM能力仍在演进，没有这些元数据，失败无法归因，成功也无法复现。

## 把迁移阶段与状态所有权逐项对齐

建立迁移通道前，源目标应先交换 machine、CPU和设备能力。这个阶段不接触客户机运行状态，适合拒绝 vlen、timebase或 irqchip模式不兼容。若管理层直到发送完数十 GB内存才发现目标没有 IMSIC save/restore，失败虽然安全，运维成本已经发生。

预拷贝开始后，源端 vCPU与设备继续运行，RAM页分轮发送。此时 CPU和设备状态仍由源端拥有，目标端收到的 RAM不是最终一致点。dirty bitmap/ring记录 CPU写，设备与 vhost写通过各自日志汇合。源端取消迁移时可以继续运行，因为状态所有权尚未转交。

进入 stop-and-copy前，QEMU发布停止请求并 kick全部 vCPU。每个线程完成必要 exit协议、停止重入并同步寄存器；设备层冻结新请求，处理 in-flight；内存层收集最后脏页。timer runstate handler在 VM停止时从 KVM取得上下文，中断控制器也必须在事件源静止后导出 pending。这里形成源端唯一的最终快照。

发送尾部状态时，顺序要满足依赖。RAM内容必须与设备保存的队列索引匹配，CPU页表根指向的页必须已经传到目标，timer和 irqchip字段要在目标 vCPU启动前装载。迁移流可以交错编码，但目标 load阶段要用 priority、section顺序和 post-load钩子建立正确依赖。

目标端在加载前已经按源端配置创建 QEMU对象、KVM VM、memory slots和 vCPU。load写入 RAM与 VMState，post-load完成派生状态重建，full put把 CPU镜像交给 KVM，timer与内核设备在允许运行前恢复。只有所有必要 section成功，目标才进入 running；任何一步失败都应保持暂停。

切换完成后，源端不能再对外产生与客户机有关的副作用。管理层通常在确认目标接管后销毁源端 VM。如果目标启动失败而源端已永久释放外部资源，就需要恢复/回滚协议；共享磁盘锁、网络身份和直通设备尤其敏感。迁移正确性扩展到 QEMU之外的资源所有权。

postcopy改变 RAM所有权时序，目标可能在全部页到达前运行并按需拉取。CPU、timer与 irqchip仍必须先恢复到一致点，缺页机制还要与设备 DMA协调。固定书稿对 RISC-V KVM的能力判断不依赖 postcopy成功；任何声称支持的配置都应单独验证预拷贝和 postcopy，不可相互代替。

暂停到文件再恢复与跨主机迁移也有差异。savevm目标通常是同一 machine配置，却可能跨 QEMU版本；实时迁移还涉及两台宿主 capability和网络中断。实验报告应写具体机制，不能把一次同进程 reset后的 snapshot恢复称为跨主机迁移。

## 一份可执行的兼容性清单

CPU清单先固定 XLEN、基础 ISA和所有客户机可见扩展，再记录带参数的能力。Vector需要 vlen与元素相关能力，CBO需要 block size，Sstc等 timer扩展影响时间接口，H需要明确是否只加速 L1还是向 L1暴露。列表应来自 QEMU最终属性与 FDT，不能直接复制宿主 `/proc/cpuinfo`。

machine清单记录 `virt`版本、RAM基址与大小、socket/hart拓扑、PCIe和设备地址、PLIC/AIA选择、`aia-guests`及 kernel irqchip模式。两端 host虚拟地址和 slot编号可以不同，客户机物理布局与设备节点必须兼容。machine别名随 QEMU升级变化时，应使用有版本的 machine名称。

内核清单记录 KVM API、关键 capability、register list和 AIA device attrs。源目标“都运行 Linux 6.x”没有足够精度，发行版可能回移补丁或关闭配置。保存内核 commit、配置与实际 ioctl探测，才能区分 QEMU模型不兼容和宿主接口缺失。

timer清单包含 FDT `timebase-frequency`、KVM one-reg返回频率以及 VMState字段版本。当前实现无法把异频宿主转换成相同客户机时间基准，应要求相等。只比较设备树还不够，源端若生成错误 FDT也会两边一致地错误，需与 KVM值交叉核对。

中断清单按所有者记录。PLIC/emulated AIA列 QEMU VMState版本；split列用户态 APLIC与内核 IMSIC能力；full hwaccel列完整 KVM AIA save/restore接口。任何一项写“未知”时，生产迁移策略应拒绝或改用明确的模拟模式，而非依赖 auto回退。

设备清单记录 virtio版本、队列数量、后端类型、vhost/直通开关和 in-flight支持。两个 QEMU命令行看起来相同，源端使用 vhost、目标端回退用户态时也可能有状态转换要求。能够启动后端不代表能够接收源端未完成请求。

清单还应区分硬要求和性能建议。缺失源端暴露的 ISA位是硬失败，目标物理 CPU较慢只是性能变化；timer频率差异在当前实现中会改变语义，应列硬失败；slot数量较小若仍能容纳布局则可接受。明确分类可以避免管理层把警告全部忽略或把可降级项全部拒绝。

## 六个常见的“表面成功”场景

第一个场景是 Vector workload迁移后仍能启动，但计算偶尔错误。若测试只查看 shell，PC/GPR恢复足以通过；直到应用使用高位向量数据才暴露 vlen或寄存器缺失。解决办法是迁移前比较参数，并在客户机中对每个向量寄存器写不同模式后自检。

第二个场景是客户机时钟看似连续，定时任务却提前。源目标 frequency不同，当前代码只打印错误；短测试只看到秒数变化不大，长时间或高精度 timer会积累偏差。应在开始传输前拒绝异频目标，并测量 compare事件而不只读一次时间。

第三个场景是 AIA hwaccel VM恢复到登录界面，某个设备从此不再中断。迁移时该源有 pending但被 mask，用户态没有导出 KVM IMSIC位；启动阶段其他中断正常，掩盖了这一项丢失。测试需要在暂停前主动制造 mask+pending组合，并在恢复后解除 mask验证。

第四个场景是块 I/O迁移后数据出现重复。MMIO doorbell已经在 QEMU处理，后端请求尚未提交，CPU快照却位于指令完成之后；目标按队列索引重新提交，源端外部存储也可能刚完成。设备必须用 quiesce或 in-flight协议把外部副作用与队列字段对齐。

第五个场景是内存校验只在高负载失败。最后一轮 dirty收集前，某个 vhost线程仍可 DMA写页；迁移日志只覆盖 KVM vCPU写，目标收到旧页。停止顺序应先冻结所有写源，再合并尾部日志。测试要让 CPU与设备同时写不同区域，并在恢复后全量校验。

第六个场景是 L1恢复正常，原有 L2却崩溃或重新启动。普通 S级寄存器、RAM和设备都迁移成功，H/VS运行上下文仍留在源内核；`vmstate_hyper`保存的只是未同步镜像。验收必须让活动 L2跨越迁移继续执行，不能以 L1 shell作为 nested migration判据。

这些场景的共同点是控制面返回成功，长尾状态没有覆盖。迁移测试应针对每个所有者制造非默认、活动或 pending状态；源码审查则沿 get、序列化、post-load和 put四步寻找断点。任何只测试 reset值的用例都会高估覆盖率。

## 恢复顺序怎样写成测试断言

第一条断言是 vCPU进入次数。在所有必需 CPU、timer和 irqchip状态 put完成前，目标 `KVM_RUN`计数必须为零。可在 `kvm_arch_put_registers()`、timer handler、AIA恢复钩子与首个 run处加 trace，按时间戳验证。

第二条断言是事件源静止。保存 pending中断前，设备不能再改变 irq线；保存最终 RAM前，vCPU与 DMA不能再写。可在源端 stop阶段给每个写源维护序列号，最终快照记录最后值，迁移后确认没有源端更晚事件。

第三条断言是派生状态重建。页表/TLB缓存无需原样迁移，但恢复 `satp`、未来的 H/VS根状态后必须执行必要失效；中断输出应从 pending/enable重新计算，不能把宿主线程或 eventfd状态序列化。测试可以在恢复后强制访问先前缓存过、现已改映射的地址。

第四条断言是错误原子性。故意让目标最后一个 Vector或 AIA状态写入失败，vCPU不得运行，管理层应收到具体字段，源端保持可恢复。若目标运行了几条指令才停止，错误路径已经破坏一致性。

第五条断言是取消路径。预拷贝期间取消时，源端 timer、中断和 ioeventfd应继续正常工作；进入最终切换后取消的支持范围要按迁移协议定义。只测试成功路径会遗漏 stop/cont handler重复注册、timer dirty标记和 eventfd重启问题。

第六条断言是跨版本。至少选择当前版本与一个受支持旧版本，固定 machine与 CPU model做双向测试，确认未知 subsection和新增字段按兼容规则处理。使用两个完全相同的二进制只能验证实现内部自洽，不能验证迁移 ABI。

## 邮件和 Git 日志如何进入结论

Git提交页面回答“最终合入了什么”，当前 tag源码回答“本书版本实际怎样调用”，邮件系列回答“哪些替代方案被讨论、范围如何收敛”。三者证据强度不同。提交说明可能简略，邮件某一版又可能与最终实现不同，因此正文把最终代码放在调用链中心。

timer历史是较完整的例子。四个提交依次出现，不代表维护者一开始就计划了完全相同的四层结构；我们只能确认各提交解决的具体问题，以及最终代码保留这种分工。从顺序推断的工程动机要标为推断，不能伪造成上游原话。

AIA save/restore补丁晚于候选标签，能证明有人识别并尝试修补缺口，不能证明方案最终合入或 ABI稳定。审查时还要追对应 Linux UAPI；只有 QEMU邮件没有内核接口，可能只是 RFC。书中把它放在“演进中”小节而非命令行教程。

Linux nested v1的 cover letter直接写明不能运行 L2，这一陈述可以准确引用其范围。未来 v2若能运行 L2，也不自动证明迁移；还要找 H/VS导出、QEMU同步和 migration test。按能力层次更新证据，比把“nested”当单个开关更不容易过时。

负面源码证据要谨慎表达。没有搜到 H/VS one-reg组支持“当前显式路径未覆盖”，不支持“内核永远无法实现”。没有 AIA get/set支持“固定标签未建立闭环”，不支持“任何厂商版本不能迁移”。限定版本和仓库可以让结论以后被新提交明确推翻。

## 把状态覆盖矩阵落到代码符号

CPU core这一行从 `kvm_riscv_get_regs_core()`开始，向上确认 `kvm_arch_get_registers()`调用，向下确认 `vmstate_riscv_cpu`字段，再追目标端 `kvm_arch_put_registers()`。四个节点都存在，才可标“代码路径闭环”；实验还要让 PC和每个 GPR偏离 reset值，才可标“已验证”。

S级 CSR这一行多一个 capability条件。`kvm_csr_cfgs`给出候选字段，register list决定宿主实际支持，get/put只访问存在项，VMState公共 CPU结构保存 QEMU字段。目标缺某个源端已使用 CSR时应失败，不能因为配置表包含同名字段就认定兼容。

浮点与 Vector分别列行。它们在 full get/put中闭环，runtime写回有意跳过；矩阵备注要写这条不变量。Vector再列 vlen参数，源目标值相等属于前置条件。实验若只用整数 workload，这两行仍标“未覆盖”，不能从代码存在改成通过。

MP state单列，入口是 `KVM_GET/SET_MP_STATE`及 capability检查，语义是 runnable/stopped而非寄存器值。多 hart测试让一个 hart运行、一个由 SBI HSM停止，迁移后状态保持。全部 hart都运行的测试无法判断该行。

timer拆成 time、compare、state与 frequency。前三项有 one-reg、runstate与 `vmstate_kvmtimer`；frequency由 KVM读取并用于 FDT/目标比较，却不在 subsection中。矩阵把前三项标“字段闭环”，frequency标“要求宿主相等，当前不转换”，并链接四个历史提交。

PLIC或模拟 AIA按具体设备 VMState列行，pending、enable、priority/route和 in-service分别制造状态。完整 KVM AIA则要寻找 device状态 get/set；固定标签没有可确认闭环，标“待验证/受限”。split把 APLIC和 IMSIC拆两行，禁止用前者的通过覆盖后者。

RAM行对应 RAM迁移与 dirty tracking，不从 VMState CPU字段取值。把 CPU写、QEMU设备 DMA、vhost写分成子项，逐项确认日志来源。memory slot只属于重建机制，在矩阵中记录“目标重新注册”，不记录源 slot编号。

MMIO未决状态、virtqueue in-flight和 eventfd生命周期归设备协议。若设备选择排空，请记录停止钩子与完成等待；若保存 in-flight，请记录字段和目标重建；两者都没有则标缺口。设备寄存器 VMState通过，不能自动把这行改为通过。

H/VS状态从 `vmstate_hyper`出发反向寻找 KVM get。TCG路径可找到权威 `CPURISCVState`，KVM固定标签缺完整 one-reg组，因此矩阵清楚显示断点在“内核到 QEMU镜像”，而非“没有序列化字段”。这种定位比一句“nested不支持”更能指导后续实现。

最后给每行四种状态：固定源码已闭环、上游补丁演进中、强推断待实验、已在指定环境验证。状态旁必须有 tag、链接和实验编号。新版本更新时逐行替换，不需要重写整章结论，也不会让一个新增 capability掩盖其他缺口。

## 面向实现者的补丁审查顺序

新增 one-reg时，先核对 Linux UAPI编号、宽度和客户机可见语义，再接 register list探测与 legacy行为。随后加入 get/put，判断 runtime、reset和 full各需要哪些操作；最后连接 VMState、版本和测试。只加 `GET_ONE_REG` helper会让调试可读，迁移仍不完整。

新增内核设备状态时，接口应允许在 vCPU停止后得到一致快照，并在目标启动前恢复。字段要描述架构状态，尽量避免导出宿主指针、线程或内部缓存；缓存应从架构字段重建。读取期间若设备仍接收 irq，UAPI还需冻结或版本一致性机制。

修改 runstate handler时，覆盖 stop、cont、迁移取消、reset和错误恢复。handler可能被每个 vCPU注册，多 hart下不要重复暂停同一 VM级对象。timer是 per-vCPU状态，AIA device则可能是 VM级；生命周期不能照搬。

优化同步时，提交说明要列出省掉的 ioctl、状态所有者不变量和不适用级别。测试同时包含用户态 exit、调试读取、reset与迁移。只有纯运行基准通过，无法证明 full restore没有被误跳过。

补 nested功能时，patch系列按能力分层更容易审查：先能力枚举和 L1可见 H，再 H/VS状态与运行 L2，再 timer/AIA和多 hart，最后迁移。每层给独立测试和失败边界。一个巨大“nested support”补丁会让性能、UAPI和迁移问题相互遮蔽。

## 本章结论的适用范围

“普通 RISC-V KVM状态可同步”只指当前显式覆盖的 core、S CSR、浮点、Vector、MP state与 timer，并要求目标 CPU和内核兼容。它不自动包含任意新扩展、所有 PMU/debug状态、in-kernel AIA或厂商 one-reg。实际命令行每增加一项设备和能力，都要回到覆盖矩阵增加一行。

“模拟 irqchip较容易迁移”描述状态位于 QEMU VMState的结构优势，不代表所有版本已经经过完整回归。pending、claim、路由修改和多 hart仍需实验。反过来，“in-kernel AIA未闭环”限定在官方固定标签与随附 UAPI；后续合入或发行版补丁需要重新判断。

“Linux nested v1不能运行 L2”来自该版 cover letter，不能推广成 RISC-V H架构能力不足，也不能否认 TCG能够模拟 H语义。它说明的是当时 KVM nested实现范围。宿主 H加速普通 L1、L1看到 H、L2执行和 nested migration继续保持四项独立结论。

“frequency不兼容”依据当前 timer实现：迁移字段没有转换频率，目标 put阶段只比较并报告。若未来 QEMU引入固定虚拟 timebase或换算协议，这条限制可能变化；在本版部署中仍应作为硬性前置检查。

实验通过也只对记录的硬件、内核和 QEMU commit有效。上游功能快速演进，复现报告必须保存 register list、FDT与实际 irqchip模式。书稿以后切换源码锚时，先重跑负面与 pending状态测试，再更新措辞；仅把 `v11.1.0`替换成新版本不足以证明结论延续。

阅读这些限制时，还要把“无法证明”与“已经证明失败”分开。固定源码缺少状态接口时，本书写待验证或未闭环；上游邮件明确给出失败范围时，才记录对应版本不能完成；实验得到错误时，还要排除命令行、宿主配置和补丁不一致。证据层次写清以后，读者既不会把开发中的功能当成现状，也不会把暂时缺口误解为永久结论。

对于工程部署，保守标签应转成具体策略：选择显式 CPU集合，锁定 machine与 irqchip模式，在调度目标前比较 timer和 Vector参数，禁用没有保存恢复闭环的内核设备，并保留迁移前自检。对于上游开发，同一标签则转成待补接口、测试和文档。两类读者面对相同源码，可以采取不同动作，但都应引用同一版本证据。

迁移失败报告还应指出所有权停在哪一侧。若源端仍在运行，问题属于前置协商；若源端已经停止、目标尚未运行，要记录最后成功加载的 section；若目标运行后客户机偏离，则需要比较首个 `KVM_RUN`前的 CPU、timer和 irqchip快照。只写“迁移失败”无法判断是兼容拒绝、状态缺失还是恢复顺序。

对于能够回滚的失败，验证源端继续运行后的 timer、中断和后端 I/O，不要只确认进程存在。stop/cont handler、eventfd和 dirty log都经历过状态切换，回滚本身可能留下静默损坏。一次完整的负面测试应包含拒绝、恢复源端服务和再次成功迁移三个阶段。

归档迁移样本时同时保存源端与目标端的能力清单、QEMU日志、内核 trace和客户机自检结果，并标明数据中是否包含敏感 RAM。公开问题报告可以删减客户机内容，但不能删掉版本、模式和首个失败字段；否则上游无法判断应修改 QEMU、Linux UAPI还是部署配置。

## 实验一：核对 one-reg 与 VMState

::: {.hands-on}
配套英文实验手册：[`inspect-one-reg-state`](../experiments/part-03-riscv-hardware-virtualization/chapter-15-kvm-state-and-migration/inspect-one-reg-state/README.md)。

在 RISC-V KVM宿主上启动包含 F/D、Vector和多 hart的最小客户机。先用 `KVM_GET_REG_LIST`保存实际 ID集合，再在 `kvm_arch_get_registers()`、timer runstate handler和 `vmstate_riscv_cpu`保存路径加入断点或 trace。客户机把 GPR、浮点、Vector和合法 S CSR写成可识别模式，随后执行 QMP `stop`。

建立三列表：客户机可见状态、权威所有者、迁移字段。确认 core/S CSR/FP/Vector由 get同步，timer从独立 handler取得，MP state走专用接口。再查 H/VS寄存器是否出现在实际 register list与 get路径；若缺少，结论写“当前同步未覆盖”，不能用 `vmstate_hyper`字段存在补齐证据。
:::

## 实验二：测试普通迁移边界

::: {.hands-on}
配套英文实验手册：[`test-migration-boundary`](../experiments/part-03-riscv-hardware-virtualization/chapter-15-kvm-state-and-migration/test-migration-boundary/README.md)。

准备能力相同的源目标 RISC-V KVM宿主，显式固定 CPU扩展、vlen、machine version与 irqchip模式。客户机同时运行 Vector校验、周期 timer、内存写入和一个可校验的 virtio块请求。迁移前制造 pending外部中断，分别在模拟 PLIC或 AIA模式执行迁移。

目标恢复后核对寄存器模式、timer连续性、内存校验、块写恰好一次以及 pending中断的目标 hart和次数。随后改变一个变量做负面测试：timebase、vlen、扩展或 AIA模式。预期管理层在迁移前明确拒绝；若只是日志警告或恢复后异常，要记录为兼容缺口。
:::

## 实验三：为 nested 建立四层验收表

::: {.hands-on}
本实验复用 [`inspect-one-reg-state`](../experiments/part-03-riscv-hardware-virtualization/chapter-15-kvm-state-and-migration/inspect-one-reg-state/README.md) 采集状态覆盖，复用 [`test-migration-boundary`](../experiments/part-03-riscv-hardware-virtualization/chapter-15-kvm-state-and-migration/test-migration-boundary/README.md) 的恢复判据；统一入口见[第 15章英文实验索引](../experiments/part-03-riscv-hardware-virtualization/chapter-15-kvm-state-and-migration/README.md)。

结果表固定四行：宿主 H加速普通 L1、QEMU向 L1暴露 H、L1实际运行 L2、活动 L2迁移。每行分别填写硬件、Linux/QEMU commit、必要补丁、命令、成功判据和第一个失败点。对 2026 Linux nested v1按 cover letter标注“尚不能运行 L2”，第三行不得用 L1启动成功替代，第四行保持“未闭环”。

未来系列能够运行 L2后，再给 L2加入二阶段缺页、虚拟 timer、AIA中断与多 vCPU负载，并在这些状态活动时迁移。只有 H/VS one-reg覆盖、内核派生状态可重建、irqchip与 timer状态可恢复、目标 capability兼容四项同时成立，才把第四行改为通过。
:::

## 证据审查清单

先从固定 tag列状态，不从功能名称出发。搜索每个 guest可见字段的运行时所有者、get、VMState、post-load和 put；记录 needed条件和版本。若值在 KVM device，寻找明确的 device attr保存恢复，而不是假定 QEMU同名对象有效。

再看 Git历史回答设计原因。timer的四个提交分别建立 one-reg上下文、runstate暂停、VMState与 FDT频率，说明分层是按生命周期形成；FP/Vector优化系列说明 runtime与 full不能混；AIA save/restore晚于候选标签，说明当前迁移边界仍在演进。

邮件中的每个结论要标版本。cover letter描述该版范围，review回复可能只是建议，最终提交才代表 QEMU当前选择。Linux nested v1明确不能运行 L2，是直接上游陈述；它仍不能替代未来合入状态。更新书稿时先换源码锚，再重新跑实验，不能只把版本字符串改新。

最后审查负面路径：目标缺 one-reg、vlen不同、timer频率不同、AIA模式不同、pending中断不可导出、设备后端无法 quiesce时，系统怎样失败。可迁移性由最弱的一项状态决定；其他九十九项通过，缺一项仍可能让客户机恢复后静默偏离。

## 小结

RISC-V KVM迁移是一份分布式状态协议。vCPU退出后，QEMU按需读取 core、S CSR、浮点与 Vector，MP state和 timer走独立路径；VMState按扩展和 accelerator使用 subsections。RAM依靠 dirty tracking，设备还要处理 DMA和 in-flight I/O。恢复顺序决定这些字段何时重新产生中断和时间推进。

提交史解释了 timer为何由 one-reg、runstate、VMState与 FDT共同完成，也揭示当前限制：frequency没有作为可转换状态迁移，异频目标必须视作不兼容；完整 in-kernel AIA在 `v11.1.0-rc0`没有可确认的保存恢复闭环。模拟、split和 hwaccel模式需要分别报告。

H扩展进一步扩大状态面。TCG的 `vmstate_hyper`能够保存其权威 H/VS字段，当前 RISC-V KVM显式 get/put与 UAPI却没有展示完整对应组；Linux nested v1又明确尚不能运行 L2。因此本书只确认宿主 H加速和能力表达路径，把 L2运行标为演进中，把 active nested migration标为未闭环。这条边界以后可以更新，但只能由新的固定源码、上游合入记录和带状态的迁移实验共同改变。
