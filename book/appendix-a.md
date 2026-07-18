\appendix

# 源码阅读与实验速查

本附录收集全书通用的源码阅读方法和实验记录模板。具体命令应根据 QEMU 版本调整。

## 推荐的工作树布局

```text
workspace/
├── qemu/          # 上游源码
├── build-tcg/     # TCG 构建目录
├── build-kvm/     # KVM 构建目录
├── images/        # 实验镜像
└── notes/         # 命令、trace 与结论
```

QEMU 使用 out-of-tree build。不要把生成文件混入源码目录，也不要在没有记录 configure 参数的情况下比较两个二进制。

## 一次实验至少记录什么

| 项目 | 示例 |
| --- | --- |
| QEMU 版本 | tag 或完整 commit hash |
| 宿主环境 | CPU、内核、发行版、编译器 |
| 构建参数 | 完整 configure 命令 |
| 运行参数 | 完整 QEMU 命令行 |
| 客户机环境 | machine、CPU model、固件、内核 |
| 观察工具 | trace events、perf、QMP 命令 |
| 预期现象 | 先写出可以证伪的判断 |
| 实际结果 | 保存原始日志和时间戳 |

## 源码检索清单

1. 从类型名查 `TypeInfo` 和注册函数；
2. 从结构体查 owner、生命周期和 class 回调；
3. 从 QAPI 命令查 schema、generated marshal 和实现函数；
4. 从 trace event 查发出位置和字段含义；
5. 从错误字符串反向定位失败分支；
6. 使用 `git blame` 和邮件列表补足“为什么这样设计”。

## 章节完成标准

一章进入“可评审”状态前，至少应具备：

- 清晰的概念图或状态图；
- 一条经过版本固定的主要调用路径；
- 一个读者可以复现的实验；
- 对至少一种替代设计或历史约束的解释；
- 小结、思考题和官方参考资料。
