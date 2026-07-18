# 迁移与状态一致性

迁移把一台正在运行的虚拟机拆成可传输的状态，再在目标端恢复。它同时考验设备状态建模、RAM 脏页跟踪、版本兼容和并发收敛。

## 本章目标

- 理解 savevm state、RAM state 与外部后端状态的边界；
- 跟踪 precopy 的迭代、停机窗口和目标端恢复；
- 能判断一个新设备字段是否破坏跨版本迁移。

## 迁移状态机

介绍连接建立、setup、active、device stop、completion、switchover、resume、cancel 与 failure。明确源端和目标端各阶段允许哪些操作。

## VMStateDescription

解释字段、版本、minimum version、subsection、条件字段和 post-load。讨论“能序列化”与“能兼容恢复”之间的区别。

## RAM 迁移与脏页

说明 RAMBlock、脏页 bitmap、迭代发送、限速、auto-converge、postcopy 和压缩。分析写入速率与网络带宽对收敛的影响。

## 设备冻结与恢复

处理 timer、in-flight I/O、virtqueue、内核状态和外部进程状态。说明恢复顺序为何是可观察行为的一部分。

::: {.design-note}
迁移兼容性是一种长期 ABI。结构体字段顺序只是实现细节；真正需要稳定的是迁移流语义、feature 协商和恢复后的 guest 可见状态。
:::

## 小结

迁移不是一次内存复制，而是一套分布式状态转换协议。任何保存字段都必须回答版本、顺序、并发、错误和回滚问题。

## 思考题

1. 为什么新增字段通常应优先考虑 subsection？
2. precopy 在什么条件下不会收敛？
3. 目标端 post-load 失败后，源端是否还能继续运行？
