# 谁拥有状态：迁移、兼容与 RISC-V H/KVM

一台 RISC-V 虚拟机正在运行时，最新的通用寄存器和 CSR 可能在 KVM vCPU，普通 RAM 同时被客户机 CPU、QEMU 设备和 vhost 后端修改，timer 在宿主内核推进，APLIC 可能位于 QEMU，IMSIC 可能位于 KVM。迁移线程若直接序列化 `CPURISCVState` 和设备对象，得到的只是若干用户态镜像；它们未必代表同一个客户机时刻。

迁移必须先制造一个一致边界：阻止状态继续变化，让每个执行者交出自己持有的最新值，把共享内存变化汇总到脏页集合，再按稳定格式发送。目标端要以兼容的 machine、CPU capability、timer 和 irqchip 模式重建这些状态。恢复执行以后，客户机能观察到的寄存器、内存、设备完成与中断顺序必须连续。

本章用这个要求审计 QEMU `v11.1.0-rc0` 的 RISC-V KVM 路径。重点不在背诵迁移函数，而在建立所有权方法：每个字段问“谁会修改、谁是权威、何时同步、格式如何版本化、目标端能否接收”。同样的方法也适用于 reset、快照、调试和崩溃分析。

## 先画状态所有权矩阵

KVM 运行时，状态没有统一放在一个结构体中。下面的矩阵描述常见权威位置；停机与同步会让部分所有权转移。

| 状态 | vCPU 运行时的主要权威 | QEMU 怎样取得或协调 | 目标端约束 |
|---|---|---|---|
| core/CSR/FP/Vector | KVM vCPU 与硬件 | 停止 vCPU，one-reg get | CPU model、扩展、寄存器 ID 可写 |
| RAM 内容 | QEMU memory backend 的共享页 | KVM/QEMU/vhost 脏页合并，发送页面 | 内存布局、页大小与 backend 能重建 |
| 用户态设备 | QEMU 设备对象与后端 | VMState、设备 quiesce、in-flight 收拢 | machine version 与设备 feature 兼容 |
| KVM timer | 内核 vCPU timer | timer one-reg get/put，VMState 子段 | timebase frequency 与语义兼容 |
| APLIC/IMSIC | 取决于 emul/full/split | QEMU VMState 或 KVM device state | 相同/可转换的 irqchip 模式与状态接口 |
| vhost 数据面 | 内核 worker 或 vhost-user 进程 | stop、日志、vring 与 in-flight 协议 | 后端 feature、协议与恢复能力兼容 |

矩阵中的“权威”指谁能在当前阶段继续推进状态，不代表数据只存在一份。RAM 页面映射在 QEMU 进程，KVM 通过同一后端访问；QEMU 的 `env` 保留 CPU 字段，却可能落后于硬件；virtqueue ring 在 RAM，后端还可能持有尚未提交的请求。迁移正确性依赖阶段切换，而非寻找一个永远最新的总结构体。

所有权还要覆盖派生状态。G-stage TLB 可以从 slot 与页表重建，通常无需直接迁移；设备中断线路若能从控制器状态和队列状态重新计算，也可能不单独编码。能重建必须由明确 invariant 支撑，不能因为字段没出现在 stream 中就假设它无关紧要。

## 停机窗口怎样形成一致切面

pre-copy 阶段，源端 vCPU 和设备仍在运行，迁移线程发送 RAM 初始副本并周期性同步 dirty set。此时 CPU、timer 和设备 VMState 尚不能作为最终值发送，因为它们会继续变化。管理层根据剩余脏页、带宽与策略决定进入 stop-and-copy，QEMU 把运行状态切到迁移停机并 kick 所有 vCPU，使阻塞在 `KVM_RUN` 的线程返回。

vCPU 到达停止点后，QEMU 才能从 KVM 拉取寄存器与 timer。设备侧先阻止新请求，再让 IOThread、vhost 或 vhost-user 后端完成/移交 in-flight 工作，刷新可能写入 RAM 的数据；随后收集最后 dirty set。irqchip 与 pending interrupt 必须在设备完成状态稳定后取得，否则“请求已完成”与“中断是否已发出”可能来自两个时刻。

一种便于审计的顺序如下：

```text
stop accepting new device requests
        |
kick vCPUs and wait for every KVM_RUN to exit
        |
drain backend in-flight work and flush RAM writes
        |
sync CPU/timer/irqchip and read the final dirty set
        |
send remaining RAM, device state, and CPU state
        |
restore in dependency order, validate, then run
```

