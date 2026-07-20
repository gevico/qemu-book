# 深入理解 QEMU 设计原理

本仓库是《深入理解 QEMU 设计原理》的开源主仓库，包含书稿 Markdown 源文件、配图、实验说明和可复现的 PDF 构建环境。

仓库包含五篇二十三章的书稿、实验目录、证据账本和 PDF 构建链路。全书从问题与历史现场出发，沿补丁、邮件审查、会议材料和当前源码追踪设计如何形成；内容检查关注章节是否具备足够展开、结构是否过度碎片化，以及是否给出可复核的实验或源码验证入口。后续版本仍会随着 QEMU 上游演进持续校订。欢迎通过 Issue 讨论内容，通过 Pull Request 修正错误或贡献章节。

全书面向 QEMU `v11.1.0` 发布线，源码引用以 [QEMU 官方 GitLab](https://gitlab.com/qemu-project/qemu) 为准。截至 2026 年 7 月 19 日，上游最新节点为 [`v11.1.0-rc0`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0?ref_type=tags)，本轮书稿的现状结论、源码链接和依赖源码版本的实验设计冻结在该节点。这个“源码审查基线”不表示所有 live、KVM 或双主机实验都已经运行；正式版发布后仍需重新执行证据与实验门禁，不能预先把 RC 结果写成正式版事实。

## 阅读与构建

正文位于 [`book/`](book/) 目录：

- `introduction.md`：前言、目标读者和阅读方法；
- `part1.md` ～ `part5.md`：五篇篇章页；
- `chapter1.md` ～ `chapter23.md`：全书各章；
- `quiz-answers.md`：构建时自动汇总各章思考题答案；
- `appendix-a.md`：源码阅读和实验环境速查；
- `references.md`：规范、源码、邮件与排版参考；
- `afterword.md`：后记；
- `metadata.yaml`、`preamble.tex`、`filters/`：Pandoc 与 XeLaTeX 排版配置；
- `images/`：全书图片，按章节命名；
- `research/`：源码、Git 提交和 qemu-devel 审查的证据账本。

实验代码与英文手册位于 [`experiments/`](experiments/)；目录按 `part-XX/chapter-YY/project-name` 组织。书中用中文说明实验要解决的问题和观察方法，仓库中的项目手册则用英文写明环境、步骤、预期结果、清理和故障排查。每个项目保持独立，避免读者必须先运行整本书的所有实验。

推荐使用 Docker 构建，宿主机只需要 GNU Make 与 Docker：

```bash
make pdf
```

默认输出文件为 `output/pdf/深入理解-QEMU-设计原理-持续更新.pdf`。设置
`BOOK_VERSION=v0.2.0` 后，文件名会变为
`output/pdf/深入理解-QEMU-设计原理-v0.2.0.pdf`。

如果本机已经安装 Pandoc、XeLaTeX、中文 TeX 宏包和 Noto CJK 字体，也可以直接运行：

```bash
make pdf-native
```

每次向 `main` 推送或提交 Pull Request 时，GitHub Actions 都会编译 PDF，并将结果保存为 workflow artifact。

## 版本发布

版本由 Git Tag 决定。推送一个以 `v` 开头的 Tag 后，GitHub Actions 会把 Tag 和本次构建时间写入 PDF 封面，创建同名 GitHub Release，并上传带版本号的 PDF：

```bash
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
```

Release 中的文件名为 `深入理解-QEMU-设计原理-v0.1.0.pdf`。如果重跑同一 Tag 的 workflow，已有 Release asset 会被新构建结果替换。

本地构建默认使用“持续更新”作为版本，并读取构建环境的系统时间。需要可复现的封面信息时，可以显式指定：

```bash
BOOK_VERSION=v0.1.0 BOOK_DATE="2026-07-19" make pdf
```

## 全书结构

| 篇 | 章节 | 主线 |
| --- | --- | --- |
| 第一篇：QEMU 从哪里来 | 1. 跨架构运行既有程序；2. 从进程走向完整机器；3. 机器契约；4. QOM 与生命周期；5. 地址空间；6. Accelerator 与状态所有权 | 从 2003 年的具体问题追到今天的系统边界，并比较 TCG、KVM 和其余 Accelerator |
| 第二篇：TCG 与可维护的动态翻译 | 7. dyngen；8. TCG 转折；9. 强类型 IR；10. 收敛的优化；11. TB、SoftMMU 与 MTTCG | 解释 QEMU 为什么把代码生成能力收回到自身架构中 |
| 第三篇：QEMU 与 KVM | 12. 硬件虚拟化机会；13. `/dev/kvm`；14. exit 与 I/O；15. 状态和迁移 | 追踪内核、硬件与用户态机器模型如何形成分层栈 |
| 第四篇：为什么要模拟这么多硬件 | 16. 模型分类与平台契约；17. RISC-V 外设建模；18. RISC-V 板卡建模；19. IOMMU、virtio、vhost 与 VFIO | 从可运行的 RISC-V 代码掌握设备和 board 开发 |
| 第五篇：百万行代码如何继续演进 | 20. monitor、log、trace 与 gdb 调试；21. 测试、迁移、版本和安全；22. 邮件评审与维护；23. Rust | 覆盖内核、裸机、RTOS、一般 guest 调试与长期维护 |

TCG 与 KVM 是两条并行的执行路径。TCG 在 QEMU 内显式实现客户机架构语义，KVM 则由 Linux KVM 和宿主硬件执行客户机指令；它们共享 CPU 公共状态、Machine 与设备模型，又各自承担不同的可移植性、性能和状态同步成本。

## 写作约定

章节标题和思考题都不手工编号，由构建链路统一生成。思考题穿插在相关知识点之后，其答案自动汇总到附录并建立双向链接。图片、代码、表格、公式和提示框的具体写法见 [`CONTRIBUTING.md`](CONTRIBUTING.md)。提交前先运行 `make check-content` 与 `make check-experiments`，再运行一次 `make pdf`，确保内容、实验目录、链接、中文字体和分页均正常。

本仓库的书稿组织方式参考了 [bojieli/ai-agent-book](https://github.com/bojieli/ai-agent-book)：正文按章节拆分，用 Pandoc 汇总 Markdown，再由 XeLaTeX 生成整本 PDF。本项目在此基础上增加了固定容器环境和自动化 PDF 构建。

## 许可协议

本项目使用 [Apache License 2.0](LICENSE)。除非另有说明，提交到本仓库的内容均按该协议授权。
