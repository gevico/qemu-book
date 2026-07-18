# 加速器抽象与 KVM

QEMU 的设备与机器模型不应依赖某一种 vCPU 执行引擎。加速器抽象允许 TCG 在用户态翻译执行，也允许 KVM 把 vCPU 交给内核运行。

## 本章目标

- 理解 AccelClass、CPUClass 与具体 accelerator 的职责边界；
- 跟踪 KVM vCPU 创建、状态同步、`KVM_RUN` 和 exit handling；
- 解释为何 KVM 加速仍需要完整的 QEMU 设备模型。

## 加速器选择与初始化

分析 `-accel` 配置、machine 允许的 accelerator、全局初始化和 per-vCPU 初始化。说明 capability 探测如何影响设备和 CPU 特性。

## KVM vCPU 运行循环

从用户态准备寄存器和中断状态，到进入 `KVM_RUN`，再到处理 MMIO、PIO、halt、system event 等退出原因。

## CPU 状态同步

区分 QEMU 可见状态、内核 vCPU 状态和“dirty”标记。讨论调试、迁移、设备访问和异常注入何时需要同步。

## irqchip 与内核加速设备

说明设备模型一部分进入内核后的边界变化，以及 split irqchip、in-kernel irqchip 对中断路径和迁移的影响。

::: {.design-note}
KVM 不是绕过 QEMU，而是替换 vCPU 指令执行这一层。配置、设备模型、I/O 后端、管理面和迁移仍需要在边界清晰的前提下协作。
:::

## 小结

加速器抽象把“CPU 如何运行”与“机器是什么”分离。KVM 的关键不只是一次 ioctl，而是用户态与内核态之间的状态所有权协议。

## 思考题

1. KVM exit 越少是否一定越好？
2. 哪些 CPU 状态不需要在每次进入内核前同步？
3. in-kernel irqchip 给迁移带来了什么额外约束？
