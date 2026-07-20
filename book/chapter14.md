# CPU 快了以后：exit 经济学与 I/O 分层

把 RISC-V 客户机从 TCG 切到 KVM 后，一段纯计算可能明显加速，串口输出或网络吞吐却未必按相同比例增长。原因可以在 trace 里直接看到：普通指令长期留在 VS/VU，访问用户态 UART 寄存器时却要退出硬件、进入 KVM、返回 QEMU、取得设备锁、执行寄存器语义，再沿原路进入客户机。若驱动逐字节轮询，这条路径会反复出现。CPU 执行器已经换成硬件，设备交互仍可能由退出频率支配。

优化虚拟 I/O 的第一步是给退出建立账本，再判断哪些高频路径值得靠近内核：什么事件让 vCPU 离开，在哪一层被消费，每次传递多少数据，完成后怎样通知客户机，状态由谁保存。virtio、ioeventfd、irqfd、in-kernel irqchip 与 vhost 都在移动这条边界。边界每移动一次，性能、隔离、调试和迁移也会一起变化。

本章以 QEMU `v11.1.0-rc0` 的 RISC-V `virt` machine 为现场。RISC-V 没有依赖 x86 port I/O 的传统包袱，常见 transport 是 MMIO 或 PCI；这让“设备地址为何产生 exit”更清楚，也适合观察 AIA 的 full/split irqchip 如何把中断责任分给 QEMU 与 KVM。

## 一次 exit 的成本由什么组成

硬件 trap 只是开端。vCPU 从客户机模式回到宿主特权态，KVM 保存必要状态并判断原因；若内核不能完成，便在 `struct kvm_run` 填入数据，让 ioctl 返回。宿主调度器重新运行 QEMU vCPU 线程，QEMU 取得需要的锁，AddressSpace 查找 `MemoryRegion`，设备模型执行回调。随后 QEMU 写回读数据或完成标志，再次进入 `KVM_RUN`，内核才可能提交上一次 I/O 并恢复客户机。

这条链上至少有五类成本：特权级切换与状态保存、内核/用户态边界、线程唤醒和调度、QEMU 分派与锁、设备后端自身的系统调用或复制。单次成本很低时，次数仍会放大总量；单次传输的数据很小时，每字节成本尤其突出。优化前要同时记录 exit rate、每次批量大小和 vCPU 在各层停留的时间。

