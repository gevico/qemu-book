# 地址空间与 MemoryRegion

RISC-V CPU 发出一次访存，地址可能经过页表、TLB、客户机物理地址空间，再落到 RAM、PCIe BAR 或中断控制器。配置代码看到的是一棵 MemoryRegion tree，执行热路径使用的却是已经扁平化的访问视图。

## 本章目标

- 区分 `MemoryRegion`、`AddressSpace`、`FlatView` 与 `RAMBlock`；
- 理解 subregion、overlap、alias 和 container 的解析规则；
- 跟踪 CPU 与 DMA 访问在内存分派层的汇合位置。

## MemoryRegion 描述响应者

叶子 region 可以表示 RAM、ROM、MMIO 或 IOMMU，容器 region 组织子区域。offset 决定映射位置，priority 解决重叠，alias 把另一个 region 的一段范围映射到新窗口。

:::: {.quick-quiz}
alias region 为什么不复制内存内容？

::: {.quick-answer}
alias 只重映射目标 MemoryRegion 的地址范围，本身没有独立存储。两个窗口访问同一份内容，目标变化会立即可见，也不需要为别名复制或重复迁移数据。
:::
::::

## 从配置树到 FlatView

内存拓扑更新通过 transaction 合并，listener 接收变化，AddressSpace 再发布新的 FlatView。访问热路径可以读取稳定快照，旧视图等到 RCU grace period 后再回收。

:::: {.quick-quiz}
为什么 FlatView 更新适合由 RCU 保护？

::: {.quick-answer}
访存是高频读操作，拓扑更新相对少见。更新方可以构造新快照后原子发布，让既有读者继续使用旧视图；延迟回收旧对象，能避免每次查找都获取重锁。
:::
::::

## RISC-V `virt` 的地址布局

`virt` machine 在板级初始化中创建 DRAM、固件区、ACLINT、PLIC/AIA、UART、PCIe ECAM 和 MMIO 窗口。设备树或 ACPI 把同一布局告诉客户机，MemoryRegion tree 则决定 QEMU 如何响应访问。

## CPU、DMA 与 IOMMU

CPU 先经过 RISC-V MMU 和软件或硬件 TLB，设备 DMA 从选定的 AddressSpace 出发，并可能经过 RISC-V IOMMU。完成各自转换后，两条路径都进入 MemoryRegion 分派，最终访问 RAM 或调用设备回调。

:::: {.quick-quiz}
设备 DMA 和 vCPU 访存在哪个层次汇合？

::: {.quick-answer}
两者在完成各自的地址转换后，都会进入 AddressSpace／MemoryRegion 的客户机物理访问分派。CPU 路径先经过 MMU，DMA 可能经过 IOMMU，但最终使用同一套 RAM 与设备响应规则。
:::
::::

::: {.source-path}
从 `system/memory.c`、`system/physmem.c`、`hw/riscv/virt.c` 和 `hw/riscv/riscv-iommu.c` 建立拓扑与热路径。Git／邮件研究关注 FlatView、listener、RCU 和 IOMMU notifier 的演进。
:::

::: {.hands-on}
实验步骤与产物位置见英文手册 [Map memory regions](../experiments/part-01-system-foundations/chapter-05-address-spaces/map-memory-regions/README.md)。使用 HMP `info mtree -f` 导出 RISC-V `virt` 的 MemoryRegion 与 FlatView，中文报告把 UART、PLIC/AIA、PCIe ECAM、PCIe MMIO、MROM 和 DRAM 映射回 `virt_memmap[]` 与创建代码。每一项注明区域类型、父容器、偏移、最终客户机物理范围和响应回调，不能只复制 mtree 输出。
:::

## 一次访存至少有三种地址

RISC-V hart 执行 load/store 时，指令给出客户机虚拟地址。MMU 根据当前特权级、`satp`、可能的 `vsatp`/`hgatp`、PMP 与页表，把它转换为客户机物理地址；QEMU 再在某个 `AddressSpace` 中解释该物理地址，落到 RAM 或 MMIO。宿主最终访问的 QEMU 虚拟地址属于第三套坐标。日志若只写一个 `addr`，很容易拿客户机虚拟地址去 `info mtree` 搜索，当然找不到。

TCG 下，RISC-V 地址转换和 SoftMMU/TLB 由 QEMU 软件路径实现，TLB 命中后可快速访问 RAM，MMIO 或异常则进入慢路径。KVM 下，客户机页表遍历主要由硬件和内核 vCPU 完成，RAM 通过 KVM memory slot 映射，无法在内核处理的 MMIO 以 exit 回到 QEMU。两条加速器路径不同，客户机物理平台仍由 `virt` 的内存拓扑约束。

设备 DMA 又有自己的输入地址。一个简单 sysbus 设备可能直接使用系统内存 AddressSpace，PCIe 设备可从总线 DMA AddressSpace 出发，启用 RISC-V IOMMU 后还要经过 I/O 页表与权限翻译。CPU 与 DMA 并非从同一入口开始，却会在完成各自转换后使用 QEMU 的物理分派与 RAM/设备响应。

:::: {.quick-quiz}
GDB 显示客户机 PC 正在访问虚拟地址 `0xffff...`，为什么不能直接在 `virt_memmap[]` 中寻找这个数？

::: {.quick-answer}
`virt_memmap[]` 描述客户机物理平台，PC 或指令操作数可能是客户机虚拟地址。应先依据当前页表、特权级和 MMU 状态完成 RISC-V 地址转换，再把得到的客户机物理地址与 MemoryRegion/FlatView 对照。宿主 QEMU 指针又属于另一坐标。
:::
::::

## MemoryRegion 是“谁对一段地址作出响应”的描述

