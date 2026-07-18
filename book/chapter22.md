# 从 Git 与邮件列表重建设计演进

源码里有一条看起来多余的条件分支，删掉以后 TCG 测试全绿，KVM-only 构建却失败。只看当前函数，开发者很容易把它解释成历史包袱；沿 Git 走回去，才发现这条分支来自一次 accelerator 边界整理，邮件评审还专门讨论了禁用 TCG 的配置。此时“多余”已经超出代码风格判断，变成一个可以被构建矩阵验证的假设。

QEMU 的设计理由很少完整地留在一处。当前源码说明最后合入了什么，commit message 记录作者提交时愿意长期保留的理由，qemu-devel 线程保存质疑、替代方案和版本变化，后续修复与测试又告诉我们最初假设在哪个现实条件下失效。要回答“为什么现在这样设计”，这些材料必须互相校验。

本书目标版本为 QEMU `v11.1.0`，研究锚点固定在官方 GitLab [`v11.1.0-rc0`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0)，commit `eca2c16212ef9dcb0871de39bb9d1c2efebe76be`。所有历史链最终都要回到这个树：更早提交解释来源，更晚邮件只能说明演进方向，尚未进入锚点的方案不写成现状。体系结构案例统一使用 RISC-V/riscv64。

## 本章目标

- 从当前符号提出可验证问题，用 path、`-S`、`-G`、blame 和 diff 找到引入与修复；
- 由 commit trailer 回到 qemu-devel/Patchew，比较 patch v1、后续版本与最终合入结果；
- 用事实、上游陈述、作者推断、开放问题四级表达设计结论；
- 把 RISC-V TCG 目录拆分与 K230 Machine 作为完整研究案例；
- 建立可复现的证据账本，让书稿以后更换 QEMU 锚点时能逐条更新。

## 问题要小到能被搜索

“QEMU 为什么这么复杂”没有可执行的搜索边界。把它改成“为什么 RISC-V 的 `cpu_helper.c` 位于 `target/riscv/tcg/`，而 `cpu.c` 仍在公共目录”，就有路径、提交和构建配置；改成“为什么 K230 当前只建模一颗小核并支持直接 `-kernel` 启动”，就能去找 Machine 源码、v1 到 v8 changelog、最终 commit 和 functional test。

问题通常来自三个入口。第一，当前代码中的特殊条件、注释、TODO 或兼容字段；第二，实验中观察到的边界，例如 KVM-only 构建不应链接 TCG CSR；第三，测试名称和修复提交暴露的不变量。先写一句可能被推翻的初始假设，再开始搜索。若搜索过程中问题不断换主题，拆成多条，不让一条证据链承担整个子系统历史。

固定锚点以后，确认 tag、commit 与工作树一致：

```console
git rev-parse v11.1.0-rc0^{commit}
git show -s --format=fuller eca2c16212ef9dcb0871de39bb9d1c2efebe76be
git status --short
```

研究使用完整历史。浅克隆会让 `--follow` 停在截断边界，partial clone 也可能在离线时缺对象。若命令没有结果，先确认历史可用，再记录“未找到”；不能把本地仓库不完整当成上游从未发生。所有链接指向官方 GitLab commit 或 blob，邮件引用保留 Message-ID，网页搜索结果只用于定位。

## 从 MAINTAINERS 找到代码的社会边界

[`MAINTAINERS`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/MAINTAINERS) 不只是一份联系人列表，它把文件模式、邮件列表、维护状态和责任人关联起来。研究 `target/riscv/`、`hw/riscv/`、K230 或 migration 时，先找对应条目，可以知道补丁发送到哪一组、哪些维护者的 review 更接近该子系统决策。代码目录边界与维护边界往往相关，却不保证完全重合。

维护者的身份不是设计证据。某人出现在条目里，不能推出他支持某个方案；`Reviewed-by` 表示对提交版本的审阅，也不能代替线程中具体意见。正文若说“上游认为”，至少要有 commit message、cover letter 或回复原文对应。找不到明确陈述时，写作者推断，并列支撑的源码和测试。

路径移动后，MAINTAINERS 也可能变化。当前条目告诉我们现状，历史提交中的 `get_maintainer.pl` 结果可能不同。研究一份旧 patch 应看当时的文件与收件人，不能用今天的团队结构解释几年前所有决定。需要讨论责任迁移时，对 MAINTAINERS 自身运行 Git 历史。

维护状态同样要谨慎解释。`Maintained` 说明有人承担维护，不代表每个角落都完整；`Orphan` 说明缺少明确维护者，不等于代码不可用。状态可以帮助评估 review 路径和风险，不能直接变成功能质量结论。

## Git 的五种入口

第一种是按路径查看：

```console
git log --follow --stat -- target/riscv/tcg/cpu_helper.c
```

`--follow` 对单文件重命名有帮助，复杂拆分、合并和同时改写仍可能断链。遇到一次机械移动，阅读该提交的 rename detection，再在旧路径继续。目录级历史不能完全依赖 `--follow`，可先看整个子树的提交，再跟关键符号。

第二种是 pickaxe `-S`，寻找某个字符串出现次数发生变化的提交：

```console
git log -S'riscv_cpu_swap_hypervisor_regs' --oneline -- target/riscv
```

它适合函数、字段、属性和宏的引入或删除。符号被重命名，旧名和新名都要搜；代码生成或宏展开后才出现的名称，可能不在源码历史。`-S` 没结果只说明该字符串计数没有按预期变化。

第三种是 `-G`，按 diff 正则匹配变化行：

```console
git log -G'CONFIG_(TCG|KVM)' -p -- target/riscv
```

它适合条件、调用模式或多个相关符号，结果通常比 `-S` 多。先用 `--oneline` 缩小，再读完整 diff；直接对全仓库 `-G'.'` 只会得到噪声。路径限制也可能漏掉一次跨目录重构，必要时移除路径做第二轮。

第四种是 blame。它很适合从当前一行跳到最近提交：

```console
git blame -L '/riscv_cpu_register_gdb_regs_for_features/',+25 \
    v11.1.0-rc0 -- target/riscv/gdbstub.c
```

