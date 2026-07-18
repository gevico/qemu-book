# 外设状态机、时钟、Reset 与 VMState

一段 UART写看起来只是在 `0x10000000`附近写一个字节。设备模型要解释寄存器 bank、DLAB复用、FIFO、发送时序、字符后端、IRQ mask与 pending；reset可能在字符尚未发送时到来，迁移可能发生在 FIFO timeout之前。寄存器回调只是入口，真正的设备是一组跨线程、timer、总线和迁移阶段保持一致的状态机。

本章仍限定 RISC-V/riscv64，平台实例使用 `virt`的 16550A UART、Goldfish RTC、PLIC/APLIC/IMSIC。源码事实锚定官方 GitLab [`v11.1.0-rc0`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0) 的 `eca2c162`，主要阅读 [`hw/char/serial.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/char/serial.c)、[`hw/char/serial-mm.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/char/serial-mm.c)、[`hw/rtc/goldfish_rtc.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/rtc/goldfish_rtc.c)、[`hw/core/resettable.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/core/resettable.c) 与 RISC-V irqchip文件。

## 本章目标

- 从寄存器规格建立持久状态、派生状态与外部副作用；
- 跟踪 instance、property、realize、reset、unrealize和 finalize的边界；
- 理解 Resettable的 enter、hold、exit以及 qbus reset树；
- 解释虚拟时钟、timer deadline、异步 completion与取消顺序；
- 用 Serial、RTC、PLIC/AIA的 VMState审查迁移 ABI和实现所有者。

## 先列客户机能观察什么

设备状态结构不应机械复制寄存器表。客户机能写入一个寄存器，最终状态可能是屏蔽后的控制位、被清除的 pending位或一次异步动作；客户机能读取的某个寄存器，也可能由 FIFO是否为空、后端连接和当前时钟即时计算。建模前先列观察点，比按偏移创建同名字段可靠。

第一类是持久寄存器状态，例如 UART的 IER、LCR、MCR、SCR和波特率除数。它们会影响未来访问或输出，reset有规范默认值，迁移通常要保存。第二类是队列状态，例如接收/发送 FIFO、读写指针和正在移出的字符；客户机可以从状态位和数据顺序观察，也要进入迁移。

第三类是派生状态。UART LSR的某些位可以从 FIFO与发送器状态计算，IRQ输出可从多个 pending来源与 mask计算；直接保存 irq line电平容易与目标重算冲突。第四类是宿主资源：chardev指针、timer对象、event source ID和 QOM link。它们不能作为原始指针迁移，目标按配置重建。

第五类是外部副作用。串口字符已经交给宿主终端、块写已经提交到镜像、网络包已经发出，迁移无法通过还原寄存器撤销这些事实。设备停止协议要决定排空、重复容忍或 in-flight保存，字段设计必须与外部语义配合。

第六类是时间关系。保存宿主绝对时间通常没有意义，客户机关心 alarm距离虚拟时间多少、timer是否 armed以及暂停期间是否推进。Goldfish RTC的历史 VMState正是围绕时钟基准演进。

:::: {.quick-quiz}
为什么 MMIO写入值不能直接复制到同偏移字段？

::: {.quick-answer}
寄存器可能包含只读、保留、write-one-to-clear或触发动作的位。回调要按规格屏蔽和执行副作用，持久字段保存处理后的状态，写入原值常常不再有意义。
:::
::::

## SerialMM 与 SerialState 的两层模型

RISC-V `virt`调用 `serial_mm_init()`创建 `TYPE_SERIAL_MM`。SerialMM是 SysBusDevice包装，持有 MMIO region、regshift、端序和一个组合的 `TYPE_SERIAL` child。SerialState实现 16550寄存器、FIFO、timer、IRQ与 chardev。包装层让同一串口内核也能被 ISA、PCI等 transport复用。

SerialMM realize先 realize内部 Serial child，再用选定端序的 `serial_mm_ops`创建 I/O MemoryRegion，大小为 `8 << regshift`，随后初始化一个 sysbus MMIO端口和 IRQ输出。`virt`把 regshift设为 0、小端，映射到 `0x10000000`。

MMIO read/write把字节地址按 regshift还原成 16550寄存器号，然后调用 `serial_ioport_read/write()`。包装处理地址和端序，SerialState处理设备语义。若另一个 RISC-V SoC把寄存器间距设为 4字节，只需改变包装属性，FIFO与 IRQ实现无需复制。

SerialMM的 VMState只嵌套 `vmstate_serial`。这说明 wrapper的 regshift、endianness和 baudbase属于创建配置，目标应按同一 machine配置重建；运行中可变的串口状态由 child保存。若未来允许客户机修改 wrapper属性，迁移边界也要重新评审。

QOM组合关系在这里很重要。Serial child不是挂在独立硬件总线上的第二个客户机设备，它是包装内部实现。`info qom-tree`会看到两层，FDT只描述一个 UART节点。把 QOM节点数当硬件数量会得到错误结论。

## 16550 寄存器是一组复用状态机

16550的寄存器编号只有少量，DLAB位会改变同一偏移的意义。LCR.DLAB为零时偏移零是接收/发送数据，置位后变成 divisor latch低字节；偏移一也在 IER与除数高字节间复用。read/write回调必须先看 LCR，再决定访问哪个字段。

发送数据寄存器写入后，字符可能进入 xmit FIFO，再由 timer或 chardev回调推进。LSR.THRE/TEMT与 transmit holding/shift状态相关，IRQ pending也随 FIFO阈值和 IER变化。立即把字符视为“已经发送”会让状态位和时序失真。

接收方向由 chardev回调把宿主输入送入 UART。`serial_can_receive1()`决定 FIFO容量，`serial_receive1()`更新数据、LSR与 timeout timer，之后重新计算 IRQ。宿主字符到达与 vCPU MMIO访问可能在不同事件循环阶段，设备要按 QEMU线程规则保护状态。

IIR读取报告当前最高优先级中断来源，并可能带 FIFO状态；某些寄存器读取还会清除 pending或 delta位。read回调因此也能有副作用。调试器重复读取设备寄存器可能改变客户机行为，qtest应明确一次访问的预期。

FCR写入可以启用/清空 FIFO，清空时要同步指针、状态位、timeout和 IRQ。MCR控制外部线与 loopback，MSR含当前状态和 delta位。只保存公开寄存器，而漏掉 FIFO或 pending的内部区分，迁移后第一次 IIR/LSR读取会改变。

非法宽度、越界与端序属于 ABI。SerialMM的 MemoryRegionOps定义实现宽度，machine选择 little endian。设备不应按宿主字节序直接强转；riscv64客户机也可能用不同宽度访问，结果要符合模型约束或给出 guest error。

## IRQ 是派生输出，也是跨设备边

