# 为什么 TCG 的优化保持收敛

同一段 RV64 循环，第一次进入时要译码、生成 IR、优化、分配寄存器并发射宿主代码；第二次进入才直接命中 TB。若只看热循环，给 TCG 再加几轮优化似乎总有收益。换到固件启动、短命进程、动态装载或频繁失效的代码，前一轮多花的时间可能还没收回，TB 已经被淘汰。

TCG 优化器的边界由这笔账决定。它要清理前端机械生成的冗余，给后端提供合适的代码形状，同时把翻译时延、内存占用、精确异常和跨宿主维护成本压在可控范围内。这里的“收敛”是一组可检查的工程条件，不是缺少优化能力。

## 翻译成本发生在客户机等待的路径上

提前编译器可以为一个函数运行多轮全局分析，因为成本在发布或安装时支付。TCG 遇到新 PC 才生成 TB，vCPU 此刻没有别的宿主代码可执行。optimizer 每扫描一次 op、每建立一张数据流表，都会延长冷路径；QEMU 又无法预先知道这个 TB 将运行一次还是一百万次。

TB 的寿命也不稳定。客户机可能修改代码并执行 `fence.i`，调试器会插入断点，plugin 配置改变会 flush，代码缓存耗尽也会让已有翻译失效。一次昂贵优化只有在后续执行节省的时间超过生成成本时才回本。动态翻译面对的是概率分布，不能只为最热的一端设计。

RISC-V `virt` 启动能看到两种相反区域。固件和内核的初始化代码大量只跑一次，翻译速度更敏感；调度、内存拷贝和锁循环会反复命中，宿主代码质量更敏感。TCG 没有在首次翻译时可靠预测未来热度的完整 profile，因此采用低固定成本的通用优化，再把长期收益交给 TB 缓存与直接链接。

这也解释了性能评测为何要同时报告 translation 与 execution。只跑预热后的循环会隐藏优化器开销，只测总启动时间又可能淹没热代码收益。实验至少要保存生成 TB 数、IR op 数、宿主代码大小和运行阶段，才能知道变化发生在哪一边。

:::: {.quick-quiz}
一个优化让 RV64 热循环快 3%，是否足以说明它应该进入 TCG？

::: {.quick-answer}
还不够。需要同时测首次翻译时延、生成代码大小、不同 TB 长度、一次性启动路径、多个 host backend 和正确性矩阵。若分析成本高于短命 TB 的收益，或只让单一宿主受益，通用层未必适合承担它。
:::
::::

## 初始设计已经划出优化半径

