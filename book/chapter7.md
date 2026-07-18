# 动态翻译与 Translation Block

让一段 RISC-V 固件在 TCG 上启动，日志里很快会出现一个有趣现象：同一段客户机代码不会每次都重新译码。第一次走到某个地址时，QEMU 生成宿主代码；循环再次回来，执行流直接落进已经存在的代码块。速度来自复用，麻烦也随之出现。客户机可以改写代码页，调试器可以插入断点，MMU 映射会变化，另一颗 vCPU 还可能正在执行待失效的代码。Translation Block，简称 TB，就是这些需求共同妥协出的执行单位。

TB 常被介绍成“若干客户机指令组成的基本块”，这个描述只够解释入口。QEMU 里的 TB 还带有翻译状态、物理页关联、宿主代码位置、退出信息与跳转链接，它同时服务查找、执行、失效、回溯和调试。把它只当编译器基本块，读到自修改代码和 MTTCG 时会突然失去坐标。

## 本章目标

- 理解动态翻译相对解释执行、提前编译的工程取舍；
- 跟踪 `cpu_exec()`、`tb_lookup()`、`tb_gen_code()` 与目标 `translator_loop()`；
- 拆开 TB 的身份、边界、缓存、直接链接与退出；
- 说明自修改代码、断点和代码缓存耗尽怎样触发失效或 flush；
- 用 RISC-V 实验观察一次 TB 的生成、复用、链接和重建。

## 从一个热循环开始

假设客户机在 `0x80002000` 运行一个十条指令的整数循环。解释器每轮都要取指、匹配 opcode、分派语义，循环跑一百万次，译码开销也重复一百万次。静态翻译可以提前处理整个映像，却很难知道运行时装载模块、JIT 生成代码和页表变化，精确异常位置也要额外映射。TCG 选择按需动态翻译：执行第一次到达该 PC 时生成宿主代码，把成本摊到后续命中。

“按需”还让 QEMU 只处理真正走到的路径。固件映像里大量错误分支、平台兼容代码可能从未执行，不必消耗翻译时间和代码缓存。代价是冷路径第一次进入会产生翻译延迟，代码缓存需要管理，翻译结果还必须与客户机状态保持一致。TB 因而没有追求传统编译器那样跨函数的大范围优化，它更重视生成快、定位准、容易退出。

动态翻译的收益取决于两个比例：一段代码复用多少次，以及一次 TB 执行相对生成成本有多大。短命进程、频繁切换地址空间或大量生成代码的工作负载，复用率会下降；稳定内核循环、固件等待路径则很容易变热。QEMU 不假定所有程序都热，它把快速 lookup 和相对轻量的生成管线放在一起，允许未命中后迅速补块。

## `cpu_exec()` 看到的执行世界

