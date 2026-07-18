# 深入理解 QEMU 设计原理

本仓库是《深入理解 QEMU 设计原理》的开源主仓库，包含书稿 Markdown 源文件、配图、实验说明和可复现的 PDF 构建环境。

目前仓库处于“框架搭建”阶段：章节边界、写作约定和构建链路已经建立，正文将持续补充。欢迎通过 Issue 讨论内容，通过 Pull Request 修正错误或贡献章节。

## 阅读与构建

正文位于 [`book/`](book/) 目录：

- `introduction.md`：前言、目标读者和阅读方法；
- `chapter1.md` ～ `chapter13.md`：全书各章；
- `appendix-a.md`：源码阅读和实验环境速查；
- `afterword.md`：后记；
- `metadata.yaml`、`preamble.tex`、`filters/`：Pandoc 与 XeLaTeX 排版配置；
- `images/`：全书图片，按章节命名。

推荐使用 Docker 构建，宿主机只需要 GNU Make 与 Docker：

```bash
make pdf
```

输出文件为 `output/pdf/深入理解-QEMU-设计原理.pdf`。

如果本机已经安装 Pandoc、XeLaTeX、中文 TeX 宏包和 Noto CJK 字体，也可以直接运行：

```bash
make pdf-native
```

每次向 `main` 推送或提交 Pull Request 时，GitHub Actions 都会编译 PDF，并将结果保存为 workflow artifact。

## 版本发布

版本由 Git Tag 决定。推送一个以 `v` 开头的 Tag 后，GitHub Actions 会把 Tag 写入 PDF 的版本页，创建同名 GitHub Release，并上传带版本号的 PDF：

```bash
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
```

Release 中的文件名为 `深入理解-QEMU-设计原理-v0.1.0.pdf`。如果重跑同一 Tag 的 workflow，已有 Release asset 会被新构建结果替换。

## 全书结构

| 章 | 主题 | 主线 |
| --- | --- | --- |
| 1 | QEMU 全景与源码地图 | 从一条命令建立进程、线程、对象和数据流的整体视图 |
| 2 | QOM 对象模型 | 类型注册、继承、属性、组合树与生命周期 |
| 3 | Machine 与 qdev | 命令行如何变成机器、总线和设备拓扑 |
| 4 | 内存子系统 | `MemoryRegion`、`AddressSpace`、`FlatView` 与地址转换 |
| 5 | TCG 前端 | 指令译码、TCG IR、helper 与架构语义 |
| 6 | TCG 后端与 TB | 优化、寄存器分配、主机代码生成、链接和失效 |
| 7 | 加速器抽象与 KVM | TCG/KVM 共用边界、vCPU 运行与退出处理 |
| 8 | CPU 执行、异常与中断 | 执行循环、状态同步、异常、中断和调试 |
| 9 | 事件循环与并发模型 | AioContext、BQL、iothread、协程、定时器与 RCU |
| 10 | 设备模型与 virtio | qdev、总线、IRQ、DMA、virtqueue 与 vhost |
| 11 | 块设备与网络 I/O | Block graph、请求路径、异步 I/O 与网络后端 |
| 12 | 迁移与状态一致性 | VMState、脏页、兼容性、停机窗口与恢复 |
| 13 | 调试、测试与扩展 QEMU | trace、QMP、gdb、qtest 和新增设备的工程方法 |

## 写作约定

章节标题不手工编号，由文档类统一生成。图片、代码、表格、公式和专题提示框的具体写法见 [`CONTRIBUTING.md`](CONTRIBUTING.md)。提交前至少运行一次 `make pdf`，确保链接、中文字体和分页均正常。

本仓库的书稿组织方式参考了 [bojieli/ai-agent-book](https://github.com/bojieli/ai-agent-book)：正文按章节拆分，用 Pandoc 汇总 Markdown，再由 XeLaTeX 生成整本 PDF。本项目在此基础上增加了固定容器环境和自动化 PDF 构建。

## 许可协议

本项目使用 [Apache License 2.0](LICENSE)。除非另有说明，提交到本仓库的内容均按该协议授权。