blame 指向最近触碰该行的提交，可能只是移动、格式化或变量改名。拿到 hash 后继续看父版本、`git show --find-renames` 和更早 pickaxe。把 blame 的作者名写成“设计者”尤其危险，一次机械整理也会获得整段行的归属。

第五种是测试反向搜索。当前测试里的 assertion、错误字符串、bug URL 或 commit subject 常能找到修复；修复 diff 又指回引入提交。设计边界往往在失败后才清楚，研究只停在功能引入会漏掉真正不变量。时间线至少留出“引入—回归—修复—回归测试—当前位置”五列。

:::: {.quick-quiz}
为什么 `git blame` 不能单独回答“为什么这样设计”？

::: {.quick-answer}
blame 只指向当前行最近一次变化，常落在移动、重命名或格式化提交。设计理由可能在更早的引入、整组 patch cover letter、review 回复和后续修复中；拿到 hash 后仍要沿父版本、符号历史和邮件继续追。
:::
::::

## 先读完整提交，再引用一句话

一条可靠记录至少包含 commit hash、作者/提交时间、subject、正文、diff、测试和 trailer。subject 适合索引，不足以表达范围。“fix migration”可能只修一种 irqchip；“move TCG code”可能仍留下少数公共 helper。正文中的限制条件与 diff 中真正变化的文件要互相对照。

查看提交时使用 `--format=fuller`，区分 author date 与 commit date；用 `--stat` 看范围，再读 `--patch`。合并提交的正文可能来自 pull request 摘要，设计信息常在被合并的单个提交。机械生成的 diff 要与生成源一起看，例如 decodetree 规则变化不应只研究生成文件。

commit message 是合入后的长期说明，证据强度高于某版 cover letter，但它也可能省略审查争议。正文中“提交说明指出”只转述明确写出的因果。若提交只陈述行为，作者从目录和构建结果推断模块边界，应标作推断。

trailer 各有语义。`Signed-off-by` 表示 DCO 流程，`Reviewed-by` 和 `Acked-by` 表示对应版本的审阅/认可，`Tested-by` 说明有人在特定环境测试，`Fixes` 指向被认为引入问题的提交，`Cc: stable` 表示稳定分支考虑，`Message-ID` 或 `Link` 提供邮件入口。它们不能互换，也不能从一个标签推导评审者对所有设计细节的立场。

提交必须属于研究锚点。用 `git merge-base --is-ancestor COMMIT v11.1.0-rc0` 验证；网页上更新的主线提交即使主题相关，也只能放“后续演进”。研究分支和发行版 backport 另列，不能把未进入官方 tag 的接口混进源码讲解。

## 从 Message-ID 回到补丁系列

QEMU 的公开 review 主要发生在邮件列表。最终提交常保留 `Message-ID:` 或 `Link:`，可直接打开 lore；缺少链接时，用精确 subject、作者和日期在归档检索。Patchew 把系列、各版 diff 与应用状态组织得更直观，仍要保留原 Message-ID，避免只引用会变化的搜索页面。

先读 cover letter。它说明目标、范围、依赖、测试、已知限制和版本 changelog；随后读目标 patch 的 commit message 与 diff；最后展开相关 review 回复。大型系列不必逐句抄录，每条与研究问题有关的意见记录提出者、问题类型、作者回应、下一版变化和最终状态。

版本号是关键。v1 的接口可能被 v3 重写，v5 的说明可能仍引用已删除字段。比较 vN 与 vN+1 时，先看 cover letter changelog，再用 Patchew diff 或下载 mbox 应用到临时分支。结论只有在最终提交仍保留时，才能描述当前设计。未采用意见写成“评审曾建议”，不能写成“当前要求”。

邮件线程里也有范围拆分。维护者可能认可方向，却要求迁移、测试或文档另起系列；作者可能先合入基础设施，设备后来才进。某个 patch 被丢弃不证明想法错误，也许依赖未成熟、基准不足或超出本轮。研究记录要写状态：merged、superseded、withdrawn、RFC、pending，而非只有“找到/没找到”。

引用邮件时尽量转述，保留链接与 Message-ID。截取一句脱离上下文容易把条件句变成绝对结论。若上游只讨论性能，没有谈安全或兼容，书中不要补成全方位动机。作者可以提出更广的工程解释，等级必须降为推断。

:::: {.quick-quiz}
patch v1 的设计说明能否直接当成最终实现依据？

::: {.quick-answer}
不能。评审会改接口、拆范围、补测试，甚至替换方案。应比较每版 changelog、最终合入 diff 与当前锚点，确认哪些陈述仍对应代码；未合入的想法只能作为评审历史或开放方案。
:::
::::

## 四级陈述法

“源码事实”由固定 tag 的代码、测试、文档或规范直接确认。例如 `v11.1.0-rc0` 中 RISC-V TCG helper 位于 `target/riscv/tcg/`，`gdbstub.c` 的 CSR callback 受 `CONFIG_TCG` 条件控制。事实写清版本和路径，不夹带目的。

“上游陈述”来自 commit message、cover letter 或 review 中明确说明的理由。例如提交说移动 TCG-only 文件是为了清理公共目录并暴露埋在 TCG helper 中的公共代码，这可以转述并链接 commit。另一位作者用不同措辞总结时，仍要标来源。

“作者推断”把多条事实连接成工程解释。例如目录移动、KVM-only 构建和 GDB 条件隔离共同支持“上游在强化 accelerator 依赖边界”。这条解释很有用，却未必是任何一封邮件的原句。正文可写得肯定而清楚，同时显式标“作者据此推断”。

“开放问题”保留证据缺口。没有在固定 tag 找到 KVM RISC-V 某个 CSR 的 GDB 同步，只能写当前显式路径未覆盖或待验证，不能宣称内核永远不支持。邮件中有 RFC、没有最终提交，则写方案在讨论。开放问题应带下一步：要找哪个 UAPI、跑什么实验、等待哪条 series。

同一段里混合等级时，用语言分界。“当前代码调用 A；提交说明把 B 列为原因；由 A、B 与测试 C，作者推断 D；是否也为 E 服务，尚无邮件证据。”这种写法比段末统一放一个“可能”更容易审查。

