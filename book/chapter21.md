# 测试、迁移与兼容性

一个 RISC-V 设备补丁可以顺利编译，也能把 Linux 启动到 shell，合入几个月后却在迁移中丢掉 pending IRQ。启动测试当时没有错，它验证的契约太宽，也太浅：固件、内核和设备恰好完成了一条正常路径，却没有把寄存器复位值、非法访问、IRQ 门控和迁移状态分别钉住。后来任何一层变化，失败都只能表现为整机超时。

QEMU 的测试体系服务于许多不同边界。单元测试约束局部算法，qtest 直接碰设备和 Machine，functional test 让真实固件或操作系统走完整流程，迁移测试又要在两个进程、两个二进制乃至两个版本之间验证状态连续。层次增加并不代表越靠上越“高级”，每一层都在回答不同问题。失败能落到最窄的责任边界，维护成本才可控。

本章写作口径为 QEMU `v11.1.0`，当前研究固定在官方 GitLab [`v11.1.0-rc0`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0)，commit `eca2c16212ef9dcb0871de39bb9d1c2efebe76be`。RISC-V/riscv64 是唯一体系结构主线。当前源码、上游提交与邮件、作者推断、尚未验证的兼容范围会分别标明，不把“同版本冒烟通过”扩写成跨版本保证。

## 本章目标

- 按契约选择单元测试、qtest、functional test 与迁移测试，理解它们为何不能互相替代；
- 从 RISC-V 寄存器、reset、IRQ、固件启动到迁移往返建立递进验证；
- 读懂 `VMStateDescription` 的字段、版本、hook、subsection 和恢复顺序；
- 区分 Machine 配置兼容、迁移流兼容、宿主能力兼容与后端可迁移性；
- 为测试输入、跳过、超时、随机性和失败材料建立可复查规则。

## 先写契约，再选测试入口

设备规格说 control 寄存器 bit 0 启用计数，status bit 0 表示完成，写一清零 IRQ。这里至少有四类契约：位级读写，非法宽度和保留位，reset 后默认状态，状态变化与 IRQ 的顺序。把它们全部交给 Linux 驱动间接覆盖，驱动可能只写一次合法值，也不会验证保留位；启动成功无法说明错误访问是否被拒绝。qtest 可以对每项行为直接断言，运行快，失败位置也清楚。

同一设备还要被 Machine 映射到正确地址，IRQ 接到正确 hart，设备树与固件描述一致，驱动最终可用。这些属于装配和软件集成，单独调用寄存器函数无法覆盖。functional test 启动 OpenSBI、U-Boot 或 Linux，可以发现地址图、DTB、启动参数与后端组合问题。它的失败包含更多组件，因此底层契约应先由更窄测试保护。

纯算法或数据结构适合单元测试。位图、队列、解析器、迁移编码 helper 不需要启动一台 Machine，直接构造输入即可获得快速反馈。单元测试若为了访问私有函数复制一份实现，又会失去价值；较好的做法是提取可独立验证的逻辑，同时让设备测试覆盖它与 QOM 生命周期的连接。

测试选择可以沿“谁拥有状态”来做。状态只在一个 Rust/C 结构中，用单元测试；由 MemoryRegion callback、reset 和 IRQ 改变，用 qtest；由 Machine、固件和驱动共同决定，用 functional test；需要跨进程或版本保存，用 migration test。一个功能横跨多层时，每层留一个最小断言，整机测试负责证明组合，底层测试负责定位。

:::: {.quick-quiz}
为什么一个成功启动 Linux 的 functional test 不能替代设备 qtest？

::: {.quick-answer}
整机启动只覆盖该镜像真正走到的合法路径，失败时还混合固件、DTB、内核、Machine 与后端。qtest 能直接约束寄存器、reset、非法访问和 IRQ，把回归落到设备契约；functional test 再验证这些组件组合后确实能工作。
:::
::::

## qtest 把设备放到显微镜下

qtest 客户端通过专用协议和 QMP 控制 QEMU，能够读写 guest physical memory、访问 I/O、查询 IRQ、推进虚拟时钟。设备可在 qtest accelerator 下创建，测试不必准备完整客户机指令流。由此得到的速度和确定性，很适合寄存器状态机。它也带来明确边界：没有真实 RISC-V 指令执行，CPU 异常、驱动内存序与固件行为不能从 qtest 结果推出。

一个小型 RISC-V MMIO 设备的首轮 qtest 从 reset 开始。读取所有可见寄存器，确认默认值与只读位；按支持的 1/2/4/8 字节宽度分别访问，检查对齐、endianness 与错误结果；对每个 writable mask 写全一、交替位和边界值；再次 reset，确认计数器、pending、FIFO 与 IRQ 回到规范状态。测试名直接描述契约，例如 `/riscv/bookdev/reset-clears-pending`，失败时不用翻一段整机串口。

IRQ 测试要观察电平状态机。先在 masked 状态制造条件，pending 可以变化而输出保持低；启用后输出升高；写一清除或消费事件后输出降低；level-triggered 条件仍存在时，清除可能立即重新拉高。仅断言“某次 IRQ 为 1”会漏掉边沿、重复和清除顺序。多 hart 设备再验证 target 选择，不能用 hart 0 的通过代表路由正确。

虚拟时间让 timer 测试更稳定。qtest 可以按指定步长推进 clock，先停在 compare 之前一 tick，确认无中断，再越过边界，确认 pending 与 IRQ。测试使用 guest-visible tick 作为判据，不依赖宿主 `sleep()`；后者在繁忙 CI 中会产生随机超时。若设备的时钟来自不同 clock domain，测试应先查询或固定频率，避免把单位错误掩盖为调度抖动。

负面输入需要预期结果。越界 MMIO 是返回零、记录 guest error、产生 access error，还是忽略写入，要根据设备规范和 MemoryRegionOps 声明决定。qtest 断言错误路径以后，后来开发者若改变策略会收到明确失败并重新审查，而不是无意中扩大客户机 ABI。随机 fuzz 可补充边界搜索，固定的最小回归仍要单独保留，否则 seed 变化会让已知 bug 时有时无。

