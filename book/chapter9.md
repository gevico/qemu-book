# 为什么 TCG 需要 IR

在 RISC-V `virt` 上启动一段固件，`addi a0,a0,1` 最终也许只对应一条宿主加法。沿源码直接寻找“RV64 addi 怎样编码成 x86 add”看似最快，很快就会遇到麻烦：换成 AArch64 或 RISC-V64 宿主，编码完全不同；把 `addi` 换成 `lw`，software TLB、端序和异常又进入路径；打开 RV128，原来一个值可能要拆成两半。

TCG IR 站在这些变化之间。它让 RISC-V 前端提交客户机语义，让宿主后端兑现本机约束，也让公共层在中间完成生命周期分析、轻量优化与寄存器分配。IR 的价值要沿一次真实翻译才能看清。

## 没有 IR 时会出现一张乘法表

设 QEMU 支持 G 种客户机 ISA 和 H 种宿主 ISA。若每个客户机前端直接发射宿主指令，工程上要维护接近 G × H 组组合。RISC-V `addi` 在 x86_64、AArch64、PowerPC64 和 RISC-V64 上各有实现；每加入一种客户机扩展，还要逐宿主补齐。精确异常、helper ABI 与内存访问也会在组合里重复。

IR 把这张乘法表切成两条线。guest frontend 从 RISC-V 指令生成 TCG op，host backend 从 TCG op 发射本机代码。理想规模接近 (G + H)，当然还有每种宿主能力与通用 op 的差异处理。2018 年 Michael Clark 加入 [`RISC-V TCG Code Generation`](https://gitlab.com/qemu-project/qemu/-/commit/55c2a12cbcd3d417de39ee82dfe1d26b22a07116)，同年 Alistair Francis 另起系列加入 RISC-V host backend；两组提交的分离就是这个结构的实例。

分离带来的收益还包括故障定位。同一 RV64 guest 在全部宿主上算错，先查 `target/riscv/tcg`；只有 RISC-V64 host 出错，先查 [`tcg/riscv64`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/tcg/riscv64)；多个 guest 在同一个 IR pass 后出错，再查 `tcg/optimize.c` 或公共 lowering。IR 形成了可测试的责任边界。

这张结构也有成本。前端只能使用 IR 能表达的语义，宿主后端要实现 op 或提供合法展开；一项很贴近某种 ISA 的专用指令，经过通用表示后可能丢掉优化机会。TCG 用可选 op、constraint、generic expansion 和 helper 处理差异，并不追求每条客户机指令都与宿主一一对应。

:::: {.quick-quiz}
RISC-V guest 与 RISC-V64 host 相同，为什么仍然需要 TCG IR？

::: {.quick-answer}
客户机指令运行在模拟的 privilege、地址空间和 CPU state 中，宿主指令受 QEMU 进程 ABI 与安全边界约束。访存要经过 SoftMMU，异常要恢复客户机 PC，寄存器也没有一一绑定。相同 ISA 只让后端有机会选择相似指令，不能省掉语义转换。
:::
::::

## IR 之前，decode 已经完成一次语义筛选

RISC-V translator 不把任意 32 位字直接交给 TCG。构建阶段，`scripts/decodetree.py` 根据 `target/riscv/insn*.decode` 生成位模式匹配和参数填充代码；运行时 translator 先按低位判断 16/32 位等指令长度，安全取指，再让 decoder 选择 `trans_*`。field、argument set 与 format 复用寄存器和立即数提取，pattern 固定 opcode/funct 等识别位。

取指本身已经可能异常。一条 32 位指令从页尾倒数两个字节开始，前半页可执行、后半页无映射，QEMU 应对当前 PC 报 instruction page fault，不能先把四个字节当宿主指针读取。decodetree 只处理已经合法取得的 opcode，SoftMMU 与 translator 负责跨页和权限；分层也适用于输入端。

匹配成功仍不表示可以生成 IR。`REQUIRE_EXT`、XLEN check、privilege 与 V 状态判断决定当前 CPU model 是否接受编码。某些 H 扩展指令在 VS-mode 下应产生 virtual instruction exception，在完全没有扩展时可能是 illegal instruction。前端必须在生成可见副作用前选定正确失败路径。

`DisasContext` 把本次 TB 已知稳定的事实带给每个 `trans_*`：XLEN、当前 privilege、virtualization、memory index、端序、扩展配置和 PC。前端可在翻译时消掉恒定分支；会修改这些事实的 CSR 或 trap 指令则结束 TB，让下一块重新建立上下文。IR 因而建立在一组明确假设上，不能脱离 TB key 单独解释。

从机器码到 `trans_*` 的节点也给测试提供了四个断点。机器码错误查生成工具或汇编；取指失败查地址与权限；pattern 未命中查 `.decode`；进入 `trans_*` 后结果错误才查 IR/helper。把所有失败都归为“TCG 翻译错了”，会跨过最有用的定位边界。

## 一条 `addi` 怎样穿过这条边界

在 `v11.1.0-rc0` 的 [`target/riscv/tcg/insn_trans/trans_rvi.c.inc`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/tcg/insn_trans/trans_rvi.c.inc) 中，`trans_addi()` 进入通用的立即数算术生成函数。函数通过 `get_gpr()` 取得源寄存器对应的 TCG 值，分配目的临时值，调用 `tcg_gen_addi_tl()`，再用 `gen_set_gpr()` 提交目的寄存器。RV128 时还提供 `gen_addi2_i128()` 路径，把长值拆成低、高两部分完成带进位加法。

`a->imm` 是翻译时已经从机器码解出的常量，`a->rs1` 和 `a->rd` 是寄存器编号；`get_gpr()` 返回的 `TCGv` 表示客户机运行到这条指令时的寄存器内容。三者都写在 C 函数里，却处于不同时间层。IR API 和 opaque type 约束这层差异，避免前端把编号 `10` 当成 a0 的运行时值。

生成的文本 IR 可能呈现为 `add_i64` 或带立即数的等价形式，具体临时编号由生成过程决定。optimizer 可以把加零消掉、传播常量或删除无用纯计算。若目的为 x0，RISC-V 前端会让最终写回没有体系结构效果；这并不意味着所有“写 x0”的指令都可删除，load 到 x0 仍会访问内存并可能 fault。

宿主后端接手时才考虑本机立即数范围和寄存器 constraint。RISC-V64 host 的 12 位有符号立即数能直接进入 `addi`，更大的值需要构造常量或改用其他序列；x86_64 的选择会不同。guest 前端只提交“按目标 XLEN 加这个立即数”，后端负责找合法编码。

在 `-d op` 日志中，看到 `add_i64` 也不能立即与某一条源码调用一一绑定。前端 helper wrapper 可能先产生 `mov` 与扩展，optimizer 又会传播 constant、合并 copy 或删除死结果。正确读法是同时保存优化前后两份 op：前一份回答 translator 表达了什么，后一份回答通用层证明了什么，`out_asm` 才回答后端选择了什么。

## `lw` 说明 IR 还要表达副作用

`trans_lw()` 本身很短，它把 `MO_SL` 交给共用 load 生成函数。后者先记录当前 opcode 对应的恢复信息，计算地址，把当前端序并入 `MemOp`，再调用 `tcg_gen_qemu_ld_tl()`。`MemOp` 同时携带访问宽度、有符号扩展和端序，`ctx->mem_idx` 表示当前特权与地址转换上下文。

`qemu_ld` 类 op 不能当成普通宿主 load。地址是客户机虚拟地址，执行时可能命中 software TLB 的 RAM fast path，也可能走页表遍历、PMP 检查、MMIO 或异常。IR 必须保留这些可见副作用，optimizer 才不会因为结果未使用就删掉整次访问。RISC-V 的 `lw x0,0(a0)` 正是负向样例：目的寄存器没有变化，page fault 与设备读取仍然有效。

这项设计也把目标相关与公共机制分开。RISC-V 前端决定 `lw` 的符号扩展、XLEN、当前 `mem_idx` 和架构内存序；TCG 公共层生成 TLB fast path 与 slow path；RISC-V `tlb_fill` 实现 Sv39、H 扩展两阶段转换与 fault 字段。IR op 没有复制 RISC-V PTE walker，却保存足够信息让执行路径进入正确 walker。

原子访问和 barrier 进一步说明副作用需要显式表示。`aq`、`rl`、Ztso 等规则不能靠 C 编译器“碰巧”维持，前端要生成 TCG memory barrier 或具有原子合同的 op，host backend 再根据宿主内存模型发射 fence、原子指令或 helper。IR 若只记录最终算术值，多 vCPU 程序会在弱内存宿主上失去架构保证。

## helper 是 IR 的语义逃生口

某些 RISC-V 指令适合几条 TCG op，另一些会检查大量 CSR、遍历页表、修改跨 CPU 状态或抛出异常。强行把所有逻辑内联成 IR 会拉长翻译时间和代码缓存占用，也让精确状态更难审查。TCG 允许前端生成 helper call，把复杂或低频语义留在普通 C 函数。

`hfence.gvma` 是一例。当前 [`trans_rvh.c.inc`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/tcg/insn_trans/trans_rvh.c.inc) 先要求 H 扩展，在 system emulation 中调用 `decode_save_opc()` 保存异常恢复位置，然后生成 `gen_helper_hyp_gvma_tlb_flush(tcg_env)`。helper 负责权限检查并刷新当前 vCPU 的软件 TLB；它既不会替客户机完成跨 hart shootdown，也不会因此强制结束当前 TB。远程失效需要客户机软件通过 SBI remote fence 或 IPI 协调目标 hart，QEMU 内部的全 vCPU flush 则属于另一套调用协议。

helper 不是绕开 IR 合同的任意 C 调用。声明要说明输入、输出以及是否读取或写入 globals，调用是否有副作用、能否抛异常。默认情况下，TCG 在调用前把需要的 global 放回 canonical location，并假定 helper 可能修改 CPU state。若声明为 `NO_READ_GLOBALS`、`NO_WRITE_GLOBALS` 或 `NO_SIDE_EFFECTS`，optimizer 才能减少保存、重载或删除无用调用。

标记过于保守会损失性能，标记过强则破坏正确性。一个可能触发 page fault 的 helper 若被写成无副作用，结果未使用时可能被删除；一个读取隐含 CSR 的 helper 若宣称不读 global，可能看到过期状态。review helper patch 时，函数体、声明与异常出口必须一起看。

:::: {.quick-quiz}
什么时候一个复杂的 RV64 指令更适合 helper？

::: {.quick-answer}
它执行频率低、需要大量条件与状态访问、异常路径复杂，或展开后会产生很长 IR 时，helper 常能降低翻译与代码缓存成本。热路径、简单纯运算或后端能高效实现的语义更适合直接生成 op，最终要用测量和正确性矩阵决定。
:::
::::

## 强类型还约束值的寿命

当前 TCG 文档把变量分成 fixed global、global、constant、TB temporary 与 extended-basic-block temporary。`cpu_env` 是固定 global，始终指向 `CPUArchState`；普通 global 对应 CPU 状态中的长期位置；constant 在 TB 范围复用；temporary 的值只能活在规定控制流区域内。

这些类别直接影响寄存器分配与状态同步。一个 RV64 GPR 若映射为 TCG global，多个 IR op 可以让它暂留宿主寄存器，需要调用未知 helper 或离开 TB 时再同步；短计算的 temporary 在最后一次使用后即可回收。把临时中间值错误地声明成 global，会增加保存与重载；把跨分支仍需使用的值当成短命 temporary，则会读到已失效内容。

i32、i64、i128 和 vector type 解决宽度问题。32 位宿主上的 i64 会拆为一对 i32，i128 在各宿主上按寄存器宽度拆分；host backend 不支持的 vector 宽度可以展开为更小操作或 helper。类型让这种展开有固定入口，前端不必按宿主位宽散布条件编译。

RISC-V 的 XLEN 与 TCG type 仍不能画等号。`target_long`/`TCGv` 会随目标配置取宽度，但 RV64 的 word 指令要求 32 位截断后符号扩展，RV128 又出现 128 位架构值。前端必须提交 ISA 规定的截断和扩展，IR 类型只保证承载空间与 op 语义，不会自动补齐 RISC-V 规则。

控制流会缩短 temporary 的生命。普通 temp 在 basic block 边界死亡，EBB temp 可以沿 conditional fall-through继续，到退出仍必须结束；global 则在 helper 和 TB 出口按合同同步。若值要跨 `brcond` 使用，前端选择错误 temp 类别可能只在某个分支出现坏值。`-d op` 需要同时标出 label 和 temp 最后使用，不能只列算术关系。

constant 也属于 TCG variable。相同 type 与值可在 TB 中复用，后端再决定是否立即编码、放入 constant pool 或装进寄存器。翻译期 C 常量进入 IR 后仍要遵守目标 type width；将负的 12 位 RV64 immediate 直接转成无符号宿主宽度，可能在 32/64 位后端得到不同高位。

## IR 怎样服务精确异常

动态翻译为了速度，通常不会在每条客户机指令后把 PC 和所有状态写回 `env`。一段 TB 内，PC 可以由翻译上下文推进，寄存器可停留在 TCG global 或宿主寄存器。遇到 `lw` fault 时，客户机却要求 `xepc` 指向确切故障指令，已经提交与尚未提交的副作用也要分清。

RISC-V translator 在可能异常的操作前调用 `decode_save_opc()`，公共翻译层记录客户机指令边界与生成代码偏移。slow path 带着宿主 return address 离开，`cpu_restore_state()` 根据 TB 映射恢复当前指令状态，再进入 RISC-V trap 处理。IR 的顺序和 op 副作用声明由此参与异常 ABI。

优化器不能把可能 fault 的访存跨过另一项可见副作用，也不能把恢复点合并到错误指令。纯算术常量折叠通常安全；读 MMIO、helper call、barrier 和 `qemu_ld/st` 受到更强顺序约束。TCG 的优化范围看起来保守，部分原因就是它工作在“精确客户机状态”这条线上。

TB 出口同样要提交翻译时假定的状态。直接分支可用 `goto_tb + exit_tb`，但在跳转前要更新主循环查找下一 TB 所需的 PC 与 flags；会改变特权级、地址转换或扩展状态的指令通常结束当前 TB，让下一次 lookup 用新 key。IR 把计算写对还不够，离开路径也必须让执行循环看见自洽状态。

## 从 IR 到 RISC-V64 宿主代码

通用层在 [`tcg/tcg.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/tcg/tcg.c) 建立 op 序列、活跃性和寄存器分配信息，[`tcg/optimize.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/tcg/optimize.c) 执行常量折叠、复制传播和代数简化等变换。随后后端按照 constraint 为输入、输出挑选宿主寄存器，必要时插入 move、spill 和 reload，再发射代码。

RISC-V64 backend 将通用 op 映射到本机指令。`tcg-target-con-str.h` 描述单个 operand constraint，`tcg-target-con-set.h` 组合各 op 可接受的寄存器和立即数，`tcg-target.c.inc` 负责 relocation、load/store、branch、call、prologue 与最终发射。后端还声明 `TCG_TARGET_HAS_*`，告诉公共层哪些 op 可直接实现。

“支持某条 RISC-V64 指令”与“支持某个 TCG op”仍有距离。后端选择应受语义、ABI 与可用扩展约束；即便宿主有一条看似匹配的指令，边界条件或 flag 行为不同，也可能需要多条序列。反过来，guest 与 host 都是 RISC-V 时，QEMU 仍要经过客户机 privilege、SoftMMU 和 CPU state，不能把 guest opcode原样复制到缓存。

寄存器分配把 IR 生命周期变成机器约束。跨 helper 活跃的值要避开 call-clobbered register 或先保存，固定 `cpu_env` 要遵守后端约定，i128 拆分值要保持配对关系。后端 bug 常在高寄存器压力、罕见立即数或 helper 边界出现，所以只跑一个短算术用例不足以证明实现完整。

`tcg_gen_code()` 的顺序值得对着日志走一遍。`tcg_optimize()` 先简化值关系，reachable pass 删掉确定不可达区域，liveness 判断 temp 最后使用与 global 同步点；后续变化若影响活跃性，会重新运行相应分析。寄存器分配再根据每个 op 的输入/输出 constraint、early clobber、配对值与调用 ABI 选位置，最后由 `tcg_out_op` 一类后端入口发射。

这条管线没有输出宿主目标文件。代码直接写入 QEMU 管理的 JIT region，relocation 与 constant pool 在生成期间处理，必要时执行宿主 icache 同步，然后 TB 发布给 lookup。因而 `out_asm` 中的地址属于本次进程的代码缓存，重启后会变化；分析应以 TB start PC、op 序列和相对 offset 对齐，避免把 ASLR 地址当稳定标识。

若发射时发现单个 TB 超过缓冲区上限或 out-of-line slow path 空间不足，生成路径要丢弃未完成结果并安全重试，不能发布半段代码。这个失败模式提醒我们，IR op 数、后端 expansion 和代码缓存管理仍在同一次事务里，前端无法只看语义正确就忽略生成尺寸。

:::: {.quick-quiz}
为什么 `out_asm` 的宿主地址不能作为跨运行实验的主键？

::: {.quick-answer}
JIT region 地址受进程布局、ASLR、生成顺序和代码缓存状态影响。用客户机 TB 起始 PC、固定 QEMU commit、IR 序列与相对 host offset 更稳定；绝对地址只在单次日志内帮助对齐。
:::
::::

## IR 为什么可以演进而不成为 ABI

2008 年初始 IR 只有 i32、i64 和有限 op，随后加入更丰富的条件、原子、vector、i128 与插件相关支持。它持续增长，却属于 QEMU 内部接口。客户机迁移流不会序列化 TCG op，机器类型也不承诺某段 guest code 永远生成相同宿主指令。

内部接口仍需要纪律。新增 op 会影响所有 host backend、TCI、optimizer、liveness、日志与测试；若现有 op 的组合已经足够，增加一条专用 op 可能只把复杂度从前端挪到每个后端。当前官方文档的“Recommended coding rules”仍建议复杂或低频指令使用 helper，并根据后端可用 op 选择展开。

判断是否新增 op，可以问三个问题：多个 guest target 是否都会受益；主要 host 是否能直接实现或得到更好代码；通用语义能否完整描述异常、内存序和未定义行为。只为一条罕见 RV64 指令绕过 helper，收益可能抵不过后端矩阵与验证成本。

IR 也保留可观测性。`-d op` 让开发者看到优化前后 op，TCG plugin 在受控位置插桩，`-perfmap`/`-jitdump` 把 JIT 代码带入宿主 profiler。它们属于诊断接口，版本间文本和代码形状可变；实验要固定 QEMU commit，并用客户机结果作为正确性 oracle。

plugin 进一步证明 IR 与 TB 是执行合同的一部分。按指令插桩可能要求更细的边界，读取内存事件会改变生成的 callback，启停 plugin 也可能促使旧 TB 失效。比较性能时，plugin、single-step、icount 和日志开关都要列入配置；这些观察手段会影响被观察代码的形状。

perf map 解决另一层可见性。宿主 profiler默认只看到一大片匿名 JIT region，无法把 sample 归到客户机 TB；映射文件用 guest/host 信息补上坐标。它适合回答“时间花在哪些生成代码”，却不能证明某次 RV64 page fault 的 cause，后者仍靠客户机 trap oracle 与恢复日志。不同证据回答不同问题。

## 实验：保存一条完整的 RV64 IR 证据链

::: {.hands-on}
按照 [`dump-tcg-ir`](../experiments/part-02-tcg-execution-engine/chapter-09-tcg-ir-and-host-code/dump-tcg-ir/README.md) 准备一个短函数，包含 `addi`、条件分支、RAM `lw/sw` 和一次 CSR/helper 路径。用 `-d in_asm,op,out_asm` 采集同一 PC 范围，逐条标注机器码、`trans_*`、IR temp 定义与最后使用、helper、`qemu_ld/st`、两个 TB 出口和宿主指令。

先核对客户机结果，再解释代码形状。`lw` 即使目的为 x0也必须保留访问，条件分支的两个结果都要覆盖，CSR 路径要加入权限失败。若 `op` 日志显示某次纯计算消失，检查其结果确实无用；若访存消失，优先怀疑副作用声明或实验被宿主编译器提前优化。

宿主若非 RISC-V64，`out_asm` 按实际架构记录。要研究 [`tcg/riscv64`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/tcg/riscv64)，必须在 RISC-V64 主机或可核验的远端环境重跑，并保存 `uname`、编译器、CPU 扩展和 QEMU commit。IR 可跨宿主比较，最终机器码不可移植。

日志截取要从 TB start 到两个出口完整保留。只摘一条 `add_i64`，看不到前面的 sign extension 和后面的 dead write，也无法判断 helper 前是否同步 global。对每个 op 写“输入来自哪里、输出最后在哪里使用、是否有副作用”，一条短函数就能覆盖 IR 阅读的主要问题。
:::

## 实验：让同一 IR 遇到两种后端约束

::: {.hands-on}
继续使用 [`compare-host-code`](../experiments/part-02-tcg-execution-engine/chapter-09-tcg-ir-and-host-code/compare-host-code/README.md)。在 RISC-V64 host 上构造两组等价 RV64 guest 函数：一组使用可直接编码的 12 位有符号立即数，另一组使用需要构造的大常量；再增加跨 helper 活跃值，逐步制造寄存器压力。

比较 IR、宿主代码字节数、常量物化、move、spill 与 helper ABI。实验目标是观察“同一 guest 语义如何因后端 constraint 得到不同代码”，不根据一次 wall-clock 排名宣布全局性能。每组都用独立参考实现检查正负边界、shift 0/63 和溢出结果。

若结果错误，按四层二分：RISC-V 前端生成的 IR 是否正确，optimizer 前后是否等价，constraint 是否允许非法 operand，发射编码与 relocation 是否正确。这个顺序就是 IR 分层提供的调试收益。
:::

## 小结

TCG IR 把 RISC-V 客户机语义与宿主编码分开，同时记录类型、值生命周期、副作用、helper 边界与精确状态要求。它让 guest 和 host 的支持规模从组合问题变成两条可维护的演进线，也让错误能落到前端、通用层或后端中的一层。

IR 存在并不意味着 QEMU 应把它做成重量级编译器。翻译发生在执行等待路径，TB 生命有限，helper、SoftMMU 和异常又限制了自由移动代码的空间。下一章就沿这些成本回答一个常见疑问：TCG 已经有 IR，为什么优化器仍然显得克制。