证据等级会随研究变化。找到维护者原话后，推断可升为上游陈述；运行实验闭环后，开放问题可变成指定环境的事实；切换 QEMU tag 后，旧事实仍属于旧版本，不能自动迁移。账本保留日期与锚点，升级要留下变更记录。

## 案例一：RISC-V TCG-only 目录拆分

当前树把译码、CSR、异常、向量 helper 等大量 TCG 实现放在 [`target/riscv/tcg/`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/target/riscv/tcg)，公共 CPU 与模型仍在 `target/riscv/`，KVM 实现在 `target/riscv/kvm/`。单看目录可以描述分层，不能说明它何时、为何形成。

路径历史定位到提交 [`d45b9bc6`](https://gitlab.com/qemu-project/qemu/-/commit/d45b9bc65515e376f360cc8c2877cc94f22d4e49)，Message-ID `20260703180538.3346781-5-daniel.barboza@oss.qualcomm.com`。提交一次移动 50 个文件，绝大多数为 rename，正文明确说 RISC-V 公共目录里有过多 TCG-only 代码，移动能清理目录，也能暴露藏在 TCG helper 内的公共实现；它还说明少量文件暂留，后续再处理。这些属于上游陈述。

这不是孤立的整理。相关 [24-patch v4 系列](https://patchwork.ozlabs.org/project/qemu-devel/list/?series=511999) 继续搬移 CSR/debug/PMP/IRQ helper，并检查禁用 TCG 的构建边界。系列中的提交 [`002749d2`](https://gitlab.com/qemu-project/qemu/-/commit/002749d230f63ba32d24a3139b69e86fe8f0c808)，Message-ID [`20260703180538.3346781-20-daniel.barboza@oss.qualcomm.com`](https://lore.kernel.org/qemu-devel/20260703180538.3346781-20-daniel.barboza@oss.qualcomm.com/)，把 GDB CSR、virtual 与动态 CSR feature 限制在 TCG。提交正文直言这些函数若用于 KVM 会出错，并提出未来按 accelerator 拆 gdbstub 的方向。

当前事实与上游陈述合在一起，支持一个强推断：这组变化在用目录和构建条件表达状态所有权，减少 KVM-only 二进制意外引用 TCG 语义。推断不等于所有公共/私有边界已经完成；首个提交自己就说仍留下一些内容，后续 series 也逐项处理。研究结论应保留这个渐进性。

验证不能只看文件移动。检出父提交和锚点，分别配置 riscv64 system emulator 的 TCG-only、KVM-capable 或禁用 TCG 组合，比较编译对象与链接错误；再追一个符号从旧路径到新路径，确认行为 diff 主要是移动。若测试结果与提交陈述一致，可以说构建边界得到实验支持，仍不能从一次构建证明所有 accelerator 共享状态正确。

机械 rename 还提醒我们，blame 会把许多行指向 `d45b9bc6`。这些行的算法设计可能早几年形成。研究具体 CSR 或 MMU 原理时，应在提交父版本用原路径继续 `-S`；研究目录边界时，移动提交正是目标。相同 hash 对不同问题的证据价值并不相同。

## 案例二：K230 从 v1 到 v8

当前锚点包含 [`hw/riscv/k230.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/k230.c)、K230 watchdog、qtest 与文档。Machine 初始支持最终合入提交为 [`6cf0d08c`](https://gitlab.com/qemu-project/qemu/-/commit/6cf0d08c3953ee447cb215edc3a384834cbe48db)，Message-ID [`a161697a249b896e44e2748435f6c0caec12c9f4.1781246408.git.chao.liu@processmission.com`](https://lore.kernel.org/qemu-devel/a161697a249b896e44e2748435f6c0caec12c9f4.1781246408.git.chao.liu@processmission.com/)。提交正文确认先支持 C908 小核，可运行 K230 SDK 构建的 U-Boot 与 Linux；QEMU 不自动生成 K230 DTB，直接启动可由用户传入。

[K230 v8 系列](https://patchew.org/QEMU/cover.1781246408.git.chao.liu%40processmission.com/) 保存了逐版 changelog。v2 增加 Svpbmt 并调整文档归属，v3 对齐 C908 扩展、根据数据手册调整 PLIC/CLINT 地址，v5 修复 reset vector ROM 跳转，v7 修复访问未实现 UART 导致的 Oops、把 hart 数调为一、支持直接 Linux 启动并修正 watchdog IRQ，v8 修正 mode 检查并注册 riscv64 Machine interface。这些是 cover letter 的明确上游陈述，不能压成“反复 rebase”。

这个时间线展示了四种证据源。硬件手册约束地址与 IRQ，固件/内核实际启动暴露 reset vector 和 UART 行为，QEMU 框架要求 Machine interface，review 与 qtest 约束 watchdog。早期模型能够编译、甚至启动某一固件，仍可能在另一条路径 Oops。设计逐版收敛，靠的是外部行为和框架契约共同施压。

最终提交不等于系列最后一页的所有文本。研究者要将 v8 patch 与 `6cf0d08c` diff 比较，确认文件、属性和描述进入锚点；再检查 watchdog 提交 [`dace3986`](https://gitlab.com/qemu-project/qemu/-/commit/dace398674df8af11df13f2554e8566e9de3f8c7) 与测试。系列被应用到维护分支后还会经过 pull，hash 与邮件 patch 不必相同，Message-ID 是连接它们的稳定线索。

功能合入以后，提交 [`a539bb91`](https://gitlab.com/qemu-project/qemu/-/commit/a539bb911ee1085c69ce00781acd2f13bd3cb82b)，Message-ID [`20260711125320.72319-1-caojunze424@gmail.com`](https://lore.kernel.org/qemu-devel/20260711125320.72319-1-caojunze424@gmail.com/)，又增加 direct Linux 与 U-Boot 两条 functional boot test，并固定资产与 SHA-256。它属于后续证据：初始 series 的 qtest 保护 watchdog，functional test 保护整机启动，二者覆盖层次不同。

作者由此推断，K230 当前模型的边界由“真实 SDK 行为、可公开验证的硬件资料、QEMU Machine 约定和可维护测试”共同形成。这个推断不能改写成“当前模型完整复现 K230”。最终提交自己限定为初始支持，当前设备列表仍有未实现区域；大核和更多外设要看后续固定提交。

:::: {.quick-quiz}
为什么修复提交和后续测试常比最初引入提交更能说明设计边界？

::: {.quick-answer}
引入提交描述预期，修复暴露某个假设在真实固件、并发、迁移或构建中怎样失效，测试再把不变量固定下来。完整历史应同时包含引入、评审变化、失败、修复与当前测试，不能只复述初版设计。
:::
::::

## 区分重构、行为变化与兼容修复

提交写“no functional change”时，先看 diff 是否真是 rename、函数搬移或机械替换，再用构建和测试佐证。代码移动会改变 include、链接对象、条件编译和初始化顺序，即使算法不变也可能暴露新问题。书中可以说上游声明无功能变化，不能把它升级为数学证明。

行为变化要找客户机可见面。RISC-V 地址、CSR、异常 cause、IRQ、DTB、Machine 属性与迁移字段变化，都可能形成兼容影响。diff 只改内部 helper，也可能改变返回或时序；反过来，文件很大但全是移动，客户机行为可能不变。评估以接口与实验为准，不按增删行数。

兼容修复常保留旧分支。`Fixes:` 指向引入提交，commit message 解释为什么不能简单统一；Machine compat 或 VMState version 又可能让旧行为继续存在。看到分支先问它服务哪个版本/配置，查对应测试。删除前需要证明所有支持范围都不再使用，而非只跑默认 RISC-V `virt`。

安全修复可能刻意缩短公开说明，邮件线程也可能延后。此时当前 diff、测试和公告是主要事实，作者不应填补未公开根因。能说“增加长度校验并在 vCPU 运行前拒绝”，不能猜具体攻击路径。证据纪律同样保护安全信息。

## 负面证据怎样写

“`git grep` 没找到”很弱。先限定 tag、目录、符号同义词、生成代码和条件编译，再用 `git log -S/-G` 搜删除或重命名。仍未找到时，结论写“在固定锚点的这些显式路径中未发现”，附命令。它支持开放问题，通常不足以证明功能不存在。

邮件没有回复不表示认可。可能无人有时间、收件人错误、问题在别处讨论，或作者线下修改。只有明确 review tag、应用回复和最终提交能说明系列状态；即使合入，也不能说每位收件人赞成全部理由。

测试缺失只证明当前没有找到覆盖。功能可能由更高层测试间接触发，也可能完全未测。账本同时记录 direct、indirect、unknown，下一步用故障注入确认某测试是否会失败。测试文件存在也不能自动算覆盖，要读 assertion 和配置。

某个 bug 在锚点无法复现，也不证明从未存在。修复可能已经合入，环境条件可能不同，观测又可能改变时序。研究历史 bug 时，在引入后、修复前的可构建 commit 上复现，保存条件；当前版本只验证回归测试仍通过。

## 证据账本

本仓库用 `book/research/evidence-ledger.md` 保存章级入口，具体研究再建条目。每条至少包含：问题、当前符号/路径、锚点、引入提交、相关 Message-ID/系列、后续修复、测试、实验、陈述等级、开放问题和最后复查日期。链接之外保存 hash 与 Message-ID，网页布局改变后仍可定位。

事实表与叙述笔记分开。事实表记录“commit X 移动文件”“v7 changelog 写了 Y”；叙述笔记解释这些变化如何回答问题。更新 tag 时先重跑事实表，再判断解释是否仍成立。若直接在散文里改版本号，旧路径、删除字段和后来修复很容易漏掉。

一个结论可有多条来源。当前源码证明实现，上游邮件证明动机，测试证明某个行为，规范定义客户机要求。账本为每条来源标角色，避免用规范推导 QEMU 已实现，也避免用源码行为替代规范正确性。四者冲突时，冲突本身就是研究结果。

实验材料保留命令、配置、二进制和结果哈希。邮件 mbox 可在许可和存储策略允许时缓存，至少保存归档链接与 Message-ID；外部硬件手册记录版本和页码。生成图或时间线的脚本进仓库，手工筛选规则写清楚。

## 面向书稿的写作流程

第一轮只写当前调用链，确保读者能从入口走到状态变化。第二轮插入历史节点，解释哪些边界由引入、评审或修复形成。第三轮给实验验证，并把无法闭合的部分降级。历史不能抢走原理主线，原理也不能脱离实现证据。

引用 commit 时不堆 hash。先讲它改变的工程约束，再给链接；连续系列可以用一条时间线，挑与结论直接相关的几项。五十个无解释的提交号不比一条完整链更可靠。读者应该知道为何打开链接、要核对哪个字段。

邮件中的争论用转述呈现。写出问题属于正确性、性能、兼容、测试还是维护性，下一版如何回应。避免把 review 写成戏剧化输赢；没有采用的方案也可能有合理场景。技术结论落在最终代码和实验，人物只承担来源角色。

每节末做一次等级审查。有没有把“可能”换成了“因此”，有没有从一个平台推广到所有 RISC-V，是否把主线之后的 patch 写进当前实现，链接是否仍指固定 tag。写得流畅不能提高证据等级，恰恰更需要这次停顿。

## 提交图不是一条直线

QEMU 子系统通常先进入维护者分支，再由 pull request 合并到 staging，之后进入 release。`git log --first-parent` 展示集成节奏，普通 `git log` 展示单个 patch；两种视图回答不同问题。研究功能实现要落到单个 commit，研究它何时进入主线可看 merge/pull。只引用 merge subject，读者很难定位真实 diff。

author date 表示作者创建提交的时间，committer date 可能是维护者应用或 rebase 的时间，邮件发送又有自己的 Date。三者不一致很常见。时间线以可说明的事件命名：“v8 发送”“维护分支应用”“进入 rc0”，不把一个日期泛称“功能完成”。时区保留原值或统一换算并注明。

同一 patch 经 `git am` 后 hash 会因正文、父提交或 trailer 变化。邮件中的 patch-id 可以帮助判断内容相似，Message-ID 连接评审身份，最终 Git hash 锚定合入对象。三者各有用途。把邮件里给出的旧 hash 当作 tag 内 commit 搜不到时，先比较 subject、作者、diff 与 Message-ID，不要立刻判定未合入。

维护分支可能 squash、拆分或修改。cover letter 的五个 patch 进入主线后仍可能是五个，也可能某项延期。研究者制作“邮件 patch—最终 commit”映射，每行记录相同、修改、拆分、未合入。只有映射完成，才可把某条 review 意见连接到当前代码。

release branch 的 backport 又形成另一条图。`Fixes` 提交在主线出现，不代表目标发行版包含；发行版带额外补丁，也不代表官方 tag 现状。本书只把官方 rc0 祖先当当前事实，部署章节若讨论发行版，应另列包版本和补丁清单。混用仓库会让同一函数出现互相矛盾的“当前实现”。

merge-base 检查适合自动化。证据账本中的每个 commit 都跑 `git cat-file -e` 和 `git merge-base --is-ancestor`，结果保存；非祖先条目标记 post-anchor 或 side branch。更新锚点时重跑，即可看哪些演进已进入，而不靠人工翻网页。

## `range-diff` 和 patch-id 看版本怎样收敛

cover letter 的 changelog 是作者摘要，可能漏掉某个小改动。取得两个版本 mbox 后，在临时分支应用，用 `git range-diff base..v7 base..v8` 比较 patch 对应、commit message 与 diff。系列 rebase 到不同基线时，先选各自 merge-base，避免上游无关变化淹没目标差异。

`range-diff` 的配对是启发式，不是证明。patch 拆分或重写后可能匹配错误，仍要读目标文件。对 K230，可围绕 `hw/riscv/k230.c`、CPU 定义、watchdog 与 qtest 分别比较；看到 v7 调整 hart 数和 UART，再回到 cover letter 确认作者陈述。工具发现变化，邮件解释理由，当前源码确认结果。

`git patch-id --stable` 可辅助识别跨 rebase 的等价 patch。它忽略部分元数据，内容略改就会变化，两个 patch-id 相同也不说明 commit message 与 trailer 相同。研究 review 时不能只留 patch-id，因为设计说明往往恰在 message 中更新。

diffstat 适合发现范围漂移。一个“设备模型”系列突然改通用 RISC-V CSR、Machine 和测试，review 风险增加；也可能是合理依赖。逐版记录文件集合，能看出维护者要求拆分、补测试或把通用 API前置。范围缩小不表示功能缩水，可能让接口先独立合入。

应用旧 patch 要用临时 worktree，不污染研究锚点。记录基线 commit、`git am` 结果与手工冲突；需要改才能构建时，改动另成实验 patch，不能把调整后的行为当作原版结果。Patchew 显示“applied”只说明它对某个当时树成功，不代表今天的 rc0 可直接应用。

## 评审意见按工程问题分类

正确性意见问模型是否符合 RISC-V 规范、硬件资料和客户机行为。K230 的 PLIC/CLINT 地址、watchdog IRQ、mode 检查属于这一类。记录引用的手册版本、具体寄存器或启动现象，下一版是否修改。只写“reviewer 要求修复”会丢掉可复核的技术约束。

兼容性意见关注已有 Machine、迁移、QMP、命令行与默认值。新增属性是否改变旧客户机，VMState 是否需要版本，未实现寄存器应返回什么。评审没有提兼容，不代表没有风险；作者可以从代码识别并提出开放问题，不能伪造邮件共识。

性能意见需要基准。评论者可能担心热路径锁、trace、额外 ioctl 或 TB 失效，作者用数据修改方案或证明成本可接受。记录 workload、硬件、方差和对照，不能只摘“性能没问题”。最终代码换了实现，旧基准也可能失效。

维护性意见涉及目录、公共/私有 API、生成代码、命名、测试位置和未来扩展。TCG-only 搬移主要展示这一维度，同时有构建正确性。维护性理由常被误写成“纯风格”；当它决定 KVM-only 构建能否隔离依赖时，已经是结构约束。

测试意见最容易验证。review 要求 qtest、functional、迁移或负面路径，下一版是否添加，最终测试能否在锚点运行。若测试延后合入，时间线明确分开。一个 `Tested-by` 标签说明有人测试该版，不等于仓库留下自动回归。

文档与用户接口意见也有独立价值。命令行、DTB 来源、支持设备、已知限制写进文档，会影响用户期待。K230 系列把 direct boot 与 DTB 约束逐版写清，当前文档可作为现状事实之一。文档若落后于源码，冲突应报告，不能挑更方便的一边。

## 用修复提交提取不变量

从当前特殊分支向后跑 `git log -S`，若找到 `Fixes:`，先读被指提交与修复测试。把失败写成“在条件 C 下，旧假设 A 导致状态 B 偏离”，再看修复建立了什么不变量。单写“修复空指针”太浅，可能遗漏对象为何在该生命周期为空。

修复往往只覆盖一个配置。RISC-V TCG 修复不自动适用 KVM，模拟 AIA 修复也不自动覆盖内核 irqchip。commit message、`#ifdef`、Meson 条件和测试命令共同限定范围。书中避免把 subject 去掉限定词后推广。

回归测试是可执行的不变量。先在修复父提交运行确认红，再在修复提交确认绿；若旧版本无法构建，记录原因，至少读 assertion 和故障注入。测试一直绿可能是环境没走到路径，不能直接当证明。触发条件比测试文件名更重要。

随后找“fix the fix”。第一次修复可能引入性能或兼容问题，第二次提交会重新界定边界。用 `git log --ancestry-path` 不能保证找到语义后续，仍要按符号和错误字符串搜索。时间线不设固定结束点，直到锚点当前实现和测试都能解释。

删除代码也可能是最终修复。实验性 QAPI 字段因语义混乱被移除，未必有替代字段；旧 workaround 在底层 API 精确后被删掉。研究者若只搜“添加”，会把现状解释成缺功能。删除提交正文常直接说明旧抽象为什么不再成立。

一个强不变量最好有三角证据：修复 diff 改变状态路径，测试能重现，邮件/commit 解释条件。少一角时结论仍可用，但降级：只有 diff 是事实，只有测试现象是指定环境事实，只有邮件提案仍是上游陈述。三者冲突时先检查版本和配置。

## 规范、硬件资料和客户机软件怎样进入证据链

Git 和邮件只能解释 QEMU 选择，不能单独证明选择符合 RISC-V 规范。CSR 权限、异常 cause、H 扩展两阶段转换应对照固定规范版本；SoC 地址和 IRQ 对照可引用的硬件资料；启动流程再由 OpenSBI、U-Boot、Linux 行为验证。每种来源回答不同层次。

规范版本必须写清。RISC-V 扩展从 draft 到 ratified 可能改字段，QEMU CPU 属性还会选择不同 priv spec。邮件作者说“按规范”时，追链接或日期，确认是哪版。用今天文档解释旧 commit，可能把当时正确的实现误判为错误。

硬件资料也可能不公开或版本冲突。可确认的地址、reset 值和 IRQ 写事实；来源不稳定时保留页码与摘要，不能公开的资料不宜成为开源模型唯一证据。K230 v3/v7 changelog 明确说依据数据手册调整，这属于上游陈述；本书若进一步解释寄存器，仍需可审计资料或实验。

客户机软件是重要的行为探针，却不是硬件规范。某版 Linux 驱动只使用寄存器子集，QEMU 能启动它不代表完整模型；厂商固件依赖未规范行为，也可能迫使兼容模型保留。研究记录把“驱动需要”“手册规定”“QEMU 选择”分三栏，避免相互替代。

多个来源冲突时，先缩小条件。手册版本、芯片修订、固件配置、CPU 扩展和 QEMU Machine 都可能不同。无法消解时写开放问题，设计实验区分。例如两个 IRQ 编号冲突，可触发 watchdog 并观察真实板路由；没有硬件时，不把其中一个猜测写成事实。

## 处理相互冲突的上游陈述

邮件 v3 说接口 A 会保留，最终提交却删除 A，当前源码优先回答“现在是什么”；v3 说明仍能作为曾考虑方案。commit message 与代码不一致时，先检查同系列后续 patch 是否调整，或提交说明是否描述预期而实现有 bug。不能为保持叙述顺滑而忽略冲突。

两位维护者可能提出相反意见，线程最后通过第三种方案收敛。正文不选一句当“上游观点”，应描述约束：一方关注 ABI，另一方关注维护成本，最终 diff怎样权衡。若线程没有结论且 patch 未合入，保留讨论状态。

测试与文档冲突时，运行锚点测试确认。测试成功可能因为没有触发文档所述限制，文档也可能过时。找到修复或文档提交前，事实写成“源码/测试观察 X，文档写 Y”，不要自行统一。冲突条目进入证据账本的高优先级待办。

时间也会改变结论。早期邮件说某宿主 API 不可用，后续内核增加后，QEMU 设计可能调整。旧陈述限定到日期和版本，不能用它否认当前实现；当前功能也不能反过来嘲笑早期选择。工程设计总在当时约束下成立。

引用 review 建议时区分疑问和断言。“Could this race?” 是要求证明，不是已发现竞态；“This violates X because...” 才是明确技术判断，最终是否被接受仍看回复和 diff。转述语气保持原强度，是证据研究的基本礼貌。

## 自动化证据校验

书稿链接可以机械检查。对每个 GitLab commit URL 提取 hash，验证对象存在且为锚点祖先；对 blob URL 验证 tag 下路径存在；对 lore URL 提取 Message-ID，与 commit trailer 或系列记录比对。检查失败先阻断发布，避免一条手误链接让整段无法复查。

代码符号会移动。研究笔记保存路径与符号两种定位，更新 tag 时先 `git grep` 符号，再看 path history。行号链接容易随 tag 改变，同一固定 tag 内可用，跨版本笔记更适合文件链接加函数名。书中关键调用链同时写符号，读者可以在本地 `rg`。

证据表可以生成一份状态报告：祖先、路径存在、邮件链接、实验最近运行、陈述等级。自动化只能验证引用结构，不能判断推断是否合理；人工 review 仍要读上下文。把“链接有效”误当“论证成立”，只是换了一种自动化幻觉。

外部网页会暂时不可用。hash、Message-ID 和 subject 留在正文，即使归档故障仍能重新搜索；关键 changelog 可在研究笔记中做有限转述，不大段复制。缓存 mbox 时保留来源和取得日期，后续使用仍链接公共归档。

实验结果也应可校验。结果文件记录 QEMU commit、构建摘要和输入哈希，分析脚本生成摘要；CI 可重跑便宜的历史命令和链接检查，耗时构建标最近验证日期。一本长期维护的源码书，证据过期是正常状态，静默过期才危险。

## 常见研究误区

第一种是从当前命名倒推原始意图。一个函数今天叫 `common`，也许由 TCG helper 移出；名字表达现状，不证明它从诞生就服务多个 accelerator。历史问题要看引入时的调用者。

第二种是把最早提交当唯一设计。后续 bug、性能数据和兼容属性已经改变约束，书稿仍复述 v1，会给读者一套过期心智模型。至少搜到锚点，列最后一次语义变化和测试。

第三种是以提交数量衡量重要性。一个一行 memory barrier 可能保护 MTTCG 发布，一个千行 rename 可能无行为变化。证据权重取决于不变量和客户机影响，diffstat 只帮助导航。

第四种是把 review tag 当成动机。`Reviewed-by` 很重要，却没有告诉我们具体哪项权衡；需要引用理由时读线程。反过来，没有 tag 也不说明无人审查，pull 流程和邮件上下文可能不同。只写可确认状态。

第五种是把邮件搜索摘要当原文。搜索引擎会截断、排序变化，也可能混入同 subject 的其他版本。打开完整线程，核对 From、Date、Message-ID、In-Reply-To 和 patch 内容，再做记录。

第六种是只保存最终网页链接。几年后归档路径变化，缺 hash/Message-ID 就无法恢复。稳定标识写进正文与账本，URL 是方便入口。

第七种是为了故事完整填补空白。工程历史经常没有公开决定，或者理由只存在于未归档会议。此时写“尚未找到公开证据”，提出源码和实验推断即可。空白不会削弱书，伪造的确定性才会。

## 用同一方法研究测试框架和 Rust 接入

测试框架的四个 2024 提交形成小型系列：基础类去除 Avocado 依赖，Meson 区分 quick/thorough，测试可直接执行，资产按内容哈希缓存。逐个 commit 能看功能，Message-ID 串起系列后，才看到“反馈速度、调试入口、外部输入”如何一起塑造框架。这个案例也提醒我们，当前目录名不足以解释迁移动机。

Rust 接入同样需要系列视图。先有构建 feature，随后 bindgen 依赖、bindings/interface crate，再有首个设备；迁移支持由另一提交补入。若只看今天的 `rust/` 工作区，很容易写成一次完整引入。历史说明基础设施和设备能力分阶段合入，当前 API 又在后续提交中继续重组。

这两个案例与 K230 共享一条方法：固定当前路径，找引入系列，比较各版，找后续修复/测试，最后回到锚点。不同的是证据重点。测试框架关注 runner 与资产，Rust 关注构建/FFI/生命周期，K230 关注硬件和启动。研究流程稳定，判断维度随子系统变化。

同一 commit 也可能跨章复用，但结论不能复制。Rust bindings 提交在构建章说明生成顺序，在安全章说明 raw FFI 边界；K230 functional test 在测试章说明资产，在本章说明合入后补强。每次引用写它对当前问题提供什么证据，防止 hash 变成装饰。

## 形成可审查的历史结论

交付研究前，让另一位读者从问题开始复走。只给他锚点、命令和账本，不口头补充；他是否能找到同一提交、邮件和当前符号，是否能区分事实与推断。走不通的地方通常暴露路径遗漏、版本含混或链接只到搜索页。

再做反方检查。假设作者推断错误，现有证据还能有哪些解释？目录拆分可能主要为构建，也可能为了维护性；K230 hart 数变化可能来自当前支持范围，而非硬件总核数。把可替代解释列出来，找邮件或实验区分；无法区分就缩短结论。

结论的适用范围写在句子里。不要在章首说一次“仅限 rc0”，后文反复用现在时推广。写“在 `v11.1.0-rc0` 的 riscv64 system emulator 中”，读者立即知道后续版本和 user-mode 不在范围。关键限制重复一两次比隐藏在脚注更安全。

最后检查可行动性。设计解释应帮助读者审补丁：新增 RISC-V helper 应放公共还是 TCG/KVM，K230 设备需要哪些 qtest/functional，Rust API 变化要追哪些系列。只讲历史趣闻，不能指导当前工程；只给规则没有演进证据，又容易成为个人偏好。两者结合才是本书需要的“为什么”。

## 一张最小评审时间线怎么写

时间线第一列是事件，不只是日期。`current-question` 记录从锚点提出的问题，`v1-posted` 记录初版范围，`review` 记录具体异议，`vN-posted` 记录回应，`merged` 记录最终 hash，`fix` 与 `test` 记录后续约束。事件名稳定以后，日期只负责排序；同一天多封邮件也不会混成一格。

第二列保存对象身份：commit hash、Message-ID、series cover Message-ID、文件和符号。subject 会改，作者邮箱也可能变化，这些 ID 让连接可复查。若一封回复同时讨论多个 patch，把 patch index 和引用上下文写上，避免后来把意见套到错误文件。

第三列只写原始陈述的短转述，第四列写代码变化。比如“v7 changelog 说未实现 UART 访问导致 Oops”与“下一版为相应地址设置未实现设备/调整访问路径”分开；前者是上游陈述，后者由 diff 确认。两列一致时证据增强，不一致时立刻暴露待查点。

第五列写验证。构建、qtest、functional、迁移或源码检查各自给出命令和结果。review 要求“增加测试”而最终没有仓库测试，验证列不能用作者手工命令冒充自动覆盖。反过来，后续独立提交补上测试，应作为新事件连接。

第六列写书稿结论与等级。一条时间线可能支撑多个结论，逐条编号；每个结论列反例和适用范围。以后当前源码变化，只需定位受影响编号，而非全文搜索含糊关键词。账本成为书稿与上游证据之间的索引层。

## 用 RISC-V H 扩展练习“能力拆分”

研究硬件虚拟化时，“支持 H 扩展”太宽。先拆成规范状态建模、TCG 两阶段翻译、向客户机暴露 H、KVM capability、实际运行 L2、H/VS 状态迁移六个问题。每项有不同源码和上游系列，某一项合入不能把其余格子一起涂绿。

当前 TCG 源码能确认 `CPURISCVState` 中的 H/VS 字段、CSR 与两阶段转换，测试可以制造 guest-page fault；这支撑模拟语义。KVM 路径要查 Linux UAPI、one-reg、capability 和 QEMU get/put；邮件里出现 nested RFC，只说明有人提出方案。若 cover letter明确说该版不能运行 L2，这是一条限定版本的上游陈述，不能被“硬件有 H”覆盖。

历史搜索也按格子进行。`git log -S'hgatp'` 找架构状态引入，`-G'KVM_RISCV_ISA_EXT_H'` 找 capability，迁移从 `vmstate_hyper` 反向找 get/put。结果可能出现“有 VMState 字段、KVM 没有对应同步”的断点。此时结论是固定路径未闭环，既不说 TCG 不支持，也不说未来内核无法补足。

这种拆分会防止标题驱动研究。补丁 subject 里写 nested，读者容易想象完整 L2 与迁移；能力表迫使每个动词有测试。书中其他功能也可照做：AIA 拆模拟、split、内核加速和迁移，Rust 拆构建、QOM、设备、迁移，K230 拆 CPU、Machine、外设与启动。

## 研究结果怎样随新 tag 更新

新 tag 发布时，先保留旧账本，不在原记录上覆盖 hash。创建新锚点列，运行路径、祖先和邮件链接检查；对 `git diff old..new --` 的目标目录做语义筛选。没有变化的结论仍引用旧引入历史，同时增加“已在新 tag 复核”；发生变化的条目重新走完整链。

源码移动但行为不变时，更新当前路径，历史引入保持；接口语义变化时，增加新时间节点，检查旧实验是否仍有效；旧功能删除时，写清删除 commit 与替代。版本更新不是字符串替换，它是一轮证据迁移。

邮件中早于 tag 的 patch 若未合入，继续标 pending/superseded；tag 后的新系列放后续研究。不要因为新 tag 版本号更大，就把所有较早日期邮件当成已包含。祖先检查比日期可靠，维护分支可能晚合入，也可能永不合入。

实验重跑顺序按风险。先跑源码/构建和窄 qtest，再跑 functional、迁移与性能；结果变化时保存旧、新配置差异。若新默认改变而显式旧配置仍通过，结论应区分默认演进与实现回归。证据账本记录最后运行环境，避免“曾经通过”长期冒充当前事实。

更新书稿时保留历史措辞的版本主语。读者可能使用旧 QEMU，删除旧结论会丢掉解释；可以写“在 rc0 时……，从提交 X 起……”。这也是开源书相对一次性文档的优势，设计演进能被连续呈现，不必把过去重写成仿佛从未存在。

## 实验一：追踪一个 RISC-V 功能的历史

::: {.hands-on}
配套英文实验手册：[`trace-feature-history`](../experiments/part-05-engineering-and-evolution/chapter-22-git-and-mailing-list-evolution/trace-feature-history/README.md)。

从 `target/riscv/tcg/` 选择一个当前路径，先写问题，例如“为什么该 helper 属于 TCG”。在完整官方 GitLab clone 上运行 path log、`--follow`、符号 `-S` 和条件 `-G`，找到移动与更早引入。对每个候选提交保存 `--format=fuller`、stat、diff、父版本路径与 ancestor 检查。

随后用 Message-ID 连接对应 24-patch 系列，比较目标 patch 与最终提交，运行至少一个禁用 TCG 或 accelerator 相关构建验证。结果分四栏：固定源码事实、commit/邮件上游陈述、由构建和结构得到的作者推断、仍需 KVM/TCG 实验的开放问题。完整命令与结果写入实验 `results/history.md`。
:::

## 实验二：重建 K230 v1 到 v8 评审线程

::: {.hands-on}
配套英文实验手册：[`reconstruct-review-thread`](../experiments/part-05-engineering-and-evolution/chapter-22-git-and-mailing-list-evolution/reconstruct-review-thread/README.md)。

以 [K230 v8 系列](https://patchew.org/QEMU/cover.1781246408.git.chao.liu%40processmission.com/) 为入口，保存 v1 至 v8 cover letter、目标 patch 和相关回复的 Message-ID。按 CPU 扩展、PLIC/CLINT 地址、reset vector、未实现 UART、hart 数、direct boot、watchdog IRQ、Machine interface 八项建立时间线，逐项记录首次出现、评审理由、下一版 diff 与最终锚点位置。

再把最终 Machine/看门狗提交和 functional boot test 放进时间线，确认哪些是系列内收敛，哪些是合入后的补强。至少选择一项用当前 qtest 或 functional test 验证。若某次变化只有 changelog、未找到原 review，标为 patch 作者陈述；若当前源码与邮件不一致，以锚点事实为准并记录差异。
:::

## 证据边界与开放问题

本章能够确认的现状包括固定锚点、RISC-V TCG/KVM 目录、TCG-only 移动提交、K230 最终源码与测试。邮件和 Patchew 能确认具体系列版本与 changelog。由这些材料推导的模块化、状态所有权和评审收敛属于作者解释，不能替代上游原句。

开放问题总与版本绑定。未来 RISC-V gdbstub 是否按 accelerator 拆文件，K230 是否加入大核和更多设备，RISC-V `virt` 是否建立版本化 Machine，都需要新的合入提交与测试。主线上的 RFC 或 post-rc0 commit 可进入研究待办，不进入 `v11.1.0` 现状章节。

还有一类问题来自资料本身：某版邮件归档缺页、旧 patch 无法应用、硬件文档版本不可公开，或 commit message 没写设计理由。此时账本记录已经查过的范围和失败原因，避免下一位作者重复无效搜索。可以用当前源码、测试与公开规范形成强推断，但句子中保留来源缺口；若结论会影响兼容或安全建议，宁可暂停定论。

研究也应设置停止条件。当前调用链、引入/修复、最终邮件版本和行为实验已经闭合，继续翻无关提交只会增加噪声；尚缺的某封私有讨论又无法通过公开渠道取得，应转为开放问题。停止意味着把证据范围固定到可审计状态。以后出现新链接或新 tag，再从账本中的明确缺口继续。

对于引用频繁的核心结论，建议两人交叉复核。一人从源码向历史追，另一人从最终邮件向当前树验证，最后比较映射。两条路线得到相同 commit、符号和限制，能减少确认偏误；不一致时先保留分歧，不用行文技巧把它抹平。

书稿正式公开发布前再抽查一次原始上下文：链接打开的是目标版本，回复确实属于该 thread，最终 commit 是锚点祖先，实验命令没有借用本地未记录补丁。四项都满足，读者才能从散文回到原始证据；任何一项缺失，都应在正文降低结论强度。

::: {.source-path}
本章材料来自 QEMU 官方 [`MAINTAINERS`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/MAINTAINERS)、固定 tag 的 Git 历史、qemu-devel/lore、Patchew、Patchwork 与仓库测试。源码链接只指向官方 GitLab；证据记录位于 `book/research/`，关键邮件保留 Message-ID，体系结构研究限定 RISC-V/riscv64。
:::

## 小结

当前源码是研究起点，不是完整答案。路径和符号帮助找到提交，提交给出合入后的说明，邮件呈现方案怎样被质疑和修改，修复与测试揭示真正不变量。每一步固定版本、保留原始 ID，研究才能被另一位读者复做。

四级陈述法让叙述保持锋利，也保留诚实边界。源码事实可以直接核对，上游陈述有明确说话者，作者推断展示工程理解，开放问题告诉下一步去哪里找。RISC-V TCG 目录拆分和 K230 八版演进都说明，QEMU 的形状来自构建、真实软件、硬件规范、兼容与维护成本的持续拉扯；“为什么如此”只有放回这条时间线，才不会沦为对当前代码的事后想象。
