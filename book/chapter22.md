# 复杂开源工程如何形成共识

给 QEMU 增加一块 RISC-V 板卡，第一版能编译、能启动厂商固件，看起来已经完成了大半。K230 系列却走到 v8：地址需要对照数据手册，reset vector 在一条启动路径里跳错，访问未实现 UART 会让 Linux Oops，支持的 hart 数要与当前模型范围一致，direct boot、DTB 来源和 Machine interface 也要逐项说明。

八个版本并不代表前七次都毫无价值。每一版都把一组含糊假设变成了公开约束：硬件资料说什么，客户机实际依赖什么，QEMU 框架要求什么，哪些范围暂时不做。复杂开源工程的共识就形成在这些可审查的变化里。本章借 K230 的真实系列观察 Contributor、Reviewer 和 Maintainer 怎样协作，同时给出一套可迁移到其他项目的研究方法。

## 代码目录背后有一张责任图

[`MAINTAINERS`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/MAINTAINERS) 把文件模式、邮件列表、维护状态和角色连接起来。固定锚点中，“K230 Machines”由 Chao Liu 维护；“RISC-V TCG CPUs”由 Palmer Dabbelt、Alistair Francis 维护，Chao Liu 等人担任 reviewer；相关讨论进入 `qemu-riscv@nongnu.org`。这张表告诉贡献者补丁应该到哪里、谁长期承担后续维护，却不能代替某次 review 的具体意见。

角色表达责任边界，不构成荣誉等级。Contributor 提出可运行、可解释、可测试的变化，并在新版本中回应问题；Reviewer 检查自己熟悉的接口，明确给出意见或 tag；Maintainer 还要判断范围、依赖、回归风险和进入维护分支的时机。一个人可以在不同子系统承担不同角色。K230 作者后来成为该 Machine 的 maintainer，意味着合入之后仍要接手 bug、测试、文档和后续贡献。

trailer 有精确语义。`Reviewed-by` 表示审阅过对应版本，`Acked-by` 常用于子系统认可并允许另一位维护者排队，`Tested-by` 记录特定环境的功能测试，`Signed-off-by` 承担 DCO 来源认证。不能从 `Reviewed-by` 推导 reviewer 赞成书中所有解释，也不能从收件人列表推导某人参与了设计。

:::: {.quick-quiz}
为什么当前 `MAINTAINERS` 不能直接解释几年前某项设计由谁决定？

::: {.quick-answer}
它描述当前责任边界，角色和文件归属会随时间变化。研究旧补丁还要查看当时的收件人、邮件回复、trailer 和 MAINTAINERS 历史；当前名字只能帮助找到入口。
:::
::::

## 补丁拆分就是第一份设计说明

K230 v8 由五个 patch 组成：C908 CPU 支持、板卡、watchdog、qtest、文档。这个顺序把不同问题拆开了。CPU reviewer 可以先检查扩展集合，Machine reviewer 检查地址图与启动，设备 reviewer 检查寄存器和 timer，测试与文档又分别回答回归和用户接口。若 1800 多行压成一个 patch，任何一处改动都会迫使所有人重新阅读整块 diff。

拆分还表达依赖。板卡先需要 CPU 类型，qtest 需要 watchdog 已存在，文档描述最终用户接口。公共 API 若要修改，通常先单独合入基础设施，再让设备使用；迁移能力也可以在设备基本行为之后独立审查。每个 commit 都应在它声明的范围内构建、测试，并给下一步留下稳定前提。

一组可评审补丁通常包含三类信息：为什么出现这个工程需求，客户机或框架能够观察到什么，作者怎样验证。代码只展示“做了什么”，cover letter 负责系列边界，单个 commit message 负责长期理由，测试把一部分理由变成可执行断言。三者不一致时，review 应先要求收敛陈述。

## K230 v1 到 v8 收敛了哪些约束