2008 年初始 `tcg/README` 承诺的优化很有限：单指令化简、basic block 级 liveness、删除死 move 和死结果。文档还直说，如果 TCG 做更昂贵的优化，某些 macro 机制才会减少价值。几个月后的提交 [`0a6b7b7813`](https://gitlab.com/qemu-project/qemu/-/commit/0a6b7b7813799f76e1859387688611af05db376c) 更新 README，删除未继续采用的 macro 描述，加入“best performance”编码规则。

这次历史转折只需要保留一个判断：维护者没有把 IR 出现理解成“复制一套传统优化编译器”。前端应主动选择 globals、temporaries 和 helper，IR 层做便宜且高命中的清理。复杂或低频客户机指令进入 helper，让宿主 C 编译器在构建阶段优化那段逻辑。

当前 [`docs/devel/tcg-ops.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/devel/tcg-ops.rst) 仍保留这条建议：复杂或少用的 guest instruction 可以放心使用 helper；一条指令展开超过大约二十个 TCG op 时，内联优势往往有限。文档也补充了适用边界——复杂逻辑或算术更适合 helper，包含许多 load/store 的情况未必，因为 helper 会引入状态同步和调用开销。

“二十”应当当作经验线索，不能写成硬阈值。某段 IR 只有十几个 op，若每个都形成宽向量或昂贵 slow path，成本仍高；另一段超过二十个纯整数 op，若处于极热路径且后端能很好组合，也可能值得内联。patch 需要用具体 workload、host code 与翻译时间说明选择。

## 当前优化管线具体做了什么

在 `v11.1.0-rc0` 的 [`tcg_gen_code()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/tcg/tcg.c) 中，前端完成 op 序列后依次进入 `tcg_optimize()`、reachable code pass、几轮 liveness，再开始寄存器分配和后端发射。若后续 liveness 变换了 IR，代码会重新运行相关分析。顺序体现了一条朴素关系：先让 op 变简单，再删除不可达和死亡结果，最后为仍活着的值分配稀缺宿主寄存器。

[`tcg/optimize.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/tcg/optimize.c) 维护常量、copy relation、已知为零/一的 bit mask 和有限的 memory copy 信息。它能做常量折叠、复制传播、代数恒等化简、条件恒定化、部分位级推理和相邻操作组合。比如 `x + 0` 可以退化成 copy，常量比较可以直接得到真假，连续 mask 在已知位信息足够时可以收缩。

reachable pass 删除已经证明走不到的 IR 区域；liveness 从出口向前判断 temp 最后一次使用，删除没有副作用且结果死亡的 op，并决定哪些 global 在 basic block、helper 或 TB 出口前必须同步。优化与 liveness 分开，使前者聚焦值关系，后者聚焦生命周期和状态提交。

它没有为客户机函数建立跨 TB 的 SSA 图，也不在首次执行时做完整循环优化。TB 可能因状态 key、页边界、异常和异步退出被切开，跨 TB 关系还会被代码失效与直接链接打断。构建全局图需要更高成本，也会让精确状态映射复杂得多。

TB 内的 IR 也常比源程序函数短得多。一个 RV64 branch、可能改变 privilege 的 CSR 或页边界都可结束翻译，优化器实际看到的是动态执行单位，未必对应编译器眼中的函数或循环。用传统编译器 benchmark推断 pass 收益前，应先统计 QEMU 中真实 TB 的 op 数分布；只在人工构造的长块上有效，落到系统启动可能没有施展空间。

:::: {.quick-quiz}
为什么 `lw x0,0(a0)` 的结果死亡，liveness 仍不能删除它？

::: {.quick-answer}
`qemu_ld` 可能访问 MMIO、触发页表或 PMP fault，也受 watchpoint 和内存序影响。目的寄存器没有活跃值，只能删除最终写回；访存 op 带有客户机可见副作用，必须保留。
:::
::::

## RISC-V 前端要给优化器可证明的形状

optimizer 只能利用 IR 中显式的信息。RV64 `addi` 使用 `tcg_gen_addi_tl()`，立即数作为翻译期常量进入，后续才有机会折叠加零或与相邻计算合并。若前端把简单加法藏进无属性 helper，通用层只看见一次未知调用，无法传播常量，也要保守同步 globals。

反过来，前端不能为了“让 IR 看起来多”而内联所有语义。RISC-V CSR 访问会检查 privilege、扩展、只读位和 side effect；向量指令可能按 `vl` 循环处理元素；地址转换 fence 要完成权限检查和当前 hart 的 TLB 失效，跨 hart shootdown 还需要客户机软件的通知与确认协议。把这些都展开为大量分支和 load/store，会增加翻译时延与代码缓存，也可能在异常恢复点漏掉状态。

一条指令适合 TCG op 还是 helper，可以按执行频率、IR 长度、异常复杂度、状态可见性和后端覆盖来判断。基础整数、branch、普通 load/store 通常值得直接生成；罕见特权操作、复杂浮点 corner case 和大段向量循环更常进入 helper。实际源码会随后端能力与测试结果调整，不能把分类写成 ISA 固有属性。

前端还可以通过 helper flag 给优化器更多事实。函数只读 globals、不会写 CPU state，就准确声明 `NO_WRITE_GLOBALS`；纯函数且不会异常，才考虑 `NO_SIDE_EFFECTS`。声明的强度必须由完整函数体和间接调用证明。性能 patch 若只改 flag，review 重点应放在异常、MMIO、日志与隐藏 CSR 读取，而非代码行数。

RISC-V 的 x0 提供了好测试。`addi x0,a0,1` 可以删除计算及写回，因为纯算术无可见结果；`lw x0,0(a0)` 保留 load；`csrrw x0,csr,a0` 仍可能写 CSR；AMO 写 x0 仍修改内存。四个用例把“结果死亡”与“操作无副作用”清楚分开。

## 寄存器分配为何更需要短而准确的 IR

优化后的 IR 还不是宿主代码。`tcg_reg_alloc_*` 根据 temp 生命周期、op constraint、调用约定和后端寄存器集合选择位置。值在寄存器中能减少 memory traffic；寄存器不足时要 spill 到临时区，之后 reload。helper call 会破坏 call-clobbered register，跨调用活跃值需要移动或保存。

RISC-V64 host backend 在 `tcg_target_reg_alloc_order` 中提供分配偏好，在 constraint 文件中声明某个输入能使用哪些寄存器、是否接受立即数、输出能否与输入重合。普通 RV64 guest `addi` 若常量落在宿主 12 位有符号范围，后端可直接发射；超出范围时先 materialize，额外临时值会加重寄存器压力。

前端产生冗余 temporary，会在分配前放大活跃集合。copy propagation 与 liveness 因而是高收益优化：它们成本有限，却能少一次 move、少一个 spill，效果覆盖所有 guest 与 host。相较之下，针对一种复杂表达式的全局重排可能只改善少量 TB，还要在每个后端验证。

RISC-V guest 与 RISC-V64 host 同架构时也不会跳过这层。客户机寄存器是 `CPURISCVState` 中的模拟状态，宿主 ABI 规定 QEMU 自身可用哪些物理寄存器；客户机 a0 不会永久绑定宿主 a0。helper、signal、SoftMMU 和调试都要求清楚的状态归属。

:::: {.quick-quiz}
为什么减少一条 IR op 不一定减少一条宿主指令？

::: {.quick-answer}
后端可能把多个 IR op 合并成一条指令，也可能把一个 op 展开成常量构造、主操作和辅助 move。constraint、寄存器压力、helper ABI 与宿主扩展都会改变结果。评审需要同时查看优化后 IR 和实际 host code。
:::
::::

## 精确异常限制代码移动

传统优化器常把相互独立的指令重排，以隐藏延迟或扩大公共子表达式。TCG 面对的“独立”还要包含客户机异常顺序。两次 RV64 load 都可能 fault，规范要求先执行的指令先被观察；一次 MMIO read 可能改变设备状态，也不能随意与另一访问交换。

RISC-V translator 在可能异常的 op 前保存当前 PC 信息，生成代码的 host offset 又与客户机 instruction boundary 对应。optimizer 若跨边界移动可异常 op，`cpu_restore_state()` 可能恢复到错误指令。当前 TCG 把有副作用的 load/store、helper、barrier 和 exit 当作强边界，大量变换停留在 basic block 内的纯值关系。

TB key 中还记录翻译期间假定不变的 CPU state，例如 privilege、XLEN、虚拟化和扩展相关 flags。状态改变后要结束块或让旧 TB 不再命中。跨 TB 常量传播若忽略 key，会把某个 privilege 下的结论带到另一状态；如果把所有状态都塞进全局分析，又会增加缓存身份与失效复杂度。

self-modifying code 带来另一层期限。客户机修改指令页后，旧宿主代码和任何基于旧指令的优化都要失效。优化范围留在 TB 内，使 page→TB 反向关联能够回收完整结果；跨多个 TB 共享优化产物会让失效图更复杂。这里的克制也在降低一致性成本。

## 代数恒等式要先通过机器语义

编写 optimizer 很容易从纸面公式出发，例如 `x / x = 1`、连续 shift 可以相加、两个窄 load 可以合成宽 load。TCG op 对除零、溢出、shift 超宽和 memory access 都有明确的 undefined 或 unspecified 条件，RISC-V guest 又规定自己的 trap 与结果。只有输入范围和副作用都能证明，代数式才可以进入变换。

以 RV64 shift 为例，客户机寄存器形式只取 shift amount 的低若干位，TCG shift op 对等于或超过类型宽度的输入可能有不同合同。前端通常先 mask，再生成 op；optimizer 若把两个 shift 的常量直接相加，必须继续按相同宽度处理。测试要覆盖 0、31、32、63、64 和负数经寄存器截断后的情况，不能只试中间值。

除法更敏感。RISC-V 对除零和最小负数除以 -1 给出规定结果，而宿主 C 或某些机器指令可能 trap 或具有未定义行为。前端、TCG runtime 与 backend需要在进入危险宿主操作前建立 guard。一个常量折叠 pass 也要复现这些规则，不能用宿主语言表达式直接计算全部边界。

内存合并还要考虑 page boundary、MMIO access size、端序、对齐、watchpoint 和 fault 顺序。两次相邻 byte load 落在 RAM 时可能看似能合并，第二次若在下一页 fault，宽 load 会改变第一项访问是否发生；设备还可能为每次读产生不同副作用。TCG 因而把通用 memory optimization 限制在能够证明地址范围与属性的场景。

known-zero/known-one bit mask 是一类低成本证明。它能发现某些 and/or/extract 的结果位恒定，帮助折叠比较或缩短操作，又不必建立完整符号表达式。即便如此，每个 fold handler仍要保持 type width、sign extension 与 vector element size。优化器的代码量增长，主要来自这些边界证明，而非简单罗列恒等式。

:::: {.quick-quiz}
为什么两次相邻的 RV64 byte load 通常不能直接合成一次 halfword load？

::: {.quick-answer}
它们可能跨页、分别触发 fault 或 watchpoint，也可能落在只允许 byte access 的 MMIO，并具有两次可见副作用。只有地址、内存属性、端序和异常顺序都能证明等价时才可合并。
:::
::::

## 代码缓存把“更快”拆成三项指标

更激进的内联通常减少运行时 helper call，却扩大每个 TB。代码缓存容量固定时，平均 TB 变大会更早触发 flush，热代码也可能因 instruction cache 压力变慢。优化器自身的数据结构还占用 QEMU 内存，多个 MTTCG 翻译上下文会放大这部分成本。

因此性能 patch 至少要看翻译时间、生成代码尺寸和稳态执行。三项可能互相冲突。常量折叠往往同时降低 op 数与 host code，是理想收益；把 helper 展开成几十条指令也许提升极热循环，却扩大缓存并拖慢冷路径；复杂分析若只减少少量 move，翻译成本可能主导。

direct chaining 属于另一类优化。它不改 TB 内的运算，而是让已翻译的相邻块减少主循环往返。对于大量短 TB，这项机制可能比跨块 IR 优化更便宜。TCG 选择把性能工作分散在快速 lookup、chaining、software TLB、轻量 optimizer 和后端发射，而非让一个 pass 承担全部收益。

报告代码尺寸时要区分 guest bytes、IR op 数、host bytes 和代码缓存实际占用。RV64 压缩指令让 guest bytes 更少，却不保证 IR 或 host code 同比减少；RISC-V64 host 的大立即数构造又会扩大输出。只报“TB 数下降”也可能隐藏单个 TB 变大。

代码缓存还影响宿主 instruction cache 与分支预测。一个 helper call 让执行离开 JIT region，但 helper 本身是构建期优化好的共享代码；大段内联避免调用，却会在许多 TB 复制相同冷逻辑。对异常罕见的除法 corner case、CSR 权限失败或 vector 尾部处理，共享 helper 常比每块复制更符合 cache 行为。

多线程翻译时，优化器的固定开销也会乘以同时生成 TB 的 vCPU 数。per-vCPU TCG context减少了生成锁争用，allocator、临时表和 optimizer 工作集仍会争夺宿主 cache 与内存带宽。MTTCG workload 的评测要同时观察翻译并发与执行并发，不能把 vCPU throughput 的变化全部归因于宿主代码指令数。

## 一项优化怎样通过上游评审

先给出可复现的低效 IR 和生成代码，说明它来自哪些 RISC-V 指令与前端模式。随后证明变换保持 op 的类型、未定义/未指定行为、异常顺序和 helper 副作用。若新增后端能力，列出支持与 fallback；若改通用 optimizer，运行多 guest、多 host 的 TCG test，而非只验证 RISC-V。

性能证据分层准备。微型用例证明预期代码形状，启动型 workload 测翻译税，热循环测稳态，代码缓存统计观察占用。结果附 QEMU commit、构建选项、host CPU、加速器参数和日志开关。百分比没有这些条件，很难在邮件列表复核。

还应给出未优化基线的代码形状。某项 pass 若只修 RISC-V 前端本可避免的冗余，可能把通用复杂度强加给所有 target；先在 `trans_*` 直接生成更好的 op，diff 更小。只有多个前端会自然产生同一模式、后端又普遍受益，通用 fold 才有充分理由。

还要主动寻找反例：常量边界、shift 等于位宽、符号扩展、i64 在 32 位 host 的拆分、vector fallback、helper 前后活跃 global、MMIO 和 fault。优化器 bug 往往来自“代数上相等，机器语义上有未定义边界”。TCG 文档对每个 op 的 undefined 与 unspecified behavior 描述，就是 review 的合同。

若收益只来自 RISC-V64 host 的一条新指令，优先放在后端 pattern 或 constraint；多个 host 都能受益的恒等变换才适合通用层；只服务某条 RV64 guest 指令且语义复杂，可以留在前端或 helper。把变化放到最窄责任层，验证矩阵也随之缩小。

QEMU 自带的 `tests/tcg/` 提供 guest 语义回归，后端改动还需要 cross-host 构建与运行；optimizer 的 fold 函数适合加入小而穷尽的边界用例，system emulation 再覆盖 SoftMMU 和异常。测试层次与代码层次对应：纯 op 用算术 oracle，guest translator 用 ISA 用例，memory op 用 system/MMIO，MTTCG 用并发 litmus。只在 Linux 启动成功，覆盖面太粗。

## 实验：比较优化前后的 RV64 IR

::: {.hands-on}
使用 [`dump-tcg-ir`](../experiments/part-02-tcg-execution-engine/chapter-09-tcg-ir-and-host-code/dump-tcg-ir/README.md) 的程序，加入三组表达式：`x + 0`、常量条件分支、计算后覆盖的死结果；再加入 `lw x0,0(a0)`、一次 CSR helper 和 memory barrier。通过 `-d op,op_opt,out_asm` 或当前版本对应日志选项保存优化前后 IR。

预期前三组纯计算被折叠或删除，访存、helper 和 barrier 保留。逐项记录 op 数变化与 host bytes，检查客户机 oracle和 fault 用例。若日志选项在版本中名称不同，以 `qemu-system-riscv64 -d help` 输出为准，报告固定 `v11.1.0-rc0`。

然后扩大循环次数，分别测冷启动和预热稳态。不要用打开 `out_asm` 的运行测最终耗时，日志 I/O 会改变结果；诊断运行解释代码形状，无日志基线承担性能比较。
:::

## 实验：让 RISC-V64 后端暴露 constraint

::: {.hands-on}
使用 [`compare-host-code`](../experiments/part-02-tcg-execution-engine/chapter-09-tcg-ir-and-host-code/compare-host-code/README.md)，在 RISC-V64 host 上比较小立即数与大立即数、低寄存器压力与跨 helper 高压力四种组合。保存优化后 IR、分配结果可见日志、最终反汇编、spill/reload 数和代码尺寸。

这项实验验证“通用优化结束后，后端约束仍会改变输出”。小立即数应更容易直接编码，大常量可能产生 materialize；跨 helper 活跃值会受到 ABI clobber 影响。具体寄存器序列随版本和 host feature 变化，正确性 oracle 与 constraint 原理更稳定。

最后做一次层次实验：能在 RISC-V64 backend 局部解决的问题，不改通用 optimizer；再描述若把同一规则放到通用层，需要增加哪些 host 验证。这个练习让“最窄责任层”从审查口号变成可见 diff。
:::

## 小结

TCG 的优化范围由动态翻译场景决定：首次执行正在等待，TB 可能短命，代码缓存有限，异常与访存顺序必须精确，多种 host 还要共享同一套语义。当前管线用常量折叠、复制传播、位信息、可达性和 liveness 清理高频冗余，再把寄存器与指令选择交给后端。

这套边界没有把性能问题留空。TB 缓存、direct chaining、software TLB、helper 选择和后端能力共同承担速度。下一章进入最难压缩的部分：地址转换、异常、自修改代码与多 vCPU 并发怎样反过来规定 TCG 可以生成什么、何时必须停下来。