具体设备可能调整局部顺序，但必须证明调整不会漏写。例如后端要靠 vCPU 消费完成中断才能排空时，完全先停 vCPU 会形成等待环；实现可以先进入 draining，再在明确点停 vCPU。审计迁移死锁时，应画出每个线程等待的条件，而非只观察主迁移协程。

目标端的恢复顺序同样有依赖。RAM 与 slot 要先就绪，设备才能解析 vring 地址；irqchip 路由要建立，pending interrupt 才有落点；CPU/timer 状态写入后，vCPU 仍应保持停止，直到全部设备 post-load 成功。任何 post-load 失败都应阻止部分 vCPU提前执行，否则目标会在不完整平台上推进客户机。

停机时间因此只是协议最后一段，迁移正确性横跨全程。过早发送会变化的状态、过晚开启 dirty logging、目标端提前运行，都可能在总停机时间看似漂亮时留下损坏。性能优化要在一致切面成立之后进行。

:::: {.quick-quiz}
QEMU 已经有完整的 `CPURISCVState`，为什么迁移前还要从 KVM 读取寄存器？

::: {.quick-answer}
`KVM_RUN` 期间真实指令由内核和硬件推进，用户态 `env` 不会逐指令更新。停住 vCPU 后，QEMU 要用 one-reg 把权威状态拉回，随后 VMState 才能序列化同一停机点的寄存器。
:::
::::

## `vcpu_dirty` 记录同步方向

