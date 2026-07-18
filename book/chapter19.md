# virtio、vhost 与 I/O 数据面

virtio 把设备 I/O 写成一份共享内存协议：客户机驱动发布描述符，设备消费请求并写回完成。寄存器访问只负责协商、建队列和通知，批量数据留在客户机内存。vhost 又把描述符消费移到内核或独立后端进程，减少 QEMU 主循环参与次数。每移动一次执行位置，状态所有权、内存授权、错误传播和迁移冻结都要重新划界。

本章固定使用 RISC-V `virt` 与 riscv64 客户机。源码锚为 QEMU 官方 GitLab [`v11.1.0-rc0`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0) 的 `eca2c162`，主要入口是 [`hw/virtio/virtio.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/virtio/virtio.c)、[`virtio-mmio.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/virtio/virtio-mmio.c)、[`virtio-pci.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/virtio/virtio-pci.c)、[`hw/block/virtio-blk.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/block/virtio-blk.c)、[`hw/net/virtio-net.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/net/virtio-net.c) 与 [`hw/virtio/vhost.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/virtio/vhost.c)。源码事实、提交说明、作者推断和开放问题会分别标注。

## 本章目标

- 区分 virtio device、transport、virtqueue、QEMU backend 与 vhost backend；
- 在 RISC-V `virt` 上跟踪一次 virtio-blk 和一次 virtio-net 请求；
- 解释 split/packed ring、描述符验证、内存顺序和通知抑制；
- 跟踪 vhost 的 memory table、notifier、IOTLB、dirty log 与 in-flight state；
- 从 Git 历史判断数据面下沉为何没有消除 QEMU 控制面责任。

## 先把五个角色摆开

`VirtIODevice` 保存设备公共状态，包括 device status、协商后的 feature、config generation 和 virtqueue 数组。virtio-blk、virtio-net 在此基础上定义请求格式、配置空间和完成规则。设备类型决定“队列中的字节是什么意思”。

transport 决定客户机如何发现设备、写队列地址、发送 kick 和接收 interrupt。RISC-V `virt` 的板级循环创建八个 virtio-mmio slot；PCIe 路径则把 virtio device 包在 virtio-pci proxy 后，挂到 GPEX root bus。两条路径使用同一 virtio core 与设备实现，枚举和通知布线不同。

`VirtQueue` 是协议状态。它记录 ring 地址、队列大小、`last_avail_idx`、used 索引、packed wrap counter、notification 状态、guest/host notifier 以及映射 cache。它不解释块操作码或网络头，只把客户机散布在内存里的 descriptor chain 变成 `VirtQueueElement`。

QEMU backend 执行具体宿主操作。virtio-blk 把请求交给 block layer，virtio-net 把帧交给 NetClient 图。异步完成回调最终回到 virtio device，更新 used ring 并决定是否中断。

vhost backend 接管若干 virtqueue 的消费与完成。QEMU仍创建前端设备、协商 feature、提供客户机内存映射、传递 kick/call fd、处理启动停止和迁移。把 vhost 称为一个独立“设备”会遮住这份分工。

| 层次 | 拥有的主要状态 | RISC-V `virt` 中的实例 | 失败时首先检查 |
| --- | --- | --- | --- |
| device | feature、status、device config、请求语义 | virtio-blk、virtio-net | 请求格式与完成语义 |
| transport | 发现、queue address、notify、IRQ | virtio-mmio 或 virtio-pci | MMIO/PCI 配置和中断路由 |
| virtqueue | descriptor/avail/used 与索引 | split 或 packed ring | 地址、长度、索引、内存顺序 |
| QEMU backend | 块图或网络图中的宿主操作 | block backend、NetClient | 异步错误与 backpressure |
| vhost backend | 已下沉队列的数据面 | 内核或独立进程 | memory table、fd、IOTLB、连接状态 |

:::: {.quick-quiz}
为什么“设备已经由 vhost 接管”仍不能关闭 QEMU 中的 virtio 对象？

::: {.quick-answer}
客户机仍通过该对象完成 feature/status/config 交互，machine reset、热插拔和迁移也从 QEMU 控制面发起。vhost只接管约定队列的数据面，前端可见状态和生命周期没有随之消失。
:::
::::

## RISC-V `virt` 上的两种 transport

virtio-mmio slot 位于 `virt_memmap[VIRT_VIRTIO]`，多个实例按固定步长排列。FDT 为每个 slot 发布 `virtio,mmio`、寄存器范围和 PLIC/APLIC interrupt。客户机驱动读 magic、version、device ID，协商 feature，设置 queue size 和 descriptor/driver/device 区地址，然后写 status 的 `DRIVER_OK`。

`virtio-mmio.c` 接受 queue selector、64 位 ring 地址、queue ready 和 notify 写入。队列 ready 后调用 `virtio_init_region_cache()`建立 ring 映射；queue notify 寄存器最终进入 `virtio_queue_notify()`。当前 `virtio_mmio_set_guest_notifiers()`路径明确不请求 irqfd，这是一项固定源码事实，不能扩大成所有 transport 或所有加速模式的结论。

virtio-pci 由 PCI 配置空间和 capability 暴露 common/device/notify/ISR 区。客户机先经 ECAM 枚举 BDF，再为 BAR 分配 PCI MMIO 地址；queue notify 可能写 notify BAR。设备 DMA 使用 PCI AddressSpace，启用第 18 章的 RISC-V IOMMU 后，描述符和数据映射受 requester ID 对应的 context 约束。

两条 transport 都向 virtio core 提供 queue address、通知和 config 回调。设备实现不应从 `virtio-blk.c`直接访问 RISC-V PLIC 或 GPEX BAR。工程收益是复用，代价是调试时必须跨三层：board 发布资源，transport 翻译访问，device 执行语义。

transport 选择也影响 vhost notifier 能力。ioeventfd 可以让客户机 kick 直接唤醒数据面，绕开常规 MMIO 退出处理；irqfd 或 call notifier 可以加速完成通知。具体组合要由 transport class 和运行环境共同确认，不能从 `ioeventfd=true`属性推断两向通知都已旁路。

## feature 与 status 是启动协议

设备先发布 host features，驱动选择子集并写回。virtio core 保存 negotiated features，device 的 `set_features`回调据此启用 packed ring、间接描述符、event index、多队列或设备特定功能。驱动不能使用未被双方接受的布局。

status 通常按 `ACKNOWLEDGE`、`DRIVER`、`FEATURES_OK`、`DRIVER_OK`推进。设备在 `FEATURES_OK`阶段校验组合，拒绝时清相应确认；`DRIVER_OK`之后队列才进入正常服务。`FAILED`与 `DEVICE_NEEDS_RESET`分别表达驱动放弃和设备要求恢复。

status 写零表示设备 reset。virtio core要清队列索引、地址、ready、notification和协商状态，device还要取消异步请求或把它们放到安全恢复路径。transport寄存器、device状态与 backend活动必须在同一个 reset事务里收敛。

