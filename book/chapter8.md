# RISC-V 指令译码与语义实现

打开 `target/riscv/insn32.decode`，映入眼帘的是一组像指令手册的位图：哪几位是 `rs1`，哪几位是 `rd`，立即数怎样拼接，opcode 与 funct 怎样固定。构建过程把这些声明生成译码器，运行时再调用 `trans_addi`、`trans_lw` 或 `trans_hfence_gvma`。这个结构让新增扩展显得很顺手，也容易诱使人漏看后半段：匹配到位模式只是开始，扩展是否启用、当前特权是否允许、异常值怎样报告、结果按 XLEN 怎样截断，才构成完整指令语义。

本章沿一条 RISC-V 指令从二进制走到 TCG IR，再沿一次非法执行退回 trap。我们只使用 RISC-V 例子，并把目标版本固定在 QEMU `v11.1.0`，当前源码事实锚定 `v11.1.0-rc0` 的 `eca2c16212ef9dcb0871de39bb9d1c2efebe76be`。

## 本章目标

- 理解 decodetree 的 field、argument set、format、pattern 与 overlap group；
- 跟踪取指、16/32 位长度判断、生成译码器和 `trans_*` 调用；
- 判断一段 RISC-V 语义适合直接生成 TCG op，还是进入 helper；
- 处理扩展检查、特权检查、x0、XLEN、精确异常与可重启指令；
- 从 patch 系列辨认“能译码”和“完整接入一项 ISA 扩展”的差别。

## 译码之前，先要安全地拿到指令

RISC-V 基础指令通常是 32 位，C 扩展加入 16 位压缩指令，架构编码还为更长指令保留空间。翻译器先取得最初的半字，根据低位判断长度，再决定是否读取后续部分。这个过程不能直接把客户机 PC 转成宿主指针后解引用，因为取指受客户机页表、执行权限、PMP 和两阶段转换约束，指令还可能跨页。

假设 PC 在页尾倒数两字节，低位表明这是 32 位指令。第一页可执行，第二页没有映射，正确结果是对当前 PC 报取指 page fault。若实现一次性读取四字节，可能先访问无效宿主地址；若只校验第一页，可能把无权读取的第二页内容送进译码器。异常发生在哪一步、`xepc` 和 fault address 写什么，都由 RISC-V 规范约束。

`target/riscv/tcg/translate.c` 中的取指和 `decode_opc` 一类路径把这项工作放在 TB translator 内。翻译上下文保存当前 PC 与当前指令长度，成功翻译后才推进；失败时生成非法指令或取指异常退出。这里的“当前”不能被下一条指令提前覆盖，否则异常回溯会把 trap 归到错误 PC。

把跨页取指和 decodetree 分开看，有助于缩小职责。decodetree 接受已经形成的 opcode，负责位模式与参数提取；它不替代 SoftMMU，也不知道客户机页面权限。取指层保证字节合法，生成译码器保证编码匹配，翻译函数保证体系结构语义，三层各自有失败方式。

## 声明式译码解决了哪类重复

手写大 switch 并非不能工作。问题在于 RISC-V 大量指令共享 R、I、S、B、U、J 格式，扩展又复用相同字段。每个 case 重复掩码、移位、符号扩展，很容易让两个本应相同的立即数提取出现细微差异。decodetree 把位布局写一次，生成 C 匹配和参数填充，`trans_*` 聚焦语义。