通用 KVM 层用 `CPUState::vcpu_dirty` 表达用户态 CPU 镜像是否可能需要写回内核。当前 [`kvm_cpu_synchronize_state()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/kvm/kvm-all.c#L3187)看到该标志为 false 时，在对应 vCPU 线程上调用 `kvm_arch_get_registers()`，然后将它设为 true。此时 QEMU 已取得一份可读、可被 reset/迁移代码修改的状态。

重新运行前，`kvm_arch_put_registers()` 根据 `KvmPutState` 等级把所需字段写入内核；成功后标志清为 false，表示 KVM 再次成为运行权威。这个名字容易造成误解：true 不只表示“某个寄存器刚被修改”，也表示用户态副本处于需要在下一次运行前同步的阶段。读代码时要结合 get/put 转移方向判断。

RISC-V [`kvm_arch_get_registers()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c#L1341)依次取得 core、CSR、FP 和 Vector。put 路径先写 core 与 CSR；对 `KVM_PUT_RUNTIME_STATE`，当前实现跳过 FP/Vector，因为前一次 `KVM_RUN` 退出后内核已经持有正确值，QEMU 的 exit handler 不会修改它们。根据客户机是否启用 FP/Vector，该优化每次 vCPU exit 省去 36–68 次 `KVM_SET_ONE_REG`；完整配置约为 68 次。reset 或完整恢复仍会写 FP/Vector。

这个优化展示了性能与 invariant 的正确结合。它没有假设 FP/Vector 永远不重要，而是把省略条件限定为 runtime put，并明确 QEMU 在该阶段不修改这些字段。将来若某个 exit handler 开始改 Vector 状态，必须同步更新这个约定；只在 benchmark 中看到 ioctl 减少，无法证明优化安全。

同步还必须发生在 vCPU 线程可接受的上下文。QEMU 通过 `run_on_cpu` 把 get 操作安排到目标 vCPU，避免管理线程与正在运行的 ioctl 并发读写。暂停全 VM 不等于所有寄存器自动进入用户态，迁移调用链仍要显式触发同步。

## RAM 脏页是一份合并账本

pre-copy 迁移先发送大部分 RAM，同时让客户机继续运行；之后反复发送上轮以来被写脏的页面。当剩余集合足够小，QEMU 停止 vCPU 与数据面，发送最后脏页和设备/CPU 状态，再在目标端恢复。页面内容位于 QEMU memory backend，困难在于找出所有写入者。

KVM vCPU 写入 RAM 时，内核通过 slot dirty logging 记录。当前 [`kvm_physical_sync_dirty_bitmap()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/kvm/kvm-all.c#L1161)可以使用 `KVM_GET_DIRTY_LOG` 读取 bitmap，支持时也可消费 dirty ring。QEMU 用户态设备通过 MemoryRegion/迁移脏页接口标记自己造成的写入；vhost 后端还要开启日志，让绕过 QEMU 的 DMA 或队列更新进入同一迁移账本。

任何漏记都会产生静默损坏。源端页面在第一轮发送后若被设备改写，却未重新进入 dirty set，目标端保留旧内容；客户机恢复时错误可能出现在文件系统、网络 buffer 或页表中，距离迁移代码很远。多记页面只增加带宽和停机时间，漏记页面破坏正确性，因此实现通常偏向保守标脏，再用度量减少冗余。

dirty log 的启停也是 slot 状态更新。开始迁移前要让记录机制覆盖所有活跃写入者，读取 bitmap 时要处理“读取与继续写”之间的竞态，最终停机阶段再收集一次。dirty ring 提高高写入率场景的增量处理效率，也引入 ring 溢出、消费顺序和 fallback。接口变化不能改变“最后一轮覆盖停机点之前全部写入”这一 invariant。

2007 年 KVM Forum 的 [live migration 演讲](https://gitlab.com/qemu-project/kvm-forum/-/raw/main/_attachments/2007/KvmForum2007%24Kvm_Live_Migration_Forum_2007.pdf)由 Anthony Liguori 与 Uri Lublin 讲解，已经把 QEMU dirty byte map 与 KVM bitmap 合并，设备 save/load 使用版本化格式，并要求 KVM 状态先同步到 QEMU。Uri Lublin 同期参与早期 dirty logging 提交。这个历史现场之所以仍值得保留，是因为今天 vhost、dirty ring 与更多内核设备仍在回答同一个问题：谁写过页面，怎样汇入唯一账本。

:::: {.quick-quiz}
为什么只读取 KVM dirty bitmap 仍可能迁移出错误 RAM？

::: {.quick-answer}
KVM bitmap主要覆盖 vCPU/KVM 路径的写入。QEMU 用户态设备、vhost 或其他 DMA 后端也可能修改共享 RAM，必须通过各自脏页或日志协议合并。漏掉任一写入者，目标端可能保留旧页面。
:::
::::

## 设备与 in-flight 请求必须先停稳

设备 VMState 保存客户机可观察的寄存器、队列索引、feature、配置和中断状态。它无法替代 quiesce。一个 virtio 请求可能已经从 available ring 取出，正在 vhost worker 或 vhost-user 进程中执行，却尚未写入 used ring；此时只保存 ring index，会让目标端重复请求或永久丢失完成。

迁移协议要选择一种可证明的策略：等待所有 in-flight 请求完成；取消并保证后端没有副作用；或显式迁移 in-flight 描述。块设备写入、网络发送和可重试读操作的副作用不同，不能用同一“清空队列”口号覆盖。停止新请求、停止后端、收拢完成、同步脏页、保存设备状态的顺序需要由具体设备实现固定。

中断处在请求完成的尾部。若后端已写 used ring 但中断尚未注入，目标端必须恢复一个可触发的 pending 状态；若中断已被客户机接受，不能再次注入。APLIC、IMSIC、vCPU pending interrupt 和 virtqueue notification suppression 共同决定客户机接下来看到什么。irqfd 缩短运行路径，也让迁移必须从内核路由和 irqchip 取回相应状态。

源端与目标端的切换还要避免 split brain。2007 年演讲已经用双端握手说明：目标确认能恢复以后，源端才完成交接；失败时只有一端继续运行。现代管理层可能增加存储 lease、fencing 和网络切换，QEMU 迁移协议仍要提供清楚的成功/失败边界。迁移连接断开不能让两台宿主都认为自己拥有同一客户机。

## RISC-V timer 是独立状态机

虚拟 timer 随宿主时间推进，不能仅靠通用 CSR 镜像恢复。当前 RISC-V KVM 代码通过 timer one-reg 读取 time、compare、state 和 frequency。`kvm_riscv_get_regs_timer()` 只在用户态副本尚未标记 dirty 时拉取；`kvm_riscv_put_regs_timer()` 在恢复后写回 time、compare 与有效 state。runstate handler 在虚拟机停止与继续之间安排相应 get/put，使暂停不会被误算成客户机时间。

[`vmstate_kvmtimer`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/machine.c#L212)当前保存 time、compare 和 state，`post_load` 把 timer 标成待写回。frequency 不在这个子段中；put 路径在迁移期间读取目标宿主 frequency，与源端记录值比较，不同时报告错误。源码注释明确指出当前不支持跨不同 timer frequency 的迁移。兼容检查若发生得太晚，会在已经传输大量 RAM 后才暴露问题。

timer 还关系到 pending interrupt。compare 已经过期时，恢复后的 timer 应立即或按规范触发；state 若表示关闭，不能只根据数值重新计算。源端 stop 到目标端 resume 的墙钟时间是否计入客户机，也取决于虚拟时钟策略。三个整数能够编码格式，不代表时间语义自动正确，测试必须覆盖过期、临界 compare 和长时间停机。

这个案例说明迁移能力应在启动或迁移协商阶段预检。源/目标都显示 `KVM_RISCV_TIMER` 可用，只证明接口存在；frequency、可写状态和暂停语义仍需匹配。CPU extension 的检查也应采用同样层次。

## AIA full/split 改变迁移边界

AIA emulation 位于 QEMU 时，APLIC/IMSIC 状态可沿设备 VMState 保存；使用 in-kernel AIA 后，权威状态进入 KVM device。full 模式可能把 APLIC 与 IMSIC 都交给内核，split 模式由 QEMU 保留 APLIC、KVM 负责 IMSIC。两种模式在运行时都能减少部分退出，迁移却需要不同的状态采集组合。

审计固定基线的 [`kvm_riscv_aia_create()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c#L1832)，可以看到创建、模式、source/MSI 数量、地址、hart bits 与初始化控制；同一文件没有与之配套的完整 AIA save/restore 路径。由此只能得出保守结论：不能从“VM 能以 in-kernel AIA 启动”推导它能 live migrate，部署应使用明确支持的模式并做源/目标实测。

split 让问题更可见。QEMU APLIC 的 VMState 与 KVM IMSIC 的设备状态必须来自同一个停机点，中间还可能有已路由、未投递或已 pending 的 MSI。只迁移 APLIC 会丢失 per-hart interrupt file，只迁移 IMSIC 又会丢失 source 配置。若目标端只能使用另一种模式，还需要定义状态转换；没有转换协议时应拒绝迁移。

一组 AIA save/restore v3 补丁在 `v11.1.0-rc0` 冻结前已经发到邮件列表，但没有进入该标签。它说明社区正在处理这段状态协议，不能把未合入功能写成当前能力。本书把标签源码视为事实基线，把邮件中的候选方案标为演进线索。

:::: {.quick-quiz}
源端和目标端都支持 RISC-V AIA，是否足以允许迁移？

::: {.quick-answer}
不足。还要匹配 emul/full/split 模式、APLIC/IMSIC 状态接口、路由与 pending interrupt，并证明固定 QEMU/内核组合能保存恢复。能创建 irqchip 只覆盖初始化，不代表有完整迁移协议。
:::
::::

## machine、CPU model 与目标预检

迁移 stream 不能让目标端猜客户机平台。QEMU machine version 固定设备布局、默认属性和 VMState 兼容行为；CPU model 固定客户机可见 ISA extension 与寄存器集合；命令行选择的 AIA、virtio feature、memory backend 和 accelerator 属性也会改变状态格式或恢复能力。管理层需要在源端启动时记录这些约束，并在目标端接收大量数据以前验证。

RISC-V KVM 常使用宿主能力构造 CPU 属性。“host 支持”适合本地性能，不天然形成稳定迁移基线：两台 hart 可能有不同 Vector 长度、SATP mode、vendor extension、SBI 能力和 timer frequency。可迁移部署应定义共同 CPU 基线，关闭目标端缺失的可选扩展，并确认 one-reg 在两端都可 get/put。隐藏扩展还要检查客户机是否已经使用相关状态。

兼容性有三个层次。语法兼容说明目标 QEMU 认识 stream section；结构兼容说明字段大小和版本可解码；语义兼容说明恢复后的硬件/内核会以相同行为执行。一个 H CSR 能写入，不代表目标实现同样的 nested trap、AIA 与 timer 语义。测试要覆盖客户机实际使用路径，而非只做空闲 VM 往返。

目标预检失败应给出可定位信息：缺少哪个 KVM capability、哪个 one-reg 不存在、哪项 CPU property 不匹配、timer frequency 是否不同、irqchip 模式能否恢复。笼统的“destination incompatible”会迫使运维在停机窗口里重新做源码调查。

## H 可见、L2 可运行、nested 可迁移是三件事

当前 `target/riscv/kvm/kvm-cpu.c` 把 `RVH` 映射到 `KVM_RISCV_ISA_EXT_H`，因此 QEMU 能询问或配置 H extension。这个映射只说明 L1 CPU model 的一个能力入口。真正让 L1 运行 L2，需要内核 virtualize H/VS CSR、二阶段控制、trap delegation、timer 与 nested interrupt；迁移还要把这些权威状态从 KVM 拉回并版本化。

公共 RISC-V CPU VMState 中的 [`vmstate_hyper`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/machine.c#L87)已经列出 `hstatus`、`hedeleg`、`hideleg`、`hgatp`、`htimedelta`、VS CSR 等 H 状态。TCG 路径可以直接提供这些 `env` 字段；当前 KVM `kvm_arch_get_registers()` 只走 core、现有 CSR、FP 与 Vector 组，固定基线中看不到一条完整的 H/VS nested 状态 get/put 链。公共 VMState 字段存在，不能证明 KVM 运行时能取得对应权威值。

2026 年初 Linux RISC-V nested KVM [v1 series](https://patchew.org/linux/20260120080013.2153519-1-anup.patel%40oss.qualcomm.com/)仍明确处于演进阶段。它能说明 Maintainer 与 Contributor 正在定义接口，不能改变本书固定标签的审计结果。部署判断应分成四格：L0 用宿主 H 加速 L1；L1 是否看到 H；L1 是否能进入并稳定运行 L2；活跃 L2 是否能迁移。前一格通过不推出后一格。

nested 还会放大所有权层数。L1 认为自己拥有给 L2 的 `hgatp` 与虚拟中断，L0 KVM 必须保存并验证这些值，真实硬件又持有当前执行上下文。迁移要同时恢复 L1 可观察的控制状态与 L2 正在执行的状态，任何只覆盖“外层 vCPU 寄存器”的方案都会留下断点。

## 实验：用失败边界验证迁移承诺

::: {.hands-on}
先运行 [`inspect-one-reg-state`](../experiments/part-03-riscv-hardware-virtualization/chapter-15-kvm-state-and-migration/inspect-one-reg-state/README.md)。在 vCPU 运行、停止、同步和重新运行四个阶段，记录 core/CSR/FP/Vector/timer 的权威位置与 get/put 调用。特别验证 runtime put 为何跳过 FP/Vector，以及 reset/full restore 是否重新写入。若无法动态 trace，使用固定源码建立调用表，并把推测单列。

随后运行 [`test-migration-boundary`](../experiments/part-03-riscv-hardware-virtualization/chapter-15-kvm-state-and-migration/test-migration-boundary/README.md)。先用最小 CPU、用户态可迁移设备和一致 timer/irqchip 配置做基线，再逐项启用 Vector、vhost、AIA 模式或 H。每次只改变一个维度，记录迁移协商、pre-copy dirty rate、停机时间、目标恢复和客户机内自检。失败是有价值结果，前提是能指出停在哪个所有权协议。

客户机自检应覆盖寄存器、内存和设备顺序：多个 hart 持续更新带校验的共享数据；timer 在 compare 边界产生中断；virtio 保持有 in-flight I/O；迁移后检查无重复/丢失完成。若测试 H/nested，还要分别记录 L1 是否看到 H、L2 是否真正运行以及迁移是否在启动前被拒绝。

实验报告最后附一张源/目标矩阵：QEMU tag、内核版本、物理 ISA、KVM capability、CPU model、timer frequency、AIA 模式、后端与 migration capability。没有这张矩阵，“在我的机器上成功”无法转化为可复现结论。

对每次失败再标注发生阶段：协商前、pre-copy、stop-and-copy、目标 post-load 或恢复运行后。阶段能够反推缺失协议，避免把 capability 不匹配、dirty logging 漏洞和设备恢复错误混成同一种“迁移失败”。

恢复后还应延长观察窗口。某些漏失的 timer 中断、晚到的设备完成或旧后端写入，要等客户机再次使用相关队列才显现；只看到目标端首个 shell 提示符，还不足以确认状态连续。

持续负载下的长期校验更有说服力。
:::

## 可迁移才算完整地移动了边界

KVM 带来的性能来自把普通指令、内存转换、中断或数据面移向硬件与内核。每次移动都会产生新的权威状态。QEMU 的任务是建立同步点、版本化格式、目标预检和失败协议，让这些状态在暂停、迁移和恢复之间保持同一个客户机时序。

RISC-V 当前实现已经提供 vCPU one-reg、memory slot、dirty log、timer 和 AIA 接线，也清楚暴露了边界：不同 timer frequency、in-kernel AIA save/restore、完整 H/VS nested 状态仍需逐项证明。承认这些边界不会削弱 KVM 的价值，反而让维护者知道下一份 patch 应该补哪一段协议、review 应该追问什么、实验应该怎样构造。

第三篇由此回到开头的问题。TCG 给出跨 ISA 和可控制的执行，KVM 把同 ISA 热路径交给硬件；QEMU 用 accelerator 抽象、AddressSpace、设备与迁移框架把两者接到同一平台。理解这套系统的可靠方法，是沿状态和责任追踪每一次跨层交接，再用邮件、commit、固定源码和实验互相校验。面对下一套数百万行系统软件，也可以从同样的问题开始：压力从哪里出现，边界为何移动，谁为移动后的状态负责。
