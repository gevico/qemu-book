# 设备模型、virtio 与 vhost

设备模型把 guest 可见寄存器、队列和中断转换为后端操作。virtio 定义半虚拟化设备接口，vhost 则可以把部分数据面下沉到内核或独立进程。

## 本章目标

- 掌握设备寄存器、IRQ、DMA、timer 与 reset 的通用实现模式；
- 区分 virtio device、transport、virtqueue 与 backend；
- 理解 vhost 的控制面仍由 QEMU 协调。

## 一个普通设备模型

从 MMIO region、读写回调、IRQ line、DMA AddressSpace 和 timer 构造最小设备。讨论寄存器 side effect、访问宽度和端序。

## virtio 分层

把 virtio 核心、PCI/MMIO/CCW transport 和具体设备拆开。说明 feature negotiation、queue setup、kick、used notification 与配置中断。

## virtqueue 数据路径

跟踪 descriptor table、avail ring、used ring 和 event suppression。讨论 scatter-gather、地址翻译、内存屏障和恶意 guest 输入校验。

## vhost 边界

介绍 vhost-net、vhost-user 等后端如何取得队列和内存映射，QEMU 如何处理启动停止、feature、通知与迁移协调。

::: {.hands-on}
为同一个 virtio 设备分别关闭和开启 vhost，记录 QEMU 线程、系统调用和中断数量。解释哪些操作离开了 QEMU 数据面，哪些控制路径仍然保留。
:::

## 小结

qdev 负责设备生命周期，MemoryRegion 与 AddressSpace 提供访问，virtio 规范化队列接口，vhost 改变数据面的执行位置。

## 思考题

1. virtio device 与 transport 为什么分离？
2. vhost 为什么需要知道 guest memory table？
3. 设备 reset 时必须怎样处理尚未完成的异步请求？
