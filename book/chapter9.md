# TCG IR、优化与宿主代码生成

上一章的 `trans_addi` 没有直接写出宿主机器码，它先产生 `add`、`movi`、`qemu_ld` 一类 TCG 操作。这样绕一层，是 QEMU 能让同一份 RISC-V 客户机语义运行在不同宿主上的关键。对本书的 RISC-V 主线而言，我们还可以选择一个很有意思的闭环：客户机是 `riscv64`，宿主后端也看 `tcg/riscv64/`。指令集名称相同，TCG 仍不能把客户机指令原样复制，因为两边的虚拟寄存器、地址空间、特权状态和异常环境并不相同。

这一章不把 TCG 当成缩小版通用编译器。它面对的输入很短，生成发生在客户机运行途中，翻译延迟本身就是成本；生成代码还要随时退出、恢复精确 PC、访问 SoftMMU，并能被 TB 失效。有限 IR、轻量优化和约束驱动后端，都是围绕这个运行现场做出的选择。

## 本章目标

- 理解 TCG 临时值、全局值、op、label、basic block 和 helper call；
- 跟踪前端 IR、优化、liveness、寄存器分配、后端发射与 relocation；
- 说明 RISC-V 宿主约束、立即数范围与固定临时寄存器怎样影响代码生成；
- 处理 `qemu_ld/st`、原子操作和客户机内存序；
- 用 IR 与宿主反汇编验证优化，不用单次运行时间代替结构证据。

## 为什么需要一层有限 IR

若 RISC-V 前端直接生成每种宿主机器码，所有指令语义都要按 host 复制。新增一个客户机扩展，需要同时理解多个宿主 ABI、寄存器和立即数编码；修复精确异常，也要在每个后端重复。TCG IR 让 target 前端只表达客户机运算，host 后端只声明如何实现有限 op，组合数量由两者相乘降为相加。

这个接口不会抹平所有差异。某个后端有直接位操作，另一个后端需要两三条指令；有的宿主支持宽原子，有的要 helper；立即数能否嵌入也不同。公共 TCG 通过 capability、constraint 与 lowering 把差异反馈给优化和寄存器分配，前端不必知道具体寄存器编号。

IR 集合有意保持贴近动态翻译需求。它包含整数与向量运算、分支、条件、扩展截断、barrier、客户机内存操作、helper call 和 TB 退出。没有必要完整覆盖源语言类型系统、异常表和链接期优化，因为输入不是 C 程序，生命周期只覆盖一个 TB。能力越广，优化器与每个 host backend 的实现负担也越大。

:::: {.quick-quiz}
TCG IR 为什么不直接复用某个通用编译器 IR？

::: {.quick-answer}
TCG 要在客户机运行途中频繁处理很短的 TB，重视低翻译延迟、精确异常、SoftMMU 内存操作和快速链接。通用编译器 IR 能表达更多语言与全程序优化，管线和运行时成本也更高。QEMU 选择有限 IR，是用较少优化空间换取可预测的在线生成成本与目标语义接口。
:::
::::

## 三类值，不同生命周期

TCG temporary 表示 IR 中间结果。普通 temp 的生命通常局限于一个基本块或 op 区间，优化器和寄存器分配可以自由放在宿主寄存器或 spill slot；local temp 需要跨基本块保持值，生命周期更长，分配更保守。全局值则映射 CPU 环境中的长期字段，例如 RISC-V PC 或通用寄存器的入口，它们在 translator 初始化时建立。

把所有值做成 global 会很方便，前端随时可读写，却迫使生成代码不断把结果同步到 `env`，也让数据流分析看不清局部值。把所有值做成普通 temp 又无法跨分支和 helper 保留。前端应按真实生命周期选择，错误分类可能表现为性能下降，也可能在控制流合并后得到旧值。

常量不需要占宿主寄存器直到真正用到。TCG 可在 IR 中标记 constant，优化器传播并折叠，后端再判断能否作为立即数编码。RISC-V 宿主的 I 型立即数范围有限，一个大常量可能需要 `lui`、`addi` 或多段构造；相同常量在不同 op 的约束也可能不同。保持常量身份到后端，比前端过早生成装载序列更有选择空间。

TCG 类型以 i32、i64、i128、pointer 与向量宽度为主，不等同于客户机 C 类型。RV64 的 `addiw` 可以在 i64 容器中完成低 32 位运算后符号扩展；客户机地址类型也可能与宿主 pointer 宽度不同。类型决定 op 的位宽和后端约束，符号解释常由具体 op 表达，不应把一个 `i64` 自动理解成有符号整数。

## op 链与 label 形成局部控制流

前端按执行顺序追加 `TCGOp`，输入输出引用 temp，branch 指向 label。基本块边界由 label、条件跳转和退出形成。TCG 可以在单个 TB 内表达 RISC-V 条件分支的局部路径，也可以让分支成为 TB 出口。选择取决于目标 translator 与公共策略，IR 不要求每条客户机 branch 都拆成新的宿主函数。

每个 op 带有定义好的副作用。纯整数 `add` 可以交换、折叠或删除未使用结果；`qemu_ld` 可能 fault 或访问 MMIO，不能因输出未使用就随意删除；helper call 的读写集合若不够精确，优化器必须假定它碰触更多状态。优化的安全边界来自 op 语义，不来自函数名看起来是否简单。

`insn_start` 类标记不产生普通计算结果，却保留客户机 PC 与生成位置关系。宿主信号、watchpoint 或 helper 异常需要从当前代码地址恢复 RISC-V 状态，优化器不能把这些标记随意移动到另一条指令后。动态翻译 IR 同时承担计算和可回溯元数据，这点与离线编译常见的 debug info 有相似处，但异常恢复更直接依赖它。

## IR 生成先求正确，再求紧凑

RISC-V 前端最好使用表达语义最直接的 op。例如无符号比较用对应 condition，word 运算显式截断与扩展，访存用带正确 `MemOp` 的 `qemu_ld/st`。不要为了猜测某个宿主的理想序列，在 target 前端手写一串位运算；那会让其他宿主也承担同样展开，并可能阻止公共优化识别模式。

