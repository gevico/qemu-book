# 谁在执行，谁拥有状态

同一台 RISC-V `virt`，把 `-accel tcg` 改成 `-accel kvm`，UART 地址、DTB 和大部分设备对象仍在原处，vCPU 内部却换了世界。TCG 把 RISC-V 指令翻译成宿主代码；KVM 让内核和硬件推进客户机。程序计数器、整数寄存器和 CSR 都属于同一颗客户机 CPU，但运行期间哪一份副本最新、怎样暂停、如何注入中断，答案已经不同。

这类差异不能散落成全项目的 `if (tcg_enabled())` 与 `if (kvm_enabled())`。Machine、GDB、迁移和设备都需要对 CPU 发出共同请求：创建 vCPU、停止、唤醒、reset、同步状态、处理中断。QEMU Accelerator 抽象把这些请求固定下来，让执行机制各自实现。它统一的是生命周期和控制语义，没有要求各后端走同一条数据面。

## Accelerator 选择的是执行机制

QEMU 系统模拟先创建客户机机器，再选择一种 accelerator 推进 CPU。当前[系统模拟导言](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/system/introduction.rst)列出多种后端，它们依赖不同宿主操作系统和架构：

| Accelerator | 执行来源 | 适用边界 |
|---|---|---|
| TCG | QEMU JIT 生成宿主代码 | 可跨 ISA，覆盖广，便于插桩；执行成本由软件翻译承担 |
| KVM | Linux 内核与硬件虚拟化扩展 | 宿主/客户机架构与内核能力匹配；vCPU 通过 `/dev/kvm` 运行 |
| HVF | macOS Hypervisor Framework | macOS 上受支持的 x86/Arm 组合 |
| WHPX | Windows Hypervisor Platform | Windows 上受支持的 x86/Arm 组合 |
| NVMM | NetBSD 内核虚拟化接口 | NetBSD/x86 |
| Xen、MSHV 等 | 对应 hypervisor 或内核接口 | 受宿主角色、架构和项目配置限制 |

表格只说明执行来源。每种后端仍要与 QEMU Machine、CPU 类型、MemoryRegion、设备和管理面配合；调试、确定性重放、嵌套虚拟化、irqchip 和迁移能力也不完全对齐。本书所有动态调用链固定到 RISC-V，实际对照只有 TCG 与 KVM；其他 accelerator 用来说明公共接口为何不能写成二选一开关。

## 其他 Accelerator 共享什么合同

一种 accelerator 接入 QEMU 时，至少要回答五个共同问题：怎样探测宿主能力并初始化 VM 级资源；哪条宿主线程推进 vCPU；客户机 RAM 怎样登记给执行者，MMIO 又怎样返回设备模型；寄存器和中断状态何时在后端与 `CPUState` 之间同步；调试、暂停、reset 和迁移可以得到多强的停止保证。各后端使用不同宿主接口，回答的仍是同一组责任。

| 路径 | 宿主控制接口与 vCPU 执行者 | 内存和设备边界 | 状态、调试与迁移边界 |
| --- | --- | --- | --- |
| TCG | QEMU vCPU 线程执行 JIT 生成代码 | AddressSpace 与 SoftMMU 直接分派 RAM/MMIO | `env` 由 QEMU 持有，插桩和单步范围最完整；迁移无需向硬件后端取回寄存器 |
| KVM | `/dev/kvm`、VM/vCPU fd 与宿主硬件 | RAM 注册为 memory slot，用户态 MMIO 通过 exit 返回 QEMU | 运行状态在内核/硬件，查询与迁移前需同步；irqchip、timer 等状态要逐项确认 |
| HVF、WHPX、NVMM、MSHV | 对应宿主系统的 hypervisor API 与硬件 guest mode | QEMU 把 RAM 映射交给平台 API，设备访问按该 API 的退出模型返回 | 寄存器、断点、脏页和迁移能力受平台接口限制，不能从 KVM 行为类推 |
| Xen | Xen hypervisor 推进 vCPU，QEMU 常作为 device model | 客户机内存通过 Xen 的映射与事件机制接入设备模型 | CPU 控制权不只在 QEMU，暂停、状态保存和迁移需与 hypervisor 工具栈协调 |

