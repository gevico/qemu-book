# SoftMMU 与 RISC-V 地址转换

一条 `lw a0,0(a1)` 在 RISC-V 客户机里只有四个字节，到了 QEMU system emulation，却要回答一串问题：`a1` 是哪一级虚拟地址，当前以哪个特权态访问，页表根在哪里，PTE 权限是否允许，PMP 会不会拦住，最终物理地址落到 RAM 还是设备。若每次 load 都从头走完这条路径，动态翻译省下的译码成本很快会被页表遍历吃掉。SoftMMU 的工作，是把常见结果压进可内联的 software TLB，同时保留慢路径的全部 RISC-V 语义。

这一章的“地址”会很多。阅读时始终标注层级：客户机虚拟地址 GVA，虚拟机中的 guest physical address GPA，QEMU machine 使用的 system physical address，以及 QEMU 进程里的 host virtual address。把任何两个都简称“物理地址”，两阶段转换和 MMIO 很快会混成一团。

## 本章目标

- 区分 GVA、GPA、system physical address 与 host virtual address；
- 理解 `CPUTLBEntry`、`CPUTLBEntryFull`、victim TLB、MMU index 和 TLB fill；
- 跟踪 RISC-V Sv39 页表、PTE 权限、PMP 与精确 fault；
- 说明 H 扩展 VS-stage 与 G-stage 如何组合，又怎样保留阶段相关异常；
- 分析 `SFENCE.VMA`、`HFENCE.VVMA`、`HFENCE.GVMA` 与跨 vCPU flush 协议。

## 四种地址先排好队

在没有虚拟化的普通 RV64 S-mode 中，客户机 load 给出 virtual address，`satp` 指向页表，转换后得到客户机物理地址；QEMU machine 的 MemoryRegion 拓扑再把这个地址解析到 RAM 或设备。RAM 最终可以形成 QEMU 进程的 host pointer，MMIO 则进入设备回调。这里已经有三层，host pointer 只是 RAM 快速路径的结果，不是客户机能够观察的地址。

H 扩展打开 V=1 后，VS-stage 使用 `vsatp` 把 guest virtual address 转成 guest physical address，G-stage 使用 `hgatp` 把 GPA 转到 hypervisor 管理的 system physical address。页表本身也在 guest memory 中，读取 VS-stage PTE 时，那次隐式访问还要经过 G-stage。于是一次客户机 load 可能包含“为走第一阶段而发生的第二阶段访问”，错误报告必须说明失败来自哪里。

QEMU 的物理地址分派仍在两阶段结果之后。G-stage 成功不代表一定是普通 RAM，system physical address 可以落到 `virt` machine 的 UART、PLIC/AIA、PCIe window 或未映射洞。设备返回 transaction failure 时，RISC-V 目标还要把它转成合适 access fault。地址转换与设备拓扑相接，却由不同模块负责。