TCG vCPU 线程进入 [`accel/tcg/cpu-exec.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/tcg/cpu-exec.c) 的执行循环。外层先处理异常、退出请求与中断，内层取得目标提供的 TB CPU state，查找对应 TB，必要时生成，然后跳入宿主代码。TB 返回后，循环根据 exit reason 决定查下一个块、处理链式跳转、响应请求，或离开执行引擎。

这里有两种时间尺度。宿主生成代码内部尽量连续，避免每条客户机指令都回到 C；`cpu_exec()` 则在 TB 边界重新获得控制，处理无法或不适合内联的全局事务。TB 太短，C 与生成代码之间切换频繁；TB 太长，中断、单步和失效响应延迟变大，翻译成本也难摊。边界选择是一项调度策略，不只是译码器看见 branch 就停止。

当前版本把目标相关的状态取得放入 `TCGCPUOps`。2025 年提交 [`4759aae432`](https://gitlab.com/qemu-project/qemu/-/commit/4759aae432) 让 `cpu_get_tb_cpu_state` 返回 `TCGTBCPUState` 结构，而不是通过三个输出指针返回；提交 [`c37f8978d9`](https://gitlab.com/qemu-project/qemu/-/commit/c37f8978d9) 又把该函数移到 `TCGCPUOps` hook；[`18a77386f1`](https://gitlab.com/qemu-project/qemu/-/commit/18a77386f1) 随后把结构直接传给 `tb_gen_code()`。这些提交本身不改变客户机语义，上游在做的是让“取得 TB 身份状态”成为显式、可携带的边界。

作者从这一系列推断，结构体返回的意义超过代码风格：当一个目标需要更多身份位时，公共调用链不必继续增加平行参数，调用者也较难把某次取得的 PC 与另一次取得的 flags 混用。这个解释属于作者推断，事实依据是提交顺序和当前接口，不应写成上游明确承诺。

## TB 的身份证不只有 PC

客户机 PC 说明从哪里开始，却不能单独决定生成代码。RISC-V 当前特权级会影响 CSR 与地址转换，虚拟化状态会改变 VS/HS 语义，扩展和运行模式会改变某些编码是否可用，数据端序与内存序也可能进入生成选择。目标 CPU 把影响翻译结果的状态编码进 `flags`、`cs_base` 或相关字段，lookup 只有在这些值一致时才能复用 TB。

一个常见错误是把所有 CPU 状态都塞进 key。这样当然安全，任何变化都会未命中，但缓存命中率会迅速下降，key 比较和失效也变重。正确做法是只加入会改变“这段代码应怎样生成”的状态。通用寄存器内容通常是运行数据，不进入 key；当前 PC 必须进入；某项扩展若在 CPU realize 后固定，也可能不必每次编码；客户机能在运行时切换且会改变翻译的状态，则必须反映。

RISC-V 在 2026 年遇到了 flags 位数不够的问题。提交 [`1c88ab9e77`](https://gitlab.com/qemu-project/qemu/-/commit/1c88ab9e77) 题为“Use the `tb->cs_base` as the extend tb flags”，提交说明指出 RISC-V 每个 TB 需要表达的状态已经超过 32 位，于是使用 `cs_base` 承载扩展 flags。对应邮件 Message-ID [`20260402125234.1371897-6-max.chou@sifive.com`](https://lore.kernel.org/qemu-devel/20260402125234.1371897-6-max.chou@sifive.com/) 能看到系列上下文。

这条演进揭示了模块化 ISA 的实际成本。扩展增加并不只多几个 `trans_*`，影响翻译的模式位也会挤压缓存身份空间。作者推断，新增 TB flag 前应先回答它是否真的改变生成代码，能否在 realize 后固定，能否由已有字段推导。否则“为安全起见多放一位”会把长期扩展压力推给每次 TB lookup。

:::: {.quick-quiz}
为什么 guest PC 不能唯一标识一个 RISC-V TB？

::: {.quick-answer}
同一 PC 在不同特权级、虚拟化状态、地址空间和翻译相关模式下，合法指令、访存规则与异常路径可能不同。QEMU 必须把会改变生成结果的状态放进 TB 身份；寄存器普通数据则不应进入，否则缓存会因每次计算结果变化而失去复用。
:::
::::

## 一次 TB 怎样生成

lookup 未命中后，`tb_gen_code()` 分配 TB 元数据和代码缓存空间，设置 PC、flags、最大指令数等输入，再启动 TCG 翻译上下文。目标 RISC-V translator 取指、调用 decodetree 生成的译码函数，逐条产生 TCG IR。翻译停止后，TCG 优化 IR，完成寄存器分配和宿主后端发射，记录客户机指令到宿主代码的映射，最后把 TB 发布到查找结构与页面关联中。

这条路径的顺序不能随便换。TB 在宿主代码完全写好、元数据完整之前，不能让另一 vCPU lookup 命中；页面关联必须在失效协议可见之前建立；W^X 平台上写代码和执行代码还可能使用不同映射或权限切换。发布动作看起来只是把指针放入哈希表，背后需要保证读线程看到的对象已经初始化完毕。

目标 translator 并不自行决定全部边界。公共 `translator_loop()` 提供最大指令数、单步、插件和 page 限制等条件，RISC-V `DisasContext` 再根据指令语义结束块。例如无条件跳转自然终止顺序流，可能改变特权或地址转换状态的指令也要回到调度点，异常指令则生成退出。边界是公共执行策略与 ISA 语义的交集。

翻译失败也要可恢复。代码缓存剩余空间不足时，当前生成不能写越界；宿主后端发现 buffer overflow，需要丢弃未完成结果并安排 flush 或重新分配。提交 [`ebf7a5d294`](https://gitlab.com/qemu-project/qemu/-/commit/ebf7a5d294) 改进 `tb_gen_code()` 的 buffer overflow 处理，提交 [`31dd80e1e7`](https://gitlab.com/qemu-project/qemu/-/commit/31dd80e1e7) 加入对应 trace，邮件 [`20250925035610.80605-3-philmd@linaro.org`](https://lore.kernel.org/qemu-devel/20250925035610.80605-3-philmd@linaro.org/) 表明上游希望这类稀有事件可观察，而不是只留下模糊的性能抖动。

## TB 为什么不能无限增长

控制流是最直观的边界，但不是唯一边界。默认情况下，翻译还受最大指令数、页面边界、单步和 icount 限制。RISC-V 指令有 16 位压缩编码，也有更长编码的扩展空间，取指接近页尾时必须谨慎处理下一页。若一个 TB 横跨太多页面，自修改代码反向关联会变复杂，失效锁集合也扩大。

异常响应是另一项约束。外部中断通常在可接受边界检查，TB 越长，最坏响应时间越高。QEMU 可以在生成代码中插入额外出口，却会增加每次执行成本。于是实现选择有限大小的块，在热路径连续执行和异步事件延迟之间折中。调试单步时最大指令数会被压到一条，说明 TB 大小是运行策略，不是固定编译属性。

插件和日志也会改变边界或生成内容。开启 `-d in_asm,op,out_asm` 会记录不同阶段，TCG plugin 可能要求按指令插桩，`icount` 需要可预测地计数客户机指令。这些功能不能复用一份缺少插桩的宿主代码，所以相应 cflags 或 flush 机制要让旧 TB 退出。观测工具并非站在执行引擎之外，它会参与代码生成契约。

:::: {.quick-quiz}
为什么 TB 通常不能无限增长？

::: {.quick-answer}
更长的 TB 可以减少分派，却会增加首次翻译延迟、代码缓存占用、页面关联和失效成本，也会拉长中断、单步与退出请求的响应。控制流、异常语义、页边界和运行策略共同限制长度，目标是让热路径有足够连续性，同时保留可控的安全点。
:::
::::

## 两级查找为什么值得存在

TB lookup 是每次从执行循环进入下一个块都可能经过的热路径。QEMU 先尝试与 vCPU 关联的快速缓存，命中后比较完整身份；未命中再进入共享或更完整的查找结构。局部程序通常反复运行少量相邻块，小缓存能用很低成本吸收大多数访问，全局结构则保证容量和跨路径复用。

快速缓存不能只比较 PC。旧条目可能来自另一 flags 或另一物理映射，必须验证 key。另一方面，每次都重新做客户机虚拟到物理转换也很贵，TB 查找会利用目标提供的状态和代码页信息。这里和 SoftMMU 有联系，但用途不同：数据 TLB 加速客户机访存，TB 结构加速已翻译代码定位，两者在页表变化时又要协调失效。

查找结构需要面对并发。MTTCG 下两颗 vCPU 可能同时在同一 PC 未命中并生成等价 TB，或者一边 lookup、一边失效。实现可以允许短时间重复生成，再在发布阶段选择现有对象，也可以用锁串行化关键区域。过度锁住整个翻译过程会让多核客户机冷启动互相阻塞，完全无锁又会使对象生命周期难以证明。当前代码把查找、页面锁、RCU 读取和发布组合起来，读者应沿具体函数看锁域，不能只用“哈希表线程安全”一笔带过。

## direct chaining 省掉了什么

如果 TB A 每次都稳定跳到 TB B，A 返回 `cpu_exec()`、重新 lookup B 再进入，会重复支付分派成本。direct chaining 在 A 的宿主代码出口打补丁，让它直接跳到 B 的入口。客户机热循环可以在多个 TB 之间连续运行，通用 C 循环只在需要处理事件时重新掌权。

链接不是不可撤销。目标 TB 失效时，所有指向它的入口都要解除；调试、单步、插件或退出请求也可能要求停止直接链。TB 元数据因此保存出边和入边关系，失效路径既处理自己的代码，也要拆开邻居引用。提交 [`03fe665980`](https://gitlab.com/qemu-project/qemu/-/commit/03fe665980) 修复 TB 链到自身时的 unlink，提交说明指出移除 destination 链接时可能丢掉随后仍需处理的关系。一个边界条件足以说明，direct jump 不是简单保存“下一个地址”，它是一张会动态修改的图。

宿主代码补丁还受平台权限和指令缓存约束。生成区可能采用分离读写与执行映射，修改跳转后要确保其他线程和处理器看到新指令。2026 年提交 [`78420b59f0`](https://gitlab.com/qemu-project/qemu/-/commit/78420b59f0) 将 macOS 上 JIT 写权限操作移入 `do_tb_phys_invalidate`，邮件 [`20260526110243.470002-5-alex.bennee@linaro.org`](https://lore.kernel.org/qemu-devel/20260526110243.470002-5-alex.bennee@linaro.org/) 说明失效在该平台需要先开启 JIT 区写访问。上游事实提醒我们，宿主代码缓存也有内存保护协议，不能把它当普通 malloc 缓冲区。

:::: {.quick-quiz}
direct chaining 如何与异步中断共存？

::: {.quick-answer}
直接链接省掉常规 TB 分派，不取消退出机制。生成代码在规定位置观察退出条件，其他线程通过发布请求并 kick vCPU 让它离开链；需要全局改变执行条件时，还可解除链接或 flush。关键是链接图必须可逆，退出请求与补丁对执行线程具有正确可见性。
:::
::::

## TB 退出包含可解释的信息

TB 返回值不仅表示“执行结束”。正常落到下一 PC、间接跳转、请求 lookup、同步异常、原子执行需求和外部退出，会走不同编码路径。执行循环据此决定能否链接、是否处理异常、是否重新取得状态。若所有情况都返回一个布尔值，C 层只能重新检查大量全局字段，热路径和错误路径都会变得模糊。

精确异常还要求知道宿主 PC 对应哪条客户机指令。翻译时插入的 `insn_start` 元数据把生成代码位置与 RISC-V PC、必要状态关联起来。宿主收到信号或 helper 决定退出时，QEMU 可以回溯到当前 op，恢复客户机 PC，再报告 page fault、非法指令或断点。TB 是这张映射的自然范围，超出 TB 做任意全局优化，会增加状态回溯难度。

间接跳转无法提前知道目标，通常返回查找路径；直接分支可以带两个固定出口，便于 chaining。RISC-V 的 `jalr` 目标来自寄存器，生成代码可能利用 jump cache，但仍需验证身份；条件 branch 则有 taken 与 fall-through 两个稳定候选。源码中的 `tb_add_jump` 与 exit index 正是把客户机控制流映射到可补丁宿主出口的桥。

## 自修改代码把缓存变成一致性协议

客户机写普通数据时，无需碰 TB；写到已翻译代码所在物理页，旧宿主代码可能立即过时。QEMU 必须建立“物理代码页到 TB”的反向关系，写入路径才能快速找到受影响块。一个 TB 可能跨两个页面，两个页面都要关联；失效时又要从每个页面结构移除，并拆开 direct jump。

为何按物理页关联，而不是只按客户机虚拟地址？同一物理代码可能通过不同虚拟地址映射，页表重映射也会让相同虚拟地址指向新内容。真正决定指令字节的是客户机物理内存及其 MemoryRegion 映射。虚拟 PC 仍是 TB 身份一部分，但自修改写入要从最终落到的物理页寻找受害者。

失效路径和执行线程并发时，不能立刻释放另一个线程仍在使用的 TB。锁负责修改页面关系与链接图，RCU 或相应生命周期机制允许读侧完成，代码缓存回收则在安全条件下进行。把所有操作放到 BQL 下会比较容易推理，却会破坏 MTTCG 的并行性；细粒度 page collection 又增加锁排序和重复页面处理。当前 `accel/tcg/tb-maint.c` 中的 page collection、锁定和 `tb_phys_invalidate()` 是阅读重点。

2025 年提交 [`a9519a4615`](https://gitlab.com/qemu-project/qemu/-/commit/a9519a4615) 从 `tb_flush` 建立 `queue_tb_flush`，把“现在已经满足独占或串行条件，可以直接清空”和“从普通 vCPU 上下文排队请求清空”分开；此前 [`b773c149a8`](https://gitlab.com/qemu-project/qemu/-/commit/b773c149a8) 拆出 `tb_flush__exclusive_or_serial`。上游命名把前置条件写进函数，减少调用者在并发状态不满足时直接清全局缓存的机会。

作者推断，这种长函数名是一种并发文档。TB flush 能否调用取决于其他 CPU 是否运行、调用者是否处在 serial context，若条件只藏在注释里，未来调用点很容易误用。把约束写进 API 名称并提供 queue 版本，牺牲一点简洁，换来审查时可见的安全边界。

## 为什么有时只能全局 flush

精确失效需要找到具体物理页和 TB，优点是保留无关热代码。某些变化却影响全部翻译条件，例如代码缓存空间耗尽、全局插桩配置改变，或者实现无法可靠缩小范围，此时全局 flush 更稳妥。flush 会丢掉热 TB，引发一轮重新翻译，频繁出现时表现为明显性能锯齿。

全局 flush 因而既是正确性机制，也是可观测的性能事件。提交 [`98d7c29941`](https://gitlab.com/qemu-project/qemu/-/commit/98d7c29941) 为 `tb_flush()` 增加 trace，对应邮件 [`20250925035610.80605-2-philmd@linaro.org`](https://lore.kernel.org/qemu-devel/20250925035610.80605-2-philmd@linaro.org/)。当工作负载突然变慢，trace 能帮助区分“客户机代码本身慢”与“执行引擎不断丢缓存”。

代码缓存也不能无限扩大。更大缓存降低容量 flush，却增加宿主内存占用和失效扫描成本；JIT 区还受地址范围、跳转编码与 W^X 平台约束。TCG 将缓存划分为 region，让多个翻译线程取得空间，同时保持后端 relocation 能到达相关目标。这里的工程目标是稳定运行，不是让一次 benchmark 把所有宿主内存吃满。

## 跨页取指与跨页 TB

RISC-V 压缩指令使 PC 可能按两字节对齐，一条 32 位指令可能从页面倒数两字节开始，后半段落到下一页。翻译器不能先无条件解引用四字节宿主指针，再补查第二页权限；后一页可能不存在、不可执行，甚至映射到 MMIO。正确顺序要让取指遵守客户机地址转换和异常语义。

TB 若跨越页面，两个物理页都决定它的指令内容。页一保持不变、页二被写，TB 仍须失效。页面收集逻辑还要处理地址回绕、不同 page bits 与 IOMMU 映射。提交 [`ec03dd9723`](https://gitlab.com/qemu-project/qemu/-/commit/ec03dd9723) 虽然修复的是严格对齐目标在 pointer wrap 前后处理顺序，却揭示了通用取指路径的约束：异常优先级必须符合目标规则，通用代码不能先触发一个更晚的检查。

对 RISC-V 实验而言，最好主动把指令放在页尾，而不是等待编译器偶然生成。链接脚本可以控制 section 地址，测试程序再分别映射或撤销后一页。观察结果不只是“QEMU 崩不崩”，还要确认异常 PC、cause 和 fault address 对应当前指令，旧 TB 是否在映射改变后重建。

## 断点、单步和 icount 怎样改变 TB

软件断点可能通过改写客户机代码实现，也可能让翻译器在指定 PC 插入调试退出。无论哪种，已有 TB 都不能继续绕过断点。QEMU 会使覆盖地址的 TB 失效，重新生成带检查的代码。断点移除后也要重建，否则热路径会永久保留无用开销。

单步要求每执行一条客户机指令就返回调试循环，最直接方式是限制 TB 指令数并关闭不合适的 chaining。当前版本将 `CPUState::singlestep_enabled` 更名为 `singlestep_flags`，提交 [`7e28b7c897`](https://gitlab.com/qemu-project/qemu/-/commit/7e28b7c897) 说明该字段早已包含多个 flag，邮件 [`20260705215729.62196-32-philmd@oss.qualcomm.com`](https://lore.kernel.org/qemu-devel/20260705215729.62196-32-philmd@oss.qualcomm.com/) 展示了命名审查。这个变化不直接修改 TB，却让影响生成策略的状态含义更准确。

`icount` 追求可重复的客户机指令计数，TB 入口要检查预算，退出要报告消耗。它会牺牲一部分吞吐，换取确定性和虚拟时间控制。若直接拿开启 icount 的结果与默认 TCG 比性能，很容易得出错误结论。实验报告应记录所有影响 TB cflags 的选项，因为缓存行为离不开运行配置。

## RISC-V TB flags 应该怎样逐位审查

`cpu_get_tb_cpu_state()` 把当前PC和翻译相关状态交给公共查找。审查RISC-V flags时，不要从宏名猜含义，应为每一位找到三个位置：它在哪里从 `env` 或CPU配置生成，哪段翻译代码读取它，什么事件会改变它并让执行离开旧TB。少任意一个，flag都可能是无效负担或潜在一致性缺口。

特权级和虚拟化状态是典型动态位。执行 `mret/sret`、进入trap或切换V状态后，后续指令的CSR权限与地址转换变了，当前TB必须结束，新PC按新flags查找。数据端序若受 `mstatus` 动态位控制，同样需要在写CSR后退出；固定CPU扩展在realize后不变，可以通过配置指针参与translator初始化，未必每次占flags。

debug trigger、指令级控制流保护状态和某些向量已知条件也可能影响生成。提交 `1c88ab9e77` 使用 `cs_base`扩展RISC-V flags，解决容量问题，却不意味着空间可以无约束增长。越多动态状态进入key，切换时会形成多份相同PC的TB，代码缓存与lookup局部性都会受影响。

实验中可以对同一PC在M、S、VS三种上下文各停一次，打印 `TCGTBCPUState`，再对照日志中的TB生成次数。若两个状态生成代码完全相同，却因一个无关flag分成两份，这是潜在优化线索；在提交补丁前仍需证明该位不影响任何helper和异常路径。

## `translator_loop()` 的阶段边界

公共 translator先调用目标 `init_disas_context`，让RISC-V从TB state建立 `DisasContext`；随后进入逐指令循环，在每次迭代调用 `insn_start`、取指与 `translate_insn`；达到停止条件后，目标 `tb_stop`生成最终PC更新和TB exit。公共层维护最大指令数、插件和page边界，目标层维护ISA状态。

`insn_start` 必须在可能fault的操作之前出现，记录当前RISC-V PC和必要扩展数据。若优化器删除一条纯指令，对应元数据可按规则处理；若load保留，异常回溯仍要找到它。目标前端提前更新 `ctx->base.pc_next` 方便顺序翻译，异常恢复不能直接拿这个“下一PC”冒充当前PC。

`tb_stop` 根据disas jump type决定下一步。顺序执行可写回next PC并请求lookup，固定branch可生成goto_tb候选，exception路径已由helper退出，no-return不应再追加普通出口。新增指令若会改变翻译状态，却忘记设置停止类型，后续指令会按旧context生成，这类bug往往跨多条指令才表现。

2026 年提交 [`2578f3b68b`](https://gitlab.com/qemu-project/qemu/-/commit/2578f3b68b) 为 `translator_loop` 增加当前address type参数，提交说明说新的 `TCG_ADDRESS_BITS`机制允许指定地址类型。上游事实表明，公共translator仍在适应target地址表示；作者推断，目标与公共循环的接口应携带语义明确的结构，不依赖编译期全局宏暗传。

## 生成并发布 TB 的并发窗口

MTTCG下两个vCPU可能在同一key同时miss。若翻译全程持全局锁，启动阶段多核会串行；若完全不协调，两个线程可能发布重复TB，页面链和代码区也要容忍。QEMU把代码区分配、生成、页面锁和哈希发布分成若干临界区，允许大部分翻译并行，再在必要位置验证。

重复TB不一定破坏正确性，两份宿主代码表达同一语义即可，代价是缓存空间。危险的是发布未初始化对象：lookup线程看见TB指针时，host code、page relation和jump元数据必须全部可见。锁释放、RCU发布或原子store承担内存序，不能仅依赖结构写入在源码中排在前面。

翻译期间客户机代码页还可能被另一vCPU写。生成器取到前半指令后页面变化，最终TB混合新旧字节会出错。page lock与代码写保护协议要么阻止并发修改，要么在发布前检测变化并重试。精确SMC支持程度由target和执行模式决定，不能把单线程下“翻译很快”当作同步。

`TCGCPUOps.precise_smc` 从旧编译宏演进而来。提交 [`77ad412b32`](https://gitlab.com/qemu-project/qemu/-/commit/77ad412b32) 把 `TARGET_HAS_PRECISE_SMC` 转为运行接口，让能力跟CPU ops关联。上游事实是编译期target开关被对象化，作者推断其收益包括同一构建中更清晰地区分CPU行为，并减少公共代码读取target宏。

## region 分配要服务多翻译线程

`tcg/region.c` 将JIT buffer划成region，翻译线程从自己的区域顺序分配，减少对单一全局指针争用。每个TB大小生成前不完全已知，后端若越过边界要检测overflow，丢弃未完成结果并换区或请求flush。区域尾部碎片是降低锁竞争付出的空间成本。

代码地址还受宿主branch和helper调用范围限制。region不能任意散落到进程地址空间，否则RISC-V64 host的某些跳转需要更长序列，direct chaining补丁也复杂。TCG prologue、helper trampoline和TB区布局共同保证可达，后端通过relocation选择序列。

split W^X环境中，翻译线程写RW view，执行线程跳RX view，同一逻辑位置地址不同。TB元数据通常保存执行地址，补丁函数要转换到可写视图。失效或direct jump修改若用错视图，轻则权限fault，重则改到错误内存。上一章提到的JIT写权限提交正发生在这条边界。

容量耗尽时全局flush比扩展无限内存更可控。flush必须等待正在生成或执行的线程到安全点，重置region，再让热代码逐步重建。trace `tb_flush`与buffer overflow可以判断容量事件是否频繁；直接把buffer放大只能改变发生时机，不会修复异常增长的TB或失效风暴。

## lookup 命中后为什么还要验证

每vCPU jump cache按PC低位快速定位，槽位可能保留旧address space或旧flags的TB。命中候选后比较完整 `TCGTBCPUState`，不一致则走共享lookup。这个模式把常见局部性压成少量load，同时允许key继续扩展。

共享表中的TB还可能正被失效。RCU读侧保护对象生命周期，状态位或页面锁保证不会把已经撤销的对象重新链入。lookup返回指针不代表可以永久保存，执行入口只在规定读侧区间有效。调试代码把TB指针缓存到下一次事件循环，容易形成use-after-free。

物理映射也要验证。相同virtual PC经过页表切换可指向另一代码页，TB key与代码物理页关系共同防止复用旧字节。TLB flush处理virtual translation缓存，TB lookup仍需确保当前代码地址对应关联页面。两套缓存各有职责，任何一套缺失效都可能运行旧代码。

jump cache flush通常随相关TLB或全局状态变化进行。过度保留不会直接执行错误TB，因为完整比较会拒绝，却会增加冲突和慢lookup；漏掉某个比较字段才是正确性问题。性能和安全检查要分开判断。

## direct jump 补丁的前后关系

TB A初次执行时，出口尚不知道目标host address，先返回lookup；找到TB B后，`tb_add_jump()`在A的指定出口写入跳转，并在B的incoming list登记A。以后A可直达B。登记入边与修改宿主代码必须形成一致顺序，否则B失效时找不到已经指向它的A。

失效B时，先阻止新链接，遍历incoming解除A的补丁，再从哈希与page list移除，最后等待读者后回收。顺序若反，A仍可能跳进已复用的代码区。self-link修复 `03fe665980` 表明A与B可以是同一TB，遍历和删除不能假设两个节点不同。

宿主补丁通常需要原子或受锁保护，并刷新I-cache。RISC-V64 host固定32位指令有利于原子替换某些位置，长跳转可能涉及多条指令，后端会预留安全patch形式。读者不要从“同样是RISC-V”推断直接写一个 `jal` 一定足够，距离和W^X仍决定实现。

退出请求不一定逐条解除所有链接。生成代码检查全局/CPU请求后可从链中退出，保留链接供恢复后复用；只有改变代码或翻译条件时才需要unlink或flush。把管理pause实现为全局TB flush功能可行，却会产生巨大无谓重翻译。

## 自修改代码的两种观察粒度

客户机正常store走SoftMMU，entry若标记代码保护，会进入slow path并调用TB失效；DMA设备写RAM也可能修改代码，MemoryRegion写路径必须通知；调试器直接写guest memory同样要走适当API。只在CPU store helper插失效，会漏掉设备和管理入口。

精确失效按物理范围找重叠TB，保留同页未覆盖块。页粒度保护仍可能让第一次写进入slow path，再用range缩小受害者。范围计算要考虑写跨页、地址wrap和TB跨页。客户机一次宽store若只失效首字节所属页，第二页旧TB可能继续执行。

某些客户机按规范必须执行 `fence.i` 才保证本hart看见先前写。QEMU仍不能允许宿主内存安全错误，但可以按target策略延迟某些可见性。实验要区分“QEMU检测物理代码变化”和“RISC-V软件完成指令同步”，两者共同决定何时运行新指令。

DMA自修改还涉及设备完成与CPU fence顺序。设备把新代码写入RAM，驱动等待完成，再执行 `fence.i`；若设备模型异步任务尚未发布内存，CPU fence无法凭空等待。这里连接设备、MemoryRegion和TCG invalidation，适合在后续virtio章节做综合实验。

## 页面数据结构为何从链表演进

一个物理页可能关联许多TB，失效给定地址范围要找所有重叠对象。简单链表易实现，代码密集或跨页块多时扫描成本高。当前维护代码使用适合范围查询的数据结构和page collection，一边缩小失效，一边按稳定顺序加锁。

2025 年提交 [`b94cca31a7`](https://gitlab.com/qemu-project/qemu/-/commit/b94cca31a7) 移除 `invalidate_phys_page_range` 中已经无效的 `mmap_unlock()`，提交说明回溯到采用interval tree的旧提交。邮件 [`20250924164824.51971-1-philmd@linaro.org`](https://lore.kernel.org/qemu-devel/20250924164824.51971-1-philmd@linaro.org/) 说明数据结构演进还会留下过期锁操作，后续清理需要理解历史前提。

page collection先收集涉及页面再排序锁定，避免两个线程按不同顺序锁多页而死锁。跨两页TB让集合有重叠，去重也很重要。这里的复杂度来自并行精确失效，若只看单页单线程用例，会觉得代码过度设计。

作者推断，interval tree的价值不能只用查找复杂度概括，它还让“失效范围”成为显式对象，便于和page locks一起证明。具体性能仍需trace，不应假定树在任何工作负载都比小链表快。

## 用启动阶段解释冷、热与失效

RISC-V `virt` 刚复位时，OpenSBI、引导加载器和内核解压路径大量只执行一次，TB生成占比高；进入内核idle和常用系统调用后，热点稳定，lookup与chaining收益增大；装载模块、设置断点或JIT workload又会提高失效。一次完整启动的平均数字会把这些阶段混合。

分析性能应按时间窗统计：冷启动记录generated TB数量和翻译字节，稳定循环记录lookup hit与direct jump，全局flush前后记录重建坡度，自修改阶段记录每次写影响TB数。这样才能判断优化作用在哪个阶段。

大TB不总是适合冷启动，生成更多未执行分支会拖慢；小TB在热循环中分派多。TCG使用同一基本策略覆盖多样负载，依靠chaining和缓存获得稳健结果，不针对单一benchmark做昂贵profile重编译。作者据此把它描述为“面向通用模拟的在线编译器”，而非追求峰值JIT。

## 稀有故障如何建立最小复现

若看到随机illegal instruction，先保存客户机代码页和TB `in_asm`，确认生成时字节；再检查是否有CPU、DMA或debug写，核对失效trace；最后看跨页和direct link。不要一开始怀疑decodetree，因为译码正确也可能执行了旧TB。

若只在MTTCG崩溃，尝试固定两个hart，一个循环执行，另一个以受控序列修改并fence；关闭chaining、限制TB一条指令、切single-thread分别缩小范围。这些开关会改变时序，不能作为最终修复，只用于定位lookup、link、SMC或内存序层。

若性能周期性下降，对齐 `tb_flush` trace、region overflow和客户机行为。全局flush可能由代码缓存满、插件配置或显式管理动作触发；局部失效风暴则有不同计数。将“重新翻译很多”细分为容量、条件变化和代码写，方案才不会只加大缓存掩盖问题。

## 用一次特权切换验证 TB 身份

准备一段在相同虚拟PC执行的代码，先由S-mode运行，再让hypervisor以VS-mode映射同一物理页运行。字节完全相同，CSR访问、地址转换和某些异常语义不同。日志应显示两份不同flags的TB，或至少在lookup中拒绝跨状态复用。若强行复用后仍通过纯加法测试，不代表正确，加入CSR或fault才会暴露。

随后只改变一个不影响翻译的普通GPR，再回到同PC。应命中原TB，证明运行数据未进入key。这个正反对照比只打印flags更有说服力：一项状态变化必须分块，一项不相关状态变化必须保持复用。

再执行改变端序、地址模式或控制流保护状态的CSR写，观察当前TB在哪里结束。若写后下一条仍在同一翻译块中，检查translator是否更新context或生成运行时分支；不能从“同一TB”直接判错，但实现必须给出正确依据。

最后恢复原状态，旧TB若未被全局flush，可以再次命中。这说明key允许多版本共存，状态切换不等于代码失效；只有代码字节或全局生成条件变化才需撤销对象。区分“切换选择另一份缓存”和“旧缓存内容已错误”能减少不必要flush。

## 插件插桩怎样参与 TB 生成

TCG plugin在翻译时收到指令和内存访问事件，登记运行时callback，生成代码插入调用或inline操作。已有未插桩TB不能自动拥有新callback，plugin通常在启动时固定，动态条件变化要通过flush/cflags管理。插桩位置还要保留精确RISC-V指令身份。

每指令callback会限制优化或增加helper调用，每TB callback开销较低、粒度粗。插件作者应按问题选择，不为统计一次TB执行而插每条指令。内存callback需区分RAM与MMIO、load/store宽度和fault，callback在访问前还是后也影响可观察状态。

插件不能持有TB内部指针超出生命周期，失效后元数据可能回收。公开plugin API提供稳定handle或回调阶段，内部 `TranslationBlock *`不属于永久对象。MTTCG callback还会并发运行，插件自己的计数器与输出必须线程安全。

实验开启plugin后，应重新统计TB生成和宿主代码，不能把无plugin缓存结果拿来解释。性能报告把plugin开关列为执行配置，和icount、single-step一样会改变代码形状。

## user-mode 与 system-mode 的 TB 相同处和差异处

两种模式都使用TCG IR、TB缓存、lookup与宿主后端，RISC-V译码可大量共享。system-mode访存通过SoftMMU和machine MemoryRegion，user-mode依赖宿主进程地址映射与signal转换；page lock、SMC保护和异常入口因此有不同实现。

`translate-all.c`、`tb-maint.c` 等文件在当前构建中可能按模式编译两次，条件代码选择所需头文件。2025 年提交 [`b5dee28732`](https://gitlab.com/qemu-project/qemu/-/commit/b5dee28732) 让 `translate-all.c` 双构建，提交说明着重删除大量未使用头文件。这类重构减少目标宏渗透，让共同算法在两种模式复用。

本书实验统一system emulation，因为后面要连接RISC-V `virt`、H扩展和设备。阅读公共TB历史时仍会看到user-mode修复，不能简单忽略；它们可能改变exit request、代码页保护和host signal等共享部分。引用时说明适用模式。

user-mode客户机 `fence.i` 与host进程写可执行映射的关系也不同，没有machine DMA；system-mode还需设备写通知。一个SMC补丁只在linux-user测试通过，不足以证明system DMA路径。

## TB 统计要区分对象数和执行数

生成一万个TB并不等于执行一万次。冷启动可能对象多、每个一次，热循环对象少、执行数巨大。代码缓存压力看生成字节和存活对象，分派成本看执行边，失效成本看受害对象与入边，不能用单一“TB count”。

direct chaining命中数也要有分母。固定branch大量执行适合链接，间接jump、exception或频繁request天然较少。看到链接率低，先按出口类型分组，再判断是否优化空间。为了提高比例把间接目标错误固定，属于用指标破坏语义。

失效统计分局部与全局，局部再记录写范围、跨页与incoming数量。一次全局flush清十万TB和一千次各清一个，对总删除数相同，重建时间形状不同。trace timestamp与客户机阶段帮助区分。

代码大小使用host bytes，不只IR op数。RISC-V64大立即数和slow path会让相同op不同长度；plugin callback和debug exit也占空间。region碎片单独统计，不能全归TB有效代码。

## TB 相关测试分成五类

第一类验证身份，同PC不同privilege、V状态和地址映射；第二类验证边界，branch、页尾、单步、icount；第三类验证链接，两个固定块、自环、target失效；第四类验证代码变化，CPU store、DMA、debug写和跨页；第五类验证并发，两vCPU同时翻译、执行与失效。

每类都要有正向复用。若测试只期待失效，最保守的“每次全flush”也会通过，却掩盖性能退化。身份测试既要拒绝错误key，也要在相同key命中；局部写既要删重叠TB，也要保留无关页。

故障注入可以缩小稀有路径：限制JIT region触发overflow，构造self-loop触发自链接，控制页布局触发双页，barrier让两线程在发布窗口相遇。随机压力随后补覆盖，不能替代确定性用例。

结果oracle优先客户机状态和trace协议。host代码地址受ASLR变化，不适合作固定golden；日志文本也可能重排。比较PC范围、exit reason和生成/失效关系更稳定。

## 沿提交历史追一个 API 的方法

从当前 `tb_gen_code(CPUState *, TCGTBCPUState)` 开始，用 `git log -S'TCGTBCPUState'` 找引入，再读 `4759aae432`、`c37f8978d9`、`18a77386f1` 的顺序。第一条组合返回值，第二条移入TCGCPUOps，第三条贯穿生成参数，系列逐步缩短旧接口寿命。

对每条提交记录行为是否改变。结构体替代输出指针主要是接口整理，移动hook改变所有者，传结构减少重新读取；若测试结果相同，仍有维护价值。不要把所有重构包装成性能提升，上游没有测量就不写百分比。

再到邮件按Message-ID找v1，检查是否曾包含更多字段或不同命名。reviewer可能要求拆patch，最终Git历史的三步就是审查产物。作者可推断“避免PC与flags不同步”，但若邮件没明确说，必须标成推断。

最后在正式tag重新跑 `git range-diff` 或rc0到release diff。TB代码在候选期仍可能修复，书中固定hash和实验结果一起更新，不只改版本字符串。

## 阅读复核：一份 TB 档案应包含什么

为实验中的任意TB建立档案，至少保存客户机起始PC、物理代码页、`TCGTBCPUState`、客户机指令数、host code范围、两个exit、incoming/outgoing link、生成原因和最终失效原因。只有 `in_asm` 没有key，无法解释重复生成；只有host地址没有物理页，无法解释自修改。

档案还要记录运行配置：CPU型号、accelerator、icount、single-step、plugin与日志选项。它们会改变cflags或边界，同一PC出现不同TB不一定是缓存错误。QEMU commit必须固定，因为内部结构和日志格式会演进。

对一次正常生命周期，未命中生成、发布、第一次执行、链接、重复执行、局部失效、重新生成应形成闭环。对一次全局flush，说明触发者和exclusive/queued前置条件；对代码写，说明CPU、DMA或debug来源与 `fence.i`。遗漏触发者，只看到 `tb_gen_code`再次出现，结论仍不完整。

并发用例再加读者时序：vCPU A执行，vCPU B修改，谁取得page lock，何时unlink，旧TB何时允许回收。trace不能直接证明内存序，源码锁和RCU合同提供因果；实验只验证现象。把证据类型标在图上，避免用timestamp替代同步证明。

最后做一个反事实检查：如果每次都全局flush，功能是否仍通过。若答案是，当前测试只覆盖正确性，没有证明精确失效；加入无关热页，断言它不被重生成。反过来，若从不flush仍通过，测试可能一直没有重新进入修改地址。正反条件都具备，TB实验才真正约束实现。

## 何时不应该直接链接

固定branch目标也可能因当前执行策略禁止chaining，例如单步、插件要求回调、icount预算、跨page特殊状态或退出请求。后端能编码jump，不代表执行循环允许。链接决定由公共条件和TB cflags共同控制，target translator不应擅自patch。

间接jump若运行时目标高度稳定，可以利用jump cache，仍需每次验证key；把最近目标永久改成direct edge，会在寄存器目标变化时执行错误。性能优化应保留guard和fallback，并测mispredict workload。

链接跨越的两个TB必须属于兼容执行上下文。相同PC不同flags、不同address space或不同CPU环境不能互链。incoming list的对象关系保证失效，身份验证保证语义。任意一项为了省比较而放宽，都要给出严密证明。

因此direct chaining的收益来自“已证明稳定的局部控制流”，不是一般控制流优化。理解这个限定，能够解释为何QEMU宁可保留通用lookup，也不把所有TB预先拼成大函数。

发布版本复核还要关注默认代码缓存、TB最大长度和host page配置。它们属于运行参数或构建条件，可能改变实验数量，不应写成架构常数。书中固定的是TB身份、发布、链接和失效协议，具体阈值由 `v11.1.0` 源码与命令输出给出。

若正式tag只调整阈值，正文原理不必重写，实验结果和表格要更新；若改变key或失效锁域，则重新检查本章推断。这种区分能让版本升级工作集中在真实设计变化上。

最后保留一份未开启日志的基线。日志、插件和单步都可能迫使TB重新生成或改变边界，只有基线能说明正常执行策略；诊断配置负责解释，基线负责比较。两者使用相同客户机镜像与CPU属性，原始命令随实验结果入库。若两次构建编译选项不同，先消除构建差异，再讨论TB设计。

基线还应记录生成TB总数、局部与全局失效数、代码缓存高水位。没有这些数，后续版本即使输出相同，也无法判断是更好复用，还是用更大缓存掩盖重复翻译。

## 当前源码该怎样读

从 [`include/exec/translation-block.h`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/include/exec/translation-block.h) 看 TB 对外结构，再到 `accel/tcg/cpu-exec.c` 找 `tb_lookup()` 和执行返回，到 [`accel/tcg/translate-all.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/tcg/translate-all.c) 看 `tb_gen_code()`。生成完成后的维护逻辑位于 `accel/tcg/tb-maint.c`，代码区分配在 `tcg/region.c`，RISC-V 目标边界则落到 `target/riscv/tcg/translate.c`。