这张表是接口级比较，没有声称 HVF、WHPX、NVMM、MSHV 或 Xen 能运行本书的 RISC-V 动态实验。它说明 accelerator 抽象不能只提供一个 `run()`：执行循环一旦移出 QEMU，内存注册、状态交接和生命周期也必须一起成为合同。后续章节用 RISC-V TCG/KVM 把这五项逐一跑通，读者再阅读其他后端时，可以沿相同问题定位差异。

在 RISC-V 宿主之外，`/dev/kvm` 即使存在也不能执行 RISC-V 客户机。x86 KVM 提供的是 x86 硬件虚拟化，Arm KVM 提供 Arm 执行环境。跨 ISA 时要使用 TCG，或把实验移到匹配宿主。QEMU 不会把 KVM 缺少的 RISC-V 指令临时交给 TCG 混跑，那会让寄存器、异常和性能边界失去可控所有者。

:::: {.quick-quiz}
一台 x86 Linux 主机有可访问的 `/dev/kvm`，为什么 `qemu-system-riscv64 -accel kvm` 仍会失败？

::: {.quick-answer}
KVM 依赖宿主硬件与内核提供对应 ISA 的 guest 执行模式。x86 KVM 不能直接执行 RISC-V 指令；QEMU 的 RISC-V Machine 和设备模型存在，也无法补上所需硬件执行环境。跨 ISA 应选择 TCG。
:::
::::

## 当前抽象分成机器级与 vCPU 级

在 `v11.1.0-rc0` 中，[`AccelClass`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/include/accel/accel-ops.h)围绕 accelerator 对象和 Machine 生命周期组织：`init_machine` 建立后端所需的 VM 级资源，`cpu_common_realize` 参与 CPU realize，`setup_post`、`pre_resume_vm` 和统计等回调处理控制面。具体 accelerator 作为 QOM 类型被选择，`AccelState` 保存本次实例状态。

[`AccelOpsClass`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/include/accel/accel-cpu-ops.h)更靠近 vCPU 执行。它要求后端提供 vCPU thread 创建和中断处理，并可实现 kick、idle 判断、reset hold、寄存器同步、虚拟时钟和 GDB breakpoint。这个拆分避免把 Machine 只调用一次的初始化与高频 vCPU 操作塞进同一张表，也让用户态模拟与系统模拟可以复用合适部分。

接口有一项刻意保留的非对称性。`synchronize_post_reset()` 与 `synchronize_post_init()` 以 QEMU 表示为参考，把状态送往硬件 accelerator；`synchronize_state()` 与 `synchronize_pre_loadvm()` 以 accelerator 为参考，把运行后的状态取回 QEMU。这段方向直接写在头文件注释里，调用者无需猜“sync”究竟覆盖哪一边。

并非每个可选回调都由所有后端实现。TCG 没有把寄存器送进 `/dev/kvm` 的步骤，硬件后端也不拥有 TCG Translation Block；某些 accelerator 没有 reverse execution 或同样的 breakpoint 能力。公共层检查能力，再使用可用接口。把空回调理解成“后端自然等价”，会把功能缺口拖到运行期。

:::: {.quick-quiz}
为什么 `AccelOpsClass` 同时提供“QEMU → accelerator”和“accelerator → QEMU”的同步方向？

::: {.quick-answer}
reset、初始化或 GDB 修改后，QEMU 表示包含要执行的新状态，需要推给后端；vCPU 运行后，最新寄存器位于执行后端，需要在调试、查询或迁移前取回。无方向的同步容易用旧副本覆盖新副本。
:::
::::

## RISC-V CPU 怎样走到 vCPU 线程