[`Memory API` 文档](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/devel/memory.rst) 与 [`system/memory.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/system/memory.c) 用一张有层次的图描述物理响应者。叶子可以是 RAM、ROM、MMIO、IOMMU 或 alias，container 用来组织子区域。设备实例通常在 realize 中初始化自己的 region，再由 Machine、bus 或 bridge 把它映射到更大的容器。

MemoryRegion 本身不是客户机地址。它拥有大小和操作，却要作为某个父 region 的 subregion，以 offset 放置；同一 region 还可能通过 alias 从另一窗口可见。最终地址取决于从 AddressSpace root 到叶子的偏移累积。报告“UART region 大小 0x100”仍不足以定位 UART，还要写它在系统内存容器中的 base。

区域图表达的是配置与组合，访问热路径不会每次递归走所有 object child。拓扑变更后，QEMU 生成 FlatView 和分派结构，为地址查找提供非重叠范围。把配置图与执行视图分开，是理解 memory API 的第一道门。

## RAM、ROM 与 MMIO 的叶子语义

RAM region 对应可读写客户机内存，通常关联一个 RAMBlock 作为宿主后备与迁移身份。访问可以在满足条件时直接变成宿主内存读写，仍需处理脏页、只读、加密或加速器映射等状态。ROM 对客户机写入有受限语义，QEMU 在启动和 reset 阶段可能通过 ROM 管理接口更新其内容。

MMIO region 保存 `MemoryRegionOps`，访问到达后调用设备 read/write 回调。ops 声明有效访问宽度、实现宽度、端序与可选属性。客户机一次 8 字节访问若设备只实现 4 字节，memory API 可能按合法规则拆分，也可能拒绝；结果由 ops 配置决定，不能假定 C 回调参数宽度永远等于指令宽度。

IOMMU region 的响应不是普通数据读写，它把输入 I/O 地址翻译到目标 AddressSpace 与地址，并返回权限等信息；alias 则简单重定位目标 region 的一段范围。container 通常没有自己的数据存储，空洞如何继续匹配要看父与重叠拓扑。不同类型共用 MemoryRegion 基础，是为了让它们参与同一地址组合，不表示访问语义相同。

## Container 把局部地图拼成系统地图

设备内部可以先建立局部容器。例如一个 PCI device 有多个 BAR region，桥又提供下游窗口，Machine 最后把主桥接到系统内存。每一层只处理自己的相对 offset，QEMU 在渲染时累加并裁剪。这样设备模型不必知道它在 `virt` 上最终被分配到哪个 PCIe MMIO 地址，也能被其他 Machine 复用。

container 的大小定义可容纳范围，subregion 超出或溢出应在建立拓扑时检查。一个 container 还可用于覆盖：高优先级设备窗口遮住低优先级 RAM，禁用后低层重新可见。芯片选择、ROM shadow 和别名窗口都可借此表达，而不需要改写每次访问的全局 if/else。

图必须保持可渲染，alias 或 subregion 关系若形成环，会让递归失去终点。API 与调用约定限制这种结构。QOM child 与 MemoryRegion subregion 又是两张图：一个设备拥有 region 对象，region 被映到系统容器，设备 owner 不必等于内存父容器。

## Alias 共享目标，不复制内容

`memory_region_init_alias()` 创建从新窗口指向目标 region 某段偏移的映射。两个窗口访问同一目标状态，写入一边会从另一边观察到。alias 自己不创建 RAMBlock，也不复制 MMIO 寄存器；迁移保存目标一次，而不是为每个别名保存一份内容。

alias offset 与 alias 自身大小要同时计算。外部地址先减去 alias 在父容器的 base，再加 target offset，才得到目标 region 内偏移。多层 alias 会继续组合，调试时如果只看最后设备回调的 `addr`，它通常已经是设备局部 offset，不能反推出客户机使用了哪个窗口。

启用/禁用 alias 可以切换可见窗口，却不改变目标本身。若其他 AddressSpace 仍映射目标，设备仍可能被访问。生命周期上，alias 必须保证目标在其存在期间有效；设备 unrealize 应按拥有关系撤销别名，避免 FlatView 中留下指向已释放 region 的范围。

## Overlap 与 priority 是显式的地址选择规则

普通 `memory_region_add_subregion()` 用于不应重叠的区域，`memory_region_add_subregion_overlap()` 允许调用者给出 priority。重叠区中更高 priority 的 region 先取得响应，低优先级区域在未被覆盖的部分仍可见。相同优先级的顺序由 API 的插入规则决定，设计不应在没有说明时依赖偶然调用次序。

priority 解决同一 AddressSpace 中的覆盖，它与设备中断优先级、QOM 属性优先级无关。数值只在相关 sibling 渲染时比较。把一个 region 调到高优先级可以修复当前窗口，却可能遮住更大范围的 RAM；审查必须画出交集，不只看起点。

region 的 `enabled` 状态参与渲染。禁用高优先级覆盖后，原先被挡住的低层范围重新出现；transaction 可以把多个 enable/disable 合并成一次拓扑发布，避免客户机短暂看到两边同时或都不响应。这种切换是第二个实验的核心。

:::: {.quick-quiz}
两个 sibling region 地址重叠，把其中一个设置为更高 priority 后，低优先级 region 是否从整棵树删除？

::: {.quick-answer}
不会。它只在交集范围被遮住，未重叠部分仍可进入 FlatView；高优先级 region 禁用或移除后，低层范围还能重新显现。应比较渲染后的区间，而不是把 priority 当成对象删除。
:::
::::

## AddressSpace 是观察同一图的一种视角

`AddressSpace` 以某个 root MemoryRegion 为起点，维护该视角下的 FlatView 与 listener。系统内存和系统 I/O 是常见全局 AddressSpace，设备或 IOMMU 还可建立专用视角。相同目标 region 可以从多个 AddressSpace 到达，地址与权限因路径不同。

这项抽象避免把“物理内存”写死成唯一全局数组。CPU、DMA、PCIe 与 IOMMU 可以选择各自 root，桥和翻译层把请求导向下一 AddressSpace。实现设备 DMA 时，必须使用设备获得的 DMA AddressSpace，直接调用全局 `address_space_memory` 会绕过 IOMMU 和总线限制。

AddressSpace 初始化后会注册到内存核心，拓扑变化时得到新视图；销毁也要经过 RCU 等待旧读者。调用者不能在保存一份裸 `FlatView *` 后无期限使用，必须遵守 ref/RCU API。视角是对象，快照也有生命周期。

## FlatView 把重叠图渲染成非重叠区间

MemoryRegion tree 便于配置，却包含 container、alias、disabled region 和重叠。`render_memory_region()` 递归遍历 root，计算裁剪后的绝对范围、alias 偏移和 priority，把能响应的叶子加入 FlatRange；`generate_memory_topology()` 生成新的 FlatView。最终 FlatRange 按地址排列且彼此不重叠，热路径不必每次重新解决覆盖关系。

渲染要处理区间裁剪与地址溢出。父容器只暴露子区域落在自身范围内的部分，alias 目标也受源窗口大小限制。priority 影响交集分割，因此一个大的 RAM region 可能在 FlatView 中被多个设备窗口切成若干段。`info mtree -f` 显示的正是这类扁平结果，很适合与配置树对照。

FlatView 不是只读文本，它还连接 MemoryRegionSection、dispatch tree 和 listener。新视图与旧视图比较后，QEMU 通知 KVM、vhost 等消费者新增、删除或属性变化。若每次单个 region 修改都立即重建与通知，大型机器初始化会产生大量重复工作，transaction 因此成为必要机制。

## Transaction 把一组拓扑改动原子发布

`memory_region_transaction_begin()` 增加 transaction 深度，期间 add/del、enable、priority 等修改标记 pending；最外层 `memory_region_transaction_commit()` 才统一生成拓扑、比较视图并通知 listener。嵌套允许公共辅助函数在不知道外层是否已经批处理的情况下安全使用同一接口。

“原子发布”说的是读者不会观察每个中间 FlatView，不表示所有设备业务状态自动成为事务。调用者仍要在合适锁或 BQL 下修改，确保属性、IRQ 与设备树等相关状态不会与地址视图错位。transaction 只覆盖 memory API 管理的拓扑。

commit 可能触发多个 listener 和宿主系统调用，临界区过大将影响停顿。Machine 初始化可以批量完成，热插拔则要平衡一致性与延迟。若回调在 listener 中反向修改内存拓扑，还可能形成复杂重入，API 对调用阶段有约束，不能把 commit 当普通 setter。

## MemoryListener 把同一拓扑交给不同执行后端

MemoryListener 观察 AddressSpace 的 region add/del、日志状态、eventfd 与 transaction begin/commit 等事件。KVM listener 把 RAM ranges 转换为内核 memory slots，vhost listener 把客户机内存表交给数据面，迁移和脏页跟踪也使用相关通知。MemoryRegion 因而成为平台模型与多个后端之间的公共描述。

listener 有优先级与回调顺序，新增与删除往往采用相反方向，确保依赖者按正确次序建立和拆除。一个 listener 失败时的处理受接口具体契约限制，不能假定内存拓扑像数据库事务一样可由所有外部系统无条件回滚。设计新 listener 前要阅读现有调用与错误模型。

2011 年提交 [`7664e80c`](https://gitlab.com/qemu-project/qemu/-/commit/7664e80c) 增加观察物理映射的 MemoryListener API，随后 [`a01672d3`](https://gitlab.com/qemu-project/qemu/-/commit/a01672d3) 与 [`04097f7c`](https://gitlab.com/qemu-project/qemu/-/commit/04097f7c) 分别让 KVM、vhost 使用 listener。历史说明公共内存图不是只服务 TCG 查找，它还要把平台变化广播给加速与后端。

::: {.design-note}
已核对事实是 KVM 与 vhost 先后改用 MemoryListener，当前 listener 仍由 memory 核心在 topology commit 中驱动。作者推断，这种观察者边界减少了 Machine 对具体加速器的直接调用，也让新增消费者能复用同一 FlatView；代价是提交顺序、错误和生命周期更难，需要严格的 transaction 契约。
:::

## RCU 让访存读取稳定的旧视图

地址查找是极高频读操作，拓扑更新相对少。当前 AddressSpace 可以原子发布新 FlatView，读者在 RCU read-side 临界区继续使用旧视图，grace period 后再由 `call_rcu()` 回收。这样 vCPU 与 I/O 热路径不必为每次物理访问取得一把全局重锁。

提交 [`374f2981d1f`](https://gitlab.com/qemu-project/qemu/-/commit/374f2981d1f) 把 `current_map` 置于 RCU 保护，提交说明提到大型系统和许多 IOThread 上 `flat_view_mutex` 的 futex 争用。上游已经把原因明确到读侧锁竞争带来的扩展性问题。更新仍有成本，构造和 listener 通知继续在写侧完成。

读者只能在保护期内使用视图及其范围，或取得明确引用。MemoryRegion 目标的生命周期还要与视图回收配合，删除 region 后不能立即释放设备。RCU 保存旧地图，并不保存一个已被设备 unrealize 破坏的回调对象；内存 transaction、对象引用和设备 teardown 必须一起安排。

## Dispatch 把绝对地址变成设备局部 offset

[`system/physmem.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/system/physmem.c) 与 memory 核心共同实现 address-space 查找、读写和 map。请求先在当前 FlatView/dispatch 结构中找到 FlatRange，再根据 range offset 与 region 映射计算设备局部地址，检查访问属性，最后直达 RAM 或调用 MemoryRegionOps。