TCG 提供高层生成 helper，例如 deposit、extract、rotate 或条件 move。若 host 不直接支持，lowering 可以展开；若优化器发现常量，又能折成更短序列。2026 年一组提交把 unsupported `deposit`、`extract2` 的 lowering 移到 optimize 阶段，提交 [`5f747705a4`](https://gitlab.com/qemu-project/qemu/-/commit/5f747705a4) 与 [`e4cebfc664`](https://gitlab.com/qemu-project/qemu/-/commit/e4cebfc664) 的说明指出，在较早的 `tcg-op.c` 展开可能不是最优，延后后可以基于更多信息选择形式。

同系列提交 [`bb5b6bbb10`](https://gitlab.com/qemu-project/qemu/-/commit/bb5b6bbb10) 增加 `tcg_op_imm_match`，邮件 [`20260303010833.1115741-6-richard.henderson@linaro.org`](https://lore.kernel.org/qemu-devel/20260303010833.1115741-6-richard.henderson@linaro.org/) 展示了上下文；[`744eb39667`](https://gitlab.com/qemu-project/qemu/-/commit/744eb39667) 据此在 deposit into zero 时比较移位展开。上游事实是 lowering 时机和立即数匹配被集中到 optimizer，作者推断其设计意图是尽量让前端保持语义级 op，让 host capability 与常量信息晚一点共同决策。

## 常量传播不止算出一个数

最直观的 constant folding 是 `3 + 4` 变成 `7`。TCG optimizer 还维护已知为零、已知为一、可能受影响的 bit mask，借此简化 and、or、shift、extract 等操作。RISC-V 位操作扩展会产生大量这类 IR，位级事实能避免不必要的 mask 和扩展。

位信息传播必须非常谨慎。一个 mask 算错，可能只在某一输入位组合出现；简单随机测试也未必覆盖。提交 [`23b53ec3a8`](https://gitlab.com/qemu-project/qemu/-/commit/23b53ec3a8) 修复 affected bits 优化意外未启用的问题，邮件 [`20251223163720.985578-1-pbonzini@redhat.com`](https://lore.kernel.org/qemu-devel/20251223163720.985578-1-pbonzini@redhat.com/) 是上游证据；提交 [`08b12bfb8f`](https://gitlab.com/qemu-project/qemu/-/commit/08b12bfb8f) 又修正 `orc` 的 mask 计算。前者影响优化机会，后者可能影响正确性，二者都说明 bit lattice 是实际实现，不是抽象教材里的无风险公式。

复制传播把 temp 的已知来源沿 op 传递，死代码删除移除无可见用途的纯运算。它们要尊重 basic block、helper clobber 与内存副作用。若一条 RISC-V load 写 x0，结果 temp 没人用，load op仍不能删除；若只是 `addi x0,x0,0`，整条纯计算可以消失。前端给出的 op 副作用标记决定了优化器能否分辨。

提交 [`c9349965ce`](https://gitlab.com/qemu-project/qemu/-/commit/c9349965ce) 为 `mul[us]2` 的 0 和 1 操作数增加优化，邮件 [`20260520125139.13352-3-philmd@linaro.org`](https://lore.kernel.org/qemu-devel/20260520125139.13352-3-philmd@linaro.org/) 可看到审查。提交前一项 [`f7c62771e6`](https://gitlab.com/qemu-project/qemu/-/commit/f7c62771e6) 先整理 `fold_multiply2()`，说明“为下一提交便于 review”而调整检查顺序。把机械重构和行为改变拆开，是上游降低优化器审查风险的常见办法。

## liveness 连接优化与寄存器分配

liveness pass 从使用点反推 temp 是否仍有未来用途，给 op 标记输出死亡与输入最后使用。寄存器分配据此及时释放宿主寄存器，减少 spill；若纯 op 的输出全死，整个 op 可以删除。活跃区间越长，寄存器压力越大，跨 helper 和分支的值尤其昂贵。

死值分析必须知道 global 的同步要求。某个 RISC-V GPR 在 TB 末尾仍是客户机可见状态，即使当前 IR 后面没有显式读取，也可能需要写回环境；而纯临时值离开 TB 后没有意义。TCG 通过 temp kind 与 basic block 规则区分，不是只数 SSA 使用次数。

helper call 形成明显 clobber 点。按宿主 ABI，caller-saved 寄存器会被破坏，仍活跃的值要移到 callee-saved 位置或 spill；作为 helper 参数的值还要放进指定寄存器或栈。频繁小 helper 可能让前后产生很多 move，这也是上一章建议简单语义直接 IR 化的原因。

:::: {.quick-quiz}
为什么寄存器分配错误可能只在某些客户机程序中出现？

::: {.quick-answer}
错误常依赖临时值数量、活跃区间、固定寄存器冲突、helper clobber 与 spill 位置。简单程序寄存器压力低，错误值恰好一直留在安全寄存器；特定指令组合或控制流才会迫使分配器进入有问题的约束路径。因此需要压力测试和多种 IR 形状，不能只跑一条算术用例。
:::
::::

## constraint 是后端给公共层的合同

宿主指令对操作数有具体要求。RISC-V `addi` 的立即数只有一定宽度，shift immediate 有位数限制，某些序列要固定临时寄存器，load/store 地址形式也有限。后端在 constraint 表中描述输出允许哪些寄存器、输入能否是立即数、输入输出是否必须同址，公共寄存器分配器据此安排。

约束写得过窄，会产生多余 move 或常量装载；写得过宽，后端收到无法编码的组合，轻则断言，重则生成错误机器码。问题可能只在常量越界或寄存器压力高时出现。审查一个新 TCG op，需要同时看所有后端约束与 lowering，不能只在开发者宿主上验证。

本书架构例子统一使用 RISC-V。当前宿主后端位于 [`tcg/riscv64/tcg-target.c.inc`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/tcg/riscv64/tcg-target.c.inc)，约束表在同目录生成/声明文件中。即便 guest 与 host 都是 RV64，客户机 `addi` 产生的 IR 常量也未必能用一条宿主 `addi`：客户机值可能先经过虚拟寄存器映射，异常与 PC 更新也会加入额外指令，大立即数仍需展开。

2025 年提交 [`169d253e1f`](https://gitlab.com/qemu-project/qemu/-/commit/169d253e1f) 修复 RISC-V TCG 后端 `tgen_extract` 的移位方向，提交说明指出问题来自转换过程中引入的 typo。这类修复提醒我们，后端短小的位拼接函数承担真实正确性，guest 测试需要覆盖不同 offset、length 和边界位，不应因为 host 与 guest 同架构就假定映射直观。

## 线性扫描为何适合在线生成

复杂图着色寄存器分配可以获得更优结果，却要建立干涉图并迭代，TB 很短时编译成本未必能摊回。TCG 采用面向线性 op 流的快速分配，顺序扫描需求，遇到约束时选择寄存器或 spill。它可能比离线编译器多出几次 move，却把首次执行延迟控制在较小范围。

这项选择要结合 TB 生命周期看。冷代码可能只执行一次，花十倍时间生成最优代码反而更慢；热代码会反复执行，较好的宿主序列更值钱。TCG 没有对每个 TB 做重型 profile-guided 重编译，整体策略偏向稳定、低成本。后端因此会手工优化常见 op，把收益放在局部发射而不是全局迭代。

spill 不等于 bug。宿主寄存器有限，长活跃区间与 helper call 必然会把一些值保存到 TCG frame。问题在于不必要 spill：错误的 temp 生命周期、过窄 constraint、过早 materialize 常量，都可能增加栈访问。实验应比较 IR 与最终宿主代码，找出 spill 来源，而不是看到栈读写就下结论。

## lowering 的位置影响优化机会

某个 op 后端不支持，可以在前端生成时展开，可以在 optimizer 根据 capability 展开，也可以到后端临时发射多条指令。越早展开，通用优化更容易看到细节，却丢失高层语义；越晚展开，前面阶段保持紧凑，但寄存器分配可能不知道隐藏的临时需求。TCG 会按 op 特性选择位置。

2026 年移除只服务 32 位 host 的 `brcond2_i32`、`setcond2_i32` 与 `dup2_vec` 等 op，提交 [`e3601d2cfc`](https://gitlab.com/qemu-project/qemu/-/commit/e3601d2cfc)、[`2f4bf8148f`](https://gitlab.com/qemu-project/qemu/-/commit/2f4bf8148f)、[`6e7b13936d`](https://gitlab.com/qemu-project/qemu/-/commit/6e7b13936d) 展示 IR 集合也会收缩。上游事实是这些 opcode 只为特定 host 位宽存在，当前演进选择通过其他机制覆盖，而非永久保留专用 IR。

作者推断，IR 稳定性服务 QEMU 内部，不是对外 ABI。新增 op 要证明跨 target/host 的长期价值，删除 op则要保证所有后端都有正确 lowering。书中讨论某个 opcode 时必须注明版本，不能把旧版本博客中的 IR 名称视为永久接口。

## `qemu_ld/st` 为什么是特殊操作

宿主普通 load 接收宿主虚拟地址，客户机 load 接收 guest virtual address。系统模拟下，它要查询 software TLB，命中 RAM 才形成宿主地址，未命中进入 fill，MMIO 则调用设备回调，任一步都可能产生 RISC-V 异常。`qemu_ld/st` 把这条语义标给后端，让后端生成内联快速路径和 C slow path。

RISC-V64 后端的 `tcg_out_qemu_ld_direct`、`tcg_out_qemu_st_direct` 负责能直接访问的情况，`tcg_out_qemu_ld_slow_path` 与 store 对应函数生成或连接慢路径。寄存器分配必须为地址、数据和临时值满足约束，还要保留可供异常回溯的 return address。下一章会展开 SoftMMU，这里只需记住，IR 中一个 load op可能发射一段 tag compare、地址修正、分支与真正宿主 load。

MemOp 编码访问宽度、符号扩展、端序、对齐和原子要求。前端若选错，后端只能忠实地产生错误语义。公共 TCG 又会结合 host capability 调整原子性与 barrier。跨层调试时，应先核对 RISC-V `trans_lw` 生成的 MemOp，再看 optimizer 是否保留，最后看 RISC-V64 host 发射。

## 客户机内存序不等于宿主内存序

RISC-V 允许相对宽松的内存模型，`fence`、原子指令的 `aq/rl` 和 Ztso 等能力施加额外顺序。宿主也是 RISC-V 时，仍不能简单删除所有 barrier：QEMU 生成代码、软件 TLB、设备回调和多 vCPU 线程构成额外层，客户机某个访问可能变成 C helper，编译器也会参与重排。

TCG 用 `tcg_gen_mb` 和原子 op表达客户机需要的顺序，再由 host 后端映射到合适 fence 或已有指令语义。过弱会让客户机并发算法出现规范不允许的结果；一律使用最强 fence 功能上安全，却会拖慢所有共享内存访问。工程目标是按客户机约束与宿主模型求足够强的映射。

:::: {.quick-quiz}
为什么客户机内存序不能简单等同于宿主内存序？

::: {.quick-answer}
两者可能有不同模型，TCG 还把一次客户机访问展开为 tag 检查、宿主内存、helper 与设备回调。编译器和多 vCPU 线程也在中间。实现必须把客户机要求翻译成覆盖整条生成路径的宿主操作与 barrier，既不能遗漏，也不应无条件升级为最强顺序。
:::
::::

## 原子操作要考虑 host 能力与对齐

RISC-V A 扩展要求 AMO 与 LR/SC 的可观察原子性，访问宽度、自然对齐和 reservation 都有规则。若宿主能原生完成对应宽度，TCG 可生成原子序列；否则可能调用 helper 或在 serial context 中执行。不同路径还要报告一致的异常优先级。

对齐与原子性不能混成同一个数字。提交 [`4dea00368d`](https://gitlab.com/qemu-project/qemu/-/commit/4dea00368d) 引入 `MO_ALIGN_TLB_ONLY`，提交说明解释通用 TCG 需要区分普通内存对齐、设备内存对齐和访问原子性。该改动最初由另一目标需求推动，却改变公共 MemOp 语义，RISC-V 前端也会通过同一层受益。上游审查通用 op时必须跨目标评估，就是因为一个枚举会服务多种 ISA。

实验可用两颗 RISC-V vCPU 对同一缓存行做 AMO，再故意构造未对齐地址，分别检查计数结果与 trap。若只在单核运行，普通 load/add/store 也可能看似“原子”；若只看最终计数，又可能漏掉某次应当 trap 的访问。

## helper call 是宿主 ABI 边界

TCG helper 是普通 C 函数，却由生成代码调用。参数要按宿主 ABI 放入寄存器或栈，返回值要取回，caller-saved 寄存器按约定失效。helper 还可声明读取或写入环境、可能退出或不会返回等属性，公共 TCG 用这些信息做 liveness 与同步。

属性写错的风险两头都在。把有副作用 helper 标成纯函数，optimizer 可能删除或重排；把纯 helper 标得过于保守，会阻止传播并增加 spill。helper 内触发客户机异常时，还要传递正确的宿主 return address，让 `cpu_restore_state` 找到调用指令。普通单元测试只比较返回值，无法覆盖这一层。

调用大型向量 helper 时，生成代码短，C 循环可能成为运行热点；直接展开 IR 则增加翻译和缓存压力。选择必须用工作负载衡量。作者建议同时记录每 TB IR 数、宿主代码字节数、helper 调用次数和执行时间，避免只看最后一个数字。

## RISC-V64 后端怎样发射代码

寄存器分配完成后，`tcg/riscv64/tcg-target.c.inc` 根据最终 `TCGOutOp` 发射 32 位 RISC-V 指令，处理立即数构造、branch range、load/store 和 relocation。TB 内 label 初次出现时目标地址可能未知，后端先记录 relocation，布局完成后回填。direct TB jump 还要保留可补丁位置，供运行时 chaining。

当前 TCG 已将整数 opcode 转为 `TCGOutOp` 形式，提交 [`eafecf0805`](https://gitlab.com/qemu-project/qemu/-/commit/eafecf0805) 移除旧 `tcg_out_op`，提交说明指出整数 op 已全部转换。上游事实显示，后端接口会重构，阅读旧补丁需要识别当时的发射 API，不能只按当前函数名搜索。

RISC-V branch 立即数有范围，TB 内远跳可能需要反转条件加长跳转，或通过临时寄存器构造地址。代码区 region 布局也要保证 helper 和跳板可达。后端的 `tcg_out_goto_tb`、prologue 与 relocation 共同解决这些问题。前端只看 label，距离由最终布局决定。

## 固定临时寄存器是一种隐形资源

后端常保留若干寄存器给 TCG 环境、栈指针、调用约定或复杂序列临时使用。这些寄存器不能当普通 allocatable set。若发射函数内部临时使用一个寄存器，却没在约束或保留集合中体现，寄存器分配器可能同时把活跃值放在那里，错误只在特定压力下触发。

提交 [`af6db3b713`](https://gitlab.com/qemu-project/qemu/-/commit/af6db3b713) 修复 RISC-V 后端 `TCG_REG_TMP0` 在 `tcg_gen_dup{m,i}` 中被 clobber，提交说明指出 `set_vtype*` 也可能用该寄存器装载 vtype。这个案例非常适合说明后端局部函数之间的隐形合同：两段代码单独看都合理，组合后争用了同一临时资源。

作者推断，新增后端序列时，review checklist 应包括“最坏分支会用哪些 scratch”“helper/内联路径是否相同”“向量状态设置是否嵌套调用”。依靠约定俗成的 TMP0 名称不够，压力测试要覆盖这些组合。

## 代码缓存、W^X 与指令可见性

后端把字节写入 JIT 区，执行线程再从可执行映射取指。现代系统常要求 writable 与 executable 不同时成立，QEMU 使用 split W^X 映射或平台专用权限切换。`tcg_splitwx_diff` 描述两种映射的地址差，relocation 和链接补丁都要在正确视图操作。

提交 [`f6ff5ec21e`](https://gitlab.com/qemu-project/qemu/-/commit/f6ff5ec21e) 修复 `tcg_splitwx_diff` 计算触发的 UBSan overflow，邮件 [`20260605132539.2775364-1-farosas@suse.de`](https://lore.kernel.org/qemu-devel/20260605132539.2775364-1-farosas@suse.de/) 给出证据。地址差在实现中看似普通整数，却横跨两份映射，C 有符号溢出规则会让 sanitizer 报错。JIT 内存管理因此也是正确性与可移植性的一部分。

写完宿主指令后，还要按平台要求刷新指令缓存或建立可见性。RISC-V 宿主的 I-cache 一致性需要对应机制，不能假定刚写的数据立刻能作为指令执行。后端与通用代码在发布 TB 前完成同步，执行线程才可 lookup。

## 怎样读 `op` 与 `out_asm`

`-d op` 展示优化前后哪一阶段，要结合日志标签确认；`-d out_asm` 是最终宿主代码。一个客户机 `addi` 对应多条宿主指令不代表翻译失败，周围可能有 PC、退出和 TLB 管理；多个客户机运算合成较短序列也不代表漏执行，常量传播和死写删除可能生效。

分析时先做语义分组。把 IR 分成客户机计算、CPU 状态同步、内存快速路径、异常慢路径、TB 退出，再对应宿主代码。只逐行寻找“一条 guest 对一条 host”，在同架构闭环里尤其容易被迷惑。TCG 翻译的是虚拟机语义，不是二进制重定位器。

日志会显著增大 I/O，不能用开启 `out_asm` 的运行时间评估正常性能。先用日志理解结构，关闭日志后再用稳定 workload 测量；两次运行要记录相同 CPU 型号、TB 配置和宿主频率条件。

## 一次 `tcg_gen_code()` 的阶段清单

目标translator结束后，TCG拿到按顺序组织的op与temp。生成阶段先完成必要的优化和lowering，随后liveness标注死值与同步需求，寄存器分配遍历op、满足constraint、安排spill，后端发射最终指令，最后处理label relocation与slow path。不同版本会调整具体函数边界，概念顺序可用来定位状态在哪一阶段改变。

不要把日志中的第一份IR当最终输入。前端可能先产生高层op，optimizer折叠常量、删除死写并展开host不支持形式；寄存器分配还会插入move、load constant和spill，这些通常不再以原始TCGOp形式完整显示。要回答“这条宿主指令从哪来”，需要同时看优化后IR与backend trace。

阶段之间的合同很紧。optimizer认为某op支持两个立即数，constraint只允许一个，reg allocator会遇到无法满足组合；lowering产生新的temp却未正确设置生命周期，spill可能读未初始化槽；backend发射额外scratch却未声明，覆盖活跃值。分层不等于各自独立，测试要穿透整条管线。

生成失败通常不能回退执行半个TB。buffer overflow、relocation越界或后端断言发生时，未发布代码被丢弃，调用者flush或重新生成。已发布TB必须保证所有patch完成、I-cache同步和元数据一致，运行时不会再调用optimizer补丁。

## `TCGContext` 为何按翻译线程组织

`TCGContext` 保存当前op链、temp池、代码指针、label、寄存器集合和backend状态。MTTCG允许多个vCPU并行翻译，若所有线程共用一个可变context，锁会包住整次生成。当前实现为翻译线程提供独立或分配的context，代码region和全局helper信息再以适当方式共享。

context只能在所属翻译期间使用。把 `TCGTemp *` 或当前op指针存进长期CPU对象，下一次生成可能复用内存；backend全局静态scratch也会在线程间竞态。目标translator通常通过传入的context API生成，不自行保存内部地址。

全局TCG初始化建立helper表、prologue和host capability，一次完成；每个TB context重置局部arena，避免大量malloc/free。arena对象生命周期短，能快速批量回收，也要求错误退出统一清理。动态翻译偏好这种内存模型，因为小对象数量非常大。

调试插件若要观察IR，应在规定callback内复制需要信息，不能跨context持有裸指针。日志输出在生成线程发生，多线程行可能交错，分析脚本要按TB标识分组，不按文件相邻行猜同一块。

## temp 从内存、寄存器到 dead 的状态机

寄存器分配器为每个temp跟踪当前位置：常量、宿主寄存器、frame memory、或已dead。读操作要求值在满足constraint的位置，必要时从frame load或materialize constant；写操作分配输出寄存器，旧值若无需保留可覆盖；最后使用后释放寄存器。

global temp更复杂。它对应 `env` offset，可能在寄存器里有更新值，而memory副本仍旧。调用会读取global或TB退出需要同步时，分配器写回；若下一op覆盖且旧值不可观察，可以省写。状态机必须知道helper flags和basic block边界。

spill slot通常位于TCG prologue建立的frame，地址相对固定frame pointer。不同宽度和对齐要正确，i128或向量temp可能占多个槽。一个值spill后再reload并非总能用同一宿主指令，RISC-V64 offset超出load立即数范围时还需构造地址。

debug分析时，可把每个temp画成区间，标出定义、last use、helper和branch。看到重复load先检查是否跨helper clobber，看到早期store先检查是否global sync。没有生命周期证据就把所有move称作“寄存器分配差”，很容易错。

## basic block 边界为什么要求同步

条件branch有两个后继，线性分配器不能假定当前宿主寄存器映射在两边都相同。进入label时通常把需要跨边的local/global状态同步到约定位置，释放临时寄存器，再从统一状态开始。这样牺牲部分跨块优化，换来简单可靠的控制流合并。

普通temp不允许跨basic block使用，local temp为此存在。滥用local会扩大活跃范围和同步，少用又会在后继读到未定义值。目标前端生成复杂select或循环时，应尽量利用TCG条件op，避免无必要地建IR内部大控制流。

TB本身已是较小单位，跨basic block优化收益有限。TCG没有为每个TB建立完整SSA与phi网络，翻译延迟是约束。RISC-V条件分支常直接作为TB出口，使控制流由TB chaining处理，而非把大量客户机块合进一个IR函数。

异常边也要同步。`qemu_ld` slow path可能从中间退出，backend在发射slow label前保存足够状态，return address关联当前insn。正常fast path不必为每次load写回全部global，精确恢复使用元数据重建。这里是运行时回溯与编译期liveness的配合。

## op definition 同时描述数据流与副作用

TCG op表定义参数数目、输入输出、常量参数、是否branch、是否call等属性。optimizer、pretty printer、liveness和backend都依赖同一描述。新增op只写 `tcg_gen_*` 与一个backend case不够，其他阶段若不知道参数角色，会把输出当输入或错误删除。

纯op没有环境和内存副作用，结果dead即可删；`mb`即使没有输出也必须保留；`qemu_st`写guest memory；`exit_tb`改变控制；call依据helper flags。side effect越精确，优化机会越多，错误声明风险也越高。上游倾向为新op补所有host或提供通用lowering，保证任意构建有定义。

立即数元参数如condition code、MemOp、label index不是普通temp，寄存器分配不能materialize。日志里数字外观相似，需按op签名解释。修改op参数顺序是内部全树变更，所有生成点、optimizer和backend必须原子更新。

TCG IR不是稳定外部格式，插件也应使用公开callback而非解析内部结构。书中实验解析 `-d op` 只为当前版本诊断，正式tag变化后要重新验证脚本，不能把文本格式当API。

## 位级优化如何证明安全

optimizer为temp维护已知zero bits、one bits和受影响范围。对 `x & 0xff`，高位确定零；再做零扩展可能冗余。对shift，已知位随方向移动，移出范围丢弃；shift amount越界则必须按op规定处理，不能直接使用C未定义移位。

RISC-V bitmanip前端常生成rotate、orc、clz等高层op。若backend不支持，lowering展开为shift/or；已知位信息可把某些mask删除。正确性证明要覆盖所有位宽和常量边界，尤其32位op装在64位temp时的高位状态。

提交 `08b12bfb8f` 修正 `orc` 的 `a_mask`计算，说明一个内部mask会影响后续折叠。回归测试不能只测orc最终结果，还要构造其结果继续参与and/compare，让错误known bits真的影响删除。optimizer bug常在第二条或第三条op才显现。

随机差分是有效补充：生成短IR表达式，和无优化解释结果比较大量输入。它不能替代人工证明，因为helper、内存和异常难覆盖；对纯整数fold非常有价值。测试需固定seed并输出最小化表达式，失败才可复现。

## constraint 字符串怎样变成分配选择

host后端为每种op给出constraint set，例如输出可用通用寄存器、输入可为寄存器或特定立即数、某输入与输出tie。初始化阶段解析为位集合和predicate，生成时选择匹配当前常量的备选。多个set让后端针对不同组合提供路径。

立即数predicate必须与真正编码函数一致。若constraint接受4096而RISC-V I-immediate只到2047，分配器会保留常量形式，发射时溢出；若只接受到1023，2047会被无谓装寄存器。边界测试应覆盖最小、最大、刚越界与负数。

tie constraint适合二地址指令或复用输入输出，分配器可能插move让二者同址。若输出覆盖输入但另一个后续值仍需原输入，liveness必须保留副本。复杂op的多个constraint set要在高寄存器压力下分别触发，正常编译器代码可能永远只走第一组。

RISC-V64后端目录中的 `tcg-target-con-set.h` 是入口，真正立即数判断和发射在 `tcg-target.c.inc`。审查应交叉看二者，再用assert或unit test确保predicate与encoder同步。

## RISC-V64 大常量如何落地

RV64没有一条把任意64位常量装寄存器的指令。小有符号12位可用 `addi rd,x0,imm`，适合高20位的值可用 `lui`组合，完整64位常量需要分段移位加法，或从literal/附近数据加载。后端根据值形状选择序列。

常量传播有时让序列变长：两个运行时值运算变成一个无法内嵌的大常量装载再运算。总体仍可能更快，因为删除了依赖和前序计算，但不能只用宿主指令条数评价。代码尺寸、依赖链和寄存器压力共同作用。

地址常量还受code model与relocation影响。helper地址、TB jump目标在生成时或链接时已知，可能用PC-relative `auipc`加 `jalr`，距离越界则经过trampoline。普通guest常量不应误用可重定位host地址路径。

实验的“立即数内/外”两组正是为了观察constraint和materialize。应把最终序列按数值分解手算一次，确认符号扩展，尤其低12位最高bit为1时高段需要补偿。

## RISC-V64 prologue 建立执行约定

TCG prologue是C `cpu_tb_exec`与生成TB之间的桥。它保存宿主callee-saved寄存器，建立TCG frame，把环境指针放到约定寄存器，跳入TB；TB exit再回到epilogue恢复并返回编码结果。每个TB无需重复完整C函数序言，降低链接开销。

保留env寄存器能让RISC-V guest global通过固定base访问，代价是少一个可分配host寄存器。frame与临时寄存器集合也在后端定义。prologue改变时，所有生成代码和helper ABI都受影响，应在启动前一次生成并保持生命周期。

direct chaining从一个TB跳另一个TB，沿用同一prologue环境；只有离开TCG才执行epilogue。若链接目标假定不同env或frame，跨CPU误链会灾难性出错，所以TB属于具体target/TCG context，jump patch有严格来源限制。

信号处理与精确异常要识别PC是否位于JIT区，找到对应TB并恢复，然后通过epilogue/longjmp离开。prologue保存哪些寄存器、宿主ucontext如何读取，形成平台相关边界。

## qemu load 的 fast path 在后端展开

RISC-V64后端取得guest address，计算TLB索引，加载tag并比较。命中RAM时从entry的offset形成host address，用按MemOp选择的 `lb/lbu/lh/lw/ld` 等指令读取；未命中或flag特殊则branch到slow label，传参调用C helper，回来后跳回主序列。

慢路径通常放在TB主体之后，保持常见顺序代码紧凑。branch到slow path的距离要可编码，布局完成后patch。load结果在哪个寄存器、slow helper返回位置和主路径后续使用必须一致，constraint与label记录共同保证。

符号扩展可以由host load指令直接完成，例如guest `lw`到RV64用有符号word load；guest端序与host不同则需要byteswap，未对齐或跨页也会slow。相同ISA不等于永远一条host load，software TLB与属性检查仍在前。

MMIO slow path可调用设备并退出或重新进入，helper clobber比普通TLB fill更大。后端在slow label前同步必要global，返回后恢复live值。日志中大量保存/恢复可能只存在冷MMIO路径，不应计入RAM命中每次成本。

## RISC-V64 host 向量能力如何被使用

TCG host backend可以利用宿主V扩展实现部分vector op，前提是运行时探测能力与vlen满足。guest RISC-V向量指令往往先变成gvec/helper，并不保证一一映射host vector，因为guest VL、LMUL、mask和异常语义不同。

host后端设置vtype可能使用固定TMP寄存器，`af6db3b713` 的clobber修复就发生在dup序列。向量状态属于宿主线程资源，helper或C代码也可能使用ABI规定，TCG需要在边界重新建立。不能假定一次 `vsetvli` 后跨所有TB永久有效。

宿主没有V扩展时，TCG通过scalar展开或helper保持功能。测试矩阵应在启用和禁用host vector capability下运行同一guest，结果一致，宿主代码形状不同。架构示例仍只涉及RISC-V，变量是同一RISC-V host是否具备V。

性能结论要按指令族衡量。有些guest vector helper已高度优化，强行用host vector可能受descriptor转换和tail处理拖累；某些纯bitwise则收益明显。上游patch应附微基准与完整正确性用例。

## helper 属性错误的两种症状

若helper实际写CPU global却声明不写，调用前分配器可能保留旧memory副本，helper写入后寄存器中的旧值继续被使用；或者optimizer把两次调用合并。症状依赖后续是否读取，常在特定TB形状出现。修复不只是加barrier，要改helper info让所有调用点正确同步。

若helper实际纯净却声明读写全部global，功能正确，生成代码会在调用前写回大量寄存器、之后重载，TB chaining收益下降。性能profile看到helper周围spill风暴，应先检查flags，不能直接手写backend特例。

可能fault的helper还需要return address。标成不会退出后，后端可能省异常元数据；真实fault时无法恢复PC。负向测试应让helper内部访问页尾或非法CSR，断言精确trap，不只测正常返回。

上游review可从实现反推读写集，并搜索未来可能增加的字段。过于激进的pure声明给后续修改埋雷，适度保守有维护价值。提交说明应解释依据，方便以后重新审计。

## 如何验证一个后端修复不是“只修样例”

后端bug通常由某种constraint和寄存器压力触发。最小复现确定失败op后，要枚举输入输出重叠、立即数边界、所有可分配寄存器和spill状态。修复TMP0 clobber，测试应让其他值主动占满寄存器，并让嵌套序列也用TMP0，而非只跑一个dup常量。

然后在RISC-V64 host上运行 `tests/tcg/riscv64` 与跨target TCG测试。host后端服务所有guest target，本书虽以RISC-V guest讲解，修复不能假定只有RISC-V前端产生某种op。若实验范围只验证RISC-V，应诚实标注，不能称全后端覆盖。

disassemble最终TB，确认修复路径实际触发；仅源代码覆盖率进入函数，不证明走到特定constraint set。加入assert可在开发构建检查scratch不在live set，发布构建则依靠测试。

最后比较翻译时间和代码尺寸，防止正确修复无意把常见立即数全部materialize。性能回归不是拒绝正确性的理由，却应在同一系列说明权衡并寻找较小实现。

## 在线编译成本应该怎样测

将总运行时间拆为TB生成次数、optimizer时间、后端发射时间、生成字节和TB执行次数。冷启动看每个TB只跑少数次，翻译成本占比高；热循环看生成一次、执行百万次，宿主代码质量占比高。平均值不能替代分层计数。

不同日志会污染测量，`-d op`本身格式化大量文本。可先用trace或内部统计定位，再关闭输出跑wall-clock。宿主频率、ASLR和线程调度也会影响小样本，应重复并报告分布，不给没有置信依据的小数点百分比。

优化patch若减少两条host指令，却让optimizer每TB扫描多轮，热benchmark可能赢、启动可能输。QEMU服务固件、OS和用户模拟多种场景，上游通常需要几类workload。书中实验只做结构比较，不把两段toy loop外推全局。

作者把TCG取舍归纳为“三本账”：生成时间、代码缓存、执行时间。helper、lowering与优化都在三者间移动成本。这个框架来自当前实现和常见review问题，具体权重随工作负载变化。

## call lowering 如何遵守 RISC-V64 ABI

helper参数按类型分配到RISC-V64 ABI的整数或浮点参数寄存器，超过数量再放栈，返回值从约定寄存器取得。TCG内部i128可能拆成两个机器字，参数顺序和对齐必须稳定；小于XLEN的值还要按helper原型决定扩展，不能让C端读取未定义高位。

调用前，活跃在caller-saved寄存器的temp要spill或移动，callee-saved由prologue整体管理。env通常占固定寄存器，也可能作为第一个helper参数显式传入。helper flags决定哪些global必须写回memory，调用后哪些缓存值失效。

间接调用目标地址可能超出 `jal` 范围，backend生成 `auipc/jalr` 或通过trampoline。代码区与helper共享进程地址，但ASLR使距离每次不同，不能在构建时固定。relocation在TB布局后补目标，发布前检查可编码。

若helper `noreturn` 通过 `cpu_loop_exit` 离开，正常return path不应生成无用代码；但C ABI栈和保存状态仍要让longjmp恢复。标记错误会留下不可达序列或更严重的状态同步缺口。实验制造helper fault，核对PC与frame。

## label、relocation 与 TB patch 是三件事

TB内label在同一生成单元里，后端先记分支位置，知道最终offset后回填；helper调用relocation指向外部C/跳板；`goto_tb` 为运行时未知的下一个TB预留patch点。三者都“后来填地址”，生命周期和修改权限不同。

TB内label发布后不再变，距离越界在生成阶段选长序列。helper目标通常固定于QEMU进程，重定位完成后不随客户机控制流改变。direct chaining则会随TB lookup与invalidation反复修改，必须保存incoming关系和I-cache同步。

RISC-V64分支范围有限，backend可能反转condition跳过长jump。constraint和liveness要为长序列scratch留资源，不能在短分支测试通过后假定远label正确。限制region或构造大slow path可覆盖。

W^X下三种patch都写RW view，执行用RX view。生成阶段尚未发布，操作相对简单；运行时goto_tb patch需要线程与JIT权限协议。把通用relocation函数复用到运行时，必须确认它可并发且会flush I-cache。

## 用一个位提取修复看跨层证据

提交 `169d253e1f` 修正RISC-V后端 `tgen_extract` 的shift方向。要验证它，先找到哪些TCG op调用该generator，再从RISC-V guest构造能产生对应extract的指令或直接用其他target测试，最后让offset和length覆盖低位、高位与全宽边界。

优化前IR必须保留extract，若常量传播把它折掉，测试没有进入后端。可以让输入运行时变化并查看 `out_asm`。错误结果与参考C表达式比较，保存最小IR和host代码，证明问题在backend而非guest translator。

修复后还检查指令条数与立即数。方向改对可能暴露原先被错误路径掩盖的越界shift，不能只改一字符。邮件或commit说明若只称typo，书中可陈述事实，额外根因分析标成作者复核。

这个案例展示证据链：guest程序只是触发器，IR界定前端正确，host disassembly界定发射，参考结果界定语义。以后分析任何backend问题，都可以复用这四层。

## 同为 RISC-V 的 guest/host 仍要隔离状态

guest `x1` 不等于host `x1`。寄存器分配可把guest值放任意host寄存器，host ra、sp、tp有ABI用途，部分寄存器被TCG保留。guest PC是数据，host PC正在执行JIT；guest privilege由 `env`模拟，host进程仍在用户态。

guest load经过software TLB，host load访问QEMU进程；guest `ecall`进入模拟trap，host `ecall`会进入宿主内核，backend绝不会把前者原样复制。guest `fence`映射为覆盖TCG路径的host fence，可能加强或调整。名称相同只让最终序列更容易阅读，不会消除虚拟化层。

向量状态也分开。guest v0-v31存于CPU环境，host V寄存器是TCG临时资源，helper调用可按ABI破坏。直接映射需要处理VLEN、vtype、mask与异常差异，当前backend选择由capability和gvec路径决定。

这一隔离正是IR层价值的直观证明。若想优化同架构直译，必须逐项证明状态可映射，并保持exit与异常；不能因opcode相同跳过TCG合同。

## 后端 patch 的构建与运行矩阵

至少构建RISC-V64 host的system与user mode，开启debug和release，运行RISC-V guest TCG测试、通用TCG tests与能触发修改op的其他guest前端。交叉编译只能证明encoder可编译，运行需要RISC-V硬件、KVM内的RISC-V开发机或可信仿真环境。

host capability分支也要覆盖，例如有/无V、不同原子能力、split W^X。可以用后端测试开关屏蔽能力，前提是代码支持，不伪造硬件执行不存在指令。CI矩阵结果记录QEMU hash和工具链。

sanitizer用于C optimizer与内存管理，生成代码正确性靠TCG tests和差分。UBSan提交 `f6ff5ec21e` 说明即使功能结果正常，地址算术未定义行为也需修；JIT与signal使某些sanitizer组合有限，报告限制。

性能测试最后做，在正确性矩阵通过后测翻译与执行两阶段。若patch只为修bug，性能不退化即可；不要用微小加速替代缺失host配置验证。

## 何时值得新增 TCG op

一段语义被多个target频繁使用，现有op展开阻止host利用专门指令，且可以为所有host提供正确lowering，才有新增op的基础。只为一条低频RISC-V扩展增加专用op，会把维护成本推到全部backend，helper或现有组合可能更合适。

提案要写op精确位宽、异常和side effect，列host capability与generic expansion，补optimizer fold、liveness描述和tests。若op只是语法别名，没有优化或发射收益，有限IR保持更小通常更好。

删除op也需证明所有生成点已迁移、32/64位host都有替代、optimizer不会退化。2026 年删除若干只为32位host的op，展示内部IR可演进，但演进要成系列完成。

作者的判断标准是复用频率、语义独立性、lowering质量和三本账收益。它不是硬规则，上游邮件中的host维护者反馈才决定方案；正文应把最终取舍与作者建议分开。

## 阅读复核：给一段 IR 做三次解释

第一次按客户机语义解释，标出哪组op实现一条RV64指令，哪些只维护PC、异常与TB出口。第二次按数据流解释，标temp定义、常量、last use、helper clobber和global sync。第三次按RISC-V64 host解释，标constraint选择、立即数构造、spill、slow path和relocation。三次图叠在一起，才不会把虚拟机管理指令误算成客户机算法。

看到优化消失的op，证明它是纯且结果dead；看到保留的无输出op，说明memory、barrier或control副作用。看到host多条指令，区分大常量、TLB检查和ABI，不按“一对一”评价。看到spill，先找活跃区间与helper，再判断constraint。

随后用参考程序验证结果，用 `-d op,out_asm`验证结构，关闭日志测生成/执行两阶段。正确性、结构和性能三份证据互不替代。邮件中若只声明正确性修复，不替上游添加未经测量的性能结论。

最后核对版本。IR op、后端目录和发射API都是内部实现，`v11.1.0-rc0` 的图只解释当前锚；正式tag若重构，保留原理、更新符号和实验。这样章节依赖稳定合同，不依赖一张过期反汇编截图。

对每次更新，至少重跑两个固定样例：一个纯整数数据流，用来观察optimizer和constraint；一个RAM加CSR/helper，用来观察slow path与ABI。两份IR都保存机器可读摘要，比较op类别、host bytes和结果，不对host地址做golden。

若差异只来自寄存器编号，语义可能不变；若helper、barrier或qemu_ld消失，需要人工确认副作用。自动diff负责提醒，不能替代架构判断。

在共享仓库保存日志时，只提交筛选后的结构报告和生成脚本，不提交依赖宿主地址的巨型 `out_asm`。原始日志可作为实验产物由CI归档。报告注明RISC-V64宿主能力，尤其V扩展、原子与W^X；这些条件改变后端选择，却不改变客户机oracle。这样下一位读者能重跑，而不是只能浏览一次机器的输出。

筛选脚本自身也要测试，至少确认不会把slow path和relocation误删。报告中的每个宿主序列保留原始日志偏移或TB标识，读者可追溯到未加工证据。

若原始日志因体积没有长期保留，CI产物需标保存期限；书稿中的结论仍应能由脚本和固定输入重新生成，不能依赖已经消失的附件。

::: {.source-path}
主要入口为 `tcg/tcg-op.c`、`tcg/tcg.c`、`tcg/optimize.c`、`tcg/liveness.c`、`tcg/tcg-op-gvec.c`、`tcg/riscv64/tcg-target.c.inc`、`tcg/riscv64/tcg-target-con-set.h` 与 `target/riscv/tcg/`。源码固定 `v11.1.0-rc0`，host 示例仅使用 RISC-V64 后端。
:::

## 实验：保存一条完整 IR 证据链

::: {.hands-on}
实验名称：`dump-tcg-ir`。使用英文手册 [`dump-tcg-ir`](../experiments/part-02-tcg-execution-engine/chapter-09-tcg-ir-and-host-code/dump-tcg-ir/README.md)。准备包含 RV64 整数、条件分支、RAM load/store 和一次 CSR 访问的短函数，用 `-d in_asm,op,out_asm` 限定地址范围运行。报告逐项标注 temp 定义与最后使用、可折叠常量、helper call、`qemu_ld/st` 和两个 TB 出口，再把优化后的 IR 对应到 RISC-V64 宿主反汇编。不要用其他 host 架构举例。
:::

为了获得 RISC-V64 宿主代码，实验需要运行在 RISC-V64 主机或受控的 RISC-V64 开发环境中；若当前宿主不是 RISC-V，只完成 IR 部分，并把官方构建产物或远端实验作为独立证据，不能把本机 `out_asm` 冒充 RISC-V。手册应记录工具链、QEMU commit 与日志开关。

## 实验：比较同一后端的两种代码形状

::: {.hands-on}
实验名称：`compare-host-code`。使用英文手册 [`compare-host-code`](../experiments/part-02-tcg-execution-engine/chapter-09-tcg-ir-and-host-code/compare-host-code/README.md)。在 RISC-V64 host 上构造两组等价客户机函数，一组让常量落入宿主立即数范围，另一组使用需要多条构造的大常量；再通过增加跨 helper 活跃值制造寄存器压力。比较最终代码字节数、常量装载、move、spill 与 helper ABI，不以一次 wall-clock 排名作为结论。
:::

实验还应加入正确性 oracle：用客户机原生计算或独立参考实现验证大量边界输入，尤其覆盖 shift 0、63，extract 跨界，大立即数正负边界。若看到宿主序列变化而结果一致，才能讨论优化；结果不同则先按前端 IR、optimizer、constraint、发射四层二分定位。

## 历史证据怎样进入结论

本章的源码事实是 TCG IR 经 optimizer、liveness 与寄存器分配后进入 RISC-V64 backend，`qemu_ld/st` 拥有特殊 slow path，代码缓存采用可执行映射协议。上游提交明确描述了 lowering 延后、位掩码修复和 TMP0 clobber。作者据此提出“有限 IR 优化模拟器总成本”“constraint 是后端合同”，这些是归纳，不是邮件原句。

看到某条优化提交时，还要检查它在目标研究锚中是否已经合入，并记录完整 hash。邮件的 v1 可能与最终 commit 不同，书中引用最终代码事实，用 Message-ID 解释审查过程。若 `v11.1.0` 正式 tag 与 rc0 之间发生调整，发布前应重新跑本章实验并更新差异说明。

## 小结

TCG IR 将 RISC-V 客户机语义与 RISC-V64 宿主约束隔开，temp 和 op保留足够数据流，轻量 optimizer 与 liveness 降低运行成本，线性寄存器分配再按 constraint 选择寄存器、立即数和 spill。后端代码量相对集中，却承担 ABI、跳转范围、W^X、原子与指令缓存等真实架构责任。

下一章进入 `qemu_ld/st` 展开的地址路径。那里一个看似普通的 load 会穿过 software TLB、RISC-V 页表和 MemoryRegion，IR 中的内存语义也会变成精确 fault 与 MMIO 分派。
