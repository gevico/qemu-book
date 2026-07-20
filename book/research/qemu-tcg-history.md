# QEMU 动态翻译与 TCG 证据账本

本账本服务第二篇第 7～11 章，版本锚固定为 QEMU `v11.1.0-rc0`（commit `eca2c16212ef9dcb0871de39bb9d1c2efebe76be`）。历史材料只用于回答设计转折，当前机制与实验统一使用 RISC-V target。正文没有采用、但可能帮助后续复核的材料保留在这里。

## 事实校正

1. dyngen 已经使用 micro-op，也已经按 TB 做动态生成。IR 与 TB 不能写成 TCG 同时发明的概念。
2. 初始 `tcg/README` 只说 TCG 起初是一个 generic backend for a C compiler，并吸收 Paul Brook 的 QOP code generator。当前没有一手证据把这个 backend 点名为 TinyCC，因此正文禁止写“TCG 原本就是 TinyCC”或“TCG 原本是一套完整 C 编译器”。
3. 2008 年 TCG 没有一次性替换全部 target。公告明确说 legacy dyngen micro-op 仍可经 TCG 使用，target 能够渐进转换。
4. TCG 的优化范围从初始设计起就较窄：单 op 化简、basic-block liveness、dead result/move 消除。当前实现已经明显演进，但仍以 TB 翻译时延、代码缓存和精确异常为约束，不能用“早期功能少”解释今天的收敛。
5. RISC-V guest frontend 与 RISC-V host backend 是两条线：前者 2018 年 3 月进入，后者 2018 年 12 月分步加入。guest/host 均为 RISC-V 时仍要经过 TCG、SoftMMU 和客户机状态合同。

## 具名参与者与角色边界

| 人物 | 可核验活动 | 书中采用的角色表述 |
|---|---|---|
| Fabrice Bellard | 2005 论文作者；2008 TCG 基础与接入提交 author/committer；公告与 SPARC 回复 | QEMU 创建者、TCG 初始实现与集成者；不为早期线程虚构 `Reviewed-by` |
| Paul Brook | QOP 来源；提出 opaque TCG variable；提交 `ac56dd48`；分 16 个 patch 转换 ARM | 设计来源、接口建议者与迁移 contributor |
| Christian Roue | 复现并缩小 SH4/GCC 4.1.2 构建故障 | reporter/diagnostic contributor |
| Alexander Graf | 讨论 SH4 workaround 与 configure 检测 | 诊断参与者；该线程未留下形式化 reviewer trailer |
| Thiemo Seufer | 指出 `-fno-*` 只是 workaround，并支持渐进迁移 | 维护经验与设计方向提供者 |
| Blue Swirl | 提交 SPARC WIP、持续转换 SPARC；向 Fabrice请求设计意见 | target conversion contributor/maintainer 参与者 |
| Aurelien Jarno | 2008 年 12 月删除 dyngen并提交清理 | dyngen removal integrator/contributor |
| Laurent Desnogues | dyngen 删除后的清理提交 Signed-off-by | cleanup contributor |
| Frederic Konrad | MTTCG option、async TLB work 等提交 author/Signed-off-by | MTTCG contributor |
| Alex Bennée | thread-per-vCPU、TB locking等 author/committer，重整系列 | MTTCG maintainer/integrator |
| Richard Henderson | MTTCG 关键提交 `Reviewed-by`，长期 TCG contributor/maintainer | 可由 trailer确认的 reviewer |
| Michael Clark | 2018 `RISC-V TCG Code Generation` author | RISC-V guest frontend contributor |
| Alistair Francis | 2018 RISC-V host backend 系列 author | RISC-V TCG host backend contributor |

早期 QEMU 处于 CVS/SVN 工作流，Git 镜像中大量提交没有 `Reviewed-by`、`Acked-by` 等 trailer。邮件里的回复可说明讨论与建议，不能自动升级为现代形式化 review。正文只在 Git trailer 明确时使用“Reviewer”称谓。

关键邮件的归档编号与 Message-ID 对照如下，避免后续只凭网页序号引用：