MMIO 回调看到的 `addr` 通常相对该 region，不是客户机物理绝对地址。设备可以据此用寄存器偏移 switch，而不关心 Machine 把窗口放在哪里。trace 若想显示客户机绝对地址，需要在分派层或同时记录 region base，不能在设备回调里把局部 offset 当绝对地址打印。

跨 region 或不满足实现宽度的访问可能被拆分。拆分顺序、端序和原子性会影响设备行为，尤其是读清寄存器、FIFO 和 doorbell。设备应在 ops 中准确声明合法宽度，非法访问按规范返回，而不是依赖宿主未对齐 C 读写碰巧工作。

## `MemTxAttrs` 与 `MemTxResult` 带着访问上下文

内存请求不只有地址、大小和值，还可能携带安全属性、请求者身份、是否未指定等信息，设备回调通过 `MemTxAttrs` 判断访问来源。IOMMU、TrustZone 类机制和平台安全域会使用这些属性；RISC-V 路径也可能需要 requester 信息。忽略 attrs 会让不同发起者被错误合并。

回调返回 `MemTxResult`，让失败沿内存访问路径传播。TCG CPU 访问可据此形成异常或未实现行为，DMA 调用者可收到错误，KVM MMIO exit 也要转换结果。设备不应对客户机可触发的非法偏移直接 `abort()`，否则一条恶意访存就能终止 QEMU 进程。

结果语义由调用层解释，设备只报告本次事务。一次 8 字节访问被拆成两个 4 字节，其中后半失败时，前半可能已经产生副作用，memory API 不承诺通用回滚。规范要求原子的寄存器必须限制访问宽度或实现专用处理，不能寄希望于分派层恢复。

## RAMBlock 是宿主后备与迁移身份

MemoryRegion 描述客户机地址响应，RAMBlock 则代表一段宿主分配或后端提供的 RAM 存储，带有 id、host pointer、大小、page 信息和脏页相关状态。一个 RAM region 通常关联 RAMBlock，alias 仍指向同一目标，不新建 block。二者生命周期相关，却不是同一抽象。

RAMBlock 列表被迁移、脏页、KVM 与 address_space_map 等路径使用。其 id 要在迁移两端稳定，大小变化受严格约束。宿主后备可能来自匿名内存、文件、memfd 或用户提供的 memory-backend，客户机物理地址仍由 region 映射决定。同一个 1 GiB 后端可以被 Machine 放在 DRAM 基址，不意味着宿主指针等于 `0x80000000`。

热插拔内存会创建和映射新的 block/region，拔除要先确保客户机不再使用、迁移和 DMA 不再持有映射。RCU 延迟回收 RAMBlock 列表读者，pin 或 map 引用还可能延长后备寿命。第五章把这项区别讲清，后续迁移章节才能准确说明“保存的是内容、身份还是地址”。

## CPU 访问：从 RISC-V MMU 到系统 AddressSpace

TCG 执行 RISC-V load/store 时，TLB 首先缓存客户机虚拟页到物理页及权限。miss 路径依据当前特权级、页表模式、PMP 与 H 扩展的两阶段转换计算结果，填入 QEMU TLB。RAM fast path 随后可以直接访问宿主后备，MMIO 或特殊属性则进入 `address_space_*` 慢路径。