[`target/riscv/cpu.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/cpu.c)中的 `RISCVCPU` 继承通用 `CPUState`，并包含 `CPURISCVState env` 与 CPU 配置。Machine/hart array 创建实例后，属性和型号默认先形成候选扩展集合；`riscv_cpu_finalize_features()` 再让 TCG 或 KVM 路径完成各自能力校验。TCG 可以实现软件扩展，KVM 暴露集合还受宿主硬件与内核 UAPI 约束。

`riscv_cpu_realize()` 调用通用 CPU realize，注册 GDB 所需状态，然后进入 `qemu_init_vcpu()` 并执行 reset。[`system/cpus.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/system/cpus.c)中的 `qemu_init_vcpu()` 给 CPU 建立 AddressSpace，随后调用已注册 accelerator 的 `create_vcpu_thread()`，等待线程完成创建。vCPU 初始为 stopped，Machine、reset 与 incoming migration 准备好以后，runstate 才允许它执行。

TCG 实现位于 [`accel/tcg/tcg-accel-ops.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/tcg/tcg-accel-ops.c)及 MTTCG 相关文件，RISC-V 目标语义在 [`target/riscv/tcg/`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/target/riscv/tcg)。KVM 公共循环位于 [`accel/kvm/`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/accel/kvm)，RISC-V capability 与寄存器对接落在 [`target/riscv/kvm/kvm-cpu.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c)。公共创建线走到这里分流，设备模型仍通过 Machine 和 AddressSpace 留在同一进程语义中。

这条调用链解释了三个相互独立的选项。`-machine virt` 决定客户机平台，`-cpu` 决定 RISC-V 能力与型号约束，`-accel` 决定状态由哪套执行机制推进。组合需要校验，概念不能合并。TCG 模拟的 RISC-V CPU 可以带 H 扩展，让客户机内部运行 hypervisor；这次宿主执行仍由 TCG 完成。

## CPU 型号是一次能力求交

RISC-V CPU 不能只用 `rv64` 一个名称描述。基础扩展、Z 扩展、privileged spec、页表模式、PMP、向量长度与厂商 id 会共同决定客户机可见能力；某些扩展彼此蕴含，另一些组合受规范约束。用户属性、具名型号默认、Machine 要求与 accelerator 能力要在 realize 前求交，得到这次运行真正能承诺的 CPU。

TCG 能力来自目标翻译器和 helper 是否实现，KVM 能力来自宿主硬件、内核和 RISC-V KVM UAPI。相同属性在 TCG 下可用，在当前 KVM 宿主上可能被拒绝。启动失败比静默删掉扩展可靠：固件和 Linux 会从 ISA string、CSR 或设备树探测能力，声明与执行不一致会把错误推迟到客户机选用某条指令之后。

realize 后，定义型号的结构性属性通常冻结。运行中打开一个改变译码或寄存器集合的扩展，会让已有 TB、GDB 寄存器描述、迁移格式和 KVM vCPU 配置同时过期。客户机通过 CSR 打开已有能力的某种运行模式，是架构状态变化；管理层给 CPU 增加一项原本不存在的能力，属于型号变化。两者需要不同失效与兼容策略。

reset 也沿这条边界工作。`riscv_cpu_reset_hold()` 恢复 PC、特权级和 CSR 初态，同时保留型号配置、hartid 与 Machine 提供的 reset vector。TCG 私有缓存需要失效，KVM 路径要把 QEMU 参考状态同步到内核 vCPU。把整个 `RISCVCPU` 清零会连扩展配置、锁和对象关系一起破坏。

这组约束让 CPU 型号、状态与执行后端可以分别演进。新增 RISC-V 扩展先定义客户机承诺，再为 TCG/KVM 接上实现；某个后端缺失时给出能力诊断。Machine 只提出平台需要，不在板级代码里复制译码与寄存器逻辑。

## 同一个 `env`，不同的新鲜度