| 归档 | Message-ID |
|---|---|
| `2008-02/msg00011` | `<47A31AE8.1010402@bellard.org>` |
| `2008-02/msg00048` | `<200802020334.10618.paul@codesourcery.com>` |
| `2008-02/msg00320` | `<ef99d6f80802160322k7a753cddh9144b87df1d1e0f4@mail.gmail.com>` |
| `2008-02/msg00338` | `<2151CED4-02CD-4928-978A-6C63A734F19F@csgraf.de>` |
| `2008-02/msg00342` | `<20080218204926.GE4747@networkno.de>` |
| `2008-02/msg00406` | `<f43fc5580802211227u4e6e5ee6ofd4582c3a16bce46@mail.gmail.com>` |
| `2008-02/msg00427` | `<47C064B5.4040809@bellard.org>` |

## 决策记录

### D1：借 GCC 生成 micro-op 片段

- `claim`：dyngen 用 GCC 在构建期编译 C micro-op，再从目标文件抽取、重定位和拼接宿主代码；运行时没有启动 GCC。
- `current_source`：历史机制，当前源码已删除。现代对应路径是 [`accel/tcg/cpu-exec.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/tcg/cpu-exec.c) 与 `tcg_gen_code()`。
- `history`：[Bellard 2005 USENIX 论文](https://www.usenix.org/legacy/events/usenix05/tech/freenix/full_papers/bellard/bellard.pdf)；早期 translation cache [`7d13299d07`](https://gitlab.com/qemu-project/qemu/-/commit/7d13299d07a9c3c42277207ae7a691f0501a70b2)，direct chaining [`d4e8164f7e`](https://gitlab.com/qemu-project/qemu/-/commit/d4e8164f7e9342d692c1d6f1c848ed05f8007ece)，precise exceptions [`a513fe19ac`](https://gitlab.com/qemu-project/qemu/-/commit/a513fe19ac4896a09c6c338204d76c39e652451f)。
- `review`：论文是设计说明，早期 commit 无现代 review trailer。
- `reasoning`：论文明确说明机制；“有限人力下借成熟 compiler backend 控制 host port 成本”是结合论文“performance/complexity compromise”与代码历史的工程解释。
- `experiment`：`observe-tb-lifecycle` 验证现代 TB 缓存/复用，不用于声称 dyngen 的具体性能。

### D2：把 GCC 代码形状视为工程债务

- `claim`：dyngen 依赖编译器生成的函数布局、symbol/relocation 和对象格式；合法 GCC 优化也可能破坏抽取假设。
- `current_source`：无当前 dyngen 源码；TCG 后端以显式 constraint、relocation、发射与 icache 同步接管这些责任。
- `history`：Christian Roue 的 [SH4 报告](https://lists.gnu.org/archive/html/qemu-devel/2008-02/msg00320.html)，Alexander Graf 的[诊断回复](https://lists.gnu.org/archive/html/qemu-devel/2008-02/msg00338.html)，Thiemo Seufer 的[workaround 边界](https://lists.gnu.org/archive/html/qemu-devel/2008-02/msg00342.html)。
- `review`：Christian定位 `op_cmp_str_T0_T1` 的尾部布局和 `-fno-tree-dominator-opts`；Alexander建议 configure 检测；Thiemo希望 workaround减少而非扩张。
- `reasoning`：线程直接支持“GCC版本/优化形状造成构建失败”；它只是 Bellard公告所说“various GCC versions”问题的一个实例，不证明所有 target 都以相同方式失败。
- `experiment`：不复现 2008 toolchain；当前实验用 fixed commit 验证 TCG 路径。

### D3：TCG 来源与命名

- `claim`：TCG 来源为 generic C compiler backend + Paul Brook QOP，进入 QEMU 后简化。
- `current_source`：[`docs/devel/tcg-ops.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/devel/tcg-ops.rst)。
- `history`：初始 [`tcg/README`](https://gitlab.com/qemu-project/qemu/-/blob/c896fe29d6c8ae6cde3917727812ced3f2e536a4/tcg/README)。
- `review`：初始文档由 Fabrice Bellard随 TCG 基础提交加入。
- `reasoning`：只采用文档逐字能支持的范围；TinyCC关联保持 open，不在正文推断。
- `experiment`：无，属于来源事实。

### D4：用兼容桥渐进迁移 target

- `claim`：TCG 接入时可以承接 legacy dyngen op，各 target 分批迁移，旧 op 前后形成保守 basic block 边界。
- `current_source`：兼容桥已删除；现代边界由 temp/global/helper 和 `TranslatorOps` 表达。
- `history`：TCG 基础 [`c896fe29d6`](https://gitlab.com/qemu-project/qemu/-/commit/c896fe29d6c8ae6cde3917727812ced3f2e536a4)，接入 [`57fec1fee9`](https://gitlab.com/qemu-project/qemu/-/commit/57fec1fee94aa9f7d2519e8c354f100fc36bc9fa)，[公告](https://lists.gnu.org/archive/html/qemu-devel/2008-02/msg00011.html)。
- `review`：Blue Swirl 的 [SPARC WIP](https://lists.gnu.org/archive/html/qemu-devel/2008-02/msg00406.html) 与 Fabrice 的[设计回复](https://lists.gnu.org/archive/html/qemu-devel/2008-02/msg00427.html)涉及 T2/delay-slot restore、TCG globals和 target-specific 定义边界。
- `reasoning`：公告明确承诺 progressive conversion；“不能停机的引擎更换”是对可构建中间状态的叙事概括。
- `experiment`：`trace-riscv-decode`、`add-toy-instruction` 让读者在现代 RISC-V 接口上观察迁移终点。

### D5：opaque variable 把强类型落到 C 接口

- `claim`：Paul Brook发现变量、立即数和寄存器编号易混，建议 opaque TCG variable；两天后提交合入。
- `current_source`：当前 `TCGv_i32/i64/i128` 与 vector wrapper 延续类型区分。
- `history`：[Paul 的建议](https://lists.gnu.org/archive/html/qemu-devel/2008-02/msg00048.html)，[`ac56dd4812`](https://gitlab.com/qemu-project/qemu/-/commit/ac56dd48120521b530e48f641b65b1f15c061899)。
- `review`：邮件是 proposal，提交 author/committer 为 Paul Brook；没有额外 trailer。
- `reasoning`：强类型也服务 optimizer，但本记录只把“避免前端值类别混淆”归因于该线程。
- `experiment`：toy instruction检查 `rs1` 编号、immediate 与 `TCGv` 的分离。

### D6：删除过渡层

- `claim`：2008 年 12 月删除 `dyngen.c`，随后清理 `tcg-dyngen.c`、`dyngen-exec.h` 与遗留宏。
- `current_source`：`v11.1.0-rc0` 不包含运行时 dyngen。
- `history`：[`86e840eef7`](https://gitlab.com/qemu-project/qemu/-/commit/86e840eef78d5c6882cfd2befd8571e6cd98782f)，[`49516bc0d6`](https://gitlab.com/qemu-project/qemu/-/commit/49516bc0d622112caac9df628caf19010fda8b67)。
- `review`：后一个提交含 Laurent Desnogues 与 Aurelien Jarno Signed-off-by。
- `reasoning`：删除范围由 commit diff确认；“约十个月兼容期”按 2 月 1 日到 12 月 7 日计算。
- `experiment`：无。

### D7：优化保持轻量并依靠前端/helper选择

- `claim`：TCG 在 TB 内做常量/复制/位信息、可达性和 liveness等分析，不构建跨 TB 的重量级全程序优化；复杂/低频指令可进入 helper。
- `current_source`：[`tcg/optimize.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/tcg/optimize.c)，[`tcg/tcg.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/tcg/tcg.c)，[推荐编码规则](https://www.qemu.org/docs/master/devel/tcg-ops.html#recommended-coding-rules-for-best-performance)。
- `history`：初始 README 与更新 [`0a6b7b7813`](https://gitlab.com/qemu-project/qemu/-/commit/0a6b7b7813799f76e1859387688611af05db376c)。
- `review`：历史 commit 无完整邮件 review；当前结论以源码管线为主。
- `reasoning`：翻译时延、TB寿命、代码缓存、异常映射与 host 矩阵共同解释收敛；具体性能收益必须实验，正文不写无来源百分比。
- `experiment`：`dump-tcg-ir` 比较优化前后，`compare-host-code` 检查 constraint、spill和立即数物化。

### D8：RISC-V guest/host 两条演进线

- `claim`：RISC-V guest translator只描述 ISA 到 IR，RISC-V64 host backend负责 IR 到宿主代码。
- `current_source`：[`target/riscv/tcg`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/target/riscv/tcg)，[`tcg/riscv64`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/tcg/riscv64)。
- `history`：Michael Clark [`55c2a12cbc`](https://gitlab.com/qemu-project/qemu/-/commit/55c2a12cbcd3d417de39ee82dfe1d26b22a07116)；Alistair Francis 的 RISC-V host backend 系列从 [`fb1f70f368`](https://gitlab.com/qemu-project/qemu/-/commit/fb1f70f3685bae613d91626578bce96590ed2cb7) 延伸到 prologue/JIT 注册 [`92c041c59b`](https://gitlab.com/qemu-project/qemu/-/commit/92c041c59b99fbc35bdf4d5520fcaff80dc69ee0)。
- `review`：正文只使用 commit author与拆分顺序，不推断完整邮件角色。
- `reasoning`：guest/host 分离由目录、提交与当前调用链共同支持。
- `experiment`：同一 RV64 镜像跨 x86_64/RISC-V64 host 比较 guest结果和 IR。

### D9：SoftMMU 与精确异常是 IR 的执行合同

- `claim`：`qemu_ld/st` fast path使用 per-vCPU software TLB，miss进入 `riscv_cpu_tlb_fill()`；fault借 host return address与 TB 元数据恢复准确客户机 PC。
- `current_source`：[`accel/tcg/cputlb.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/tcg/cputlb.c)，[`target/riscv/tcg/cpu_helper.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/tcg/cpu_helper.c)，[`docs/devel/tcg.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/devel/tcg.rst)。
- `history`：precise exceptions先于 TCG；正文不把机制来源错误归给 2008 IR。
- `review`：当前源码事实。
- `reasoning`：software TLB 是 QEMU执行缓存，不代表真实 RISC-V硬件 TLB；正文明确区分。
- `experiment`：`inject-riscv-trap`、`trace-page-walk`（后者保留在旧第10章实验目录，正文合并到第11章原理）。

### D10：MTTCG 把串行假设变成显式同步

- `claim`：原 system TCG 单线程 round-robin，MTTCG 为每颗 vCPU 建线程，并补 TB、TLB、内存序和设备共享状态同步。
- `current_source`：[`docs/devel/multi-thread-tcg.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/devel/multi-thread-tcg.rst)，RISC-V `riscv_tcg_ops` 中 `.mttcg_supported = true`。
- `history`：option [`8d4e9146b3`](https://gitlab.com/qemu-project/qemu/-/commit/8d4e9146b3568022ea5730d92841345d41275d66)，TB lock [`2f16960660`](https://gitlab.com/qemu-project/qemu/-/commit/2f1696066049c25f7f7d75352aa0cad3b0b1d87e)，thread-per-vCPU [`372579427a`](https://gitlab.com/qemu-project/qemu/-/commit/372579427a5040a26dfee78464b50e2bdf27ef26)，async TLB work [`e3b9ca8109`](https://gitlab.com/qemu-project/qemu/-/commit/e3b9ca810980851f93f5719a7df2044c9435f003)。
- `review`：关键提交记录 Frederic Konrad、Paolo Bonzini、Alex Bennée 的 Signed-off-by，Richard Henderson 的 Reviewed-by。
- `reasoning`：原子字段不足以完成多步协议；此结论由当前设计文档的 shared structures、memory consistency与safe work章节支持。
- `experiment`：`compare-tcg-thread-modes` 用 RV64 shared memory、LR/SC、IPI、WFI和shootdown比较 single/multi。

## 当前源码阅读顺序

1. `target/riscv/insn*.decode` 与 `target/riscv/tcg/translate.c`：取指、decode、`DisasContext` 和 TB 出口。
2. `target/riscv/tcg/insn_trans/trans_rvi.c.inc`：`addi`、`lw`、`fence`、`fence.i`。
3. `target/riscv/tcg/insn_trans/trans_rvh.c.inc`：`hfence.*` 与 H load/store helper。
4. `tcg/tcg-op.c`、`tcg/optimize.c`、`tcg/tcg.c`：IR 生成、优化、liveness、regalloc与发射管线。
5. `tcg/riscv64/`：RISC-V64 host constraint、relocation、prologue和 op emission。
6. `accel/tcg/cpu-exec.c`、`translate-all.c`、`cputlb.c`：TB 执行、发布/失效与 software TLB。
7. `target/riscv/tcg/cpu_helper.c`、`tcg-cpu.c`：页表、异常、interrupt hook与 MTTCG 声明。

## 尚未提升为正文事实的开放项

- TCG generic C compiler backend 与 TinyCC 的具体代码谱系：缺少本轮查到的一手点名材料。
- QOP 代码库的独立历史与具体复用范围：初始 README 只说“has roots”，不足以逐文件归因。
- 2008 年各 target 完成迁移的精确时间表：正文只使用 SPARC、ARM和最终删除这几个能解释转折的节点。
- 某项 optimizer 对特定 workload 的百分比：必须由固定 commit、host和实验数据支持，书稿当前不预填数字。
