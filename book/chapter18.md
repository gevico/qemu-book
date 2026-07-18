# PCIe、RISC-V IOMMU 与设备地址空间

CPU执行 `load`时，地址从 RISC-V页表走向内存；PCIe网卡发起 DMA时，事务带着 requester ID和设备地址，从另一套地址空间进入系统。没有 IOMMU，设备通常直接把地址解释为 guest physical address；启用 RISC-V IOMMU后，device context、process context、S-stage/G-stage页表、权限与缓存共同决定它最终能访问哪里。

本章固定使用 RISC-V `virt`和 riscv64设备实例，源码锚为官方 GitLab [`v11.1.0-rc0`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0) 的 `eca2c162`。入口包括 [`hw/riscv/virt.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/virt.c)、[`hw/pci-host/gpex.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/pci-host/gpex.c)、[`hw/riscv/riscv-iommu.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/riscv-iommu.c)、[`riscv-iommu-pci.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/riscv-iommu-pci.c) 与 [`riscv-iommu-sys.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/riscv-iommu-sys.c)。

## 本章目标

- 把 PCI bus/BDF、ECAM、BAR、CPU MMIO窗口和设备 DMA视图分开；
- 跟踪 requester ID到 RISC-V IOMMU device/process context及两阶段翻译；
- 理解 IOATC、命令队列、fault/page-request队列和 invalidation；
- 解释 ATS、MSI/MRIF与 IMSIC协作的状态边界；
- 从基础模型、cache、ATS、debug、sysbus封装和 reset历史判断当前限制。

## PCIe 有三套地址

PCI配置地址由 bus、device、function组成，通常写成 BDF。客户机通过 ECAM把 BDF与寄存器 offset编码为 CPU物理地址，从配置空间读取 vendor/device ID、class、capability和 BAR。ECAM窗口只服务配置事务，不承载设备数据寄存器。

BAR保存 PCI地址空间中的资源需求和分配值。固件或 OS先写全一探测大小，再为 BAR分配 PCI MMIO地址；GPEX把 PCI地址窗口映射进 CPU物理空间，CPU最终通过这段地址访问设备寄存器。BAR值不是 QEMU host pointer。

DMA地址由设备放进总线事务。未启用 IOMMU时，它可能直接对应 guest physical memory；启用 IOMMU时，它是 IOVA，需要结合 requester身份翻译。设备 BAR的 CPU MMIO地址和 DMA缓冲区地址属于两个方向，不应混在一张变量表里。

MSI又使用写事务承载中断。设备写一个特殊目标地址和数据，平台将其解释为 IMSIC interrupt file更新。它走 DMA样式的事务，却不能当普通 RAM写；IOMMU的 MSI page table与 trap AddressSpace专门处理这条分支。

:::: {.quick-quiz}
为什么 PCI BAR不能保存 QEMU进程中的宿主地址？

::: {.quick-answer}
BAR是客户机可编程的 PCI总线地址，固件和驱动会重新分配。QEMU通过 MemoryRegion把该地址映射到设备回调，host pointer属于进程实现，既不能暴露也不能跨迁移复用。
:::
::::

## GPEX 把 PCI fabric 接到 `virt`

`virt` machine创建 `TYPE_GPEX_HOST`，先设置 ECAM、低 4G MMIO、高 MMIO和 PIO的 base/size，再 realize。GPEX内部建立 root PCI bus、ECAM寄存器区与 PCI memory space，board随后用 alias映射到 RISC-V `virt`地址图。

ECAM位于 `0x30000000`起的固定大窗口，低 PCIe MMIO位于 `0x40000000`起。riscv64高 MMIO窗口大小固定为 16 GiB，基址在 RAM末端以上对齐；RAM变大时窗口上移。FDT `ranges`发布最终值。

GPEX还导出 PIO窗口，并提供四条 INTx输出。board把它们连接到 PLIC/APLIC源，设置 platform IRQ号。PCI INTx pin还经过 swizzle，桥后设备与 function可能映射到不同输出。只看设备 INTA不能直接得到最终 RISC-V中断号。

PCI设备挂在 GPEX root bus，配置空间由 PCI core维护。realize时设备注册 BAR MemoryRegion、MSI/MSI-X capability和 DMA AddressSpace；客户机枚举后才写 BAR与 command register。设备对象存在时 BAR可能仍未 enabled，mtree和 `info pci`要一起看。

初始 `virt`没有 PCIe，提交 [`6d56e396`](https://gitlab.com/qemu-project/qemu/-/commit/6d56e39649808696b2321cbd200dd7ccaa7ef7fe) 接入通用 GPEX。当前仍沿用通用 host，说明 board选择布线，PCI核心维护枚举和配置语义。这是源码与历史共同支持的分层事实。

## requester ID 是隔离身份

PCI requester ID通常来自 BDF。IOMMU不能只用 IOVA查页表，因为两块设备可以在各自地址空间使用相同 IOVA，却映射到不同 GPA。device ID先选择 device context，process ID可进一步选择进程上下文。

`riscv_iommu_pci_setup_iommu()`通过 PCI core的 IOMMU hooks接管 root bus DMA。QEMU为需要的 requester创建 `RISCVIOMMUSpace`，其中 IOMMU MemoryRegion表示该设备的 IOVA空间。设备 DMA API访问 `vdev->dma_as`或 PCI AddressSpace时进入 `riscv_iommu_memory_region_translate()`。

MemTxAttrs可以携带 process ID等属性。当前实现限制 PID位数与 QEMU attributes表达能力，并在 device/process context校验 capability组合。没有有效 PID时走 device default过程，不能随便用零替代一个明确进程。

FDT `iommu-map`把 PCI requester ID区间关联到 IOMMU phandle和 specifier。它让客户机内核知道哪些 BDF受哪个 IOMMU管理；QEMU运行时的 PCI IOMMU hook必须表达同一关系。描述与实现任一侧漏一个 ID，隔离和驱动绑定都会失效。

提交 [`926a8b8e`](https://gitlab.com/qemu-project/qemu/-/commit/926a8b8e4f11a1b1955f5f46c89069614ea28156) 修正 system IOMMU `iommu-map`的空 tuple与 length。修复覆盖 `0x0000`到 `0xffff`全部 requester ID。它说明身份区间边界也是平台安全语义。

## Device Directory Table 选择上下文

RISC-V IOMMU由 DDTP寄存器给出 device directory table根和 mode。DMA事务到来时，`riscv_iommu_ctx_fetch()`按 device ID遍历目录，读取 device context并验证格式。DDTP为 OFF时 DMA disabled，BARE时可直通；其他 mode决定目录层级。

device context包含 translation control、I/O G-stage根、first-stage或 process directory设置、地址空间 ID、MSI page table和 fault策略等。实现先验证保留位、capability依赖、S/G mode与地址范围，再用于页表遍历。

若启用 process directory，process ID选择 process context。它可以提供进程级 first-stage地址空间和属性；device context仍控制外层能力。目录读取本身也是内存访问，失败要产生准确 fault cause，不能继续使用半初始化上下文。

上下文进入 `ctx_cache`，避免每次 DMA重新遍历 DDT/PDT。cache key必须包含 device ID、process ID以及影响语义的身份。客户机修改目录后要提交相应 invalidate命令；QEMU不会通过普通 RAM写自动知道表项变化。

cache加速建立在软件遵守失效协议的前提上。若 driver改表后未 invalidate，真实硬件也可以继续使用旧 context；QEMU不应偷偷每次重读来掩盖 guest bug。测试要按规范执行 fence/invalidation。

## S-stage 与 G-stage DMA翻译

基础提交 [`0c54acb8`](https://gitlab.com/qemu-project/qemu/-/commit/0c54acb8243dfc51a021d108ffef794c89c84f72) 在规范 ratification后加入模型，明确首先支持 S-stage的 Sv32/Sv39/Sv48/Sv57和 G-stage的 x4模式。对应上游邮件 Message-ID可从[邮件归档](https://lore.kernel.org/qemu-devel/20241016204038.649340-4-dbarboza@ventanamicro.com/)查看。

first-stage把 IOVA转换成 GPA或 intermediate address，G-stage再把它转换到 system physical address。只启用一阶段时另一阶段为 BARE；两者都启用时权限取交集。读取与写入分别检查 R/W、U与 A/D等规则。

`riscv_iommu_translate()`接受 context、IOVA、access flags并填充 IOTLB entry。entry包含 translated address、address mask、permission和 target AddressSpace。调用者获得的不只是地址，还知道这段映射能覆盖多大范围和允许何种访问。

页表叶子可以表示不同 page size，NAPOT等能力又影响 mask。cache entry必须对齐到实际粒度；过大 mask会让相邻未授权页误命中，过小只损失性能。实现中的 permission和 mask属于隔离边界。

页表读取失败、非法 PTE、权限不足、A/D条件不满足和模式不支持分别产生 cause。两阶段错误还要表明发生在 S还是 G/VS路径，fault record携带足够 identity和地址供 driver诊断。

CPU H扩展的两阶段翻译与 IOMMU G-stage概念相似，状态和执行单元不同。CPU用 `hgatp`等 CSR，IOMMU从 device context取得 `iohgatp`类字段；不能从 CPU TLB实现推断 DMA自动受保护。

:::: {.quick-quiz}
为什么 IOMMU translate结果必须返回权限和 page mask？

::: {.quick-answer}
调用者会缓存结果并用于后续 DMA。缺少权限会让写绕过只读映射，错误 page mask会把未授权邻页纳入命中；地址本身不足以表达安全语义。
:::
::::

## IOATC 与失效命令

提交 [`9d085a1c`](https://gitlab.com/qemu-project/qemu/-/commit/9d085a1c3cb2b6a1ee77d5f6e0ca20241208acd8) 加入 Address Translation Cache。当前实现有 context cache与 I/O translation cache，容量受 `ioatc-limit`属性约束。缓存减少 DDT/PDT和页表读取，代价是 invalidation协议更复杂。

命令队列由 guest在内存中建立，寄存器给出 base、head、tail与 enable。IOMMU处理 IOTINVAL、DDT/PDT context invalidation、IOFENCE、ATS相关命令等。非法命令、内存错误或 timeout更新 queue status并通知。

失效可以按全部、device、process、GSCID/PSCID与 IOVA细分。细粒度失效减少 cache抖动，key组合也更容易出错。实现把不同组合映射到 hash table遍历/删除 callback，必须覆盖每个规范过滤条件。

IOFENCE建立命令和 DMA可见性的先后关系，并可请求通知。它不是简单清 cache：driver依赖 fence确认此前 invalidation与内存写已生效，再允许设备使用新映射。QEMU事件循环里的执行顺序仍要呈现规范效果。

context cache与 IOTLB是派生状态，reset可以清空，迁移理论上也可在目标重建。寄存器、队列 head/tail和 guest memory中的表才是架构状态。然而当前固定实现整体迁移仍有明确限制，后文单列。

性能测试要区分 cold walk与 cache hit。只测一次 DMA主要反映目录/页表遍历；稳定队列反映命中；频繁 map/unmap反映 invalidation成本。把三者混合成单个吞吐数字无法解释优化。

## Fault Queue 与 Page Request Queue

`riscv_iommu_report_fault()`构造 fault record，包含 cause、transaction type、device ID、可选 process ID和地址信息，再通过 `riscv_iommu_fault()`写入 guest配置的 fault queue。queue满或 memory access失败还要更新 overflow/status。

fault是否记录受 context DTF等策略影响。某些 cause可被禁止报告，DMA仍按错误返回；不能因 queue没有新记录就认为访问成功。实验要同时检查设备完成状态和 FQ。

Page Request Interface用于 ATS/PRI场景。设备发现地址未驻留时可以发送 page request，IOMMU写 PQ，软件处理后提交 page response。当前实现包含相关 queue与命令路径，实际设备/guest driver是否启用要按 capability和实验环境确认。

queue是 guest memory中的环，IOMMU寄存器保存 base/size/head/tail与控制。设备模型对 queue memory的读写必须做边界、对齐和 endian检查，不可信 guest可以提供恶意指针。错误不能越界访问 QEMU host memory。

通知可以是 wired interrupt或 MSI，取决于封装和 IGS能力。通知只告诉软件队列有工作，record本身在 guest RAM。迁移和 reset要分别处理寄存器、pending与内存内容。

## ATS 把 translation cache 延伸到设备

PCIe Address Translation Services允许设备请求地址转换，并缓存 translated address。提交 [`69a9ae48`](https://gitlab.com/qemu-project/qemu/-/commit/69a9ae483696e185889edaeddacf46afd9110bc6) 加入 ATS translation request、fault/event queue、page-request与 IOATC invalidation支持。

ATS启用后，IOMMU cache不再是唯一副本。软件修改页表时，既要失效 IOMMU内部条目，也要向设备发 invalidation并等待 completion。否则设备可能继续用旧 translated request绕过新权限。

QEMU的 PCI/IOMMU notifier把 map/unmap和 device IOTLB更新传播给后端。vhost使用 IOMMU platform feature时也注册 listener，内核数据面需要收到同样的 IOTLB更新。第 19章会跟踪这条边。

ATS capability存在不代表所有挂接设备都实现。device context还要允许 ATS，设备 PCI capability也要协商，driver才能使用。正文把当前 IOMMU core路径与具体设备支持分开。

ATS错误测试应先建立正常 translation request，再改变 PTE、执行 invalidation并验证旧条目不再使用。只看 capability bit无法证明失效闭环。

## Debug Translation Interface

提交 [`a7aa525b`](https://gitlab.com/qemu-project/qemu/-/commit/a7aa525b93c3f7a847cd2185b71aef97a17ec3d5) 加入 `tr_req_iova`、`tr_req_ctl`与 `tr_response`，当前 DBG capability始终启用。软件可以请求 IOMMU为指定 identity/IOVA执行调试翻译并读取响应。

debug接口复用正式 context与页表逻辑，适合定位 driver配置。它不能替代真实 DMA测试：设备 access flags、并发、cache和 MSI分支可能不同。报告应标“debug translation”或“data-plane DMA”。

`riscv_iommu_process_dbg()`处理 GO/BUSY、输入字段和响应。请求期间 guest再改控制寄存器或目录，模型要按规范决定快照；测试不应依赖未定义竞态。

调试响应也可能返回 fault，信息应与 FQ cause一致。若 debug成功而真实 DMA失败，优先检查 requester/process attrs、设备 bus mastering和访问方向。

## MSI、MSI page table 与 IMSIC

设备发 MSI时，目标 GPA可能匹配 context的 MSI address pattern。IOMMU在普通页表转换的适当阶段检测，命中后把 target AddressSpace切到 trap AddressSpace，让 `riscv_iommu_msi_write()`解释 MSI PTE。

MSI PTE可以选择基本翻译、pass-through或 MRIF相关模式。实现验证 valid/config字段、目标对齐、interrupt ID范围，随后向目标地址写数据或更新 memory-resident interrupt file并发送 notice MSI。错误写入 FQ。

IMSIC interrupt file是特殊目标，最终把消息投递给特定 hart/privilege/guest file。IOMMU负责设备身份与 MSI重映射，IMSIC负责 pending/enable/delivery；AIA machine负责地址布局。三者状态不能合并成一个“MSI开关”。

普通 DMA若恰好写 MSI范围，必须按 context策略拦截；否则恶意设备可伪造中断或写入不可见地址。反过来，把所有写都当 MSI会破坏 RAM DMA。地址 mask和 page table配置是安全边界。

PCI封装用 MSI-X向客户机报告 IOMMU自己的 CQ/FQ/PQ等事件，当前还为 MRIF notice分配额外 vector。system封装可以选择 wired或内部 MSI表。这里讨论的是“IOMMU设备自身通知”和“被管理设备发出的 MSI”两条路径，不应混写。

:::: {.quick-quiz}
MSI已经是一笔内存写，为什么 IOMMU还需要专门 trap路径？

::: {.quick-answer}
目标地址和数据编码了 interrupt file与 ID，context还可能要求重映射或 MRIF更新。普通 RAM写无法执行这些验证和投递语义，也无法生成对应 MSI fault。
:::
::::

## PCI封装与 platform封装共享核心

`riscv-iommu-pci`是 PCI system IOMMU设备，class ID为系统 IOMMU，BAR0组合核心寄存器与 MSI-X table/PBA。instance init创建内部 `TYPE_RISCV_IOMMU` child并 alias属性，realize先 realize核心，再初始化 BAR、MSI-X与 PCI bus IOMMU hook。

PCI封装可由 `-device riscv-iommu-pci`加入 `virt`。machine plug callback给自动 FDT添加 `riscv,pci-iommu`节点和 `iommu-map`，记录其 BDF；同时关闭 system IOMMU选择，避免一条 PCI bus被两个默认 IOMMU同时接管。

`riscv-iommu-sys`由提交 [`5b128435`](https://gitlab.com/qemu-project/qemu/-/commit/5b128435dcf1e6545b544e3e402470ecf5b45ac7) 加入，对应[上游邮件](https://lore.kernel.org/qemu-devel/20241106133407.604587-4-dbarboza@ventanamicro.com/)。提交说明明确保留 PCI设备的核心设计选择，board提供四条连续 wired IRQ并支持通知模式。

system wrapper同样组合一个核心 child，machine设置固定 MMIO地址、base IRQ、irqchip link与 riscv64的 56位 physical address size。realize把核心 registers暴露为 sysbus MMIO，若发现 PCI bus则安装同一 IOMMU hook，并建立 wired/MSI通知资源。

两个包装的发现方式不同：PCI封装由配置空间枚举，system封装由 FDT固定节点发现；核心 translation、queues、cache和 fault语义共享。把封装拆开能让 review聚焦 bus glue，避免复制两千多行 IOMMU逻辑。

## Reset 已实现，迁移尚未闭环

提交 [`9afd2671`](https://gitlab.com/qemu-project/qemu/-/commit/9afd26715ef4f887f5eaf2ecfe365a7837f2e500) 实现 RISC-V IOMMU reset protocol，对应[邮件记录](https://lore.kernel.org/qemu-devel/20241106133407.604587-7-dbarboza@ventanamicro.com/)。PCI与 sys wrapper都在 Resettable hold阶段调用公共 `riscv_iommu_reset()`。

reset把 DDTP恢复到用户选择的 OFF或 BARE初态，关闭 CQ/FQ/PQ与 busy/interrupt状态，清 debug busy、IPSR、context cache和 IOT cache。guest memory中的目录、页表和队列 buffer仍属于 RAM，reset只断开 IOMMU对它们的运行引用。

当前 `riscv-iommu-pci.c`的 VMState明确设置 `.unmigratable = 1`，DeviceClass还标 `hotpluggable=false`。使用 `--only-migratable`时应在 realize阶段拒绝。源码事实不允许本书声称 PCI IOMMU live migration已经支持。

system wrapper当前没有一份等价完整 VMState来保存核心寄存器、queue状态与 MSI表。它没有 PCI wrapper同样的显式 unmigratable marker，也不能由此推断迁移可用。缺少状态协议时应标开放问题，并用带活动映射/queue的实验验证未来实现。

cache可以丢弃重建，DDTP、queue head/tail、fault pending、MSI config、HPM和 debug状态需要明确分类。迁移设计还要停止所有 downstream DMA，保存 guest RAM中的表与队列，再按顺序恢复并 invalidate派生 cache。

## 逐步合入体现协议边界

基础提交先建立 S/G translation与 fault语义，随后 `9d085a1c`加 IOATC，`69a9ae48`加 ATS，`a7aa525b`加 debug。它们来自同一多版 review系列，却按协议边界拆分。最终源码保留这种分层。

可以作出强推断：维护者选择先让基础地址和权限正确，再加入 cache及外部设备缓存，最后提供调试；这样每个 patch的可审查不变量更清楚。推断来自提交顺序和说明，不能解读成所有未来 IOMMU功能必须采用同一拆分。

sysbus系列又把封装与核心分开，reset独立成后续 patch。这个历史提醒设备作者：能完成一次 translation，不代表 reset、发现、通知和迁移已经完成。功能声明要列协议面。

固定标签在基础之后还有大量修复和 HPM扩展。正文函数名以当前树为准，邮件中的早期字段若不一致只用于解释演进。读者复查先 checkout tag，再用符号搜索。

## 性能、安全与可观测性

IOMMU每次 miss可能读取 DDT、PDT和一到两阶段页表，访问次数高于直通。IOATC降低重复成本，细粒度 invalidation又有 CPU开销。测试应区分 hit rate、walk次数、queue处理和设备吞吐。

权限错误必须 fail closed。无效 context、保留位、越界 PTE、写只读页或 MSI配置错误都应返回 access error并记录适当 fault；静默 BARE会破坏隔离。`off`属性决定 reset后 DMA disabled还是 BARE，部署要明确选择。

guest控制的 queue base、tail、PTE与 MSI地址都是不可信输入。实现使用 AddressSpace API和 MemTxResult检查，不能将数值当 host pointer。fault报告也要避免二次越界。

tracepoint覆盖 context、translation、IOTLB、command、fault、ATS、MSI和 reset。调试先记录 device ID、process ID、IOVA、access direction与 stage，再看结果。只打印最终 GPA会丢失隔离身份。

FDT、`info pci`、`info mtree`和 IOMMU trace提供四个视图。BDF与 `iommu-map`不一致属于发现问题，BAR未 enable属于 PCI配置，context无效属于 IOMMU配置，PTE fault属于翻译。分层诊断可避免在错误文件里加日志。

## PCI 设备从枚举到可 DMA

QEMU realize PCI设备时先给它分配BDF或接受用户指定的addr，初始化配置空间并注册BAR。此时BAR只声明大小和类型，客户机还没有为它选择地址。GPEX root bus已经存在，ECAM读写才能到达该function。

firmware或RISC-V内核枚举vendor/device/class和capability，向BAR写全一探测size，再把分配地址写回。PCI core按mask保留可实现位，MemoryRegion alias随BAR配置映射到PCI memory space。command register的memory enable决定CPU访问是否解码。

bus master enable又控制设备是否允许发起DMA。驱动在BAR、MSI/MSI-X与IOMMU context准备好之后才应打开。QEMU设备若绕过PCI core直接访问RAM，会让command和IOMMU失去控制意义。

MSI-X table位于某个BAR范围，table entry保存message address/data与vector mask；PBA保存pending。设备自身寄存器、MSI-X table与IOMMU寄存器可能共享BAR0的不同offset。`riscv-iommu-pci`在BAR0组合这些区域，配置空间只发布资源，不复制核心寄存器。

PCIe reset会影响command、BAR/capability运行状态与设备core，system reset还覆盖host bridge。热拔需要先停DMA、注销IOMMU notifier、移除BAR映射，再释放BDF。当前RISC-V IOMMU PCI封装明确不可热插拔，相关代码路径不能当已支持接口。

## BAR、CPU MMIO 与 DMA 的完整往返

以一个RISC-V `virtio-blk-pci`为例，客户机CPU写notify BAR时，CPU物理地址经GPEX `ranges`进入PCI memory AddressSpace，再命中virtio-pci MemoryRegion回调。事务方向是CPU到设备，IOMMU不翻译这次寄存器写。

设备随后读取virtqueue descriptor，方向变成PCI requester到memory。PCI core根据function取得DMA AddressSpace；若root bus挂了RISC-V IOMMU，该访问进入per-device IOMMU MemoryRegion，IOVA经context和页表变成目标地址。

完成中断若用MSI，设备发起一笔message write。IOMMU context可能对MSI地址执行专门翻译或MRIF处理，最终到IMSIC file。若用INTx，则function拉高pin，经swizzle和GPEX输出进入PLIC/APLIC。两条中断路径不能用同一地址图解释。

因此一次请求至少有三类访问：CPU配置/notify，设备读写descriptor和data，设备发送completion。调试只看到BAR写成功，只能证明第一类；guest仍卡住时要检查DMA permission和中断投递。

IOMMU自己也要读取DDT/PDT、页表和queue。这些访问由模型的system AddressSpace执行，属于翻译器取元数据，并非被管理设备发起的新DMA。递归地再走同一IOMMU会造成循环，源码明确选择合适target AddressSpace。

## DDTP 模式切换是一项控制协议

DDTP给出device directory根与mode。OFF表示IOMMU阻止受管DMA，BARE表示不做地址翻译，目录模式决定DDT层数与device ID覆盖范围。reset属性可选择回到OFF或BARE，部署的安全默认由此不同。

driver应先在guest RAM构建并清理DDT/PDT和页表，写入合法context，再设置DDTP。目录已经启用时修改根或mode要遵守规范的busy与转换规则，并配合fence/invalidation。QEMU对保留位、对齐、physical address宽度和支持mode做校验。

OFF与BARE不能被当成同义“没有IOMMU”。OFF应让DMA失败，可用于启动隔离；BARE允许地址直通，适合明确无翻译的配置。错误处理若从非法DDTP静默退回BARE，会把管理错误变成越权访问。

mode决定device ID如何切分成多级索引。支持的层数不足以覆盖某个RID时，context fetch应报cause，不能截断高位并命中另一device。FDT `iommu-map`覆盖RID范围和DDT可寻址能力需要同时核验。

DDTP改变后，旧context cache和IOTLB条目不再属于新根。reset源码显式清缓存；运行时切换则依赖实现的寄存器处理和命令协议。测试要先填充旧映射，再切换根，才能发现陈旧命中。

## 走一遍 DDT 与 PDT

假设GPEX上的function具有requester ID `0x0100`。PCI IOMMU hook用该ID查找或创建`RISCVIOMMUSpace`，translate收到IOVA、读写类型和MemTxAttrs。`riscv_iommu_ctx_fetch()`先按DDTP mode拆分device ID，读取相应DDT entry。

device context提供translation control、stage roots、process-directory配置、地址空间标识、MSI与fault策略。实现先验证valid和保留位，再检查advertised capability是否允许这些组合。校验失败生成context相关fault，不能带着部分字段继续walk。

若事务带process ID且context启用PDT，代码按process ID读取process context。PID位宽受实现和MemTxAttrs承载能力限制。没有显式PID时走device规定的default process语义；把缺失属性等同任意进程零会破坏隔离。

context cache的key至少区分device与process身份，value包含已经校验的stage配置和标识。相同IOVA在两个RID下可以得到不同结果，缓存不能只按地址索引。driver修改DDT/PDT后必须发context invalidate。

目录项来自guest memory，可能跨页、不可读或在并发修改。AddressSpace读取返回MemTxResult，QEMU要把失败转换成规范fault而非使用未初始化buffer。driver通过先写完整entry、内存屏障、再置valid并invalidate来避免硬件观察半项。

## 用一个两阶段例子理解权限

设device context启用first-stage Sv39，把IOVA `0x40001000`映射到guest physical `0x90001000`，又启用G-stage x4页表，把它映射到system physical RAM。translate先完成S-stage，再以中间结果进入G-stage，最后返回目标AddressSpace、translated address、page mask与permission。

S-stage叶子允许读写，G-stage叶子只读时，最终permission仍只读。写DMA必须失败。任一阶段的U、A/D、valid、leaf格式或地址宽度不满足，都不能由另一阶段的允许位补救。

superpage要求低PPN按层级对齐。若PTE声称大页却含非法低位，安全做法是fault；把它向下对齐会映射到客户机未请求范围。返回的page mask也必须匹配实际leaf和NAPOT语义。

G-stage x4根比普通页表多地址位和对齐要求，不能把CPU Sv39 helper参数原样套入。IOMMU实现可以复用页表算法概念，context字段、fault cause和transaction type仍是DMA协议自己的。

页表walk读取PTE本身可能失败，leaf指向的最终RAM访问也可能失败。前者是translation fault，后者是target MemTx failure；日志和FQ应尽量保留区别。只输出最终“DMA error”会增加定位成本。

## Fault cause 是客户机调试接口

context无效、DDT/PDT访问错误、page table无效、permission不足、地址越界、MSI配置错误和command queue错误属于不同cause。driver会依据cause决定修表、禁用设备或报告硬件故障，QEMU不能任意折叠。

fault record还包含device ID、transaction type、IOVA以及可选process信息。两阶段场景需要表达错误发生在哪个stage和相关地址。record写入FQ后更新tail与interrupt pending，队列满则设置overflow状态。

报告策略可由device context控制。某类fault不入FQ，不表示访问成功；translate仍向设备返回拒绝。测试同时校验目标buffer未修改、设备完成错误和FQ，避免把“没有record”误当直通。

fault本身的queue写也可能遇到guest memory错误。实现要设置FQCSR相关状态并停止或继续按规范处理，不能递归生成无限fault。错误路径必须有上界。

安全审计可为每个cause建立最小输入：无效DC、只读PTE写入、非法superpage、越界PID、坏MSI PTE。预期cause、identity与side effect都明确。只做一例invalid PTE覆盖不足。

## Command Queue 是失效执行器

guest在RAM建立command ring，写base和控制寄存器，推进tail。IOMMU读取从head到tail的命令，验证opcode、保留位与参数，执行后推进head。enable、busy、memory fault和illegal command状态对guest可见。

IOTINVAL可以按地址空间标识和IOVA筛选translation cache，DDT/PDT invalidate作用于context cache，ATS命令还要通知device cache。范围越细，减少的cache抖动越多，匹配条件也越复杂。

IOFENCE让driver知道此前页表写与失效何时完成。它可以要求写completion或发送interrupt，形成软件可等待的边界。QEMU事件循环按顺序处理命令，不等于可以省略fence的可见性语义。

command queue memory由guest控制。head/tail环绕、size、entry对齐、base范围与读取MemTxResult都要检查。非法tail不能让模型在host无限循环；单次处理可以有budget并重新调度。

reset关闭queue、清busy和interrupt状态，并丢弃派生cache。guest RAM里的旧commands仍在，重新enable前driver要重新初始化head/tail。QEMU不替guest擦除buffer。

## Cache key 与 invalidation 矩阵

context cache命中维度包含device/process身份和与context选择有关的标识；IOTLB还包含IOVA page、access或permission、stage标识以及address-space ID。实现可以选择key编码，语义上不能让不同保护域碰撞。

全局invalidate清得最多，容易正确但代价高；按device清理一块设备；按process清理同设备内地址空间；按GSCID/PSCID和IOVA进一步缩小。每一种命令flag组合都需要正反测试：目标entry失效，相邻保护域继续命中。

permission upgrade和downgrade都需要invalidate。upgrade漏失效表现为旧拒绝，主要影响可用性；downgrade漏失效保留旧写权限，属于隔离缺陷。测试优先覆盖downgrade。

cache entry的mask决定一个命中覆盖多少地址。invalidate单页时，若命中的是superpage，要按规范选择删除整entry或切分；保留覆盖目标页的旧entry不可接受。NAPOT又增加非普通粒度。

IOATC容量属性影响替换与性能，不应改变正确性。设置很小容量可以强制eviction并验证重walk；设置零或边界值要按property约束处理。性能实验要记录容量，否则不同运行结果无法比较。

## FQ、PQ 与中断形成第二条环

Fault Queue由IOMMU生产、driver消费；Page Request Queue也由设备/IOMMU侧写入，软件处理后提交page response。它们与virtqueue类似都有base、head、tail和通知，却使用RISC-V IOMMU规定的entry与控制寄存器。

队列full不能覆盖尚未消费record。模型设置overflow或memory fault状态，保留可诊断信息，并按规范停止相应写入。driver清错和推进head后才能恢复。覆盖旧record会让隔离故障无声丢失。

通知pending与队列内容是两种状态。driver可能mask interrupt而queue继续增长；迁移若只保存线电平会漏record，reset若只lower线又保留queue控制会重新触发。公共core和封装要各自处理寄存器与外部投递。

PQ服务按需页面与PRI。请求携带device/process和地址，软件映射页面后回复。当前QEMU核心有相应路径，不代表任意RISC-V guest、PCI设备和vhost backend组合都能触发；运行结论需要capability与driver证据。

压力测试可把队列设为最小合法size，连续制造不同fault直到full，再消费一条、清状态并再次注入。检查record顺序、tail环绕、overflow与IRQ次数。该测试比单个fault更接近真实控制协议。

## ATS 引入分布式缓存一致性

未启用ATS时，设备每次DMA经IOMMU translate，旧映射主要存在IOMMU IOATC。启用ATS后，PCI function可以请求translation并缓存结果，后续发translated request。IOMMU不再看到每次原始IOVA查找。

软件撤销映射时要先阻止新使用或按协议发invalidation，让设备删除条目并等待completion，再允许页面复用。只清QEMU IOMMU hash table无法触及设备缓存。命令队列和PCI ATS消息共同完成闭环。

ATS请求也带requester/process identity，响应包含成功、permission或fault。device context和PCI capability双方允许后才能用。QEMU IOMMU advertised capability、具体PCI设备实现与guest driver协商是三项独立条件。

vhost数据面若缓存IOTLB，QEMU还要把map/unmap传给backend。它与PCI ATS device cache概念相近，接口不同；报告应分别写“guest-visible ATS”和“backend IOTLB”。混称会漏掉一侧ack。

测试撤销权限时，先证明旧translation确实进入cache，再改PTE、执行完整invalidations，最后重复相同IOVA写。目标页不能被修改，fault/response符合路径。没有cache warmup的测试无法证明失效命令生效。

## MSI 重映射需要单独的威胁模型

普通DMA主要威胁RAM机密性和完整性；MSI写可让设备选择hart、privilege或guest interrupt file，越权会导致中断注入和拒绝服务。MSI page table与pattern匹配限制设备能够投递的目标。

IOMMU判断目标地址是否进入MSI范围，读取MSI PTE并验证mode、valid、目标和ID。basic模式转换为目标message write，MRIF模式更新内存resident file并发送notice。每个分支都要返回正确fault。

MRIF内存更新本身是DMA样式写，notice又走IMSIC地址。顺序要保证interrupt handler看到与通知对应的pending内容。并发设备更新同一MRIF还涉及原子位操作，不能用普通load-modify-store丢事件。

IOMMU自身的FQ/CQ/PQ通知可能使用PCI MSI-X或system wired IRQ。它与“下游设备的MSI被IOMMU重映射”方向相反。trace中都出现MSI字样时，先标source object和vector。

测试可以给device context配置一个允许ID范围，再请求范围内与范围外interrupt。合法消息到达指定IMSIC file，非法消息生成fault且不改变其他file。只检查CPU收到某个中断无法证明重映射隔离。

## PCI 与 system 封装的差异清单

PCI封装通过BDF和class code发现，BAR0承载核心寄存器与MSI-X资源，并在PCI bus安装IOMMU hook。FDT的`iommu-map`把RID区间指向对应PCI IOMMU节点。设备当前标记不可热插拔、VMState明确unmigratable。

system封装位于`virt_memmap`固定MMIO，FDT直接发布compatible、reg与四条wired IRQ。machine设置irqchip link和riscv64 physical address size；若存在GPEX bus，它同样为PCI DMA安装公共core hook。

两个wrapper组合同一`TYPE_RISCV_IOMMU` child，属性alias把用户选择送入core。公共translate、queues、cache、debug和reset减少语义分叉；bus realize、发现、中断和迁移仍各自实现。

PCI wrapper的显式unmigratable是确定事实。system wrapper缺少等价完整VMState，也没有同样marker；这只能得出“尚无闭环证据”。用不存在marker推断支持属于逻辑错误。

若未来补迁移，core需要一份共享状态协议，wrapper另存MSI-X或wired通知状态，并保证bus hook和cache在post-load重建。实现前这仍是开放设计，不写成当前路线承诺。

## Reset、拔电与迁移的 IOMMU 顺序

system reset到来时，下游设备可能仍有DMA。平台应先阻止新事务或让所有设备进入reset，再清DDTP、queues、interrupt和cache。Resettable hold阶段调用公共reset，配合树顺序处理跨对象影响。

只清IOMMU cache却让device继续使用ATS或vhost IOTLB旧项，会在reset窗口绕过新状态。相关device cache与backend listener需要纳入整体协议。当前实现覆盖多少组合要按具体transport验证。

热拔IOMMU比普通function困难：root bus上的所有requester正在依赖其AddressSpace。固定PCI类型禁止hotplug避免了未定义切换；system IOMMU又由machine固定创建。这个限制体现生命周期完整性优先。

迁移则要保留任意DDTP、queue head/tail、interrupt、HPM和debug状态，冻结downstream DMA，保存guest RAM表，再在目标重建listener与cache。当前明确缺口使“reset可用”不能延伸成“迁移可用”。

管理层使用`--only-migratable`可以让PCI封装在启动时拒绝，提前暴露限制。system封装还需显式策略或测试，不能依赖同一开关自动发现没有声明的状态。

## 并发修改页表时谁负责一致性

guest CPU在RAM写PTE，设备线程同时DMA，IOMMU只能观察规范允许的顺序。driver应先阻止相关DMA或构造新表，使用内存屏障，再发布PTE和invalidation/fence。QEMU不应通过每次重读掩盖缺少协议。

页表entry可能跨host cacheline，规范的原子宽度和对齐决定IOMMU是否可见半写。实现读取固定宽度并检查MemTxResult，guest写入仍需按RISC-V内存模型发布。测试用普通用户态store而不做fence，结果不具可移植性。

IOMMU command处理、DMA translate和reset可能在不同QEMU执行上下文。cache hash table、queue head/tail与interrupt状态需要遵守BQL/AioContext约束或加锁。源码审计应从调用者确认，而非看到`static`函数就假定串行。

debug translation接口与真实DMA并发时也读取同一context/cache。它应返回一个合规时刻的结果，不提供跨多个guest写的事务快照。调试工具要先quiesce设备再比较，避免把合法竞态报成模型错误。

## 分层测试矩阵

PCI层先测ECAM枚举、BAR size/enable、bus master、INTx和MSI，不启用IOMMU。这样可以证明设备与GPEX基本路径。随后加入IOMMU BARE，确认hook存在但地址不变；再启用一阶段和两阶段映射。

翻译层覆盖读、写、execute不适用的处理、4 KiB、superpage、两阶段permission交集、context/process identity与fault。cache层覆盖cold/hit、细粒度invalidate、downgrade和eviction。

控制层覆盖CQ非法命令、FQ/PQ full、interrupt mask、debug request与reset。扩展层覆盖ATS失效、MSI remap、MRIF和vhost IOTLB，只有环境支持时才标运行通过。

最后审计迁移和热插限制。PCI IOMMU预期`--only-migratable`拒绝；system wrapper标静态缺口；两者reset应回到配置的OFF/BARE并清派生状态。不要用一个Linux启动结果替代四层测试。

每份报告列固定tag、riscv64 machine参数、accelerator、IOMMU wrapper、guest driver和trace事件。源码静态路径、运行观测与作者推断分栏，后续版本改变时容易定位需要更新的结论。

## 寄存器页是 guest 与模型的控制面

RISC-V IOMMU核心创建一段寄存器MemoryRegion，读写callback按offset处理capability、fctl、DDTP、queue、interrupt、performance和debug寄存器。wrapper决定这段region出现在PCI BAR还是固定sysbus MMIO，核心语义一致。

只读capability由实现属性与已编译功能生成，guest写入应被忽略或按规范处理。WARL字段只接受支持值，W1C字段清相应状态，busy/enable之间有状态转换。把寄存器数组当普通RAM会跳过全部副作用。

64位寄存器在riscv64驱动中可一次访问，也可能拆成受支持宽度。MemoryRegionOps要规定合法size、alignment与endianness；callback对不支持宽度返回guest error。PCI配置端序规则与RISC-V CPU普通load的host端序无关。

queue base通常编码地址、size与保留位，写入时先验证再生效。enable后对base的写是否允许由规范状态机决定。模型不能在运行queue时无条件替换指针，让旧处理callback访问新ring。

寄存器trace应输出名称、旧值、新值与拒绝原因，避免只打印offset。敏感页表内容不需要大段转储，identity和地址足以复盘。

## Capability 是承诺，不是装饰

`intremap`、`ats`、page-table mode、process ID宽度、MSI模式、queue与debug等capability会决定guest driver启用哪些路径。广告一位意味着寄存器、context校验、data path、fault、reset与必要迁移状态都要实现。

QEMU property可以关闭某些能力，用于兼容或测试。关闭后capability bit、context接受范围和运行分支要一致；仅隐藏bit却仍接受配置会制造不可测试暗路径，仅拒绝data path又会让driver在晚期遇错。

physical address size限制DDT/PDT/PTE与目标地址。system wrapper由machine为riscv64设置相应值，PCI wrapper也有核心属性。地址超宽应在context或walk阶段fault，不能静默截断。

capability组合还存在依赖：ATS需要相应PCI/queue支持，MRIF依赖interrupt remapping，process context需要PDT mode。实现验证依赖比guest driver假设更可信，因为恶意guest可以绕过正常驱动。

兼容审查要比较旧新capability。新增bit通常是opt-in，删除或收窄会让旧guest配置失败；默认property变化也会影响迁移目标。当前PCI wrapper不可迁移，平台启动兼容仍需考虑。

## ASID、PSCID 与 GSCID 防止缓存串域

页表根地址相同不必代表同一地址空间。软件可能复用物理页作为不同进程或guest的页表，PSCID/GSCID类标识让cache与invalidation区分语义域。context携带这些标识，translation entry继承。

first-stage IOVA与second-stage中间地址可能数值相同，stage和ID不同。IOTLB key若只含page number，会让一个guest或进程命中另一方结果。cache实现的结构细节可以变化，保护域维度不可省。

软件回收ID前要失效旧条目并等待fence，再把ID分配给新页表。QEMU不应根据root pointer碰巧改变自动猜测回收；真实协议依赖显式命令。测试先warm旧ID、重用并映射不同页，检查无陈旧命中。

细粒度invalidation按ID过滤，错误地清多了主要损失性能，清少了会跨域。正向测试目标entry被删，负向测试相邻ID保留，两项都需要trace或walk计数支持。

## Page walk 的内存访问也受错误约束

IOMMU读取PTE要计算每级index、entry地址和剩余层级，检查加法溢出与physical address size。目录根合法，不代表后续non-leaf PPN合法。每一级都通过AddressSpace读取并检查结果。

non-leaf PTE不应带只允许leaf的组合，leaf R/W编码要符合RISC-V规则。A/D位处理按IOMMU支持方式执行，若不自动更新则产生fault。写A/D又是一笔guest memory写，需要处理只读或失败。

superpage与NAPOT影响输出地址拼接。来自IOVA的低位、PTE的PPN和stage扩展位按规格组合，任一mask错误可能扩大映射。单元测试应使用边界地址和相邻页不同权限。

两阶段walk中，读取first-stage页表的guest physical地址本身可能需要G-stage转换。实现要按规范选择适用stage，而非直接用system address绕过guest隔离。错误记录也要表明是page-table access还是最终data access。

debug接口复用walk有助于一致性，仍要确保它不会更新正常HPM、A/D或fault queue到规范不允许的程度。调试请求的副作用从当前源码和规范逐项核对。

## HPM 计数属于可观察运行状态

IOMMU硬件性能监控可以按事件、device/process或其他筛选统计translation、walk、fault等。counter与selector由guest配置，overflow可能触发通知。它们不是纯host调试变量。

实现每个data path更新点要与event定义一致，cache hit与miss不能重复计数。多线程DMA下counter更新需要原子或串行保证，溢出宽度按寄存器mask处理。

reset应清selector、counter与overflow状态到规范初值。迁移若要支持，活动counter和selector需要保存；当前wrapper迁移未闭环，这些字段是缺口清单的一部分。

性能实验可用HPM区分cold walk、IOATC hit和fault，而外部trace用于校准。先验证一个可预测的小请求数，再用于吞吐分析；未经校准的counter值不能当设计结论。

HPM capability是否在固定tag及具体property下启用要从CAP和源码确认。正文不把存在结构体字段扩大成guest始终可见。

## Debug translation 的操作流程

driver或调试工具先写请求IOVA与控制字段，包括device/process identity和访问类型，再置GO。模型标busy，调用与正常DMA相同的context fetch和translation，最后写response并清busy。

response包含成功地址/permission或fault信息。它适合验证DDT/PDT与页表，无需让真实设备构造请求。若身份或attrs与真实PCI transaction不同，debug成功仍不能证明device data path。

busy期间再次写GO、修改输入或reset，要按寄存器规则处理。reset提交显式清debug busy，防止重启后保留一笔旧请求。并发页表修改产生的结果只代表某个观察时刻。

安全工具可把debug结果与预期映射表逐页比较，再用真实DMA抽样。两者不一致时优先查RID/PID、bus master、IOMMU listener、cache invalidation与访问方向。

## PCI IOMMU hook 的创建和销毁

PCI core为bus设置IOMMU ops后，设备请求DMA AddressSpace时按devfn取得per-device空间。`riscv_iommu_pci_setup_iommu()`把root bus关联到核心，按requester需要创建`RISCVIOMMUSpace`和IOMMU MemoryRegion。

space对象记录device identity并进入核心维护的列表，translation callback从MemoryRegion定位core/context。设备移除或IOMMU销毁时，notifier、cache与region引用必须先断开，防止DMA线程进入已释放core。

同一bus只能有一致的默认IOMMU语义。system与PCI wrapper都试图安装hook时，machine/plug逻辑限制组合。后安装覆盖前安装会让早期设备持有旧AddressSpace，形成分裂保护域。

设备realize可能在IOMMU之前或之后发生，PCI core的hook接口要为已有和新设备提供一致视图。`virt`提前建立PCI节点骨架与plug逻辑，正是动态设备发现时序的一部分。

测试先创建设备再添加允许的IOMMU组合，再反向顺序，比较`vdev->dma_as`路径。当前不可热插IOMMU限制了运行时案例，启动阶段顺序仍值得审计。

## Queue 通知从 core 到 wrapper

核心CQ/FQ/PQ状态产生“有工作/有错误”条件，wrapper把它变成wired IRQ或MSI-X vector。core保存pending/source，wrapper保存transport相关mask/table，目标CPU或IMSIC保存最终投递。

PCI封装给不同事件分配MSI-X资源，guest可单独mask。vector被mask时PBA保留pending，解除后投递。system封装使用连续wired IRQ或内部MSI选择，FDT发布对应specifier。

ack/clear寄存器只清规定pending，队列中未消费entry可能再次形成条件。driver处理顺序通常先读状态和record，再推进head并clear。QEMU要避免clear与新record并发造成lost interrupt。

reset清core pending和wrapper通知状态，PCI通用reset还处理MSI-X。迁移需分别保存；当前限制说明这条链没有可宣称的完整实现。

观测时记录queue tail、CSR pending、wrapper vector和IMSIC/PLIC状态。CPU没有进入handler，可能是任一层mask，不应只在IOMMU core加重复notify。

## Driver 更新映射的安全配方

建立新映射时，driver先写完整PTE与必要context，执行RISC-V内存屏障，再提交针对identity/address的invalidate或fence，最后允许device启动DMA。若此前地址不存在，仍要考虑negative cache。

撤销映射更敏感。先停止设备产生新请求，等待或记录已有I/O；清PTE/permission并发布；失效IOMMU IOATC；若ATS或vhost IOTLB存在，再失效外部cache并等completion；完成fence后才复用物理页。

改变DDT/PDT context也要先让旧identity quiesce，更新entry并做context invalidate。只发IOTINVAL可能保留旧页表根。改变G-stage时还要按GSCID范围处理。

这个配方是对协议依赖的作者整理，具体命令flag与先后必须以RISC-V IOMMU规范和driver实现为准。正文用它解释为什么QEMU有多类invalidate，不能替代规范伪代码。

故障注入可故意省略其中一步，预期观察陈旧映射风险；这类测试只在隔离的临时guest进行，不用于生产数据。正确性测试最终必须执行完整序列。

## vhost IOTLB 把边界延伸到另一个执行体

virtio PCI设备通过RISC-V IOMMU后，QEMU普通数据面每次访问使用DMA AddressSpace。vhost接管时，backend不能调用同一用户态translate函数处理每个descriptor，QEMU通过IOMMU notifier把map/unmap转换为backend IOTLB消息。

memory table先授权可共享GPA范围，IOTLB再授权该device IOVA到GPA及读写permission。backend必须同时检查。只更新memory table不会撤销一条旧IOVA mapping。

invalidations有顺序与ack要求。guest完成IOFENCE之前，QEMU、backend和可能的device ATS cache都要达到规定状态。backend断开或不支持协议时，应让feature协商或I/O失败，不能回退为未经翻译的GPA访问。

迁移还要停backend DMA、同步dirty log、保存virtqueue/in-flight，目标重新注册IOMMU listener并建立初始IOTLB。第19章的控制面与本章的地址隔离在这里会合。

仓库已经提交正向 DMA guest、initramfs 构建脚本、trace 解析器与合成故障单测。运行环境若缺少兼容内核、静态 RISC-V 工具链或 IOMMU 设备支持，只能完成源码闭环、能力探测和解析器测试，不能写成已经观察到 live IOTLB 消息；合成故障行也不能替代真实客户机负向访问。

## 拒绝服务与隔离缺陷要分开

恶意guest可以让CQ持续非法、制造FQ full、频繁invalidate或构造深页表walk，消耗QEMU CPU。模型需要budget、边界与错误停止，性能防护属于拒绝服务面。

更严重的是越权：RID碰撞、permission合并错误、superpage mask过大、stale downgrade、MSI目标未验证。这些会让设备访问未授权RAM或interrupt file，测试优先级高于性能。

fault record可能泄露其他保护域地址，identity与response要来自当前transaction，不可复用未清结构。日志也不应输出host pointer或别的VM内容。

输入fuzz可从寄存器状态机、DDT/PDT/PTE、command entry、MSI PTE和queue head/tail六类生成。每次设置处理budget与临时RAM，断言QEMU不崩溃、目标buffer越权不变、fault有界。

安全结论按威胁模型写：本章假设guest与设备输入不可信，host管理配置受控。独立backend和host内核又有各自信任边界，不由IOMMU模型单独解决。

## 用历史系列解释功能拆分

基础提交`0c54acb8`及对应邮件先合入核心S/G translation与fault，后续`9d085a1c`加入IOATC，`69a9ae48`加入ATS，`a7aa525b`加入debug。顺序是可核验历史。

从顺序可推断review把基础正确性、缓存一致性、外部device cache和调试接口分成可验证协议面。该推断由patch边界支持，未来系列可以采用不同拆法，不能当硬性上游规则。

sysbus提交`5b128435`复用既有PCI核心，邮件说明保留core设计并增加platform通知；reset提交`9afd2671`独立补协议。它们说明wrapper发现与公共translation可以分别评审。

历史搜索还要跟随fixup。最终tag可能包含基础提交之后的边界修复，正文函数行为以最终tree为准。只读首版邮件会漏掉修订；只读当前代码又看不到为什么分层。

## IOMMU 补丁的评审模板

先画身份和地址：RID/PID、IOVA、S-stage中间地址、G-stage目标、MSI地址与最终AddressSpace。每次转换标permission、mask与fault owner。

再查控制协议：capability、context validation、CQ命令、invalidate/fence、FQ/PQ、ATS/debug/HPM。新增feature必须连到每一项适用路径，保留位和非法组合也要测试。

第三步查生命周期：realize wrapper与core、bus hook、reset、hotplug限制、migration VMState/blocker、unrealize和listener。data path通过不表示对象能够安全停止。

第四步查平台：GPEX BDF、FDT `iommu-map`、IRQ/MSI到IMSIC、system/PCI wrapper互斥、riscv64 physical address size。核心单测不能覆盖machine接线。

最后对照GitLab最终commit与lore最终邮件，把事实、上游陈述、作者推断、开放问题分栏。每个运行结论附fixture和trace；没有fixture则停在静态审计。

## 一笔非法写 DMA 的取证样例

设BDF `01:00.0`对应RID `0x0100`，driver为它建立device context，IOVA `0x40001000`经两阶段映射到一页RAM，但最终permission只有读。设备尝试写64字节时，PCI core把事务送进该RID的IOMMU AddressSpace。

取证第一步确认identity：`info pci`中的BDF、FDT `iommu-map`覆盖区间、IOMMU trace中的device ID三者相同。若不同，错误位于platform发现或hook，暂不分析PTE。

第二步确认context：DDTP mode、DDT entry valid、PDT是否启用、PSCID/GSCID与root。context cache trace若命中，也要确认命中key属于该RID。context fault到此结束，不会进入leaf permission。

第三步记录S-stage leaf与G-stage leaf，分别写地址、level、R/W和page mask。最终写权限取交集为false，translate返回拒绝。目标RAM的哨兵值必须保持，设备收到MemTx error或相应完成。

第四步检查FQ record包含write transaction、RID、IOVA与正确cause，tail推进且通知到达。若context策略抑制record，仍要求DMA失败，并在报告中说明没有FQ是配置结果。

随后把最终PTE改为可写，执行完整invalidation/fence，再重试同一请求。成功写入证明设备和目标buffer基本路径，前一轮失败可归因于permission。若不做成功对照，BAR、bus master或backend问题也可能产生相似超时。

## Reset 状态逐项核对

公共`riscv_iommu_reset()`把DDTP恢复到property选择的OFF或BARE，关闭并清理CQ/FQ/PQ控制与busy，清interrupt pending、debug busy、context cache和IOT cache。wrapper在Resettable hold调用它，是固定源码事实。

guest RAM中的DDT、PDT、PTE和queue buffer不会被擦除；它们属于RAM内容。reset后driver可选择复用并重新发布，也可以重新初始化。旧tail/head和enable不应自动继续消费旧command。

PCI配置空间与MSI-X还有PCI层reset，system wrapper有wired IRQ状态。公共core清零不能替wrapper处理外部通知。实验同时看core register、PCI/PBA或wired线。

HPM、MSI table、fault policy等字段是否全部由当前reset覆盖，应按函数逐项与结构体比对。书中已列明确项，未逐项证实的字段不使用“全部恢复”表述。

reset后进行两次探测：不重新配置时DMA按OFF/BARE策略；重新建立context后合法DMA恢复。第一步验证清理，第二步验证对象和bus hook仍可用。

## 当前迁移开放问题清单

需要序列化的架构状态至少包含DDTP与feature controls、CQ/FQ/PQ寄存器和head/tail、interrupt mask/pending、MSI/MRIF配置、debug请求、HPM selector/counter以及wrapper通知状态。具体字段以最终实现审计为准。

可丢弃派生状态包括context cache与IOTLB，目标必须从guest RAM重建。丢弃前要让下游DMA停止，目标运行前要防旧backend IOTLB残留。cache不进流也需要生命周期协议。

guest RAM中的目录、页表和queue entries由RAM迁移承载，但与IOMMU寄存器快照要来自同一停机边界。源端保存tail后仍执行command，会让目标重复或漏执行。

PCI wrapper已用`.unmigratable=1`给出明确答案。system wrapper的开放问题包括缺少完整VMState、wrapper IRQ状态和管理层阻止机制。未来实现需有活动mapping、queued fault、ATS/IOTLB和reset后的组合测试。

这份清单是从当前结构和协议推导的设计审计，不是已接受上游方案。后续版本若加入VMState，要逐项对照实际fields与邮件review，再更新结论。

## 规范、驱动与 QEMU 三方对照

RISC-V IOMMU规范定义寄存器、context/PTE格式、命令、fault和顺序；guest驱动决定何时分配表、发布entry、invalidate与处理queue；QEMU实现这些硬件可见效果。三方使用相同名词，责任不同。

发现故障时先判断层次。driver写了非法保留位，QEMU应按规范拒绝；QEMU广告未实现capability，属于模型缺陷；driver漏fence后看到旧cache，未必是模型错误；规范留有选择时，QEMU要在capability或文档表达选择。

上游邮件可解释实现选择和被拒方案，最终commit说明当前取舍，规范仍是协议判据。邮件中的早期草案若对应旧规范版本，不能覆盖固定tag源码与最终binding。

本书示例把每项结论标成源码事实、上游陈述、作者推断或开放问题。读者复核时可用规范章节检查语义，用driver trace检查命令顺序，用QEMU trace检查模型分支，避免只在一个仓库内自证。

部署还要显式选择reset后的DDTP策略。OFF让未配置设备DMA失败，便于先建立隔离再启动；BARE允许直通，兼容性较好却扩大错误配置影响。选择由威胁模型和boot顺序决定。

启动日志应记录property、CAP、实际DDTP mode与driver是否接管。只写命令行意图不足以证明硬件进入对应状态。system与PCI wrapper的发现方式不同，guest最终绑定结果也要记录。

任何“默认安全”结论都限定固定tag与明确property。未来默认变化、firmware预配置或管理层自动加设备，都需要重新检查DMA在driver加载前的行为。

最后把合法直通、翻译成功、权限拒绝、context错误和queue错误各保存一条最小trace。五条基线比一份长日志更适合版本差分，也能证明错误分类没有因重构被折叠。

## 实验一：映射 PCIe 拓扑

::: {.hands-on}
配套英文实验手册：[`map-pcie-topology`](../experiments/part-04-machine-and-device-models/chapter-18-pcie-and-riscv-iommu/map-pcie-topology/README.md)。

在 `virt`上挂一个明确 BDF的 `virtio-blk-pci`或其他可用 PCI设备，启动 monitor并保存 `info pci`、`info qtree`、`info mtree -f`和自动 FDT。记录 bus/device/function、配置空间、BAR大小/分配值、ECAM、低/高 MMIO与 INTx/MSI路径。

若有 RISC-V Linux客户机，再用 `lspci -vv`对比。区分 firmware与 kernel分配资源，避免把一次 BAR值当固定 platform ABI。预期四份视图关系一致，路径和表示形式不同。
:::

## 实验二：跟踪一次 IOMMU 翻译与 fault

::: {.hands-on}
配套英文实验手册：[`trace-iommu-translation`](../experiments/part-04-machine-and-device-models/chapter-18-pcie-and-riscv-iommu/trace-iommu-translation/README.md)。

英文手册已经提供正向 DMA guest fixture：兼容的 RISC-V Linux 由 IOMMU driver 配置 device context 和 IOVA 映射，静态用户态探针经 E1000E 发送固定数量的数据报，脚本同时开启 `hw/riscv/trace-events` 中实际存在的事件。运行后把探针计数、BDF、IOVA 和翻译地址关联起来，证明的是这一次正向路径。

负向 live fault 需要另行审查的内核注入补丁：撤销写权限或置无效 PTE，执行规范要求的 invalidation 后重试。仓库自带的合成 fault 只校验解析器把 translation 与 fault 分开计数，不证明客户机真的进入 FQ。若运行前提不足，就执行可复现的源码分支，从 `riscv_iommu_memory_region_translate()` 跟到 context fetch、`riscv_iommu_translate()` 与 fault record，并明确把结果标为静态审计。
:::

## 实验三：验证 reset 与不可迁移边界

::: {.hands-on}
本实验复用 [`map-pcie-topology`](../experiments/part-04-machine-and-device-models/chapter-18-pcie-and-riscv-iommu/map-pcie-topology/README.md) 建立设备与 BDF，状态观察步骤参照 [`trace-iommu-translation`](../experiments/part-04-machine-and-device-models/chapter-18-pcie-and-riscv-iommu/trace-iommu-translation/README.md)；入口见[第 18章英文实验索引](../experiments/part-04-machine-and-device-models/chapter-18-pcie-and-riscv-iommu/README.md)。

启用 `riscv-iommu-pci`，建立非默认 DDTP、queue和 cache状态后执行 system reset。预期 DDTP回到配置的 OFF/BARE，queues停止，IPSR与 cache清空，PCI对象仍存在。随后用 `--only-migratable`启动同一设备，记录固定标签因 `.unmigratable`拒绝。

system IOMMU不应因缺少显式 marker就写成可迁移；对它只记录当前 VMState搜索结果与开放问题。实验结论分别标“reset已验证”“PCI迁移明确阻止”“sys迁移未证明”。
:::

## 源码和上游审查清单

PCI侧先画 BDF、ECAM、BAR、CPU窗口、DMA AddressSpace和 IRQ/MSI。IOMMU侧再标 device/process identity、S/G root、permission、cache和 queues。不要用“地址”一个词覆盖六种命名空间。

新增 capability时检查寄存器广告、context validation、data path、commands/invalidation、fault、reset、debug、migration和 tests。只设置 CAP bit会让 guest启用未实现路径。

引用邮件时写清 patch版本和最终 commit。基础、sysbus与 reset系列有对应 lore链接；固定源码决定当前字段。作者对拆分动机的解释明确标为强推断。

迁移能力以 DeviceClass VMState与活动状态测试为准。当前 PCI封装明确 unmigratable，system封装没有闭环证据。开放问题不使用模糊的“应该可以”。

## 小结

GPEX让 RISC-V `virt`拥有可枚举 PCIe fabric，ECAM、BAR与 CPU MMIO窗口解决发现和寄存器访问；DMA则带 requester/process身份进入设备 AddressSpace。RISC-V IOMMU从 DDT/PDT取得上下文，执行 S/G两阶段翻译、权限检查与 fault记录。

IOATC、ATS、queues、debug和 MSI/MRIF在基础模型之后逐步加入。历史拆分展示了工程顺序：先证明地址与 fault，再扩大 cache和设备协作；PCI与 sysbus包装共享核心，machine负责 FDT和 IRQ。

固定标签已经实现 reset protocol，PCI IOMMU仍明确 unmigratable，system IOMMU也没有可确认的完整迁移状态。下一章把一个 virtio请求放进这套 PCI/IOMMU地址空间，再观察 vhost把 descriptor消费和 DMA移入内核后，QEMU还要维护哪些 feature、memory table、IOTLB、dirty log和 in-flight状态。