设备通常在状态变化后集中调用 update IRQ函数，根据 pending与 enable计算电平，再用 `qemu_set_irq()`驱动输出。集中计算可避免每个寄存器分支遗漏降线或升线。保存时优先保存产生输出的状态，目标 post-load重算。

UART有接收数据、发送 holding empty、线路状态和 modem状态等来源。IER屏蔽，IIR选择优先级，某些读取清 pending。IRQ线只表示“至少一个允许来源存在”，无法反向恢复具体来源。迁移只保存线电平会丢信息。

level-triggered输出在条件持续时保持高，目标重算可以安全恢复；edge事件若已经产生而控制器未锁存，设备需要保存 pending或由 irqchip保存。设备和中断控制器的责任必须按协议划分，不能两边都重新发一次。

reset enter阶段清本地 pending后，何时 lowering外部 qemu_irq需要遵守 Resettable规则。enter阶段禁止对其他对象产生副作用，hold/exit才允许调整外部线。旧 legacy reset回调未完全采用三阶段语义时，需要结合具体框架适配阅读。

in-kernel irqchip进一步改变所有者。模拟 APLIC/IMSIC的 qemu_irq连接和用户态字段有效，KVM irqchip则由内核拥有 pending。第 14、15章已给出迁移边界；reset也必须作用在当前权威实现。

## timer 选择哪一只时钟

QEMU timer关联 clock type和 deadline。`QEMU_CLOCK_VIRTUAL`在 VM暂停时停止，适合 CPU/设备看到的虚拟时间；`QEMU_CLOCK_REALTIME`跟随宿主实时时间，常用于 UI或需要暂停仍推进的任务；host clock又有不同调整语义。设备不能因 API方便随意选择。

UART字符发送和 FIFO timeout使用虚拟时钟，VM暂停时传输也暂停。这样客户机在断点停十分钟后恢复，不会突然发现虚拟串口已经悄悄清空。Goldfish RTC需要给客户机提供墙钟外观，又要在迁移和暂停中保持 offset语义，代码保存 offset与 alarm而非 timer对象。

timer对象是宿主调度资源，包含 callback和 opaque指针，不进入 VMState。可迁移字段通常是 deadline、剩余时间、是否 armed或足以推导它们的状态。post-load在目标重新创建/调度 timer。

保存绝对 `QEMU_CLOCK_VIRTUAL` deadline可行的前提是目标虚拟时钟基准按迁移协议连续；保存剩余 delta则要在 pre-save准确取样，并考虑停机时间。设备应选择一种清晰语义，不能在版本升级中悄悄切换。

timer删除与 callback并发要按所属 AioContext处理。`timer_del()`阻止未来触发，不一定替代对已经排队 callback的线程同步。设备 unrealize或 reset还要保证 callback不会再访问释放/重置后的状态。

周期 timer常在 callback内安排下一次 deadline。迁移若保存“下一次”却在目标 post-load又把周期从当前时间重新计算，会丢失相位；reset则通常从规范初值开始。migration和 reset都重建 timer，目标不同。

:::: {.quick-quiz}
为什么 VM暂停时仍继续推进的 host timer不适合普通客户机设备 timeout？

::: {.quick-answer}
客户机 CPU已经停止，设备 timeout若继续推进，恢复后会看到暂停期间发生的事件。虚拟时钟与 vCPU runstate一致，更容易保持客户机可观察时间关系；确需墙钟语义的设备要显式设计转换。
:::
::::

## Goldfish RTC 展示时钟版本兼容

`virt`在固定地址创建 Goldfish RTC。设备保存 `tick_offset`，把 QEMU clock转换为客户机读到的 RTC时间；alarm寄存器决定下次事件，`irq_pending`与 `irq_enabled`决定输出。MMIO只允许 4字节访问并指定端序。

reset删除 timer，清 alarm、running、pending和 enable。它没有销毁 RTC对象，也不重置所有创建属性。reset后再次写 alarm可以复用原 timer资源；unrealize/finalize才释放资源。

当前 `goldfish_rtc_vmstate`版本为 3，保存旧 `tick_offset_vmstate`、alarm、pending、enable、time_high以及 v3新增的直接 `tick_offset`。`post_load`在读取旧于 v3的流时，根据 realtime/virtual clock差值把旧表示转换成新字段，然后重新安排 alarm。

这个例子说明 VMState version不只是结构长度。旧版本保存的是另一种时钟基准表达，目标必须转换语义。简单给缺失字段填零会让 RTC跳到错误时间。

post-load最后调用 `goldfish_rtc_set_alarm()`，因为宿主 timer本身没有迁移。此时所有字段已加载，才可从 `alarm_next`和 clock重新调度。若在逐字段 load期间提前安排 timer，目标可能在状态未完整时触发 IRQ。

测试 RTC迁移要覆盖未来 alarm、已经 pending但未 ack、IRQ被 mask三种状态，也要加载旧 VMState样本。只读当前时间连续性，无法验证 alarm和 version转换。

## 异步 completion 要携带“仍然有效”的前提

chardev输入、块 I/O、网络发送、DMA、bottom half和 timer callback都可能晚于发起 MMIO。回调持有设备指针时，reset或 unrealize必须先阻止新请求，再取消/排空并等待现有 callback不再访问旧状态。

一种常见办法是 generation counter。发起请求时记录代数，reset递增，completion发现代数不同便只释放请求，不更新寄存器或 IRQ。另一种办法是 drain所有请求，确保 reset后没有旧 callback。选择取决于后端能否取消和外部副作用。

取消不代表外部操作没有发生。块层请求可能已经写入磁盘，网络包可能已发出；设备只能保证客户机完成状态与规范一致。若可能重复提交，协议需要 request ID、幂等或 in-flight迁移。后端语义不能由通用 qdev reset替代。

热拔比 reset更严格。reset后对象继续存在，迟到 callback即便不更新状态也能安全释放；unrealize后内存可能进入 finalize，所有 callback和 event handler必须撤销。DeviceClass unrealize应对 realize成功分配的资源做反向清理。

错误路径同样可能异步。后端断开要把 device status或 error返回客户机，迁移 stop期间发现 backend失败应终止迁移。吞掉 callback错误会让 used ring、IRQ和外部存储互相不一致。

## qdev 生命周期的真实顺序

instance init建立对象内部不变量，可以创建 child、初始化队列头与默认属性存储，但不应访问尚未连接的后端或 bus。用户和 machine随后设置 properties、links、parent bus和 child关系。所有必需输入准备好后才 realize。

通用 `device_set_realized()`先检查设备是否允许 hotplug以及 `--only-migratable`。hotplug controller有机会 pre-plug校验平台资源；DeviceClass realize分配 MMIO、IRQ、timer、backend handler和 child bus。失败通过 Error返回。

realize成功后，device listeners收到通知，canonical path固定，clock path建立，VMState注册，child buses realize。hotplug设备随后在新 parent的 reset状态下执行 reset，再由 hotplug handler真正接入平台，最后原子发布 `realized=true`。

