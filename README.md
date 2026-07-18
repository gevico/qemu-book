# 深入理解 QEMU 设计原理

本仓库是《深入理解 QEMU 设计原理》的开源主仓库，包含书稿 Markdown 源文件、配图、实验说明和可复现的 PDF 构建环境。

仓库已经形成六篇二十六章的首轮完整书稿，并建立实验目录、证据账本和 PDF 构建链路。内容门禁要求全书正文不少于 30 万汉字、每章不少于 3000 个汉字，并为每章提供至少两个可独立复现的实验；后续版本仍会随着 QEMU 上游演进持续校订。欢迎通过 Issue 讨论内容，通过 Pull Request 修正错误或贡献章节。

全书目标源码基线为 QEMU `v11.1.0`，源码引用以 [QEMU 官方 GitLab](https://gitlab.com/qemu-project/qemu) 为准。在上游正式 tag 发布前，预研使用 [`v11.1.0-rc0`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0?ref_type=tags)；正式版发布后统一冻结源码链接、实验命令和结果。

## 阅读与构建

正文位于 [`book/`](book/) 目录：

- `introduction.md`：前言、目标读者和阅读方法；
- `part1.md` ～ `part6.md`：六篇篇章页；
- `chapter1.md` ～ `chapter26.md`：全书各章；
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
BOOK_VERSION=v0.1.0 BOOK_DATE="2026-07-18" make pdf
```

## 全书结构

| 篇 | 章节 | 主线 |
| --- | --- | --- |
| 第一篇：QEMU 系统基础 | 1. 问题边界与 RISC-V 主线；2. 命令行到首条指令；3. 主循环与并发上下文；4. QOM；5. 地址空间；6. RISC-V CPU 与加速器抽象 | 建立配置、对象、线程、内存和 CPU 的共同坐标 |
| 第二篇：TCG 软件执行引擎 | 7. TB；8. RISC-V 译码；9. TCG IR 与后端；10. SoftMMU；11. 异常、中断与 MTTCG | 从 RISC-V 指令一路追到宿主代码、地址翻译和并发执行 |
| 第三篇：RISC-V 硬件虚拟化与 KVM | 12. H 扩展；13. Linux KVM；14. KVM 内存、I/O 与中断；15. 状态同步、迁移与嵌套边界 | 把 TCG 架构模型与硬件 H 扩展、Linux KVM 控制面平行比较 |
| 第四篇：Machine 与设备模型 | 16. `virt` Machine；17. 外设、时钟与 reset；18. PCIe 与 RISC-V IOMMU；19. virtio、vhost 与数据面 | 沿 RISC-V `virt` 观察平台、设备和 I/O 的状态所有权 |
| 第五篇：工程实践与代码演进 | 20. 调试与性能；21. 测试、迁移与兼容；22. Git 与邮件列表；23. Rust 设备建模 | 用可观测、可测试、可追溯的方法解释当前设计 |
| 第六篇：异构计算与综合项目 | 24. RISC-V GPGPU；25. K230 与 G233；26. AI 加速器与 Agent 辅助建模 | 将前述边界用于树外模型，并清楚区分上游事实与本书实验 |

TCG 与 KVM 是两条并行的执行路径。TCG 在 QEMU 内显式实现 RISC-V 架构语义，KVM 则由 Linux KVM 和宿主硬件执行客户机指令；它们共享 CPU 公共状态、Machine 与设备模型，但不能把实现位置和能力边界混为一谈。

## 写作约定

章节标题和思考题都不手工编号，由构建链路统一生成。思考题穿插在相关知识点之后，其答案自动汇总到附录并建立双向链接。图片、代码、表格、公式和提示框的具体写法见 [`CONTRIBUTING.md`](CONTRIBUTING.md)。提交前先运行 `make check-content` 与 `make check-experiments`，再运行一次 `make pdf`，确保内容、实验目录、链接、中文字体和分页均正常。

本仓库的书稿组织方式参考了 [bojieli/ai-agent-book](https://github.com/bojieli/ai-agent-book)：正文按章节拆分，用 Pandoc 汇总 Markdown，再由 XeLaTeX 生成整本 PDF。本项目在此基础上增加了固定容器环境和自动化 PDF 构建。

## 许可协议

本项目使用 [Apache License 2.0](LICENSE)。除非另有说明，提交到本仓库的内容均按该协议授权。
