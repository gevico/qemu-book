# 内存为什么不能只是一根指针

RISC-V `virt` 的 UART 位于客户机物理地址 `0x10000000`。客户机执行一次 store，QEMU 最终调用 UART 的寄存器回调。DRAM 从 `0x80000000` 开始，另一条 store 则可能落到宿主分配的一页 RAM。两条指令都写“内存”，一条产生设备副作用，一条改变可迁移的字节；地址还可能先经过 CPU 页表、IOMMU、PCIe bridge 或 alias。

如果把客户机地址直接当成 QEMU 进程指针，第一步就会丢掉这些差别。宿主虚拟地址属于 QEMU 进程，客户机物理地址属于虚拟平台，两者没有数值上的对应关系。更麻烦的是，设备窗口可以移动、重叠和禁用，RAM 可以热插拔，KVM 和 vhost 还需要在拓扑变化时同步自己的映射。

QEMU 的 MemoryRegion、AddressSpace 与 FlatView 源于一个基本要求：先描述“谁响应哪段地址”，再让 CPU、DMA、加速器和后端从各自视角消费同一张平台图。

## 一次访问先要回答四个问题

第一个问题是地址处在哪套坐标。RISC-V load/store 给出客户机虚拟地址，MMU 根据特权级、`satp`，以及可能的 `vsatp`/`hgatp` 完成转换，得到客户机物理地址。QEMU 再用某个 AddressSpace 查找响应者；命中 RAM 后才得到可访问的宿主地址。设备 DMA 从 IOVA 或总线地址出发，若启用 IOMMU，还会走另一套页表。

第二个问题是发起者。CPU、PCIe 设备、平台设备和直通后端可能看到不同 AddressSpace，`MemTxAttrs` 还携带 requester 与安全属性。设备代码若总是绕到全局 `address_space_memory`，可能跳过 IOMMU 和总线限制。

第三个问题是访问语义。RAM 支持普通字节存储与脏页跟踪；ROM 对客户机写入有限制；MMIO 调用 `MemoryRegionOps`，宽度、端序、读写副作用都由设备定义；IOMMU region 返回翻译与权限。相同数值地址在不同视图中可能得到不同结果。

第四个问题是当前拓扑版本。一个热插拔事务正在添加窗口时，vCPU 不能看见半张新图；旧读者也不能在更新瞬间拿到已经释放的 region。配置层需要成组发布，热路径需要稳定快照。

:::: {.quick-quiz}
GDB 显示客户机 RISC-V 指令访问 `0xffffffc080100000`，为什么不能直接在 `virt_memmap[]` 中查这个数？

::: {.quick-answer}
该数通常是客户机虚拟地址，`virt_memmap[]` 描述客户机物理平台。要先结合当前页表与特权级完成 RISC-V 地址转换，再用得到的客户机物理地址查 AddressSpace。宿主指针还属于第三套坐标。
:::
::::

## 2011 年的转折：把属性与位置拆开