两阶段地址转换要区分 guest virtual、guest physical 与 host physical（从虚拟机内部 hypervisor 视角），而 QEMU 文中“host”还可能指宿主机器。书中将 H 扩展的中间地址明确写成 VS-stage/G-stage，不用一个含糊 GPA 覆盖全部。无论转换几级，`virt_memmap[]` 对应最终送到平台 AddressSpace 的客户机物理范围。

KVM 让硬件和宿主内核处理页表/TLB，QEMU 通过 MemoryListener 把可直接映射 RAM 注册为 memory slot。访问 MMIO 窗口时 KVM exit 携带地址和数据，QEMU 再走 MemoryRegion 分派。`info mtree` 因而仍是 KVM MMIO 的平台依据，却不能显示客户机页表或内核 TLB。

## DMA 访问必须从设备的 AddressSpace 出发

设备读取描述符时通常调用 DMA helper，传入设备相关 AddressSpace、地址、长度、方向与属性。helper 处理 IOMMU 翻译、跨 FlatRange 分段、RAM 映射或 MMIO 回调，并报告失败。直接把 DMA 地址加到 `memory_region_get_ram_ptr()` 上，会绕过权限、alias、IOMMU 和热插拔生命周期。

`address_space_map()` 可把一段可直接访问 RAM 暂时映射给后端，并返回实际连续长度。调用者必须在完成后 unmap，标明是否写入，让脏页与失效处理生效。映射不保证覆盖请求全部长度，也不保证目标一定是 RAM；循环和错误分支要处理短 map。

异步 DMA 又叠加第三章的生命周期。设备发起请求后，IOMMU 映射可能变化，RAMBlock 可能进入 unplug，设备可能 reset。后端要么固定映射并由 notifier 维护，要么在每次访问重新翻译；选择取决于性能与协议。无论哪种，都不能让一个裸宿主指针无限期逃出 memory API。

:::: {.quick-quiz}
设备拿到 `address_space_map()` 返回的宿主指针后，为什么仍必须调用 unmap？

::: {.quick-answer}
map 可能建立临时映射或引用，并返回比请求短的范围；unmap 释放资源、报告写入长度并触发脏页等处理。永久保存裸指针会绕过拓扑变化、IOMMU 与热拔除生命周期，也可能让迁移看不到设备写入。
:::
::::

## RISC-V `virt` 的当前地址骨架

`v11.1.0-rc0` 的 `virt_memmap[]` 把 MROM 放在 `0x1000` 起的低地址区，test、RTC 随后出现，CLINT 位于 `0x02000000`，平台与中断窗口分布在更高区域，UART0 位于 `0x10000000`，八个 virtio-mmio 窗口从 `0x10001000` 开始。fw_cfg、flash、IMSIC、PCIe ECAM/MMIO 与 `0x80000000` 起的 DRAM 共同组成主骨架。

数字必须与源码和本次配置一同阅读。选择 AIA 会创建 APLIC/IMSIC 相关区域，传统路径使用 PLIC；IOMMU、PCIe 和其他可选项也影响实际对象。`virt_memmap[]` 提供固定候选 base/size，`virt_machine_init()` 的条件分支决定哪些 region 被初始化和映射，FlatView 则给出最终无遮挡范围。

设备树把相同布局交给客户机。实验对每个锚点做三向核对：`virt_memmap[]` 的常量、`info mtree -f` 的 FlatRange、DTB 的 `reg`。三者若不一致，先确认属性与版本，再检查 alias/overlap 和地址 cell 编码。任意两份一致都不能自动证明第三份正确。

## RISC-V IOMMU 给 DMA 加入第二套页表