VMState在 realize之后注册有明确理由：实例 ID和 canonical path已稳定，设备也知道 feature/queue数量。过早注册会把失败或半配置设备放入迁移列表。unrealize则先标记不可用，再反向注销 child bus与 VMState。

设备对象引用计数可使 finalize晚于 unrealize。unrealize释放运行资源，finalize释放只随对象内存终结的资源；两者不能重复释放。machine instance finalize还会处理从未 realize的预创建 flash，这又是一条分支。

hotplug失败回滚要覆盖 pre-plug、realize、VMState、child bus和 plug各阶段。板载 helper大量使用 `error_fatal`，通用可插设备要保持错误可恢复。代码审查不能只读成功路径。

## Reset 与构造、暂停、迁移的区别

构造从无到有分配对象和宿主资源；reset在同一对象上恢复客户机规定的复位状态；暂停保持寄存器和 pending，只停止时间/执行；迁移保存任意运行状态；unrealize撤销对外注册并释放运行资源。五种操作有交叉步骤，目标完全不同。

把 reset写成 `memset(state, 0)`经常错误。某些寄存器 reset值不是零，FIFO/timer需要 helper清理，IRQ要按阶段降低，创建属性和 QOM links要保留，后端句柄也许继续连接。Serial reset设置 LSR、MSR、divider等具体默认值并删除 timer。

reset不能重新调用 realize。realize可能再次注册 MemoryRegion、VMState或 chardev handler，造成重复映射和回调。设备应在 instance/realize中准备可复用资源，在 reset中只修改运行状态。

暂停也不能调用 reset。QMP `stop`后继续要求设备从原状态恢复，FIFO、alarm和 pending都要保留。虚拟时钟停止自然冻结许多 timer，设备无需清空。

snapshot load有独立 ResetType，但当前 Resettable文档也承认类型支持仍在演进。设备不能假定所有 reset type语义相同；若只实现 cold reset，明确限制并依靠迁移 post-load重建。

## Resettable 的 enter、hold、exit

Resettable把一次 reset拆成 enter、hold、exit。enter清本地状态，不允许修改其他对象、raise/lower qemu_irq或读写 guest memory；所有子对象完成 enter后进入 hold，此时可以产生跨对象副作用；release时执行 exit。

三阶段解决树形依赖。若父设备先降低共享线，而子设备尚未清 pending，中间状态可能让另一个对象观察到矛盾。先让整棵树进入本地 reset，再统一处理外部连接，顺序更可推理。

reset树沿 qbus关系遍历：bus的 children是挂接设备，device的 children是它拥有的 buses。Resettable文档明确指出这和 QOM hierarchy不同。组合 child若不在 qbus树，需要父设备显式传播或由注册机制覆盖。

每个对象的 ResettableState含嵌套 count、hold pending与 exit进行标志。多来源同时 assert reset时，只有计数从零到一执行 enter，全部来源 release后才 exit。这样父 bus与全局 reset同时覆盖设备时，不会过早离开 reset。

`resettable_change_parent()`用于设备在不同 reset parent间移动，并只允许在安全阶段调用。hotplug设备加入正在 reset的 bus时，框架先 reset其子树，再改变 parent，防止新设备以运行状态插入被 reset平台。

API要求持有 iothread mutex，当前实现用全局标志断言 enter/exit阶段。它提供有序控制面，不使设备数据面自动线程安全。异步 backend仍需自己的 drain/锁。

:::: {.quick-quiz}
Resettable为什么禁止 enter阶段降低 IRQ？

::: {.quick-answer}
enter时其他对象可能尚未进入 reset，跨对象副作用会暴露半复位状态。等所有子对象完成本地 enter后，在 hold或 exit阶段调整连接，系统关系更一致。
:::
::::

## APLIC 与 IMSIC 的 reset演进

当前 APLIC在 `riscv_aplic_reset_enter()`清 domain配置、source、target、enable、MSI配置和 direct-delivery字段；模拟 direct模式还降低每 hart external irq。若当前实现由 KVM拥有，函数按 ownership条件跳过用户态状态。

