# 研究与证据账本

这里保存写作过程中的取证记录，不直接参与 PDF 构建。正文负责讲清一条设计因果，账本负责保留来源、分歧、版本和仍未解决的问题。资料数量不构成质量指标；一条邮件如果没有改变方案、暴露约束或解释当前边界，就不进入正文。

## 研究基线

- 目标发布线：QEMU `v11.1.0`；截至 2026-07-19 的源码审查基线：`v11.1.0-rc0`；
- 当前源码锚点：`v11.1.0-rc0`，commit `eca2c16212ef9dcb0871de39bb9d1c2efebe76be`；
- 当前实现主线：RISC-V 64 位，优先使用 `target/riscv/`、`hw/riscv/`、`accel/`、`tcg/` 中与 RISC-V 路径直接相关的代码；
- 历史材料：允许引用早期 x86、Arm 或其他 target，但只用于解释 QEMU、TCG、KVM 或某项通用抽象的诞生；
- 上游位置：QEMU 官方 GitLab、qemu-devel/qemu-riscv/linux-kernel 公开归档、规范维护组织和 KVM Forum 官方材料。

描述当前实现时，链接固定 tag 或完整 commit。描述仍在开发的内容时，记录核验日期，避免把 master 上的阶段性状态写成发布承诺。

## 一条主张怎样记录

每个能够影响正文结论的主张使用下面的字段。专题账本可以采用表格或分节形式，但不能省略事实与综合判断的边界。

| 字段 | 内容 |
| --- | --- |
| `id` | 稳定标识，例如 `TCG-IR-003` |
| `question` | 这条材料准备回答什么问题 |
| `claim` | 正文可以表达的最窄结论 |
| `kind` | `current-source`、`upstream-statement`、`experiment`、`synthesis` 或 `open` |
| `current_source` | RISC-V 当前源码文件、符号、固定版本链接 |
| `history` | 引入、重构或删除该设计的完整 commit |
| `review` | cover letter、Message-ID、patch 版本及改变方案的回复 |
| `people` | 事件发生时的 Author、Contributor、Reviewer、Maintainer；依据邮件、trailer 和当时 `MAINTAINERS` 判断 |
| `alternatives` | 被讨论、推迟或否决的方案，以及提出反例的人 |
| `decision_and_cost` | 最终选择解决了什么，同时增加了什么维护、兼容、性能或安全成本 |
| `verification` | 最小源码检查、命令、测试或 trace，以及预期现象 |
| `confidence` | `verified`、`inference`、`open`；附最后核验日期 |

提交的 Author、Committer 和 subsystem Maintainer 可能是不同的人。`Reviewed-by` 表示接受该补丁的技术审查，`Acked-by` 只覆盖参与者负责的范围，maintainer 入队时的 `Signed-off-by` 还承担来源校验。账本按当时角色记录，不能用今天的头衔覆盖过去。

## 史料进入正文的门槛

一个历史现场至少满足以下两项，才会写进章节：

1. 原作者或 reviewer 清楚描述了待解决的问题；
2. 某个反例让补丁发生可定位的变化；
3. 候选方案之间存在可解释的取舍；
4. 最终决定仍能解释 RISC-V 当前实现、兼容属性或维护边界。

版本日志、全部 review 回复和旁支方案留在账本。正文通常只保留一个转折现场和一条回到当前源码的路径。

## RISC-V 取材规则

全书的代码片段、调用链、实验命令和设备示例统一以 RISC-V target 为参考。通用框架可以讲 `MachineState`、QOM、MemoryRegion、TCG 或 KVM，但落地时应选择 `hw/riscv/virt.c`、`target/riscv/tcg/`、`target/riscv/kvm/` 等路径。真实板案例也优先选择已进入 QEMU 上游、具有公开 review 的 RISC-V machine。

早期 QEMU 和 KVM 发生在 x86 背景中，TCG 迁移也经历过 Arm、SPARC、SH4 等 target。它们承担历史证据，不扩展成并行的源码教学主线。

## Agent 的使用边界

Agent 可以帮助定位符号、验证 commit 祖先关系、搜索 Message-ID、比较 patch 版本、检查失效链接和生成待核验问题。模型摘要不能单独成为来源。写进正文前，研究者必须打开原始材料，并确认它实际支持的结论范围。

QEMU 当前拒绝包含或源自生成式 AI 内容的上游贡献；API/算法研究、静态分析和调试不在这一禁令内，前提是生成内容不进入提交。账本中的 Agent 工作流用于研究和教学，不授权读者把生成补丁投递到 QEMU。真实贡献必须遵守当时的项目政策、DCO 和邮件审查流程。

## 验证顺序

1. 在固定版本确认当前符号和行为；
2. 用 `git log -S`、`git log -G`、`git blame` 或路径历史定位变化；
3. 从 commit 的 Message-ID、主题和日期还原邮件线程；
4. 比较真正改变方案的 patch 版本与 review；
5. 核对历史 `MAINTAINERS` 和 commit trailer 中的角色；
6. 运行最小实验，或明确记录硬件、内核、固件缺失导致的 skip；
7. 将结论标成已验证、综合判断或开放问题。

## 专题账本

- [`evidence-ledger.md`](evidence-ledger.md)：五篇二十三章的状态与主要问题；
- [`qemu-origin-evidence.md`](qemu-origin-evidence.md)：QEMU 起源以及系统边界怎样扩大；
- [`qemu-tcg-history.md`](qemu-tcg-history.md)：dyngen、TCG、IR 和轻量优化；
- [`qemu-kvm-history.md`](qemu-kvm-history.md)：KVM 分层、exit、状态与迁移；
- [`riscv-tcg-evidence.md`](riscv-tcg-evidence.md)：RISC-V TCG 当前实现；
- [`riscv-h-kvm-evidence.md`](riscv-h-kvm-evidence.md)：RISC-V H 与 KVM 当前实现；
- [`qemu-riscv-modeling-evidence.md`](qemu-riscv-modeling-evidence.md)：第 17–19 章采用的设备、板卡和 I/O 主张边界；
- [`riscv-machine-device-evidence.md`](riscv-machine-device-evidence.md)：RISC-V machine、IOMMU 与 K230 的补充提交索引；
- [`qemu-engineering-evidence.md`](qemu-engineering-evidence.md)：第 20–23 章采用的调试、测试、协作与 Rust 主张边界；
- [`engineering-evidence.md`](engineering-evidence.md)：测试框架、迁移和 Rust 引入提交的补充索引。
