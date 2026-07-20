# dyngen：QEMU 最初怎样借用 GCC

2005 年，Fabrice Bellard 在 USENIX 论文里画出了一条当时很少见的翻译路径。客户机指令先被拆成几百种 micro-op，每种 micro-op 用一小段 C 实现；GCC 在构建 QEMU 时把这些 C 函数编成宿主目标文件，`dyngen` 再从目标文件里抽取机器码。虚拟机真正运行以后，QEMU 只要把选中的机器码片段拼起来，就能得到一段可执行的宿主代码。

这套方法撑起了早期 QEMU 的速度与可移植性，也埋下了后来必须更换翻译引擎的原因。要理解 TCG 为什么出现，先得走一遍 dyngen 的工作现场。它解决了什么，依赖了什么，又把哪些偶然条件变成了工程债务。

## 从一条客户机指令到一段宿主代码

假设早期 QEMU 正在翻译一条客户机加法指令。目标前端读出 opcode 和操作数，选择若干 micro-op：把客户机寄存器装入约定的临时位置，执行加法，再把结果写回 CPU 状态。micro-op 的数量远少于“指令 × 寄存器 × 寻址方式”的全部组合，所以前端不用为每一种组合准备宿主机器码。

micro-op 的 C 文件会在构建阶段交给 GCC。编译器负责指令选择、宿主寄存器使用和函数序言尾声。`dyngen` 读取编译结果，识别符号、重定位和参数占位点，生成 `gen_op_*()` 一类运行时代码生成函数。客户机执行到尚未翻译的地址时，前端调用这些函数，把机器码片段复制进代码缓存，并按本次操作数修补参数。