[`docs/devel/decodetree.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/devel/decodetree.rst) 是语法入口，[`scripts/decodetree.py`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/scripts/decodetree.py) 是生成器。RISC-V 的 [`target/riscv/insn32.decode`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/insn32.decode) 先定义 `%rs1`、`%rs2`、`%rd` 与多种立即数字段，再定义 `&r`、`&i` 等 argument set，接着用 `@r`、`@i` 表示共享 format，最后写出 `addi ... @i` 一类 pattern。

field 描述从哪几位提取值，还能通过函数做拼接或移位；argument set 定义翻译函数收到的有名参数；format 将位布局与参数集组合；pattern 固定识别位并选择 format。生成器验证位覆盖、重叠与参数一致性，许多错误因此在构建时暴露，不必等到客户机执行罕见编码。

:::: {.quick-quiz}
Format 与 Pattern 为什么要分开？

::: {.quick-answer}
Format 描述一族指令共享的位布局和参数结构，Pattern 再固定 opcode、funct 等识别位。多个指令可以复用同一套字段提取，修改立即数拼接时也不必逐个复制。Pattern 仍保留每条指令的编码身份，两者分开后，重复和差异都更容易审查。
:::
::::

## overlap group 不是逃避冲突检查

有些编码需要按附加条件解释，或者规范明确让一个更具体的 pattern 覆盖通用 pattern。decodetree 支持 overlap group 与有顺序的选择，但它不应成为“生成器报重叠就包起来”的消音器。使用 overlap 前要证明优先级来自架构规则，翻译函数还可能需要检查扩展启用状态。

RISC-V 的 `ori` 与某些预取提示提供了有趣例子。当前 `insn32.decode` 注释写明，特定 `rd=x0` 的 CBO prefetch 编码仍按 `ori` 处理，没有单独译码。生成器有能力匹配这些编码，架构却特意把提示放进兼容空间，让未实现提示的处理器仍可执行等价的无可见效果路径。这个事实提示我们，位模式更具体不意味着一定要建新 `trans_*`。

生成顺序同样会演进。提交 [`b79f944e09`](https://gitlab.com/qemu-project/qemu/-/commit/b79f944e09) 调整 decodetree，在推断 format 前先确认 argument set，提交说明指出，若不先确认参数集，推断可能得到不正确结果。这不是 RISC-V 指令语义修复，却会影响所有使用生成器的目标，说明声明式工具本身也属于编译链，需要单元测试和兼容意识。

## 从 `addi` 看一条短路径

`addi` pattern 使用 `@i`，生成参数结构包含符号扩展后的立即数、源寄存器和目的寄存器。生成译码器匹配后调用 `trans_addi(DisasContext *, arg_addi *)`，翻译函数取得 `rs1` 的 TCG 值，加上立即数，再写回 `rd`。运算可由少量 TCG op 表达，不需要 C helper，优化器也能在源为常量或目的为 x0 时进一步处理。

这条看似平直的路径仍包含 RISC-V 细节。立即数是 12 位有符号值，解码字段必须正确扩展到目标运算宽度；RV64 上普通 `addi` 按 XLEN 运算，`addiw` 则截到 32 位再符号扩展；读 x0 永远得到零，写 x0 丢弃结果。若把这些规则全推给通用 TCG op，前端会失去语义；若每条指令都调用 helper，IR 优化和寄存器分配又看不到简单关系。

当前翻译器为 32 个整数寄存器建立 `cpu_gpr[]`，同时对零寄存器使用特殊值或写回辅助逻辑。这样做避免每次读写都访问 `env` 数组，也允许宿主寄存器分配。写 x0 时不产生体系结构副作用，但指令的其他副作用仍要保留，例如 load 到 x0 仍然必须访问内存并可能 fault，不能因为结果丢弃就删除整个指令。

这正是“按语义优化”和“按语法优化”的差别。`addi x0,x0,0` 可以成为真正的 nop；`lw x0,0(a0)` 不能成为 nop，因为地址转换、权限检查和 MMIO 读取都可见。翻译函数应表达完整副作用，优化器只能在证明安全时删除纯计算。

## 从 `lw` 看访存边界

`lw` 也使用 I 型格式，立即数与 `rs1` 形成客户机虚拟地址。翻译函数选择 32 位 load、符号扩展语义和当前 memory index，再生成 `qemu_ld` 类 TCG 内存操作。IR 后端不会直接把它当宿主普通 load，因为客户机地址还要经过 SoftMMU，访问可能落到 RAM、ROM、MMIO 或触发异常。

RISC-V 数据端序、对齐规则、当前特权级和虚拟化状态会影响 MemOp 与 `mem_idx`。当前 `DisasContext` 保存 `mo_endianness`、`priv`、`virt_enabled`、地址 XLEN 等信息，翻译时把稳定状态折进 IR。2026 年提交 [`56db2b7eac`](https://gitlab.com/qemu-project/qemu/-/commit/56db2b7eac) 实现由 `mstatus` MBE/SBE/UBE 控制的运行时数据端序，邮件 [`20260527201348.29511-3-philmd@linaro.org`](https://lore.kernel.org/qemu-devel/20260527201348.29511-3-philmd@linaro.org/) 展示了该系列。一个 load 的语义由此不再只看 opcode，还要看当前特权态对应端序位。

访存结果写 x0 仍保留访问，store 更显然不能因源寄存器为 x0 而消失。原子指令还带 `aq`、`rl` 位，需要生成正确的内存序。decodetree 负责把两位提取到 `arg_atomic`，翻译函数负责把它们映射为 TCG barrier 与原子操作，SoftMMU 和宿主后端再兑现语义。位提取只是整条责任链的第一环。

## DisasContext 是 TB 内的已知事实

`DisasContext` 不是 `CPURISCVState` 的复制。它保存翻译当前 TB 时可视为稳定的事实，例如 XLEN、当前特权级、虚拟化状态、扩展配置指针、浮点与向量状态摘要、内存索引、端序和当前指令长度。翻译函数读这些值决定生成哪条路径，不必每条指令都在运行时重新读取 `env`。

把状态放进 context 能减少生成代码检查，前提是状态变化会终止 TB 或使旧 TB 不再匹配。写某个影响地址转换或浮点舍入模式的 CSR 后，若继续执行按旧 context 生成的后续指令，结果会错误。因此 CSR 翻译常在写入后结束块，或者明确更新 context 中已知值。注释中“写系统寄存器会退出 TB，所以已缓存的 FRM 无需手工重置”就是这类局部不变量。

context 也控制优化的保守程度。它知道 `vstart` 是否为零、`vl` 是否等于最大值，向量翻译可省去部分运行检查；一旦指令可能改变这些状态，就要更新已知条件或结束块。缓存越精细，生成代码越快，维护不变量的负担越大。reviewer 通常会追问：这个状态从哪里初始化，哪条指令改变它，变化后怎样阻止旧假设泄漏。

作者据此推断，`DisasContext` 可以当作 TB 级证明环境。每个布尔值都在宣称“本 TB 后续翻译可假定某事实”，代码必须给出建立和失效路径。这个说法是解释模型，不是上游术语，却能帮助审查新增字段。

## 扩展检查不能只放在 CPU 属性层

CPU realize 已经校验扩展组合，为何 `trans_*` 里仍常见 `REQUIRE_EXT(ctx, RVH)`？因为某条编码是否可执行，不只取决于型号是否支持，还可能受当前模式、动态 enable 位和扩展版本影响。译码器匹配位模式后，翻译函数要判断当前执行环境，失败则返回 false 让非法指令路径接管，或生成规定的 virtual instruction exception。

以 H 扩展 load/store 指令为例，`trans_hlv_b`、`trans_hsv_w` 等先要求 RVH，再由公共 helper 检查特权与虚拟化条件，最终以特殊 MMU index 访问 guest 地址空间。`hfence.gvma` 与 `hfence.vvma` 还要根据当前虚拟化状态、`mstatus.TVM` 等规则决定非法指令还是虚拟指令异常。只在 decode 文件里看见 pattern，无法判断这些条件。

扩展依赖也会跨文件。CPU 属性层保证一组静态能力合理，翻译函数保证当前指令允许执行，CSR 层保证控制位访问合法，迁移层保证状态可保存，测试层验证边界。新增一个 `REQUIRE_EXT` 能阻止未启用时误执行，却不等于扩展已经完整接入。

:::: {.quick-quiz}
为什么 pattern 已经匹配，`trans_*` 仍可能返回 false？

::: {.quick-answer}
位模式只证明 opcode 形状吻合。当前 CPU 可能未启用该扩展，XLEN 不合要求，特权级或虚拟化状态也可能禁止执行；重叠编码还可能交给另一个 decoder。返回 false 让译码链继续或走非法指令处理，避免把“编码存在”误作“当前合法”。
:::
::::

## 特权错误与虚拟指令异常要分清

H 扩展引入 virtual instruction exception，用于某些在虚拟化环境中应由更高层处理的指令。它和普通非法指令看起来都发生在译码执行阶段，客户机看到的 cause 却不同，hypervisor 的处理策略也不同。翻译上下文中的 `virt_inst_excp` 等状态帮助相关检查选择正确出口。

如果实现图省事，把所有权限失败都调用 `gen_exception_illegal`，简单裸机测试可能通过，嵌套虚拟化或 guest supervisor 才会暴露错误。异常类型属于指令语义，不能在后续 trap handler 里靠猜测修补。翻译函数知道是哪条规则失败，最适合决定异常类别并记录当前 opcode。

异常值还要精确。非法指令 trap 的 `tval` 是否包含指令位，取指 fault 的地址是什么，地址未对齐的目标值是什么，规范都有条件。生成异常前应先保证 PC 和 opcode 仍对应当前指令。TB 内预取下一条、提前推进 PC 等优化，不能破坏可报告状态。

## CSR 指令展示了 helper 边界

`csrrw` 编码本身很规则，真正复杂的是 CSR 查找、读写权限、副作用和别名。CSR 编号由立即数字段给出，当前特权、扩展与虚拟化状态决定是否存在及能否访问；读可能返回动态计时器，写可能触发 TLB flush、改变中断或结束 TB。把所有逻辑展开成 TCG op，会复制 CSR 表和大量条件。

RISC-V TCG 因而在 `target/riscv/tcg/csr.c` 维护 CSR 操作描述，翻译路径通过 helper 或生成辅助函数执行访问。helper 的调用边界让复杂 C 逻辑可复用，也方便集中实现权限。代价是调用前后要同步参数和结果，优化器看不到内部副作用，只能保守处理。

即便使用 helper，翻译函数仍可做结构优化。例如 `csrrs` 的源为 x0 时不写 CSR，只读；目的为 x0 时某些指令可以省掉返回值保存，但 CSR 读取本身若有副作用，仍须按规范处理。需要在 CSR 描述中知道读写属性，不能只看寄存器编号。

:::: {.quick-quiz}
helper 为什么可能阻碍跨指令优化？

::: {.quick-answer}
helper 对优化器通常是外部调用，可能读写 CPU 状态、内存或控制流。没有精确副作用摘要时，调用前后要保存临时值，优化器也不能安全地把计算跨过去传播、合并或删除。简单纯运算更适合直接生成 IR，复杂低频且副作用集中的语义才值得 helper 化。
:::
::::

## helper 与 TCG op 的选择标准

判断标准不应是“代码长就 helper”。先看频率与数据流：整数加法、位运算、常见分支位于热路径，直接 IR 能让常量传播和寄存器分配发挥作用；复杂 CSR、浮点特殊情况、向量大循环或罕见特权操作，helper 可以缩短翻译时间与生成代码体积。再看精确异常：helper 内访问客户机内存时，需要正确的 return address，让异常恢复到调用指令。

还要看宿主能力。TCG IR 提供某项操作，后端可能原生实现，也可能展开；前端不用为每种 host 决策。若前端直接调用目标 C helper，所有 host 都承担 ABI 调用。对于执行频繁、容易由 IR 表达的语义，后者通常不划算；对包含大表查找或复杂循环的指令，生成大量 IR 反而会膨胀代码缓存。

向量指令特别能体现折中。一条客户机向量指令处理多少元素由 `vl`、SEW、LMUL 和 mask 决定，全部展开成每元素 IR 会让 TB 体积随运行参数失控。QEMU 常用向量 helper 在 C 循环中处理元素，同时传入描述字和环境。这样牺牲跨元素 JIT 优化，换来稳定翻译延迟和较小宿主代码。

作者推断，TCG 前端优化的是“模拟器总成本”，不等同于传统编译器只优化生成代码运行速度。翻译延迟、代码缓存、helper ABI、异常恢复和宿主覆盖都要计入。这个判断来自代码结构与性能约束，具体指令仍需 benchmark，不能按规则机械决定。

## 可重启指令让状态提交更谨慎

普通整数指令要么完成，要么在副作用前 fault，状态边界相对清楚。向量访存可能处理中途遇到异常，RISC-V 用 `vstart` 指示重启位置。helper 必须按元素顺序更新可见状态，发生 fault 时保存正确 `vstart`，恢复后从未完成元素继续，不能重复已经对 MMIO 产生副作用的访问。

原子指令也要求谨慎。load-reserved/store-conditional 维护 reservation，异常、中断和其他写入会影响成功条件；AMO 要保持规定原子性和 `aq/rl` 内存序。用几个普通 load/store TCG op 拼起来，可能在 MTTCG 下被另一 vCPU 插入。前端需要选择专门原子 op 或 helper，让公共 TCG 和宿主后端知道不可分割边界。

这些例子说明，指令语义并非只有最终寄存器值。访存次数、顺序、异常时已提交的状态、重启点都可被客户机观察。实验若只比较最终数组，很可能漏掉 MMIO 重复写或异常 cause 错误。

## 扩展 patch 应该怎样审

一个完整扩展通常包含 CPU 属性与依赖、decode pattern、`trans_*` 或 helper、CSR、反汇编、迁移状态、文档和测试。各扩展需求不同，不必强求文件数量，但审查者会检查规范版本、保留编码、RV32/RV64 条件、扩展互相依赖和非法路径。只提交一个能跑 happy path 的翻译函数，很难证明实现完成。

提交 [`b52d49e97f`](https://gitlab.com/qemu-project/qemu/-/commit/b52d49e97f) 引入 ratified Zacas 扩展的 `amocas.w/d/q`，邮件 [`20231207153842.32401-2-rbradford@rivosinc.com`](https://lore.kernel.org/qemu-devel/20231207153842.32401-2-rbradford@rivosinc.com/) 可追踪审查。随后 Zabha 系列提交 [`be4a8db7f3`](https://gitlab.com/qemu-project/qemu/-/commit/be4a8db7f3) 与 [`d34e406602`](https://gitlab.com/qemu-project/qemu/-/commit/d34e406602) 增加 byte/halfword AMO 与 CAS，Message-ID 属于同一线程 `20240709113652.1239-*`。沿系列看，会发现编码、原子 helper、扩展属性与测试必须一起协调。

规范会淘汰旧编码。提交 [`b638f679fe`](https://gitlab.com/qemu-project/qemu/-/commit/b638f679fe) 移除 obsolete `sfence.vm`，对应系列邮件 [`20250205-b4-ctr_upstream_v6-v6-1-439d8e06c8ef@rivosinc.com`](https://lore.kernel.org/qemu-devel/20250205-b4-ctr_upstream_v6-v6-1-439d8e06c8ef@rivosinc.com/)。同一时间加入新指令，删除旧入口，是防止实现继续接受规范已不承诺的编码。兼容性不等于永远执行一切历史草案，QEMU CPU 型号与规范版本要给出清晰边界。

## 保留编码修复为何特别危险

RISC-V 向量编码空间密集，mask 位和字段组合中存在 reserved 情况。实现若把保留编码当合法指令，普通程序未必触发，编译器或未来扩展却可能依赖 trap 行为。提交 [`8539a1244b`](https://gitlab.com/qemu-project/qemu/-/commit/8539a1244b) 修复 RVV 未掩码指令的 reserved encoding，邮件 [`20250408103938.3623486-11-max.chou@sifive.com`](https://lore.kernel.org/qemu-devel/20250408103938.3623486-11-max.chou@sifive.com/) 说明问题来自向量规范。

这种 bug 很适合用负向测试捕捉：手工发射保留机器码，期待 illegal instruction，而不是只让编译器产生合法指令。decodetree pattern 若写得过宽，翻译函数必须补条件；更好的方式是在编码层能表达时收紧 pattern，使非法值根本不进入语义函数。选择哪层，取决于条件能否只由位模式决定。

作者从这类修复推断，review decode 文件时应同时问“它会匹配什么”和“它意外多匹配什么”。新增指令的 happy path 很直观，编码空间的补集才常藏兼容问题。这个推断适用于实验设计，不能替代逐条规范核对。

## 反汇编器与执行译码器为何可能分叉

QEMU 的 disassembler 面向日志和调试，TCG decoder 面向执行，它们可能使用不同实现或表。新增执行支持却忘记反汇编，客户机仍能跑，`-d in_asm` 会显示 `.word`，调试体验明显变差。提交 [`9273cda722`](https://gitlab.com/qemu-project/qemu/-/commit/9273cda722) 补上 CBO 指令的反汇编，提交说明直言先前遗漏，邮件 [`20260519204714.1376551-1-daniel.barboza@oss.qualcomm.com`](https://lore.kernel.org/qemu-devel/20260519204714.1376551-1-daniel.barboza@oss.qualcomm.com/) 提供证据。

执行与显示分开也有合理性。执行译码需要扩展启用和特权语义，反汇编常在缺少完整 CPU 状态时尽量展示编码；两者性能目标不同。工程上要通过共享 opcode 定义、测试或 review checklist 防止漂移，而不是强迫它们调用同一个函数。

实验报告最好同时保存原始机器码、objdump 结果和 QEMU `in_asm`。三者不一致时，先判断是工具版本、扩展开关还是实现遗漏，不能因为程序执行正确就忽略可观测工具。

## 生成文件不要手工改

decodetree 输出通常由 Meson 构建规则生成，源文件是 `.decode`。直接修改生成的 C，下一次构建会覆盖，diff 也难审。新增指令应编辑源声明和 `insn_trans`，让生成器在不同构建目录稳定复现。实验中的 toy instruction 也要遵守这条路径。

生成步骤让错误更早暴露，但它不是规范验证器。位宽覆盖正确，不代表 opcode 选择符合 RISC-V 手册；参数名一致，不代表立即数符号语义正确。审查仍要把 pattern 与规范表格逐位对齐，再用正负向机器码测试。

当前 RISC-V TCG 文件已在提交 [`d45b9bc655`](https://gitlab.com/qemu-project/qemu/-/commit/d45b9bc655) 后移入 `target/riscv/tcg/`，邮件 [`20260703180538.3346781-5-daniel.barboza@oss.qualcomm.com`](https://lore.kernel.org/qemu-devel/20260703180538.3346781-5-daniel.barboza@oss.qualcomm.com/) 说明这是为了把 TCG-only 代码与 accelerator 共享代码分开。查旧提交时路径可能是 `target/riscv/translate.c`，使用 `git log --follow` 或按符号搜索，不要因目录变化误判历史从 2026 年才开始。

## 构建系统怎样把 `.decode` 变成 C

Meson规则调用 `scripts/decodetree.py`，把一个或多个decode源生成到构建目录，再由RISC-V translator包含。生成内容包含参数结构、field提取函数和匹配决策树，源树不需要提交大段机械C。增量构建若没有重新运行生成器，通常是依赖声明或构建目录问题，不能靠手改产物解决。

decodetree会在生成阶段检查pattern位数、字段重叠、argument set一致性和无法解释的冲突。错误位置指向 `.decode` 行，比运行时落到错误 `trans_*` 更容易定位。实验加入toy instruction后，应先单独运行生成命令或构建目标，保存生成器诊断，再进入执行测试。

多个decode文件可通过decoder列表按条件尝试。标准基础、扩展与厂商自定义编码可能使用不同入口，`DisasContext::decoders` 让CPU模型决定当前启用集合。顺序就是语义的一部分：若自定义decoder过宽并排在标准前，会抢走标准编码；标准decoder返回false后是否继续，也取决于生成函数合同。

生成C只是内部产物，调试时可以读，却不宜在正文引用固定行号。生成器版本、pattern加入和优化都会改变布局，稳定证据应指向 `.decode`、`trans_*`与构建规则。若要解释匹配性能，可用当前tag产物作为快照，并明确它不是手写API。

## 16 位压缩指令如何复用语义

RISC-V C扩展把常见操作压成16位，寄存器编码与立即数布局不同，展开后的体系结构效果往往等价于32位基础指令。`insn16.decode`负责压缩位模式，`trans_*` 可以调用共同生成helper，避免为 `c.addi`复制整套算术语义。

复用前要核对限制。压缩指令可能禁止某些寄存器为零、立即数不能为零，RV32与RV64下同一编码还可能代表不同操作。decoder若只提取参数再直接调用基础实现，必须在入口补足压缩编码的保留条件。否则合法基础语义会错误接受非法压缩机器码。

指令长度影响PC推进、branch target和异常附加值。翻译上下文保存 `cur_insn_len`，正常结束按2或4增加；异常PC仍指向指令起点。混合16/32位流中，硬编码 `pc += 4` 的bug会在第一条压缩指令后错位，后续日志看起来像译码器随机失效。

跨页测试也应覆盖16位起点。32位指令从页尾倒数2字节开始需要第二页，16位指令放同一位置不需要。两条机器码只改低位即可让取指路径分叉，适合验证实现是先判断长度再安全取后半，而非总读四字节。

## XLEN、操作宽度和地址宽度不是一个值

当前 `DisasContext` 同时有 `xl`、`ol`、`address_xl`、`addr_xl` 等字段。RV64通常让它们相同，H扩展、MPRV或未来RV128支持会让差异显现。`get_xlen()`描述当前整数寄存器操作宽度，`get_olen()`描述某项操作宽度，地址形成还受effective mode控制。

word指令在RV64上按32位计算并符号扩展到64位，不能简单换成i32 temp后忘记写回扩展。shift amount mask也按操作宽度选择。地址计算若用32位模式，需要按规范符号或零扩展，再进入页表canonical检查。把所有地方统一用 `target_ulong` 可编译，不代表语义准确。

2026 年类型整理系列修复多项宽度。提交 [`5aed8ac67e`](https://gitlab.com/qemu-project/qemu/-/commit/5aed8ac67e) 修正PC与load reservation/value为64位，邮件 [`20260520125406.28693-4-anjo@rev.ng`](https://lore.kernel.org/qemu-devel/20260520125406.28693-4-anjo@rev.ng/) 说明这些字段映射为TCG globals；[`c4e6bc6385`](https://gitlab.com/qemu-project/qemu/-/commit/c4e6bc6385) 修正GPR与GPRH尺寸。上游事实说明C字段类型会直接约束TCG global，尺寸“碰巧够用”在新XLEN或扩展下会失效。

作者推断，新增翻译代码时应先写出输入宽度、计算宽度、写回宽度和地址宽度四项，再选TCG type。这个步骤比看函数邻近代码照抄更可靠，特别是word、向量元素和hypervisor load/store。

## 控制流指令如何结束 TB

`jal` 的目标由PC与立即数形成，link寄存器写入下一指令地址；`jalr` 还要清目标最低位，并可能触发指令地址未对齐；conditional branch产生taken与fall-through两条路径。翻译函数既计算RISC-V结果，也要告诉TB框架哪些出口可direct chaining。

固定目标仍需canonical和对齐检查。C扩展启用时指令最小对齐为2字节，未启用时规则不同；目标在同页不代表一定合法。若异常可能在branch发生，link寄存器副作用提交顺序要符合规范，不能先写回再发现target misaligned，除非架构明确允许。

间接 `jalr` 目标运行时才知道，生成代码写PC并返回lookup。常见返回序列可被jump cache加速，但译码层不应猜宿主函数调用语义。Zicfilp等控制流完整性扩展还会让 `jalr` 更新“期望landing pad”状态，当前 `DisasContext`保存相关flag，目标TB key也要反映。

提交 [`966f3a3895`](https://gitlab.com/qemu-project/qemu/-/commit/966f3a3895) 实现Zicfilp `lpad`与branch tracking，邮件 [`20241008225010.1861630-8-debug@rivosinc.com`](https://lore.kernel.org/qemu-devel/20241008225010.1861630-8-debug@rivosinc.com/) 展示同一系列。新增控制流扩展会影响译码、TB状态和异常，远超一条pattern。

## 浮点译码为何保存舍入模式缓存

浮点指令编码含静态rounding mode，也可选择动态 `frm`。每条指令都调用helper设置宿主softfloat状态会重复，translator在 `DisasContext::frm` 缓存上一条已安装模式，相邻相同模式可以复用。写 `fcsr/frm` 的CSR指令会结束TB，保证缓存不跨状态变化。

这种优化依赖两个不变量：所有改变FRM的路径都退出或更新context，所有浮点helper使用同一环境状态。新增CSR别名若漏掉TB结束，后续指令可能按旧舍入执行。review不能只看 `trans_fadd`，还要查CSR写路径和异常flag提交。

NaN-boxing也体现前端与helper分工。窄浮点值存入宽寄存器要填高位，读取时非法boxing按规范产生canonical NaN。直接IR可完成部分位处理，复杂算术交给softfloat helper。优化器不能把boxing mask当无用高位删掉，因为客户机后续可按更宽格式观察。

浮点异常flag常是累积CSR副作用。目的寄存器为无关值时，运算仍可能设置flag，不能像纯整数死写一样删除。helper属性必须说明写环境，否则optimizer会误判。

## 向量译码要控制生成规模

向量指令的SEW、LMUL、mask、tail/mask agnostic策略来自 `vtype`与编码，`vl/vstart`又是运行状态。`DisasContext`缓存能在TB内证明的条件，例如 `vstart_eq_zero`、`vl_eq_vlmax`，翻译函数据此选择较短helper路径。状态不确定时保守生成运行检查。

每元素展开IR会让一条指令随VL产生巨大TB，也无法在翻译时知道动态VL，因此多数向量语义调用helper循环。descriptor编码元素宽度、组倍数和策略，helper读取向量寄存器内存。descriptor位分配属于内部合同，改变时所有调用和helper必须同步。

向量访存可能在第k个元素fault，前k个已完成，`vstart`记录重启点。helper每轮提交到哪个时机、mask-off元素是否访问内存、fault-only-first怎样更新VL，都要逐规范实现。最终数组正确不足以验证，需在页边界让中间元素fault并恢复。

提交 [`8539a1244b`](https://gitlab.com/qemu-project/qemu/-/commit/8539a1244b) 修复RVV保留编码，就是向量条件散布的例子。审查新增向量指令时，应同时列合法SEW/LMUL组合、mask限制、overlap规则、vstart和异常提交，不按标量模板扩写。

## 原子译码与 aq/rl 不能丢在参数层

`@atom_ld`、`@atom_st` format提取 `aq`、`rl`，还对load形式固定 `rs2=0`。pattern匹配后，翻译函数检查A或细分扩展，选择访问宽度与原子op。`aq/rl`最终要映射TCG内存序，不能只保留在参数结构却未使用。

LR/SC维护reservation，SC返回成功或失败，其他store、trap和context switch可能清reservation。AMO/CAS则在一个原子事务中读改写。host缺少宽原子时可能进入serial helper，语义路径与常见直接op不同，测试要覆盖。

Zacas的 `amocas.q` 在RV64涉及双寄存器/128位值，对寄存器对齐和扩展条件有附加规则。新增byte/halfword AMO的Zabha又改变符号扩展与subword atomic。沿 `b52d49e97f`、`be4a8db7f3`、`d34e406602` 的系列查看，能看到扩展不是复制 `amoadd.w` 改宽度。

内存序错误通常只在多hart litmus出现。单线程验证返回值是必要起点，不能证明 `aq/rl`。实验可以把toy instruction限定纯整数，避免为了演示decodetree意外引入原子与并发责任。

## helper 声明如何进入生成器

RISC-V helper原型集中在 `target/riscv/helper.h`，宏参数描述返回、参数和flag，构建生成 `helper-gen`、`helper-proto` 与helper info。translator调用 `gen_helper_*`，TCG得到类型和副作用摘要；C实现位于 `op_helper.c`、`cpu_helper.c`、向量或浮点文件。

原型类型必须与TCG temp一致。把64位CSR值声明成 `tl` 在当前RV64可能工作，跨构建或字段扩宽会暴露；pointer与guest address也不能混。2026 年类型修复系列大规模替换 `target_ulong`，说明helper边界是宽度审计重点。

helper flags如 `TCG_CALL_NO_WG`、`NO_RWG` 表达是否读写global，声明过强会允许危险优化，声明过弱则增加同步。新增helper应从实现实际访问出发，不按相似名字复制。可能 `cpu_loop_exit` 的helper还涉及noreturn和异常恢复，不能标成普通纯函数。

查看 `-d op` 时，helper通常显示call名称与参数。实验应核对调用前是否写回它要读取的CPU state，返回后是否重新加载被写global。寄存器分配产生的move体现了ABI与副作用合同，并非随意增加的开销。

## 多 decoder 与厂商扩展的治理

QEMU RISC-V支持若干厂商扩展，独立 `.decode`和 `trans_x*` 能减轻标准文件拥挤。CPU型号决定启用哪些decoder，custom opcode空间仍可能和别的厂商定义重叠。只要不会在同一CPU同时启用，编码可以共存；模型配置若允许冲突集合，就必须定义优先或拒绝。

厂商扩展不能借通用CPU默认为所有用户开启。它可能与标准未来版本冲突，迁移也需要固定。类型和属性层限定适用型号，decode层再检查扩展，形成双重防线。实验toy opcode也应挂独立教学属性，不污染 `max`默认。

当非标准实现后来被标准替代，兼容策略要看CPU模型。旧具名型号可能继续接受历史编码，新型号遵从ratified规范；简单全局删除会破坏既有客户机，永久全局保留又占用标准空间。邮件列表通常要求说明真实硬件、规范版本和迁移影响。

作者推断，decoder列表也是ISA命名空间治理工具，不只是性能优化。它把“哪些编码解释器可以同时存在”绑定到CPU模型，review应检查组合，而不只检查单文件pattern。

## 测试矩阵至少覆盖四个维度

第一维是编码：每条合法pattern的代表值、字段边界和保留编码。第二维是能力：扩展开、关，以及依赖缺失。第三维是执行上下文：RV64的相关XLEN、特权、V状态和动态enable。第四维是结果：寄存器/内存、异常cause与副作用顺序。

编译器只生成它认为合法的编码，负向测试要用 `.insn`、`.word`或字节数组。反汇编器可能拒绝显示保留码，原始hex必须保留。测试期待illegal时，还要确认trap handler没有误把其他fault当通过，例如测试页本身不可执行。

差分测试可以让同一RISC-V程序在QEMU TCG与可用的参考实现/硬件运行，比较架构状态。硬件型号未实现某扩展时不能比较；KVM复用同一宿主硬件，作为oracle缺少独立性。对规范边界，手工预期和上游架构测试套件更可靠。

性能测试另行进行。译码新增不会影响已生成TB执行，主要影响冷翻译；helper选择影响热执行和代码体积。把两者混在一次启动耗时里，无法说明方案好坏。

## 从 patch v1 到 vN 看审查收敛

扩展系列的cover letter通常声明规范版本、依赖和测试，patch拆为CPU config、decode/translate、CSR、disas、tests。v2以后可能因reviewer指出保留码、命名或迁移问题而重排。最终commit正文未必保留所有被否决方案，Message-ID线程能补足。

以Zicfilp/Zicfiss系列为例，提交 [`f06bfe3dc3`](https://gitlab.com/qemu-project/qemu/-/commit/f06bfe3dc3) 实现Zicfiss指令，邮件 [`20241008225010.1861630-17-debug@rivosinc.com`](https://lore.kernel.org/qemu-devel/20241008225010.1861630-17-debug@rivosinc.com/) 位于较长系列后段。只读这一个commit会漏掉CPU属性、CSR和测试，应该按同一Message-ID前缀重建系列。

正文引用审查结论时，要标明谁明确说了什么。若reviewer要求用共同format，是上游陈述；若作者观察v1手写mask、v4改为field后推断“维护性推动重构”，应标成推断。事实和解释分开，后续规范变更时容易更新。

正式 `v11.1.0` tag发布后，还应检查rc0期间新增指令是否改变默认CPU模型。译码文件存在pattern不代表最终版本默认可用，实验命令要固定 `-cpu`属性并输出ISA能力。

## 设计一条 toy instruction 时刻意保持边界

教学指令选择custom opcode、两个源寄存器和一个目的寄存器，语义只做纯整数变换，可以让实验集中于decode链。不要读取MMIO、改变特权或使用未定义CSR，否则需要额外异常和迁移设计。编码文档明确位图，避免与当前CPU已启用厂商decoder冲突。

属性名可用实验前缀，默认关闭；`trans_*` 先检查属性，读取源、生成有限TCG op、写目的。目的x0用例验证写丢弃，源x0验证读取零，大立即数边界验证field。扩展关闭时原始机器码必须illegal，不应回退到另一重叠pattern。

反汇编可作为附加任务，执行支持与显示同时更新更完整。测试工具链不知道toy mnemonic，可用 `.word`并在C注释写field，避免维护自定义binutils。实验分支结束后保持patch独立，不把生成文件或构建目录加入仓库。

最后写一段“为何不能上游”：没有公开规范、没有真实硬件或稳定软件生态，custom教学编码只服务学习。这样既练习完整工程路径，也不把能编译误解成具备上游资格。

## system 指令的短编码、长语义

`ecall`、`ebreak`、`mret`、`sret`、`wfi` 在decode文件里是固定编码，几乎没有参数，语义却会触发trap、特权切换、休眠或debug。pattern越简单，越不能据此选择“直接IR”。它们通常调用目标helper、设置exception或结束TB，让统一CPU逻辑更新CSR。

`ecall` 的cause取决于当前M/S/U/VS上下文，同一机器码在不同mode产生不同异常。译码器只命中 `ecall`，翻译函数或helper读取context选择code。若把mode编码成多个pattern既不可能，也会把运行状态错误放进位匹配。

`mret/sret` 恢复previous privilege与interrupt enable，可能切换V状态和页表，必须结束TB。返回PC还需对齐与合法性处理。helper完成状态交换后，translator不能继续按旧 `DisasContext`生成下一条。

`wfi` 是否非法受TW、VTW和特权影响，合法时可让CPU halted。等待和kick由执行循环处理，指令翻译只建立架构状态与退出。把host线程睡眠直接写进helper，会让longjmp、BQL和icount难以协调。

## `fence` 家族连接 IR 与缓存协议

普通 `fence pred,succ` 的位字段描述前后访问集合，前端转换为TCG memory barrier。`fence.i` 处理指令可见性与TB一致性，`sfence.vma` 处理地址转换缓存，H扩展两条hfence又按阶段flush。名字相似，目标缓存完全不同。

decode pattern会提取pred/succ、VA、ASID或VMID参数，翻译函数检查扩展与privilege。无用参数不能随意忽略，例如 `sfence.vma` 的rs1/rs2决定范围；实现可以保守全清，仍需按规范处理全局页与非法上下文。

barrier op没有寄存器结果，死代码删除仍必须保留。helper flush可能 `cpu_loop_exit` 或终止TB，副作用声明要准确。实验从 `-d op` 应能看到普通fence的barrier，而sfence/hfence通常是helper与TB exit，验证两条实现路线。

规范允许某些hint作为nop，不能把所有fence都删除。是否有客户机可观察顺序，要按RVWMO和设备I/O判断；同为RISC-V host也要跨TCG层映射。

## HLV、HSV 与 HLVX 的特殊访问上下文

H扩展virtual-machine load/store让hypervisor显式访问guest地址，访问的effective privilege由 `hstatus.SPVP` 等状态决定，使用VS-stage与G-stage，却不是CPU当前V=1普通访存。`trans_rvh.c.inc` 先要求RVH，再调用生成helper选择特殊MMU index。

HLVX按execute权限进行读取，用于检查guest指令内存，和普通HLV load的R权限不同。若前端复用普通load只改地址空间，会漏X权限与fault cause。HSV又要正确传store/AMO类型，让guest-page fault报告对应cause。

2026 年 `40540c8a92` 修复这类指令的pointer masking effective privilege，说明地址预处理也不能直接复用当前mode。译码审查要沿到MMU helper，不能看到 `REQUIRE_EXT(RVH)` 就结束。

实验可让同一guest页R=0,X=1，比较HLV与HLVX；再改变SPVP和masking，核对fault。每个结果同时看destination寄存器、cause和附加GPA，防止错误路径碰巧返回相同数据。

## CSR 表如何集中权限与副作用

CSR编号稀疏，扩展众多，QEMU用操作表为每个CSR提供predicate、read、write和附加信息。`csrrw` translator不按编号写巨大switch，而是进入共同访问逻辑。predicate判断扩展与privilege，read/write实现WARL、WPRI和副作用。

WARL意味着写入不支持值后读回legalized值，不一定trap。`satp/hgatp`会筛选mode与PPN，写后影响TLB；只把 `env->csr = val` 会接受保留模式。read-only CSR写操作又要按指令语义判断，即使目的x0。

CSR别名在V状态映射到VS bank，helper要选择正确字段。trap进入HS时交换寄存器视图，外部GDB读也需一致。将CSR全部内联IR会复制这张动态表，集中helper更便于规范审计。

性能上，CSR通常低于整数运算频率，helper开销可接受；计数器读可能很热，仍优先保证时间与权限。若优化某个CSR快路径，必须保持predicate、trap和迁移，不只返回字段。

## 草案规范版本为何必须写进提交

RISC-V扩展在ratified前可能改编码、名称和语义。QEMU若实现草案，应在CPU属性与提交说明标版本，后续更新可能需要兼容或移除旧编码。用户看到扩展名相同，不能假定不同QEMU版本执行同一草案。

提交 [`26154585c6`](https://gitlab.com/qemu-project/qemu/-/commit/26154585c6) 加入ZALASR，说明明确基于规范v0.9，邮件 [`20251112162923.311714-1-roan.richmond@codethink.co.uk`](https://lore.kernel.org/qemu-devel/20251112162923.311714-1-roan.richmond@codethink.co.uk/) 是证据。正文引用它时应保留版本，不把实现描述成最终ratified承诺。

草案更新要比较encoding、CSR、异常和memory model，不只改version string。若旧QEMU CPU型号已向用户暴露，machine compatibility可能要求保留；开发期 `max`也可能允许破坏性跟进，取决于上游政策。

作者推断，邮件cover letter的规范链接与版本是代码可复核性的组成。没有版本，reviewer无法判断reserved bit和依赖，几年后也无法解释为何当前代码看似偏离新手册。

## decoder 性能不要凭决策树外观判断

生成C可能出现嵌套if、switch和位mask，文本很长不代表运行慢。decodetree按固定bit构建决策，常见32位基础opcode可以很快分组；真正翻译成本还包括取指、IR和helper。优化前应profile冷TB生成。

pattern顺序与overlap会影响比较，过宽厂商decoder放前可能增加所有指令开销。decoder列表只启用CPU需要集合，避免每条指令遍历所有扩展文件。新增扩展的指令数多，不等于线性增加每次匹配。

手写“快速switch”可能重复field提取和冲突检查，维护成本高。若profile确认热点，应改进生成器或pattern组织，并跑所有target decode tests，不能为一个扩展绕开工具。

测量用大量首次翻译的固定指令流，分别统计decode、整个translation和执行。热TB不再译码，运行benchmark几乎看不到decoder差异；用热循环证明新pattern零开销没有意义。

## fuzz 与负向编码测试互补

定向测试覆盖规范列出的reserved组合，fuzz随机32位word可发现unexpected match、helper断言和状态泄漏。输入必须在受控CPU属性和privilege运行，timeout与trap handler保证非法码不会停止整个campaign。

oracle可先要求“非法或执行都不能让QEMU崩溃”，再对已知编码做语义差分。随机码恰好是合法内存指令时，会访问任意地址并产生正常fault，不应当作失败。保存最小机器码、CPU配置和初始寄存器即可复现。

coverage能显示某些 `trans_*` 从未触发，不能证明合法性。reserved encoding期望不进入trans，coverage低正是目标。将规范分类与coverage结合，比追求百分比更合理。

fuzz发现问题后补确定性 `tests/tcg/riscv64` 或decode test，避免以后依赖随机seed。修pattern时检查相邻扩展，过窄可能把合法码变illegal。

## 一项扩展完成度的交付清单

提交前列规范名称与版本、CPU property和依赖、decode正负空间、RV64宽度、privilege/virtualization、TCG op/helper、CSR与迁移、disassembler、文档和测试。没有涉及的项写“不需要及原因”，比默默缺文件更便于review。

实验也采用同一清单，只是toy指令明确无CSR、无迁移新增状态、无规范上游资格。这样学生能看到“无需修改”和“忘记修改”的差别。真实扩展若新增架构状态，VMState与GDB往往不可省。

错误路径至少包括扩展关闭、非法XLEN、权限不足、reserved field和内存fault。性能记录翻译IR数、host bytes与helper，不给无对照的“开销很小”。

最后用Git范围展示每个patch职责，cover letter引用英文规范与qemu-devel讨论。正文中文解释设计，证据仍保持原始链接，读者可以回到上游判断。

## 阅读复核：从机器码反向追到规范

选一条日志里的机器码，先不用QEMU函数名，按规范手工切出opcode、funct、rd、rs1、rs2与立即数，写出合法条件。再在 `.decode` 找field/format/pattern，确认位数、符号扩展和固定bit完全一致。手工结果与生成声明不同，先解决差异，不进入 `trans_*` 猜语义。

进入翻译函数后，列出四类检查：CPU静态扩展、运行时enable、XLEN、privilege/virtualization。每个失败对应illegal或virtual instruction等准确异常。随后列副作用：寄存器、内存、CSR、PC、TB结束和可重启状态。函数短不代表清单项目少，很多工作在共同helper。

继续到IR/helper，确认x0、符号扩展、MemOp、barrier与helper flags。最后找正向测试、扩展关闭测试、reserved编码和异常测试。缺哪类就标研究空白，不用一条Linux启动替代。对于向量/原子，还要加入中途fault与多hart。

历史证据从pattern或helper做 `git blame`，再读完整系列与Message-ID。提交说基于草案v0.9，就按v0.9解释；作者认为某次拆分提高维护性，明确写推断。这样一条机器码可以串起规范、当前实现、审查和实验，章节不会散成指令列表。

## 新指令失败时的定位顺序

构建失败先查decodetree语法、重叠与生成依赖；运行总illegal，查CPU属性、decoder列表、pattern和 `REQUIRE_EXT`；结果错，查field符号、XLEN、x0和IR；只在fault错，查PC元数据、helper return address与cause；只在多核错，查原子和内存序。

反汇编显示 `.word` 而执行正确，问题在disassembler或工具版本；反汇编正确而执行illegal，不要被显示迷惑，两套decoder可能分叉。日志保留raw hex，始终有独立事实。

只在优化开启错误，比较优化前后IR，可能是helper副作用或known bits；只在某host错误，前端IR相同则转后端constraint/发射。分层定位能减少在decode文件反复改mask造成新冲突。

最终修复补对应最小测试，并跑扩展矩阵。把定位过程写入提交说明，比“fix instruction”更能让reviewer判断根因是否封闭。

译码章节的版本复核不只比较 `.decode` diff。还要看CPU默认扩展、规范版本、helper原型、反汇编和tests，同一pattern未改，合法条件仍可能因属性或CSR更新变化。实验启动时打印CPU能力，避免把默认改变误作译码回归。

正式tag若在rc0后修复reserved编码，应以最终行为为正文事实，同时保留修复commit解释演进。书稿目标是让读者复现当前边界，不维护一份过期候选版行为。

还要保存生成器版本和构建命令。相同 `.decode` 在生成器修复后可能形成不同决策树，执行语义应一致，构建期冲突诊断可能更严格。若新生成器拒绝旧声明，先判断它发现了真实歧义，不能为了保留文本原样绕过检查。源声明、生成工具和测试共同构成译码链的可复现输入。

每次更新至少随机抽取一条基础指令、一条压缩指令、一条特权指令和一条H扩展指令，按本章端到端方法复核。四条路径能很快发现生成、长度、权限或虚拟化条件的系统性偏移，再决定是否扩大回归范围。

抽样结果要包含原始机器码和负向条件，不能只保存助记符；工具链若改变助记符显示，机器码仍能把实验锚回同一条架构语义。

这也是跨版本复核最可靠的起点。

::: {.source-path}
主要入口：`target/riscv/insn16.decode`、`target/riscv/insn32.decode`、`target/riscv/tcg/translate.c`、`target/riscv/tcg/insn_trans/`、`target/riscv/tcg/csr.c`、`target/riscv/helper.h`、`scripts/decodetree.py`、`docs/devel/decodetree.rst` 与 `tests/tcg/riscv64/`。当前源码使用官方 GitLab `v11.1.0-rc0`，历史查询要跨越 RISC-V TCG 目录搬迁。
:::

## 实验：跟踪两条端到端译码路径

::: {.hands-on}
实验名称：`trace-riscv-decode`。按英文手册 [`trace-riscv-decode`](../experiments/part-02-tcg-execution-engine/chapter-08-riscv-decode/trace-riscv-decode/README.md)，选择基础整数 `addi` 与 H 扩展 `hfence.gvma`。对每条指令记录机器码、field、argument set、format、pattern、生成的 `decode_*` 入口、`trans_*`、TCG op/helper、异常条件和测试程序。分别在扩展启用、扩展关闭、特权不足的环境执行，核对成功路径与 trap cause。正文实验报告使用中文，原始命令和操作手册保留英文命名。
:::

这个实验要防止“grep 到函数就算完成”。`hfence.gvma` 还涉及虚拟化状态和 TLB flush，必须追到 helper 或相关退出；`addi` 要验证 x0 和符号扩展。建议为每条路径画一张纵向图，只保留实际经过的节点，再把没有动态覆盖的条件标成静态源码证据。

## 实验：加入一条教学指令

::: {.hands-on}
实验名称：`add-toy-instruction`。按英文手册 [`add-toy-instruction`](../experiments/part-02-tcg-execution-engine/chapter-08-riscv-decode/add-toy-instruction/README.md)，在隔离分支和实验 CPU 属性下占用明确的 custom opcode，加入一条只做整数运算的教学指令。修改 `.decode`、`trans_*` 和 `tests/tcg/riscv64/`，再增加扩展关闭、目的寄存器为 x0、输入溢出与非法编码测试。不得把实验编码描述成 RISC-V 标准扩展，也不要把补丁提交上游。
:::

实验评审重点是边界完整性：构建系统是否重新生成 decoder，执行与反汇编是否一致，未启用时是否 trap，RV64 运算宽度是否准确，测试能否在无该扩展的工具链下用 `.insn` 或 `.word` 构造编码。最后用 `git diff` 区分生成文件和源文件，说明哪些变化属于实验、哪些若要上游化仍需规范与邮件讨论。

## 从实验结果回到工程判断

若新增指令只在 `-O0` 测试通过，先检查编译器是否优化掉调用；若 QEMU 日志显示机器码正确却进入非法指令，检查 CPU 属性和 `REQUIRE_EXT`；若 H 指令得到 illegal 而预期 virtual instruction exception，回到当前特权和虚拟化状态。实验失败应缩小到取指、匹配、合法性、语义、提交状态中的一层。

不要用一条成功输出证明 helper 选择合理。性能需要热循环与生成代码统计，精确异常需要负向用例，维护性则要看 patch 是否重复字段与检查。本章提供的是评审问题清单，结论仍要由源码和实验共同支持。

## 小结

decodetree 将重复的位提取和模式匹配从手写 C 中移开，`DisasContext` 保存 TB 内可依赖的 RISC-V 状态，`trans_*` 再完成扩展、特权与副作用检查。简单语义直接生成 TCG op，复杂或大规模语义进入 helper，两者的分界由运行频率、代码体积、优化机会和精确异常共同决定。

一项扩展的实现远不止一行 pattern。CPU 能力、执行译码、CSR、反汇编、迁移和正负向测试必须形成闭环。下一章沿 `trans_*` 产生的 IR 继续向下，看这些客户机语义怎样经过优化、寄存器分配，最终成为宿主代码。