qtest 也能验证 Machine 映射。启动 `virt` 或书中实验 Machine，查询设备树/QOM 路径与地址，再对映射地址访问；错误地址应保持未实现区域语义。若只直接实例化设备，MemoryRegion 本身正确却挂错地址的回归不会被发现。设备级测试与 Machine 级 qtest 可各一组，前者快，后者保护装配。

当前测试名受构建配置影响。RISC-V IOMMU、AIA 或某设备未启用时，相应二进制可能不存在。实验应先运行 `meson test --list`，按本次构建选择，保存 skip 原因。把“测试未构建”写成 pass 会制造覆盖幻觉；把预期不支持的平台一律算失败，又会让 CI 信号充满环境噪声。

## functional test 的演进说明了工程取舍

当前 [`tests/functional/`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/tests/functional) 以 Python 基础设施组织系统级测试。提交 [`fa32a634`](https://gitlab.com/qemu-project/qemu/-/commit/fa32a634329f4b2cdab8e380d5ccf263b1491daa) 的 Message-ID [`20240830133841.142644-9-thuth@redhat.com`](https://lore.kernel.org/qemu-devel/20240830133841.142644-9-thuth@redhat.com/) 引入新基础类，并移除对 Avocado 的依赖，QEMU 二进制与构建目录通过环境变量传入。这是可核对的上游陈述：测试框架与外部 runner 的耦合被主动缩小。

紧接着的 [`14973778`](https://gitlab.com/qemu-project/qemu/-/commit/1497377857ae4f41688f112903387032d939fb6e)，Message-ID [`20240830133841.142644-12-thuth@redhat.com`](https://lore.kernel.org/qemu-devel/20240830133841.142644-12-thuth@redhat.com/)，把 functional test 分成 quick 与 thorough。提交说明给出的理由是下载资产和运行时间不同：quick 可以进入普通 `make check`，thorough 留给专门目标。这里没有“越完整越应该每次运行”的简单规则，反馈时延与覆盖成本要分层管理。

提交 [`cce85725`](https://gitlab.com/qemu-project/qemu/-/commit/cce85725f10fbe92481e8314986e69dbe6ca0dd1)，Message-ID [`20240830133841.142644-13-thuth@redhat.com`](https://lore.kernel.org/qemu-devel/20240830133841.142644-13-thuth@redhat.com/)，让转换后的简单测试可以直接执行，提交说明明确把易于调试列为动机。CI 失败后，维护者无需先复刻完整 runner 命令，仍要保留 Meson 设置的环境和同一构建产物。直接执行是诊断入口，不代表可以忽略正式 suite。

资产管理由 [`9903217a`](https://gitlab.com/qemu-project/qemu/-/commit/9903217a4ed013228d95d8b1876b6053b2bc5e95)，Message-ID [`20240830133841.142644-15-thuth@redhat.com`](https://lore.kernel.org/qemu-devel/20240830133841.142644-15-thuth@redhat.com/)，引入基于内容哈希的缓存。当前 `Asset` 会校验 SHA-256，用哈希作为缓存文件名，并可通过环境变量选择缓存或禁止下载。URL 能访问只证明拿到了某个文件，内容哈希才把测试输入固定下来。

这四个提交属于同一演进脉络，却解决不同成本：框架依赖、suite 时长、单测诊断和外部资产。作者推断是，functional test 被设计成可独立运行且可分级的工程工具，不只是 CI 上的一盏绿灯。推断有多条上游陈述支持，仍应与维护者原话区分。

RISC-V 的当前例子可看 [`tests/functional/riscv64/`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/tests/functional/riscv64)。K230 启动覆盖由提交 [`a539bb91`](https://gitlab.com/qemu-project/qemu/-/commit/a539bb911ee1085c69ce00781acd2f13bd3cb82b) 加入，Message-ID [`20260711125320.72319-1-caojunze424@gmail.com`](https://lore.kernel.org/qemu-devel/20260711125320.72319-1-caojunze424@gmail.com/)。提交说明确认两条路径：QEMU 直接加载 Linux，以及经 SDK U-Boot 启动；资产 URL 固定到具体版本并校验 SHA-256，成功判据是进入 shell。它证明这两条启动链在给定资产上工作，不覆盖 K230 每个外设，也不证明迁移。

functional test 的成功判据应尽量靠近功能。只等串口出现 “Linux” 容易匹配到早期 banner，真正启动可能在稍后崩溃；等待 shell 又可能因登录配置变化失效。测试可先等阶段标记，再执行一条返回确定校验的命令。若目标是 OpenSBI trap 修复，判据应包含触发与恢复，而非泛化成整个发行版启动。

## 失败材料决定测试是否可维护

CI 超时是信息最少的失败。测试应在超时前保存 QEMU 完整命令、串口尾部、QMP `query-status`、进程退出码和关键日志。若能判断卡在固件、内核解压、驱动 probe 或 shell，就分别设置阶段性 deadline；总超时只作最后保险。每段等待输出预期模式和已见最后一行，维护者不用下载数百兆日志才找到停点。

跳过也要可诊断。缺少 KVM、宿主不支持某扩展、下载被策略禁止、测试二进制未构建，分别对应不同行动。探测条件写进测试，skip 消息包含缺失 capability。依赖环境的失败不能伪装成 pass；长期持续 skip 的关键路径应在 CI 覆盖报表中暴露，否则功能名义上有测试，实际上从未运行。

网络输入只在预取阶段出现。测试运行阶段优先使用经哈希验证的缓存，网络波动不应与 QEMU 行为混成一个结果。资产不可用时区分 404 这类固定错误与暂态网络错误，保留 URL、哈希和 cache 状态。若上游内容在同一 URL 被替换，哈希失败是正确报警，更新哈希前要审查新内容，不能为恢复绿灯直接改数字。

并发与随机测试保存 seed、线程数和调度相关参数。发现失败后先重放原 seed，再缩小输入，最终把最小序列加入固定回归。只增加重试次数会把错误率压低，却没有修复不变量。确实属于宿主资源抖动的测试，可以调整资源或 timeout，提交说明应给采样数据，防止真正死锁被“偶尔再跑一次”遮住。

测试日志也可能泄露客户机数据或密钥。公开 CI 使用专门的测试镜像，串口和 QMP 输出避免真实凭据；失败归档设置保留期。迁移测试会产生 RAM 流，通常不上传完整内容，只保存 section 摘要、错误位置和非敏感校验。可诊断性与数据最小化要一同设计。

## 迁移验证的是跨边界连续性

迁移把运行中的系统切成若干状态所有者：RAM、CPU、timer、中断控制器、设备、块/网络后端和未完成 I/O。源端要在一致切面上抽取，流格式要能表达，目标端要按合法顺序重建，Machine 和宿主 capability 还要兼容。任何一项缺失，控制面可能显示 `completed`，客户机恢复后仍会在下一次中断或 I/O 上偏离。

预复制阶段 vCPU 继续写 RAM，迁移层发送页面并记录重新变脏的部分；最终切换时停止新的写源，收尾 RAM，冻结设备并保存状态。顺序不能只看数据体积。若 vhost 或设备 DMA 在最后 dirty 收集后仍写，目标拿到旧页；若 timer 在设备恢复前开始走，目标可能产生源端没有的中断；若 vCPU 在 irqchip pending 加载前运行，会错过原本已经产生的事件。

迁移测试需要制造非默认状态。reset 值在目标重新初始化时也可能碰巧正确，无法证明字段真的传输了。测试设备应让计数器非零、FIFO 半满、IRQ pending 且暂时 masked，timer compare 接近到期；CPU 执行一个持续更新并带校验的 riscv64 循环。恢复后逐项检查值和行为：解除 mask 后中断恰好到达，timer 在正确虚拟时间触发，队列不会重复完成。

同一二进制的源目标测试先验证实现自洽，再换两个不同二进制验证流兼容。两类结果不能合并。相同构建能够序列化并读回自己的字段，仍可能无法读取旧版本，或默认 Machine 已变；跨版本失败也可能是命令行属性不一致，不一定来自 VMState。测试报告应列源/目标 commit、展开后的 Machine/CPU/设备属性和传输方向。

取消与失败路径也属于协议。目标拒绝字段时，源端是否仍能继续，timer、irqfd、后端和 dirty logging 是否恢复；预复制中途取消与最终 stop 后失败可能有不同保证。一次兼容性测试至少包含成功、预期拒绝、源端恢复运行。只验证管理命令返回错误，会漏掉源端已经被留在半暂停状态。

## VMState 描述客户机状态，不复制结构体

当前 [`include/migration/vmstate.h`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/include/migration/vmstate.h) 的 `VMStateDescription` 包含 `version_id`、`minimum_version_id`、priority、pre/post load/save hook、`needed`、字段数组和 subsections。`VMStateField` 则记录名称、offset、size、类型信息、flags、字段版本与存在条件。这些是固定源码事实，说明迁移格式由显式描述组成。

把整个 C 或 Rust 结构体原样写入流会带上指针、padding、锁、缓存、宿主句柄和编译器布局。目标进程中的地址没有意义，缓存可由权威字段重建，宿主 fd 也必须重新创建。真正需要保存的是决定客户机下一步行为的状态：寄存器、队列索引、pending、计数值、协商属性。字段选择属于设备 ABI 设计，宏只能减少编码样板。

版本解决格式演进。加入新字段时，可以提高 description 版本，并让字段只在新版本出现；读取旧流时给出定义明确的默认或在 post-load 重建。重新解释旧字段比新增字段危险，旧目标仍按原语义读取。`minimum_version_id` 抬高意味着明确放弃更早流，需要文档、兼容策略和测试支撑，不能因为实现方便悄悄改变。

subsection 适合可选状态，例如只有某扩展启用才存在的 RISC-V Vector 或 H 状态。`needed` 必须由稳定配置决定，若依赖一瞬间的 pending 值，流的结构可能随运行时摇摆，恢复逻辑会更难审查。可选 subsection 无法充当兼容逃生门：目标不支持源端必需的 CPU 扩展时，应在运行前拒绝，不能读完流后默默忽略。

pre-save 用于把权威状态同步进可序列化字段，post-load 用于校验并重建派生状态。KVM、vhost 或内核 irqchip 下，最新值可能不在 QEMU 对象；仅看到 VMState 字段存在，无法证明 pre-save 已经取回。恢复侧也不能在 post-load 完成前启动执行者。审查一项状态要沿“所有者—get—字段—load—put/重建”走完整链。

priority 表达恢复依赖，例如 IOMMU、总线和设备可能需要顺序。具体设备还会通过 reset、realize 与 VMState hook 交互：目标先创建相同对象图，再加载运行状态，不能把 migration load 当作第二次 realize。宿主资源在加载后重新申请，失败要通过明确 Error 返回，不能留下半连接 IRQ 或 MemoryRegion。

迁移格式还要验证输入。目标读取的长度、数组数、枚举和索引来自流，不能无限分配或越界。`VMSTATE_VALIDATE`、equal/le 类型和 post-load 检查可以约束配置或值。兼容性不等于无条件接受旧数据，损坏或恶意流应在 vCPU 启动前失败，并指出 section 与字段。

:::: {.quick-quiz}
为什么不应直接序列化整个设备结构体？

::: {.quick-answer}
结构体含指针、padding、锁、缓存和宿主资源，布局也会随语言、编译器与版本改变。迁移流只应显式保存决定客户机后续行为的字段，并为字段提供版本、默认值、存在条件和加载校验；目标端重新创建宿主对象与派生状态。
:::
::::

## RISC-V 状态要按所有者拆开测试

TCG 下大部分 CPU 架构状态位于 `CPURISCVState`，KVM 运行时最新 GPR、CSR、Vector 和 timer 可能在内核。两种 accelerator 共用部分 [`target/riscv/machine.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/machine.c) VMState，却需要不同的同步入口。迁移实验必须写 accelerator；TCG 通过不能证明 KVM one-reg 覆盖，KVM 普通 S 态通过也不能证明活动 H/VS 上下文完整。

CPU 测试让寄存器偏离 reset。每个 GPR 写不同模式，浮点和 Vector 使用可校验数据，`satp`、特权级和中断状态进入非默认值。涉及 H 扩展时，再分别覆盖 HS/VS CSR 与两阶段翻译。恢复后不仅读取寄存器，还执行依赖它们的计算和访存；一个字段读回正确，派生 TLB 或虚拟化视图未重建时，下一条指令仍可能失败。

中断控制器测试按实际模式选择。用户态 PLIC、模拟 AIA 的 pending/enable/priority/target 可由 QEMU VMState 保存；in-kernel 模式的权威状态需要对应 KVM device get/set。测试要制造 masked pending、claim 未 complete 和多 hart 路由。空闲迁移只覆盖零值，最容易给出虚假的完整感。

timer 测试记录客户机单调时间、compare 和预期事件。在源端暂停一段宿主时间，目标恢复后客户机虚拟时间不应把暂停全部当作运行；中断也不能重复或丢失。不同宿主 timebase、clock 参数和 accelerator 会改变可迁移条件，部署测试先比较 capability，再做行为验证。

设备与 RAM 同时活动。让客户机循环写每页标记，另一个设备执行 DMA 或 virtio I/O，迁移后检查所有页与请求恰好一次。只用 CPU 写 RAM，无法覆盖 vhost/设备 dirty 路径；只看文件最终大小，也无法发现重复 sector。后端类型和 in-flight 支持要列入矩阵。

## Machine 兼容不是一个开关

Machine 类型决定地址图、默认设备、CPU 属性、固件接口与兼容属性。成熟平台常用带版本的 Machine 与 compat properties 固化旧行为，新版本可以采用新默认，旧工作负载仍选择旧版本。这个机制解决的是配置与客户机可见机器契约，VMState 解决流中状态字段，两者相互依赖，却不是同一层。

通用迁移 qtest 在提交 [`dcf389cb`](https://gitlab.com/qemu-project/qemu/-/commit/dcf389cbc84c2b714d49887775918c5f03f73864) 中加入 `find_common_machine_version()`，Message-ID [`20231018192741.25885-7-farosas@suse.de`](https://lore.kernel.org/qemu-devel/20231018192741.25885-7-farosas@suse.de/)。上游提交说明给出了明确原因：用两个不同 QEMU 二进制测试迁移时，需要找到两端都支持的 Machine 版本。当前 helper 会解析 alias，检查一个二进制是否认识另一个的类型，选出共同项，否则让测试失败。

这项通用能力不能直接套成 RISC-V `virt` 的版本列表。固定锚点的 [`hw/riscv/virt.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/virt.c) 只注册 `MACHINE_TYPE_NAME("virt")`，没有在该文件中注册 `virt-X.Y` 系列，也没有看到本类型的 compat props 数组。这是当前源码事实。由此可以说 RISC-V `virt` 在该标签下缺少常见的版本化选择，不能说它永远不会兼容，也不能凭通用 helper 宣称已有跨版本 ABI。

对于本书实验，先显式固定所有可见属性：CPU model 与扩展、hart 数、AIA/PLIC 模式、ACLINT、IOMMU、PCIe/virtio 设备、固件、内存和启动参数。源目标展开命令行逐项比较，再执行迁移。若以后上游引入版本化 `virt`，研究应沿提交和邮件确认旧默认怎样固化，不能只把新字符串填进脚本。

Machine 相同也不保证后端兼容。源端使用 KVM、in-kernel irqchip 或 vhost，目标缺少相同 capability 时，状态所有权和恢复接口可能不同。某些设备允许切回用户态实现，是否能在迁移中转换要由代码和测试证明。管理层应在传输前协商，目标端运行后才发现缺状态会造成静默损坏。

CPU 属性尤其敏感。RISC-V ISA 扩展是集合，Vector 还有 VLEN 等参数，AIA 有模式和 guest file 数，timer 有频率。源端用 `-cpu max` 或宿主相关模型，目标端同名模型不一定给出相同实际能力。测试保存 QMP 展开的 CPU 属性与 DTB/ACPI 中发布给客户机的内容，按交集选择，而非只比较命令行字符串。

:::: {.quick-quiz}
Machine version 解决的核心问题是什么？

::: {.quick-answer}
它把实现继续演进与旧客户机看到的机器契约分开，让旧默认可由明确类型和 compat 属性保留。它不替代 VMState、CPU capability 或后端保存恢复；固定锚点的 RISC-V `virt` 尚未提供常见的版本后缀系列，因此跨版本能力必须实测并限定配置。
:::
::::

## 建立兼容性矩阵，别只跑一条绿路径

矩阵的行是状态或接口，列是组合。CPU 行包含 GPR、CSR、Vector、H/VS、timer；中断行包含 PLIC、模拟 AIA、split/hwaccel（若环境支持）；设备行包含寄存器、队列、pending、后端；Machine 行包含地址图和属性；控制面行包含 QMP schema。每个格子写源码闭环、运行验证、预期不支持或未验证，空白不能自动算通过。

版本列至少有当前到当前、旧到当前、当前到旧。迁移协议未必双向对称：新目标可以给旧流新增字段默认值，旧目标却不认识新 section。产品只承诺单向升级时，测试矩阵也要清楚标出，别让反向失败看似回归。书中实验若只有同二进制，结论明确写“同版本自洽”。

配置列一次只改一个变量。相同 `virt` 下改变 AIA 模式，预期可能在启动协商或迁移加载时拒绝；改变 CPU Vector 参数，预期在目标运行前失败；移除一个可选且未使用设备，是否允许取决于 Machine 与流 section。每个负面用例都要写期待的错误层，若目标启动后才崩溃，虽然“最终失败”，仍不符合安全兼容策略。

测试数据带非默认状态。CPU 只在 idle、IRQ 全为零、队列为空时迁移，很多缺字段不会暴露。矩阵旁给每行一个激活方法：写寄存器模式、制造 masked pending、挂起一笔 I/O、让 timer 即将到期、触发两阶段页错误后停在 handler。激活脚本与结果校验共同保存。

连续运行也要覆盖。迁移成功后让客户机继续多个状态周期，重复中断、I/O 和内存校验。某些恢复错误在第一步正常，第二次 clear、wrap-around 或 reset 才出现。短 smoke test 保留在每次提交，较长稳定性测试进入 thorough/定时 CI，两者分别报告。

## 从测试失败反推设计边界

qtest 的 reset 断言失败，先看设备本地字段与外部副作用是否分阶段清理。QOM reset 可能有 enter/hold/exit，IRQ 改变不一定允许在最早阶段执行。一次修复若把所有字段归零却在错误阶段访问其他对象，单设备测试通过，Machine reset 仍会出错。回归应覆盖局部值和系统连接。

functional test 在 OpenSBI 之前失败，检查 reset vector、固件映射、hart 启动和 DTB；进入内核后卡在 probe，再根据设备和中断状态下钻。不要直接延长 timeout。阶段变化常由 Machine 装配或发布给客户机的描述引起，设备 qtest 可能全部通过，恰好说明问题在组合层。

迁移 load 报字段不匹配，先记录 section、版本、源目标 Machine 与 CPU 属性。若字段应该相等，错误是提前拒绝不兼容的保护；测试应期望该错误。若配置相同仍失败，检查默认属性是否在两个版本中变化，或 source pre-save 是否写了宿主派生值。把 equal 校验删掉只会让不兼容继续运行。

恢复后偶发丢 IRQ，寻找源端停止前的权威 pending、流中字段、目标 post-load 和输出重算。四个节点中第一个偏离就是实现边界。若字段存在而源端值旧，问题在同步；流正确而输出未重算，问题在恢复；目标过早启动则属于顺序。这样的定位也告诉我们应补 qtest、migration test 还是 runstate 测试。

一次修复提交最好同时带最窄回归和必要的上层用例。最窄回归稳定重现状态机，整机用例确认真实路径；若下载和运行很重，归入 thorough。commit message 写原始失败、状态所有者和兼容选择，后来的维护者才能理解为何保留看似多余的版本分支。

## 一个 RISC-V 设备怎样逐层长出测试

教学设备最初只有一个可读写寄存器。第一份测试放在安全的状态逻辑旁，覆盖写入掩码、读回和 reset；接入 MemoryRegion 后，qtest 再覆盖访问宽度、对齐、endianness 与越界。此时若单元测试通过、qtest 失败，问题多半在 callback 适配或地址解释，范围很窄。直接从 Linux 驱动起步会把这两层错误都压成 probe 超时。

加入 IRQ 时，测试先把条件和输出分离。状态逻辑验证 pending/enable 组合，qtest 验证 qemu_irq 电平与 reset phase，Machine qtest 验证它连接到 RISC-V 中断控制器的正确 source。最后的 functional test 让驱动触发中断并确认计数。每层只多一个新所有者，失败路径容易追踪。

加入 timer 后，单元测试验证 compare 算法，qtest 用虚拟时钟推进边界，整机测试观察客户机 timer 使用。若定时器还要迁移，迁移测试在 compare 即将到期时切换；恢复后事件只能触发一次。`sleep()` 只用于等待测试框架响应，不能代替虚拟时间断言，否则 CI 调度会把正确实现判成随机失败。

加入 DMA 或队列后，输入面扩大。单元测试可验证 descriptor 长度与索引，qtest 构造合法、环绕和越界队列，functional test 让真实驱动传输，迁移测试挂起一笔未完成请求。安全测试还要覆盖 guest-controlled 长度、地址溢出、IOMMU translation failure 和后端短读。Rust 能限制本地数组访问，也不能免除协议输入验证。

设备进入 Machine 之前，先决定它是默认创建、可选属性还是命令行设备。默认设备会改变所有该 Machine 客户机的硬件外观，需要更强兼容审查；可选设备需要测试 absent/present 两条路径；命令行创建要验证 QOM 属性和 realize 错误。测试布局跟着产品选择变化，不能把装配问题留给最后一条启动测试。

迁移支持最好单独提交。运行设备先合入时明确标记 `unmigratable` 或受限，不让管理层误判；下一步列状态字段、版本和 post-load，再加往返与负面测试。上游首个 Rust 设备后来单独增加迁移支持的历史也说明实现与迁移契约可以分开审查。对书中 RISC-V 设备，这种拆分让寄存器语义与长期 ABI 各有清晰 diff。

测试数量不按功能行数机械增长。一个 mask 函数十个等价值不需要十条命名测试，可以表驱动；reset、IRQ 和迁移却涉及不同生命周期，应分开。判断标准是失败是否给出独立行动：若两个断言失败后都修改同一逻辑，可合并；若一个指向设备、一个指向 Machine，拆开更利于维护。

## reset、热复位与错误恢复

设备常有冷启动、系统 reset、总线 reset、迁移恢复等入口，表面都把字段“恢复”，语义并不完全一样。普通 reset 应回到客户机规范状态，迁移 load 要重建源端任意状态，错误回滚又要释放部分宿主资源。测试若只调用一次全局 reset，会把这些路径混在一起。

QOM reset 分阶段的目的之一，是让本地状态清理与对外副作用有顺序。进入阶段可以冻结或重置局部字段，所有对象进入 reset 后，hold 阶段再改变 IRQ、时钟或其他对象，退出阶段恢复允许的活动。测试在每个阶段观察外部线很诱人，却可能依赖未承诺的中间状态；应按 Resettable 契约选择断言，最终状态与禁止副作用的阶段最关键。

热复位时后端请求怎么办，需要设备明确选择。可以排空、取消、让其完成后丢弃结果，或把 in-flight 状态纳入协议。测试制造一笔正在进行的请求，在 reset 前后检查队列索引、DMA、副作用和 IRQ。只确认寄存器归零，会漏掉旧 callback 在 reset 后写回新状态的竞态。

realize 失败也要原子。故意提供非法地址、缺失 chardev 或不支持的属性，QEMU 应返回具体 Error，不应留下已注册 MemoryRegion、IRQ 或 timer。随后用同一进程创建一个合法实例，确认失败没有污染全局状态。错误路径很少出现在启动 happy path，却是设备可组合性的基础。

迁移 post-load 校验失败与 realize 失败相似，发生时目标对象已部分构造。测试用受控错误字段触发拒绝，确认 vCPU 尚未运行、目标退出或保持安全状态，源端能按协议继续。若错误只打印 guest error 后继续，损坏状态可能在很久以后才显现。

## 差分、性质和模糊测试怎样配合

固定样例适合保护已知契约，仍可能漏掉组合空间。性质测试可以声明不变量：只读位在任意写入后不变，写一清零只会减少指定 pending，reset 两次与一次结果相同，合法队列索引始终落在环大小内。生成大量输入以后，失败会缩减为最小序列，再转成固定回归。

差分测试需要可靠参照。书中 RISC-V 教学设备没有真实硬件作为 oracle，可以比较 C 与 Rust 两个等价实现，或比较模型与独立规格函数。两个实现都从同一代码复制位运算时，它们可能共同出错；参照要尽量独立，结果不一致后仍回到规范判断，不能按多数投票。

对 RISC-V CPU 指令或 CSR，差分可比较 TCG 与另一可信实现，但 accelerator 能力、未定义行为、timer 和并发要先归一。KVM 依赖真实宿主，不适合作为所有扩展的绝对 oracle；规范允许多种结果的输入应过滤。差分发现的是偏离，哪一侧错误要靠规范、源码和历史继续确认。

模糊测试擅长寻找解析、长度、状态序列漏洞。qtest 提供快速设备输入面，fuzzer 可生成 MMIO 序列、reset、clock step 和 IRQ 操作。每个 crash 保存 seed、QEMU commit 和最小输入，修复后加入确定性测试。只在每日随机运行中保留 seed，会让回归依赖运气。

迁移流也可做受限变异。以测试生成的非敏感流为种子，修改 section 长度、版本、数组数与枚举，目标应清晰拒绝，不能越界或在错误后运行。迁移格式复杂，变异工具必须理解基本 framing，纯随机字节常只覆盖 magic 检查。安全结果和兼容结果分别报告，拒绝损坏流不等于能读旧合法流。

## 迁移阶段逐步写成断言

准备阶段先验证目标配置。目标二进制应认识 Machine、CPU 属性和设备，所需 accelerator 与后端可用，传输通道建立。任何硬性不兼容尽量在源端停机前暴露。测试给目标故意移除一个必要 capability，确认管理层在传大量 RAM 之前给出具体错误；如果错误只能在 load 后发现，记录停机影响。

预复制阶段验证脏页进展。客户机按固定模式循环写 RAM，每页计数满足可检查关系；测试等待目标收到标记页，再确认源端继续把已发页面写脏。统计传输轮次和剩余量只用于进展诊断，最终正确性由目标内存内容决定。高脏页率可能让迁移收敛失败，这属于策略结果，不应被无限 timeout 掩盖。

停机阶段建立冻结序列。先阻止 vCPU 继续执行，再协调设备、DMA 和后端，收集最终 dirty，保存 CPU/timer/irqchip/设备状态。实际 QEMU 代码由多个框架 hook 完成，测试可用 trace 与 QMP 事件观察关键偏序。它不需要给每个函数强加全局顺序，但必须证明保存某状态以后没有其所有者继续修改。

传输流按 section 携带配置与状态。测试一般不应依赖每个字节偏移，因为内部 framing 会演进；可以使用迁移分析工具记录 section 名、版本和大小，针对需要兼容的字段做稳定断言。发现 size 增长时，先查新字段与 subsection，不能把所有变化判成回归；无解释的大幅增长则需要审查性能和隐私。

目标加载阶段要求对象图已构造，字段按版本读取，post-load 校验并重建派生状态，宿主资源重新连接。测试在首个目标 vCPU 运行前采集 CPU、timer、IRQ 和设备摘要，确认必要 put 已完成。若只能在运行后读取，也可让目标保持 `-S` 或用迁移 defer 机制，避免客户机修改证据。

恢复阶段验证行为连续。客户机计数继续而非归零，timer 在虚拟时间上连续，pending IRQ 解除 mask 后到达一次，未完成 I/O 依据协议完成或重试。仅看 `query-migrate` 为 `completed` 是控制面成功，未覆盖客户机语义。长时间运行与第二次迁移可以发现清理不完整、重复 handler 和 wrap-around。

源端清理也要检查。成功切换后，源端不再执行或写共享后端；失败取消后，源端重新启用 timer、irqfd、vhost 与 dirty tracking。测试可在取消后继续 workload，再尝试一次正常迁移。第二次成功很有价值，它证明第一次错误没有留下隐蔽的生命周期污染。

## 四种兼容性分开报告

第一种是客户机硬件接口兼容。地址图、寄存器、IRQ、DTB/ACPI、CPU ISA 和默认设备决定客户机看到什么，Machine 与 compat 属性主要约束这一层。测试使用旧镜像或明确设备访问，不能只比较 QEMU 对象名称。对当前 RISC-V `virt`，未版本化类型意味着每次默认变化都需要特别审查和回归证据。

第二种是管理接口兼容。QMP command、字段、错误与事件被编排工具使用，HMP 文本不承担同等契约。测试按 QAPI schema 发请求，覆盖字段缺省、显式值和错误。一个设备运行兼容，QMP 属性改名仍可能破坏部署；两者要分开记账。

第三种是迁移流兼容。VMState section、字段版本、subsection 与 load 校验决定新旧进程能否交换状态。它有方向性，也受 Machine 选择影响。测试报告源到目标方向，不能用 A→B 通过推出 B→A。保存/加载同一结构只证明自洽，不证明旧版本。

第四种是宿主执行兼容。KVM one-reg、irqchip、vhost、IOMMU、timer frequency 和 CPU 扩展属于宿主/内核能力。QEMU 可以提供协商和回退，实际是否语义等价需要对应实现。两个命令行完全相同，宿主能力不同仍可能产生不同对象所有权。生产矩阵把内核与硬件列入版本信息。

四种兼容可以独立失败。Machine 接口相同，迁移流字段可能新增；流能读取，目标宿主却缺 Vector 长度；客户机继续运行，QMP 监控字段却变化。报告只写“兼容/不兼容”会丢掉修复入口。每个失败标层次、预期协商点和对客户机的影响。

## CI 分层与覆盖债务

提交前运行最快的单元和 qtest，普通 CI 加 quick functional 与核心 migration smoke，thorough 任务下载镜像、跑长启动和大矩阵，定时任务覆盖多版本与低概率竞态。分层让开发反馈维持分钟级，也让重测试有稳定位置。把所有测试塞进每次提交，最终往往导致超时、禁用或无人看结果。

测试选择要看改动面。修改 RISC-V CSR，运行 CPU/qtest、相关 functional 和 TCG/KVM 能力检查；修改 VMState，必须加迁移；修改 Machine 地址图，设备 qtest 之外还要启动固件和检查 DTB；修改 Rust wrapper，运行 Rust 单测、C/Rust 边界测试和实际设备 qtest。路径匹配可以优化 CI，不能把跨目录依赖删掉。

覆盖债务要显式记录。某测试因缺 RISC-V KVM 宿主长期 skip，报表应显示；某迁移组合尚无 in-kernel AIA 保存接口，标 unsupported/待验证；某 functional asset 暂时下线，标 blocked。绿色总数不反映这些空洞，维护者需要一张“应该跑、在哪里跑、最近一次何时通过”的表。

flaky test 先统计再处理。保存失败率、宿主、阶段和最后进展，用相同输入重放。若根因是竞态，补状态同步和回归；若资源不足，调整 runner；若外部下载，移到预取。无限重试会让 CI 变绿，却使少量真实回归长期积累。临时 quarantine 要有负责人、问题链接和退出条件。

测试本身也需要 review。断言是否真的会在缺陷存在时失败，错误路径有没有被 try/except 吞掉，skip 条件是否过宽，timeout 是否把慢当错，资产哈希是否固定，清理是否会杀错进程。最有说服力的新增回归，是先在未修复代码上稳定红，再应用补丁变绿，并把这一过程写进提交说明。

## 补丁审查清单

新增设备行为时，先问客户机可见契约是什么，最小测试在哪层。寄存器和 IRQ 有 qtest，固件集成有 functional，迁移字段有 active-state 往返。若作者只给启动截图，评审应要求把关键状态拆出来；若只给单元测试，也要确认 QOM/MemoryRegion 适配被覆盖。

修改 VMState 时，逐字段问所有者、默认、版本和恢复。新字段是否真的客户机可见，旧流没有它时怎样重建，目标缺 capability 时何时拒绝，pre-save 是否拉取内核状态，post-load 是否在 vCPU 前完成。测试至少让字段非默认，并覆盖一个旧/新方向或明确说明当前只有同版本。

修改 Machine 默认时，列出地址图、设备树、CPU 与后端影响。固定标签的 RISC-V `virt` 没有常见版本化入口，变更尤其需要说明已有客户机怎样继续使用旧行为。若选择不兼容修复，提交与 release note 要明确；若增加属性保留旧行为，测试显式选择两种值。

修改测试框架时，检查执行成本、直接调试、资产与 skip。quick/thorough 分类是否合理，测试能否单独运行，失败材料是否足够，离线缓存是否可用。框架重构不应悄悄减少 RISC-V 架构覆盖，前后 suite 列表和实际执行数要对比。

最后核对证据措辞。当前源码事实用固定 tag 链接，提交动机附 Message-ID，实验结果带环境。由测试缺失得到的只能是“未覆盖”，不能写成“不支持”；由同版本通过得到的只能是该配置自洽，不能写成“向后兼容”。这条语言纪律能阻止兼容承诺在转述中不断膨胀。

## 把 RISC-V 迁移状态做成一组可观察模式

普通整数状态可以让每个 hart 的 x1 至 x31 写入不同模式，PC 落在各自循环，内存中保留 hart ID 与轮次。源端停止时通过客户机自检或调试同步记录摘要，目标恢复后继续计算，最终 checksum 同时依赖全部寄存器。只从 QMP 看 CPU 数量，无法发现一颗 hart 的寄存器被另一颗覆盖。

页表状态使用两套映射。一个虚拟页持续读写，另一个页在源端已修改 PTE 并执行相应 fence。迁移后访问应遵循新映射，旧的 TLB/TB 派生缓存不必进入流，却必须按恢复协议失效。H 扩展实验再加入 VS-stage 与 G-stage，各使用可区分的 fault 地址；若当前 accelerator 没有完整状态闭环，矩阵保持未验证，不为通过实验裁掉状态。

Vector 状态不能只写 v0。为多个向量寄存器填充不同 lane 模式，保存 `vl`、`vtype` 与相关控制，恢复后执行一轮向量计算并比较内存结果。目标 VLEN 与扩展集合在迁移前检查。若宿主不支持 KVM Vector，测试明确 skip 或改用 TCG，结果不跨 accelerator 外推。

timer 模式把 time、compare 与中断组合起来。源端把 compare 设在未来，迁移开始时距离到期仍有可测间隔；目标恢复后事件不能立即重复，也不能永远不来。再做一个 pending 状态：源端事件已到期但中断被 mask，目标解除 mask 后应交付一次。前者验证时间连续，后者验证 pending 保存，两项失败指向不同字段。

PLIC/AIA 模式让两个 source、两个 hart 与不同 priority 同时活动。源端保留一个 masked pending，一个已 claim 未 complete，再迁移；目标分别解除与完成，检查路由和次数。当前 irqchip 后端若把权威状态放在内核，先确认 get/set 接口，不能读取用户态影子后宣布通过。测试报告写 `aia=none`、`aplic` 或 `aplic-imsic` 等实际配置。

virtio/I/O 模式需要外部副作用判据。给每个请求写唯一序号，迁移时让一笔请求 in-flight，目标端记录完成集合；集合必须无缺失、无重复，块数据另做内容校验。后端若不支持 in-flight 迁移，应在命令开始前拒绝或先排空，测试接受明确策略，不接受控制面成功后数据偶发变化。

这些模式组合成 smoke 和 thorough 两档。smoke 选整数、内存、一个 timer 与简单设备，几分钟内完成；thorough 覆盖 Vector、H、复杂 irqchip、多 hart 与 I/O，在具备 capability 的 runner 定期运行。每个模式都有独立激活和校验，某项 skip 不会让整次结果看似全通过。

## 失败怎样成为兼容承诺的一部分

兼容失败并非越晚越准确。目标缺 Machine、CPU 扩展或必要后端时，理想行为是在源端停机前拒绝，并给管理层结构化原因；流损坏或字段版本不合法，只能在读取阶段发现，也必须保证 vCPU 未启动。测试把“第一个允许失败的阶段”写成断言，能推动错误从客户机崩溃前移到配置协商。

错误文本本身也分层。QMP 返回的 error class 与描述面向管理工具，测试不宜死锁整句自然语言，可检查结构化类别和关键对象；日志补充 section、字段与 capability，方便人工定位。客户机串口不应是迁移配置错误的唯一出口，因为客户机可能已经无法运行。

目标部分加载后失败，清理路径要释放监听器、fd、线程与临时文件。反复运行负面测试可以发现资源泄漏：同一进程或 runner 连续执行数十次，监控 fd、线程和临时目录。一次失败后第二次因端口占用而失败，说明兼容拒绝虽然正确，生命周期仍有缺陷。

源端的恢复能力按迁移阶段定义。协商或预复制失败通常应继续运行；最终切换后某些错误可能无法无损回滚，管理层需得到明确状态。测试不能假设所有失败都自动恢复，也不能只确认进程存在。继续执行客户机计数、timer、IRQ 和 I/O，才证明服务恢复。

这些负面结果应进文档和 release 说明。哪些 RISC-V CPU/irqchip/后端组合可迁移，哪些只支持同版本，哪些明确拒绝，部署者需要在调度前知道。源码中一个 `unmigratable` 标志很重要，却不等于用户已理解限制；测试、错误和文档三处一致，兼容边界才可操作。

## 实验一：运行并审查 RISC-V qtest

::: {.hands-on}
配套英文实验手册：[`run-riscv-qtests`](../experiments/part-05-engineering-and-evolution/chapter-21-testing-and-compatibility/run-riscv-qtests/README.md)。

在同一 QEMU commit 的源码与构建目录中，先用 `meson test -C "$QEMU_BUILD" --list` 枚举本次配置实际生成的 RISC-V 测试，再选寄存器/CSR、IOMMU 或其他可用的窄测试，带 `--print-errorlogs` 运行。每个结果回到测试源码，记录它控制的接口、明确断言、使用的 Machine/accelerator 和未覆盖边界。

随后在书中教学 MMIO 设备或一个可安全修改的本地分支里制造单一回归，例如 reset 不清 pending、保留位可写或 IRQ 未降低。确认最小 qtest 稳定失败，整机启动是否可能仍成功，再修复并重跑。报告把 skip 与 pass 分开，附构建配置、测试名、命令和日志，正文用中文解释失败怎样缩小状态所有者。
:::

## 实验二：RISC-V 迁移兼容冒烟与负面用例

::: {.hands-on}
配套英文实验手册：[`migration-compatibility-smoke`](../experiments/part-05-engineering-and-evolution/chapter-21-testing-and-compatibility/migration-compatibility-smoke/README.md)。

先使用两个完全相同的 QEMU `v11.1.0` 构建，在 TCG 下固定 RISC-V `virt`、CPU 属性、内存、irqchip 与设备。客户机持续更新带校验的计数，源端另制造 timer 和设备非默认状态；通过 QMP 启动迁移，等待 `completed` 与目标 RESUME，验证计数单调、校验一致、IRQ/timer 行为连续。保存两端原始 QMP JSONL、串口和展开命令行。

第二轮只改变一项明确属性，例如 CPU 扩展或 AIA 模式，预先写期待的拒绝阶段。若迁移没有提前失败而目标恢复后偏离，记录为兼容缺口。环境允许时，再换两份不同 commit 的二进制，只对共同且显式固定的配置做单向测试；鉴于固定标签的 RISC-V `virt` 没有版本后缀，本实验不声称通用跨版本保证。
:::

## 证据边界与开放问题

固定源码能够确认 qtest/functional 目录结构、Asset 的内容哈希、VMState 字段与 hook、迁移 qtest 的共同 Machine helper，以及 RISC-V `virt` 当前只有未版本化类型。四个 functional framework 提交和对应 Message-ID 直接说明框架脱离 Avocado、quick/thorough 分层、直接执行与资产缓存的动机；共同 Machine helper 的提交说明了双二进制测试需求。

作者推断包括：测试层次是状态所有权的映射，迁移能力是“源端抽取、流格式、目标重建、Machine、宿主/后端”的交集，RISC-V `virt` 缺少版本化类型会提高显式配置和真实跨版本测试的重要性。这些结论由源码与失败模式支持，仍不是兼容承诺。

开放问题必须落到组合上：某一对 QEMU 版本、CPU model、Vector 参数、AIA 模式、KVM 内核和设备后端是否能迁移；当前没有测试的格子就写未验证。未来新增 `virt-X.Y`、KVM 状态接口或 Rust 设备 VMState 后，先更新矩阵和实验，再修改叙述，不能从功能名称推断兼容自动延伸。

::: {.source-path}
本章主要阅读 [`tests/qtest/`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/tests/qtest)、[`tests/functional/`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/tests/functional)、[`tests/qtest/migration/`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/tests/qtest/migration)、[`migration/`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/migration)、[`include/migration/vmstate.h`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/include/migration/vmstate.h)、[`target/riscv/machine.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/machine.c) 与 [`hw/riscv/virt.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/virt.c)。体系结构状态和实验只使用 RISC-V/riscv64。
:::

## 小结

测试的价值体现在失败落点。单元测试约束局部算法，qtest 直接验证设备寄存器、reset、IRQ 和虚拟时间，functional test 覆盖固件、Machine、DTB 与操作系统，迁移测试检查状态能否跨进程、配置和版本继续。多层同时存在，既能快速反馈，也能证明组合有效。

迁移进一步要求显式 ABI。VMState 保存客户机可见状态，版本和 hook 负责演进与重建；Machine、CPU capability 和后端能力在流之外决定目标能否接受。固定锚点中 RISC-V `virt` 没有常见的版本化 Machine 系列，因此本书不替上游许诺跨版本兼容，只给出可重复的同版本基线、负面用例和双二进制研究方法。每个新结论都要回到状态矩阵、源码链与实际实验。