[`hw/riscv/riscv-iommu.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/riscv-iommu.c) 实现 RISC-V IOMMU 设备核心，PCIe 等 requester 的 DMA 地址根据设备上下文和页表翻译，再导向目标 AddressSpace。IOTLB/IOATC 缓存降低遍历成本，失效命令与 notifier 保证映射变化能够传播，错误则通过 fault 记录与中断等机制让软件观察。

2024 年提交 [`0c54acb8243`](https://gitlab.com/qemu-project/qemu/-/commit/0c54acb8243) 引入基于[已批准 1.0 规范](https://github.com/riscv-non-isa/riscv-iommu/releases/download/v1.0/riscv-iommu.pdf)的基础模拟，对应 Message-ID [`20241016204038.649340-4-dbarboza@ventanamicro.com`](https://lore.kernel.org/qemu-devel/20241016204038.649340-4-dbarboza%40ventanamicro.com/)；系列后续加入 IOATC 与 ATS。提交 [`2c12de146`](https://gitlab.com/qemu-project/qemu/-/commit/2c12de146) 把 IOMMU 选项接入 `virt`，对应 Message-ID [`20241106133407.604587-5-dbarboza@ventanamicro.com`](https://lore.kernel.org/qemu-devel/20241106133407.604587-5-dbarboza%40ventanamicro.com/)。

这条历史展示了“设备实现”与“Machine 集成”的分步。先有符合规范的 IOMMU 核心、缓存和翻译，再由 `virt` 创建实例、连接 PCIe、生成 DTB/ACPI 信息。作者可以推断分步便于独立 review 规范语义与平台接线；具体系列动机仍以 cover letter 和 patch 说明为准。

## IOMMU notifier 为直通与缓存后端传播映射变化

若后端每次 DMA 都调用软件翻译，正确性直接但开销较高；vhost、VFIO 或其他加速路径可能缓存已翻译映射，需要在 guest 更新 IOMMU 页表、执行 invalidation 或改变权限时收到通知。IOMMU notifier 描述映射新增、失效和能力，让后端维护自己的视图。

通知顺序与粒度影响性能和安全。漏掉失效会让设备继续访问已撤销内存，过度全量失效则让缓存收益消失。页大小、权限和 requester ID 都要准确，ATS 又允许设备侧缓存 translation，形成更多层次。上游实现必须同时对照 RISC-V IOMMU 规范与 QEMU 通用 notifier 契约。

迁移时，缓存通常可丢弃并在目标重建，权威页表和设备可见 fault 状态则要保存。暂停 vCPU 不一定自动停止外部 DMA，迁移框架还需 quiesce 后端。MemoryRegion/IOMMU 对象只描述翻译，设备生命周期负责确保没有请求越过切换边界。

## 脏页跟踪把“写过 RAM”变成迁移信息

迁移需要知道哪些 RAM 页在一轮发送后又被 CPU 或设备写过。memory API 和 RAMBlock 维护脏页位图，KVM 可以在内核记录 vCPU 写，QEMU DMA/unmap 路径报告设备写，listener 切换 log 状态。若某条优化路径绕过记录，迁移目标会恢复旧内容，错误可能很久以后才显现。

脏页粒度通常按目标页组织，设备一次跨页 DMA 要标记完整实际写入范围。只读映射、ROM 与 discard 状态有不同处理。开启 dirty logging 还可能降低性能，迁移在不同阶段调整策略，并与硬件脏日志能力协作。

MemoryRegion 本身不保存整份迁移数据，它提供区域与日志接口；RAMBlock 身份和位图关联实际内容，设备 VMState 保存寄存器与队列。三类状态在目标端重新组合，正好对应“地址响应、存储内容、设备协议”三个抽象。

## MMIO 的端序、宽度与副作用必须明确

RISC-V 客户机通常按小端访问 `virt` 设备，但 MemoryRegionOps 仍要声明设备端序，memory API 负责必要转换。寄存器允许 1/2/4/8 字节中的哪些宽度、是否对齐、跨界如何处理，都应来自设备规范。使用 `ldl_le_p()` 等宿主辅助不能替代 ops 契约。

读操作也可能有副作用，例如读取状态清除中断、弹出 FIFO；拆成多个小访问会重复副作用。写合并、byte enable 与原子寄存器同样敏感。设备应限制 `.valid` 和 `.impl`，必要时在回调检查 offset/size 并返回错误。为了让某个操作系统驱动碰巧工作而宽松接受所有宽度，会扩大未测试行为。

并发访问还要遵守设备锁。两个 hart 可以同时 MMIO，DMA 也可能重入；MemoryRegion 分派只找到回调，不替每个设备串行。传统设备依赖 BQL，无 BQL 路径使用内部锁或事件域。第三章的重入 guard 正是在 MMIO/DMA 边界保护部分危险嵌套。

## Eventfd 与 coalesced MMIO 是热路径旁路

某些简单 doorbell 写可以注册 ioeventfd，让 KVM 在匹配地址和值时直接通知后端，减少 vCPU 退出到 QEMU；coalesced MMIO 则允许内核暂存一批写，用户态稍后处理。MemoryListener 负责把这些匹配随拓扑交给加速器。优化改变了回调时点，却必须保持客户机可见语义。

并非所有寄存器适合旁路。写操作若需要立即返回设备错误、与相邻寄存器严格排序或触发复杂 QEMU 状态，就不能简单交给 eventfd。匹配宽度、端序、datamatch 和 region 生命周期都要准确，撤销 region 时先从 KVM 删除监听，避免通知落到已释放后端。

性能收益来自减少 exit 与批处理，代价是观察和迁移更复杂。设备 trace 若只放在普通 write 回调，启用 ioeventfd 后会看不到请求；实验要查询加速路径或在后端通知处补观测。不能把“回调没调用”直接判断成客户机未写。

## 从 AddressSpace 到 FlatView 的历史演进

2017 年提交 [`166206845f7f`](https://gitlab.com/qemu-project/qemu/-/commit/166206845f7f) 让 memory 代码更明确地从 AddressSpace 使用 FlatView，对应 Message-ID [`20170921085110.25598-7-aik@ozlabs.ru`](https://lore.kernel.org/qemu-devel/20170921085110.25598-7-aik%40ozlabs.ru/)。提交说明强调 FlatView 可在多个 AddressSpace 间共享，并声明该步不改变行为。它说明 FlatView 不只是一个新名字，而是把视图快照从观察者身份中抽出。

结合此前 RCU 提交，可以看到热路径逐渐从“持锁读取当前映射”转向“发布并共享不可变视图”。当前代码中的 refcount、RCU 和 listener 顺序，是多轮演进叠加的结果。不能从最终结构反推每一步都为同一性能问题，引用时分别保留各提交明确陈述。

历史研究还应检查后续修复。共享 FlatView 会带来引用与销毁条件，IOMMU 和 eventfd 又扩展 listener 事件；一个 2017 年“无行为变化”的补丁不代表 2026 年所有消费者都与当时相同。最终事实仍以 `v11.1.0-rc0` 的 `memory.c`、`physmem.c` 和 listener 实现为准。

## 实验二：验证重叠、alias 与 enable 切换

::: {.hands-on}
实验框架见英文手册 [Test overlap and alias resolution](../experiments/part-01-system-foundations/chapter-05-address-spaces/test-overlap-alias-resolution/README.md)。在独立教学设备或 qtest 场景中建立一个低优先级 RAM/IO region、一个局部高优先级覆盖和一个指向目标子范围的 alias。中文报告先预测每个地址由谁响应，再用读写和 `info mtree -f` 验证；随后在 memory transaction 中切换高优先级 region 的 enabled 状态。

每次访问记录绝对客户机物理地址、命中的 FlatRange、设备局部 offset 和读写结果。验证 alias 两个窗口共享状态，覆盖只影响交集，禁用高层后低层重新出现。仓库中的 `region_model.py` 已提供这些最小语义与单元测试；它是用于推翻假设的概念模型，不代替固定 QEMU 版本的 `info mtree` 和源码核对。增加一个边界访问，检查跨 region 或非法宽度怎样处理，再把命令与真实输出写入报告。
:::

这个实验有意不先加入 IOMMU。先把 MemoryRegion 渲染与分派验证清楚，再在后续章节给 DMA 加翻译；否则一次地址不一致可能来自 alias、priority、CPU MMU 或 IOMMU 中任意一层。好的实验会减少变量，而不是为了显得完整同时打开所有功能。

## 动态思考题

:::: {.quick-quiz}
FlatView 中看不到某个 container 名称，能否说明该 container 没有参与地址布局？

::: {.quick-answer}
不能。container 用于组织和裁剪子区域，扁平化后通常只留下能响应访问的 FlatRange。它的 offset、大小和 priority 已经影响最终区间，即使名字不作为叶子出现。应把配置树与 FlatView 并排查看。
:::
::::

:::: {.quick-quiz}
KVM 已把 DRAM 注册为内核 memory slot，QEMU 的 MemoryRegion tree 是否可以在运行中任意移动这段 RAM？

::: {.quick-answer}
不能任意移动。拓扑 transaction 会通过 KVM MemoryListener 更新 slots，还要协调 vCPU、脏页、迁移、DMA 和客户机平台 ABI。即使 API 能删除再添加 region，运行期是否允许取决于热插拔协议和所有消费者的生命周期。
:::
::::

:::: {.quick-quiz}
IOMMU translation 返回一段 RAM 后，设备是否可以永久缓存宿主指针？

::: {.quick-answer}
不可以无条件永久保存。客户机可修改映射与权限，IOMMU 会失效缓存，RAM 也可能热拔除或迁移。后端若缓存，需要注册 notifier、维护 pin/引用并响应失效；普通设备应使用 DMA/address-space API 管理映射寿命。
:::
::::

:::: {.quick-quiz}
为什么 RAMBlock 的宿主地址不能用来解释客户机设备树中的 `reg`？

::: {.quick-answer}
RAMBlock 的 host pointer 是 QEMU 进程地址，设备树 `reg` 是客户机物理地址与长度。二者通过 RAM MemoryRegion 映射关联，数值没有相等要求。迁移还依赖 RAMBlock id，而客户机发现依赖平台地址，属于不同身份。
:::
::::

## 读 `info mtree` 时先认根，再认区间

mtree 输出可能同时列出多个 AddressSpace、MemoryRegion tree、FlatView 与 owner 信息。第一步确认正在看 `memory`、`I/O` 还是设备专用 AddressSpace；第二步确认每行地址是绝对范围还是相对父容器；第三步再看 region 类型、priority、只读与 enabled。跳过根名称，很容易把 PCIe I/O port 和系统物理内存的相同数值混在一起。

树形缩进展示配置层次，`-f` 的 flat 输出展示最终响应。一个 RAM region 在树中连续，FlatView 里可能被多个高优先级窗口切开；alias 在树中有自己的窗口，flat range 则指向目标 region 和偏移。报告若要解释一次访问，应引用 flat 结果；若要解释为何形成该结果，再回到树、add_subregion 调用和 priority。

owner 列能把 region 关联到 QOM 对象，却不一定直接给出 qdev bus。无 owner 的容器也可能是全局框架创建，不表示内存泄漏。地址树只展示已经 commit 的当前视图，transaction 中尚未发布的中间状态不会稳定出现，这正是批处理的一致性效果。

## PCIe BAR 展示“设备局部地址”如何得到平台地址

PCIe 设备定义 BAR region 时，只描述 BAR 内部大小与回调。客户机固件或操作系统向 PCI 配置空间写 BAR，PCI 核心根据分配结果把 region 映入桥窗口；`virt` 的 ECAM 让客户机配置设备，PCIe MMIO window 则为 BAR 提供平台范围。设备模型无需把 `0x40000000` 一类 Machine 常量写进寄存器实现。

BAR 被重新编程时，旧映射要移除、新映射在 transaction 中建立，KVM/vhost listener 同步变化。设备仍是同一个 QOM 对象，RAMBlock 或寄存器状态也没复制，变的是 AddressSpace 中的窗口。调试驱动无法访问 BAR，要同时检查配置空间值、桥窗口、mtree FlatView 与设备 ops。

64 位 BAR、prefetchable 属性与 bridge 窗口会影响分配位置，不能只把低 32 位当完整地址。客户机写非法或未对齐值时，PCI core 按规范掩码。一次 BAR 实验能够直观看到“设备局部 region—总线资源—Machine 平台窗口”三层，而 RISC-V 只决定这里使用 `virt` 的 PCIe 主桥布局。

## KVM memory slot 是 FlatView 的一个消费者

KVM 需要知道哪些客户机物理范围可直接映射到宿主 RAM，以及相应 userspace address、只读和 dirty-log 属性。MemoryListener 把 FlatRange 变化转换成 memory slot 更新。slot 数量、对齐和重叠受 KVM API 限制，所以一张过度碎片化的 FlatView可能消耗更多 slot，Machine 布局会影响加速器资源。

MMIO region不会作为普通 RAM slot交给内核，客户机访问时产生 KVM exit；只读 ROM或特殊 RAM属性可能使用不同 flags。新增 alias 若指向同一 RAM，是否需要额外 slot取决于最终范围和 KVM 后端处理，不能从 MemoryRegion 类型直接猜。查看 `/proc` 也看不到完整客户机语义，应把 KVM ioctl trace 与 mtree 对照。

更新 slot 前要让正在运行的 vCPU 不会使用过期映射，KVM API 与 QEMU listener/锁共同建立条件。内存热插拔或删除不是普通指针替换，它会影响内核页表、脏日志和在途 DMA。即使 TCG 路径能接受某种动态修改，KVM consumer 的约束也可能让通用 API 拒绝。

## 内存热插拔把对象、RAMBlock 与地址图同时改变

热插拔内存通常先创建 memory-backend Object，设备或平台对象引用后端，realize 建立 RAM MemoryRegion/RAMBlock，再按热插拔协议映到系统 AddressSpace 并通知客户机。三层分别管理宿主资源、客户机设备语义和地址响应。只添加一个 subregion，客户机固件未获通知，操作系统不会安全使用它。

拔除更严格。客户机先把页迁走并确认，QEMU 阻止新访问，收束 DMA 和迁移引用，撤销 KVM slot 与 region，最后释放 RAMBlock/后端。任何持久 map、vhost 内存表或 IOMMU cache 都可能延长过程。引用计数能防止立即释放，却不能证明客户机已不再访问。

RISC-V `virt` 当前具体内存热插拔能力要以 Machine 与 ACPI/DT 支持为准，本章不从通用 memory API 推断功能已经开放。这里使用它作为边界练习：如果未来平台接入，必须同时满足对象生命周期、客户机发现、FlatView/listener 和迁移，而不是调用一个 add_subregion 就完成。

## H 扩展与 IOMMU 是两条不同的二阶段转换

RISC-V H 扩展允许 hypervisor 使用 VS-stage 与 G-stage 组合翻译客户机 CPU 访存，目标是隔离虚拟 CPU 执行的地址。RISC-V IOMMU 面向设备 DMA，根据 device context 和 I/O 页表转换请求。二者都可能出现“两阶段”字样，却有不同发起者、寄存器、缓存、fault 和失效协议。

在 TCG 模拟带 H 扩展的 CPU 时，CPU MMU 路径实现 `vsatp`/`hgatp` 等语义；IOMMU 设备模型独立读取客户机内存中的表。KVM 则可能由硬件/内核执行 CPU 两阶段转换，QEMU IOMMU 或内核/直通路径处理 DMA。最终都要落入宿主为该 VM 准备的物理内存，但不能共享一份 TLB 就宣称语义相同。

虚拟机内再运行 hypervisor 时，命名尤其要严谨。最内层软件的 guest physical，经 H 扩展 G-stage 得到外层客户机物理，QEMU 又把它解释为 `virt` AddressSpace；设备 DMA 可能另经虚拟 IOMMU。实验日志应标 VS-VA、GPA、QEMU guest-physical 和 IOVA，避免连续三个“物理地址”互相替代。

## 未映射访问与 IOMMU fault 也属于机器语义

访问没有任何 FlatRange 响应的地址时，memory API 使用未分配区域或按调用路径返回错误/默认值，CPU 再形成体系结构可见异常或平台行为。设备 MMIO 回调也可以对非法 offset 返回 `MEMTX_ERROR`。不能用宿主 segmentation fault 表示客户机总线错误，那会把隔离边界打穿。

IOMMU 翻译失败要生成符合 RISC-V IOMMU 规范的 fault 记录，包含原因、requester 与地址，并按配置通知软件。直接返回全零数据会让设备继续运行在错误状态，直接终止 QEMU 又给不可信客户机拒绝服务能力。错误路径和成功翻译同样是设备模型的一部分。

fault 队列本身也通过客户机内存访问，必须防止递归 fault、无效指针和队列溢出。IOTLB 不能缓存一次失败为永久结论，客户机修复页表并 invalidation 后应重新翻译。测试只覆盖恒等映射，会错过 IOMMU 最关键的隔离语义。

## 访问原子性不能由宿主 C 类型大小推断

客户机执行一条自然对齐的 64 位 store，经过 MMU 和 memory API 后，目标可能是 RAM、只支持 32 位的 MMIO，或跨越两个 region。RAM 路径还受宿主原子能力与锁约束，设备路径按 ops 拆分。客户机 ISA 对普通 load/store 的原子保证、设备规范对寄存器宽度的要求和宿主实现能力必须同时满足。

RISC-V AMO/LR-SC 对 RAM 有专门执行语义，不能通过普通 MMIO read 后 write 模拟出对其他 hart 原子。设备若定义原子 doorbell，需要明确支持的访问与锁。跨 region 访问通常无法提供整体回滚，平台应通过对齐、宽度限制或异常避免把不可原子的组合暴露成看似成功。

宿主字节序也不能决定客户机结果。MemoryRegionOps 声明端序，RAM 保存客户机字节序列，TCG/KVM 与 helper 做必要转换。直接把 MMIO buffer cast 成宿主 `uint64_t *`，会同时引入未对齐、端序和别名问题。使用 QEMU 提供的 load/store helper，意图和行为才可审查。

## 零拷贝是一项带期限的借用

为了减少复制，块、网络或设备后端会把客户机 RAM 映射成 iovec，让宿主 I/O 直接读写。性能收益来自省掉中间缓冲，代价是这段内存在请求完成前不能被拔除、重映射或释放，写入还要进入 dirty tracking。一次 map 应看作有明确完成点的借用，而非取出永久指针。

请求跨多个 FlatRange 时会得到多个 iovec，后端必须处理短映射和部分完成。若中途遇到 MMIO 或不可映射区域，不能把设备回调地址伪装成 RAM。取消 I/O 后也要等内核不再使用 buffer 才 unmap，异步取消返回不一定表示系统调用已经停止触碰内存。

IOMMU invalidation 与长期 pin 之间会产生权衡。完全允许设备固定页可提高性能，却可能阻止客户机撤销映射；每次重新翻译更安全灵活，开销更高。VFIO、vhost 等后端各有协议，正文分析时会引用具体接口，不把“零拷贝”写成统一实现。

## 内存拓扑也是安全审查表

客户机控制的地址、长度和 requester 进入 DMA helper 前，要检查加法溢出、跨页和权限；MemoryRegionOps 要检查 offset/size；alias 与 overlap 要避免把受保护 RAM 意外暴露；IOMMU 要在缓存命中时仍执行正确权限。地址代码中的一个整数类型错误，可能把设备访问从目标 buffer 推到 QEMU 其他内存。

第三章的 DMA 重入问题在这里有完整路径：设备 MMIO write 触发 DMA，DMA 地址翻译后命中另一 MMIO region，内层回调重新进入设备。MemoryRegion 图允许这种连接，安全性由设备状态机与 reentrancy guard共同保证。不能因为地址分派正确就假定调用顺序安全。

调试安全问题时保留完整坐标和来源。写清客户机给出的 IOVA、IOMMU 输出、AddressSpace/FlatRange、region 局部 offset、回调 size 与对象状态。模糊成“坏地址访问设备”会遗漏可利用条件，也无法设计覆盖边界的回归测试。

## 用 qtest 把地址规则变成可重复断言

qtest 可以在不启动完整操作系统的情况下创建 `virt`，对客户机物理地址读写并查询状态，适合验证 MMIO 宽度、reset value、alias 和 overlap。测试应从板级公开地址或查询结果获得位置，避免复制一份与 `virt_memmap[]` 独立漂移的魔数；若 ABI 本来就要求固定地址，明确写注释和来源。

内存 transaction 测试可以先读低优先级区域，启用覆盖后再读，禁用后确认恢复，并检查 listener 只看到一次成组 commit。RCU 并发测试需要更新与读者并行，验证不崩溃和结果只属于旧/新完整视图，不能仅循环单线程 add/del。

IOMMU 测试至少覆盖成功读写、权限错误、无效 PTE、失效后重翻译和跨页请求。与完整 Linux 驱动测试相比，qtest 更容易精确构造 fault；系统测试再证明固件/内核发现与驱动路径。两层测试互补，前者定位协议，后者验证集成。

## 从现象回到内存代码的固定路线

客户机访问失败时，先确认发起者和地址层：CPU 虚拟地址、CPU 最终物理地址，还是设备 IOVA。然后在 DTB/PCI 配置确认客户机认为设备在哪里，用 `info mtree -f` 找 FlatRange，回到 `virt_machine_init()` 或总线映射点，再定位 MemoryRegionOps。若启用 KVM、IOMMU 或 ioeventfd，补上对应 listener/退出/旁路。

数据损坏而非访问失败时，再检查宽度、端序、拆分、并发与 dirty tracking。只在迁移后出现，重点看 RAMBlock id、VMState 与脏页；只在热拔除出现，重点看 map/RCU/后端引用；只在 KVM 出现，比较 memory slot 与 MMIO exit。症状差分能把巨大内存子系统切成几段。

历史证据最后加入解释。FlatView/RCU 提交说明读侧扩展问题，listener 历史说明多后端消费，RISC-V IOMMU 系列说明规范与平台接入。当前代码确认机制仍在，实验确认本次配置走过。三者对齐后，才能写“为什么今天这样设计”，而不是把一个函数名包装成动机。

## 本章证据边界

可直接核对的事实包括 `virt_memmap[]` 数值、当前函数与数据结构、mtree/DTB 输出、提交 diff 和 RISC-V IOMMU 规范。上游明确陈述包括 RCU 提交提到的 futex contention、FlatView 提交声明的共享与无行为变化、IOMMU 系列对规范版本与功能的说明。它们应带固定 commit 或 Message-ID。

作者推断负责解释取舍：不可变 FlatView 用写侧复杂度换读侧扩展，listener 用通知协议换 Machine 与加速器解耦，hart/设备共用 AddressSpace 让平台契约集中。推断要列出代价和替代方案，若邮件未说“为了迁移”，就不能因为 listener 后来被迁移使用而替早期作者补动机。

实验结果是第四类局部证据。一次 `info mtree` 证明本次配置视图，不能证明所有属性组合；一次 alias 读写证明共享目标，不能证明所有并发安全。写清适用范围，结果就能与后续 tag 对比，而不会因一项默认变化整章失效。

## 客户机页、宿主页与迁移页不是同一个单位

RISC-V 页表可以选择规范允许的页大小，客户机虚拟页经 MMU 映到客户机物理；QEMU RAMBlock 按目标/宿主相关 page 组织脏位图和映射，宿主内核又可能用 4 KiB、hugepage 或文件后备。三个“页”服务地址转换、存储管理和迁移，大小与生命周期都可能不同。

使用 hugepage 能减少宿主 TLB 压力，却会影响内存分配、pin、NUMA 和迁移粒度；客户机使用大页不要求宿主一定采用相同大页，KVM 会在两层页表中组合。性能分析若只看到客户机 `satp` 页大小，就推断 RAMBlock 或 dirty bitmap 粒度，容易得出错误结论。

边界请求还会跨越这些单位。DMA 长度可跨多个 IOMMU 页和 RAMBlock FlatRange，迁移脏位图把实际写入映射到自己的 page，后端 iovec 又受宿主页连续性限制。实现必须循环处理每段，测试也应故意把起点放在页尾，而不是永远使用对齐缓冲。

## Memory backend 决定 RAM 从哪里来，Machine 决定放到哪里

匿名 RAM、file-backed memory、memfd 与 NUMA 绑定等宿主策略通常由 memory-backend Object 表达。Machine 引用后端，创建或取得其 RAM MemoryRegion，再映到 `virt` DRAM 范围。用户可以改变宿主分配位置与共享属性，而客户机仍从 `0x80000000` 一类平台地址看见内存。

后端属性往往必须在分配/realize 前确定。大小、share、prealloc、host-nodes 和 policy 改变后备方式，运行中修改需要搬迁实际内存，普通 setter 无法完成。QOM 负责配置与生命周期，MemoryRegion/RAMBlock 负责映射和内容，Machine 负责客户机拓扑，三章的对象边界在这里会合。

NUMA 配置还影响 CPU 与内存距离，却不改变基本 AddressSpace 查找。性能实验要保存宿主绑定和客户机 NUMA 描述；功能实验只研究 MMIO 分派时，应使用简单后端减少变量。把后端选择写进完整命令，能避免两次运行因 hugepage 或 prealloc 差异被误判为 FlatView 性能变化。

## 缓存一致性在真实硬件与设备模拟之间交接

普通 QEMU RAM 由宿主 CPU 访问时，宿主硬件维护其缓存一致性；客户机看到的内存序仍由 RISC-V ISA、执行后端与设备协议共同实现。真实直通设备 DMA 可能涉及 IOMMU、pin 和平台 DMA coherency，纯软件设备则由 QEMU 线程读写同一宿主内存。不能用一句“内存是共享的”省略屏障与缓存属性。

virtio 等共享队列规定驱动与设备的发布顺序，MemoryRegion 只帮助找到 RAM，不保证描述符已经初始化。设备后端读取前仍需协议要求的 barrier，写完成后再更新 used ring 并注入中断。KVM/TCG 要保存客户机 fence 语义，宿主线程间还需 qatomic 顺序，正好对应第三章的双层 happens-before。

非一致 DMA 或直通细节取决于宿主与设备，QEMU 可能通过 VFIO 等接口委托同步。本书在 `virt` 软件设备示例中不假定某块真实平台的 cache-maintenance 指令，却会在讨论直通时单独核对接口。平台模型、宿主实现和客户机驱动三者都明确后，才能判断是否需要显式同步。

## 地址拓扑的修改也需要生命周期顺序

删除一个 subregion 后，新读者不会再从新 FlatView 找到它，旧 RCU 读者却可能继续使用旧 view；listener 还要撤销 KVM slot、eventfd 或后端映射，设备回调也可能在另一线程执行。因此正确顺序通常是停止新业务、收束在途请求、提交拓扑删除、等待相关读者/通知完成，再释放 owner 对象与 RAM 后备。

反向创建时，先准备完整对象和回调，再在 transaction 中发布 region，最后允许客户机或后端发起访问。若 region 已经可见而 ops opaque 尚未初始化，另一个 vCPU 能立即命中半成品。QOM realize、BQL/设备锁、memory transaction 和 RCU 各自承担一段，缺一项都会留下窗口。

这条顺序也是审查 MemoryRegion owner 的方法。owner 引用帮助 region 活到不再映射，却不自动停止事件；RCU 等旧视图消失，却不自动取消 DMA；listener 删除通知后端，却不决定客户机是否已同意热拔除。每个机制只解决自己的生命周期问题，组合后才形成安全拓扑变更。

:::: {.quick-quiz}
`memory_region_del_subregion()` 返回后，能否立即释放其 MMIO 回调使用的设备对象？

::: {.quick-answer}
不能只凭该返回值判断。还要保证没有在途回调或 DMA，旧 FlatView 的 RCU 读者已退出，listener/加速后端不再引用映射，并按 qdev 生命周期取消 timer、BH 与工作线程。拓扑不可见只是释放条件之一。
:::
::::

## 小结

MemoryRegion tree 适合表达组合，FlatView 适合执行，AddressSpace 提供观察地址的视角。CPU 与设备的路径不同，最终共享同一套物理访问边界。

沿 RISC-V `virt` 主线，一次 CPU load/store 从客户机虚拟地址经过 MMU，TCG 或 KVM 把最终客户机物理地址交给平台；一次设备 DMA 从 IOVA 出发，可经 RISC-V IOMMU，再进入设备所属 AddressSpace。FlatView 把 overlap、alias 与 enable 计算成稳定区间，RAMBlock提供宿主后备，MemoryRegionOps 处理 MMIO，listener 又把同一视图同步给 KVM、vhost、迁移和其他消费者。

排查地址问题时，先写发起者和地址层，再找 AddressSpace root、FlatRange、region 局部 offset 与 owner。修改拓扑时，先准备完整对象，成组发布，停止旧访问，等待 RCU/listener/异步引用收束后再释放。性能优化若绕过普通回调，还要重新接上脏页、失效、迁移和观测；少一次复制或 exit 只是收益的一面。

本章两个实验会生成 `virt` 基线内存图和一组可控的 overlap/alias 结果。后续分析设备、中断、virtio、PCIe 与 IOMMU 时，都应回到这两份材料，只添加当前主题需要的转换层。这样，地址不会随着章节增多重新变成一个没有坐标的十六进制数。

章末复核任选一次访问，完整写出虚拟地址、页表阶段、最终客户机物理地址、AddressSpace、FlatRange、MemoryRegion、局部 offset 与回调或 RAMBlock。DMA 再补 requester 和 IOMMU。任何一格缺失，都表示结论尚不能闭环，应该回到 trace、mtree 或固定源码补证据。

复核时同时注明 TCG 或 KVM、拓扑是否处于 transaction 后、IOMMU 是否启用。三个条件会改变路径，却不改变地址坐标必须完整这一要求。原始 mtree、DTB 与访问 trace 应随实验报告一并留存，复现实验时再逐项比对。

书中后续出现地址时统一带前缀说明，例如 GVA、VS-stage GPA、QEMU guest-physical、IOVA 或 host virtual；区间统一写成左闭右开，并在加法前检查宽度。符号多几个字符，却能避免把不同层的同一数值误认成同一对象，也方便把 trace 与 mtree 自动对照。
