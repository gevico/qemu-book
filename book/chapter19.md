# I/O 为什么还要分层

在 RISC-V `virt`上给 Linux 加一块 virtio 磁盘，可以选择 virtio-mmio，也可以把 virtio-blk 放到 PCIe。请求既可以由 QEMU 线程处理，也可能交给内核 vhost 或独立 vhost-user 进程。客户机驱动看到的仍是一组 virtio feature、status、queue 和完成中断；宿主内部已经出现多个执行主体。

分层的价值不只体现在吞吐。它让设备协议、发现方式、存储后端和执行位置分别演进，也迫使系统写清状态所有者。下面以 QEMU `v11.1.0-rc0`、commit `eca2c16212ef9dcb0871de39bb9d1c2efebe76be` 为基线，从 RISC-V `virt`跟踪一笔 virtio-blk 请求，再把 vhost、RISC-V IOMMU 和 VFIO 放回各自边界。

## 先分清 transport、device 与 backend

一条 virtio I/O 路径至少有三个协议层。transport 负责发现、配置寄存器、queue 地址、notify 和中断；device 解释 virtio-blk、virtio-net 等设备类型的 feature 与请求格式；服务 backend 完成块读写、网络收发或其他宿主操作。QEMU 文档有时把整段设备模拟也称为 backend，本章在需要区分时会再写“执行主体”：普通 QEMU handler、内核 vhost 或 vhost-user 进程。

以块请求为例：virtio-mmio/PCI transport 只知道 queue 已被通知；virtio-blk device 才知道描述符里的 type、sector、数据方向和 status 字节；block layer 再决定访问哪个镜像、采用何种缓存和异步 I/O。把三层揉在一个回调里，会让同一块设备难以复用两种 transport，也让数据面迁移到 vhost 时失去清楚接口。

状态责任可以先画成一张表：

| 层 | 主要状态 | 完成条件 |
| --- | --- | --- |
| transport | feature selector、queue 地址、notify、ISR/MSI | 配置与中断符合 transport 规范 |
| virtio device | device feature、status、request 语义、配置空间 | 请求按设备规范成功或返回错误 |
| 服务 backend | 镜像、socket、文件描述符、异步任务 | 宿主操作达到约定的持久性或发送语义 |
| 执行主体 | vring base、eventfd、memory table、in-flight | 能停止、恢复并报告失败 |

## RISC-V `virt` 提供两种 transport

[`hw/riscv/virt.c`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/riscv/virt.c) 创建一组 `virtio-mmio` slot，并在 FDT 中给出 `compatible = "virtio,mmio"`、地址和中断。客户机通过固定 MMIO 寄存器读取 magic、version、device ID 和 feature，配置 queue 后向 notify 寄存器写 queue index。完成中断进入 PLIC 或 APLIC。

同一台 machine 还创建 GPEX PCIe host。`virtio-blk-pci`作为 PCI function 被枚举，transport 配置位于 capability/BAR 中，通知可使用 notify BAR，中断可用 MSI-X。[`hw/virtio/virtio-pci.c`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/virtio/virtio-pci.c) 包装底层 `VirtIODevice`；设备请求格式仍由 virtio-blk 实现。

两种 transport 的差别会进入机器拓扑、FDT/PCI 枚举、中断和迁移状态。实验若从 mmio 改成 PCI，已经改变多个变量。性能比较和故障复现都要固定 transport，不能只写“使用 virtio”。

## Feature 与 status 是启动握手