feature 的位数也会演进。提交 [`0a49a974`](https://gitlab.com/qemu-project/qemu/-/commit/0a49a97433279512a03f3d9f36164a46caf498c6) 为 64—127 位扩展 feature加入序列化，并用 build-time约束固定迁移数组大小。提交说明直接表明：新增 feature不止修改协商路径，还要决定旧迁移流如何初始化新增范围。

源码事实是当前版本保存扩展 feature；作者推断是维护者把数组大小固化，意在避免未来静默改变线格式。这个动机与提交说明相符，但不应进一步推断 feature空间永远停在当前上限。

## split ring 的所有权转移

split virtqueue由 descriptor table、avail ring和 used ring组成。descriptor给出 guest地址、长度、方向、next和 indirect标志；avail保存驱动新发布的 head index；used保存设备完成的 head与写入长度。三块区域可以位于不同 guest physical page。

驱动先写数据和 descriptor chain，再把 head放入 avail slot，最后推进 avail index。设备读取新 head，沿 next得到 scatter-gather，完成后写 used element并推进 used index。索引是 16 位循环计数，差值和队列大小共同判断可消费数量。

方向从设备视角定义：没有 `WRITE`标志的 buffer是 device-readable，带 `WRITE`的是 device-writable。virtio-blk请求头和写入数据通常在 out iovec，读回数据与 status在 in iovec。把方向按客户机 `read()`/`write()`理解会得出相反结论。

indirect descriptor让一个主表 entry指向另一张 descriptor table，减少主 ring压力。实现必须验证表长是 descriptor大小的整数倍、chain不越界、next不形成循环、元素数不超过允许上限，并限制总长度运算溢出。客户机控制所有这些字段。

`virtqueue_pop()`读取下一个可用 element，split路径把 out/in段映射成 `VirtQueueElement`。设备完成后调用 `virtqueue_push()`；该函数加入 used element并通过 `virtqueue_flush()`发布索引。设备随后调用 `virtio_notify()`，core按抑制规则决定是否真正触发 transport interrupt。

设备不能在异步 I/O开始后立刻释放 element。virtio-blk把 `VirtIOBlockReq`留到 block回调，virtio-net的异步发送也保存 element。reset、暂停或后端断开时，代码要知道谁还持有它。

## packed ring 把状态压进一张表

packed virtqueue把 descriptor和完成标志放入同一环，avail/used通过标志与 wrap counter表达。driver和device各维护 index与wrap位；绕过末尾后翻转。标志组合决定一个 descriptor属于哪一轮，单看数组下标无法判断所有权。

packed布局减少分散访问，也支持批处理；解析复杂度随之上升。间接链、连续 buffer、event suppression和 out-of-order能力要结合协商 feature处理。QEMU在 `virtio.c`中为 split和packed选择不同 pop/flush路径，device层仍收到统一 element。

迁移要保存队列 index和wrap counter。只保存 ring内存不够，因为源端可能已经消费 descriptor却未写回完成，driver/device的逻辑位置无法从瞬时标志唯一恢复。vhost接管后，backend还持有自己的 vring base与 in-flight信息。

排障时应先记录 layout feature，再解释 index。用 split ring的 `last_avail_idx`公式套 packed trace，会把一次正常wrap误判为重复消费。

:::: {.quick-quiz}
为什么 packed ring 仍需要 QEMU 保存索引，不能只在目标端扫描 descriptor 标志？

::: {.quick-answer}
标志与 wrap轮次共同表达所有权，且可能存在已取走但未完成的请求。迁移时扫描无法可靠还原设备推进位置和 in-flight边界，显式索引属于协议状态。
:::
::::

## ring 映射经过设备 DMA AddressSpace

queue地址来自不可信客户机。`virtio_init_region_cache()`通过 `vdev->dma_as`分别映射 descriptor、avail和used区域，要求返回长度覆盖完整结构。任何区域部分映射、权限不符或地址溢出都会失败。成功后用 RCU替换旧 cache，读路径可以在受控生命周期内使用映射。

PCI transport下的 `dma_as`可被 RISC-V IOMMU包装。一次 ring访问可能先查 device context，再走S/G阶段页表，最终进入 RAM。virtio device无需复制 IOMMU逻辑；它只使用设备视角 AddressSpace。virtio-mmio是否接入同样的 IOMMU取决于平台连接，不能因为 CPU能访问该 GPA就假定设备也能访问。

ring cache不等于永久 host pointer。MemoryRegion拓扑变化、queue地址重配、IOMMU invalidation或 migration阶段都可能要求刷新。RCU解决读者与替换的并发释放，不替代地址授权检查。

提交 [`e209d4d7`](https://gitlab.com/qemu-project/qemu/-/commit/e209d4d7a31b9f82925a2205e6e19e61a3facbe0) 改进 ring映射错误，把显式 device ID或 QOM路径带入诊断。提交关联了多设备场景难以定位的既有问题。上游陈述支持的结论是“可辨识设备属于错误语义”；作者进一步判断，这也降低了把 guest配置错误误当成 IOMMU缺陷的排障成本。

数据 buffer在 pop时按方向映射，不能因 ring三块区域已缓存就跳过。descriptor可能指向 MMIO、越界地址、只读映射或跨 MemoryRegion边界；实现需要处理部分映射并在失败时释放此前段。

## 描述符解析是安全边界

一条恶意 chain可以让 next自环、声明极大长度、把 indirect嵌套到不允许的层次，或混淆可读和可写段顺序。QEMU面对的是客户机输入，解析失败应停止该请求并报告设备错误，不能追随地址到宿主进程任意内存。

长度累加要防整数溢出，iovec数量要有界。virtio规范还要求 device-readable段先于device-writable段；实现遇到逆序链要拒绝。块设备随后还要检查请求头、sector范围、status buffer长度，网络设备要检查 virtio-net header和帧长。

DMA mapping返回的 host virtual address只在对应映射与 RCU/MemoryRegion生命周期内有效。异步后端若要长期持有，必须按 virtio core约定保存和 unmap；完成长度用于写回脏页标记。漏 unmap会破坏迁移脏页追踪和地址空间更新。

错误消息需要设备身份、queue index、head、guest address和访问方向，日志又不能解引用未验证数据。tracepoint用于重建路径，错误返回决定客户机可见结果；两者不能互相替代。

## 内存顺序保证“先内容、后索引”

driver发布descriptor时，设备必须在观察到新avail index后看见此前描述符和数据。设备完成时，driver在观察到used index后必须看见used element和返回数据。这是共享内存生产者—消费者协议。

QEMU中的barrier和原子访问呈现设备侧顺序。TCG执行RISC-V客户机时，guest指令的内存模型、softmmu访问与host线程并发共同参与；vhost线程直接读取guest RAM时更依赖正确barrier。一次本机测试“总能工作”不能证明弱序下正确。

通知也必须排在发布之后。先kick再写avail可能让设备醒来后看不到请求；先interrupt再写used会让driver读到旧完成。event suppression优化只能减少通知，不能打乱所有权转移。

批处理允许先加入多个used element，再一次flush和notify。它减少cacheline争用与退出次数；异常路径需要精确说明已完成多少个，避免重复写回。virtio-net接收路径就会积累多个element后统一`virtqueue_flush()`。

## kick、call 与通知抑制

kick是driver到device的队列通知，call是数据面到driver的完成通知。QEMU普通数据面里，transport收到notify后调用`virtio_queue_notify()`，queue handler再pop；完成调用`virtio_notify()`，transport更新ISR并拉起RISC-V中断线或发MSI。

`NO_INTERRUPT`标志或event index可让device判断新增used是否跨过driver要求的event。反向也有notification control，device可暂时关闭kick并在重新检查ring后避免lost wakeup。正确顺序通常是关闭通知、排空、重新启用、再次检查；只检查一次会在窗口里漏请求。

ioeventfd把指定notify写转换为eventfd信号。vhost将kick fd交给backend，把call fd接回guest notifier。fd只是唤醒通道，queue地址、索引和feature仍由控制面传入。

通知合并提高吞吐并增加尾延迟。网络小包、块随机I/O和批量顺序I/O的合适策略不同。实验要同时记录每请求kick/call比、batch大小与延迟分位，单看吞吐无法判断event suppression是否健康。

## 一次 virtio-blk 请求

RISC-V驱动为读或写建立chain：固定请求头、可选数据buffer和一字节status。它发布avail并kick。`virtio_blk_handle_vq()`循环调用`virtqueue_pop()`，`virtio_blk_handle_request()`解析type、sector和segment，再把操作提交到block layer。

写请求的payload是device-readable，后端完成后通常只写status；读请求的数据区是device-writable，完成长度要覆盖返回数据和status。flush要求此前持久性边界生效，discard/write-zeroes还有范围和对齐规则。共用virtqueue没有抹平这些设备语义。

block layer可能同步返回，也可能稍后回调。`virtio_blk_req_complete()`写status，`virtqueue_push()`把in长度提交给used，再`virtio_notify()`。若启用请求合并或多队列，完成顺序未必等于提交顺序，guest依赖每个head对应的status判断。

reset或迁移要drain/freeze异步请求。源端若把一个已经写入宿主但尚未used的写请求遗忘，目标重放可能产生重复副作用；若直接丢弃，客户机永久等待。块设备的in-flight协议必须定义这条缝。

配置只读、容量、block size和拓扑会影响请求校验。驱动协商feature后再决定可发送操作；QEMU不能把宿主backend支持能力原样暴露而不实现virtio层错误转换。

## 一次 virtio-net 发送与接收

发送时driver在TX queue发布virtio-net header和packet segments。QEMU解析checksum、segmentation等offload字段，把包交给NetClient图；同步发送完成可立即push，遇到下游拥塞时保存async element，待callback后再完成。

接收方向相反：driver预先在RX queue提供device-writable buffers，宿主收到包后QEMU选择队列、pop足够buffer、写header与payload，批量flush并notify。driver没有及时补buffer时，设备不能无限缓存；网络层通过返回值和queue状态传播backpressure或按策略丢包。

多队列需要feature、queue pair数量、RSS/steering和transport notifier协同。每个queue有独立index和fd，控制队列又承载MAC、VLAN、promiscuous等命令。把控制队列当普通数据队列下沉会漏掉QEMU设备状态更新。

网络完成表示buffer已经被设备消费，不等于远端收到数据；块flush却具有持久性语义。两者都调用pop/push/notify，只能说明队列机制复用，不能从函数名推断上层完成保证相同。

:::: {.quick-quiz}
virtio-net RX 缺少可写buffer时，为什么不能由QEMU无限保存宿主来包？

::: {.quick-answer}
无限保存会把客户机背压转成宿主内存增长，并扩大迁移与暂停状态。设备需要通过网络层反馈拥塞或执行明确丢包策略，使资源上界和完成语义可预测。
:::
::::

## vhost 启动是一套状态机

`vhost_dev_init()`先选择backend ops，执行backend init和set owner，读取并校验feature与memory slot限制，建立`vhost_virtqueue`数组、memory listener和迁移条件。backend缺少`VHOST_F_LOG_ALL`等所需能力时，代码会安装迁移blocker，而非假装能够记录脏页。

设备status进入可运行状态后，`vhost_dev_start()`设置协商feature与endianness相关状态，必要时注册IOMMU listener，提交memory table，逐队列配置ring地址、base、kick/call fd并启动vring。随后处理dirty log和backend start回调。任一步失败都要逆序撤销已完成资源。

停止路径先让backend停止新工作，再禁用vring，读取vring base，重置backend status，移除IOMMU listener并同步dirty log。顺序的目标是形成一个可保存边界：不会再取得新descriptor，旧请求的处置可被收集，ring位置回到QEMU。

当前源码中的`vhost_dev_start()`/`vhost_dev_stop()`返回错误，调用者必须传播。控制面断开时，关闭fd或忽略返回值会让迁移误以为队列已冻结。

vhost不保证所有队列都下沉。virtio-net可由vhost处理数据queue，QEMU仍处理控制或特殊路径；配置变化还可能要求暂时停vhost再切回QEMU。调试应记录每个queue的handler和notifier所有者。

## memory table 是受控授权

vhost backend要把guest地址解释成可访问的宿主映射。QEMU的MemoryListener观察RAM region添加、删除和属性变化，把可共享区间整理成backend memory table。表项包含guest物理范围、大小、用户态地址等backend协议所需信息。

这张表不是一次性启动参数。内存热插拔、DIMM映射变化、共享属性或address-space重排都可能触发更新。backend有memory slot上限，QEMU需要合并连续section并在超限时给出可诊断错误。

只把RAM交给backend可以限制其DMA表面；MMIO callback不能被当作普通指针下放。独立进程backend还涉及共享内存fd和权限，未共享region无法直接访问。QEMU必须根据backend类型建立合法映射。

memory table说明“哪些GPA可被backend访问”，IOMMU IOTLB说明“某个设备IOVA当前能到哪些GPA并具有什么权限”。启用RISC-V IOMMU时两层都要成立。任一层拒绝都应让DMA失败。

## vhost 与 RISC-V IOMMU 的交界

设备协商IOMMU platform功能后，vhost注册IOMMU notifier/listener。RISC-V IOMMU map/unmap经过PCI AddressSpace传播，QEMU把IOTLB更新发送给backend。backend用device IOVA查IOTLB，再用memory table把GPA落到共享RAM。

requester ID仍由PCI设备身份决定。vhost线程不能因为掌握宿主地址而绕过device context；失效消息也要在允许设备继续DMA前到达backend。第18章的context cache、IOTLB和ATS扩展到另一执行主体后，陈旧映射风险更高。

失效期间可能已有I/O在飞。软件撤销写权限时，要定义旧请求是否可以完成、何时确认fence、backend何时停止使用旧mapping。QEMU listener只负责传递协议事件，客户机driver与backend仍需遵循顺序规则。

无法建立IOMMU listener或backend不支持IOTLB时，应拒绝该feature组合或回退到明确支持路径。静默按GPA直通会破坏RISC-V IOMMU隔离。

## dirty log、in-flight 与后端私有状态

live migration期间，backend直接写guest RAM，QEMU CPU侧脏页机制看不到这些写。vhost dirty logging让backend标记DMA写过的页，QEMU在同步阶段合并到migration bitmap。缺少日志能力时设置blocker，是保持内存一致性的必要条件。

dirty page只回答“哪页变了”，不回答“哪条descriptor正在执行”。vring base保存消费位置，in-flight region记录已取走但尚未稳定完成的请求。块I/O还要考虑重放是否幂等，网络发送则可能允许不同丢包/重复语义。

提交 [`3a80ff07`](https://gitlab.com/qemu-project/qemu/-/commit/3a80ff0721b641f9c70af0d416c5c9e171c29aa3) 为in-flight region加入VMState，保存size、queue size和内部buffer；其提交说明明确为后续vhost-user-blk in-flight迁移做准备。修复提交 [`72f663f5`](https://gitlab.com/qemu-project/qemu/-/commit/72f663f575ab5e0f31320d7c9f25cc1f086313bd) 随后纠正pre-load返回类型和错误检查。这段历史说明恢复前分配与尺寸校验同样属于迁移协议。

当前core还提供`vhost_supports_device_state()`、`vhost_set_device_state_fd()`和`vhost_save_backend_state()`等接口，由backend ops决定是否支持状态传输。调用点存在不等于所有vhost backend都能迁移；不支持时应报错或安装blocker。

迁移冻结可按四类状态审计：guest RAM中的ring与buffer；QEMU中的virtio/device/transport状态；vhost core中的vring base、log与in-flight；backend进程或内核中的私有状态。每类要有停止、保存、恢复和失败回滚方案。

## backend 断开必须成为迁移错误

提交 [`5a317017`](https://gitlab.com/qemu-project/qemu/-/commit/5a317017b827e338358792cd07663f8ea25f1ffe) 让`vhost_dev_stop()`在停止virtqueue失败时向上传错，对应[邮件](https://lore.kernel.org/qemu-devel/20250416024729.3289157-3-haoqian.he@smartx.com/)。提交说明列出的现实故障是独立backend断开后，GET_VRING_BASE、SET_VRING_ENABLE或reset status失败。

后续提交 [`bc85aae4`](https://gitlab.com/qemu-project/qemu/-/commit/bc85aae4204509420f0a4403ca728801170d9351) 让迁移感知backend崩溃并终止，对应[邮件](https://lore.kernel.org/qemu-devel/20250416024729.3289157-4-haoqian.he@smartx.com/)。上游陈述指出，忽略断开会在目标重提in-flight I/O，乱序完成时可能造成I/O错误。

源码事实是错误现在可以沿status/stop链上传；强推断是维护者把“成功停止backend”提升为迁移提交条件，因为源端无法取得可信vring边界就无法构造目标状态。开放问题是每一种backend与设备类型如何处理断开后的已产生外部副作用，需要按各自协议验证。

错误回滚也不能重新启动一半queue。多队列设备若第k个vring配置失败，要停掉0到k-1并撤销notifier、listener和logging；否则guest看到的queue所有权分裂。

## Reset、暂停和迁移是三件事

reset由guest或machine请求，把设备带回规范初态，通常丢弃协商feature和queue配置。暂停只停止虚拟CPU与设备推进，保留可恢复状态。迁移冻结在暂停基础上还要建立可序列化、一致的跨进程边界。

vhost backend在vCPU暂停后仍可能处理kick或完成DMA，因此QEMU要显式stop。反过来，stop vhost也不等于reset，vring base和in-flight需要保留给恢复。混用三种操作会导致迁移后queue从零开始或reset后保留旧DMA。

设备status写零时，前端要等待或取消异步请求、停backend、清queue并释放映射。若backend停止失败，错误必须进入设备/管理层，不能继续释放它可能仍在使用的memory table。

## 性能优化要带着状态成本评估

普通QEMU数据面每次kick可能经过MMIO处理、主循环调度和backend提交；vhost通过ioeventfd与独立执行上下文缩短路径。收益取决于batch、系统调用、cache locality、backend类型和工作负载。

多队列让不同RISC-V vCPU处理独立queue，降低锁竞争；queue数量增加fd、memory mapping、migration state和中断负担。队列越多并不自动提高吞吐，单队列后端或共享block lock仍会串行。

zero-copy减少复制，延长guest page被backend持有的时间；通知合并减少中断，增加尾延迟；busy polling降低唤醒成本，占用宿主CPU。优化报告要同时写出状态所有权和故障回收代价。

比较QEMU与vhost路径时应保持guest镜像、RISC-V CPU数、queue数、block cache或网络backend、I/O深度和feature一致。只改命令行device名可能连transport与feature一起变化，结果无法归因。

## 安全审查从不可信环开始

guest控制queue size、ring地址、descriptor flags、长度和chain。transport寄存器写入要检查对齐与范围，virtio core检查结构，device检查协议，backend检查宿主资源。每层都要拒绝本层能够识别的非法输入。

独立backend扩大进程边界，也可能缩小QEMU本体的攻击面。Unix socket消息、共享内存fd、memory table和IOTLB更新成为新的输入面。断开、短消息、fd数量错误和版本协商失败都要有回滚。

IOMMU不能修复descriptor解析bug；descriptor位于合法映射页内，字段仍可能恶意。virtio验证也不能替代IOMMU隔离；合法chain可以指向未经授权的IOVA。两层解决的问题不同。

敏感日志不应转储整块guest packet或block data。保留device ID、queue、head、GPA/IOVA、长度、方向、feature和错误码，通常足以复盘并减少信息泄露。

## 用 trace 重建所有权变化

`hw/virtio/trace-events`包含`virtio_queue_notify`、`virtqueue_pop`、`virtqueue_flush`和`virtio_notify`。block与net目录还有请求级事件；vhost trace覆盖memory、vring、IOTLB和start/stop。先从当前源码确认事件名，再生成`-trace events=...`文件。

一条QEMU virtio-blk链应呈现kick、queue notify、pop、block提交/完成、push或flush、notify。vhost开启后，QEMU侧可能看不到逐请求pop，这是数据面已移动的证据；此时用vhost/backend统计、eventfd和guest完成共同闭环。

monitor的`info qtree`确认device/transport，`info mtree -f`确认MMIO与RAM映射，`info pci`确认BDF/BAR，自动FDT确认virtio-mmio节点。queue trace解释运行流，四个静态视图解释资源来源。

时间戳跨QEMU线程、backend进程和guest时钟不能直接相减。实验可用同一宿主单调时钟采集外部事件，以请求ID、queue head或sector/packet摘要关联，避免用日志行邻近代替因果关系。

## 从演进史判断当前设计

in-flight VMState的提交与紧随其后的pre-load修复显示，动态长度状态需要先迁移元数据、验证、分配，再读取内容。这个顺序来自提交事实；它不能证明所有in-flight格式已经稳定。

stop错误传播与backend crash系列把故障从日志提升到迁移失败。邮件明确讨论了乱序完成和重提风险。作者据此推断，vhost控制面的核心价值之一是把外部执行主体纳入QEMU事务结果，而非只负责“把fd传下去”。

ring映射错误改进又显示可观测性是多设备平台的维护接口。错误路径包含对象身份后，CI才能把恶意ring、IOMMU拒绝和设备接线问题区分开。这个判断属于作者推断，依据是提交关联的问题与修改范围。

开放问题包括：各backend对device-state传输的覆盖范围；RISC-V IOMMU与活动vhost IOTLB在迁移切换点的完整顺序；packed ring、in-flight与设备私有状态的组合测试矩阵。没有固定源码或运行证据时，本书不把它们写成已支持。

## VirtQueue 内部字段如何对应共享内存

`VirtQueue`中的`vring`记录guest提供的desc、avail、used地址和queue size，`vring.desc/avail/used` cache保存当前映射。`last_avail_idx`是QEMU已经取得的位置，`used_idx`及shadow字段帮助批量写回。队列编号把transport notify值映射到device handler。

`VirtQueueElement`保存head index、out/in scatter-gather数组、地址数组与段数。out段由device读取，in段由device写。地址数组留给unmap、脏页标记和错误处理，不能在形成host iovec后丢弃guest地址语义。

`inuse`等计数帮助检查取出但尚未归还的element。异步设备持有请求时，它是队列所有权审计的一部分；reset或migration要让计数与实际in-flight协议一致。手工把index重置为零不会释放已映射element。

guest notifier与host notifier名称从QEMU对象视角容易误读。kick fd把guest动作通知host/backend，call fd把host完成送回guest。审计时按“谁写fd、谁读fd”记录，比背名称可靠。

queue address、ready、size与feature组合在transport寄存器中配置，真正解析由virtio core统一。地址变化后旧cache需要失效并重新建立；队列运行中随意改址属于需要拒绝或reset的状态转换。

## 用具体索引走一次 split ring

设queue size为8，设备的`last_avail_idx=5`，driver把head 3写入`avail.ring[5]`，在发布barrier后把`avail.idx`从5改成6。设备观察到差值1，读取head 3并沿descriptor 3、6、7形成chain。

若descriptor 3与6为device-readable，7带WRITE，core生成两个out iovec和一个in iovec。设备处理期间`last_avail_idx`推进到6，head 3处于in-flight；driver不能重用这条chain，直到used可见。

完成时QEMU把`used.ring[used_idx % 8]`写成head 3与实际写入长度，执行发布barrier，再推进used idx。通知判断用旧新used位置与event threshold决定是否call。driver看到新used idx后才能读取status buffer。

16位idx从`0xffff`回到0时，用模运算的差值仍能表示队列内有限未处理数量。若driver让差值超过queue size，说明ring状态非法；QEMU不能循环消费任意旧entry。

这个例子区分了三个位置：driver发布idx、device消费idx、device完成idx。迁移只保存其中一个会漏掉in-flight。trace输出应至少关联queue、head和三个索引。

## Packed ring 的 wrap 与批处理边界

packed queue size为8时，driver和device index各自从0推进到7，再回0并翻转wrap。descriptor上的avail/used bit组合与当前wrap匹配，才属于这一轮。旧轮descriptor留在数组中，不能因flag某一位为一就重复消费。

一条chain可占多个连续descriptor，NEXT或indirect决定边界。device要先验证整条chain，再提交后端；解析到中途发现wrap/方向非法时，不能把前半条作为有效请求。

批量完成可以更新多个descriptor标志后一次通知，发布顺序仍要求返回数据先于used所有权。event suppression结构也在ring中，driver/device可能在相同cacheline并发写不同字段，barrier和访问宽度很重要。

迁移时保存next index、wrap、last used与in-flight。目标加载ring RAM后不应重新扫描选择“第一个可用”，因为环上可能有多个轮次残留标志。backend接管时还要把相同base传回QEMU。

测试wrap应使用很小queue连续处理超过两圈，并在边界前后save/load。每个request ID完成一次，顺序与设备语义一致，通知抑制不能造成永久停顿。

## virtio-mmio 配置时序

RISC-V driver先读magic、version、device ID和vendor ID，确认slot中确有设备。空transport可以返回device ID零，FDT列出slot只表示可探测位置。driver不能因节点存在就假定块设备。

feature selector让32位寄存器窗口分段读写更宽feature集合。driver读取device features，写driver features，设置`FEATURES_OK`并回读status确认。selector与feature值属于transport状态，reset后回到初态。

随后选择queue，读最大size，设置实际size和64位desc/driver/device地址，最后置queue ready。`virtio_init_region_cache()`在该时点验证三块ring。先ready再写完整高低地址会尝试映射中间值，应被驱动顺序避免、由模型校验。

写queue notify携带queue index。core检查index存在、queue ready和device status，再调handler。guest写越界index不能索引数组；未`DRIVER_OK`时是否处理按当前core规则确认。

完成后transport维护interrupt status，driver写ack寄存器清相应位，外部PLIC/APLIC线随剩余状态更新。清ack寄存器不消费used ring，driver仍需按idx回收descriptor。

## virtio-pci common configuration

virtio-pci modern interface通过PCI capability指出common config、notify、ISR和device config所在BAR与offset。capability本身在配置空间，实际寄存器在BAR。客户机要先启用PCI memory decode才能访问。

common config保存feature selector、device status、config generation、queue select、size、MSI-X vector、enable和64位ring地址。每个queue的MSI-X vector可不同，多队列因此拥有独立完成路径。

notify capability还给出multiplier，queue notify offset与multiplier计算最终BAR地址。设备不能假定queue编号就是连续4字节寄存器偏移。trace要同时记录queue index与写入地址。

ISR读取常带清除语义，MSI-X模式又按vector mask和PBA处理。transport负责把`virtio_notify()`转换成PCI中断，device层不读取RISC-V IMSIC地址。启用IOMMU时MSI write继续受第18章的重映射规则。

legacy与modern组合会影响feature、queue地址和迁移字段。本章固定源码实例优先使用modern路径；若命令行兼容属性启用legacy，实验必须写入环境，不能把两套寄存器trace混合。

## virtio-blk 请求解析的逐层校验

core先保证descriptor chain结构合法，virtio-blk再检查out段能容纳请求头、in段含status、type受协商feature支持、sector和长度不越过容量。每层错误属于不同协议。

读请求要求数据buffer可由device写，写请求要求payload可由device读。若方向错误，设备不能为了“兼容”反向访问。status byte通常是最后的device-writable段，完成写OK、IOERR或UNSUPP。

sector换算成byte offset时要检查乘法与加法溢出。discard/write-zeroes含多个range，range数、flags、对齐和总大小都要限制。flush没有数据payload，却要等待block layer持久性语义。

block backend可能启用缓存、节流、镜像与错误策略。virtio层收到完成错误后映射到status；管理层暂停或stop策略不能让请求既留在in-flight又已push used。异步callback是唯一完成所有者。

多队列为每个vCPU分散锁竞争，所有queue仍访问同一block graph。flush与写顺序可能跨queue，需要block层提供全局语义。只按单queue trace判断持久性会漏掉另一queue请求。

## virtio-net 的 buffer 预算

RX队列是driver提供的buffer预算。host packet到达时，设备先检查queue ready与可用buffer，再根据mergeable buffer feature决定一个packet可跨多少element。header中的`num_buffers`必须与实际使用一致。

包大于单buffer且未协商mergeable时，需要按设备规则丢弃或报告，不可越界写下一descriptor。checksum和segmentation offload改变header字段与payload处理，feature未协商时输入要按普通包验证。

TX队列消费driver buffer，NetClient返回拥塞时可暂停发送并保存一个async element。下游再次可写后继续，期间driver不能回收该head。reset要解除网络queue callback并归还或处理持有element。

control queue更新MAC、VLAN、RX mode和多队列状态，完成结果写入ack。vhost处理数据queue时，这些控制变化仍需同步到backend或由QEMU应用，避免两侧过滤规则不同。

backpressure测试需要限制guest RX补包或宿主发送能力，观察内存上界、丢包与恢复。只测满速吞吐看不到queue耗尽路径，也是大量迁移悬挂问题出现的位置。

## vhost 初始化的失败回滚

backend init成功后可能在set owner、get features、memory slot探测、queue分配或listener注册处失败。`vhost_dev_init()`要释放此前backend资源和动态数组，调用者也要撤销device侧notifier。错误信息应保留backend类型和阶段。

start阶段设置feature、memory table、vring address/base、kick/call和log。假设第3条queue设置失败，前两条已经被backend看到；回滚要禁用并取回它们，撤销fd和listener，不能只返回负值。

stop阶段同样可能部分失败。能够从backend读取的vring base要保存，无法确认停止的queue不能宣称冻结成功。`5a317017`把失败向上传递，正是为了让上层事务作出失败决定。

cleanup只应在backend不再访问memory后释放table和fd。独立进程断开可以关闭通信，内核backend仍可能有异步工作，具体ops负责同步。通用core不能凭socket EOF推断所有DMA已停止。

故障注入按每个ops返回点逐一执行，比较资源计数、fd、listener和guest status。只kill backend覆盖一种后期故障，不足以证明init回滚。

## MemoryListener 如何形成 table

system AddressSpace中的RAM可能被多个MemoryRegion section切分，包含alias、readonly和不可共享区域。listener收到region add/del，将可供backend访问的段转换成vhost memory region，并维护有序表。

相邻guest physical与host virtual范围都连续、属性兼容时可以合并，减少slot数量。仅GPA连续但host映射不连续不能合并；alias offset也要计入。错误合并会让backend跨入未授权内存。

memory hotplug先创建并映射RAM，再通知backend；拔除前要确保没有DMA引用，更新table后才能释放。table更新是控制面事务，backend返回失败时machine不能假装新内存已可用于DMA。

独立进程backend通常通过共享内存fd和offset获得映射。匿名或私有RAM若无法共享，设备启动应拒绝或选择明确兼容的内存后端。把QEMU host pointer发送给另一进程没有意义。

迁移dirty bitmap按RAMBlock/guest page组织，vhost log按backend协议记录。同步代码需要把两者地址关系转换正确。MemoryListener的table恰好提供GPA到host区域基础，但日志合并仍要检查范围。

## Notifier 的建立与切换

host notifier通常接收guest kick，guest notifier把backend call注入客户机。transport的`set_host_notifier`、`set_guest_notifiers`能力决定是否可以为每条queue建立eventfd和加速注入。

建立时先创建fd与handler，再告诉backend，最后切换transport路径；拆除时先阻止backend继续写fd，再注销handler并close。顺序错误会产生写已关闭fd、lost kick或悬挂回调。

切换到vhost前，QEMU普通queue handler可能已看到notify。代码需要排空或重新检查ring，使同一个head只被一方取得。切回QEMU后也要用返回的vring base继续，不能从旧`last_avail_idx`重复消费。

eventfd计数会合并多次通知，读取一次得到累计值。正确性依赖ring索引，不依赖一个fd事件对应一个request。性能统计把eventfd wakeup当请求数会误导。

RISC-V virtio-mmio当前guest notifier路径不请求irqfd是固定实现细节。实验若看到中断仍经过QEMU，不应归因于virtio device；应记录transport class选择。virtio-pci又有自己的notifier能力。

## vhost 迁移的四个屏障

第一个屏障停止取得新descriptor。QEMU切断kick或禁用vring，并等待backend确认。第二个屏障处理已取走请求：完成、取消或记录in-flight，设备协议决定是否可重放。

第三个屏障同步内存写。backend dirty log合并到迁移bitmap，确保目标收到完成数据、used ring和相关buffer。只保存vring base而漏dirty page会让目标索引指向未更新内容。

第四个屏障保存backend私有状态和前端VMState。feature、status、config、queue index、in-flight尺寸/内容及device-specific状态必须来自同一冻结点。状态fd接口是否可用由backend ops报告。

目标按反向依赖恢复：RAM与table可用，前端字段和backend state加载，vring/notifier配置，IOMMU listener与IOTLB建立，最后允许kick与vCPU运行。任一步失败都不能启动半恢复queue。

不同backend可能只支持其中部分屏障，QEMU用feature检查、migration blocker或错误终止表达限制。书中不能从一个vhost-user设备成功推到所有vhost设备。

## 用故障模型审查数据面

第一类输入故障来自guest ring：非法地址、循环chain、溢出长度、错方向与突然reset。virtio core和device parser负责拒绝，不把它们送到backend。

第二类资源故障来自host：block ENOSPC、网络拥塞、memory slot超限、eventfd耗尽。设备要形成可见status或启动错误，不能永久持有descriptor而没有诊断。

第三类分布式故障来自backend：连接断开、协议短消息、部分vring配置、停止失败与状态传输失败。vhost ops返回值要到达device和migration事务。

第四类一致性故障来自IOMMU与迁移：陈旧IOTLB、漏dirty page、错误vring base、重复in-flight。它们可能不立即崩溃，却造成越权、数据损坏或请求永久悬挂，测试要校验内容和唯一完成。

每类故障都写“检测者、清理者、客户机可见结果、管理层结果”。如果四项中存在无人负责的一格，设计尚未闭环。

## 性能实验如何避免误归因

固定riscv64 guest CPU数、virtqueue数量、ring layout、indirect/event-index、block cache或网络offload，再只切换QEMU/vhost数据面。feature协商结果从guest和QEMU两侧记录，不能只比较命令行。

吞吐外还要记录p50/p99延迟、QEMU线程CPU、backend CPU、kick/call、batch、上下文切换和IOMMU miss/invalidation。vhost减少QEMU CPU却增加backend busy polling时，总宿主成本可能上升。

预热阶段填充page cache和IOTLB，稳态阶段测命中，单独做cold启动。混合结果会把存储cache、IOMMU walk与virtqueue优化叠在一起。每轮保存版本与host配置。

错误率和尾部悬挂是性能结果的一部分。极限负载下若丢completion或迁移失败，较高吞吐没有工程意义。实验结束用guest校验数据和所有queue in-flight为零。

## 证据如何写进结论

当前函数、字段、默认property与返回路径来自固定tag源码，标“源码事实”。提交和lore邮件能直接支持问题陈述、review意见和合入顺序，标“上游陈述”。

从stop错误系列判断迁移需要可信冻结边界，属于有充分依据的作者推断；它可被未来新的恢复协议修正。具体backend是否支持state transfer若未运行或缺声明，标开放问题。

性能数字只属于给定host、guest和backend配置。一个设备的迁移成功也只覆盖该feature集合。结论写清量词可以让后续QEMU版本复查，而不会把实验扩张成不成立的普遍承诺。

源码阅读从device、transport、virtqueue、backend、vhost五层各取一个入口，再沿错误和reset反向走。只跟成功请求会遗漏本章最关键的控制面责任。

## Feature 组合要按依赖验证

indirect descriptor只改变chain存放方式，event index改变通知判定，packed ring改变整个layout，IOMMU platform改变地址解释，多队列改变queue集合。它们可以组合，验证不能只按单bit执行。

device先公布自身与transport/backend共同支持的交集。vhost backend若缺某bit，QEMU可以不广告、使用QEMU路径或拒绝启动，具体选择由device实现。协商后再发现backend不支持，会在`DRIVER_OK`附近造成晚期失败。

feature之间还可能互斥或依赖。device的`validate_features`/`set_features`路径应检查，guest直接写非法组合时不能进入未初始化data path。迁移目标也要支持源端已协商集合，不能重新协商成另一组。

测试矩阵至少覆盖split/packed、indirect开关、event index、多queue和IOMMU platform。矩阵可按代码影响裁剪，但每个组合记录host features、guest accepted features和实际backend features三份值。

扩展feature序列化提交说明迁移数组大小成为线协议。未来再扩展时，需要新的字段或subsection和旧流默认；仅扩大C数组会使目标读取不完整状态。

## virtio reset 的逐层顺序

guest把device status写零时，transport通知virtio core。device先停止接收新请求，QEMU或vhost数据面退出运行态；异步请求按device规则drain、cancel或保留可恢复边界。随后清queue ready、地址、索引、feature和device config运行字段。

host/guest notifier要在backend不再使用后撤销，ring cache与映射按RCU/AddressSpace规则释放。若先释放memory table，vhost线程仍可能访问descriptor。stop错误不能被reset路径悄悄吞掉。

transport清interrupt status、queue selector等寄存器，device清块/网特有状态，machine reset还会复位PCI或MMIO连接层。对象、BAR或固定MMIO region继续存在，driver可以重新协商。

PCI function-level reset、virtio status reset和system reset的覆盖范围不同。它们可能最终调用相似helper，测试应从入口分别确认PCI config、device config和backend状态。

reset后旧ring RAM仍在guest内存，queue address不再ready。driver重新初始化前，设备不能根据旧avail idx自动继续。否则复位前请求会跨代完成。

## 一个 vhost + IOMMU 请求的完整链

RISC-V driver在PCI virtqueue写descriptor，descriptor地址是IOVA。发布avail后写notify BAR，ioeventfd把kick交给vhost backend。backend用queue配置找到ring地址，却必须先从IOTLB取得IOVA到GPA permission。

IOTLB mapping由QEMU的RISC-V IOMMU notifier产生，memory table再把GPA定位到共享RAM。两级命中后backend读取descriptor和payload，执行宿主I/O，写返回buffer和used ring，并在dirty log标记对应页。

backend写call fd，virtio-pci guest notifier通过MSI-X向RISC-V IMSIC投递。若MSI也受IOMMU remap，目标由device context的MSI配置验证。guest handler读used并回收head。

这条链跨guest driver、GPEX、virtio-pci、vhost、RISC-V IOMMU、memory table、backend和IMSIC。任一环节都能导致超时。取证以queue head为主键，记录kick、IOTLB hit/miss、backend完成、dirty page、call和guest used。

撤销mapping时，先停相关I/O，IOMMU invalidate传播到backend，等待fence后才能复用页面。若backend继续命中旧IOTLB，RISC-V IOMMU用户态cache已清也无法保护RAM。

## QEMU 数据面与 vhost 切换

某些设备因状态变化、迁移或backend故障需要从vhost停回QEMU。切换前vhost停止取新descriptor并返回vring base，QEMU同步dirty/in-flight，再以该位置初始化普通queue handler。

切换窗口中guest可能继续kick。transport/notifier层要暂存或在新owner启动后重新检查avail，保证请求不会丢；旧owner和新owner不能同时pop。eventfd计数合并有助唤醒，正确性依赖ring复查。

从QEMU切到vhost反向执行：QEMU排空或记录已有请求，提交最新base、features、memory/IOTLB与fd，backend确认ready后才把kick导向它。失败则回滚并让QEMU保持唯一owner。

并非每个device都实现无缝runtime切换。上述步骤是控制面不变量，当前能力要从具体virtio-net、vhost-user-blk等调用者确认。没有调用路径时标设计要求，不写成用户功能。

## 块 I/O 的唯一完成账本

为每个virtio-blk请求记录head、type、sector、长度、queue、backend token、是否产生外部副作用、used是否发布。任一时刻只有一个组件有权把它从“已取出”推进到“已完成”。

同步错误在提交backend前写status并push；异步成功由callback完成；reset cancel只释放未产生副作用且协议允许取消的请求；迁移in-flight由源或目标按约定完成。两条路径都push同一head就是重复完成。

写请求可能已落到宿主却尚未used。目标盲目重提会重复写；普通数据写可能幂等，flush、discard或带外部副作用的操作未必。in-flight格式需要足够信息判断。

读请求完成数据写入guest后，dirty log和used发布顺序要一致。迁移只带used idx却漏数据页，guest会相信旧buffer有效。vhost logging正为这类直接DMA服务。

测试给每个请求写唯一pattern与序号，在迁移、backend断开和reset后核对磁盘内容、status和used次数。单纯fio进程退出码无法识别一次重复后仍返回成功。

## 网络 I/O 的完成与丢包账本

TX used表示device已经消费guest buffer，通常不保证远端接收。backend断开前已经交给host网络栈的包可能发送，也可能丢；迁移协议常允许网络瞬时丢包，仍不能重复占用descriptor。

RX完成意味着packet已经写入guest buffers。dirty log必须覆盖header与所有mergeable segments，used长度与`num_buffers`一致。迁移漏一段会造成guest解析损坏。

backpressure时async TX element由QEMU或backend持有，queue stop后要明确归还。控制队列改变MAC/VLAN后，数据owner的过滤状态要同步；迁移还要保存device config和backend私有表。

测试使用带序号packet区分丢失、重复与乱序，同时记录descriptor completion。网络协议可能容忍丢包，virtqueue仍要求每个已取得head有明确处置。

## Backend state fd 的能力边界

`vhost_supports_device_state()`通过ops询问backend，`vhost_set_device_state_fd()`建立保存或加载方向及阶段，`vhost_save_backend_state()`传输内容。接口存在说明core能够编排，不说明某backend实现回调。

状态fd传输还需要冻结协议：backend何时停止变化、内容与vring/in-flight对应哪个时刻、错误如何中止、fd关闭是否表示完整。调用者必须检查返回值和Error。

目标加载顺序要让memory table与必要资源先可用，backend state恢复后再启vring。若状态引用源端host fd或地址，backend格式本身无效；跨主机协议应使用稳定标识和数据。

支持查询返回false时，设备可用migration blocker明确拒绝。返回true后运行失败也要终止迁移，不能退回空state。不同设备class可有不同策略。

当前固定tag源码是能力接口事实；具体backend覆盖与长期线格式仍属逐实现问题。正文实验按实际探测分支，不预设成功。

## 上游提交中的错误传播链

`5a317017`先让`vhost_virtqueue_stop()`的错误经`vhost_dev_stop()`返回，上层才有机会知道GET_VRING_BASE或禁用vring失败。它改变的是控制面返回契约，不是数据面算法。

`bc85aae4`再把backend crash连接到device status与live migration结果，邮件明确说明忽略故障可能导致目标重提和乱序I/O错误。两个提交前后关系显示底层错误可达性是上层事务判断的前提。

`3a80ff07`为in-flight region加入VMState，`72f663f5`修正pre-load类型和错误检查。历史说明动态buffer迁移既要有线字段，也要安全分配与失败处理。

`e209d4d7`给ring mapping错误加入device身份，改善多设备诊断。它没有改变合法mapping语义，却提高故障可定位性。维护成本也是数据面设计的一部分。

这些是固定tag内可核验提交。作者将它们归纳为“状态、错误、身份必须回到QEMU控制面”，属于跨提交推断，正文保留证据链接和可修正边界。

## 数据面测试的完成条件

正常路径需要guest结果正确、每个head唯一完成、queue最终无in-flight、IRQ/kick比例可解释。看到吞吐数字或trace中出现pop，均不足以单独完成实验。

错误路径至少覆盖非法descriptor、backend I/O错误、stop失败、IOMMU拒绝和memory slot限制。每项记录guest status、QEMU管理错误、资源回收与目标buffer。

生命周期覆盖status reset、system reset、pause/resume和环境支持时的migration。四者预期不同：reset清队列，pause保留，migration保存，backend故障应阻止虚假成功。

性能比较保留完整feature、queue和backend配置，运行多轮并报告波动。正确性断言先于性能结论；任何数据损坏或悬挂都使该轮无效。

最后执行源码/历史对照。trace缺失可能因数据面下沉，运行失败也可能来自手册列出的客户机镜像、后端或 trace 能力前提。报告不把环境中不支持的 backend 写成 QEMU 实现失败，也不把脚本完成参数探测写成 virtqueue 请求已经跑通；只有客户机结果、事件链和资源回收同时闭环，才记录为一次成功运行。

## 用所有权账本结束排障

一次请求可依次由guest driver、virtqueue core、QEMU device、block/net backend或vhost backend持有。账本记录head、当前owner、取得时刻、可取消性、外部副作用、完成者和used发布。任一时刻只能有一个消费owner。

ring内存由guest RAM拥有，映射cache由virtio core管理，memory table由vhost控制面发布，IOTLB permission由RISC-V IOMMU决定，kick/call fd由transport与backend共享。把资源owner和请求owner分开，才能解释“fd仍在但queue已停”。

reset要求请求owner退出并清前端状态，pause保持owner，migration把owner状态转移，unrealize永久撤销资源。backend断开时账本中的未知项使迁移失败，而非猜测完成。

排障结束条件是每个head落到used、明确取消或协议定义的in-flight记录，所有mapping/fd/listener有回收者，guest结果与外部副作用一致。日志中出现“stop完成”只能作为其中一条证据。

同一实验还要固定transport。virtio-mmio与virtio-pci共享device/queue语义，发现、寄存器、notifier和中断路径不同；更换transport会同时改变退出次数、MSI能力和IOMMU接入方式。

报告写出FDT slot或PCI BDF、queue notify地址、IRQ/IMSIC路径、ioeventfd与guest notifier是否启用。这样vhost性能差异才不会被transport变化混入。

若某transport在当前环境缺少加速notifier，保留该结果并比较控制路径，不把它概括为virtio或vhost整体限制。能力结论始终落到固定源码、具体class和运行配置。

版本升级时重跑同一账本与transport记录，优先比较owner切换、错误返回和迁移blocker。函数重命名不一定改变协议，owner或失败条件变化才需要重写设计结论。

复查结果附一笔成功请求与一笔受控失败请求，二者使用同一queue和feature。成功证明基本通路，失败证明权限、错误传播与回收仍按预期工作。

## 实验一：跟踪 QEMU virtqueue

::: {.hands-on}
配套英文实验手册：[`trace-virtqueue`](../experiments/part-04-machine-and-device-models/chapter-19-virtio-and-vhost/trace-virtqueue/README.md)。

在RISC-V `virt`上创建virtio-blk设备，固定transport、queue数量和feature。按手册先从当前trace-events生成可用事件列表，再采集一次可识别sector的读请求。保存QEMU命令行、guest驱动信息、FDT或PCI拓扑、trace与I/O校验值。

报告按“driver发布—kick—pop—block提交—完成—used—interrupt”排列。若使用virtio-mmio，标出MMIO notify与PLIC/APLIC路径；若使用virtio-pci，标出BDF、BAR、MSI以及是否经过RISC-V IOMMU。预期读回校验正确，head只完成一次。
:::

## 实验二：比较 QEMU 与 vhost 数据面

::: {.hands-on}
配套英文实验手册：[`compare-virtio-and-vhost`](../experiments/part-04-machine-and-device-models/chapter-19-virtio-and-vhost/compare-virtio-and-vhost/README.md)。

按手册能力探测选择本机实际可用的vhost backend；若环境缺少权限、内核功能或独立backend，明确记录unsupported，不伪造性能结果。基线与vhost组保持riscv64 guest、transport、queue、feature和负载一致。

分别记录吞吐、延迟分位、QEMU CPU、kick/call计数、QEMU逐请求trace是否存在、backend启动停止日志。预期vhost组的descriptor消费离开QEMU普通handler，控制面仍能观察feature、memory table与生命周期。结论要区分“路径确认”和“性能改善”。
:::

## 实验三：审计停止与迁移边界

::: {.hands-on}
本实验复用[`compare-virtio-and-vhost`](../experiments/part-04-machine-and-device-models/chapter-19-virtio-and-vhost/compare-virtio-and-vhost/README.md)建立backend，并用[`trace-virtqueue`](../experiments/part-04-machine-and-device-models/chapter-19-virtio-and-vhost/trace-virtqueue/README.md)核对queue推进；入口见[第19章实验索引](../experiments/part-04-machine-and-device-models/chapter-19-virtio-and-vhost/README.md)。

在持续I/O中请求暂停和正常stop，保存vring base、dirty log同步、in-flight与guest校验结果。若backend支持状态迁移，再执行一次受控迁移；不支持时确认blocker或错误。故障分支在测试环境中终止独立backend，验证stop/migration失败能到达管理层。

不要把宿主进程强制退出用于生产环境。预期正常路径无重复或悬挂完成，故障路径不报告成功迁移。报告分别标源码事实、运行结果和仍未覆盖的backend私有状态。
:::

## 源码与上游审查清单

阅读新virtio功能时，先写device语义，再查transport寄存器和queue布局。feature必须覆盖广告、协商校验、data path、reset、VMState、旧版本兼容和测试。

修改ring解析时检查split/packed、indirect、循环、整数溢出、方向、部分mapping、RCU/unmap和错误身份。性能改动不能删除barrier或lost-wakeup复查。

修改vhost时画出init/start/stop/cleanup逆序关系，列出memory listener、IOMMU listener、kick/call、log、vring base、in-flight与backend private state。每个失败点都要知道谁回收前序资源。

引用上游邮件要写Message-ID对应的patch版本，并用最终GitLab commit确认落地代码。邮件解释问题，固定tag决定本书描述的函数和状态。作者从顺序作出的判断单独标注。

## 小结

virtio以共享ring传递请求，device解释语义，transport连接RISC-V `virt`的MMIO或PCIe资源，virtqueue core维护描述符、索引、mapping、barrier和通知。块与网络复用队列机制，完成含义、backpressure和异步状态仍各自独立。

vhost把descriptor消费移出QEMU，QEMU继续掌握feature、status、memory table、notifier、IOMMU更新、reset与迁移。dirty log解决DMA内存变化，vring base与in-flight解决执行位置，backend私有状态还要由具体协议传输。

固定标签中的in-flight、stop错误传播和backend crash提交共同说明：更短的数据路径并未减少一致性责任。下一步做任何加速，都应同时回答队列由谁消费、地址由谁授权、故障由谁上报、迁移时由谁冻结。
