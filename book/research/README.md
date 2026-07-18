# 章节研究记录

这里保存写作阶段的证据账本，不直接参与 PDF 构建。正文中的设计结论必须能够回到下面几类材料：

1. QEMU `v11.1.0` 的当前源码；正式 tag 发布前使用 `v11.1.0-rc0` 预研；
2. QEMU 官方 GitLab 中引入、重构或修复该设计的 commit；
3. qemu-devel 上对应 patch series 的 cover letter、review 和版本迭代；
4. RISC-V ISA、特权架构、H 扩展、AIA、IOMMU 或 Linux KVM UAPI 等规范；
5. 可以复现当前行为的构建、测试、trace 或性能数据。

源码链接只使用 <https://gitlab.com/qemu-project/qemu>。邮件链接优先使用可长期访问的 qemu-devel 公共归档，并记录 Message-ID。GitHub `qemu/qemu` 是镜像，不作为书稿证据入口。

## 记录格式

每条设计结论至少记录以下字段：

- `claim`：正文准备表达的结论；
- `current_source`：当前实现的文件、函数和固定版本链接；
- `history`：关键 commit 或 commit range；
- `review`：邮件线程、patch 版本和 reviewer 提出的约束；
- `reasoning`：哪些是上游明确说明，哪些是作者根据代码和历史做出的推断；
- `experiment`：验证结论的最小命令和预期现象。

研究材料不按数量进入正文。一节通常只保留一条能够解释当前设计的演进主线，其余内容留在账本中。

## 已建立的专题账本

- [`evidence-ledger.md`](evidence-ledger.md)：二十六章的研究入口与完成状态；
- [`riscv-tcg-evidence.md`](riscv-tcg-evidence.md)：RISC-V CPU、TCG、SoftMMU、异常中断与 MTTCG；
- [`riscv-h-kvm-evidence.md`](riscv-h-kvm-evidence.md)：H 扩展、Linux KVM、AIA、状态同步、迁移与 nested 边界。
- [`riscv-machine-device-evidence.md`](riscv-machine-device-evidence.md)：RISC-V `virt`、AIA、IOMMU、virtio、K230 与 G233 证据边界。
- [`engineering-evidence.md`](engineering-evidence.md)：调试、测试、迁移、Git/mail 研究方法与 Rust 渐进接入。
