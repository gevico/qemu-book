# 块设备与网络 I/O

块设备和网络是最常见的高吞吐 I/O 子系统。两者都需要后端抽象、异步执行、限速与错误传播，但数据模型和一致性要求不同。

## 本章目标

- 理解 block graph、BlockDriverState、BlockBackend 与节点权限；
- 跟踪一个 virtio-blk 请求到宿主文件或远端存储；
- 识别网络前端、NetClientState、filter 与 host backend 的边界。

## Block graph

解释 protocol node、format node、filter node、child link 和 permission。说明图结构如何支持镜像、备份、快照、throttle 与运行期重配置。

## 块请求的异步路径

从设备请求进入 BlockBackend，经 coroutine、driver 回调、AIO engine 到宿主完成通知。讨论 flush、discard、write zeroes 和错误策略。

## 网络前后端

区分 NIC device model 与 netdev backend，梳理 packet queue、filter、tap、socket 和 vhost-net。讨论 backpressure、offload 与多队列。

## 一致性与性能

比较存储持久性语义和网络尽力交付语义。分析 batching、零拷贝、buffer lifetime、限速和迁移冻结点。

::: {.source-path}
选择一个 virtio-blk 写请求，标出 descriptor 解析、block layer 入口、协程切换、宿主 I/O 提交和 used ring 更新。再标注 flush 请求与普通写请求的顺序约束差异。
:::

## 小结

I/O 子系统通过图、队列和异步回调把设备模型与多种后端解耦。真正困难的部分不是提交请求，而是规定完成、取消、错误与重配置的语义。

## 思考题

1. block layer 为什么需要 child permission？
2. flush 完成对之前的写请求意味着什么？
3. 网络 backpressure 应该在哪些层传播？
