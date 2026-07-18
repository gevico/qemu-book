# TCG 后端与 Translation Block

TCG 后端把 IR 优化并降低为宿主机指令。生成的代码以 Translation Block 为单位缓存、查找、链接和失效。

## 本章目标

- 解释 TCG pass、liveness、寄存器分配与后端约束；
- 理解 TB 的查找键、直接链接和退出原因；
- 跟踪自修改代码、断点和内存映射变化造成的失效。

## 从 IR 到主机代码

介绍通用优化、操作约束、临时值生存期和线性扫描寄存器分配。说明 host backend 如何描述寄存器、指令编码与 relocation。

## TB 缓存与查找

拆解 guest PC、地址空间、CPU mode 和 flags 如何确定一个 TB。区分快速查找、全局表与每 vCPU 缓存。

## Direct block chaining

说明 TB 尾部如何直接跳到下一个 TB，以及中断、单步、断点和状态变化为什么需要打断链接。

## 失效与同步

讨论自修改代码、TLB flush、代码页写入、全局 flush 和 MTTCG 下的安全点。

::: {.hands-on}
使用 QEMU 的 TCG 日志选项记录一小段 guest 代码的 `in_asm`、`op` 和 `out_asm`。把一条 guest 指令对应到 TCG op，再对应到 host 指令，并解释 TB 的退出位置。
:::

## 小结

TB 把翻译成本摊薄到多次执行，direct chaining 缩短分派路径，而精确失效机制保证缓存代码仍与 guest 状态一致。

## 思考题

1. 为什么 TB 通常不能无限增长？
2. 直接链接如何与异步中断共存？
3. 自修改代码检测依赖哪些内存元数据？