画调用图时建议为每条边标单位和宽度。GPA 在 Sv39x4 下比普通虚拟地址有不同合法位范围，host pointer 又是宿主进程宽度。2026 年提交 [`2e05b6ec89`](https://gitlab.com/qemu-project/qemu/-/commit/2e05b6ec89) 将 `guest_phys_fault_addr` 扩为 `hwaddr`，提交说明指出原先宽度不足。一个类型修复足以说明，名字里写了 address 仍不代表可以随手用 `target_ulong`。

## software TLB 缓存什么

软件 TLB 不是客户机硬件 TLB 的逐项设备模型，它是 TCG 的执行缓存。客户机看不到条目数量、替换策略和命中时间，QEMU 可以按宿主性能需求组织；它必须保证页表更新和 fence 后的可观察结果符合 RISC-V。二者目的不同，不能拿 QEMU `CPUTLBEntry` 字段去解释某颗真实 RISC-V 核的微架构。

`CPUTLBEntry` 为读、写、取指保存可快速比较的地址 tag 与附加 flag，生成代码可用客户机地址计算索引、加载 entry、比较 page 部分，命中后利用 addend 或 offset 形成 host address。为了让热路径短，结构布局受到严格约束，`accel/tcg/cputlb.c` 甚至用 build-time assertion 检查若干成员相对位置。

快速 entry 放不下 MemoryRegion section、访问属性、大页信息等全部内容，QEMU 另用 `CPUTLBEntryFull` 保存慢路径数据。两张表索引对应，命中 RAM 时通常不必触碰 full entry，MMIO、watchpoint、notdirty 与异常处理再取完整信息。这是典型冷热分离：常用比较字段留在紧凑表，丰富语义放在旁表。

:::: {.quick-quiz}
SoftTLB 为什么不能只缓存客户机物理页号？

::: {.quick-answer}
快速路径还需要区分读、写、取指权限，标记 MMIO、watchpoint、notdirty、对齐等特殊情况，并保存形成 host address 的偏移。只缓存物理页号，命中后仍要进入通用 MemoryRegion 分派，无法省掉热路径成本。完整属性又不必全塞进快速 entry，所以当前实现拆成 fast 与 full 两层。
:::
::::

## MMU index 把访问上下文带进缓存

同一虚拟地址在 M、S、U、VS、VU 或 MPRV 影响下，页表和权限可能不同。软件 TLB 不能只按地址索引，必须区分 translation regime。QEMU 用 `mmu_idx` 编码目标相关上下文，RISC-V 的 `riscv_env_mmu_index()` 根据特权、虚拟化和访问类型选择索引，SoftMMU 为不同 index 维护描述和表。

MMU index 不是把所有 CSR 值直接拼入 key。ASID、VMID 和页表根变化通常通过 flush 保持一致，特权与两阶段标志则进入 index。选择哪些状态编码、哪些靠 flush，是空间、命中率与失效复杂度的折中。index 太细，表和切换成本增加；太粗，状态变化需要更频繁全清。

2023 年提交 [`02369f7906`](https://gitlab.com/qemu-project/qemu/-/commit/02369f7906) 引入 `mmuidx_2stage`，提交说明是移动并重命名原来的 `riscv_cpu_two_stage_lookup`，让表达与 MMU index 体系一致。上游事实说明，两阶段属性从散落判定收拢到 index helper；作者推断，这有助于让 TLB key、fault 分类和目标 helper 使用同一种“当前访问处于两阶段”语言。

当前 RISC-V index 还可编码 shadow stack write 等特殊访问。新增一类访问若复用普通 store index，可能错误命中权限不同的旧 entry；为每项特性无条件扩 index 位，又会碰到公共 `MMUIdxMap` 宽度。提交 [`e1e2f08b43`](https://gitlab.com/qemu-project/qemu/-/commit/e1e2f08b43) 把 `MMUIdxMap` 扩到 32 位，同时说明尚未增加 `NB_MMU_MODES`，展示公共表示会为目标增长预留空间，但不会自动扩大所有表。

## 命中路径为什么能够内联

RISC-V 前端生成 `qemu_ld` 后，宿主后端把 TLB index、tag load、地址比较和快速跳转写进 TB。若 entry 的 read tag 匹配，且没有要求慢处理的 flag，生成代码将 guest address 与 entry 中偏移相加，得到 host pointer，执行宿主 load。整个过程不回 C，才有接近直接内存访问的性能。

tag 的低位可复用为标志，因为页地址按固定粒度对齐。比较时既检查页号，也让特殊 flag 导致快速比较失败或转到专门分支。此类位打包节省 load，却要求所有构造和测试使用同一掩码，结构布局也不能随意调整。源码中的 `tlb_read_idx`、`tlb_addr_write` 与相关 build assertion 值得逐行看。

命中仍要处理跨页访问。一个八字节 load 接近页尾，前半与后半可能落到不同映射、不同端序属性或其中一页 fault。后端要检查地址与 size，不能只按首地址 entry 直接宿主 load。慢路径可能拆分访问，并按客户机端序组合结果；MMIO 访问还受设备允许的 access size 约束。

host pointer 只在对应 RAMBlock 和映射保持有效期间可用。MemoryRegion topology 变化会通知 listener 并触发相应缓存更新，迁移 dirty logging 或 ROM protection 也会改变写路径 flag。SoftTLB 处于 CPU 执行与全局内存拓扑之间，不能自行永久持有裸指针。

## direct-mapped 表与 victim TLB 的取舍

software TLB 的快速表按地址位直接索引，查找只需要一次 entry load，代价是两个不同页可能冲突。QEMU 提供小型 victim TLB，主表替换时保留旧 entry，后续冲突页再次访问可交换回来。它减少病态冲突，又不让每次命中变成多路 associative 比较。

表大小也会动态调整。更大表降低 miss，却增加 flush 时间和缓存占用；RISC-V 客户机频繁执行 fence 时，巨表未必划算。`cputlb.c` 注释明确讨论 miss rate、flush 频率与 locality 的折中，并根据使用情况扩缩。这里是源码事实，具体阈值属于实现细节，不是客户机 ABI。

`tlb_fill_align()` 可能触发表 resize，因此调用前取得的 entry 指针在 fill 后必须重新查。当前源码有明确注释警告这一点。若慢路径保留旧指针再写 full entry，只有在 resize 恰好发生时才出错，这类 bug 很难靠普通启动测试捕捉。

作者推断，software TLB 的数据结构选择优先照顾“命中指令数”，不是追求模拟真实 TLB。victim 表与动态 resize 都可以改变，只要 fence、fault 和内存访问结果保持架构正确。性能实验应把它称作 QEMU 执行缓存，避免与客户机性能计数器中的硬件 TLB 混淆。

## miss 后怎样进入 RISC-V 页表遍历

快速比较失败，slow path 先查 victim TLB，再调用目标 `tlb_fill`。当前 RISC-V hook 是 [`riscv_cpu_tlb_fill`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/tcg/cpu_helper.c)，它取得 address、size、load/store/fetch 类型、MMU index、probe 标志和宿主 return address，调用 `get_physical_address()` 完成目标页表规则。

fill 成功后，目标得到 physical address、读写执行保护、页面大小与访问属性，再由 `tlb_set_page_full()` 结合 QEMU AddressSpace 查找 MemoryRegion section。RAM 条目形成 offset，设备条目保存 iotlb section 信息，最后写入 fast/full 表。原来的 load helper重新查 entry并继续，或直接完成慢访问。

fill 失败则不能留下半有效 entry。若 `probe=false`，目标设置异常状态并通过 TCG 退出机制回到 `cpu_exec()`；若调用者只探测，可能返回失败而不注入异常。debug 地址查询、watchpoint 和真实执行的 fault 行为不同，函数参数必须明确。

宿主 return address 用于精确恢复。miss helper 在一段 TB 宿主代码中被调用，RISC-V fault 要报告触发 load 的客户机 PC；QEMU 根据 return address 查 TB 元数据，恢复状态后再进入 trap。若 helper 层丢掉该地址，异常可能落到 TB 起点或下一条指令。

## Sv39 页表遍历拆解

在 RV64 Sv39 中，虚拟地址高位必须是有效符号扩展，VPN 分为三级索引，`satp` 提供根 PPN 与 ASID。walker 从最高级 PTE 开始，每级用 VPN 索引计算 PTE address，读取后检查 V、R、W、X、U、G、A、D 等位。非叶 PTE 指向下一层，叶 PTE 形成物理页号，还要检查 superpage 对齐。

PTE 读取本身不是普通 host pointer 解引用。页表位于客户机物理内存，可能受 PMP，虚拟化时还要经过 G-stage。walker 使用系统内存访问 helper，处理 transaction failure 和端序。若 PTE address 落到设备区，行为应按 PMA/PMP 和总线结果报告，不能让设备回调返回值悄悄当作页表。

权限取决于访问类型与当前状态。取指要求 X，load 通常要求 R，MXR 可以让可执行页按条件可读，SUM 影响 supervisor 对 user 页的数据访问；store 需要 W，且 R/W 的保留组合要 fault。A/D 位由硬件更新扩展或软件管理模式决定，更新还需要原子性，MTTCG 下两颗 vCPU 可能同时走同一 PTE。

大页命中后，TLB 可以按较大 `tlb_size` 缓存，减少 miss；失效单个地址时，缓存 entry 可能覆盖更大范围，flush 逻辑必须检测并扩大清理。`cputlb.c` 在无法精确处理 large page 时会退化为整个 mmu_idx flush。功能正确优先，性能再由范围优化。

## PTE 保留位为何要诊断

规范要求某些保留位为零，置位通常使 PTE 无效或触发 page fault。QEMU 过去可能静默把它当 unmapped，客户机只看到启动失败，很难发现页表构造 bug。提交 [`50df464f8e`](https://gitlab.com/qemu-project/qemu/-/commit/50df464f8e) 在 RISC-V PTE 保留位被设置时记录 guest error，提交说明明确说这样能让未来错误页表不必靠 bisect QEMU 调试。

日志不改变规定的客户机异常，只增强开发可见性。若将 guest error 变成 QEMU 进程 fatal，会让一个恶意或有 bug 的客户机杀掉虚拟机管理进程；若完全不报，平台开发者又难定位。当前选择是在保持架构 fault 的同时记录诊断，这是设备模拟常见的工程平衡。

扩展会重新定义保留位。Svnapot、Svpbmt 等启用后，某些位获得语义；未启用时仍应按保留规则处理。walker 的合法性检查必须结合 CPU config 和当前 mode，不能写死“高位永远为零”。这也解释了为何页表模式与扩展依赖在 CPU realize 时校验。

## PMP 位于转换之后，也参与 walker

RISC-V PMP 控制物理访问权限，M-mode 配置区域，较低特权访问在地址转换后接受检查。页表 walker 读取 PTE 的物理访问也要过 PMP，否则 supervisor 可借页表遍历读取被保护内存。QEMU 的 `get_physical_address_pmp()` 既检查最终地址，也用于 walker 的 PTE access。

PMP fault 与 page fault 的优先级需要符合规范。2024 年提交 [`68e7c86927`](https://gitlab.com/qemu-project/qemu/-/commit/68e7c86927) 修复 `raise_mmu_exception()` 优先报告 guest page fault、盖过 PMP access fault 的问题，提交说明引用特权规范指出没有这种优先关系。随后 [`6c9a344247`](https://gitlab.com/qemu-project/qemu/-/commit/6c9a344247) 修复非 guest-page fault 仍设置 `mtval2`。两条提交展示，正确地址结果之外，异常类型和附加 CSR 同样是 MMU 实现的一部分。

上游陈述可以直接归纳为：PMP 检查时机改变最终 trap，`mtval2` 只应在规范规定的 guest page fault 情况承载 GPA 信息。作者进一步推断，页表 walker 应把“失败阶段”和“失败原因”作为结构化数据传到统一异常生成处，不要一路压成单个失败布尔值。

## 两阶段转换不是简单调用两次

概念图常画 `GVA -> GPA -> HPA` 两个箭头，实际 walker 更复杂。VS-stage 读取 PTE 时产生 guest physical PTE address，这个隐式访问必须先经 G-stage；第一阶段叶 PTE给出的 GPA 再经一次 G-stage处理原始 load。两次 G-stage 的 access type和 fault address语义不同，代码用 `first_stage`、`two_stage`、`two_stage_indirect` 等参数区分。

当前 `get_physical_address()` 在 first stage 且 V=1 时选择 `vsatp`，在第二阶段选择 `hgatp`；`riscv_cpu_tlb_fill()` 先做 VS translation，再对中间地址执行 G translation和 PMP。若读取 VS PTE 时 G-stage失败，属于间接 guest-page fault，附加 fault address要指向相应 GPA；若最终 GPA 的 G-stage失败，又是直接情况。

G-stage模式为 Sv39x4、Sv48x4、Sv57x4，根表相对普通 Sv39 扩展四倍，GPA 合法高位规则也不同。提交 [`7bf14a2f37`](https://gitlab.com/qemu-project/qemu/-/commit/7bf14a2f37) 修复 Guest Physical Address Translation，提交说明逐项列出 x4 模式高位必须为零的范围。仅复用 ordinary Sv39 canonical address 检查，会接受规范禁止的 GPA。

:::: {.quick-quiz}
两阶段转换为什么不能简单合并成一张影子页表来解释全部语义？

::: {.quick-answer}
VS 与 G 两阶段有不同根寄存器、ASID/VMID、权限、页大小和 fence，读取 VS 页表时还会触发间接 G-stage访问。客户机能通过 cause、`htval/mtval2` 等区分失败阶段。实现可以缓存最终合成结果，却必须保存足够信息重现每阶段独立语义。
:::
::::

## MXR、MPRV 与虚拟化状态的组合

RISC-V 特权位组合比“当前 mode”更细。MPRV 可让 M-mode 显式数据访问按 MPP 指定权限执行，MPV 影响虚拟化上下文；MXR 允许 load 读取 executable 页，VS 与 HS 状态中又有相应视图。walker 必须选择正确 CSR 来源，并区分显式客户机访问与页表隐式访问。

提交 [`6bca4d7d1f`](https://gitlab.com/qemu-project/qemu/-/commit/6bca4d7d1f) 修复两阶段转换中 MXR 行为，提交说明引用 H 扩展规范，指出 hypervisor extension 改变 MXR、MPV、MPRV 的组合。提交 [`82d53adfbb`](https://gitlab.com/qemu-project/qemu/-/commit/82d53adfbb) 修复 MMU translation stage 上错误异常，强调 access fault只有在相应 PMA/PMP 检查后产生。历史修复表明，简单的 if 链很容易把阶段与有效特权混错。

2026 年 pointer masking 又带来同类问题。提交 [`40540c8a92`](https://gitlab.com/qemu-project/qemu/-/commit/40540c8a92) 修复 HLV/HSV 的有效特权选择，提交说明指出这些虚拟机 load/store 由 `hstatus.SPVP` 控制，`mstatus.MPRV` 不影响它们；[`fabf2446e7`](https://gitlab.com/qemu-project/qemu/-/commit/fabf2446e7) 继续修正 translation mode检查。作者据此判断，地址预处理、权限和页表选择应共享“effective access context”，分别临时重算很容易漂移。

## fault 要保留足够上下文

普通 page fault 需要区分 instruction、load、store/AMO，guest-page fault 又有对应 cause。`tval` 保存原始虚拟地址，`htval` 或 `mtval2` 在规定情形保存移位后的 guest physical fault address，`htinst` 还可能帮助 hypervisor了解原始指令。QEMU 在 TLB fill 失败时记录 `two_stage_lookup`、`two_stage_indirect_lookup` 和 fault address，trap handler随后写 CSR。

字段必须在下一次异常前清理，否则一次普通 fault 可能带上前次 guest fault 的附加地址。提交 `6c9a344247` 正是这类状态污染修复。异常路径也要处理 probe：调试器查询地址失败时通常不应修改客户机 trap CSR，真实访存才提交。

transaction failure 发生在页表完成后，比如 physical address未映射或设备拒绝访问。`riscv_cpu_do_transaction_failed()` 根据访问类型和两阶段上下文生成 access fault。不能把 MemoryRegion 的 `MEMTX_ERROR` 一律当 page fault，因为页表本身可能完全正确。

实验应同时断言 cause、PC、`tval` 和阶段相关 CSR。只看到 Linux 打印“segfault”无法证明底层 trap正确，内核可能把多种错误映射为同一用户信号。

## RAM、ROM、MMIO 在 fill 后分流

目标 walker 返回 physical address 后，`tlb_set_page_full()` 调用 AddressSpace 翻译，得到 MemoryRegionSection。普通 RAM 可以缓存 `xlat_offset` 并走 direct host load；ROM 写入、dirty logging、watchpoint 或代码保护会给 entry 加 flag，让访问进入特殊路径；MMIO 保存 section index 与 offset，slow path调用设备 `MemoryRegionOps`。

`CPUTLBEntryFull` 的 `xlat_section` 等字段必须对应正确 AddressSpace。提交 [`854cd16e31`](https://gitlab.com/qemu-project/qemu/-/commit/854cd16e31) 修复 `iotlb_to_section()` 在不同 AddressSpace 下的错误，对应邮件 [`20260128152348.2095427-3-jim.shu@sifive.com`](https://lore.kernel.org/qemu-devel/20260128152348.2095427-3-jim.shu@sifive.com/)。前一提交 [`94c6e9cf04`](https://gitlab.com/qemu-project/qemu/-/commit/94c6e9cf04) 把整个 `CPUTLBEntryFull` 传给 `io_prepare()`，让它取得所需多个成员。

上游事实说明，MMIO slow path不能只凭一个物理偏移定位设备，AddressSpace 身份也是翻译结果的一部分。作者推断，fast/full 分离虽利于性能，却增加“索引对应且上下文一致”的合同，修改结构字段时必须同时审查 RAM、MMIO、probe、watchpoint和原子路径。

## notdirty 与代码页保护

迁移 dirty bitmap 需要知道 RAM 页何时首次被写，TB 自修改检测也要保护包含代码的页。software TLB 可把写 entry 标成 notdirty 或特殊保护，让第一次写进入 slow path，更新 dirty 标记或失效 TB，再放开后续快速写。这样无需每次 RAM store都调用 C。

保护状态变化要更新所有相关 entry。若 dirty logging 开启却留下可直接写的旧 TLB，迁移会漏页；若代码页失效后仍保留保护，后续写持续走慢路径。`tlb_reset_dirty`、`tlb_set_dirty` 与 TB protection代码共同维护。

提交 [`cadee08114`](https://gitlab.com/qemu-project/qemu/-/commit/cadee08114) 将 `tlb_protect_code()` 和 `tlb_unprotect_code()` 限制在 TCG 私有头文件，邮件 [`20260705215729.62196-4-philmd@oss.qualcomm.com`](https://lore.kernel.org/qemu-devel/20260705215729.62196-4-philmd@oss.qualcomm.com/) 的上游说明指出它们只在 `accel/tcg/` 使用。目录边界反映机制归属：这些是 TCG 代码缓存一致性，不是所有 accelerator 的公共 MMU API。

## fence 与 flush 是一项并发协议

客户机修改页表后，何时必须执行 `SFENCE.VMA` 由 RISC-V 规范规定。QEMU 收到 fence，依据地址和 ASID尽可能缩小 software TLB失效；无法精确表达时可扩大范围。H 扩展的 `HFENCE.VVMA` 面向 VS-stage，`HFENCE.GVMA` 面向 G-stage与 VMID，两者目标集合不同。

单 vCPU 清本地数组很容易，MTTCG 下其他 vCPU可能仍缓存相同映射。flush API 使用 `async_run_on_cpu` 或同步版本把工作送到目标 vCPU，在安全点清表并处理 jump cache。调用者还要建立页表写与 flush 的内存顺序，保证目标 CPU 失效后不会读到旧 PTE。

:::: {.quick-quiz}
为什么 TLB flush 是并发协议，而不只是清空一个数组？

::: {.quick-answer}
多个 vCPU 各自缓存映射，并可能同时执行依赖旧 entry 的宿主代码。flush 要确定目标 CPU 与 MMU index，发布页表写，在安全点清 fast/full/victim 与相关 jump cache，必要时等待完成。原子清零本地 entry 只能处理其中一小步，不能建立跨线程顺序。
:::
::::

## 精确 flush 与全清的工程权衡

地址、ASID、VMID都给出时，理论上可以只清一小组 entry。software TLB direct-mapped、支持大页，又不一定在 entry中保存所有标签，精确扫描的成本可能超过全清。当前 range flush代码会根据范围大小和表规模选择全 flush，大页重叠难证明时也退化。

过度全清不会破坏功能，却可能让 fork、上下文切换或虚拟机内核 shootdown变慢。过度精确若漏 entry，则执行旧映射，属于严重正确性问题。上游通常先选择可证明的保守范围，再用计数与 workload推动优化。`cputlb.c` 维护 full、partial、elided flush统计，为分析提供入口。

`hgatp`、`vsatp` 写入也影响缓存。当前 CSR 写函数会 legalize mode并按需要 flush；有些状态已经包含在 MMU index中，切换不必清全部。源码注释“mode is contained in mmu_idx”就是明确工程依据。阅读时要把 index切换与实际 entry清除共同考虑，单看某条 CSR 写后没有 `tlb_flush()`，不能立刻判错。

## A/D 位更新与 MTTCG

当硬件更新 A/D 位语义启用时，walker 需要原子地把 PTE accessed/dirty位置一。两颗 vCPU可能同时处理同一 PTE，一个设置 A，另一个设置 D，普通 read-modify-write 会丢位。QEMU 必须用原子 compare-exchange 或对应内存原语，并在失败时重读。

更新 PTE 还是一次物理内存访问，受 PMP、G-stage与 transaction failure影响。不能先把最终 translation缓存，再假定 A/D 写一定成功；写失败应产生规范要求的 fault。虚拟化下，VS PTE 的 A/D 更新还穿过 G-stage。

历史提交中曾明确提到 Svadu 与 MTTCG 下错误物理映射或 guest crash，这类问题通常只在多 vCPU共享页表压力下出现。实验要用并行缺页或共享映射循环扩大竞争窗口，单线程页表 walk无法证明原子更新正确。

## 地址宽度、符号扩展与 pointer masking

RV64 并不意味着所有虚拟地址 64 位任意取值。Sv39 要求高位按规定符号扩展，G-stage x4 模式有独立 GPA 高位约束，HLV/HSV 又使用由 SPVP决定的 effective privilege。pointer masking扩展在页表转换前处理地址高位，选择哪组 PMM字段取决于访问上下文。

若过早把地址截到 host pointer宽度，非法高位可能消失；若先做 canonical检查再 pointer masking，顺序也可能反。2026 年连续提交 `0f64c97d23`、`40540c8a92`、`fabf2446e7` 修复虚拟机 load/store相关 masking逻辑，说明地址预处理与 translation mode必须一起审查。

作者建议在代码和图中区分 `vaddr`、`target_ulong`、`hwaddr`、`uintptr_t`。它们有时宽度相同，语义不同。类型转换处就是审查点，应说明截断、符号扩展或掩码依据，避免“在当前宿主刚好工作”。

## 对齐、端序和访问大小在何处检查

RISC-V 指令指定 load/store宽度，CPU 配置与扩展决定未对齐访问是否允许或怎样处理。TLB fill可检查页面和目标属性，真正访问还要防止跨页。MemOp携带端序，2026 年运行时 MBE/SBE/UBE支持又让端序随特权变化。

MMIO设备可限制合法大小和对齐，MemoryRegionOps会拆分或拒绝访问。客户机 CPU允许未对齐 RAM load，不代表可以把一个八字节 UART访问拆成八次而保持设备语义。SoftMMU在 CPU对齐、页面边界和设备约束之间选择 slow path。

提交 [`4dea00368d`](https://gitlab.com/qemu-project/qemu/-/commit/4dea00368d) 区分 TLB-only alignment与 atomicity，尽管直接背景来自另一目标，公共 TCG的工程考量适用于 RISC-V：对齐检查位置会改变异常优先级和 MMIO行为，不能只用一个“需要对齐”位覆盖全部情况。

## 调试 probe 与真实访问有意不同

GDB 读内存、monitor 查询物理地址和内部 watchpoint常调用 probe接口。它们需要转换结果，却不应像客户机指令一样提交 A/D、触发 MMIO副作用或注入 trap，具体行为由 probe参数和 API合同决定。误用真实 load helper，调试器查看寄存器旁边的内存就可能改变设备状态。

反过来，nonfault probe失败不能被当作“地址必然不可访问”。真实执行可能在 fill时更新 A/D并成功，或使用不同 effective privilege。调试工具应说明采用的上下文，尤其是虚拟化下想查看 GVA、GPA还是 system physical。

`riscv_cpu_get_phys_page_debug()` 的历史修复也体现地址 API命名问题，有些目标返回 page-aligned结果，有些调用者期望任意地址。上游逐步把接口语义说清，书中实验不要用一个 debug翻译命令替代真实 load的 fault验证。

## 用一个 Sv39 地址手工走三层

实验前先做纸面推导。取一个满足Sv39 canonical规则的虚拟地址，将bit 38向上符号扩展，把bit 38:30、29:21、20:12分别记为VPN2、VPN1、VPN0，低12位为page offset。`satp.PPN << 12` 得到根表，根地址加 `VPN2 * 8` 取得第一级PTE。若V=1且R/W/X全零，它是非叶，PPN成为下一层表基址；遇到叶则停止。

叶PTE的PPN按层级与虚拟地址低VPN组合。三级叶映射4KiB，二级叶映射2MiB，一级叶映射1GiB；大页叶要求被虚拟VPN替代的低PPN位为零，否则misaligned superpage fault。最终加page offset形成physical address，再做PMP与MemoryRegion。这个手算能核对walker循环的level、shift和mask。

权限检查不是遍历结束后统一做。无效V、`W=1,R=0`保留组合、U/S访问、MXR/SUM、A/D和扩展位都在叶判断附近。PTE本身读取失败属于access fault路径，叶权限失败属于page fault，错误类型不同。把“没得到物理地址”统一返回会丢失原因。

两阶段实验把同一张表复制为VS页表，再让它的PTE页GPA落到G-stage映射。手工表要多一列：每次PTE address是GPA还是system PA、使用原始access type还是隐式load、失败时附加地址写哪。代码里的 `two_stage_indirect` 就对应这张表无法省略的列。

## TLB tag 中的 flag 如何迫使慢路径

fast entry的 `addr_read/addr_write/addr_code` 不只保存页tag，低位还可表示invalid、MMIO、notdirty、watchpoint、对齐或其他特殊处理。生成代码比较时把要求slow的位纳入不匹配，branch到C；slow path根据full entry区分真正miss和已有特殊entry。

因此“TLB miss计数”可能包含两种情况：表里没有translation，需要walker；表里有translation，但访问因flag必须慢处理。性能分析要分别统计fill与slow access，不能看到slow helper就认定页表又走了一次。

读、写、取指tag分开，允许同一页可读不可写，或取指需要独立代码保护。一个store命中read entry没有意义，后端必须选择访问类型对应字段。权限变化flush若只清read tag，write旧权限仍可能命中。

flag位依赖目标页大小对齐，公共代码有mask helper集中处理。新增flag要检查所有比较、victim swap、flush和dump路径，不能只改fill设置点。结构位置build assertion也说明backend可能按offset直接生成load，重排成员是跨后端变更。

## 动态 resize 的收益与代价

software TLB根据窗口内使用情况调整entry数量，目标是工作集增大时降低冲突，空闲或flush频繁时避免大表。resize要分配fast/full/victim结构，搬迁或清空，更新指针。生成代码不会把表base永久硬编码为不可变裸指针，访问通过CPU负偏移区和当前描述取得。

resize可以在fill中发生，所以任何指向旧entry的局部指针都要丢弃。当前 `tlb_fill_align()` 注释明确要求调用者重新lookup，属于可验证API前置条件。若未来重构把fill藏入更深helper，仍要把“可能resize”向上传递。

表更大时full flush循环时间增加，宿主cache locality也变差。对每次context switch都执行广范围fence的客户机，小表可能总体更快。动态策略用历史窗口近似未来，不能保证每种workload最优；它保持客户机不可见，因此可持续调优。

实验冲突页时要记录resize，否则曲线在阈值处突然改善会被误认为victim策略。固定表大小若需要修改源码，应作为独立实验补丁，不进入书中默认结果。

## Svnapot 与大页让“页大小”不再单一

基本Sv39的叶层级决定4KiB、2MiB、1GiB页面，Svnapot又允许PTE编码连续自然对齐范围。walker返回translation size，software TLB用它判断覆盖；flush给定4KiB地址时，若命中entry覆盖更大范围，必须清整个映射或退化全表。

扩展只在合适 `satp` mode启用。前章提到提交 `601c8494c6` 在小于Sv39时禁用svnapot，避免CPU宣称无法使用的组合。walker还要检查N位和PPN编码，reserved组合fault。单纯把TLB size设64KiB而不核对PTE合法性，会接受错误页表。

大页能降低fill，却会放大权限与dirty粒度。MemoryRegion后端RAM可能连续，跨section或MMIO不能用一个大entry覆盖。最终缓存size取页表leaf、PMP边界和AddressSpace连续范围的共同最小值，不能只信guest PTE。

flush性能优化应先统计大页比例。若为了精确4KiB range扫描大页entry需要复杂重叠检查，全清可能更便宜。当前代码按表规模和range做保守选择，属于内部策略。

## PBMT 将内存类型带进转换结果

Svpbmt在PTE中编码page-based memory type，影响访问属性与排序。地址相同、权限相同，PBMT不同仍不能复用完全相同的TLB entry。walker解析位，形成transaction attributes或MemTxAttrs，后续MemoryRegion访问与TCG内存序使用。

PBMT位在扩展关闭时属于保留，必须fault或按规范处理；在不支持相应页表mode时CPU配置应拒绝。提交 `109856754c` 将svpbmt与satp mode约束绑定，说明扩展合法性既在realize，也在PTE运行检查。

内存类型不能等同QEMU MemoryRegion类型。guest PTE说某页采用IO语义，最终physical地址仍可能是RAM；MemoryRegion是machine拓扑，PBMT是CPU访问属性。两者合成后决定barrier、cacheability等可见行为。

实验若只比较读取值，很难验证PBMT。需要多hart内存序litmus或设备访问，并明确QEMU当前实现支持范围。未实现微架构cache效果不代表可以忽略架构顺序。

## A/D 位的软件管理与硬件更新

传统RISC-V页表若A或D未置，访问产生page fault，操作系统设置后重试；Svadu等能力允许硬件更新A/D。QEMU CPU模型决定启用哪种语义，walker在leaf检查时选择fault或原子更新。两条模式不能由客户机自行假定。

更新A/D的compare-exchange循环要保留其他hart刚写入的PTE位，重读后还要重新验证leaf与权限，因为页表可能已被替换。只把旧值OR后写回，会复活被操作系统撤销的映射。成功更新后，translation基于实际提交的PTE继续。

两阶段下，VS PTE的A/D更新是对guest memory的store，要过G-stage与PMP；G-stage PTE自身也可能更新。任何一步失败都要选择对应guest-page/access fault。状态组合多，适合用受控页表让每个阶段A/D为零逐个测试。

MTTCG压力测试让多个hart同时首次访问同页，检查最终A/D与数据，不出现错误mapping。若加日志让竞态消失，可在原子循环加trace计数而非printf，保持时序扰动较小。

## `SFENCE.VMA` 两个操作数表达范围

RISC-V `SFENCE.VMA rs1,rs2` 用rs1指定虚拟地址或全地址，rs2指定ASID或全ASID。四种组合允许实现精确shootdown。全局映射G位对ASID过滤有特殊规则，不能简单按两个零/非零做数组清理。

QEMU target helper解析寄存器，调用按page、mmu index或全部flush接口。software TLB entry未必保存足够ASID标签来做完美过滤，保守扩大范围合法。优化patch若想使用rs2，必须证明global页和ASID切换一致。

`HFENCE.VVMA` 作用于VS-stage虚拟映射，操作数类似VA/ASID；`HFENCE.GVMA`作用GPA/VMID，GPA按规范可能移位表示。当前 `trans_rvh.c.inc` 在合法性检查后调用不同helper。实验应构造两台VMID或两个VS ASID，验证不会错误保留目标，也不把功能正确依赖于精确保留无关项。

fence指令还与TB边界相关。执行flush后，后续load不能继续使用当前TB内按旧MMU context生成的假设，翻译函数通常结束或调用helper建立顺序。只清表、不阻止direct chain越过同步点，可能让生成代码重排。

## AddressSpace 更新怎样通知 CPU 缓存

热插拔、PCI BAR重映射、RAM backend变化或migration logging会修改MemoryRegion topology。memory transaction提交新FlatView，listener收到region add/del与log变化，accelerator据此更新。TCG software TLB中缓存旧section或host offset的entry必须失效。

更新采用RCU式视图，正在访问旧FlatView的线程可完成，提交后新读者看新视图。不能先free旧MemoryRegionSection再异步kick vCPU，否则slow path可能解引用释放对象。内存子系统的transaction与CPU flush顺序共同保护生命周期。

KVM路径用memory listener更新内核slot，TCG清软件缓存，两者由同一MemoryRegion变化触发，却执行不同动作。这再次说明MemoryRegion是公共machine事实，缓存实现属于accelerator。书中本章只展开TCG，后续KVM篇用同一拓扑事件对照。

提交 `854cd16e31` 的不同AddressSpace修复提醒，CPU可能有system、I/O或设备特定address space。entry保存的section index只能在对应view解释，更新和lookup都要带AS index。

## dirty logging 对写 TLB 的影响

迁移开始后，需要跟踪哪些RAM页被guest修改。若写TLB仍直接把guest address变host pointer，store绕过dirty bitmap。内存listener改变logging状态，QEMU重置相关write entry，让第一次或每次按策略进入notdirty slow path，标记后可重新开放快速写。

代码页保护与dirty logging可能同时要求slow。处理一次写时要完成两种副作用：迁移标脏、TB失效，再决定entry是否可解除flag。只处理第一个匹配原因，会漏另一个；flag组合和full entry提供上下文。

大页write entry覆盖多个migration dirty page时，标记粒度要符合迁移bitmap，不能只标入口页。实现可能缩小缓存映射，牺牲命中以保持追踪。性能测试迁移期和非迁移期应分开。

管理命令直接写guest RAM也要走dirty与code invalidation API。绕过CPU TLB不代表绕过一致性协议，MemoryRegion写helper承担等价通知。

## watchpoint 为何让命中也走慢路

GDB在某个GVA设watchpoint，访问命中普通RAM仍要比较地址、报告debug并恢复精确PC。将整页write/read entry标特殊，任何该页访问先slow，再精确比较范围；未命中watchpoint的访问完成后返回。页粒度标记降低维护复杂度，热点页上会有额外开销。

watchpoint地址随页表变化的语义由调试接口定义，通常以guest virtual或physical方式安装。TLB entry的MMU index与范围要匹配，切换ASID后不能错误触发另一进程。调试器修改watchpoint集合需要flush受影响entry与TB插桩。

slow path触发debug前不能提交store副作用，load watchpoint的访问时机也按类型区分。跨页宽访问若后半命中watchpoint，前半是否已经发生要符合QEMU调试约定，设备MMIO尤其敏感。

实验可以把watchpoint与page fault放在同一地址附近，核对异常优先级和PC。若GDB本身读取内存触发watchpoint递归，就是probe与真实访问API混用的信号。

## MMIO 原子与拆分访问的边界

guest AMO落到RAM，可由host原子或serial helper实现；落到MMIO，设备是否支持原子read-modify-write并无通用保证。MemoryRegionOps声明合法大小与实现，TCG可能拒绝、拆分或调用专门atomic callback。随意用读回写会让设备看到两次独立事务，语义可能错误。

普通未对齐访问跨两个MMIO register也不能总按字节拆。设备 `valid`/`impl` 约束和bus规则决定，失败要转RISC-V access fault。CPU ISA允许未对齐是上层能力，平台PMA仍可限制。

`CPUTLBEntryFull` 保存attrs、section和translation offset，让 `io_prepare()`选择正确设备。提交 `94c6e9cf04` 将full结构传入，正是因为多个成员共同决定I/O。过度压缩helper参数容易丢上下文，过度暴露结构又耦合；当前选择偏向slow path正确性。

原子实验最好先用RAM验证RVWMO，再用明确支持/不支持的教学设备验证MMIO fault，不拿真实UART做AMO猜测。

## MMU 日志如何避免淹没结论

`CPU_LOG_MMU` 可记录 `riscv_cpu_tlb_fill` 地址、访问类型和index，但每次fill打印会改变多核时序并产生巨大文件。先用最小页表和一次访问定位字段，再用trace counter跑压力。日志中出现fill不等于fault，成功也会记录。

为每次实验分配case ID，记录GVA、expected stage、access type和hart，脚本按ID截取。两阶段walker递归调用时，相邻日志可能来自隐式PTE访问，缩进或显式stage字段很有帮助。若上游trace缺字段，可在实验补丁添加，不把临时printf混入最终正文代码。

故障报告同时保存CSR dump与PTE memory dump。日志是QEMU内部观察，CSR是客户机可见结果，两者对不上时说明异常提交层仍有问题。只看一边无法区分walker与trap handler。

性能阶段关闭逐访问日志，使用full/partial/elided flush计数和fill统计。输出采样周期要比单次访问长，避免测量工具主导结果。

## 从修复历史提炼 review 问题

`68e7c86927` 提醒检查失败优先级，`6c9a344247` 提醒清理阶段附加状态，`7bf14a2f37` 提醒x4地址范围，`6bca4d7d1f` 提醒effective MXR，`40540c8a92` 提醒HLV/HSV不服从MPRV，`854cd16e31` 提醒AddressSpace身份。它们看似分散，可以归为五问：访问上下文、转换阶段、权限来源、错误优先级、结果地址空间。

修改walker时，先为每条路径填这五项，再写条件。复杂if若同时改两项，考虑构造小结构描述effective access，避免在不同helper重复推导。作者这一建议是根据修复聚类得出的推断，不是上游已采用的统一设计。

review还要看状态清理。`two_stage_lookup`、fault address、probe标志和exception index跨helper传递，成功路径、普通fault、guest fault、transaction failure都应设置或清零。复用 `env`临时字段能降低参数数量，也增加前次调用污染风险。

最后检查缓存。walker语义修复若改变权限或attrs，旧TLB entry在运行中何时失效；CPU属性变化只在启动前，则无需运行flush；CSR动态位变化需要fence或自动清。修对慢路径但继续命中旧快路径，测试重启后会通过，在线切换仍错。

## 两阶段 fault 矩阵应怎样写

对一次guest load，先列VS-stage读取PTE、VS leaf权限、G-stage读取VS PTE所在GPA、G-stage转换最终GPA、PMP与physical transaction六个检查点。每个点写失败cause、原始GVA、附加GPA、访问类型和是否为indirect。矩阵比一条长if更容易发现两项共用错误分支。

VS PTE无效产生普通VS page fault，hypervisor接收到的trap层级取决delegation；读取该PTE时G-stage失败产生guest-page fault，附加地址指向PTE访问的GPA；最终GPA映射失败也是guest-page fault，但indirect标志不同。PMP拒绝可能优先成为access fault，`68e7c86927` 就修复这里。

取指、load、store/AMO各有对应cause。walker隐式读取PTE虽使用load操作，最终报告有时要保留原始访问类型，不能一律改成load guest-page fault。历史提交曾修正“implicit G-stage translation失败时把access type转LOAD”的问题，说明矩阵必须同时保存原始与内部类型。

实验把六个检查点逐一故障化，每次只改一个PTE/PMP/region条件，避免两个错误竞争优先级。再构造双错误验证规范优先级，例如VS leaf权限和后续PMP同时不可达，确认QEMU选择应先发现的一项。

## HLV/HSV 访问为何复用 MMU 又不等同普通 V=1

HS-mode执行HLV/HSV时，当前V可能为0，但指令要求按guest上下文访问，MMU index显式带two-stage。effective privilege来自SPVP，MXR等位选择也有专门规则。普通 `riscv_env_mmu_index()`只看当前mode不足，翻译helper要构造特殊index。

HLVX以execute权限读guest指令数据，最终仍把值写GPR，不发生取指PC变化。software TLB若只分read/write/code三tag，HLVX应选择能反映execute检查的路径，避免命中普通read允许但X禁止的entry。

pointer masking在页表前应用，选择PMM字段跟effective access关联。`40540c8a92` 和 `fabf2446e7` 连续修复，说明“复用普通访存helper再临时改virt位”容易漏上下文。更稳妥的分析是先构造完整access context，再进入共同walker。

故障时 `tval`仍关联指令使用的guest address，cause按虚拟机load/store规则，trap目标由当前HS执行上下文决定。测试不能用普通VS load替代，它们路径相似但状态来源不同。

## 页表内存也可能落到异常 MemoryRegion

规范与平台通常把页表放RAM，恶意或错误客户机可把根PPN指向ROM、MMIO或未映射区。walker读取PTE时要用受控physical memory API，不能假定得到host pointer。MMIO read可能有副作用，平台PMA也可能禁止把该区域当页表。

QEMU对这类访问返回MemTxResult，目标转换为access fault或guest-page相关失败。若设备允许读并返回数据，是否可作PTE还受PMA，当前machine模型支持范围需查源码。实验不应把任意设备响应当架构承诺。

页表A/D更新需要写，ROM或只读region会失败。失败后不能继续使用旧PTE形成translation，也不能留下software TLB entry。transaction failure的地址与访问类型要指向PTE更新，而客户机看到cause按规范映射。

这类负向用例有安全价值。walker若直接host解引用，客户机可让QEMU越界或绕PMP；受控API把错误限制为guest trap。源码审查把所有PTE read/write调用点列出，确认都经过地址空间与权限。

## 缓存权限不能比最小约束更宽

最终translation权限来自页表R/W/X、SUM/MXR、PMP、MemoryRegion可访问性与特殊属性的交集。software TLB填入 `prot` 应取共同允许集合。任何一层拒绝write，write tag不得快速命中；read允许不代表execute允许。

大页跨PMP区域时，缓存size还要截到PMP边界。若按1GiB leaf建一个entry，却后半落到PMP禁区，后续访问会绕检查。AddressSpace section边界、RAMBlock连续性同理。fill返回的page size不是页表单独决定。

动态改变PMP或相关CSR后必须flush受影响index。若只更新配置表，旧entry保留宽权限。PMP write通常结束TB并清缓存；测试先填允许entry，再收紧PMP后重访，才能覆盖，不要每次reset后测试。

作者把这条原则概括为“缓存可合并结果，不能扩大任何上游授权”。它是从权限交集推导的工程规则，具体QEMU函数仍以当前源码为准。

## ASID 与 VMID 提高命中，也增加复用风险

ASID允许切换 `satp`根时保留其他地址空间TLB，VMID为G-stage提供类似区分。硬件会把标签作为TLB key，QEMU software TLB可通过MMU index、flush策略或entry信息实现等价可见结果。当前内部未必逐项模拟真实tag。

复用ASID而未先执行规定fence，客户机行为按规范可能使用旧translation，操作系统负责生命周期。QEMU不应替客户机每次写satp都无条件做最强全清而掩盖软件bug，当前实现与规范允许范围需对照。为安全保守清理可以合法，却影响性能和测试敏感度。

VMID宽度由实现能力决定，`hgatp`写会legalize。超范围值截断或WARL后，两个guest可能实际同VMID，hypervisor必须管理fence。QEMU CPU属性与CSR读回要一致。

实验创建两套页表、同VA映射不同PA，在ASID/VMID切换中验证目标数据，并分别有/无正确fence。无fence用例只记录实现现象，不把某次旧/新结果当稳定保证。

## 从客户机可见结果建立 oracle

一次成功load的oracle包括寄存器值、无trap、A/D位和设备访问次数；page fault包括cause、epc、tval、stage附加CSR、无目的寄存器写与无不应发生的MMIO；store还要检查内存是否未部分提交。只比最终值会漏副作用。

TLB命中与miss是QEMU内部，不属于架构oracle。相同客户机结果下，实验再用trace验证第二次访问命中、fence后fill，属于实现结构证据。内部策略未来变，架构测试仍应通过，性能预期可更新。

多hart测试把允许顺序写成集合，shootdown完成后必须看到新映射，完成前按协议可能仍旧。同步点由guest IPI/fence或QEMU synced API定义，不能用host sleep代替。

每个case保存源码hash、CPU model、扩展、页表hex与命令。正式 `v11.1.0` 和rc0结果不同，先查上游diff，不偷偷改expected。实验手册英文记录步骤，正文用中文解释观察与边界。

## SoftMMU 优化为何要同时跑设备用例

优化RAM fast path容易在Linux内存benchmark上见效，可能破坏MMIO、watchpoint、dirty logging或big-endian慢路径。`qemu_ld/st` 共享tag和full entry，改变比较或layout必须跑所有特殊flag组合。

最小矩阵包括普通RAM、ROM写、未映射、UART MMIO、跨页、未对齐、watchpoint、代码页、migration dirty、两阶段与原子。每项不必大型OS，qtest或裸机能精确计数设备callback。

性能patch报告RAM命中指令数与耗时，也报告fill/flush没有异常增长。特殊路径慢一点可能接受，功能必须保持；为了少一branch把watchpoint移到每次C查，会让调试热点严重退化，需要说明。

上游review来自多个target和device维护者，公共 `cputlb.c` 修改不能只用RISC-V guest证明。书中架构例子坚持RISC-V，提交实践仍要运行全QEMU测试矩阵，这两件事不冲突。

## 阅读复核：地址转换图必须标失败出口

只画 `GVA -> GPA -> system PA -> HVA` 的成功箭头，会把本章最重要的信息删掉。每个箭头旁标输入特权、根寄存器、访问类型和权限来源，再为canonical、PTE、PMP、MemoryRegion画失败出口，写cause与附加地址。两阶段还要把读取VS PTE的隐式G-stage单独画出。

然后把software TLB放在图上。它缓存哪段合成结果，key怎样包含MMU context，entry怎样区分R/W/X，命中绕过哪些检查；每个CSR写或fence画到对应flush。缓存没有改变规范检查，只让已经验证的结果在有效期内复用。

再把并发加上：页表写发生在哪个hart，guest fence与IPI何时发布，QEMU内部all-cpus flush何时等待，目标vCPU在哪个安全点清表。只画数组清零，无法说明新PTE可见；只画IPI，也无法说明handler完成。

最后放入RAM、MMIO、dirty和watchpoint四种终点，检查full entry上下文。任何“得到物理地址就直接host load”的描述都缺了machine分派。图能回答成功、失败、缓存和设备四类问题，才算完整。

## 一条缓存优化的反证问题

假设补丁减少TLB tag比较，问五个反证：权限刚收紧会不会命中，跨页后一页会不会绕过，MMIO flag会不会被当RAM，watchpoint会不会漏，AddressSpace更新后host pointer会不会悬空。再加入两阶段不同MMU index和大页重叠。

如果答案依赖“通常不会这样”，优化尚未证明。可用额外guard、缩小entry或slow fallback保住罕见路径，热路径收益需测。QEMU的安全边界面对不可信客户机，罕见PTE和地址组合不能因benchmark没有出现而忽略。

反过来，保守全flush或全slow功能可能正确，需用无关页保留、命中计数和设备访问次数约束性能。正确与高效分别有负向测试，设计讨论才不在两个极端摇摆。

版本复核时先对比 `riscv_cpu_tlb_fill` 的fault分支，再对比 `CPUTLBEntryFull` 布局和flush API。前者改变客户机可见CSR，必须更新oracle；后者多为内部策略，更新trace和性能预期。两类diff不能按行数判断重要性。

最后用正式tag重跑普通Sv39、间接G-stage fault、PMP优先级和MMIO四个哨兵用例。它们覆盖成功、阶段错误、权限错误和machine分派，是发现候选期MMU修复影响的最小集合。

四个哨兵都要先填充缓存再触发变化：普通映射换PTE，间接fault修G-stage，PMP从允许改拒绝，MMIO重映射section。只在空TLB上测试会绕过失效协议。第二次访问的客户机结果与内部fill计数一起记录，既验证慢路径，也验证旧entry没有继续命中。

再为每个哨兵保留一个无关地址，确认精确flush没有误伤；若实现有意全清，报告清楚记录保守策略和性能代价，不把无关页重填误写成正确性失败。

哨兵用例的页表、PMP和MemoryRegion布局应由脚本生成并打印，避免手工十六进制改动没有进入版本控制。实验失败时，布局就是第一份可审计输入。

同一输入还要记录访问hart、MMU index和扩展开关，防止地址相同、上下文不同的两次结果被错误合并。

::: {.source-path}
主要入口：`accel/tcg/cputlb.c`、`include/hw/core/cpu.h` 中的 TLB 结构、`target/riscv/tcg/cpu_helper.c`、`target/riscv/tcg/csr.c`、`target/riscv/tcg/insn_trans/trans_rvh.c.inc`、`system/physmem.c` 与 `system/memory.c`。源码锚为官方 GitLab `v11.1.0-rc0`；RISC-V H、PMP fault和 pointer masking的历史提交用于解释当前分支结构。
:::

## 实验：跟踪 Sv39 与两阶段 page walk

::: {.hands-on}
实验名称：`trace-page-walk`。使用英文手册 [`trace-page-walk`](../experiments/part-02-tcg-execution-engine/chapter-10-softmmu/trace-page-walk/README.md)。先在 RV64 TCG中建立最小 Sv39页表，触发普通 RAM load、权限 fault和跨页取指；再用启用 H 扩展的 M/HS-mode测试建立 `vsatp` 与 `hgatp`，分别触发 VS-stage叶 PTE fault、读取 VS PTE时的间接 G-stage fault、最终 GPA 的 G-stage fault。记录每级 PTE地址、权限、最终 cause、`tval` 和 `htval/mtval2`。
:::

实验要把页表内容保存成可检查的 dump，不能只依赖 QEMU日志。为每个故障写预期表，注明 first stage、indirect second stage或 final second stage，再对照 `riscv_cpu_tlb_fill()` 分支。若测试环境没有能运行 HS-mode的固件，使用仓库提供的裸机 harness，不用 Linux用户态缺页替代。

## 实验：测量 software TLB 行为

::: {.hands-on}
实验名称：`measure-tlb-behavior`。使用英文手册 [`measure-tlb-behavior`](../experiments/part-02-tcg-execution-engine/chapter-10-softmmu/measure-tlb-behavior/README.md)。构造工作集从少量页逐渐增大、再构造会落到相同 direct-map索引的冲突页，采集 TLB fill、victim hit、full/partial flush和运行指令数。随后执行 `SFENCE.VMA` 的全局、按地址、按 ASID形式，并在 H 扩展用例比较两种 HFENCE。报告同时给出结构计数与耗时，耗时只作辅证。
:::

测量前关闭大日志，使用 trace event或受控计数器，先跑预热轮。不要把 QEMU software TLB miss解释成客户机真实硬件 TLB miss；实验目标是验证 QEMU缓存策略和 flush范围。若表动态 resize，记录变化点，否则冲突曲线会被误读。

## 怎样从失败现象定位层级

客户机得到 page fault，先看 cause区分普通还是 guest-page，再看 `tval` 与阶段附加地址；接着用页表 dump手工走一遍，确认 PTE合法；然后检查 PMP、PMA和 MemoryRegion。若 QEMU打印 guest error保留位，问题大多在客户机页表；若 walker成功后设备返回 error，则属于 physical transaction。

性能下降先看 fill和 flush计数，再看工作集与冲突，不要立刻修改表大小。频繁 flush可能来自客户机 fence策略，频繁 miss也可能是 MMU index切换或两阶段上下文错误。用同一 PC、同一地址在不同 mode下比较 key，往往能发现漏掉的访问上下文。

## 事实、上游陈述与作者推断

源码事实包括 fast/full entry分离、victim TLB、目标 `tlb_fill`、RISC-V两阶段 walker和异步跨 CPU flush。上游提交明确说明了 guest fault地址宽度、PMP异常优先级、MXR组合、x4地址检查和 AddressSpace修复。作者据此提出“MMU index是访问上下文的压缩”“失败阶段应结构化传递”，这些是对当前实现与修复历史的归纳。

正式 `v11.1.0` 发布后要重新检查 rc0到tag之间的 `target/riscv/tcg/cpu_helper.c` 与 `accel/tcg/cputlb.c` diff。MMU修复常发生在发布候选阶段，实验预期必须和最终代码同步。不能为了保持书稿段落稳定，忽略上游已经改变的 fault语义。

## 小结

SoftMMU 用紧凑 software TLB把常见 RISC-V访存变成内联宿主路径，miss再进入目标页表、PMP和MemoryRegion。fast entry追求命中成本，full entry保存丰富上下文，victim表缓解直接映射冲突，flush协议在多 vCPU间维护一致性。

H 扩展让一次访问包含 VS-stage、隐式 G-stage和最终 G-stage，缓存可以合并结果，异常却必须保留阶段。下一章继续沿异常出口和跨线程请求，看 TCG怎样在连续宿主代码中恢复精确 RISC-V trap，并让 MTTCG多核保持可解释的顺序。