[Bellard 2005 年论文](https://www.usenix.org/legacy/events/usenix05/tech/freenix/full_papers/bellard/bellard.pdf) 把这条链写得很清楚：目标指令到 micro-op 的映射由手写前端完成，micro-op 的宿主实现由 GCC 预编译，运行时生成器完成拼接。这里没有“把整个客户机程序转成 C 再编译”的步骤，GCC 也不会在虚拟机运行时启动。QEMU 借用的是 GCC 在构建阶段产生的代码形状。

这个区别影响我们对性能的判断。dyngen 的运行时成本主要是选择、复制和重定位预制片段，复杂的宿主指令选择早已由 GCC 完成。与此同时，片段之间很难共享完整的寄存器分配视野，micro-op 边界可能带来额外装载、保存和跳转。早期方案用更轻的在线生成换来较弱的跨片段优化，这个交换在 2003 年的机器上相当务实。

## 为什么先选择 C 和 GCC

如果每支持一种宿主架构都手写一个代码生成器，QEMU 很快会出现两组相乘的维护工作：客户机前端要理解各自 ISA，宿主后端还要为 x86、PowerPC、SPARC、ARM 等平台生成指令。早期项目的人力有限，先让成熟编译器承担后一半，可以迅速得到多个宿主端口。

C 还给 micro-op 提供了可读的语义载体。开发者能够用普通运算、条件和内存访问表达一小步客户机行为，再让编译器处理 ABI 与指令编码。Fabrice 在论文中把 QEMU 的目标概括为性能与实现复杂度之间的折中。dyngen 正好体现了这种选择：QEMU 不重造完整编译器，把现有编译器产物加工成动态生成器。

它也让早期优化集中在对虚拟机更有价值的地方。条件码可以延迟计算，Translation Block 可以缓存和直接链接，software TLB 可以让常见内存访问绕过完整页表遍历。GCC 擅长优化一个 C 函数，却不了解客户机 PC、异常恢复、代码页失效等虚拟机合同；这些仍由 QEMU 掌握。

今天回看这项选择，很容易拿成熟的 TCG 反推“当初应该直接写 IR 和后端”。这样的推导忽略了项目所处的时间点。2003 年 3 月的 QEMU Git 历史先出现新 x86 CPU core，几天后加入 translation cache，随后才逐步补齐 host port、直接链接和精确异常。dyngen 让这些虚拟机问题可以先被验证，项目没有在第一天同时承担一套在线编译器。

## TB 为什么在 TCG 之前已经存在

Translation Block 并非 TCG 发明的概念。早期 QEMU 已经按需翻译一段客户机指令，把结果放进 translation cache，再让后续执行复用。2003 年提交 [`7d13299d07`](https://gitlab.com/qemu-project/qemu/-/commit/7d13299d07a9c3c42277207ae7a691f0501a70b2) 加入 translation cache；[`d4e8164f7e`](https://gitlab.com/qemu-project/qemu/-/commit/d4e8164f7e9342d692c1d6f1c848ed05f8007ece) 随后为 PowerPC 和 i386 加入 direct chaining；[`a513fe19ac`](https://gitlab.com/qemu-project/qemu/-/commit/a513fe19ac4896a09c6c338204d76c39e652451f) 的提交主题已经是 precise exceptions。

这三步解释了 TB 的基本职责。缓存需要一个可查找、可复用的对象；链接需要确定的入口和出口；异常需要从宿主执行位置找回客户机指令状态。于是 TB 从一段生成代码逐渐变成多项合同的交点：它带着客户机起始 PC 和翻译相关状态，关联宿主代码范围与客户机代码页，记录出口，也保存恢复精确状态所需的映射。

在 `v11.1.0-rc0` 中，这条老问题仍能从 [`accel/tcg/cpu-exec.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/tcg/cpu-exec.c) 看到。`cpu_exec()` 取得当前 CPU 的 TB 状态，查找缓存，未命中时进入生成路径，随后执行宿主代码。RISC-V 前端位于 [`target/riscv/tcg/translate.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/tcg/translate.c)，它决定一段 RV64 指令怎样展开、何时结束。代码生成器从 dyngen 换成 TCG，按需翻译、缓存、执行、退出这一层运行协议延续了下来。

因此，阅读现代 TCG 时应把两个问题分开。TB 回答“以什么单位缓存和执行客户机代码”，IR 与后端回答“这个单位怎样生成宿主代码”。把两者混为同一项设计，会误以为更换代码生成器必然重做整个执行循环，也看不懂 2008 年为什么能够渐进迁移。

在当前 RISC-V 路径里，这层分工还能展开得更细。`riscv_translate_code()` 把公共 `TranslationBlock` 和 `CPUState` 交给 `translator_loop()`；公共循环控制最大指令数、单步、plugin 与页边界，RISC-V 的 `DisasContext` 保存 XLEN、privilege、虚拟化状态、memory index 和当前 PC。每成功译一条指令，前端推进上下文并产生 TCG op；遇到 branch、异常、特权状态变化或公共上限时结束。

随后 `tb_gen_code()` 把前端结果交给 `tcg_gen_code()`，完成优化、活跃性、寄存器分配和后端发射。宿主代码与恢复元数据准备完整以后，TB 才能进入 lookup 结构。`cpu_tb_exec()` 通过 TCG prologue 进入代码缓存，TB 出口返回带原因的结果；外层决定链接下一个块、处理异常或响应管理请求。任何一环都可以在不改变 RV64 指令语义的前提下演进，连接处的状态合同却要保持一致。

TB 的“身份”也远多于 PC。同一 RV64 地址在 M-mode 与 S-mode、V=0 与 V=1、不同 XLEN 或翻译相关扩展状态下，指令合法性和访存规则可能变化。`riscv_get_tb_cpu_state()` 把会改变生成结果的状态放进 key；普通 GPR 内容属于运行数据，不进入 key。key 太少会错误复用，key 太多会制造大量只差无关状态的 TB。阅读新增 flag patch 时，应先检查那一位是否真的改变代码形状。

:::: {.quick-quiz}
同一个 RV64 PC 为什么可能对应多个 TB？

::: {.quick-answer}
PC 只给出起点。privilege、虚拟化、XLEN、地址转换上下文和部分扩展状态会改变合法指令、访存或异常路径，必须进入 TB 身份。普通寄存器计算结果不应进入，否则每次运行都难以复用缓存。
:::
::::

## GCC 的产物何时变成了接口

dyngen 读取的对象文件并不是稳定 API。GCC 只承诺生成语义正确的目标代码，没有承诺某个 C 函数一定以 `ret` 收尾、局部跳转采用哪种布局、符号放在哪张表、重定位长什么样。目标文件格式又随 ELF、Mach-O、宿主 ISA 和 ABI 改变。dyngen 要从中识别可搬运片段，相当于依赖编译器后端的实现细节。

这些依赖最初能被控制。QEMU 的 configure 脚本检测编译器行为，micro-op C 代码避开容易改变形状的写法，dyngen 为不同宿主格式实现解析和重定位。可随着 GCC 4 的优化器变化，维持这份默契越来越难。一个本来合法的控制流优化，可能把函数尾部改成 dyngen 没准备识别的布局；解决眼前构建失败，往往要再加一个 `-fno-*` 选项。

对象格式让问题进一步扩大。ELF 的 REL/RELA、Mach-O 的 symbol table、不同宿主的小数据段和 branch relocation 都需要专门解析；一段代码可以在原地址运行，不代表复制到 code cache 后仍然正确。dyngen 要识别哪些引用能重定位、哪些局部跳转留在片段内、参数占位如何修补，还要在发射后执行宿主 instruction-cache flush。宿主端口因此同时依赖 ISA、ABI、编译器与对象格式四个维度。

这些代码并非全无价值，它们帮助 QEMU 发现动态翻译后端必须明确表达的事项：寄存器约束、立即数、重定位、调用约定、代码缓存权限和 icache 同步。TCG 后来把它们从“猜 GCC 产物”改成受 QEMU 控制的 backend 接口。问题没有凭空消失，控制权和可测试边界发生了变化。

2008 年 2 月，Christian Roue 报告 SH4 linux-user 使用 GCC 4.1.2 构建失败。他继续缩小问题，发现 `op_cmp_str_T0_T1` 被优化成“`ret` 后还有赋值，再向后跳回出口”的形状，并尝试 `-fno-tree-dominator-opts`。Alexander Graf 判断这个方向能处理症状，建议放进 configure 的自动检测；Thiemo Seufer 随后指出，那些选项原本就是 workaround，期待的是逐渐删除，而非继续扩张。对应的[报告](https://lists.gnu.org/archive/html/qemu-devel/2008-02/msg00320.html)、[诊断](https://lists.gnu.org/archive/html/qemu-devel/2008-02/msg00338.html)和[回复](https://lists.gnu.org/archive/html/qemu-devel/2008-02/msg00342.html)留下了一条短而完整的证据链。

这次故障发生在 TCG 公告之后，却准确展示了替换仍然必要的原因。当时 SH4 尚未完成迁移，只能继续走 legacy micro-op。编译器生成了正确函数，QEMU 构建仍然失败，说明对象代码布局已经成为隐藏接口。只修一个目标、一个 GCC 版本，下一次优化器变化还会打开新的缺口。

## 快速执行不能牺牲精确状态

一段 RV64 热循环反复命中 TB 时，vCPU 可以在生成代码中连续运行，许多中间值留在宿主寄存器。遇到 `lw` page fault、非法指令、外部中断或调试停止，QEMU 又必须把控制权交回 C，并让客户机看到准确 PC 与架构状态。这项要求早于 TCG，现代实现只是把恢复信息做得更系统。

TB 不能随意无限增长。块越长，首次翻译时间和代码缓存占用越高，异步事件最坏响应也会拉长；跨越更多客户机代码页，又会放大自修改代码的失效范围。块太短则频繁返回执行循环，浪费查找和 prologue/epilogue 成本。当前 RISC-V translator 与公共 `translator_loop()` 一起决定边界：控制流、可能改变翻译状态的指令、单步、最大指令数和页面约束共同参与。

direct chaining 也受到正确性限制。相邻 TB 可以把出口直接修补到目标宿主代码，省下一次主循环查找；映射或代码内容变化时，这条链接必须解除。当前 [`docs/devel/tcg.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/devel/tcg.rst) 说明 `goto_tb + exit_tb` 的要求，并解释为何直接分支通常限制在同一页：内存映射变化不能让旧链接跳到已经失效的代码。

RISC-V 的 `fence.i` 提供了一个适合观察的边界。客户机修改将要执行的指令后，需要按 ISA 合同同步取指视图；QEMU system emulation 同时利用内存写路径发现已翻译代码页，失效相关 TB 和直接链接。客户机同步与模拟器失效协议缺一项，测试都可能表现出偶发旧代码。这里没有哪一项“优化附加功能”，缓存正确性本来就是动态翻译的一部分。

当前 RISC-V `trans_fence_i()` 给出了一个容易误读的实现：注释称 FENCE.I 在 QEMU 中是 no-op，同时函数会更新 PC、结束 TB 并返回执行循环。“no-op”指 QEMU 不在这里再做一遍 host instruction-cache 维护，代码页写路径已经承担 TB 失效；结束 TB 仍然是必要语义边界。若只 grep 到注释就宣布客户机可以省略 FENCE.I，会把实现分工错写成架构规则。

精确异常也依赖同一份 TB 元数据。生成代码中的第 N 条 RV64 指令 fault 时，slow path 带宿主 return address 退出，QEMU 查到所属 TB 和 instruction boundary，再恢复客户机 PC。若 TB 已因代码修改失效，正在执行的旧块仍要在安全出口完成生命周期，不能一边回收元数据一边让另一线程用它恢复状态。失效、执行和回收由此成为三件不同的事。

:::: {.quick-quiz}
页面写入已经让旧 TB 失效，为什么还不能立即释放全部 TB 元数据？

::: {.quick-answer}
另一颗 vCPU 可能正在旧宿主代码中运行，异常恢复还需要 TB 的客户机—宿主映射。失效先阻止新 lookup 和 direct jump 使用，真正回收要等现有执行者离开并满足生命周期协议。
:::
::::

## dyngen 留给 TCG 的问题清单

到 2008 年，QEMU 已经知道一套新生成器至少要守住六项能力：按 TB 生成代码，保留精确异常恢复，支持 software MMU，处理自修改代码，允许直接链接，并能在多个客户机目标与宿主目标之间扩展。新的实现还要摆脱 GCC 对象布局，减少 micro-op 边界带来的寄存器往返。

这份清单决定了 TCG 不会成为通用的重量级优化编译器。虚拟机第一次走到一个 PC 时就在等待代码，翻译时延直接进入客户机执行路径；生成结果的生命又可能因代码写入、断点、插件或全局 flush 提前结束。QEMU 需要在线完成 IR 生成、轻量优化、寄存器分配和宿主发射，还要给异常与失效留下可追踪的边界。

另一个约束来自迁移过程。2008 年的 QEMU 已有多个目标，要求所有前端在一天内重写会让主线长时间不可用。TCG 必须暂时接纳 legacy dyngen micro-op，让旧目标可以一部分一部分迁移。这项兼容桥接会在下一章展开，它也是 IR 设计起初仍明确标注“legacy dyngen operation”边界的原因。

回到现在，RISC-V 没有经历过自己的 dyngen 时代。RISC-V target 在 2018 年进入 QEMU 时直接生成 TCG op，因而享受的是前人替换引擎后形成的 guest/host 分层。理解这段历史的价值，正是看清当前 [`target/riscv/tcg`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/target/riscv/tcg) 为什么只描述客户机语义，不需要夹带 GCC 对象文件解析和每种宿主指令编码。

阅读当前代码时，可以用一张“TB 档案”检验是否真正理解执行单位。档案至少包含 guest start PC、物理代码页、`TCGTBCPUState`、客户机指令数、host code 范围、两个出口、incoming/outgoing link、生成原因和最终失效原因。只有 `in_asm` 没有 key，无法解释同一 PC 为什么重复生成；只有宿主地址没有代码页，也无法解释页面写入怎样找到它。

lookup 也要区分局部快路径和全局结构。vCPU 最近跳转具有强局部性，per-vCPU cache 先吸收常见命中；完整 key 不匹配或缓存未命中，才进入更通用的哈希查找。MTTCG 下查找要允许多个读者，生成与发布又可能并发。性能报告若只统计“哈希命中”，会漏掉更前面的 jump cache 与 direct chaining。

TB 生成失败同样属于生命周期。后端发射发现空间不足、单块超限或 slow path overflow 时，未完成对象不能进入 lookup；代码缓存 flush 后可以重新尝试。调试偶发冷启动卡顿时，要把“首次生成”“因空间重试”“全局 flush 后重建”分成不同 trace event，不能把日志里两次 `in_asm` 都归于缓存 key 错误。

最后核对版本边界。本书的源码事实固定到 `v11.1.0-rc0`，历史 commit解释设计转折，实验结果还要记录实际二进制的 `--version` 与构建配置。TB 结构、日志字段和默认 cache size 都可能变化；PC、状态假设、发布、执行和失效这条合同更稳定。更新书稿时先判断变化落在哪一层，再决定改图、改实验或只更新符号名。

## 实验：观察一个 RV64 TB 的生命周期

::: {.hands-on}
实验使用 [`observe-tb-lifecycle`](../experiments/part-02-tcg-execution-engine/chapter-07-translation-blocks/observe-tb-lifecycle/README.md)。准备一段包含 RV64 整数循环和条件出口的裸机程序，在 `qemu-system-riscv64 -accel tcg` 下运行，并用 `-d in_asm,op,out_asm -D <log>` 限定日志文件。先把客户机 PC 范围、QEMU 完整 commit、CPU 型号和命令保存下来，再标出第一次翻译时出现的客户机指令、TCG IR 与宿主代码。

循环次数应足够大。若日志只在首次到达时出现生成内容，后续执行却持续推进计数，说明翻译结果正在复用；日志行数不能直接当作 TB 执行次数。再开启 single-step 或 icount，比较 TB 边界与链接变化。这个对照会显示，TB 大小受执行策略影响，并非由 RV64 branch 独自决定。

报告为每个 TB 记录起始 PC、翻译相关 flags、客户机指令数、代码页、两个出口和最终退出原因。`in_asm` 只能证明输入块，`op` 才能看到 IR，`out_asm` 受宿主架构影响。实验如果运行在 x86_64 宿主，宿主反汇编就按 x86_64 标注，不能把它写成 RISC-V 后端输出；本章统一用 RISC-V 描述客户机语义。
:::

## 实验：让代码缓存承认内存已经改变

::: {.hands-on}
第二个实验沿用 [`trigger-tb-invalidation`](../experiments/part-02-tcg-execution-engine/chapter-07-translation-blocks/trigger-tb-invalidation/README.md)。在一页可写可执行的客户机 RAM 中放置短函数，先反复调用使 TB 变热，再把其中一条 RV64 指令替换成等长编码，执行规范要求的 `fence.i` 后重新进入。观察旧 TB 解除链接、失效和再次生成，并核对新结果。

为了把因果关系拆开，保留三组用例。第一组只执行原代码，证明缓存稳定；第二组修改指令并正确执行 `fence.i`，作为架构正确性用例；第三组故意省略同步，只记录现象，不把某次得到新旧代码写成保证。再增加一页完全无关的热代码，确认精确失效没有把所有 TB 都重新生成。这样才能区分页级失效与全局 flush。

若环境允许两个 hart，再让一颗 hart 修改、另一颗 hart 执行。日志要同时记录客户机同步、QEMU 页面失效与执行线程重新查找三个时点。时间戳可以帮助排列现象，真正的并发保证仍要回到 `accel/tcg` 的锁、原子操作和安全工作协议；实验不替代源码中的内存序证明。
:::

## 小结

dyngen 的价值在于把 GCC 已有的宿主代码生成能力带进早期 QEMU，让项目先解决动态翻译、TB 缓存、直接链接和精确异常。它的代价也来自同一入口：编译器版本、目标文件格式和函数布局逐渐成为 QEMU 必须追随的隐藏接口。

2008 年要解决的已经不止一次 GCC 构建失败。QEMU 需要自己控制 IR、寄存器分配与宿主发射，同时保留运行多年的 TB 和异常合同，还要让各目标逐步搬迁。下一章进入这次更换引擎的现场，并解释为什么“通用 C 编译器后端”与 Paul Brook 的 QOP 只能作为 TCG 的来源线索，不能被改写成“TCG 原来就是 TinyCC”。