K230 [v8 cover letter](https://patchew.org/QEMU/cover.1781246408.git.chao.liu%40processmission.com/) 保存了逐版 changelog。时间跨度可以压成一行：v1 2025-11-30，v2 12-04，v3 12-15，v4 2026-01-20，v5 01-30，v6 04-17，v7 05-11，v8 06-12，最终于 2026-06-16 合入。日期只标出协作节奏；真正需要解释的仍是下面四条工程主线：

| 约束来源 | 版本中的处理 | 它阻止了什么误解 |
|---|---|---|
| RISC-V/SoC 资料 | v2 增加 Svpbmt；v3 对齐 C908 扩展并调整 PLIC/CLINT 地址；v7 修正 WDT IRQ | “CPU 名称和大致地址相近就足够” |
| 启动与运行反馈 | v5 修复 reset vector ROM 跳转；v7 处理未实现 UART 引发的 Oops | “一条固件启动成功即可代表整机路径正确” |
| 当前支持范围 | v7 将 hart 数调整为一，并增加 direct Linux boot | “芯片拥有的全部能力都已进入初始模型” |
| QEMU 框架与用户契约 | v2 修文档构建；v8 注册 riscv64 Machine interface，补清 DTB/启动说明 | “模型内部能创建就等于用户能稳定使用” |

这里的历史服务于当前设计。固定锚点里的 [`hw/riscv/k230.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/k230.c) 先支持 C908 小核；QEMU 不生成 K230 DTB，direct boot 由用户传入；未实现区域会以占位模型承接访问。读者从这些决定可以反推板卡模型的边界：地址、hart、reset 和设备树都属于客户机可见平台契约，不能藏在“以后再完善”里。

v8 邮件还保留了一个容易被忽略的事实：系列在 Patchew 当前 master 上显示 apply failure，Alistair Francis 的回复却明确说已应用到 `riscv-to-apply.next`。补丁针对的维护分支、集成时间和归档检查时间不同，自动状态可以同时出现。最终现状要回到合入 commit 与固定 tag，不能只看网页上的一个彩色标签。

## 人的判断如何进入最终提交

最终板卡提交 [`6cf0d08c`](https://gitlab.com/qemu-project/qemu/-/commit/6cf0d08c3953ee447cb215edc3a384834cbe48db) 由 Chao Liu authored，Alistair Francis committed；trailer 保留 Peng Jiang 的 `Tested-by`、Alistair 的 `Acked-by`、Nutty Liu 的 `Reviewed-by`，以及双方的 sign-off。v8 线程中，Alistair 回复“Applied to riscv-to-apply.next”。这些记录足以确认谁提交、谁测试、谁审阅、谁完成集成。

更细的动机必须逐封回到邮件。cover letter 写“v7 修复未实现 UART 导致的 Oops”，可以转述问题和变化；它没有标明每一项由哪位 reviewer 首次提出，就不能给某个人编造意见。找到相应回复后，才能记录“reviewer 指出什么、作者怎样回应、下一版改了哪里”。没有公开证据时，写“作者根据 changelog 作此归纳”比补齐一段戏剧化对话更可靠。

Maintainer 的工作还包含范围控制。初始提交明确使用 “preliminarily supports”，先让 C908 小核运行 SDK U-Boot 与 Linux；后续功能可以继续提交。接受一个清楚受限、带维护人的模型，常比等待所有外设一次完成更容易演进。限制必须写进文档和测试，避免用户把“初始支持”理解为完整 SoC。

Reviewer 的价值也会在代码之外留下痕迹。v2 采用 Daniel 的文档构建修正，v6 拾取 Fabiano 对测试 patch 的 ack；v3、v5、v7、v8 的 changelog 则显示规格、启动、接口和测试问题逐步被处理。review 让假设变成可见 diff，最终共识落在合入版本、测试和用户文档上。

这套协作也塑造参与者的工程能力。作者需要把“我的环境能跑”拆成他人能够重复的命令、资料和边界；reviewer 要把直觉改写成能落到代码或测试的技术问题；maintainer 则要在局部正确与长期维护之间作选择。一次 patch revision 训练的不只是 Git 操作，还包括如何承认证据不足、如何缩小承诺、如何让不同背景的人在同一份 diff 上沟通。

成为 reviewer 或 maintainer 也不意味着停止被 review。K230 作者在 RISC-V 子系统承担 reviewer/maintainer 责任，自己的系列仍然经过其他 reviewer 和维护者检查。开源协作中，可信度来自持续接受公开验证，并在合入后回应问题；头衔只帮助社区知道谁会接住下一封邮件。

角色交接同样需要留下工程入口。新 maintainer 若只能依赖前任记忆，板卡的固件来源、已知缺口和测试环境很快会失传；文档、测试、邮件归档和清晰的 commit 边界，能让后来者重建当时的判断。Contributor 也可以从小范围修复开始，沿失败测试找到所有者，再通过 review 学会子系统约定。贡献的长期收获因而不只是一行署名，还包括提出可证伪问题、接受异议、维护承诺和帮助下一位贡献者接续工作的能力。

这些能力离开 QEMU 仍然有效：面对任何大型工程，都能先辨认责任边界，再用公开证据推动局部改进。

:::: {.quick-quiz}
为什么不能把 cover letter 的逐版 changelog 直接写成某位 reviewer 的思考？

::: {.quick-answer}
changelog 通常由作者概括变化，未必标出意见来源。只有对应邮件回复能证明谁提出了哪项约束；否则可以描述版本变化和作者陈述，人物动机应保持未确认。
:::
::::

## 共识是一条可重放的证据链

研究一个当前设计，第一步从锚点源码提出小问题，例如“为什么 K230 只有一个 hart”“为什么 direct boot 要传 DTB”。第二步用 path history、符号和 commit 找到引入或最后一次语义变化。第三步从 commit 的 Message-ID 回到系列，比较各版 cover、目标 patch 和相关回复。第四步检查后续 fix、qtest、functional test 与文档。第五步才把材料写成设计解释。

每条结论最好同时标四个层次：固定 tag 可直接确认的源码事实；commit、cover 或 review 明说的上游陈述；由多条材料连接得到的作者推断；仍缺邮件或实验的开放问题。例如，“v7 将 hart 数改为一”是上游陈述，“当前 `k230.c` 只创建一颗 C908”是源码事实，“这是为了让模型发布的能力与已验证范围一致”若无直接回复，只能保留为有依据的推断。

最终 Git hash、邮件 Message-ID 和 patch 版本承担不同身份。邮件 patch 被维护者应用、补 trailer 或 rebase 后，hash 可能改变；Message-ID 仍连接评审对象，最终 hash 锚定合入代码。`range-diff` 可以发现 v7 到 v8 的变化，匹配结果仍需人工阅读。blame 适合找入口，一次机械移动的作者并不会因此成为原算法设计者。

## 负面证据需要限定搜索范围

“没有找到”常被写得过于肯定。固定 tag 中没有 `rust/hw/riscv`，只能说明该锚点没有显式的上游 RISC-V Rust 设备；不能推出社区从未讨论。某封邮件没有回复，也不能说明所有人默认同意。某个测试文件存在，还要看 assertion 是否真正触发目标路径。

可审查的负面结论要带命令和范围：查了哪个 tag、哪些目录、哪些同义符号、生成代码与条件编译是否包含。找不到测试时写“未找到直接覆盖”，再用故障注入检查更高层测试是否间接失败。找不到公开决定时，可以保留源码与实验推断，读者仍能继续调查。

冲突材料也不要急着抹平。邮件 v3 说接口会保留，最终 diff 删除了它，现状由固定源码回答，v3 只说明曾经的方案；文档与测试不一致，先运行锚点测试并查后续修复。把冲突记进证据台账，往往比挑一条顺眼的叙述更接近工程现实。

## Agent 可以扩大检索，人仍要承担来源责任

Agent 很适合处理机械工作：枚举路径、从书稿提取 commit URL、验证 hash 是否为锚点祖先、收集 Message-ID、比较 patch 文件集合、找出缺失测试和互相冲突的陈述。它也能在海量邮件里给出候选线程。候选不是结论，作者仍需打开原文、核对上下文、确认角色与版本，并亲自判断推断边界。

QEMU 当前 [`code-provenance.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/devel/code-provenance.rst) 对上游贡献给出明确规则：项目会拒绝被认为包含或派生自 AI 生成内容的贡献。政策允许用 AI 研究 API/算法、做静态分析或调试，前提是其输出不进入贡献。因而 Agent 可以帮助定位证据和验证实验，不能把生成的代码、commit message 或文档直接当作上游 patch；贡献者必须能够按 DCO 对每一行来源和权利负责。

这条边界也改善研究质量。让工具保留命令、链接、hash 与失败记录，让人负责技术判断和最终表达。Agent 给出的角色归因若无法回到邮件，就降为待查；生成的代码建议可作为调试线索，真正提交的实现应由贡献者基于规范与源码重新完成、测试和审阅。

:::: {.quick-quiz}
Agent 找到一封看似相关的 qemu-devel 邮件后，作者还要核对什么？

::: {.quick-answer}
至少核对 Message-ID、patch 版本、上下文、提出者的原始语气、下一版变化和最终合入代码。搜索摘要可能截断条件，也可能命中已被替代的 v1；只有连回锚点，材料才支持当前设计结论。
:::
::::

## 两个实验练习重建共识

### 实验一：从当前路径追到设计变化

::: {.hands-on}
配套英文实验手册：[`trace-feature-history`](../experiments/part-05-engineering-and-evolution/chapter-22-git-and-mailing-list-evolution/trace-feature-history/README.md)。

选择 `hw/riscv/k230.c` 或 `target/riscv/kvm/kvm-cpu.c`，先写一个当前问题，再生成完整 path history。对候选提交阅读正文、diff、测试和 trailer；把源码事实、上游理由和作者推断分栏。若路径经历 rename，回到父提交的旧路径继续追，避免把移动者写成设计者。
:::

### 实验二：重建 K230 v1 到 v8

::: {.hands-on}
配套英文实验手册：[`reconstruct-review-thread`](../experiments/part-05-engineering-and-evolution/chapter-22-git-and-mailing-list-evolution/reconstruct-review-thread/README.md)。

以 `6cf0d08c` 的 Message-ID 和 v8 cover 为入口，记录每版的范围、review 问题、下一版变化和最终位置。重点复查 CPU 扩展、PLIC/CLINT、reset vector、UART、hart、direct boot、WDT IRQ 与 Machine interface。找不到原回复的条目只记 changelog，不补人物动机；最后验证 commit 是 rc0 祖先，并检查 qtest、functional test 和文档是否已经进入锚点。
:::

## 小结

复杂开源工程通过可审查的小步变化形成共识。Contributor 把需求、实现和验证公开出来，Reviewer 把规格、框架、兼容与维护问题压成具体意见，Maintainer 决定范围和集成时机，并继续承担发布后的责任。最终证据留在 commit、邮件、测试、文档和 MAINTAINERS 中，人物故事不能脱离这些记录。

K230 v1 到 v8 的价值也在这里。它让一块新板卡从“能够启动某份软件”走向明确的地址、reset、hart、DTB、测试和支持范围。Agent 能让这条链更快被找到；作者对来源、推断和贡献内容的责任仍然无法外包。