当前 [`kvm_cpu_exec()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/kvm/kvm-all.c#L3427)在进入 ioctl 前释放 BQL，退出后按 `exit_reason` 分派。RISC-V 用户态 MMIO 由通用分支处理，SBI 等架构 exit 进入 [`kvm_arch_handle_exit()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c#L1730)。看到函数调用次数时要再区分：某次重新进入可能只为完成上一次 MMIO 指令，随后才开始新的客户机执行。

退出也有必要价值。它让 QEMU 保持完整设备语义、错误注入和可观察性，使一个设备模型能同时服务 TCG、KVM 和测试工具。低频控制面访问通常不值得增加另一份内核实现。真正需要缩短的是高频、语义稳定、容易批处理的数据面。

:::: {.quick-quiz}
为什么只比较 `KVM_RUN` ioctl 的平均耗时，无法判断 I/O 优化是否有效？

::: {.quick-answer}
一次 ioctl 可能在客户机执行很久，也可能立即因 MMIO、信号或调度返回；返回后还有线程唤醒、锁、设备后端和重新进入成本。应按 exit reason 统计次数、批量大小和各层停留时间，再结合吞吐与尾延迟。
:::
::::

## virtio 把设备接口改成批量协议

全模拟设备让客户机看到真实硬件寄存器和描述符格式，现有驱动可直接使用，代价是许多访问原本为物理总线设计。虚拟环境两端可以合作，便可把接口重构为共享内存队列：客户机在 RAM 中准备描述符和数据，只用一次 notify 告诉后端有新工作；后端批量消费，再用中断或轮询报告完成。virtio 的性能来源首先是协议变化，随后才是后端放置位置。

2007 年 KVM Forum 上，Dor Laor 的 [paravirtualized devices 演讲](https://gitlab.com/qemu-project/kvm-forum/-/raw/main/_attachments/2007/KvmForum2007%24kvm_pv_drv.pdf)展示了当时的抉择。全模拟 RTL8139 只有约 55 Mbps，并产生大量 I/O exit；改用较现代的 e1000 仍需每个包约两三次 exit。团队希望接口接近原生、能进入 Linux、复用已有基础设施、后端留在用户态，并能脱离 KVM 工作。virtio 的跨 hypervisor 复用正是这组约束的结果。

当前 RISC-V `virt` 可创建 virtio-mmio transport。客户机把 descriptor table、available ring、used ring 和数据缓冲放在已注册 RAM 中，普通数据访问经过 G-stage；对 notify 寄存器的写才触发设备边界。QEMU 的 [`hw/virtio/virtio-mmio.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/virtio/virtio-mmio.c)解释 transport 寄存器，[`hw/virtio/virtio.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/virtio/virtio.c)维护通用队列与 feature negotiation，具体块、网卡或控制台设备实现请求语义。

队列没有取消正确性约束。客户机写描述符、发布 available index、notify 后端之间需要内存屏障；后端写 used ring、更新 index、发中断也要遵守顺序。feature negotiation 决定双方理解哪些格式，设备 reset 要处理尚未完成的请求，迁移要保存队列地址、索引、feature 与 in-flight 状态。共享内存减少 exit，同时把并发协议变成设备 ABI。

轮询与批处理还带来延迟权衡。后端等待更多请求可以提高吞吐，却让稀疏 I/O 多等一段时间；客户机使用 event suppression 可减少中断，也要避免错过唤醒。virtio 提供机制，最优参数取决于块设备、网络、CPU 拓扑和服务目标，不能从“更少 exit”单独推出。

## 沿一次 virtio-mmio 请求追踪所有权

以 virtio-blk 读请求为例。客户机驱动先在已注册 RAM 中写请求头、数据 buffer 和 status byte，把这些片段组织为 descriptor chain，再把 head index 放入 available ring。发布 index 前的内存屏障保证后端看到队列更新时，也能看到先前写入的描述符。此刻数据存在共享 RAM，QEMU/KVM 还未收到“开始处理”的控制事件。

客户机向 `QueueNotify` 写 queue index。没有 ioeventfd 时，该地址属于 virtio-mmio `MemoryRegion`，G-stage fault 形成 MMIO exit，QEMU transport 验证寄存器访问并唤醒设备后端；注册 ioeventfd 后，KVM 可直接给后端 eventfd 计数。两条路径消费同一个 vring 协议，区别落在通知是否经过 vCPU 用户态分派。

用户态后端由 QEMU 解析 chain、检查长度与访问方向，再向 block layer 提交请求；vhost 后端则从内核或独立进程直接取得 vring 配置。完成时后端写数据 buffer 和 status，把 head 放入 used ring，最后更新 used index。若迁移 dirty logging 已开启，这些后端写入必须标脏；若 reset 正在发生，后端还要证明旧请求不会在新队列上晚到。

完成通知可以经 QEMU 设备线路，也可以由 irqfd 进入 KVM irqchip。客户机收到中断后读取 used ring，回收 descriptor。中断只表示“可能有完成”，完成数量由 ring 决定，因此合并不会丢失请求；若顺序或屏障错误，客户机可能看到中断却读不到新 used entry，或先看到 index 再看到旧数据。

这个请求经过四种所有权：客户机发布前拥有 descriptor；后端取走后拥有 in-flight 操作；used ring 提交后客户机重新拥有 buffer；QEMU 始终拥有 transport 配置和生命周期协调。性能工具只显示 exit 数量，无法直接告诉我们请求处于哪一阶段。调试卡死要同时读 avail/used index、后端 in-flight、eventfd 计数和 pending interrupt。

还可以用同一追踪法分析 virtio-net。发送包允许批量 descriptor，接收包需要后端预先取得客户机提供的 buffer；mergeable buffer、checksum 与 segmentation feature 会改变每包 descriptor 数。比较两个后端时，必须固定 feature negotiation，否则吞吐差异可能来自 offload，而非少了一次 exit。

## ioeventfd 与 irqfd 缩短通知路径

virtqueue 数据位于 RAM，notify 仍可能是一次 MMIO 写。如果每次 kick 都先退出到 QEMU，再由 QEMU 唤醒后端，数据协议已经批量化，通知路径仍穿过用户态。ioeventfd 允许 QEMU 把某个 MMIO 地址和匹配值注册给 KVM；客户机写入时，内核向 eventfd 发信号，支持它的后端可以直接被唤醒，vCPU 无需为这次写执行完整用户态设备分派。

反方向的完成通知也可缩短。irqfd 把 eventfd 与客户机中断路由连接，后端发信号后，KVM 向 vCPU 注入中断。这样数据面形成“客户机共享队列—后端—irqfd—客户机”的短路，QEMU 保留配置、路由建立、reset、错误处理和迁移协调。宿主内核或 machine 不支持相应 capability 时，QEMU 必须回退到用户态路径。

eventfd 只携带计数唤醒，不包含完整设备语义。队列中哪项请求可见、是否需要 memory barrier、设备是否正在 reset、通知应路由到哪个 hart，仍由 virtio 与 QEMU/KVM 配置协议决定。把 MMIO 地址注册成 ioeventfd 以前，还要确认写操作无需返回值，并且旁路 QEMU 不会漏掉必须观察的副作用。

中断合并与 notification suppression 会改变 trace 形态。一次 irqfd 信号可能对应多个完成项，一次客户机 kick 也可能提交多个 descriptor。评价效果时应使用“每批请求的通知数”“每完成项的中断数”，避免把原始 exit 数量与请求数量一一对应。

:::: {.quick-quiz}
ioeventfd 让 notify 写绕过 QEMU 后，QEMU 是否已经退出设备生命周期？

::: {.quick-answer}
没有。QEMU 仍创建 transport、协商 feature、配置 eventfd 与中断路由，并处理 reset、热拔、错误和迁移。旁路的是高频通知数据面；共享队列语义和控制面仍需唯一协调者。
:::
::::

## vhost 把数据面放到更近的位置

QEMU 用户态 virtio 后端仍要解析 descriptor、访问 guest RAM，并调用宿主网络或存储接口。vhost 把成熟的 virtqueue 数据面交给内核 worker；QEMU 通过 vhost ioctl 配置内存表、队列地址、eventfd 与 feature，然后让 worker 直接消费客户机队列。网络包可以减少在 vCPU 线程、QEMU 设备线程和内核协议栈之间的往返。

[`hw/virtio/vhost.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/virtio/vhost.c)展示了 QEMU 仍承担的工作：建立后端、同步 memory listener、配置 vring、启动和停止设备、处理日志与迁移。vhost-user 又把数据面放到独立用户进程，通过 Unix socket 交换协议和文件描述符。它带来独立发布、调度与运维故障域，也增加了一个需要握手、恢复和版本协商的状态所有者；由于双方共享客户机内存，这个进程边界本身不是 QEMU 安全模型认可的隔离边界。

路径缩短并不等于状态减少。后端可能持有尚未写入 used ring 的请求、缓存映射和通知抑制状态；迁移或 reset 时，QEMU 必须先阻止新请求，再收拢 in-flight 工作，取得脏页信息，保存设备可见状态，最后解除内存与 eventfd 绑定。若数据面在另一个进程，失败检测和断线重连也进入设备语义。

攻击面和故障位置随之移动。用户态 QEMU 设备模型的 bug 影响 QEMU 进程；内核 vhost bug 位于更高权限；vhost-user 可以使用单独账户和资源限制改善运维控制，却仍要把能访问共享内存的 backend 视为同一信任域，并保护协议端点。选择后端时要同时评估吞吐、攻击面、运维隔离和迁移能力。没有一种放置方式对所有 workload 都占优。

## RISC-V AIA：中断控制器也可以分层

设备完成请求以后，最后一段路径是把中断送到目标 hart。若中断控制器完全在 QEMU，设备拉高线路、APLIC/PLIC 更新状态、vCPU 注入都可能需要用户态参与；若 irqchip 位于 KVM，常见路由和注入可以在内核完成。RISC-V AIA 还把有线中断域 APLIC 与每 hart 的消息信号中断文件 IMSIC 组合起来，为 full/split 提供了自然边界。

Yong-Xuan Wang 提交的 QEMU KVM AIA series 在 2023 年合入，提供 `emul`、`hwaccel` 与 `auto` 模式，经过 Jim Shu、Daniel Henrique Barboza、Andrew Jones review，并由 Alistair Francis 签入。当前 [`kvm_riscv_aia_create()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c#L1832)通过 KVM device API 创建 AIA，配置 mode、source 数量、MSI 数量、地址、hart 与 guest bits。用户选择只是偏好；内核若不接受，代码会报告并使用宿主默认模式。

随后 Daniel Henrique Barboza 推动 split irqchip，review 和维护路径仍由 RISC-V 社区协作完成。当前 split 模式让 QEMU 模拟 APLIC，KVM 负责 IMSIC；`kvm_riscv_aia_create()` 在 split 下跳过内核 APLIC source 与地址配置，[`hw/riscv/virt.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/virt.c)则创建相应 QEMU APLIC 并生成一致 FDT。full 模式可把 APLIC/IMSIC 更多状态交给内核。

split 的价值不只是折中性能。某些宿主可能具备 IMSIC 加速，却没有适合当前 machine 的完整 APLIC 实现；QEMU 设备模型也更容易观察和迁移 APLIC 控制面。代价是中断链跨越两个所有者，路由、reset、错误注入和迁移必须建立一致停顿点。full、split、emulated 应被视为三种状态协议，不能只用基准分数排序。

## 建立可比较的退出预算

一个可复现基准先固定客户机 vCPU 数、内存、virtio feature、队列数、块大小或包大小、宿主 CPU 绑定和后端，再逐项改变 transport 优化。输出至少包含业务吞吐、平均与尾延迟、每秒 MMIO/架构 exit、每秒 kick、中断数、每批 descriptor 数，以及 vCPU/IOThread/vhost worker 的 CPU 时间。缺少队列粒度时，“exit 下降一半”无法说明每项请求的成本。

分析可分三段。提交段从客户机发布 avail 到后端开始消费，受 kick、ioeventfd、线程唤醒影响；执行段由 block/network backend 与宿主存储网络决定；完成段从 used ring 更新到客户机回收，受 irqfd、AIA、interrupt moderation 和 vCPU 调度影响。总延迟上升时，先定位哪一段变化，再看相应层的 trace。

CPU 利用率也要按角色展开。vCPU 用户态时间可能因 MMIO 减少而下降，vhost 内核线程时间却上升；吞吐提高时总 CPU 甚至可能增加。若目标是单核效率，应报告每单位吞吐的宿主 CPU；若目标是尾延迟，还要记录 vCPU 被抢占、IOThread 阻塞和后端队列深度。一个聚合的 QEMU 进程百分比会掩盖数据面迁移。

退出预算还能指导是否写新内核接口。低频配置寄存器每秒只访问几次，搬进内核节省有限，却复制设备语义和迁移状态；高频 notify 若格式稳定、无返回值，ioeventfd 很合适；复杂设备命令可通过共享队列批量化，仍由用户态后端解释。先用测量判断频率与语义，再选择放置位置，可以减少为了理论热路径增加长期 ABI 的冲动。

回归测试要同时保留慢路径。关闭 ioeventfd、irqfd 或 vhost 后，QEMU 用户态路径应产生相同客户机结果；宿主 capability 不足时也应正确回退。快慢路径的差分测试能发现旁路漏掉的 reset、错误注入和 endian 处理。性能选项只有在 fallback 与迁移边界清楚时，才适合成为 machine 默认值。

:::: {.quick-quiz}
为何 RISC-V AIA split 模式要在 QEMU 保留 APLIC、在 KVM 放置 IMSIC？

::: {.quick-answer}
APLIC 承担设备侧有线中断聚合与路由，控制面复杂且适合 QEMU 建模；IMSIC 位于每个 hart 的消息注入热路径，交给 KVM 可减少用户态往返。该划分也允许宿主只加速部分 AIA，但增加了跨层状态同步责任。
:::
::::

## qemu-kvm 的合流说明了什么

KVM 最初通过修改版 QEMU获得设备模型。2008 年 Anthony Liguori 提交 [`Add KVM support to QEMU`](https://gitlab.com/qemu-project/qemu/-/commit/7ba1e61953f4592606e60b2e7507ff6a6faf861a)，给上游 QEMU 加入可选 KVM 路径，并用同一启动 workload 对比 TCG 与 KVM。review 中 Avi Kivity 很快追问 live migration 的 dirty bitmap、信号与寄存器状态；Anthony 则讨论 I/O thread 和避免全局状态。这个现场说明 accelerator 接入从来不只是一处 `KVM_RUN`，还会碰到线程模型、内存监听和迁移。

随后相当长一段时间，KVM 用户常使用独立 `qemu-kvm` 仓库，功能在 fork 中先行，再不断向 QEMU 上游搬运。短期分支让开发者快速迭代，长期却要同步 machine、设备、block、migration 和公共基础设施。Paolo Bonzini 在 FOSDEM 2012 的 [合流报告](https://archive.fosdem.org/2012/schedule/event/444/82_fosdem12.pdf)总结了规则：优先在上游工作、尽早上游、频繁合并，并展示剩余差异已缩到不足七千行量级。

今天 `accel/kvm/` 作为 QEMU 上游 accelerator 与 TCG 等后端共享 `CPUState`、AddressSpace、设备和迁移框架，是这段合流的工程结果。维护一个 out-of-tree accelerator fork 会重复修复公共安全问题、适配 QOM 与线程变化，还容易让迁移格式和设备行为分叉。上游化没有让 review 变慢这一项成本消失，却把跨组件兼容问题放到共同代码和共同测试中解决。

这段历史也能用来审视 RISC-V 的当前协作。AIA、timer、ISA extension 或 nested 支持若只在某个 vendor 分支实现，短期演示可能成功，后续每次 QEMU machine 演进都要重新同步。把功能拆成通用 KVM 层、RISC-V 架构层和 `virt` machine 接线，并在邮件 review 中明确迁移与回退，是降低长期分叉成本的办法。

## 实验：让退出路径变成数据

::: {.hands-on}
先运行 [`inspect-kvm-memory-slots`](../experiments/part-03-riscv-hardware-virtualization/chapter-14-kvm-memory-io-and-interrupts/inspect-kvm-memory-slots/README.md)。把 RAM slot 与 `virt` 的 UART、virtio-mmio、PCIe 和中断控制器地址区间放在一张图上。预测哪些访问能经过 G-stage 留在硬件，哪些会形成 MMIO exit，再用 trace 验证。地址图与实际原因不一致时，优先检查 MemoryRegion flatten、slot 注册和 transport 配置。

接着运行 [`trace-irq-and-io-exits`](../experiments/part-03-riscv-hardware-virtualization/chapter-14-kvm-memory-io-and-interrupts/trace-irq-and-io-exits/README.md)。选择两类 workload：逐字节串口输出，以及通过 virtio 块或网络批量传输。记录相同时间窗内的 MMIO exit、kick、完成中断、吞吐和 vCPU 用户/内核时间。若环境支持，再分别切换用户态后端、ioeventfd/irqfd、vhost 或 AIA 模式，保持客户机镜像和负载不变。

报告不要只写“方案 B 更快”。至少解释减少的是哪种 exit，批量大小是否变化，中断是否合并，数据面状态现在由哪个组件持有，以及迁移时需要怎样停住它。无法读取某项 trace 时保留空缺和环境信息，避免用吞吐结果反推未经观测的路径。

实验还应保存一组客户机侧计数。驱动报告的提交数、完成数、队列长度和中断数，能与宿主 exit/eventfd/irqfd 计数交叉校验。若宿主显示一百次 kick，客户机提交了一万个请求，平均批量约为一百；若中断数下降但尾延迟升高，可能是合并窗口过大。计数对不上时，先检查多队列、轮询和 event suppression，别急着把差额归为丢事件。

再做一次 reset 或设备重连压力测试。高吞吐 steady state 很少触碰队列所有权交还，reset 会迫使后端停止、撤销 eventfd、清理 in-flight 并重新协商 feature。快路径若遗漏生命周期处理，往往在这里暴露。把性能结果和 reset/迁移结果并排记录，才能判断优化是否达到可部署状态。

多队列场景还要按 queue 和 vCPU 分组。一个热点队列可能掩盖其他队列空闲，平均值看不出 irq affinity、NUMA 距离和锁竞争。固定队列到 hart 的映射，再改变一次亲和性，可以分辨退出机制成本与宿主调度成本。若优化只在特定绑定下成立，部署文档应把绑定写成前提，测试也要覆盖失配时的回退表现。
:::

## 优化的终点由状态协议决定

退出优化有一条清楚的次序：先确认事件频率与数据粒度，再选择共享队列和批处理，随后缩短通知与中断路径，最后评估是否值得移动数据面。每一步都要保留 fallback，因为宿主 capability、设备类型和运维目标不同。

当路径从 QEMU 移到 KVM、vhost 内核 worker 或 vhost-user 进程，性能热点会下降，状态所有者会增加。reset、热拔、调试和迁移必须让所有参与者在同一个边界停下，交出寄存器、队列、in-flight 请求、脏页和中断状态。若协议无法完成这一步，基准更快也不能成为可维护的虚拟机功能。

下一章将沿这条所有权链处理最严格的场景：把运行中的 RISC-V VM 迁移到另一台宿主。`vcpu_dirty`、one-reg、dirty log、timer、AIA 与 nested H 状态会共同回答一个问题——停机瞬间，哪一份状态才是客户机接下来能够观察到的真值。
