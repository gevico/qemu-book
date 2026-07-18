# CPU 执行、异常与中断

无论使用 TCG 还是 KVM，QEMU 都需要调度 vCPU、处理异步事件、维护体系结构状态，并把异常、中断和调试事件送到正确的边界。

## 本章目标

- 建立 vCPU 线程从创建到停止的状态机；
- 区分同步异常、外部中断、退出请求和调试事件；
- 理解 `run_on_cpu`、kick 与安全点的用途。

## vCPU 线程与运行状态

讨论 created、runnable、halted、stopped、paused 等状态，以及虚拟机全局 runstate 与单个 CPU 状态的关系。

## TCG 的 cpu_exec 循环

梳理 TB 查找、执行、退出原因处理、异常回送和 interrupt request 检查。解释 longjmp 风格退出为何必须与资源管理约定配合。

## 中断与异常

从设备抬高 IRQ 开始，经过中断控制器、CPU pending state 和架构注入逻辑。对比同步 fault 与异步 interrupt 的精确性要求。

## 跨线程工作

说明 kick vCPU、queued work、`async_run_on_cpu()` 和 `run_on_cpu()` 如何让状态变更发生在正确线程与安全点。

::: {.source-path}
分别选择 TCG 和 KVM，跟踪“暂停虚拟机”和“向 vCPU 注入一个外部中断”两条路径。标记发起线程、持有的锁、唤醒机制和最终消费事件的线程。
:::

## 小结

CPU 执行循环是异步世界与精确体系结构状态之间的接口。正确实现依赖明确的事件类型、状态所有权和跨线程握手。

## 思考题

1. halted vCPU 为什么仍可能需要被 kick？
2. 同步异常为什么要求精确 guest PC？
3. 跨线程直接修改 CPU 状态会破坏哪些假设？
