# 从 dyngen 到 TCG：一次不能停机的引擎更换

2008 年 2 月 1 日，Fabrice Bellard 在 qemu-devel 发了一封很短的邮件：QEMU 加入了一个新的代码生成器 TCG。邮件没有把它包装成架构重写，只列出两个动机——避开不同 GCC 版本造成的问题，并获得更好的性能。更值得留意的是下一段：各 target 只做了最小修改，TCG 暂时仍能承接 legacy dyngen micro-op，完整转换可以逐步进行。

这封邮件解释了大型系统更换基础设施时真正困难的部分。新设计要解决旧债，还要让已有目标继续启动、测试和接受补丁。TCG 的 IR、类型、全局变量与 helper 机制，从第一天起就背着这项迁移约束。

## 先校正“TCG 原来是什么”

TCG 全称 Tiny Code Generator。2008 年初始 [`tcg/README`](https://gitlab.com/qemu-project/qemu/-/blob/c896fe29d6c8ae6cde3917727812ced3f2e536a4/tcg/README) 写了两条来源：它起初是一个通用 C 编译器的 backend，后来为 QEMU 简化；它也吸收了 Paul Brook 编写的 QOP code generator。当前 [`docs/devel/tcg-ops.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/devel/tcg-ops.rst) 仍保留这段说明。

这份一手材料没有点名 TinyCC，也没有说 TCG 曾经是一套完整 C 编译器。因而本书采用更窄、也更可核验的表述：TCG 带着“通用 C 编译器后端”的来源，进入 QEMU 后被简化，并受到 QOP 的影响。除非找到 Fabrice 或 Paul 给出的进一步材料，我们不会把这个 backend 自动等同于 TinyCC，更不会把 dyngen、TinyCC 与 TCG 排成一条未经证明的继承链。

这项校正会改变读法。QEMU 需要的部分是运行时代码生成：类型明确的操作、临时值、寄存器分配、重定位和宿主发射。C 语言的解析、预处理、完整优化和目标文件输出都不在问题范围内。把 TCG 叫作“一个 C 编译器”容易让读者期待 LLVM/GCC 那种全程序管线，也遮住它为 TB 时延、异常恢复和代码缓存做的取舍。

本书把“Tiny”理解为一种工程读法，现有一手材料没有说明 Bellard 选择这个名字时的意图，因此不能把下面的解释归给他。TCG 的翻译发生在客户机第一次执行某段代码的等待路径上；每加入一轮分析、一个全局数据结构或一种重量级变换，都要支付冷启动与代码生成成本。“Tiny”不表示实现代码永远很少，也不保证 IR 永不增长，真正可核验的是这组运行时约束。

## 2 月 1 日的两个提交怎样接上旧世界

提交 [`c896fe29d6`](https://gitlab.com/qemu-project/qemu/-/commit/c896fe29d6c8ae6cde3917727812ced3f2e536a4) 先加入 7000 多行 TCG 基础代码，包括 i386、x86_64 后端、IR op、runtime 和 `tcg-dyngen.c`。紧接着的 [`57fec1fee9`](https://gitlab.com/qemu-project/qemu/-/commit/57fec1fee94aa9f7d2519e8c354f100fc36bc9fa) 才让 QEMU 使用新生成器，修改公共执行代码和多个 target。分成两步，使“生成器本身”与“接入现有虚拟机”的差异可以从历史中直接看见。

Fabrice 的[公告邮件](https://lists.gnu.org/archive/html/qemu-devel/2008-02/msg00011.html)明确说明，x86 与 x86_64 已有较大转换，其他目标仍可把 legacy micro-op 交给 TCG。初始 README 甚至规定：legacy dyngen operation 前后都形成 IR basic block 边界。旧操作并未被假装成普通 TCG op，它被包在一个保守边界里，进入前把状态放回约定位置，出来后重新建立可分析区域。

这个桥接牺牲了一部分优化空间，却把迁移风险切小。一个 target 可以先替换寄存器移动和整数运算，复杂浮点或罕见特权操作继续沿旧路径；每一批都有可启动的中间状态。若强迫所有 micro-op 一次消失，任何目标的精确异常、delay slot 或条件码恢复遗漏都可能拖住整个合入。

现代 RISC-V target 没有这层遗留边界。2018 年提交 [`55c2a12cbc`](https://gitlab.com/qemu-project/qemu/-/commit/55c2a12cbcd3d417de39ee82dfe1d26b22a07116) 加入 RISC-V TCG code generation 时，前端直接调用 `tcg_gen_*` 和 helper。今天阅读 RISC-V 代码会觉得 guest→IR 分层理所当然，原因之一正是 2008 年那座临时桥最终拆掉了。

## 类型在 review 中从文档走进接口

初始 README 已声明 TCG instruction 与 variable 都是强类型，先支持 i32 和 i64，pointer 根据 TCG target word size 取别名。然而文档里的类型若仍由裸整数承载，前端很容易把“TCG variable”“立即数”“客户机寄存器编号”混在同一参数位置。

公告当天，Paul Brook 在[回复](https://lists.gnu.org/archive/html/qemu-devel/2008-02/msg00048.html)中描述了自己试改 ARM target 时遇到的错误：变量、立即数和寄存器索引很容易混淆，编译器无法及时拦住。他提出给 TCG variable 使用 opaque type；调试构建获得类型检查，生产构建仍可保持轻量。两天后，提交 [`ac56dd4812`](https://gitlab.com/qemu-project/qemu/-/commit/ac56dd48120521b530e48f641b65b1f15c061899) 合入“Add TCG variable opaque type”。

这段讨论值得保留，因为它解释了强类型 IR 的一个现实来源。类型系统不只服务优化器推导，它先帮助众多 target 的 C 前端避免传错对象。客户机寄存器编号 `rs1=5`、常量 `5` 和表示某个运行时值的 `TCGv_i64`，在机器层面都可能塞进整数；在生成器接口里，它们承担不同生命周期和语义。opaque type 把错误提前到编译期。

当前 `v11.1.0-rc0` 已经有 `TCGv_i32`、`TCGv_i64`、`TCGv_i128`、pointer 与多种 vector type，临时值也按 fixed global、global、constant、TB temporary 和 extended-basic-block temporary 区分。类型数量增长了，Paul 当时指出的风险仍在：一段 translator 写起来像普通 C，实际操作的是“未来运行时的值”，不能把生成阶段的整数与客户机执行阶段的值互换。

:::: {.quick-quiz}
`a->rs1` 与 `get_gpr(ctx, a->rs1, ...)` 的返回值为什么不能互换？

::: {.quick-answer}
前者是翻译阶段从机器码得到的寄存器编号，后者是表示客户机运行时寄存器内容的 TCG value。编号可以用于选择 CPU state 位置，TCG value才能进入运行时加法、比较和访存。
:::
::::

## 邮件列表怎样把迁移拆成可审查的决定

TCG 公告发布两周后，SH4 的 GCC 4.1.2 构建问题暴露。Christian Roue 负责复现和缩小，Alexander Graf讨论 configure workaround，Thiemo Seufer把目标指向渐进迁移。三人的身份在这条线程里分别是报告者、诊断参与者和维护经验提供者；早期邮件与 SVN 提交没有今天完整的 `Reviewed-by` 记录，本书不会倒推一个形式化 reviewer 名单。

另一个现场来自 SPARC。Blue Swirl 发送了一版 WIP 转换，说明 SPARC32 softmmu 与 linux-user 已工作，SPARC64 和 SPARC32plus 仍失败，并公开询问怎样把 32 位 target/host 上的 64 位值从 legacy op 带到 TCG load/store。Fabrice 在[回复](https://lists.gnu.org/archive/html/qemu-devel/2008-02/msg00427.html)中提醒，T2 还参与 delay slot 的 CPU state restore；他建议为 SPARC GPR 定义 TCG global，并要求 target-specific 定义与通用定义保持分区。

这段 review 没停留在“代码能不能编译”。delay slot 决定异常时恢复哪条客户机指令，TCG global 决定值能否跨 IR 段保持，通用/目标定义分区决定后续 host 与 guest 组合是否继续扩展。Blue Swirl 随后的提交从 globals、条件码、trap state 到 branch 逐步迁移，提交主题中的 “Convert ... to TCG” 连续出现，正好印证了公告承诺的渐进路线。

Paul Brook 的 ARM conversion 也被拆成 16 个提交，于 2008 年 3 月 31 日连续进入历史。拆分方式让一类语义、一类 helper 或一组寄存器变化可以单独检查。对今天的 RISC-V contributor，这种做法仍有参考价值：新增 ISA 扩展时，decode、基础整数路径、helper、CSR、异常和测试应形成能单独说明合同的 patch，而非把几千行生成代码藏进一次“大功能支持”。

## 旧引擎何时真正离场

渐进迁移不等于永久双轨。2008 年 12 月，Aurelien Jarno 的提交 [`86e840eef7`](https://gitlab.com/qemu-project/qemu/-/commit/86e840eef78d5c6882cfd2befd8571e6cd98782f) 删除 `dyngen.c` 和构建相关代码；同日提交 [`49516bc0d6`](https://gitlab.com/qemu-project/qemu/-/commit/49516bc0d622112caac9df628caf19010fda8b67) 继续清理 `dyngen-exec.h`、`tcg-dyngen.c` 与遗留宏。后一个提交记录 Laurent Desnogues 和 Aurelien Jarno 的 Signed-off-by，说明清理也经过贡献与集成分工。

从 2 月接入到 12 月删除，迁移桥存在了约十个月。这个时间跨度比“发布 TCG，替换 dyngen”一句话更能说明过程：先允许新旧语义共处，在各 target 补齐正确性，再移除兼容层。桥接代码有明确终点，避免过渡接口成为下一个永久负担。

删除 dyngen 也没有删除 TB、异常恢复或 software MMU。它移除的是“从 GCC 目标文件抽取 micro-op 片段”这条生成路径。稳定的虚拟机合同继续留在公共执行层，TCG 接管 IR 到宿主代码的部分。这种边界让后续 optimizer、host backend 和 MTTCG 可以演进，而各 target 不必重写完整机器模型。

对照 `v11.1.0-rc0`，旧桥留下的痕迹主要在历史文档和命名里，运行代码已经围绕 TCG op、helper 与 `translator_loop()` 组织。研究一项遗留字段时，若 `git blame` 最终落到 2008 年迁移提交，应先问它是否仍承担客户机可见语义；仅为兼容 dyngen 而存在的部分，可能早已在后续重构中消失。

## 迁移约束怎样沉淀成今天的接口

legacy micro-op 进入前后要形成 basic block 边界，因为 TCG 无法分析片段内部如何使用临时寄存器、是否读写 CPU state、会不会异常。迁移完成以后，这条特殊边界消失，背后的问题仍由 global、temporary 与 helper 属性表达。TCG 只有知道值活到哪里、调用能改什么，才敢让状态停留在宿主寄存器。

RISC-V target 初始化时建立 `cpu_gpr[]` 等 TCG global，它们指向 `CPURISCVState` 中的架构位置。TB 内的短计算使用 temporary，退出或 helper 边界按 liveness 结果同步。`cpu_env` 是固定 global，后端让它持续位于约定宿主寄存器，以便生成代码快速访问 CPU state。三类对象分别承载长期状态、局部计算与状态根指针。

helper 则接住难以直接展开的语义。默认 helper 可能读写 globals，也可能抛异常，调用前后需要保守同步；只有函数声明准确给出 `NO_READ_GLOBALS`、`NO_WRITE_GLOBALS` 或 `NO_SIDE_EFFECTS`，TCG 才能减少保存和重载。2008 年 legacy op 的黑盒问题，在现代接口里变成一项可以逐函数审查的副作用合同。

这项沉淀对 RISC-V 扩展开发很实用。基础整数 `addi` 适合直接生成 op，optimizer 能看见常量和死结果；复杂 CSR、浮点 corner case 或跨 CPU fence 常进入 helper。选择没有固定公式，应同时看热度、IR 长度、异常、CPU state 与后端覆盖。若一段 helper 后来成为热点，可以在保持测试与异常合同的前提下逐步改成 IR，迁移方法与早期 TCG 替换 dyngen 有相似节奏。

公共 `translator_loop()` 也延续了“可渐进接入”的思路。它规定 TB 生成生命周期，target 通过 `TranslatorOps` 提供初始化、取指、译码和结束 hook。RISC-V 可以逐项添加扩展 decoder，不必复制 TB 分配、日志、plugin、单步和 instruction counting。公共层每增加一项观测需求，各 target 通过稳定 hook 获得它，而非把同一机制散到几十个前端。

:::: {.quick-quiz}
为什么 unknown helper 会迫使 TCG 在调用边界更保守地同步 CPU state？

::: {.quick-answer}
生成器无法证明 helper 不读取或修改某个 global，也不能排除异常出口。把状态留在未声明的宿主临时位置会让 C 函数看到旧值，异常恢复也可能缺字段。准确的 helper 属性可以缩小同步范围。
:::
::::

## RISC-V 前端怎样继承这次分层

RISC-V 的机器码首先由 decodetree 生成的译码函数匹配，随后进入 `trans_*`。以 `addi` 为例，前端检查运算宽度和寄存器规则，取得源值，生成加法 IR，再按 `rd` 写回；以 `lw` 为例，前端还要编码访问宽度、符号扩展、当前 memory index 和可能的异常路径。源码入口集中在 [`target/riscv/tcg/translate.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/tcg/translate.c) 与 [`target/riscv/tcg/insn_trans`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/target/riscv/tcg/insn_trans)。

decodetree 生成的匹配只完成编码识别。`trans_*` 还要检查 CPU model 是否启用扩展、当前 XLEN 与 privilege 是否允许、virtual instruction exception 和 illegal instruction 谁优先。取指跨页时，公共 translator 也必须保留第一段成功、第二段 fault 的准确 PC。新增一条 pattern 后能调用函数，只说明入口接通，尚未证明指令实现完成。

`DisasContext` 保存本 TB 内可视为稳定的事实，如当前 XLEN、privilege、V 状态、memory index、端序和扩展配置。前端据此在翻译时选路，减少生成代码的重复检查；任何能改变这些事实的指令都要结束 TB 或更新下一次 lookup 所需状态。target 因而承担两项责任：把稳定条件变成生成选择，把会失效的条件变成清晰出口。

RISC-V x0 是验证接口的好入口。纯算术写 x0 可以丢弃结果，load 写 x0 仍要访问内存并可能异常，CSR 写 x0 仍可能改变 CSR。若通用 `gen_set_gpr()` 把“目的为零”提前成整条指令删除，后两类副作用会丢失。前端必须先生成完整语义，再只消掉允许消失的写回。

翻译状态的写回也分两类。普通算术只更新 GPR，可以继续留在当前 TB；修改 `mstatus`、`satp`、特权级或虚拟化状态后，下一条指令的 decode、memory index 和异常规则都可能改变，前端要保存新 PC 并退出。若仍在旧 `DisasContext` 中继续翻译，IR 会沿用已经失效的常量假设。

异常路径要求在副作用之前保存指令坐标。RISC-V helper 可能通过 `cpu_loop_exit` 非局部返回，`decode_save_opc()` 为恢复准确 PC 留下元数据。新增 helper 时只验证成功返回，容易漏掉 privilege failure、page fault 和 virtual instruction exception；测试要让 helper 真正从中层退出一次，再核对 `xepc` 与 `xcause`。

内存 op 把迁移后的分层表现得最完整。前端生成 `qemu_ld/st` 并附带 `MemOp` 与 `mem_idx`，公共 TCG 展开 software TLB fast path，RISC-V `tlb_fill` 负责 Sv39/H 两阶段规则，MemoryRegion 决定 RAM 或设备。任何一层都不需要回到 dyngen 的 C 片段拼接，仍能各自保留 target-specific 语义。

这里的“target”有两个方向。QEMU target/guest 是正在模拟的 RISC-V；TCG target 是生成代码要运行的宿主 ISA。当前文档专门提醒这项命名历史。一次 RISC-V guest 在 x86_64 host 上运行，会使用 RISC-V translator 与 x86_64 TCG backend；RISC-V guest 在 RISC-V64 host 上运行，则使用同一 translator 与 [`tcg/riscv64`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/tcg/riscv64) backend。前端不会因宿主变化复制一套语义。

2018 年 RISC-V guest support 与 RISC-V host backend 也是两组不同提交。Michael Clark 的 `RISC-V TCG Code Generation` 解决 guest 指令到 IR；Alistair Francis 在同年 12 月逐步加入 TCG RISC-V host 的寄存器、constraint、立即数编码、load/store、branch、prologue 和 JIT 注册。两条演进线可以独立，是 IR 解开 guest/host 组合之后的直接结果。

host backend 系列的拆分也能反过来帮助理解 TCG。先定义寄存器和 constraint，表示“哪些值能放在哪里”；再实现立即数与 relocation，表示“代码搬进 JIT region 后怎样仍然正确”；随后补 move、load/store、branch 和 out-op；最后生成 prologue并注册 JIT。若从最终 `tcg-target.c.inc` 顺序阅读，很难看出这些依赖，按提交系列重放更容易得到构建顺序。

今天添加 RISC-V guest 指令，通常无需修改 host backend，因为现有 op 已有实现或 generic fallback。只有引入新的通用 TCG op、使用后端未声明能力，或优化特定代码形状时才进入 `tcg/riscv64`。patch 说明应明确自己改的是 guest semantics、IR contract 还是 host lowering，避免 reviewer 被“RISC-V support”这一宽泛标题带到错误目录。

这也规定了定位方法。RV64 客户机结果错误，先检查 decode、`trans_*`、helper 与架构状态；同一份 IR 只在 RISC-V64 宿主出错，再检查 `tcg/riscv64` 的 constraint、lowering 和发射。若所有宿主都在某个 IR 变换后出错，问题更可能落在通用 optimizer。分层既控制代码量，也给调试提供了坐标。

一项 RISC-V 扩展进入上游时，可以按这条边界准备证据：规范版本与机器码证明 decode，正负 privilege 用例证明 translator gate，`-d op` 证明 IR/helper，跨宿主 tests/tcg 证明 guest 语义，特定 host code 用例证明后端优化。每份证据回答一层问题，reviewer 不必从最终输出猜测中间合同。

## 实验：追踪两条 RV64 指令的迁移终点

::: {.hands-on}
使用现有 [`trace-riscv-decode`](../experiments/part-02-tcg-execution-engine/chapter-08-riscv-decode/trace-riscv-decode/README.md) 实验。选择一条短路径 `addi` 和一条带特权副作用的 `hfence.gvma`，记录机器码、decodetree pattern、参数结构、`trans_*`、生成的 TCG op 或 helper、TB 终止条件以及客户机可见结果。

`addi` 用来检查类型和纯运算边界：立即数在生成阶段已经解码，源寄存器内容是运行时 `TCGv`，写 x0 应丢弃结果。`hfence.gvma` 用来检查 helper 与状态边界：扩展是否启用、当前特权与虚拟化状态是否合法、software TLB 刷新范围、是否结束 TB。两条指令都要加入负向用例，避免“译码器调用了函数”被误当成语义完整。

报告中画出 guest→IR 的路径即可，宿主反汇编作为附录证据。这样可以直接看到 2008 年迁移的终点：RISC-V 前端只表达 ISA 与 QEMU 执行合同，GCC 对象布局已经离开运行链。

再做一次 host 交叉验证。相同裸机镜像分别在 x86_64 与 RISC-V64 host 运行，比较客户机寄存器、trap 与内存结果；`-d op` 的核心语义应一致，`out_asm` 可以完全不同。如果只有一个宿主失败，沿 host constraint 和发射查找；两个都失败，再回到 decode/translator/helper。这个小矩阵能实际验证 guest/host 分离。

日志要保存优化前后 IR。前端是否生成了错误 op 看前一份，通用优化是否破坏语义看后一份，host backend 是否错误发射看反汇编。只保留最终宿主代码，会让三层错误重新混成一团，也失去 TCG 引入 IR 后最有价值的诊断边界。
:::

## 实验：用一条教学指令体会 IR 接口

::: {.hands-on}
第二个入口是 [`add-toy-instruction`](../experiments/part-02-tcg-execution-engine/chapter-08-riscv-decode/add-toy-instruction/README.md)。在隔离分支选择 RISC-V custom opcode，定义两个源寄存器、一个目的寄存器和纯整数语义。修改 `.decode` 与对应 `trans_*`，用现有 TCG op 表达计算，并在 `tests/tcg/riscv64/` 增加正常输入、x0、溢出边界和功能关闭测试。

实验有意不加入 MMIO、CSR 或新架构状态。这样 review 能集中在三类值是否分清：机器码字段和寄存器编号属于翻译阶段，`TCGv` 属于客户机运行阶段，CPU 属性决定这段 IR 能否生成。若误把 `rs1` 编号当作运行时值，opaque type 和 API 应尽早暴露问题。

教学编码不得描述成标准 RISC-V 扩展，也不应发往上游。它的产物是一份接口练习：补丁要小，生成文件与源文件分开，扩展关闭必须产生 illegal instruction。完成后回看 Paul Brook 2008 年的类型建议，会发现那次 review 仍在保护今天的新 target 代码。

实验补丁可以按四步拆分：先加入负向 decode 测试，证明旧 QEMU 会 illegal；再加入 pattern 与参数提取；第三步实现 `trans_*` 和 CPU 属性；最后加入执行、x0 与边界测试。每一步都能构建，reviewer 可以区分编码错误、接入错误和语义错误。这种渐进交付延续了 TCG 替换 dyngen 时的风险控制，却完全落在当前 RISC-V 工具链里。

若希望观察 helper 边界，可为教学属性再加一条仅用于本地的低频变体：直接 op 与 helper 实现相同纯函数，比较 IR、globals 同步和 host code。两者结果应一致，翻译时间与代码尺寸不同。实验结束后不保留第二套实现，避免教学分支形成无维护价值的重复路径。
:::

## 小结

TCG 的诞生包含三项同时发生的决定：QEMU 自己掌握运行时代码生成；用强类型 IR 分隔 guest 语义与 host 发射；保留 legacy micro-op 桥，让已有目标逐步迁移。邮件中的 GCC 故障、opaque type 建议和 SPARC WIP 都在解释这些决定的边界，超出这条因果线的历史细节留在研究账本。

2008 年底 dyngen 删除后，RISC-V 等后来目标能够直接进入统一 IR。下一章沿一条 RV64 指令继续向下，回答 IR 为什么值得存在：它不只减少 guest×host 的实现组合，还承载值的类型、生命周期、副作用与精确异常合同。
