# 事件循环、线程与并发模型

QEMU 同时包含主事件循环、vCPU 线程、I/O 线程、协程和工作线程。理解“代码在哪个上下文运行”是判断锁、阻塞和重入问题的前提。

## 本章目标

- 区分 main loop、`AioContext`、iothread、bottom half 与 coroutine；
- 理解 BQL、RCU、mutex 和原子操作各自保护的边界；
- 能定位一次阻塞为何拖慢整个虚拟机。

## 主循环与事件源

介绍 fd handler、timer、bottom half 和事件通知。说明事件源注册、poll、dispatch 与删除如何避免 use-after-free。

## AioContext 与 iothread

解释 AioContext 作为事件循环和并发域的双重角色。讨论设备或后端迁移到 iothread 后，调用者和数据所有权如何变化。

## Coroutine

说明协程适合表达异步状态机，但不会自动把阻塞操作变成异步。分析 coroutine enter/yield、AIO completion 与 thread pool 的配合。

## BQL、RCU 与细粒度锁

介绍 Big QEMU Lock 的历史角色、逐步缩小临界区的动机，以及 RCU 在读多写少结构中的使用方式。

::: {.design-note}
线程、事件循环和协程是三个不同维度。协程切换不等于线程切换，AioContext 归属也不等于对象的内存所有权；阅读代码时应分别标注。
:::

## 小结

QEMU 的并发不是单一模型，而是多个执行上下文通过明确的锁、通知和状态转移协作。性能问题常常来自把耗时工作放错上下文。

## 思考题

1. bottom half 与 timer 的调度语义有何不同？
2. 为什么在协程里调用阻塞系统调用仍会阻塞线程？
3. RCU 读侧为什么不能任意长期持有指针？