提交 [`99bfcd32`](https://gitlab.com/qemu-project/qemu/-/commit/99bfcd329aa2441f3a08554659d2c3ee6453f9df) 把明确 reset API加入 APLIC，[对应系列邮件](https://lore.kernel.org/qemu-devel/20260428160103.3551125-3-jim.shu@sifive.com/)与提交说明写的是清寄存器与 `qemu_irq`。设备模型在此之前可以正常处理中断，却不代表 system reset后回到规范初值；前者是功能路径事实，后者需要独立生命周期证据。

IMSIC的 `riscv_imsic_reset_enter()`清 delivery、threshold和 enabled状态，并降低外部线；in-kernel irqchip时直接返回。提交 [`76639148`](https://gitlab.com/qemu-project/qemu/-/commit/766391483bdccb66e392e71769bc85839569857d) 与[系列中的下一封邮件](https://lore.kernel.org/qemu-devel/20260428160103.3551125-4-jim.shu@sifive.com/)给出 IMSIC reset补充。两项修改分别落在 APLIC 与 IMSIC，说明审查对象按状态所有者拆开，不能把其中一项通过推断成整条 AIA 链都已复位。

两项提交共同支持一个工程结论：功能路径与 reset路径要独立验收。启动、收发中断全部通过，仍可能在 guest reboot或 QMP system_reset后残留 pending。补丁进入多年后的候选标签，也说明 reset不是设备首版自然附带的结果。

ownership条件同样关键。用户态 shadow不是 KVM live irqchip，清它不会复位内核。当前函数选择跳过，真正内核 reset要走 KVM接口。若接口缺失，应标开放问题，不能假装用户态回调已经完成。

reset测试要在非默认状态触发：配置 source、enable并留下 pending，再 system_reset；空闲初始设备即使 reset回调完全没执行，看起来也会“通过”。多 hart和 split模式分别运行，才能覆盖所有者分支。

## VMState 字段如何分类

`VMStateDescription`给设备运行状态定义名称、版本、最低版本、字段、subsections与 hooks。它是序列化协议，不是 C结构布局。添加宿主指针或 padding既不安全，也会让重构破坏迁移。

持久字段应保存客户机可观察且无法从其他字段可靠重建的状态。派生字段可以在 post-load计算；常量配置由目标 machine/device属性重建；timer对象和 event handler由 realize创建；缓存通常清空后按需重建。每个省略都需要依据。

版本用于语义演进。新增字段可用版本或 subsection，在旧流缺失时给明确默认；改变字段含义需要转换。`minimum_version_id`决定最老可接受流，不能只提高版本把兼容问题推给用户。

`needed`控制可选 subsection或设备状态。例如 APLIC VMState只在模拟 APLIC拥有状态时需要，IMSIC只在非 in-kernel irqchip时需要。predicate必须反映真正 owner，错误条件会保存陈旧影子或漏掉 live状态。

pre-save用于把派生/外部状态收敛到字段，post-load用于校验、转换旧版本和重建 timer/IRQ/cache。hook失败应中止迁移，不能在错误后让 vCPU运行。

## Serial VMState 为什么有多个 subsection

`vmstate_serial`当前版本为 3、最低版本为 2，主字段保存 divider、RBR、IER、IIR、LCR、MCR、LSR、MSR、SCR和 v3的 FCR迁移表示。主干覆盖长期存在的寄存器。

THR pending、TSR、接收/发送 FIFO、FIFO timeout timer、timeout pending和 modem poll分别作为 subsections。它们只在相应非默认状态需要，避免旧 machine或简单串口每次携带大量扩展字段，也让功能分批演进。

pre-save把运行结构转换成稳定表示，pre-load准备目标，post-load恢复 FIFO/timer并重算。subsection存在不能替代 hook，宿主 timer和 chardev仍要重新连接。

SerialMM wrapper再用 `VMSTATE_STRUCT`嵌套 SerialState。这形成两级版本路径：transport wrapper和设备语义。另一种 transport可以复用 `vmstate_serial`，同时保存自己的配置状态。

审查 UART迁移时，把每个 SerialState字段分成寄存器、FIFO、timer、host handler与派生 IRQ。查到一个主 VMState后仍需继续查 subsections，否则会误判 FIFO没有保存。

## PLIC、APLIC 与 IMSIC 的状态边界

PLIC VMState保存 priority、pending、claimed、enable、threshold等数组。数组长度由创建属性决定，目标 machine必须建立相同 hart/source拓扑。IRQ输出可以从这些字段重算，不需要迁移 qemu_irq对象。

APLIC VMState版本为 3，并由 `riscv_aplic_state_needed()`判断模拟 owner。字段包含 domain/MSI配置、source state、target、delivery、force与 threshold。source数量和 hart数量是目标配置，数组按它们传输。

IMSIC VMState版本为 2，模拟模式保存每页 delivery、threshold与 interrupt state数组。`needed`在 in-kernel irqchip时为 false。该条件避免把未分配或陈旧用户态数组写入流，也暴露内核状态需要另一套接口。

reset和 migration对同一字段采取不同动作：reset清 pending/enable到规范默认，migration恢复任意值。不能用 reset helper替 post-load；也不能在迁移加载后再 cold reset，否则刚恢复的中断状态会被擦除。

第 15章已确认固定标签的 in-kernel AIA保存恢复未闭环。本章把结论落到 DeviceClass：用户态 `dc->vmsd`带 owner predicate，内核状态不会因为同名 VMState自动出现。

## realize、reset 与 VMState要一起评审

新增客户机可写寄存器时，先确定 reset值和访问语义，再判断它是否影响未来行为、是否能从其他字段重建、是否需要 VMState版本。只加 MMIO回调会让正常运行成功，reset和迁移留下缺口。

新增 timer时，realize创建、reset删除或重设、unrealize释放、VMState保存可观察 deadline/post-load重调度。四条路径必须对称。错误路径还要处理 realize创建 timer后后续步骤失败。

新增 IRQ来源时，update函数覆盖 enable/pending优先级，reset清来源并在正确 phase更新线，VMState保存来源而非单一电平，post-load重算。连接目标由 machine负责。

新增异步后端时，realize注册 handler，reset drain或换代，unrealize注销并等待，迁移冻结/in-flight，错误返回客户机。没有完整停止协议时，应添加 migration blocker或明确 only-migratable拒绝。

这个评审顺序可以解释当前代码为何分散。设备语义、通用 lifecycle、board wiring和迁移框架各自维护一段协议；把所有逻辑塞进一个 realize回调会使 reset与迁移无法复用。

## 常见失败模式

第一类是 reset值遗漏。新增 enable位默认保持上次运行值，guest reboot后设备仍发 IRQ。测试要先写非默认再 reset，而非只检查首次启动。

第二类是 timer重复。post-load安排新 timer，旧 timer未删除或 migrated deadline已经过期，目标立即触发两次。hook要清理现有调度，并按状态只 arm一次。

第三类是派生 IRQ不一致。字段恢复后没有 update IRQ，pending存在但线低；或者迁移了线电平又重算，edge被重复。恢复测试要检查 first event和 ack。

第四类是迟到 completion。reset清队列，旧块/字符回调回来写入新状态。使用 drain、cancel或 generation，unrealize还要等待引用释放。

第五类是版本默认错误。旧流没有新字段，目标默认值与旧设备行为不相同。兼容测试必须实际加载旧样本，代码审查无法覆盖时钟和 hook时序。

第六类是 ownership误判。KVM拥有 irqchip却保存 QEMU shadow，恢复流看似完整，live pending丢失。每个 conditional VMState都应附实现模式测试。

## 用访问语义给寄存器分类

设备数据手册中的一张寄存器表至少包含五种行为。普通读写字段保留屏蔽后的值；只读字段来自内部状态；write-one-to-clear字段把写一解释成确认；read-to-clear字段在读取时消费事件；command字段触发动作，本身未必有可保存值。实现和测试必须按类别写oracle。

UART的LCR、MCR和SCR接近普通持久字段，LSR/IIR混有派生与读取副作用，FCR包含FIFO控制命令，THR写入则启动发送状态机。即使寄存器宽度都是一字节，VMState策略也不同。按偏移批量生成字段会把命令误存成状态。

保留位要在写入时屏蔽，读取时返回规范值。客户机可能故意写全一探测feature，QEMU不能把未知位带进未来行为。新增规范位时，旧machine行为与迁移默认需要单独考虑，不能让过去保存的保留位突然生效。

多字寄存器还涉及访问拆分。Goldfish RTC用高低32位寄存器表达较宽时间，设备要定义读取高低之间时钟推进时的快照语义；SerialMM则限制到其支持宽度。MemoryRegionOps的`valid`和`impl`约束决定总线如何拆分，不应只依赖回调中的`size`分支。

诊断非法访问时，guest error日志包含offset、size和方向更有用。返回全一、零或总线错误应按设备约定，任意选择会改变驱动探测路径。源码事实要从固定标签的ops和回调确认。

## 串口发送链中的三个完成点

客户机写THR只表示设备接受一个字符。字符从holding register或xmit FIFO进入transmit shift register，是第二个状态转换；chardev接受字节或其watch回调完成，是宿主数据面进展。LSR.THRE、LSR.TEMT和发送IRQ分别依赖这些位置。

若chardev暂时不能写，SerialState要保留待发字符并等待可写事件。此时THRE可能表示holding可接收新字符，TEMT仍为低。把两位同步设置会让驱动过早判定线路完全空闲。

FIFO开启后，trigger与发送批量改变中断频率。FCR清TX FIFO要移除尚未进入shift的字符，已经交给chardev的字节无法撤回。reset同样需要区分内部可取消状态与外部副作用。

loopback模式把输出反馈到接收和modem输入，宿主chardev不应同时看到同一字节。MCR改变后要更新MSR delta与IRQ。这个路径适合qtest验证寄存器状态机，不依赖真实终端时序。

迁移测试可在三处制造状态：THR pending、TSR busy、xmit FIFO非空。目标恢复后字符顺序只能延续一次，THRE/TEMT变化和IRQ也要对应。仅比较最终终端字符串会漏掉一次重复后又被应用层去重的情况。

## 串口接收与 timeout 的竞态

chardev先调用can-receive确认容量，再把字节交给receive回调。两次调用之间设备可能被reset、FIFO配置可能改变，回调仍要按当前状态校验。事件循环串行化减少竞争，并不允许把先前容量判断当永久预留。

FIFO未满时新字节推进write index、更新LSR.DR，并按trigger决定RX interrupt。达到trigger可立即报告，低于trigger则arm character timeout。后续读取降低占用，timeout需要取消或重算。

timeout callback到达时，客户机可能刚好读取最后一字节。callback应再次检查FIFO与pending条件，再设置中断；不能凭“timer曾被安排”直接raise。reset先删除timer、清FIFO和pending，在允许的phase重算IRQ。

迁移pre-save要捕获timer与timeout pending的关系。目标post-load先恢复FIFO和索引，再按deadline/pending安排timer，最后更新IRQ。顺序颠倒会出现空FIFO timeout或丢失已到期事件。

测试竞态时用虚拟时钟精确推进：注入少于trigger的字符，在deadline前读空；另一次让deadline到达；第三次在deadline前save/load。每轮检查FIFO长度、IIR来源、LSR与线电平，避免依赖宿主sleep。

## AioContext 与 BQL 不是同一层保证

许多板载MMIO回调在持有大锁的vCPU线程或主循环执行，timer也可能在主AioContext运行。block、network、chardev与vhost可以引入其他AioContext或线程。设备状态是否需要锁，取决于callback实际执行上下文。

Resettable要求iothread mutex，保证控制面遍历顺序。它无法等待另一个AioContext中已经排队的completion。设备reset前需调用子系统提供的drain、cancel、aio-context acquire或同步helper，具体机制由backend定义。

把所有字段都放在一把设备锁里也不充分。持锁调用可能同步回调的backend会死锁，锁内触发qemu_irq又可能进入另一对象。常见设计是锁内更新本地状态，记录需要的外部动作，解锁或在允许phase执行。

RCU适合保护只读映射和对象替换，不提供事务级设备语义；BH适合把工作切回指定AioContext，不自动取消旧代请求；原子变量适合简单flag，不替代FIFO多字段一致性。评审要说明每种工具保护的具体不变量。

线程问题应以源码调用路径和运行配置为证据。TCG单vCPU测试没有触发竞态，不足以证明多队列、异步chardev或迁移线程安全。开放问题应列出未覆盖的callback来源。

## Timer 的数值与边界条件

deadline通常使用有符号64位纳秒或设备tick。客户机寄存器可能只有32位，换算要检查乘法溢出、负值、wrap与远未来上限。将客户机值直接乘频率后传给timer API可能越界成过去时间。

alarm写入过去时间时，规范可能要求立即pending，也可能要求等下一次wrap；设备要实现明确规则。目标post-load发现deadline已过，同样要决定立即触发还是保持已保存pending，不能依赖宿主timer实现偶然行为。

高低寄存器分次写会产生中间值。设备可在写低位时提交，也可要求专门enable；实现应与binding一致。迁移若发生在两次写之间，`time_high`这类latch本身就是客户机可观察状态，需要保存。

虚拟时钟比例、icount和暂停会改变宿主等待时间，不改变客户机deadline语义。实验输出同时写virtual clock与guest寄存器，不用wall-clock差值判定设备提前或延迟。

周期事件长期运行还会累积舍入误差。从上一个deadline加period保持相位，从“当前时间+period”可跳过过期周期并漂移。选择涉及设备规范和性能，提交说明应解释丢周期策略。

## Reset 树的遍历与对象所有权

Resettable沿qbus树传播，父bus包含设备，设备再包含child bus。一个PCI bridge的secondary bus因此自然位于bridge reset子树；QOM组合child若没有qbus边，不会仅凭对象父子自动收到同一遍历。

包装设备要明确对子对象的reset责任。SerialMM组合SerialState，当前串口实现通过其设备/VMState结构处理相应状态；新wrapper若只创建普通Object child，需要显式调用或让child成为Resettable节点。对象存在并不等于框架已经发现其reset接口。

enter阶段适合把本地寄存器、FIFO和pending设为reset值，并标记输出需要更新。hold在整棵相关子树进入后可以降低IRQ、撤销DMA或通知backend。exit恢复允许运行的handler与timer。具体设备可以不需要全部回调，阶段限制仍适用。

嵌套reset计数处理多个控制源。例如system reset尚未释放时，PCI function-level reset又覆盖同一设备；第一次enter只执行一次，任一来源释放都不能提前exit。测试需要交错assert/release，而不是连续调用两个完整reset。

移动parent或hotplug期间，框架要把新子树带入当前reset状态。否则处于reset的bus上会出现一个正在响应DMA的新设备。`resettable_change_parent()`限制调用阶段，就是为了维护这项不变量。

## Property、link 与运行字段的边界

创建属性在realize前由machine或用户设置，例如SerialMM的regshift与endianness、irqchip的source数量、设备的backend link。realize后若属性没有显式setter支持热更改，应视为冻结配置。VMState通常不重复保存这些值。

目标迁移进程必须以同样属性创建对象。若source数量不同，变长数组即使能读入也无法对应真实IRQ；若regshift不同，保存的SerialState寄存器会出现在另一地址布局。管理层兼容检查承担这部分责任。

QOM link保存对象引用关系，迁移流不能写host pointer或canonical path后在目标盲找。machine按命令行重建link，设备VMState保存通过该link产生的运行状态。可热插拓扑则由迁移设备枚举和实例ID共同恢复。

某些property可以运行期修改，setter必须把变化转成设备语义，并决定迁移。只改变字段却未重配timer、backend或FDT，会让对象属性与客户机视图分裂。若没有完整协议，realize后拒绝更安全。

审查结构体时可给每个成员标`CONFIG`、`LIVE`、`DERIVED`、`HOST`或`CACHE`。CONFIG在目标命令行重建，LIVE进VMState，DERIVED在hook重算，HOST在realize重建，CACHE丢弃。无法归类的字段往往暴露设计欠账。

## VMState 是按字段解释的线协议

VMState宏指定整数宽度、字节序处理、数组长度、结构版本和条件。它不会把C结构整体dump，因此字段重排可以安全，删除或改变已有线字段需要版本策略。宿主ABI与迁移ABI由此分离。

固定长度数组要求目标有相同逻辑容量；变长数组先迁移受校验的长度，再分配内容。长度来自guest或旧流时必须设上限，防止恶意迁移流导致巨量分配。subsection的`needed`也不能读取未初始化状态。

主版本适合所有实例都需要的新核心字段，subsection适合feature或非默认状态。把每个新增字节都放subsection会产生过多条件协议，把稀有FIFO状态塞主干又会提高旧版本兼容成本。选择要看语义可选性。

pre-load可以初始化旧版本缺省、释放旧缓存或准备动态buffer；post-load验证交叉字段并重建外部资源。若queue index超过queue size、timer状态矛盾或feature与subsection冲突，hook应返回错误并阻止vCPU恢复。

VMState名称和instance ID用于目标匹配。QOM path变化可能影响实例识别，machine中同类型设备的创建顺序也要稳定。内部重构移动对象时，应通过迁移测试确认section仍能匹配。

## 一次迁移中的设备停机窗口

预复制阶段vCPU和设备多数时间继续运行，RAM反复发送脏页。设备直接写RAM时要进入脏页日志；纯寄存器状态通常在最终停机阶段收敛。timer与IRQ仍可能在预复制期间变化。

stop-and-copy开始后，设备停止取得新工作，排空或记录in-flight，pre-save形成字段快照。VMState写出与RAM最后轮次要满足依赖：若设备在保存ring index后仍写buffer，目标会看到无法解释的完成。

目标先创建并realize同构设备，加载字段，post-load转换、校验、重建timer和IRQ，全部成功后才运行vCPU。单个设备post-load失败要让整次迁移失败，不能只把该设备reset继续。

RTC说明timer对象在目标重建，Serial说明FIFO/timeout需要subsection，irqchip说明owner可能位于KVM。三者分别代表纯用户态宿主资源、可选运行状态与外部权威状态，不能用一套“序列化结构体”概括。

savevm离线快照与live migration共用大量VMState代码，停机与外部backend条件可能不同。测试报告要写操作类型；离线snapshot成功不自动证明在线切换时in-flight和dirty logging正确。

## 中断控制器的 reset 不变量

PLIC reset后priority、pending、claimed、enable和threshold回到规范状态，所有context输出应与空pending一致。若只清pending不清claimed，客户机完成旧claim可能影响新一轮；只清enable又保留pending，重新enable会收到复位前中断。

APLIC还含source mode、target、domain config、MSI地址与direct delivery状态。reset需要同时清source配置和投递端状态，避免旧target把新source发送到错误hart。模拟模式可更新qemu_irq，内核模式要由KVM接口完成。

IMSIC每个interrupt file包含delivery、threshold、pending/enable等数组。清一个hart的外部线不足以清文件内容；反过来，清数组后忘记lower line也会让CPU继续进入中断。字段与派生输出都要覆盖。

级联结构要按层验证：设备source先进入APLIC，消息到IMSIC，IMSIC向CPU。system reset后在不重新配置时不应出现旧中断；重新配置并注入一个新事件时应只出现一次。后半步能发现残留claimed或edge。

当前两个补reset提交直接证明曾经缺少协议面。作者从中得到的评审方法是把reset列成独立功能，而非把历史补丁评价为某种普遍质量问题。证据边界必须保留。

## 故障注入比空闲 reset 更有信息

reset测试先把每类字段置成非默认：FIFO装数据、timer armed、IRQ pending且masked、APLIC source enabled、IMSIC file含pending。空设备的全零状态会让空reset回调看似通过。

迁移测试要选边界点：FIFO刚过trigger、alarm即将到期、IRQ已pending未claim、异步completion尚未返回。每个边界只有一个预期所有者，恢复后观察第一次read/ack/timeout。

realize错误可以通过缺backend、非法property和不可迁移模式触发；unrealize错误可用重复创建销毁的qtest寻找handler泄漏。故障注入应在临时配置进行，保持镜像和外部服务可恢复。

旧版本VMState测试需要保存真实样本或兼容构造器。修改当前version字段伪造旧流常会漏掉旧hook与section布局。样本要记录生成commit、machine参数和feature。

测试结论分三层：静态源码审计说明字段意图；trace/GDB说明回调顺序；客户机读取和迁移说明外部行为。三层互相支持时才称闭环，缺一项就标覆盖范围。

## 为设备建立状态责任表

以SerialState为例，可以把divider、LCR、IER列为客户机持久状态；FIFO内容、索引、TSR和timeout pending列为协议进行状态；IRQ电平和部分LSR位列为派生输出；timer/chardev/qemu_irq列为宿主资源；regshift、endianness列为创建配置。

每一类对应不同操作。reset给持久与进行状态赋规范初值，迁移保存任意值，post-load重算派生输出，realize重建宿主资源，目标命令行重建配置。分类错误通常会在其中一条路径暴露。

PLIC/APLIC/IMSIC也能用同一表。priority、enable、pending、target和threshold是live状态，hart/source数量是配置，输出线是派生，KVM device fd是宿主资源，内核irqchip内容是外部权威状态。

表中还应写“唯一写者”。timer callback、MMIO与chardev都能改Serial FIFO时，要说明串行化；QEMU shadow与KVM内核都有同名数组时，要明确谁live。没有唯一写者的字段很难建立snapshot。

状态责任表适合放在提交说明或设计文档，不必成为运行代码。它比结构体成员清单多了生命周期与所有者，能在实现前发现迁移缺口。

## 一次 reset 的可观察时间线

先让UART RX FIFO有两个字符、timeout armed且IER允许接收。system reset请求进入root，Serial所在reset子树执行enter：本地FIFO、寄存器和timer回到初值。此时其他设备可能尚在enter，不能依赖外部IRQ变化判断完成。

整棵子树进入后，hold阶段允许更新qemu_irq，使PLIC/APLIC看到UART不再pending。irqchip自身也已清或正在hold，最终CPU external interrupt线稳定为reset状态。exit后设备接受新的chardev输入与MMIO。

若reset期间一个已排队receive callback到来，设备需要事件循环顺序或generation阻止它把旧字符注入新FIFO。否则客户机会在重启后读到复位前输入。这个问题不由三阶段自动解决。

时间线的断言包括：对象与MMIO一直存在；FIFO和timer清除；IRQ在允许阶段归零；reset release后新字符可收；旧callback不产生副作用。只读LCR默认值覆盖其中很小部分。

## 一次迁移的可观察时间线

同样的UART状态在迁移中不能清零。停机点保存寄存器、FIFO、TSR、timeout状态和必要deadline，目标realize先重建SerialMM、chardev、timer与IRQ端点，再由VMState覆盖live字段。

post-load恢复FIFO指针与正在发送状态，删除任何realize初态timer，按迁移deadline重新arm，调用update IRQ。目标运行前，IIR/LSR、可读字符顺序与源端停机点等价。

chardev本身未必有可迁移外部状态。目标终端连接由配置重建，源端已经输出的字符不重放，尚在UART内部的字符继续。若backend协议无法划定边界，应阻止迁移或定义丢失/重复语义。

与reset对比可形成强oracle：reset后状态回初值，迁移后状态保持。两者都要重建或取消timer，却不能共享一个“清所有字段”helper。helper可以复用低层资源操作，调用者决定目标值。

## chardev 生命周期也要入账

UART realize按property取得chardev backend，注册can-read、read、event与可写watch。backend可能是stdio、pty、socket或测试端点；SerialState只依赖CharBackend接口，不保存具体host对象指针。

chardev断开时，设备可能更新modem状态、停止发送或保留数据，取决于模型。重新连接后handler继续使用同一UART状态。断开事件与guest寄存器读取并发时要遵守AioContext。

unrealize先移除handlers和watch，再释放timer/FIFO等资源。若先释放SerialState，迟到chardev callback会use-after-free。realize中后续步骤失败也要撤销已经注册的handler。

迁移目标需要等价backend配置，却不会把源端socket连接透明搬过去，除非上层协议明确支持。技术书应把“设备寄存器可迁移”与“外部字符流无缝迁移”分开。

测试可用可控socket chardev，在发送阻塞、断开和重连时观察THRE/TEMT、pending与字符唯一性。stdio交互难以稳定复现边界，不适合作为唯一CI。

## 旧 VMState 样本怎样维护

每个兼容样本要记录源QEMU commit、machine参数、device属性、协商feature和制造状态的脚本。二进制流没有这些元数据时，失败很难判断来自machine差异还是字段转换。

样本状态应覆盖新增字段的非默认语义。Goldfish RTC v2样本若tick offset恰为转换前后都为零，无法验证v3 post-load；Serial旧样本应包含FIFO/timeout相关subsection条件。

CI使用新QEMU加载旧样本，读取客户机可见寄存器并推进虚拟时钟。仅检查load命令返回零，会漏掉post-load转换错误。若能保留旧二进制，还可做source-to-new目标迁移。

新增version时先写旧流缺省与转换，再更新样本。最低版本提高要有明确不兼容原因和管理影响，不能用来绕过修复。迁移ABI是发布承诺的一部分。

样本含guest RAM或用户数据时需要最小化与脱敏。许多设备可用qtest构造纯状态，无需完整磁盘镜像，便于开源仓库长期保存。

## VMState hook 的失败语义

pre-save发现backend无法冻结、字段组合非法或外部owner不可读时，应返回错误并终止保存。继续写一份已知不一致的流会把源端可恢复故障变成目标数据损坏。

pre-load负责清理目标realize产生的临时状态和准备动态内存。长度与版本先校验，再分配；失败要释放已分配资源。后续load重试或对象销毁不能双重释放。

post-load可以拒绝索引越界、feature不匹配、alarm矛盾或owner缺失。它还要按依赖顺序重建timer、cache与IRQ。任何失败发生时vCPU尚未运行，管理层可保持源端或报告失败。

hook不应偷偷修改目标machine配置来容纳流，例如增大irq source数量。配置兼容由迁移握手/管理层保证，设备只验证。静默调整会让FDT、MemoryRegion与对象数组不一致。

错误文本包含VMState name、version、字段关系与设备path，便于多实例定位。迁移错误属于外部接口，可观测性同样需要兼容审查。

## Reset callback 的幂等与嵌套

enter在嵌套count从零到一时执行，逻辑上仍应能面对已经接近reset值的状态。重复删除未armed timer、清空空FIFO和设置默认寄存器要安全。依赖“必然有请求”会在多来源reset中崩溃。

hold可能在不同reset层级被调用，外部副作用不能重复累计。例如lower level IRQ重复执行通常无害，向backend发送一次性reset命令则要按count或状态保护。

exit只有所有reset来源释放后执行。它可以恢复handler或允许DMA，但不能凭reset前缓存重新raise已清pending。新事件应在exit之后按新状态进入。

错误路径若reset backend失败，要决定设备留在hold、标needs-reset或让machine reset失败。忽略错误后exit会形成前端已清、backend仍运行的分裂状态。

## IRQ 的电平、pending 与 claim

设备源pending表示事件尚未被设备侧清除，irqchip pending表示控制器已锁存，CPU external line表示至少一个context可投递，claim表示软件正在处理中。四者不是同一个布尔值。

UART读取IIR/数据可能清设备来源，PLIC claim/complete修改控制器状态，CPU处理CSR又影响是否进入trap。迁移在任意点发生时，各owner保存自己的层，post-load不应凭CPU线反推下层。

edge源需要在控制器锁存前保存事件，level源可从持续电平重新采样。qemu_irq API传递电平，设备模型要在需要时自行保存edge pending。规范和irqchip接口共同决定责任。

APLIC到IMSIC的MSI投递又把wired source转换为message和interrupt file pending。reset必须清旧source与目标file，迁移则保持已经投递的file位，避免重新发送同一MSI。

测试在四个点迁移：事件尚在设备、已进controller未claim、已claim未complete、已complete。每点的首次目标行为不同，能检出重复注入和丢pending。

## KVM owner 条件要从运行对象确认

Machine属性选择AIA模式，accelerator与KVM capability决定最终由用户态或内核实现。DeviceClass `needed` predicate读取的应是这个最终owner，而非命令行字符串。否则fallback场景会保存错误对象。

模拟模式下APLIC/IMSIC数组是live，VMState保存并在post-load重算线。内核模式下用户态对象可能只保存配置或proxy状态，真正pending需要KVM get/set接口。缺接口时迁移能力应受限。

reset同理。调用用户态reset回调只清shadow，内核irqchip仍可能投递旧中断；当前源码在in-kernel分支跳过，平台/KVM层要承担相应动作。测试需确认内核状态而非只看QEMU结构。

`--only-migratable`应在设备realize时拦截已知无迁移实现。若owner到更晚才决定，校验点也要随之调整。声明支持必须以活动pending状态往返验证。

## 设备性能与正确性状态相连

FIFO、timer合并和IRQ抑制降低每字符事件次数，却增加需要迁移的中间状态。优化新增一个batch counter或pending queue时，也要加入reset与VMState分类。

将timer换成BH可以减少时钟操作，客户机可观察timeout可能改变；将IRQ更新延迟到批末减少qemu_irq调用，边界读取的IIR仍要一致。性能补丁需要寄存器级回归。

缓存派生状态提高访问速度，post-load可以清空重建；若缓存影响replacement或外部顺序，它已经变成live状态。判断依据是丢弃后客户机能否观察差异，不是字段名称是否叫cache。

性能测试应同时执行system reset和save/load压力。只在稳态吞吐下正确的优化，常在timer armed、FIFO半满或后端阻塞时暴露生命周期缺口。

## 上游审查如何复原设计依据

Git log先找引入字段或callback的commit，提交说明给出当时缺陷与目标。再用Message-ID进入邮件系列，查看早期方案、review意见和最终版本变化。固定tag源码确认最终函数名与owner条件。

`99bfcd32`与`76639148`可以直接证明APLIC、IMSIC何时加入reset API；它们不能单独证明所有RISC-V irqchip reset已经完备。范围要由diff和当前tree决定。

Serial与RTC历史较长，字段名可能多次重构。`git log -S`搜索具体VMState字段或version，比只按文件名浏览更容易找到语义变化。重命名提交与行为修复要区分。

作者从“reset在功能之后补齐”推导独立验收方法，这是工程解释；邮件中维护者明确写出的兼容原因才标上游陈述。两者在正文中使用不同措辞。

开放问题写成可执行查询，例如“内核AIA活动pending能否由固定tag保存恢复”，并列所需KVM ioctl、VMState和实验。笼统写“迁移可能有问题”无法指导后续审查。

## 设备实现的最小闭环

一个新RISC-V板载设备至少需要：QOM/type与properties；realize创建MMIO/IRQ/timer/backend；寄存器访问与错误校验；reset初值；VMState或明确迁移blocker；unrealize/finalize清理；machine地址、IRQ和FDT接线。

功能测试覆盖正常请求，状态测试覆盖非默认reset，时间测试覆盖暂停和deadline，迁移测试覆盖in-flight，错误测试覆盖非法MMIO与backend失败。每类测试对应不同契约。

若设备暂不支持某项，代码要显式表达：不可迁移、不可热插、某feature不广告、某accelerator组合拒绝。沉默缺口会被上层当作成功能力。

闭环也包含文档与trace。用户需要知道寄存器、clock、IRQ和限制，维护者需要从device ID/path定位错误。可运行并不等于可维护。

## 提交前的状态机核对

对每个客户机写入，写清屏蔽后的字段、触发动作、可能安排的timer/backend请求和IRQ重算；对每个读取，写清返回来源与是否清pending。这样能发现回调分支只改一半状态。

对每个异步入口，列所属AioContext、持有引用、取消/drain办法和reset代数；对每个完成，列唯一写者、外部副作用与错误上报。无法停止的路径要进入迁移限制。

对每个live字段，标reset值、VMState位置或重建依据；对每个timer，标clock、deadline表达和post-load；对每条IRQ，标pending owner与派生函数。表格出现空白就继续审计。

最后在非默认状态执行reset、pause/resume、save/load与unrealize。四个动作分别清理、保留、恢复和释放，结果不应互相替代。固定标签、accelerator和irqchip模式写进报告。

## 实验一：观察 Resettable 三阶段

::: {.hands-on}
配套英文实验手册：[`trace-reset-phases`](../experiments/part-04-machine-and-device-models/chapter-17-device-lifecycle/trace-reset-phases/README.md)。

构建带 trace/debug符号的 `qemu-system-riscv64`，启动暂停的 `virt`，选择 CPU与 UART或模拟 AIA。先让设备进入非默认状态，再执行 monitor `system_reset`。用现有 reset tracepoint或 GDB记录 enter、hold、exit和 qbus遍历；没有相应事件时明确采用源码断点分支。

比较构造初态、reset前、enter后、hold后和 exit后字段。预期对象路径与 MemoryRegion仍存在，寄存器/FIFO/pending回到规范值，跨对象 IRQ在允许阶段更新。不要从 callback注册顺序猜测遍历顺序。
:::

## 实验二：审计一份 VMState

::: {.hands-on}
配套英文实验手册：[`inspect-vmstate-fields`](../experiments/part-04-machine-and-device-models/chapter-17-device-lifecycle/inspect-vmstate-fields/README.md)。

选择 `virt`的 SerialMM/SerialState或模拟 APLIC。列出 state结构全部成员，按持久字段、派生字段、宿主资源、timer/cache和 link分类；查主 VMState、subsections、needed、version与 hooks。每个未迁移字段都写出重建或省略依据。

用一组非默认状态验证：UART包含 FIFO数据和 timeout pending，APLIC包含 enabled+pending+target。执行保存/恢复后读取寄存器和 IRQ。只做源码清单时标“静态审计”，运行验证通过后才标“闭环”。
:::

## 实验三：在 alarm 到期前 reset 与恢复

::: {.hands-on}
本实验复用 [`trace-reset-phases`](../experiments/part-04-machine-and-device-models/chapter-17-device-lifecycle/trace-reset-phases/README.md) 的时序采集，并用 [`inspect-vmstate-fields`](../experiments/part-04-machine-and-device-models/chapter-17-device-lifecycle/inspect-vmstate-fields/README.md) 审计 Goldfish RTC；入口见[第 17章英文实验索引](../experiments/part-04-machine-and-device-models/chapter-17-device-lifecycle/README.md)。

设置未来 alarm并确认 timer armed。分两轮：第一轮在到期前 system_reset，预期 alarm/pending被清；第二轮在相同点保存恢复，预期 alarm按虚拟时间继续并只触发一次。再制造 pending但 masked状态，恢复后解除 mask检查 IRQ。

记录 QEMU virtual clock、alarm字段、timer pending和 irq line。reset与迁移结果应该不同；若两者都清 alarm或都立即触发，说明路径混淆。不要用宿主 wall clock停顿替代虚拟时钟数据。
:::

## 上游与源码证据清单

定位设备时从 `virt.c`类型名进入真正实现，确认 wrapper和 child。记录 instance、properties、realize、reset phases、unrealize、VMState及 timer/IRQ helper。任意一项缺少都标开放问题。

历史提交直接支持 APLIC/IMSIC何时补 reset API，当前源码说明 owner条件与清理字段。从“较晚补 reset”得到的工程教训属于作者分析，不能改写成维护者对首版质量的评价。

VMState结论只覆盖固定标签。邮件中的新字段或 RFC需要等最终提交、版本和测试；运行通过也要注明 accelerator和 irqchip模式。模拟 AIA通过不能替 in-kernel AIA背书。

## 小结

设备模型从寄存器回调延伸到 FIFO、timer、IRQ、后端和迁移。SerialMM包装地址/端序，SerialState维护 16550语义；Goldfish RTC展示时钟基准转换；PLIC/APLIC/IMSIC展示中断 owner如何决定 reset与 VMState。

qdev把 instance、property、realize、unrealize与 finalize分开，Resettable再以 enter、hold、exit组织 qbus reset树。构造、暂停、reset、迁移和销毁有不同目标，复用 helper时必须保持各自语义。

VMState是一份长期协议。持久状态显式保存，派生状态由 hook重建，宿主资源重新创建，可选状态按 owner/feature进入 subsection。下一章进入 PCIe和 RISC-V IOMMU：同一设备请求先经过 requester ID、device context与两阶段 DMA翻译，再到 RAM或 MSI路径，缓存与 fault queue又会带来新的 reset和迁移边界。
