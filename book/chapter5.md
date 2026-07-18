# TCG 前端：从客户机指令到中间表示

TCG 前端负责读取客户机指令、译码、生成体系结构无关的 TCG IR，并在必要时调用 helper 完成复杂语义。

## 本章目标

- 理解 Translation Block 的边界和翻译上下文；
- 跟踪译码器、translate 回调、TCG op 与 helper 的关系；
- 能判断一段架构语义应该展开为 IR 还是放进 helper。

## 翻译入口与上下文

介绍 CPUClass 提供的翻译接口、DisasContext 保存的状态，以及 TB flags 如何把影响翻译结果的 CPU 状态编码进缓存键。

## decodetree 与手写译码

说明指令 pattern、field、argument set、生成的解码器和 translate function。比较声明式译码与传统手写 switch 的维护成本。

## TCG IR

围绕临时变量、load/store、条件跳转、原子操作和内存序讲解 IR。说明前端如何保留 guest 语义，同时避免绑定某个 host ISA。

## Helper 边界

分析 helper 的调用开销、状态可见性、异常退出和优化屏障。给出选择 helper 的判断标准：语义复杂度、热度、可优化性和架构状态同步要求。

::: {.source-path}
选择一条简单整数指令和一条可能触发异常的访存指令，对照 decodetree pattern、translate function、TCG op 序列与 helper。记录每一步能够访问的 CPU 状态。
:::

## 小结

TCG 前端的核心任务是把 guest 语义准确地投影到有限、可优化的 IR，同时显式处理状态、异常和内存序边界。

## 思考题

1. 哪些 CPU 状态必须进入 TB flags？
2. helper 为什么可能阻碍优化？
3. 一条指令跨页时，译码边界应该怎样处理？