`CPURISCVState` 保存整数寄存器、PC、特权状态和大量 CSR 表示。TCG 翻译器围绕 `env` 生成代码，运行时某些值还会停留在宿主寄存器或 TCG 临时量中。异常与 TB 退出必须按约定恢复可报告状态，C helper、GDB 和中断处理才能读取一致值。即使纯用户态结构就在眼前，也要等到安全点。

KVM 的距离更远。执行 `KVM_RUN` 时，硬件和内核 vCPU 持有最新寄存器，QEMU 中的 `env` 不会每条指令后自动刷新。MMIO exit 不必拉回全部 CSR；GDB 停止、迁移保存或特定管理查询才按需同步。继续运行前，QEMU 修改的 PC 或寄存器又要写回内核。

因此，`env` 是 QEMU 各子系统交流 RISC-V 架构状态的共同表示，运行中未必是每个字段的权威副本。读代码时给字段附上三个问题：谁最后更新，最近同步方向，当前调用者是否已经让 vCPU 停在允许读取的位置。设备回调直接读取任意 `env` 字段，往往只能在某一种 accelerator 下碰巧正确。

## 观测者决定需要同步多少状态

GDB 读取全部通用寄存器，迁移保存架构状态，设备 MMIO exit 只需要访问地址与数据，`info registers` 又可能在暂停后查询一组字段。四类观察者的同步范围不同。KVM 若每次 exit 都获取所有 CSR，正确性容易解释，频繁 ioctl 会吞掉硬件执行收益；只取最少字段则要求接口精确标注前置条件。

迁移建立的是最强边界之一。源端先停止 vCPU，把 accelerator 权威状态同步回可序列化表示，再保存 CPU 与设备；目标端创建对象、加载状态并执行 post-load，最后把 QEMU 参考状态推给目标 accelerator，全部 hart 准备好后才能恢复。任意一颗 vCPU 提前执行，都可能看到尚未恢复的中断控制器或内存状态。

GDB 修改 PC 走相似方向，但范围更小。管理层先让目标 CPU 停止，读取当前后端状态，写入新 PC；TCG 要确保旧 TB 不会按旧 key 继续，KVM 要在下一次 `KVM_RUN` 前把新值送入内核。调试器显示写入成功，只证明用户态 setter 返回，恢复后第一条指令才验证同步闭环。

dump 与统计可以接受某些近似，迁移不能。接口应声明快照语义：运行中读取的计数可能来自不同瞬间，暂停后的 CPU 寄存器更强，经过 drain 与全局 stop 的迁移状态最强。为了展示方便而让每次查询都暂停所有 vCPU，会把管理面观测变成性能干扰。

:::: {.quick-quiz}
KVM 因一次 UART MMIO 退出回到 QEMU，能否马上认为 `CPURISCVState` 中所有 CSR 都是最新值？

::: {.quick-answer}
不能。退出只把处理该原因所需的信息交回用户态，寄存器同步通常按消费者需要进行。读取某个 CSR 前要检查 RISC-V KVM 路径是否在该同步点取回它，以及当前线程是否已经停止 vCPU。
:::
::::

## 跨线程修改要经过安全点