阅读时每次只追一条状态。追 PC，就看 `TCGTBCPUState` 如何产生、进入 key、传入 translator；追物理页，就看取代码地址、page add、写入失效；追宿主代码，就看 region 分配、后端输出、direct jump patch；追退出，则从 TB return 反向走到 `cpu_exec()`。一次把所有调用展开，会淹没真正的协议。

::: {.source-path}
固定研究锚为 QEMU `v11.1.0-rc0`，commit `eca2c16212ef9dcb0871de39bb9d1c2efebe76be`。主要入口：`accel/tcg/cpu-exec.c`、`accel/tcg/translate-all.c`、`accel/tcg/tb-maint.c`、`accel/tcg/tb-jmp-cache.c`、`include/exec/translation-block.h`、`tcg/region.c`、`target/riscv/tcg/translate.c`。历史重点检查 TB state 接口、flush 前置条件、direct jump 和 JIT 写保护的演进。
:::

## 实验：观察 TB 生命周期

::: {.hands-on}
实验名称：`observe-tb-lifecycle`。按照英文手册 [`observe-tb-lifecycle`](../experiments/part-02-tcg-execution-engine/chapter-07-translation-blocks/observe-tb-lifecycle/README.md)，编写只使用 RISC-V 整数指令的短循环，在 `riscv64` system emulation 上用 `-accel tcg -d in_asm,op,out_asm` 运行。记录每个 TB 的起始 PC、客户机指令数、两个可能出口、第一次生成时间点和后续复用。再打开单步或 icount，比较 TB 边界与 direct chaining 是否变化。报告必须保存 QEMU 完整命令、目标 commit 和原始日志，图中不要用猜测补齐未观察到的跳转。
:::