早期 QEMU 的物理映射接口围绕全局注册和 I/O 索引增长，设备、KVM 与内存管理逐渐共享一套难以组合的表。Avi Kivity 在 2011 年提交 [`093bc2cd`](https://gitlab.com/qemu-project/qemu/-/commit/093bc2cd885e4e3420509a80a1b9e81848e4b8fe)，引入分层 MemoryRegion API。提交说明给出的设计非常具体：region 的大小、读写处理、dirty logging 与 coalescing 同映射位置、enabled 状态分开；设备可以先配置一次 region，再交给父总线按总线规则映射；一个 region 还可以由 RAM 与 MMIO 等子区域组合。Anthony Liguori review 并合入这项改动。

同一系列中的 [`4ef4db86`](https://gitlab.com/qemu-project/qemu/-/commit/4ef4db860362ce9852c20b343e9813897ecdefce) 增加 transaction，让多项拓扑变化一次可见，并明确提到 KVM 参与时可以减少重复计算。数月后的 [`7664e80c`](https://gitlab.com/qemu-project/qemu/-/commit/7664e80c84700d8b7e88ae854d1d74806c63f013) 加入观察物理图变化的 API，后来发展为 MemoryListener。三个提交解释了今天 API 的基本形状：设备描述局部响应，Machine 和 bus 决定位置，更新成组发布，外部消费者通过监听获得同一变化。

历史到这里已经回答“为何需要这层抽象”。下面直接沿当前 RISC-V `virt` 走一次访问。

## 从 `virt_memmap[]` 到设备局部寄存器

[`hw/riscv/virt.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/virt.c) 的 `virt_memmap[]` 给 UART、RTC、中断控制器、virtio、PCIe 与 DRAM 分配平台范围。Machine 创建 UART 时，设备先初始化一段带 `MemoryRegionOps` 的局部 region；板级代码再把它放到 system memory container 的 `0x10000000`。设备回调最终收到的是 region 内 offset，例如 UART 寄存器 `0x0`，无需知道 Machine 把窗口放在什么绝对地址。

这项分工使设备能够复用。NS16550A 模型可以放到另一块 RISC-V Machine 的不同地址，也能挂在其他架构平台；Machine 只设置映射和 IRQ，寄存器读写留在设备。PCIe BAR 更能说明问题：设备声明 BAR 大小与局部操作，客户机配置 BAR 后，PCI core 通过 bridge window 把它映入平台 PCIe MMIO 范围。设备实现不应硬编码 `virt` 的窗口基址。

在 [`system/memory.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/system/memory.c) 中，MemoryRegion tree 保存 container、subregion、overlap、priority、alias 与 enabled。container 把局部图组合起来，alias 把另一个 region 的一段映射到新窗口而不复制数据，高 priority region 可以在交集上遮住低优先级区域。QOM child 表示谁拥有 region 对象，MemoryRegion parent 表示地址组合，两条关系仍要分开。

:::: {.quick-quiz}
一个 alias region 指向 DRAM 的 4 KiB 范围，迁移时是否需要为 alias 再保存一份 4 KiB 内容？

::: {.quick-answer}
alias 只建立另一条地址路径，目标仍是同一份 RAM 与 RAMBlock。迁移保存目标内容一次；alias 的平台配置决定恢复后从哪个窗口可见。若把内容复制，会让两个窗口失去共享语义。
:::
::::

## FlatView 为什么出现在热路径

层次图适合装配，却不适合每次访问都递归解析。container、alias、disabled region 和 overlap 会让一次查找经过多层判断。QEMU 在拓扑提交时调用 `generate_memory_topology()`，把可见叶子渲染为按地址排列、互不重叠的 FlatRange，并建立 dispatch 结构。一个大的 RAM region若被几个 MMIO 窗口覆盖，会在 FlatView 中被切成多段。

`AddressSpace` 给这张图选一个 root。系统内存、I/O port、设备 DMA 与 IOMMU 后端可以持有不同视角。访问方在 FlatView 中找到 range，计算 region 局部 offset，再直达 RAM 或调用设备 ops。[`system/physmem.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/system/physmem.c) 承担大量物理访问、map 与 RAMBlock 处理。

FlatView 还让配置成本与执行成本分离。Machine 初始化和热插拔可以付出渲染、比较与 listener 通知的成本，频繁访存则使用已经计算好的结果。代价是写侧复杂：每次 topology 变化要产生完整一致的新视图，旧视图还要活到所有读者离开。

2015 年合入的 [`374f2981`](https://gitlab.com/qemu-project/qemu/-/commit/374f2981d1f10bc4307f250f24b2a7ddb9b14be0) 用 RCU 保护 `current_map`，Paolo Bonzini 在提交说明中直接指出，大型系统和许多 IOThread 会在旧 `flat_view_mutex` 上产生 futex 争用，Fam Zheng 给出 `Reviewed-by`。当前读者在 RCU 临界区使用旧 FlatView，更新方发布新指针，grace period 后再回收旧视图。RCU 解决读侧存活，不会自动取消设备 timer 或在途 DMA，设备 teardown 仍需自己的生命周期协议。

:::: {.quick-quiz}
`memory_region_del_subregion()` 已返回，为什么设备对象仍可能不能立即释放？

::: {.quick-answer}
新 FlatView 不再包含它，但旧 RCU 读者、正在执行的 MMIO 回调、DMA map、MemoryListener 消费者或异步后端可能仍持有引用。拓扑不可见只是释放条件之一，还要收束业务和对象生命周期。
:::
::::

## Transaction 与 listener 处理“整张图同时改变”

设备的一个寄存器写入可能关闭旧窗口、启用新窗口并移动 alias。若每一步立即发布，其他 vCPU 会短暂看到两个窗口同时存在，或者两边都不存在。`memory_region_transaction_begin()` 与 `commit()` 允许调用者累积变化，在最外层 commit 时生成并发布一次拓扑。

这项原子性只覆盖 memory API 的图。设备若同时更新 IRQ、QOM 属性或客户机发现表，调用者仍要用 BQL、设备锁或暂停协议保证跨子系统关系。transaction 也不提供数据库式的通用回滚；listener 已经向 KVM 或 vhost 发出宿主操作后，错误模型取决于具体后端。

MemoryListener 让多个后端观察同一 AddressSpace。KVM listener 把可直接执行的 RAM range 转换为内核 memory slot；vhost 把客户机内存表交给数据面；脏页跟踪和 ioeventfd 也消费 region 变化。Machine 无需为每个 accelerator 写一套“UART 不映射、DRAM 要注册”的分支，FlatView 已经表达最终范围与属性。

listener 也带来限制。KVM slot 数量和对齐有限，过度碎片化的地址图可能耗尽资源；删除 RAM 要先协调 vCPU、dirty log 和后端引用；vhost 获得内存表后，热拔除不能只更新 QEMU 指针。一次拓扑修改要检查所有注册消费者，TCG 下能工作的组合未必满足 KVM 或直通设备约束。

## CPU 与 DMA 在哪里汇合

TCG 执行 RISC-V load/store 时，目标 MMU 与 QEMU TLB 先把客户机虚拟页转换为客户机物理页。RAM 命中可以走宿主指针快路径，MMIO 或异常进入 AddressSpace 分派。KVM 下，硬件和内核完成客户机页表执行，RAM 由 memory slot 支持；未由内核处理的 MMIO 以 exit 回到 QEMU，再进入同一个设备模型。

DMA 从设备所属 AddressSpace 出发。未启用 IOMMU 时，它可能直接到系统内存；启用 RISC-V IOMMU 后，设备地址先经过 device context、I/O 页表与权限检查，翻译结果再指向目标 AddressSpace。CPU 的 H 扩展两阶段转换与 IOMMU 两阶段 DMA转换服务不同发起者，寄存器、缓存与 fault 协议也不同，不能因为都出现“二阶段”就共用一份解释。

两条路径在物理响应层汇合：RAM 访问同一 RAMBlock，MMIO 调用同一 MemoryRegionOps。汇合前的地址和权限必须保留，`MemTxAttrs`、requester id 与 `MemTxResult` 才能把上下文带到设备和错误路径。客户机给出非法 offset 时，设备应返回定义好的访问结果或 fault；直接让宿主进程越界崩溃，会破坏虚拟化隔离。

:::: {.quick-quiz}
某 DMA helper 直接使用全局 `address_space_memory` 后功能测试通过，启用 RISC-V IOMMU 时为什么仍可能越权？

::: {.quick-answer}
helper 绕过了设备所属 DMA AddressSpace 和 IOMMU 翻译，测试中的恒等映射掩盖了问题。正确入口要携带设备 requester、权限与目标 AddressSpace，让失效和 fault 协议都能生效。
:::
::::

## RAMBlock 记录内容之外的身份

RAM MemoryRegion 描述一段客户机地址如何响应，RAMBlock 管理对应宿主后备、大小、id、page 与 dirty bitmap 等信息。后备可以来自匿名内存、文件、memfd 或 memory-backend Object；Machine 决定这段存储放在 `virt` DRAM 的哪个客户机物理范围。一个 2 GiB 宿主映射没有携带 `0x80000000` 这个平台基址，两个概念不能合并。

迁移尤其依赖 RAMBlock 身份。源端按 block 与脏页发送内容，目标端要把数据恢复到对应后备；id、大小和迁移配置必须一致。alias 不新建 block，多个地址窗口仍指向同一内容。热插拔则同时创建后端 Object、RAMBlock、MemoryRegion 和客户机发现状态，拔除时要反向收束 DMA、KVM slot、迁移读者与宿主映射。

dirty tracking 说明一次普通 store 也有平台之外的消费者。CPU、vhost 或外部设备写入 RAM 后，迁移需要知道哪些页变化；KVM 可以在内核维护 dirty log，TCG 和其他后端走各自标记路径。绕过正规 map/write helper 取得裸指针，可能让内容更新成功、脏页却没有记录，故障只会在增量迁移后出现。

页的含义也不止一种。RISC-V 页表页、宿主内核页、hugepage 和迁移 dirty bitmap 粒度可以不同。客户机使用 Sv39 的 4 KiB 页，不要求宿主后备一定按 4 KiB 分配；DMA 请求还可能跨越 IOMMU 页和多个 FlatRange。代码要按每次实际可映射长度循环，不能从某一层页大小推导全部边界。

## MMIO 回调必须把访问形状说清

`MemoryRegionOps` 不只提供 read/write 函数，还声明端序、合法访问宽度和实现宽度。客户机一条 64 位 store 命中只支持 32 位的寄存器时，memory core 可能按规则拆分，也可能拒绝。设备寄存器若有 read-to-clear、FIFO 或 doorbell 副作用，两个 32 位访问与一个 64 位访问未必等价，因此模型要准确限制宽度。

设备回调看到的 `addr` 通常是 region 局部 offset。记录 trace 时若要还原客户机物理地址，需要同时保存 FlatRange 基址；直接把 offset 打印成 GPA 会误导调试。端序同样由设备协议决定，不能因为宿主和当前 RISC-V 客户机都是 little-endian 就用 C 指针强转。换到 big-endian 配置、非对齐访问或另一宿主后，偶然一致会消失。

`MemTxResult` 允许错误沿 CPU 或 DMA 调用者返回，却不提供任意多段访问的全局回滚。一次跨 region 访问前半已写、后半失败时，副作用可能已经发生。平台若要求原子性，应通过对齐、宽度约束或专用原子接口保证，不能依赖 memory core 猜测设备规范。

## IOMMU fault 是地址模型的一部分

RISC-V IOMMU 收到 IOVA 后，要根据 requester 选择 device context，检查页表项、权限和队列配置，再返回目标 AddressSpace。翻译失败需要形成规范定义的 fault 记录并通知客户机软件。返回全零会让设备继续在错误地址上运行，直接终止 QEMU 又把客户机输入升级成宿主拒绝服务。

IOTLB 缓存提高热路径速度，也引入失效协议。客户机修改 I/O 页表后，旧翻译不能永久留存；invalidation 还要通知 vhost、VFIO 等可能缓存映射的消费者。长期 pin 一段客户机内存可以减少重翻译，代价是客户机撤销映射和热拔除更难。每个后端都要在性能与可撤销性之间给出明确期限。

fault queue 本身位于客户机内存，写入错误记录时仍可能遇到无效地址、队列溢出或设备 reset。实现要防止递归 fault，并在迁移中保存足够队列状态。只测试恒等映射的 DMA 成功路径，恰好绕开了 IOMMU 最需要保护的隔离边界。

## 一根宿主指针丢掉了什么

宿主指针只表达某段当前可访问的进程虚拟地址。它没有客户机物理基址、region 类型、只读与端序、脏页身份、迁移 id、IOMMU 权限、MemoryListener 订阅或映射有效期。异步后端若长期保存指针，热拔除、FlatView 更新和 RAM 后端更换都会让它失效。

零拷贝路径仍会取得宿主映射，但它是一项带完成点的借用。`address_space_map()` 可能只映射请求的一部分，跨 region 时要拆成多个片段，完成后必须 unmap 并标记写脏。后端取消请求也要确认内核不再触碰 buffer。性能优化减少复制，同时增加 pin、失效、迁移和生命周期责任。

MemoryRegion API也不追求周期精确。普通 MMIO 回调表达寄存器级功能，访问到达时间受 TCG/KVM、主循环和宿主调度影响。需要真实缓存一致性、总线仲裁或周期级模型时，QEMU 的通用系统模拟边界可能不合适。它优化的是可组合机器与高效功能执行。

## 实验：从平台地址走到最终响应者

::: {.hands-on}
运行 [Map memory regions](../experiments/part-01-system-foundations/chapter-05-address-spaces/map-memory-regions/README.md)，保存 `info mtree -f`。从 UART `0x10000000`、DRAM `0x80000000`、一个 virtio-mmio 窗口和 PCIe ECAM 各选一个地址，记录 AddressSpace root、FlatRange、MemoryRegion owner、局部 offset，以及最终进入 RAMBlock 或设备回调。

随后运行 [Test overlap and alias resolution](../experiments/part-01-system-foundations/chapter-05-address-spaces/test-overlap-alias-resolution/README.md)。先独立写出四个测试的预期，再执行 Python ordering model 与上游源码检查。模型只用于验证 priority、enabled 和 alias offset 的推理，不能冒充 QEMU 的完整 FlatView 实现。

报告中的地址统一标注 GVA、GPA/QEMU guest-physical、IOVA 或 HVA，区间统一使用 `[start, end)`。如果某一步只能从源码推断，没有运行 trace，就把证据停在该步；完整坐标比一张看似闭合却混用地址的图更有价值。
:::

## 小结

QEMU 需要表达一张会组合、移动、重叠并被多个后端消费的客户机地址图。MemoryRegion 把响应语义与映射位置分开，AddressSpace 选择视角，FlatView 把层次配置渲染成执行快照，transaction 与 RCU分别保证成组发布和读侧存活，MemoryListener 再把变化交给 KVM、vhost 等消费者。

RISC-V CPU 与设备 DMA 从不同地址转换路径进入这张图，最后在 RAMBlock 或 MemoryRegionOps 汇合。下一章要给每次访问补上时间和执行者：当 vCPU 正在 TCG 生成的宿主代码或 KVM 内核对象中运行时，哪份 CPU 状态最新，谁可以修改它，主循环和其他线程又如何把工作送到安全点。
