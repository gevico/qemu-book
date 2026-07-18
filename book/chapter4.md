# 内存子系统：从地址空间到访问分派

QEMU 的内存 API 同时描述 RAM、ROM、MMIO、别名、容器和 IOMMU。设备看到的是地址空间，配置代码操作的是区域树，执行热路径使用的是扁平化结果。

## 本章目标

- 区分 `MemoryRegion`、`AddressSpace`、`FlatView` 与 `RAMBlock`；
- 理解优先级、重叠、alias 和 container 的解析规则；
- 跟踪一次 CPU 或 DMA 访问到 RAM 或设备回调的路径。

## MemoryRegion 拓扑

解释叶子区域与非叶子区域、subregion 偏移、overlap priority 和 alias。通过一个有 PCI MMIO 窗口的示例构造区域树。

## 从树到 FlatView

说明 topology transaction 如何批量更新，listener 如何获知变化，RCU 如何保护读侧热路径。解释为什么配置友好的树不直接用于每次访存。

## CPU 地址转换与 SoftMMU

区分 guest virtual、guest physical、QEMU `hwaddr` 与 host virtual address。连接架构 MMU、软件 TLB、MemoryRegion 分派和脏页跟踪。

## DMA 与 IOMMU

讨论设备通过 `AddressSpace` 发起 DMA 的原因，IOMMU region 如何进行二次转换，以及访问权限和 IOTLB 失效如何传播。

::: {.design-note}
“内存拓扑”和“内存内容”是两个不同问题。前者决定某个地址由谁响应，后者决定 RAM 中保存什么数据；迁移、脏页与快照会同时触及二者，但不能混为一谈。
:::

## 小结

MemoryRegion tree 提供可组合配置，FlatView 提供高效查找，AddressSpace 提供访问视角。理解三者转换是阅读 CPU、DMA、IOMMU 与迁移代码的基础。

## 思考题

1. alias region 为什么不复制内存内容？
2. FlatView 更新为何适合由 RCU 保护？
3. 设备 DMA 和 vCPU 访存在哪个层次汇合？
