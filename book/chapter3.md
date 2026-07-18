# Machine、总线与设备生命周期

一台虚拟机不是若干设备的平铺列表。`MachineClass` 提供板级约束，`MachineState` 保存实例状态，qdev 和 BusState 则把设备组织成可配置、可热插拔的拓扑。

## 本章目标

- 跟踪 machine 选择、初始化和设备 realize 的主要阶段；
- 区分设备创建、属性配置、realize、reset、unrealize 与销毁；
- 理解板级默认值、兼容属性和用户显式配置的优先级。

## MachineClass 与 MachineState

说明 machine type 如何注册，默认 machine 如何选择，CPU、RAM、固件和板载设备如何在 machine init 中装配。

## qdev 的两阶段构造

设备先创建并配置，再 realize。分析这一拆分如何支持依赖注入、错误回滚和拓扑校验，以及为何 realize 之后多数结构属性不能随意改变。

## 总线与热插拔

讨论父总线、子总线、hotplug handler 和 unplug 流程。用 PCI 或 sysbus 设备比较“可枚举总线”与“板级固定设备”。

## Reset 是一套状态机

介绍 resettable 接口、reset 域和 reset 类型，区分对象生命周期与设备复位生命周期。

::: {.hands-on}
启动一台最小 machine，通过 QMP/HMP 导出 qtree 与 QOM tree。选择一个设备，找出它的父总线、QOM owner、realize 回调和 reset 回调，并画出四者关系。
:::

## 小结

machine 决定平台，qdev 管理设备生命周期，总线表达连接约束。三者共同把命令行参数变成可运行的硬件拓扑。

## 思考题

1. 板载设备为什么也要经过 qdev 生命周期？
2. 热拔除为何通常是异步流程？
3. machine compatibility 属性如何影响迁移兼容性？