主线程、vCPU、IOThread 和工作线程可以同时存在。管理命令要求改 PC、刷新 TLB 或 reset CPU 时，直接从主线程写 `env` 会同正在执行的 TCG 代码竞争，也可能绕过 KVM 内核副本。[`run_on_cpu()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/system/cpus.c)把工作排到目标 CPU，通过 kick 促使 vCPU 离开执行后端，再在 CPU 线程的安全位置运行回调；异步版本只排队，参数必须活到未来回调完成。

kick 只负责让执行者有机会观察请求。生产者先发布 work list 或退出标志，再通过 accelerator 的 `kick_vcpu_thread` 唤醒；消费者返回 CPU loop 后读取真实状态、处理 queued work。把通知次数当成请求计数，会在通知合并时丢工作。同步 `run_on_cpu()` 还可能等待，调用者若持有目标 vCPU 返回所需的锁，就会形成死锁。

暂停所有 vCPU 是一组握手。每颗 CPU 可能处于 TCG TB、KVM ioctl、设备回调或 halted 状态，停止方设置请求并 kick，随后等待所有线程确认 stopped。迁移和一致调试在这个条件上继续建立更强的快照；普通 QMP 查询未必停止所有 I/O 后端，返回值可能只是运行中近似状态。

中断走反方向。UART 或 virtio 在某个执行上下文更新设备状态，通过 qemu_irq 和中断控制器传播到目标 CPU，accelerator 再把 pending 条件送入 TCG 或 KVM，并在需要时 kick halted vCPU。设备不应直接写 `env->pc` 或调用 RISC-V KVM ioctl；共同中断接口保留了后端边界。

## 主循环、BQL 与 AioContext 管另一组所有权

主循环等待文件描述符、timer、bottom half 和管理事件，Machine 控制与大量传统设备逻辑仍在它或 BQL 保护范围内。IOThread 可以拥有独立 `AioContext`，让支持迁移上下文的块或设备数据面并行运行；协程只是在所属线程中挂起和恢复，不会把阻塞系统调用自动移走。

BQL 为历史上大量共享状态提供粗粒度串行化。长回调持锁会阻塞其他需要 BQL 的 vCPU 退出和管理操作，现代数据面逐步使用 AioContext 所有权、设备锁、原子变量与 RCU 缩小范围。选择细锁前要先写出不变量：哪个线程修改，reset/迁移从哪里进入，对象凭什么存活。删除 BQL 后只测稳定吞吐，往往会漏掉关闭和热拔除竞态。

2024 年 Stefan Hajnoczi 的 [`195801d7`](https://gitlab.com/qemu-project/qemu/-/commit/195801d700c008b6a8d8acfa299aa5f177446647) 把 `qemu_mutex_lock_iothread()` 改名为 `bql_lock()`。提交说明回顾了名称来源：早期 KVM 把 vCPU 与主循环线程分开，主循环曾被称为 iothread；后来 `--object iothread` 表示另一种独立概念，旧名开始制造歧义。Paul Durrant、Cédric Le Goater、Harsh Prateek Bora、Akihiko Odaki 等 reviewer，以及多位 subsystem 开发者共同确认这次跨范围重命名。改名没有缩小任何临界区，却让“主线程身份”“IOThread 对象”和“全局锁”重新分开。

## 抽象也在继续清理隐式全局状态

Accelerator 接口不是完成后静止的框架。Philippe Mathieu-Daudé 在 2025 年提交 [`9d01d2e8`](https://gitlab.com/qemu-project/qemu/-/commit/9d01d2e86d450f12f275bd64aeb022e8423e220c)，把 `AccelState` 显式传给 `AccelClass::init_machine()`，理由是避免回调再调用 `current_accel()` 取得隐式全局对象。Richard Henderson、Alex Bennée 和 Zhao Liu 给出 review。相邻的 [`487b25c9`](https://gitlab.com/qemu-project/qemu/-/commit/487b25c9d93add2e0e58275d7c1ef89810fad763) 让 `AccelClass` 持有 `AccelOpsClass` 引用。

这组改动解释当前代码为何区分 class、state 和 ops。显式实例参数让依赖可见，也方便测试和未来扩展；运行热路径仍通过紧凑的 vCPU ops 进入后端，没有为形式统一引入层层对象查找。控制面偏向可组合与可检查，数据面偏向直接和可测量，两种取向在 accelerator 边界相遇。

抽象的停止条件同样明确。它不抹平能力差异，不保证所有后端支持相同 CPU 型号、调试、时间和迁移组合，也不替 Machine 保存设备状态。看到公共回调只能说明上层可以提出同一类请求，最终效果还要核对具体 accelerator、目标 RISC-V 实现与宿主能力。

## 性能要按边界事件测量

“KVM 快、TCG 慢”只能提示大方向。计算密集负载中，KVM 减少指令翻译成本；频繁 MMIO、端口访问或中断会反复退出到用户态，设备模型和线程切换仍可能主导。TCG 的表现则受 TB 命中、链跳、SoftMMU、helper 和多 vCPU 同步影响。两个总耗时相近，也可能有完全不同的瓶颈。

测量应先统计边界事件。TCG 观察 TB 生成、失效与 helper；KVM 观察 exit 类型、频率与状态同步；设备路径观察跨线程通知、BQL 等待、vhost 下沉和数据复制。总时间用于确认收益，事件用于解释收益来自哪里。没有事件分解，宿主调度和缓存差异很容易被写成 accelerator 原理。

优化通常会移动所有权。vhost 把 virtio 数据面移出 QEMU 主循环，IOThread 把后端工作移到另一事件域，kernel irqchip 把部分中断状态下沉。每次移动会减少某类退出或锁竞争，也要补上迁移、错误恢复、能力协商和 teardown。少一次用户态往返是收益，状态跨边界的协议则是新增成本。

:::: {.quick-quiz}
某 accelerator 实现了 `create_vcpu_thread` 和 `handle_interrupt`，是否足以证明它支持 QEMU 的全部 GDB 与迁移能力？

::: {.quick-answer}
不够。这两项是 vCPU 基础接口，GDB breakpoint、状态同步、时钟、CPU 特性和迁移还依赖其他回调及目标实现。公共类型只定义可协作位置，能力需要逐项查询和测试。
:::
::::

## 实验：画出状态所有权的转移

::: {.hands-on}
先运行 [Inspect the accelerator contract](../experiments/part-01-system-foundations/chapter-06-cpu-and-accelerator-models/inspect-accelerator-contract/README.md)，从 `riscv_cpu_realize()`、`qemu_init_vcpu()` 走到 TCG 与 KVM 的 thread/create、kick、reset 和 synchronize 实现。选择 PC、整数寄存器与中断 pending 三类状态，分别记录初始化、运行、退出、GDB 停止和迁移前的权威位置与同步方向。

再运行 [Map thread topology](../experiments/part-01-system-foundations/chapter-03-main-loop-and-threads/map-thread-topology/README.md)，比较单线程 TCG 与 MTTCG 的宿主线程。若有 RISC-V KVM 宿主，加入 KVM 对照；x86/Arm 主机上的 `/dev/kvm` 不能算作完成。报告应把 main loop、vCPU、可选 IOThread 和 helper thread 画成泳道，通知与函数执行使用不同箭头。

最后触发一次 `stop`/`cont`，观察 runstate 与 vCPU 线程；能够使用 GDB 时，在 stopped 状态读写 PC，确认恢复前经过哪条 accelerator 同步。实验关注边界，不比较一次 wall-clock 性能。缺少 KVM 环境时，静态调用图与 TCG 动态结果分栏保存，不能把前者写成实机验证。
:::

## 小结

Accelerator 决定客户机 CPU 由谁执行，也决定运行期间状态的权威位置。`AccelClass` 管实例与 Machine 级生命周期，`AccelOpsClass` 把 vCPU 创建、kick、中断、reset、同步和调试请求交给具体后端。RISC-V CPU 对象在 realize 时完成能力求交，通过 `qemu_init_vcpu()` 进入 TCG 或 KVM 线程；Machine 与设备继续维持同一份客户机平台。

跨线程修改必须先让 vCPU 到达安全点，跨后端读取必须确认同步方向。主循环、BQL、AioContext 与对象引用又管理设备和控制面的执行归属。至此，第一篇从“怎样运行一段异构程序”走到“谁在完整机器中推进状态”。第二篇将进入 TCG 内部，追问早期 dyngen 已经能够动态翻译以后，QEMU 为什么还要建立自己的 IR、优化器和代码生成后端。
