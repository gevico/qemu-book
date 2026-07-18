# 调试、测试与扩展 QEMU

最后一章把前面的模型转化为工程方法：如何观察运行时状态、缩小问题范围、建立最小复现，以及如何安全地增加一种设备或修改核心路径。

## 本章目标

- 组合使用日志、trace、QMP、gdb 和系统级观测工具；
- 理解 qtest、functional test、unit test 和 avocado 历史测试的适用范围；
- 为新增设备或核心改动设计可验证的最小补丁序列。

## 建立可重复环境

固定 QEMU commit、configure 参数、编译器、machine type、CPU model、accelerator、固件、镜像和命令行。解释为何“同一台 guest”不足以复现实验。

## 观察而不是猜测

按问题类型选择 `-d` 日志、trace-events、QMP query、HMP info、gdb、perf、strace 和 eBPF。强调时间线、线程和状态转换的关联。

## 测试层次

使用 unit test 验证纯逻辑，用 qtest 驱动设备寄存器和时钟，用 functional test 启动真实 guest，用 migration test 验证兼容性。

## 新增设备的最小路径

从 QOM 类型、状态结构、properties、realize/reset、MemoryRegion、IRQ、迁移状态到 qtest。把数据面优化放在语义正确之后。

::: {.hands-on}
实现一个只含两个寄存器和一根 IRQ 的教学设备：写入一个寄存器触发定时器，定时器到期更新状态并抬高中断。为寄存器访问、reset、迁移和非法访问分别添加测试。
:::

## 上游协作

介绍阅读 MAINTAINERS、拆分补丁、运行 checkpatch 与相关测试、撰写 commit message 和回复 review 的基本原则。具体流程以 QEMU 当前官方贡献文档为准。

## 小结

理解设计的最终检验，是能否用可观测证据解释行为，并用小而完整的改动扩展系统而不破坏既有状态机。

## 思考题

1. 某个设备偶发丢中断时，最小观测集合是什么？
2. 哪些设备行为可以不启动 guest 就用 qtest 覆盖？
3. 为什么迁移字段应和设备功能改动一起评审？