实验的关键不是收集尽可能大的日志。给循环设置明确地址范围，用 `-D` 写入单独文件，只截取初始化后的一小段。`in_asm` 证明客户机块，`op` 展示 IR，`out_asm` 展示宿主输出，三者时间点不同；一次出现三种内容，不代表每轮都重新生成。可以在循环计数很大时检查日志是否仍只记录首次翻译，从而验证缓存复用。

## 实验：触发精确 TB 失效

::: {.hands-on}
实验名称：`trigger-tb-invalidation`。按照英文手册 [`trigger-tb-invalidation`](../experiments/part-02-tcg-execution-engine/chapter-07-translation-blocks/trigger-tb-invalidation/README.md)，准备一页可执行 RISC-V 代码，先反复调用使 TB 变热，再通过客户机写路径替换其中一条等长指令，执行必要的 `fence.i` 后重新进入。使用 TCG trace 或受控调试点记录代码页写入、`tb_invalidate_phys_page_range`、链接解除和 `tb_gen_code()` 重建。附加用例把一条 32 位指令放到页尾，修改第二页，验证跨页 TB 同样失效。
:::

自修改程序若忘记客户机规范要求的 `fence.i`，结果可能依赖实现时机，不能据此判定 QEMU 错误。实验要分别保留“符合规范”和“故意省略同步”的用例，前者作为正确性验证，后者只用来说明为什么客户机也参与指令一致性协议。MTTCG 扩展用例还应让另一 vCPU 执行该页，检查失效是否跨线程传播。