这一段客户机契约以 [OASIS Virtio 1.3 规范](https://docs.oasis-open.org/virtio/virtio/v1.3/virtio-v1.3.html) 为准；QEMU 源码用于说明规范怎样落到当前实现。规范定义 feature 协商、status、split/packed ring 与内存顺序，不能从某个 QEMU helper 的当前写法反推所有 virtio 实现都必须采用同一内部结构。

driver 先读取 device features，选择自己理解的集合，写入 driver features，再设置 `FEATURES_OK`并回读确认；queue 配置完成后设置 `DRIVER_OK`。设备无法接受组合时应拒绝 `FEATURES_OK`或返回错误，驱动遇到致命问题则设置 `FAILED`。[`virtio_set_status()`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/virtio/virtio.c) 在状态变化时调用设备校验和 `set_status`钩子。

feature 是双方对后续内存布局和语义的承诺。`VIRTIO_F_RING_PACKED`改变 ring 格式，`VIRTIO_F_EVENT_IDX`改变通知抑制，`VIRTIO_F_IOMMU_PLATFORM`要求设备按 DMA/IOMMU 语义解释地址。backend 支持某项能力，也要经过 transport、device 与迁移路径共同确认后才能暴露给 guest。

status 写零表示设备 reset。transport queue、device 协商状态、in-flight 请求和执行主体都要回到未初始化状态。它与 QMP `stop`不同：暂停需要保留协商和 queue，恢复后继续处理。

:::: {.quick-quiz}
宿主 block backend 支持 discard，为什么 QEMU 仍不能无条件向 guest 宣告相应 virtio feature？

::: {.quick-answer}
virtio device 还要验证请求格式、范围和错误转换，transport、reset 与迁移也要保存这项协商状态。宿主能力只覆盖服务 backend 的一层。
:::
::::

## Virtqueue 是一份所有权账本

split ring 包含 descriptor table、available ring 和 used ring。driver 准备 descriptor chain，把 head index放入 available ring；device 取走 head，完成后把同一个 head及写入长度放入 used ring。`VirtQueueElement`将 device-readable 段保存为 `out_sg`，device-writable 段保存为 `in_sg`，同时保留 guest 地址用于 unmap、脏页和错误处理。

所有权变化可以写成一条短时间线：

```text
driver fills data/descriptors -> publishes avail -> device gets chain
-> backend executes -> device writes data/status -> publishes used -> driver reclaims
```

“已经 kick”只表示有新工作提示，“已经 pop”表示 device 持有 chain，“宿主 I/O 返回”还要写 status 和 used，“已经 notify”也不等于 driver 已回收。reset、迁移和错误路径必须知道请求停在哪一段。

packed ring 把 descriptor、available/used 标志放进同一数组，并用 wrap counter区分环的轮次。它减少共享结构访问，却没有减少所有权阶段。目标恢复时需要 index、wrap 与 in-flight 状态，不能扫描旧 flag猜出当前位置。

可以用一个 size 为 8 的 split ring检查索引。假设 device 的 `last_avail_idx`为 5，driver把 head 3写入 `avail.ring[5]`，再把 `avail.idx`推进到 6；head 3可能继续链接 descriptor 6和7。device要先确认索引差没有超过 queue size，整条 chain无环、方向与长度合法，才把它交给设备处理。16位 idx从 `0xffff`回到零时仍按模运算比较，不能把回绕误判成一批六万多条新请求。

:::: {.quick-quiz}
为什么保存 `last_avail_idx`仍不足以迁移一个有异步块请求的 queue？

::: {.quick-answer}
该索引只说明 device 已取得到哪里，无法说明哪些 chain 已提交宿主、哪些已经产生外部副作用、哪些尚未写入 used。还需要设备请求与 backend 的 in-flight 协议。
:::
::::

## DMA 地址和内存顺序决定 ring 是否可信

driver 写完 descriptor 内容后，必须用适合 RISC-V 内存模型的 barrier，再推进 avail index；device 完成时先写返回数据和 used element，再发布 used index。顺序颠倒会让另一方看到“可用”标志，却读到旧内容。通知只能提示对方检查 ring，不能替代共享内存的发布顺序。

QEMU [`hw/virtio/virtio.c`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/virtio/virtio.c) 通过 `vdev->dma_as`映射 descriptor、avail、used 和数据段。未启用 IOMMU 时地址通常落到 guest physical memory；启用 IOMMU platform feature 后，地址可能是 IOVA。`virtqueue_pop()`需要检查 queue size、索引差、chain 长度、循环、indirect table、读写方向、映射长度与溢出。

这些检查是安全边界。guest 控制 ring 中的每个字节，合法映射页里仍可放置恶意 descriptor。IOMMU 负责地址与权限，virtio parser 负责结构与设备协议，两层都不能省略。

## 通知、中断与批处理减少切换

guest 向 host 的通知常叫 kick，host/backend 向 guest 的完成通知常叫 call。split ring 的 flag 或 event index 允许一方抑制不必要的通知；关闭通知、排空、重新开启后还要再次检查 ring，才能关闭 lost wakeup 窗口。多个 descriptor可以批量消费、批量写 used、只发一次中断。

在 KVM 路径中，ioeventfd 可以把 guest 对 notify 地址的写直接转成 eventfd，减少普通 MMIO exit进入 QEMU 主循环的次数；irqfd 可以把完成 eventfd 接到 in-kernel irqchip。fd 只搬运唤醒，queue 地址、feature、request 校验和生命周期仍由上层协议提供。

批处理带来吞吐，也会改变尾延迟。queue 数、event suppression、I/O depth 与中断合并要一起记录。只比较每秒请求数，无法判断延迟增加来自 backend、batch 还是 guest 调度。

## 走完一次 virtio-blk 请求

virtio-blk chain通常包含固定请求头、数据段和一个可写 status 字节。写请求的数据供 device 读取，读请求的数据区由 device 写入。[`hw/block/virtio-blk.c`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/block/virtio-blk.c) 的 queue handler调用 `virtqueue_pop()`，解析 type、sector 和 scatter-gather，再把请求交给 block layer。

block I/O可能同步完成，也可能稍后回调。完成路径先写读数据或错误 status，再把实际写入长度交给 `virtqueue_push()`，最后 `virtio_notify()`。flush、discard、write zeroes各有范围、对齐和持久性要求；它们共用 queue 机制，不共享同一种完成含义。

迁移或 reset 前，设备要停止取得新 chain，并 drain、保存或明确取消旧请求。一个写请求若已经落到镜像却还没发布 used，目标端盲目重放可能重复副作用；直接遗忘则让 guest永久等待。块设备因此要把“宿主完成”和“guest看到完成”之间的缝写进 in-flight 设计。

## vhost 移动数据面，QEMU 保留控制面

普通 QEMU 路径由 QEMU 解析 descriptor并调用服务 backend。内核 vhost把选定设备的数据 queue交给内核线程，vhost-user把它交给独立进程。官方 [`virtio-backends`文档](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/docs/devel/virtio-backends.rst) 也把实现位置分为 QEMU、kernel vhost和外部 vhost-user。

QEMU 仍创建 machine 和 transport，完成 feature/status 协商，选择 backend，建立 memory table与 kick/call fd，控制 start/stop、reset、热插和迁移，并把错误报告给管理层。数据请求可以不再进入普通 QEMU handler，这不等于 QEMU 从设备模型中消失。

内核 vhost常见于网络等设备，vhost-user-blk则由外部进程处理块 queue。不同 backend支持的 feature、dirty log、in-flight和设备私有状态不同；“使用 vhost”不能成为统一的迁移能力声明。

:::: {.quick-quiz}
开启 vhost 后，为什么仍要让 QEMU 保存 virtio status 和 queue 配置？

::: {.quick-answer}
这些状态属于 guest 可见的 transport/device 控制面。backend消费数据 queue，QEMU还要在 reset、热插、失败和迁移时停止它，并在目标端用相同配置重新建立执行关系。
:::
::::

## start、stop 与迁移组成一套事务

[`hw/virtio/vhost.c`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/virtio/vhost.c) 启动 backend 时设置 feature，提交可访问 RAM 的 memory table，为每个 vring配置大小、base、地址、kick/call fd，按需登记 IOMMU listener和 dirty log，然后启用 queue。中途失败要逆序撤销已经启动的 vring、listener、日志和 fd。

停止时先阻止 backend 取得新请求，再关闭 vring，由通用 vhost 路径取得 vring base、同步 used ring 与 dirty log，最后撤销映射。in-flight 不是通用 stop 自动收集的固定步骤：只有具体设备和 backend 声明能力、并走显式 `get_inflight`/设备状态路径时，才能取得这部分状态。vCPU 暂停不能代替上述步骤，backend 可能仍在处理已 kick 的请求；无法返回可信 vring base 或所需 in-flight 状态时，迁移应失败，不能带着猜测出的索引在目标继续。

memory table会随运行配置更新。RAM热插、共享属性和地址空间 section变化会触发 MemoryListener更新；MMIO区域不能当成普通 RAM交给backend。独立进程还要通过受控 fd共享内存，短消息、fd数量错误和连接中断都必须进入失败回滚。vhost-user 可以形成独立的调度、重启和运维故障域，却不是 QEMU 安全模型认可的隔离边界：双方共享客户机内存，backend 必须与 QEMU 处于同一信任域。移动数据面改变了解析位置，也新增了一条需要审计的控制协议。

live migration至少要覆盖四类状态：guest RAM中的 ring和buffer，QEMU中的 transport/device状态，vhost core中的 vring base、日志与 in-flight，backend私有状态。dirty bitmap只说明哪些页被写过，无法说明哪一条请求正在执行。固定基线提供 in-flight VMState与 backend state接口，也必须逐设备确认是否实现；缺少能力时安装 blocker是可验证的行为。

## RISC-V IOMMU 把地址所有权带到 backend

在 RISC-V `virt`的 PCIe 路径上，virtio-pci function以 BDF作为 requester。guest启用 IOMMU platform后，queue和数据地址按 IOVA解释；RISC-V IOMMU依据 device context、页表与权限翻译。vhost同时持有两张不同的授权表：memory table说明哪些 guest RAM可由 backend访问，IOTLB说明某个 requester的 IOVA当前能到达哪里。

vhost core在 `vdev->dma_as`登记 IOMMU listener，把映射失效等变化传给支持 IOTLB协议的 backend。guest撤销权限时，还要考虑已经在飞的 DMA、失效完成和 fence顺序。backend不支持所需 IOMMU能力时，应拒绝该 feature组合或回到已验证路径，不能静默把 IOVA当 GPA。

当前 RISC-V IOMMU PCI模型本身被标为不可迁移。即使某个 vhost backend能够保存 in-flight，也不能据此宣布“RISC-V IOMMU + vhost”整条链支持迁移；IOMMU context、cache、queue与 backend IOTLB都需要共同的停机点。

## VFIO 的边界比 vhost 更靠近物理设备

VFIO 把宿主物理 PCI function分配给 guest。QEMU仍呈现 PCI配置、BAR、ROM与中断，并通过 VFIO 或 IOMMUFD 向宿主内核登记 guest memory和 DMA权限；设备的数据面在物理硬件执行。它与 vhost解决的层次不同：vhost执行 virtio协议，VFIO交付一台实际设备，其协议未必是 virtio。固定基线的 IOMMUFD 文档列出的宿主架构是 x86、Arm 与 s390x，没有把 riscv64 host 列为已支持环境；本节在 RISC-V target 上解释接口边界，不把它写成已经完成的 riscv64-host 动态实验。

guest可见 RISC-V IOMMU和宿主 VFIO IOMMU是两道边界。前者让guest管理 IOVA与设备 context，后者保护宿主物理内存并受 IOMMU group、容器或 IOMMUFD约束。只配置 guest IOMMU无法替代宿主隔离，宿主合法映射也不能替 guest检查页表权限。

直通设备的 reset、热拔和迁移取决于设备及内核提供的能力。[`hw/vfio/pci.c`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/vfio/pci.c) 与 [`docs/devel/migration/vfio.rst`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/docs/devel/migration/vfio.rst) 展示了配置、IRQ和迁移状态机。设备与内核若没有提供所需的 `VFIO_DEVICE_FEATURE_MIGRATION` 能力、可读取/写入的设备状态流、可用 reset 和目标端兼容硬件，管理层应在启动或迁移前拒绝，而非到切换点再尝试恢复。

隔离测试还要主动让设备触碰映射边界，并确认宿主IOMMU拒绝越界DMA。guest中一次正常收发只能证明授权路径可用，无法证明设备被限制在授权范围内。物理设备固件、PCIe peer-to-peer和共享IOMMU group都会改变威胁面，部署结论必须带上具体host拓扑。

## 用所有权、trace 和故障完成排查

排查时先固定 RISC-V machine、transport、queue数、feature、backend和负载。monitor的 `info qtree`确认 device/transport，`info mtree -f`确认 notify与 RAM窗口，`info pci`确认 BDF/BAR；`hw/virtio/trace-events`中的 queue notify、pop、flush和 notify事件用来重建 QEMU路径。vhost开启后看不到逐请求 pop，可能说明数据面已经移交，也可能说明事件未启用，需用 backend计数和 guest完成共同验证。

每笔请求维护一行所有权账本：queue/head、driver发布、执行主体取得、宿主副作用、used发布、guest回收。再注入非法 chain、映射失败、backend断开和 reset，检查请求最终由谁释放、错误是否到达 guest或管理层。性能报告同时记录吞吐、延迟分位、QEMU/backend CPU、kick/call与 batch，才有机会解释路径变化。

跨QEMU线程、vhost-user进程和guest采集日志时，各自时间戳未必能直接相减。优先用queue index、head、sector和请求ID关联，再用同一宿主单调时钟补充外部事件。日志行彼此靠近只能提供线索，不能单独证明因果顺序。

## 实验：跟踪一笔 QEMU virtqueue

::: {.hands-on}
配套手册：[`trace-virtqueue`](../experiments/part-04-machine-and-device-models/chapter-19-virtio-and-vhost/trace-virtqueue/README.md)。

在 RISC-V `virt`上固定一种 transport和一个 virtio-blk queue，让 guest执行一笔可识别的读请求。手册会从当前二进制的 `-trace help`筛选实际存在的事件，并以 snapshot方式保护基础磁盘。报告按“driver发布—kick—pop—block提交/完成—used—interrupt—driver回收”排列。

使用 virtio-mmio 时记录 MMIO notify与 PLIC/APLIC路径；使用 virtio-pci 时记录 BDF、BAR、MSI-X以及是否经过 RISC-V IOMMU。校验数据正确、head只完成一次，同时保存原始 index，避免先画图后丢失 wrap和batch证据。
:::

## 实验：比较 QEMU 与 vhost 数据面

::: {.hands-on}
配套手册：[`compare-virtio-and-vhost`](../experiments/part-04-machine-and-device-models/chapter-19-virtio-and-vhost/compare-virtio-and-vhost/README.md)。

先执行只读能力探测，确认本机实际具备哪种 vhost backend及权限。基线组和 vhost组保持 riscv64 guest、transport、queue、feature、镜像与负载一致，分别记录 QEMU/backend CPU、kick/call、逐请求 trace、吞吐与延迟分位。环境不具备 backend时标记 skip，不修改系统权限来制造结果。

随后在持续 I/O 中请求正常 stop，观察 vring base、dirty log与 in-flight边界；仅在 backend明确支持状态迁移时继续迁移实验。预期两组都保持 guest I/O正确，vhost组的数据消费位置发生变化，QEMU的配置和生命周期记录仍然存在。路径确认与性能改善分开下结论。
:::

I/O 分层最终给了我们一套可追责的完成协议：driver、transport、device、backend和硬件各自拥有一段状态，也必须在 reset、故障和迁移时交还它。路径越快，这份账越不能省。
