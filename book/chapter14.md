# KVM 内存、I/O 与中断虚拟化

vCPU 进入硬件之后，绝大多数取指和普通内存访问都不应返回 QEMU。客户机页表给出 GPA，H 扩展的 G-stage再把 GPA转换到宿主物理页；Linux KVM维护这部分映射，QEMU则告诉 KVM哪些 GPA对应进程里的客户机 RAM。访问落在 UART、virtio寄存器或其他 MMIO区域时，控制权才可能回到用户态设备模型。中断路径也采用同样思路：语义复杂、变化频率低的配置留给 QEMU，高频通知可以借助 irqfd、ioeventfd或 in-kernel irqchip缩短往返。

本章继续以 RISC-V `virt` machine为主，目标版本为 QEMU `v11.1.0`，源码事实锚定 [`v11.1.0-rc0`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0) 的 `eca2c162`。当前实现从 [`accel/kvm/kvm-all.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/kvm/kvm-all.c)、[`hw/riscv/virt.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/virt.c)、[`target/riscv/kvm/kvm-cpu.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c)、[`hw/intc/riscv_aplic.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/intc/riscv_aplic.c) 与 [`hw/intc/riscv_imsic.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/intc/riscv_imsic.c) 交叉核对。历史说明使用 QEMU GitLab提交与 qemu-devel/Patchew，不把候选补丁当作已发布能力。

## 本章目标

- 跟踪 `MemoryRegion`、`FlatView`、KVM memory listener与 memory slot之间的转换；
- 解释一次 RISC-V MMIO读写为何退出、怎样完成原指令并重新进入 KVM；
- 分清 ioeventfd、irqfd、PLIC、APLIC和 IMSIC各自加速了哪段路径；
- 比较 `riscv-aia=emul`、`hwaccel`、`auto`以及 `kernel-irqchip=split` 的状态所有权；
- 从 AIA初始支持、split irqchip和未合入的保存恢复系列判断迁移边界。

## 先画出两条数据路径

一条普通 RAM读路径通常是：VS态指令给出 GVA，硬件完成 VS-stage得到 GPA，再完成 G-stage得到宿主物理页，最终由宿主内存响应。QEMU在这条热路径上不逐次执行回调，它只在拓扑建立和变化时把 GPA、大小、宿主用户地址与属性注册给 KVM。页表权限、缺页和脏页跟踪由硬件与内核协作。

一条用户态 MMIO读路径则是：G-stage找不到可直接访问的 RAM slot，或内核把该地址识别为需要用户态模拟，`KVM_RUN` 返回 `KVM_EXIT_MMIO`；QEMU按 GPA进入 `AddressSpace`分派，设备回调生成结果；QEMU把结果写入 `kvm_run`，再次调用 `KVM_RUN`完成原指令。两条路径访问的是同一客户机物理地址空间，却由 `MemoryRegion`属性和 KVM注册决定是否进入硬件。

中断方向相反。设备事件先在 QEMU、vhost后端或宿主设备出现，再沿 QEMU irq线、irqfd或 KVM irqchip到达 vCPU。RISC-V `virt` 的传统路径使用 PLIC把外部中断送往 hart的 S external interrupt；AIA路径则由 APLIC接收有线源，并可向每 hart的 IMSIC发送 MSI。选择 in-kernel AIA后，pending、路由和投递状态有一部分离开 QEMU对象，迁移接口必须补上这份可见性。

这两条路径共同说明“加速”移动的是边界。一次往返被省掉以后，用户态少了可观察点，也少了一份自然存在的可迁移状态。判断方案时，应同时衡量吞吐、尾延迟、状态恢复、错误诊断和目标宿主兼容性。

:::: {.quick-quiz}
为什么客户机能够直接访问 RAM，却不能直接访问 QEMU进程里的任意地址？

::: {.quick-answer}
QEMU只把经过选择的客户机 RAM区间注册成 KVM slot，slot明确 GPA、长度、宿主用户地址和属性。MMIO、空洞、QEMU堆对象及其他进程内存都不在映射中，G-stage也受 KVM建立的页级权限约束。
:::
::::

## `MemoryRegion` 先描述语义

QEMU machine创建的是一棵 `MemoryRegion`拓扑。RAM节点有可直接映射的后端，ROM与 ROMD带写入限制，MMIO节点带 read/write回调，alias把一段地址映射到另一节点，container负责组合子区域。设备模型用这些语义描述客户机可见地图，KVM不能取代这棵树，因为非 KVM加速器、调试访问、DMA与迁移也要使用它。

`AddressSpace`把根 `MemoryRegion`变成某个访问者看到的物理空间。拓扑提交后，QEMU生成扁平化的 `FlatView`，将重叠优先级、alias偏移和 enabled状态解析成互不重叠的 `FlatRange`。KVM memory listener订阅 AddressSpace变化，收到的是已经带地址与偏移的 `MemoryRegionSection`，无需重新解释整棵树。

listener只为适合直接映射的 section建立 slot。普通设备 MMIO仍留在 AddressSpace分派；某些 ROM或只读 RAM根据内核 capability使用只读 slot；无法满足对齐、脏页或后端要求的区间可能分段或不注册。由此得到一条源码事实：QEMU内存图是权威语义，KVM slot是其中可硬件执行部分的投影。slot列表不能反向完整还原设备拓扑。

拓扑更新以 transaction提交。machine初始化会连续添加大量区域，热插内存、PCI BAR重映射和 ROMD模式切换也会改变 FlatView。listener在 region add/del中更新 KVM，而 transaction边界允许批量协调。若每次子节点变化都立即让 vCPU看到半张新地图，客户机可能在 BAR旧地址已删除、新地址尚未建立的窗口访问错误目标。

内存别名说明 GPA与宿主地址并非一一对应。两个客户机范围可以指向同一 RAMBlock的不同或相同偏移，设备也能通过 alias重排窗口。KVM slot记录扁平后的 GPA和 `userspace_addr`，因此 alias变化可能表现为删除旧 slot、创建新 slot。审查 slot日志时必须同时保存 GPA和宿主地址，单看 slot编号无法判断映射关系。

## memory slot 保存什么

通用 KVM层用内部 `KVMSlot`跟踪客户机物理起点、大小、宿主地址、slot编号、flags和脏页相关状态。最终通过 VM fd调用 `KVM_SET_USER_MEMORY_REGION`；内核支持更现代接口时也可能使用 `KVM_SET_USER_MEMORY_REGION2`。slot编号是宿主接口资源，不是客户机 ABI，删除后可以复用；迁移流不应序列化编号。

一个有效 slot至少要满足页粒度与地址范围要求。`kvm_set_phys_mem()`会结合 section在 AddressSpace中的偏移、RAMBlock host pointer和页边界计算可注册区间。首尾不能直接映射的碎片保留给用户态慢路径或按实现规则处理。对齐检查存在的工程原因很明确：G-stage最终管理页表，内核不能安全映射任意字节级宿主指针。

slot数量有限，具体上限由 KVM capability和架构实现决定。大块连续 RAM使用少量 slot，频繁碎片化、alias或热插窗口会消耗更多。QEMU需要在启动时拒绝超限布局，并在删除区域后归还 slot。将每个小页做成一个 slot会放大 ioctl、内核元数据和拓扑更新时间，也可能很快耗尽上限。

flags表达只读与脏页记录等属性。启用 `KVM_MEM_READONLY` 后，客户机写入不能像普通 RAM那样静默落到宿主页；启用 `KVM_MEM_LOG_DIRTY_PAGES` 后，内核需要记录 vCPU写过哪些页。属性变化可能要求更新同一 slot，甚至删除再创建，期间要与正在运行的 vCPU协调。

`userspace_addr`指向 QEMU映射的 RAM后端，但这不表示内核长期假设进程页永远固定。匿名内存、文件后端、hugepage、共享映射和内存后端对象各有生命周期；QEMU必须在释放或重映射 host虚拟区间前先解除 KVM slot。先释放后删除会让 vCPU继续通过旧 G-stage访问已复用的进程地址，这是严重的隔离错误。

private memory等新接口会进一步分离“QEMU可读的用户地址”和“客户机可访问的受保护页”。本章固定标签的 RISC-V主线不以机密虚拟化为已完成能力，只把 `KVM_SET_USER_MEMORY_REGION2` 视为通用接口演进背景。没有 RISC-V对应的创建、转换、DMA和迁移闭环时，不能从通用结构体存在推断 confidential guest可用。

## add、delete 与并发可见性

KVM memory listener的 region add最终进入 `kvm_set_phys_mem()`，region del也通过同一核心逻辑撤销或调整 slot。删除通常用大小为零的 region更新内核对象，再清理 QEMU侧记录。这样内核先停止使用旧映射，用户态之后才能释放 RAM后端。

更新期间 vCPU可能运行。通用内存 transaction、KVM slot锁和内核 MMU失效共同保证旧页表不会无限保留。某些改变需要让 vCPU退出或刷新映射，成本与修改范围相关。内存热插很少发生，允许付出控制面成本；普通 load/store每次都 exit则无法接受。这正是 slot采用粗粒度区间注册的原因。

重叠更新要谨慎排序。若新旧区间共享一部分 GPA，直接创建重叠 slot会被内核拒绝；先删除旧 slot又会短暂留下空洞。QEMU根据 FlatView差异拆分与更新，并借助 transaction让设备拓扑在提交点切换。阅读日志时，连续的 delete/add未必代表客户机真的看见空洞，要结合 vCPU暂停和 transaction时序判断。

内存属性变化同样会使映射失效。ROMD从“读走 RAM、写走设备回调”切换到纯 MMIO时，原只读映射要撤销；否则客户机仍可能绕过设备模型读取过期内容。PCI BAR被 guest重新编程后，MemoryRegion地址变化必须传播到 listener。KVM加速没有免除 QEMU对动态硬件语义的维护。

失败路径不能只打印 slot号。诊断应包含 GPA范围、host地址、flags、memory region名称和 errno，并说明处于 add、update还是 delete。`EINVAL`可能来自对齐、重叠、无效 flags或内核不支持；`ENOMEM`可能来自 pinning或内核元数据。足够上下文才能区分 machine布局错误与宿主资源问题。

:::: {.quick-quiz}
为什么 memory slot编号不能作为迁移 ABI的一部分？

::: {.quick-answer}
编号由源端 QEMU和宿主 KVM在建立映射时分配，可因热插、删除和宿主上限不同而变化。迁移需要保存客户机物理布局及 RAM内容，目标端可以用另一组 slot编号重建等价映射。
:::
::::

## 脏页：迁移把写入路径重新变成可观察状态

迁移预拷贝阶段允许 vCPU继续运行，同时把 RAM发送到目标端。发送一轮之后被客户机再次写过的页必须重传，因此 QEMU启用 KVM dirty logging。KVM在页表或硬件辅助路径中标记写入，QEMU周期性取回 bitmap或消费 dirty ring，再把页加入迁移队列。

传统 bitmap模式按 slot查询脏页。slot的 GPA范围和位图索引必须一致，删除或调整 slot前要处理尚未收集的脏位。大内存反复扫描整张 bitmap会产生控制面开销。dirty ring把脏 GPA事件放入共享环，减少大范围扫描，但需要处理环满 exit、消费顺序和重置。当前通用 `kvm_cpu_exec()`能处理 dirty ring full，这也是 `KVM_RUN`即便没有设备 MMIO也可能返回的原因之一。

开启 dirty log通常会影响写性能，因为页表要以可捕获写入的方式管理，首次写可能触发内核处理。迁移调优不能只看网络带宽，还要看 guest dirty rate、slot大小、ring容量和停机阶段剩余页。把一个写密集 workload切成更多 slot并不会自然降低总脏页，反而可能增加查询与元数据成本。

脏页机制记录“页被写过”，不记录设备语义或写入顺序。DMA由设备或 vhost路径发起，也必须进入统一 dirty tracking；否则 vCPU位图完整，设备写入却丢失。QEMU内存 API、vhost log与 KVM log最终要合并为迁移层看到的脏页集合。只验证 CPU memcpy无法证明 virtio网络或块设备 DMA迁移正确。

停止阶段仍需最后一次同步。QEMU先阻止新的 vCPU与设备写入，再收集尾部 dirty信息，最后发送剩余页和设备状态。若先关闭 log后停止 vCPU，中间写入会消失；若先释放 slot再取 bitmap，内核状态也无法查询。第 15章会把这个顺序与 CPU、timer和 AIA一起展开。

## 一次 MMIO exit 的完整语义

客户机访问没有直接 RAM映射的 GPA时，KVM可在 `kvm_run`中返回 `KVM_EXIT_MMIO`。联合体给出 `phys_addr`、数据缓冲区、长度以及读写方向。通用 [`kvm_cpu_exec()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/kvm/kvm-all.c#L3427) 把访问交给 QEMU AddressSpace，后者按 FlatView找到 UART、virtio-mmio、PCIe窗口或未分配区域。

写操作把 `data`按长度送入设备回调。回调可能更新寄存器、启动 DMA、改变 IRQ或触发设备 reset。读操作由回调生成值并写回共享缓冲区。设备端序、访问宽度、未对齐规则由 MemoryRegionOps描述，不能简单把字节数组强转成宿主整数。RISC-V CPU通常是小端，但设备仍可能定义特定端序和允许的宽度。

无效访问也有语义。有些设备返回全一或忽略写，有些 machine应触发总线错误；AddressSpace的 unassigned handler与架构路径共同决定结果。KVM只报告 GPA访问，不知道板级设备应如何响应。将所有缺 slot访问一律返回零，会掩盖驱动错误并改变客户机可见硬件。

设备回调结束后，QEMU可能需要再次执行 `KVM_RUN`提交原指令。若此时主线程要求暂停，run loop可设置 `immediate_exit`，但仍要遵守 I/O完成协议。观察 trace时，一次 MMIO常与紧随其后的短暂 KVM re-entry成对出现；把后者误判为“多余 entry”会引出错误优化。

MMIO exit成本包括硬件退出、内核切换、vCPU线程回到用户态、AddressSpace查找、设备锁与再次进入。减少 exit可以从不同位置入手：把稳定 irqchip下沉内核；用 ioeventfd匹配简单写；用 vhost处理 virtqueue数据面；或优化设备模型。每种方案移动的状态不同，不能用一个“内核更快”概括。

coalesced MMIO适合无需立即生效的连续写。内核把多次写记录到共享 ring，QEMU批量消费，从而摊薄 exit；读和有即时副作用的写不适用。批处理还会改变可观察时刻，设备模型必须保证延迟应用不会破坏寄存器语义。延迟敏感的 doorbell通常更适合 ioeventfd。

## ioeventfd：把可匹配的写变成事件

ioeventfd把某个 guest地址、长度以及可选 data match与宿主 eventfd绑定。客户机执行匹配写时，KVM直接给 eventfd计数，后端线程被唤醒，vCPU无需为完整用户态 MMIO回调退出。virtio队列 notify是典型场景：地址和值结构稳定，写操作主要表示“有新工作”。

注册发生在设备 realize或队列启用阶段，注销必须先于 eventfd和设备状态释放。BAR重映射、队列 reset、driver改变通知配置时，QEMU需要更新路由。旧匹配若残留，客户机写新地址不会唤醒后端，写旧地址却可能访问已经销毁的对象。

ioeventfd没有取代设备寄存器模型。特征协商、状态读取、错误位、队列地址配置和复杂控制写仍由 QEMU处理；它只截取可以预先判定语义的通知。datamatch过宽会吞掉本应进入设备模型的值，过窄则频繁回退 MMIO exit。审查时应对照设备规范列出允许匹配的寄存器和宽度。

迁移开始后，后端通知与队列状态要一起静止。eventfd计数本身不是客户机设备状态，真正要保存的是已提交 descriptor、used index和设备后端完成情况。停用 ioeventfd只能阻止新通知，不能自动排空已在后端执行的 I/O。迁移框架仍需设备级 quiesce与 in-flight协议。

## irqfd：让宿主事件进入 KVM中断路径

irqfd将 eventfd与 KVM中断路由绑定。宿主后端或设备模型写 eventfd后，KVM直接把事件送入 irqchip或 vCPU可接收路径，减少“后端唤醒 QEMU主循环、QEMU再调用注入 ioctl”的往返。level-triggered中断还可能需要 resamplefd，在客户机完成 EOI或取消电平后通知源端解除条件。

irqfd依赖已经建立的 GSI/架构路由。x86有成熟的 GSI与 irqchip组合，RISC-V PLIC/AIA的路由对象和 device control不同；通用 API能否使用、支持哪些触发方式，必须以当前内核 capability和 QEMU架构代码为准。看到 `KVM_CAP_IRQFD`只说明基础入口，不能自动推出某个 RISC-V irqchip模式全部走 irqfd。

生命周期顺序与 ioeventfd相似：先建立 irqchip和路由，再注册 irqfd；设备 reset或 unplug先停止事件源，再撤销 irqfd和路由。若事件源仍在写已经复用的 fd，可能把中断送给错误设备。迁移停止阶段还要确认 pending状态到底位于 eventfd、内核 irqchip还是 QEMU设备中。

性能上，irqfd适合高频、规则明确的通知。低频管理中断走普通 QEMU注入，额外 fd与路由维护可能没有收益。尾延迟测试要区分事件源到 eventfd、KVM投递、vCPU被调度和客户机 ISR四段，单测 guest中断计数不能定位瓶颈。

:::: {.quick-quiz}
为什么 ioeventfd适合 virtio notify，却不适合替代整个 virtio MMIO配置区？

::: {.quick-answer}
notify通常是可按地址、宽度和值匹配的单向门铃；配置区包含读取、协商、状态机、错误与副作用，需要完整设备模型。ioeventfd只表达“发生了一个事件”，没有这些寄存器语义。
:::
::::

## PLIC：完全用户态 irqchip 的基线

RISC-V `virt` 使用 PLIC时，[`hw/intc/sifive_plic.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/intc/sifive_plic.c) 保存 source priority、pending、enable、threshold与 claim/complete等状态。设备把外部源接到 PLIC输入，PLIC根据 context计算输出，再通过 CPU irq线送给目标 hart。

在 KVM加速下，QEMU模拟 PLIC最终需要让内核 vCPU看到 S external interrupt。RISC-V KVM架构代码把相应 CPU irq变化转换成 `KVM_INTERRUPT`注入。客户机访问 PLIC MMIO会退出到 QEMU，claim读取和 complete写入由用户态模型执行；每次 pending变化还可能触发注入 ioctl。路径较长，却有一个迁移优势：PLIC关键状态已经位于 QEMU对象，`vmstate_sifive_plic`能够保存。

这条路径是理解 in-kernel AIA的对照组。用户态模型便于单步、trace与故障注入，适合不支持内核 AIA的宿主，也适合验证设备语义。代价在于高频中断、claim/complete和 MMIO访问产生用户态往返。性能比较必须保持客户机驱动和中断负载相同，不能拿 PLIC与 AIA的不同软件栈直接比较。

PLIC输出是聚合电平。QEMU和 KVM必须避免在 vCPU未消费时丢失 pending，也要在 complete后正确降低或重新断言。若只统计 `KVM_INTERRUPT`调用数，会漏掉 PLIC内部合并：多个 source可以让同一 external irq持续为高。正确性检查应读取 claim顺序、priority和 enable，而不是期待“一次设备事件对应一次注入”。

## AIA：APLIC 与 IMSIC 分工

RISC-V AIA把传统外部中断路径拆成 APLIC和 IMSIC。APLIC接收有线中断源，维护 source配置、domain与 target信息；在 MSI模式下，它向目标 hart的 IMSIC发送 MSI。IMSIC为每个 hart/特权级提供中断文件，维护 pending、enable和 delivery相关状态，客户机通过 CSR与内存映射窗口访问。

QEMU `virt` 的 `aia=aplic-imsic` machine配置创建相应拓扑。[`hw/riscv/aia.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/aia.c) 协调地址与 hart布局，APLIC和 IMSIC文件分别实现设备语义。`aia-guests`影响为 guest interrupt files预留的数量与地址布局，因此它是 machine可见配置，也会影响内核 AIA device属性。

AIA与 H扩展相遇时要继续分层。L0可以用宿主 AIA加速 L1的外部中断，L1可以看见 AIA设备，L1若要给 L2管理 guest interrupt file还需 nested相关内核状态。前两项可用不证明第三项；活动 L2迁移还要保存更深层 pending、enable与虚拟路由。当前章节只确认固定 QEMU源码的 L0/L1设备路径，nested中断仍标为演进中。

APLIC与 IMSIC的状态频率也不同。APLIC配置与有线路由相对低频，IMSIC pending/delivery位于中断热路径。这为 split irqchip提供工程动机：让 QEMU保留易迁移、易模拟的 APLIC，把高频 IMSIC留在内核。这个动机由架构分工与最终代码共同支持；具体性能收益仍要由 workload验证，不能仅凭结构推断数值。

## `riscv-aia` 与 `kernel-irqchip=split`

当前 RISC-V KVM accelerator提供 `riscv-aia=auto|emul|hwaccel`。`emul`要求使用 QEMU设备模型；`hwaccel`要求宿主 KVM提供对应 AIA device能力，失败应报告；`auto`根据 capability选择。自动模式便于部署，却会让同一命令行在两台宿主上形成不同状态所有权，迁移和性能复现时应显式固定模式。

允许完整 kernel irqchip时，QEMU通过 KVM device control创建 AIA device fd，设置 hart数量、source数量、地址、guest数量和工作模式等属性，再执行初始化。创建 fd只表示拿到对象，属性设置和 init都可能失败。`kvm_riscv_aia_create()`必须在 `virt` machine已经确定布局后执行，所以它晚于通用 `kvm_arch_irqchip_create()`的 capability门槛。

非 split的 in-kernel路径把 APLIC与 IMSIC交给 KVM。QEMU仍创建与 machine拓扑相关的对象或前端连接，但 emulated APLIC/IMSIC VMState在 in-kernel irqchip条件下不会自然代表权威运行状态。读 `hw/intc/riscv_aplic.c` 和 `riscv_imsic.c` 可看到 KVM分支与 VMState条件，这正是迁移审查必须追到设备实现的原因。

`kernel-irqchip=split`下，QEMU模拟 APLIC，内核加速 IMSIC。APLIC发出的 MSI需要进入 KVM IMSIC接口；当前 IMSIC路径可使用 `KVM_SIGNAL_MSI`等内核机制。split保留 APLIC的用户态 VMState和可观察性，同时减少最终投递的用户态开销。不过目标端仍需兼容的 KVM IMSIC，并能恢复其状态；split没有自动解决所有迁移问题。

`kernel-irqchip=off`或 `riscv-aia=emul`则让 AIA状态留在 QEMU。此时 APLIC/IMSIC VMState负责保存 pending、enable与配置，CPU irq注入仍跨入 KVM。它更容易在缺少内核 AIA的宿主复现，也可能因频繁 MMIO和注入降低性能。选择应写进启动清单和迁移兼容策略。

:::: {.quick-quiz}
为什么生产环境不宜只写 `riscv-aia=auto`，然后假定所有宿主行为一致？

::: {.quick-answer}
`auto`会按宿主 capability选择用户态或内核态实现，二者的性能、可观察状态和迁移要求不同。同一命令行可能在源端与目标端选中不同模式；稳定部署应显式固定并校验所需能力。
:::
::::

## AIA支持怎样演进到 split

提交 [`9634ef7e`](https://gitlab.com/qemu-project/qemu/-/commit/9634ef7e) 是 RISC-V KVM AIA支持的重要历史锚，对应经过多版审查的 [v7系列](https://patchew.org/QEMU/20230727102439.22554-1-yongxuan.wang%40sifive.com/)。系列需要同时修改 accelerator属性、`virt` machine布局、KVM device属性、APLIC/IMSIC分支和错误处理，说明 irqchip加速从来不只是增加一个 ioctl。

多版 review的价值在于暴露跨层契约：用户怎样强制模拟或硬件加速；宿主不支持时 auto与显式模式分别怎样处理；AIA device何时创建；地址和 hart配置由谁提供；失败后怎样回收。最终 `riscv-aia`属性和 device control结构是这些问题收敛后的结果。邮件可解释设计过程，固定标签源码决定本书实际调用链。

split irqchip的重要提交为 [`3fd619db`](https://gitlab.com/qemu-project/qemu/-/commit/3fd619db) 与 [`ce7320bf`](https://gitlab.com/qemu-project/qemu/-/commit/ce7320bf)，对应 [v2系列](https://patchew.org/QEMU/20241119191706.718860-1-dbarboza%40ventanamicro.com/)。它们让 `kernel-irqchip=split` 在 RISC-V AIA上具有明确含义，并调整 APLIC到 in-kernel IMSIC的连接。

从最终实现可以作出强推断：上游希望在性能与用户态状态所有权之间提供中间点。完整模拟便于迁移和调试，完整内核化减少 exit，split选择高频 IMSIC下沉。推断的边界是，上游提交存在不能证明 split必然适合所有 workload；APLIC更新频率、vCPU数和中断拓扑会影响结果。

历史提交还提醒我们检查 machine兼容。AIA地址、guest file数量和 irqchip模式都会影响客户机固件与驱动可见布局。新增 accelerator选项不能悄悄改变旧 machine的 FDT。审查时应把 `virt.c` 的 FDT生成与 KVM device配置并排阅读，确保客户机看到的节点和内核实际创建的资源一致。

## in-kernel AIA 的迁移缺口

固定 `v11.1.0-rc0` 中，QEMU创建 KVM AIA device并设置属性，但当前源码没有展示一套完整的 AIA运行状态 get/set协议。`kvm_riscv_aia_create()`持有的 device fd用于配置和初始化；APLIC/IMSIC在 in-kernel路径下又不会让用户态 VMState自然成为最新状态。由此能确认的源码事实是：内核态 AIA权威状态没有通过现有 QEMU设备 VMState闭环。

这不应被写成“任何环境都绝对无法迁移”，因为厂商内核或后续分支可能有额外接口。对本书固定标签，更准确的结论是 in-kernel AIA保存恢复未由当前源码建立，应标为待验证或受限。迁移测试若只启动源端和目标端，却没有制造 pending中断、改变 enable与路由，很容易漏掉状态缺失。

2026 年 6月出现了专门讨论 AIA save/restore的[补丁系列](https://patchew.org/QEMU/20260602142709086IsQxEt0LYI9ygtpFnj-XN%40zte.com.cn/)。其时间晚于 `v11.1.0-rc0`，且作为邮件补丁出现，恰好说明上游仍在补这条路径。它可以作为“缺口正在被处理”的演进证据，不能倒写成候选标签已经实现。

迁移能力还取决于 Linux UAPI。即使 QEMU新增 VMState，没有内核接口读取 pending、enable、delivery和路由，字段仍不是权威快照；即使源端能读，目标端也需按安全顺序写并支持相同 AIA配置。QEMU提交、内核提交和迁移测试三者要一起闭环。

split模式需要分别审查。QEMU APLIC可用自身 VMState保存，但 KVM IMSIC仍有内核状态；完整模拟则两者都在用户态；完整 hwaccel两者都需内核接口。文档若只写“AIA可迁移”而不标模式，结论没有复现意义。

## 设计选择背后的工程账本

完整用户态模拟的优势是状态集中、可测试、跨宿主要求较低。设备 read/write、pending和路由可用 QEMU trace、GDB和 qtest观察。成本是 MMIO与中断注入往返，多个 vCPU高频中断时还可能争用用户态锁。

完整内核加速缩短 APLIC/IMSIC热路径，减少 vCPU exit和主循环参与。代价是 KVM UAPI表面积增加，状态分散到内核，迁移和调试需要专门接口，错误受宿主内核版本影响。一个内核 bug也可能让 QEMU日志只看到“客户机未收到中断”，缺少中间状态。

split把两类状态分开，适合 APLIC配置低频、IMSIC投递高频的假设。它保留更多用户态可见性，却增加跨边界连接：QEMU APLIC发出的 MSI必须可靠送入 KVM IMSIC，reset和迁移需要协调两侧顺序。边界数量增加后，集成测试的重要性也随之上升。

auto模式把部署便利放在前面，显式模式把可重复性放在前面。开发机快速启动可用 auto；基准、迁移集群和长期兼容测试应记录明确模式。文档给性能数字时必须写 irqchip设置，否则读者无法判断测到的是哪条路径。

ioeventfd与 irqfd也遵循同一账本。它们减少规则明确的通知往返，仍需 QEMU管理注册、注销、reset和迁移。接口越接近数据面，越要用生命周期测试证明没有丢事件、重复事件和 use-after-free。

## 如何观察而不扰乱路径

memory slot可用 QEMU KVM tracepoint、启动日志和受限 GDB断点观察。建议记录每次 add/del的 GPA、size、host address、flags与 slot；同时导出 `info mtree -f`，把 KVM投影与 QEMU FlatView对照。只抓 ioctl看不到原 MemoryRegion名称，只有 mtree又看不到内核最终接受的 slot。

MMIO路径可在 `kvm_cpu_exec()` 的 exit分派、`address_space_rw()`附近和目标设备回调各放一个低频 trace。选择 UART状态寄存器或自建测试设备，避免控制台每字符输出制造海量日志。记录读写方向、宽度、GPA、设备名和 re-entry；不要在高频路径打印整个 CPU状态。

中断测试应同时观察源设备、APLIC/PLIC输入、路由目标、IMSIC或 CPU external irq以及客户机 ISR。任何单点计数都无法区分“源没有触发”“路由错误”“pending未使能”“vCPU未调度”。完整 hwaccel模式下，用户态 trace会缺少内核中间点，需要结合 KVM tracepoint或内核 ftrace。

比较模式时保持 vCPU数量、affinity、guest kernel、AIA配置和 workload一致。统计平均吞吐以外，还应记录 exit类型、每秒 exit、宿主 CPU利用率、IRQ投递延迟分位数和迁移停机时间。内核态路径可能提高吞吐，却因状态同步增加暂停延迟；两个指标都属于工程结果。

故障注入同样有价值。尝试超出 slot上限、创建不对齐内存后端、在 AIA hwaccel缺失的内核上显式请求该模式、迁移带 pending中断的 VM。预期结果应该是可诊断拒绝或状态一致恢复，不能接受静默切换导致行为变化。auto模式允许回退时，日志也应能说明实际选择。

## slot 边界上的几个反例

最简单的内存图只有一段连续 RAM，此时一个大 slot就能覆盖。真实 machine还包含低地址保留区、固件、PCIe窗口、热插区和设备 MMIO。若 RAMBlock在客户机地址上被一个 MMIO窗口切开，FlatView会产生多个 section，KVM也需要多个不重叠 slot。不能因为宿主后端连续就跨过客户机空洞注册，否则 vCPU会把设备访问当普通内存。

相反，客户机 GPA连续也不保证能合成一个 slot。相邻区间可能来自不同 RAMBlock、不同文件后端或不同只读/脏页属性，`userspace_addr`不连续；合并会让 GPA偏移落到错误宿主页。QEMU以 section和后端偏移计算，只有物理与宿主映射都连续、flags兼容时才有合并空间。

alias会产生更隐蔽的例子。某段 boot ROM可能在复位时映射到低地址，之后通过控制寄存器切换为 RAM；同一 GPA在不同时间对应不同后端。更新不只是改 host pointer，还要保证旧 KVM映射失效。若 TLB或 slot残留，客户机可能继续执行旧 ROM，表现为一次偶发的 reset失败。

只读标志无法完整替代设备写保护语义。ROMD区域常允许读走直接内存、写进入设备回调，以支持 flash命令状态机；单个只读 RAM slot只能拒绝写，无法执行命令。QEMU需要在设备模式变化时切换直接映射与 MMIO分派。把所有 ROMD永久注册只读 slot会丢失 flash写语义。

热插内存增加生命周期。新 RAM后端先分配并初始化，MemoryRegion加入拓扑后 listener注册 slot，最后客户机固件或 ACPI/设备树机制才通知可用；拔出顺序反向，客户机先停止使用，再撤销拓扑和 slot，最后释放 host内存。KVM只负责映射步骤，不能证明 guest已经离线页面。

内存 discard或气球回收也要区分客户机 GPA布局与实际宿主页。slot可以继续覆盖 GPA，而后端页面被打洞、按需重新分配；KVM MMU notifier和内存后端保证访问重新建立页。若直接删除 slot，访问会变成 MMIO/错误语义。优化内存占用时应确认期望的是“页内容可丢弃后归零”还是“地址区间不存在”。

large page对齐进一步影响性能。slot本身可覆盖大范围，内核是否用 hugepage还取决于 host地址、GPA、后端与页表对齐。用大量小而错位的 section会阻止大页映射，增加 G-stage TLB压力，却未必增加 `KVM_RUN` exit。性能诊断需要同时看 slot与内核页表统计，不能只数用户态退出。

错误地注册宿主指针具有安全后果。客户机能通过 G-stage读写该范围，越界可能触及 QEMU控制数据。因此 slot长度计算使用溢出安全的地址运算，后端释放顺序也必须严格。对来自命令行的 memory backend大小、offset与对齐，应在注册前验证，不能依赖内核替 QEMU理解完整对象边界。

## CPU 地址访问与设备 DMA 是两套入口

vCPU执行 load/store时，KVM根据 memory slot处理普通 RAM，缺 slot才返回 MMIO。QEMU设备发起 DMA时，通常直接调用自身 `AddressSpace`读写，不经过 `KVM_RUN`。两者最终访问同一客户机物理内容，却有不同线程、权限检查和脏页记录入口。

一个纯用户态 virtio设备从 descriptor取得 GPA，经 `dma_memory_read/write()`访问 guest RAM。AddressSpace可以包含 IOMMU翻译，DMA地址未必等于 CPU看到的 GPA。KVM slot描述 CPU的 guest physical映射，不能替设备完成 IOMMU权限和地址转换。后面的 RISC-V IOMMU章节会展开设备页表，本章只强调两套映射不可混用。

vhost把 virtqueue数据面交给内核线程，DMA写不再经过 QEMU设备回调。迁移时 vhost需要日志或协议把写脏页交给 QEMU，并在停止阶段与队列状态协调。只开启 KVM CPU dirty log可能漏掉 vhost写，因此 RAM迁移层会合并不同写源。

直通设备又有 IOMMU和硬件 DMA。设备可能在 vCPU停止之后仍完成一次写，必须通过 VFIO等层冻结、记录或阻止。memory slot成功注册只证明 CPU能访问 RAM，与设备是否被正确隔离没有直接关系。安全审查应分别检查 KVM G-stage与 DMA映射。

MMIO doorbell通常由 CPU写设备，随后设备 DMA读写 RAM；前半段可以用 ioeventfd缩短，后半段仍要遵守 AddressSpace、IOMMU与 dirty logging。若只测 doorbell exit下降而没有校验 DMA和迁移，优化完成度不足。

设备对 RAM的原子性也不能从 CPU内存模型自动获得。virtqueue协议用特定屏障和索引顺序协调 guest与后端，QEMU/vhost必须遵守。KVM只负责让内存可达，不会修复设备实现缺少 barrier的问题。多 vCPU和高并发队列更容易暴露这类竞态。

## level、edge 与 MSI 的状态不能混写

level-triggered中断表示条件持续存在，控制器在源保持高电平时应维持 pending或在 complete后重新评估。edge-triggered中断表示一次转换事件，源很快恢复，控制器必须锁存这次边沿。把 level当 edge可能在客户机屏蔽期间丢事件，把 edge当 level则可能重复注入。

PLIC的 claim/complete是一段协议。claim读取返回当前最高优先级源，并改变其处理状态；complete写告诉控制器该 context完成。如果物理源仍为高，之后可以重新 pending。迁移正好落在 claim之后、complete之前时，要保存 in-service含义；只保存 CPU external irq电平无法重建。

APLIC同样维护 source模式与 pending，但 MSI模式会把投递转换为对 IMSIC地址的一次消息。消息已经发出后，pending可能转移到 IMSIC；迁移必须避免在源端重发、目标端又恢复 IMSIC pending造成重复。用户态完整模拟可以在同一进程协调，split跨过 QEMU/KVM边界，完整内核模式则依赖内核内部一致快照。

IMSIC按 hart与 interrupt file组织 pending/enable。一个 MSI目标地址隐含 hart、privilege和 guest file选择，地址布局来自 machine配置。`aia-guests`改变可用 guest file，源目标不同不能靠截断恢复。即使两边都支持 AIA，参数不一致仍是迁移不兼容。

`KVM_SIGNAL_MSI`表达一次消息注入，与持续 irq line不同。QEMU APLIC在 split模式发 MSI后，内核 IMSIC拥有是否 pending的结果。重试错误要明确：ioctl失败前内核是否已消费消息，决定能否安全重发。错误路径若没有幂等协议，应停止 VM并报告，不能盲目循环产生重复中断。

中断路由变化也要原子。客户机修改 APLIC target时，旧目标可能已有 pending，新事件应进入新目标；实现要按规范处理在途状态。迁移测试应在修改路由附近制造事件，而不只使用启动后的固定 hart0目标。

多 hart压力可以揭示公平性和锁问题。让多个源以不同优先级投向不同 IMSIC，检查每个 hart的完成数和尾延迟；如果所有事件最终到达却集中在一个 hart，功能测试可能通过，路由实现仍有问题。性能数字要与正确目标分布一起报告。

## AIA device 的创建、reset 与销毁

KVM device control通常先用 `KVM_CREATE_DEVICE`取得 fd，再用一组 device attrs配置。RISC-V AIA需要 machine提供 hart数、source数、APLIC/IMSIC地址与 guest file等参数。属性之间有依赖，初始化命令应在所有必需值成功设置后执行；过早 init会让后续属性不可改或被内核拒绝。

创建过程必须支持部分失败回滚。假设 AIA fd已创建，前几个地址属性成功，最后一个 guest数量不受支持，QEMU要关闭 fd并撤销已经连接的对象，不能回退到 emulation后保留半初始化内核 device。显式 `hwaccel`应报错，`auto`允许回退时也要保证对象完全销毁。

reset需要同时清控制器状态和重新建立静态配置。完整模拟调用 APLIC/IMSIC reset方法；内核模式使用 KVM提供的 reset或重新配置接口。只清 QEMU前端对象不会清内核 pending，客户机复位后可能立刻收到旧中断。当前源码中针对 KVM APLIC/IMSIC reset的演进提交说明这条边界曾需要专门处理。

vCPU hotplug或 hart拓扑变化对 IMSIC尤其敏感，因为 interrupt file与 hart绑定。machine是否允许相关热插、KVM AIA能否动态增加 hart，要以 capability为准。不能先修改 FDT/QOM拓扑，再假定已初始化内核 device自动扩容。固定 `virt`配置通常在创建阶段确定，限制动态变化可以简化状态一致性。

销毁顺序从事件源开始。先阻止设备产生新 irq，撤销 irqfd/ioeventfd与路由，停止 vCPU，再释放 AIA fd和 QEMU对象。若先关 irqchip，后端仍可能写 eventfd或发 MSI，错误会落到已经复用的 fd或得到难以解释的失败。

暂停不同于 reset和销毁。暂停应保留 pending与配置，恢复后继续；reset按架构清状态；销毁释放宿主资源。三种操作若复用同一个“disable AIA”helper，必须带明确模式，不能在迁移暂停时意外清 pending。

## 性能结果需要解释边界，而不是只报比例

可以把一次用户态 MMIO粗略拆成硬件退出、内核出栈、线程调度、AddressSpace分派、设备处理和重新进入。ioeventfd省掉其中用户态分派，in-kernel irqchip省掉一部分注入与控制器访问；它们没有改变客户机设备自身的工作量。若 workload主要受后端磁盘限制，exit减少不会等比例提升吞吐。

平均每秒 exit不足以解释尾延迟。vCPU可能因 BQL或设备锁排队，内核 irqchip也可能因目标 vCPU未被调度而延迟。测试应给出 exit原因分布、单次处理时长、设备队列深度、vCPU调度延迟和客户机完成分位数。把全部时间归给 `KVM_RUN`会混淆“客户机正在执行”和“内核正在处理退出”。

批处理有吞吐与延迟交换。coalesced MMIO、dirty ring和队列通知合并可以降低每事件成本，却可能让第一个事件等待更多时间。网络包吞吐和实时 timer中断对这个权衡的容忍度不同。优化方案应说明目标 workload，不存在对所有设备都最优的边界。

内核化还改变调试成本。模拟模式可以打印每次寄存器访问和 pending变化，hwaccel需要内核 tracepoint、device attr dump或专门 debug接口。若性能收益很小，却让现场问题无法观察，工程上未必值得。split模式的价值之一就是保留 APLIC侧可见性，但 IMSIC仍需内核工具。

最后要把迁移停机时间纳入性能。完整 hwaccel运行阶段可能最快，如果暂停时需要逐 hart读取大量 irqchip状态，停机延迟会增加；当前缺少 save/restore则更直接限制迁移。任何基准结论都应列运行性能和运维能力两张表。

## 用一条 virtio 请求串起全部边界

客户机驱动首先通过 MMIO或 PCI配置区协商特征、写队列地址与大小。这些操作频率低、带状态机和错误语义，通常进入 QEMU设备模型。QEMU验证地址、队列序号和 feature依赖，再建立 ioeventfd、后端与中断路由。此时尚无数据请求，配置却决定后续每条热路径是否安全。

驱动准备 descriptor、available ring和数据缓冲区时，写的是普通 guest RAM。vCPU路径通过 KVM slot直接落到宿主页，不产生设备 MMIO exit；内存屏障保证 descriptor内容先于队列索引可见。随后驱动写 notify门铃，这个写若匹配 ioeventfd，KVM直接唤醒后端；未启用时则通过 `KVM_EXIT_MMIO`进入 QEMU回调。

用户态后端被唤醒后，从 AddressSpace读取 descriptor并执行 I/O；vhost后端在内核读取同一内存。若存在设备 IOMMU，队列给出的地址还要经过设备地址转换，不能直接当作 KVM slot的 GPA。后端完成后写 used ring，这是一笔 DMA式 guest RAM写，迁移期间必须标脏。

完成通知取决于 irqchip模式。模拟 PLIC/AIA时，设备提高 QEMU irq线，控制器更新 pending并调用 KVM注入；split AIA中，QEMU APLIC可以产生 MSI，内核 IMSIC接收；完整 hwaccel可能把更多路由留在 KVM。irqfd可让某些后端事件绕过 QEMU主循环，但路由和生命周期仍由 QEMU建立。

目标 vCPU被调度后，客户机控制器驱动读取 claim/top interrupt，设备驱动检查 used ring并完成请求。一次后端完成不一定对应一次 vCPU exit：中断可以合并，多个 descriptor共用通知，电平也可能持续。正确性以队列内容和客户机完成数为准，不以 ioctl数量一一对应。

请求过程中至少有四个所有者切换：队列配置由 QEMU拥有，descriptor内存由 guest与后端按协议共享，通知由 eventfd传递，pending中断由选定 irqchip拥有。任何优化只移动其中一段。把 ioeventfd打开后，配置寄存器仍在 QEMU；把 IMSIC下沉后，virtqueue状态仍在设备和内存。

迁移若发生在 descriptor已发布、notify未消费时，源端要保留这次通知；发生在后端完成、used ring已写、irq未投递时，目标端要继续产生中断；发生在 pending已建立、客户机尚未 claim时，中断控制器状态要迁移。用这三个切入点测试，比只在空闲队列迁移更能覆盖边界。

reset从相反方向拆除链路。驱动或 machine reset先阻止新队列工作，注销 ioeventfd/irqfd，后端停止访问 guest RAM，设备清配置与 pending，irqchip撤销输出。若先释放 queue对象、后注销 eventfd，一个迟到通知可能唤醒已销毁后端。热拔同样需要这种顺序。

错误传播也贯穿全链。无效 descriptor属于设备错误，eventfd注册失败可能回退用户态通知，AIA hwaccel显式请求失败应中止启动，KVM注入失败不能伪装成设备已完成。日志要包含队列、GPA、irq源、目标 hart和实际模式，才能判断错误位于数据、通知还是中断阶段。

## 按使用场景选择中断实现

开发设备模型时，模拟 PLIC或 AIA提供最完整的用户态可观察性。断点可以看到寄存器读写、pending和 claim，迁移字段也容易核对。若目标是验证新驱动或中断路由，先用模拟模式建立正确性基线，再启用内核加速，差异更容易定位。

追求固定宿主上的吞吐时，可以选择完整 hwaccel，但要显式校验 KVM AIA capability、地址与 hart参数。当前固定标签的保存恢复未闭环，因此这类配置更适合不要求迁移的本地 workload。部署文档应把“不迁移”写成约束，不能等运维切换时才发现。

需要保留 APLIC迁移和调试，同时降低 IMSIC投递成本时，可以评估 split。它增加一条 QEMU到 KVM的 MSI边界，测试必须覆盖错误重试、reset、pending与多 hart路由。由于内核 IMSIC仍有状态，split也要核对保存恢复能力，不能直接沿用模拟模式结论。

异构集群优先选择所有宿主共同支持且状态接口完整的模式。`auto`适合交互试跑，不适合把选择留到迁移目标启动时。源端模拟、目标端自动选中 hwaccel，即使客户机 FDT相同，状态加载路径也可能不同。管理层应把实际模式纳入兼容清单。

实时性 workload要重点测尾延迟和 vCPU调度。内核化减少用户态切换，却不能让未运行的目标 hart立刻处理中断；CPU affinity、宿主抢占和中断合并仍影响结果。吞吐 workload则关注每秒 exit、锁争用与批处理。两个目标可能得出不同的最佳边界。

所有模式都要保留回退解释。显式模式失败时输出缺失 capability或属性；auto回退时记录最终选择；运行时不能因一个注入错误悄悄从内核切回用户态，因为两侧 pending难以原子搬迁。模式只应在 machine初始化阶段收敛。

## 安全与鲁棒性检查

MMIO地址、长度和方向来自 KVM共享页，最终又源于不可信客户机。通用层要验证长度，MemoryRegionOps要限制允许宽度，设备回调不能按客户机值索引越界。日志打印数据时应限制长度，避免一次恶意访问制造海量输出。

ioeventfd的 datamatch配置由可信 QEMU建立，但客户机可以高频触发。后端必须处理 eventfd计数饱和、队列失效和 reset竞态；限流不能丢掉必须处理的设备语义。取消注册后还要等待正在运行的回调退出，关闭 fd本身不总能替代线程同步。

irqfd与 MSI目标决定中断送到哪个 vCPU或 guest file。地址、source ID和 hart索引要在创建时验证，整数移位不能溢出 machine地址范围。`aia-guests`来自 machine属性，内核返回的能力上限必须先比较；截断会让不同 L2/guest file共享状态。

memory slot的 host pointer尤其敏感。计算 `userspace_addr + size`时要检查溢出，RAMBlock生命周期与 slot撤销顺序必须固定。客户机虽然不能直接选择 host pointer，却能访问任何错误注册的 GPA；这里的一个长度错误会越过虚拟机隔离边界。

故障恢复也属于安全。内核 AIA device部分配置失败时，应完全关闭并清理，再决定是否回退；保留半配置 irqchip可能把后续中断送入未知对象。迁移加载部分状态失败时保持 vCPU暂停，不能带着不一致路由继续运行。

## 启动前后的核对表

machine realize结束时，先对照 `info mtree`与 FDT。RAM、ROM、MMIO窗口的 GPA不能重叠，FDT memory节点应落在实际 RAM slot范围，PLIC/AIA地址应对应设备 MemoryRegion。KVM日志中的 slot只覆盖可直接映射区，不应包含 UART、APLIC或 IMSIC控制窗口。

接着核对 accelerator选择。显式记录 `riscv-aia`与 `kernel-irqchip`最终值、KVM device是否创建、APLIC和 IMSIC各自由谁拥有。使用 auto时把回退原因写入报告；缺少日志就无法在迁移和性能回归中复现同一边界。

客户机启动后，读取设备树并检查驱动绑定。FDT宣称 AIA而 QEMU实际回退 PLIC，或 `aia-guests`与 KVM device属性不同，都应在早期暴露。让每个 hart分别接收一次外部中断，可以发现地址和目标索引错误。

设备工作后，选择一个 RAM写、一个 MMIO读、一个 ioeventfd通知和一个外部中断逐段 trace。预期 RAM不 exit，MMIO进入设备回调，匹配 notify唤醒后端，irq按所选控制器到达目标。四项构成最小数据面基线。

暂停、reset和热拔分别执行一次。暂停保留 pending，reset清除架构规定状态，热拔停止事件源并释放路由。三者结果若完全相同，通常说明生命周期实现过度复用。最后在 pending中断和 in-flight队列存在时迁移，明确当前模式是否有保存恢复接口。

升级 QEMU或宿主内核后，先重复这张核对表，再跑吞吐基准。新增 capability可能让 `auto`从模拟切到内核路径，性能突然变化并不一定来自某个优化提交；迁移行为也可能随状态所有者改变。显式模式的对照组可以区分自动选择和执行实现本身。

核对结果应同时保存成功路径和不支持路径。没有 KVM AIA的宿主上，显式 hwaccel应给出可诊断错误，auto可以回退并报告实际模式；slot超限、无效 AIA参数和注入失败也要留下明确对象与范围。错误信息本身属于可运维性，不能只在功能测试中检查退出码。

若一次测试同时改变内存后端、irqchip与设备后端，结果很难归因。基线先固定连续匿名 RAM、用户态 virtio和模拟中断，再分别替换 hugepage、vhost与 KVM AIA。每一步保留相同客户机镜像和负载，才能把 slot、I/O与中断三条边界的影响分开。

这种单变量方法也适用于内核升级：先证明功能路径一致，再讨论性能变化和迁移能力。

## 实验一：把 FlatView 与 KVM slots 对齐

::: {.hands-on}
配套英文实验手册：[`inspect-kvm-memory-slots`](../experiments/part-03-riscv-hardware-virtualization/chapter-14-kvm-memory-io-and-interrupts/inspect-kvm-memory-slots/README.md)。

在具备 RISC-V KVM 的宿主上启动 `virt` machine，先使用一段连续 RAM，再增加一个独立 memory backend与可热插区域。保存 `info mtree -f`、RAMBlock信息和 KVM memory listener trace；在 `kvm_set_phys_mem()`及最终 `KVM_SET_USER_MEMORY_REGION{,2}` 调用处记录 GPA、size、host address、slot与 flags。

将每条 slot映射回 `MemoryRegionSection`，验证设备 MMIO与保留洞没有注册为 RAM。执行一次内存热插和拔出，确认 delete发生在后端释放之前，slot编号可以复用而 GPA语义保持。随后开启迁移脏页日志，观察 flags变化与 dirty收集。实验结论只覆盖当前命令行和宿主 capability，不把 slot编号写入任何兼容结论。
:::

## 实验二：跟踪 MMIO、ioeventfd 与中断

::: {.hands-on}
配套英文实验手册：[`trace-irq-and-io-exits`](../experiments/part-03-riscv-hardware-virtualization/chapter-14-kvm-memory-io-and-interrupts/trace-irq-and-io-exits/README.md)。

选择一个低频 UART寄存器读写和一个 virtio队列 notify。对前者记录 `KVM_EXIT_MMIO`、AddressSpace分派、设备回调及下一次 re-entry；对后者分别启用和关闭 ioeventfd，比较 exit数量与后端唤醒。再让设备产生一次外部中断，沿 PLIC或 APLIC/IMSIC直到客户机 ISR记录各节点。

日志表至少包含访问地址、宽度、方向、exit reason、vCPU、设备回调、eventfd与最终 irq目标。预期 UART保持用户态 MMIO语义，匹配的 virtio notify可避开完整回调；中断路径取决于所选 irqchip。实验不能用“exit减少”单独证明正确，还要验证队列完成和中断次数没有丢失或重复。
:::

## 实验三：比较三种 AIA 状态所有权

::: {.hands-on}
本实验复用 [`trace-irq-and-io-exits`](../experiments/part-03-riscv-hardware-virtualization/chapter-14-kvm-memory-io-and-interrupts/trace-irq-and-io-exits/README.md)，模式矩阵与环境填写要求见[第 14章英文实验索引](../experiments/part-03-riscv-hardware-virtualization/chapter-14-kvm-memory-io-and-interrupts/README.md)。

在同一宿主依次运行 QEMU模拟 AIA、完整 `riscv-aia=hwaccel`和 `kernel-irqchip=split`。若 capability不支持某一模式，将其标为“不具备前提”，不要改用 auto掩盖。每种模式触发相同数量的有线中断与 MSI，记录 APLIC MMIO exit、IMSIC相关 exit、内核注入、宿主利用率和客户机完成数。

暂停时分别检查 QEMU APLIC/IMSIC对象和 KVM device可查询状态，明确 pending、enable与路由由谁拥有。再制造一个尚未被客户机 claim的中断并执行保存恢复。固定标签中若 in-kernel状态无法完整导出，应把迁移项标成“未闭环/待验证”，而不是把启动成功当作迁移成功。
:::

## 阅读源码与邮件的检查清单

从内存拓扑开始，确认新增区域是否进入 FlatView、是否应注册 slot、对齐和 flags如何计算、add/del错误怎样回滚。再看迁移，确认 CPU写、DMA写与 vhost写都进入 dirty集合，停止阶段还有最后同步。遇到性能补丁，记录减少的是 bitmap扫描、exit还是锁争用。

从 I/O开始，确认访问为何不能直接映射、设备允许的宽度与端序、读结果何时提交、暂停请求是否尊重 re-entry协议。若补丁引入 ioeventfd或 coalescing，列出哪些写被截获、reset与 BAR移动怎样注销、批处理是否改变可见副作用。

从中断开始，先画出 source、控制器、路由、目标 hart和 privilege。再标每段位于 QEMU、KVM还是硬件，pending和 mask由谁拥有。对 AIA务必写明 emul、split或 full hwaccel；检查 `aia-guests`、FDT与 KVM device属性一致；最后寻找 save/restore接口与带 pending状态的迁移测试。

邮件证据用于回答方案如何选择。`9634ef7e` 与 v7系列说明完整 AIA接入经历了哪些边界审查，`3fd619db`/`ce7320bf` 与 v2系列说明 split怎样形成，2026年 save/restore系列则说明固定标签之后仍在补迁移。最终功能判断始终回到固定源码和可复现实验。

## 小结

QEMU先用 `MemoryRegion`和 FlatView表达完整客户机物理空间，再由 KVM memory listener把可直接访问的 RAM投影成 slots。slot让 CPU内存热路径停留在硬件，dirty logging又在迁移期间恢复对写入页的观察。MMIO exit把复杂设备语义交回 AddressSpace；ioeventfd、irqfd和 coalesced MMIO只缩短适合匹配或批处理的部分。

RISC-V中断的用户态基线是 PLIC或模拟 AIA，完整 KVM AIA把 APLIC/IMSIC状态下沉，split则保留 QEMU APLIC并加速 IMSIC。历史提交解释了这种分层怎样进入上游，也暴露了迁移代价：`v11.1.0-rc0`没有建立完整 in-kernel AIA save/restore闭环，后续邮件系列只能标作演进证据。下一章将把 CPU one-reg、timer、AIA、内存和未决 I/O放进一次完整停止与恢复流程，审查普通迁移和 nested migration分别缺少什么。