## 证据边界与工程判断

本章的源码事实包括 TB key 不止 PC、`tb_gen_code()` 发布宿主代码、物理页维护反向关系，以及 queue flush 和 exclusive flush 在当前树中分开。提交正文明确说了结构体返回、JIT 写权限和 trace 的直接动机，这些属于上游陈述。至于“TB state 结构体也是防止时间不一致的接口”“长函数名承担并发文档”，是作者结合演进做出的解释。

做性能判断时也要守住边界。direct chaining 减少分派是机制事实，它在某个工作负载上能提升多少，需要实验；全局 flush 会丢缓存是必然影响，某次抖动是否由它导致，需要 trace 对齐；TB 越大不一定越快，因为翻译延迟、代码局部性和中断响应同时变化。书中给出设计方向，不用未经测量的百分比装饰结论。

## 小结

TB 是动态翻译的缓存单位，也是控制流链接、异常回溯和代码一致性共同使用的对象。PC 与翻译相关状态构成身份，目标 translator 与公共循环共同决定边界，生成代码进入受宿主权限约束的缓存，物理页面关系又保证自修改代码可以找回并撤销旧结果。

理解这一整套生命周期后，下一章的 decodetree 就不会只是语法工具。每一条 RISC-V 指令的译码与语义，最终都要在 TB 的状态、边界和精确退出约束里落地。
