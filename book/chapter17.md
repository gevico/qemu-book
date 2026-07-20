# 怎样建模一个 RISC-V 外设

拿到一页寄存器表时，第一版代码往往很快：创建一段 MMIO，按偏移写 `switch`，需要时拉起一根中断线。真正费时间的工作出现在随后几周。客户机用半字访问了文档只画成方框的寄存器，串口后端暂时写不动，系统在 FIFO 尚有数据时复位，迁移恰好发生在定时器到期前。寄存器回调仍然只有几十行，设备的行为已经跨过总线、线程、时钟和生命周期。

这一章从 QEMU [`v11.1.0-rc0`](https://gitlab.com/qemu-project/qemu/-/tree/eca2c16212ef9dcb0871de39bb9d1c2efebe76be) 的三个 RISC-V 例子出发：[`hw/misc/sifive_test.c`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/misc/sifive_test.c) 展示最小动作设备，[`hw/char/sifive_uart.c`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/char/sifive_uart.c) 展开一台有队列和时间的外设，APLIC 与 RISC-V IOMMU 用来检查复杂状态的边界。固定源码 commit 为 `eca2c16212ef9dcb0871de39bb9d1c2efebe76be`。

## 先把寄存器表改写成观察契约

建模前先问：客户机能够观察什么？一笔访问至少包含地址、宽度、端序、发起者和当前设备状态，结果可能是返回值、状态转移、中断、DMA、日志或整机动作。规范中的每个寄存器都应被改写成下面四类信息。

| 类别 | 需要写清的内容 | 常见遗漏 |
| --- | --- | --- |
| 输入约束 | 合法偏移、宽度、对齐、只读位和保留位 | 接受了硬件会拒绝的访问 |
| 持续状态 | reset 默认值、写掩码、队列和计数器 | 直接保存原始写入值 |
| 派生结果 | pending、状态位、IRQ 电平和可读窗口 | 同一事实保存两份后失去同步 |
| 外部动作 | 字符输出、DMA、关机、复位和错误上报 | 回滚时假定动作从未发生 |

这一张表会改变结构体的形状。只读状态位如果能从 FIFO 计算，就无需同名字段；write-one-to-clear 位需要保存处理后的 pending；宿主文件描述符和对象指针属于实现资源，不能因它们出现在 C 结构体中就当成设备寄存器。

:::: {.quick-quiz}
为什么按照寄存器偏移给结构体逐项加字段，容易得到错误模型？

::: {.quick-answer}
寄存器表描述客户机接口，结构体还要表达队列、异步操作和宿主资源。有些寄存器是派生视图，有些写入只触发动作；两者与可持久字段并不一一对应。
:::
::::

## `sifive_test`：先看一个没有持续状态的设备

SiFive test finisher 映射 4 KiB 窗口，读总是返回零。向偏移零写入时，低 16 位选择 PASS、FAIL 或 RESET，高 16 位携带退出码；设备据此请求关机或整机复位。其他写入通过 `LOG_GUEST_ERROR` 报告。这里没有需要跨访问保存的寄存器状态，模型更像一个经过 MMIO 触发的动作解码器。

它的类型定义很短：

```c
static const TypeInfo sifive_test_info = {
    .name          = TYPE_SIFIVE_TEST,
    .parent        = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(SiFiveTestState),
    .instance_init = sifive_test_init,
};
```

`TYPE_SYS_BUS_DEVICE`提供可映射的 MMIO 和 IRQ 接口，`instance_init`创建 `MemoryRegion` 并把它登记为一个 sysbus MMIO 端口。板卡代码随后实例化、realize、映射地址。设备文件因此不用知道自己位于哪块 RISC-V 板卡，也不用硬编码系统地址。

这个例子还有一条容易忽略的边界：PASS 写入调用的是“请求关机”，RESET 写入调用的是“请求复位”。设备回调没有在当前调用栈里拆毁机器。整机状态转换要回到 QEMU 主循环的有序路径，避免在 MMIO 回调仍持有对象时释放它。

## QOM 把类型、配置和运行状态分开

QOM 的 [`TypeInfo`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/docs/devel/qom.rst) 描述继承关系、实例大小与初始化钩子；`class_init`给整个类型安装虚函数和属性；实例结构保存每台设备各自的状态。这三层让同一设备可以被创建多次，并让 machine、命令行和管理程序在 realize 前完成配置。

生命周期可以按责任来读：

1. `instance_init`建立不依赖外部配置的内部不变量，例如初始化 child 对象、队列头和 MMIO 容器。
2. properties 与 QOM links 注入 chardev、时钟、地址空间、队列数量等配置。
3. `realize`校验配置，创建 timer、后端 handler 和动态数组，并把失败写入 `Error **errp`。
4. 设备进入运行期，客户机访问寄存器，后端和 timer 推动状态变化。
5. `unrealize`撤销 handler、排空异步任务、释放 realize 阶段取得的资源；对象内存稍后才会 finalize。

SiFive UART 的 `chardev` 是 property。`instance_init`创建 MMIO 和一根输出 IRQ；`realize`创建 8 字节发送 FIFO、虚拟时钟 timer，并在后端已连接时登记接收回调；`unrealize`销毁 FIFO。阅读这段代码时仍要逐项审计 timer 与 chardev handler 的撤销路径，不能从存在一个 `unrealize` 函数推导所有资源都已覆盖。

板载设备常用 `error_fatal`，因为整台 machine 缺少它就无法成立。可热插、可由用户创建的设备应把错误传回调用者，已经完成的步骤要能逆序回滚。把所有错误都升级成进程退出，会让管理层无法诊断和恢复配置失败。

## `MemoryRegionOps` 定义的是总线协议

MMIO 回调收到 `opaque`、区域内偏移、数据和访问宽度。`MemoryRegionOps` 还声明端序以及 `.valid`、`.impl` 的访问范围。前者决定客户机哪些事务合法，后者允许内存框架把合法的大访问拆成模型能够实现的小访问。这些字段属于设备 ABI，并非性能提示。

`sifive_test_ops`允许 2 到 4 字节访问，当前实现使用 `DEVICE_NATIVE_ENDIAN`；SiFive UART 明确要求 4 字节、小端访问：

```c
static const MemoryRegionOps sifive_uart_ops = {
    .read = sifive_uart_read,
    .write = sifive_uart_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 4, .max_access_size = 4 },
};
```

设备回调应按规范做掩码、范围检查和副作用。越界或未实现访问通常记录 `LOG_GUEST_ERROR` 或 `LOG_UNIMP`，返回规范允许的值；能够由恶意客户机触发的输入不能使用宿主断言结束进程。对确实表示 QEMU 内部接线错误的条件，断言才合适。

端序转换由 Memory API 按声明处理。把 `uint8_t *`强转为宿主整数，会把宿主端序、对齐和 C 未定义行为带进客户机接口。RISC-V 示例当前主要运行小端客户机，这也不能成为省略端序声明的理由。

## SiFive UART：寄存器背后有一台状态机

UART 的 `TXFIFO` 写入一个字符。字符先进入 QEMU 的 `Fifo8`，100 ns 后由挂在 `QEMU_CLOCK_VIRTUAL` 上的 timer 尝试发送。chardev 暂时写不动时，代码登记可写 watch；成功写入后才从 FIFO 弹出。`RXFIFO` 的读取会移走队首字符、减少长度、通知 chardev 可以继续接收，并重新计算中断。

这里至少有三种“完成”：客户机执行了 MMIO 写，字符进入发送 FIFO，字符被 chardev 接受。状态寄存器和 reset 要选用同一个语义。若模型在第一步就宣称发送完成，FIFO watermark 和中断会提前变化；若后端已经接受字符，迁移也无法把宿主终端上的输出撤回。

`IP` 寄存器没有独立字段。`sifive_uart_ip()`根据发送 FIFO 使用量、接收长度和 watermark 计算 pending，再由 `sifive_uart_update_irq()`把 pending 与 `IE` 相与，驱动 IRQ。派生函数集中在一处，寄存器写、接收回调和发送完成都可以复用它，降低某条路径忘记降线的概率。

:::: {.quick-quiz}
发送 FIFO 中还有字符时保存一根 IRQ 线的电平，为什么不足以恢复 UART？

::: {.quick-answer}
同一个电平可能来自发送或接收 watermark，也受 `IE` 屏蔽。目标端需要 FIFO、watermark 配置和 enable 状态才能恢复来源，并据此重算输出。
:::
::::

## IRQ、DMA 和时钟把状态边界推向设备外

IRQ 是设备输出，也是另一个对象的输入。模型应保存产生电平的 pending、mask 和队列状态，在状态完整后统一重算。边沿中断还要确认“事件已发生、控制器是否锁存、目标是否已消费”分别由谁保存。APLIC 的数组记录 source、enable、target 和每 hart 状态，输出线只表达其中一个结果。

DMA 设备面对的是客户机地址。设备应通过 `AddressSpace` 和 `dma_memory_read()`、`dma_memory_write()`一类接口访问，保留方向、长度和 `MemTxResult`；不能把客户机物理地址当宿主指针。启用 RISC-V IOMMU 后，同一个 IOVA 还要带上 requester 身份、权限与失效时序。[`hw/riscv/riscv-iommu.c`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/riscv/riscv-iommu.c) 为下游设备建立 IOVA AddressSpace，并把 context cache、IOTLB、fault queue 和通知纳入模型。

timer 选择哪只时钟，会直接改变客户机行为。SiFive UART 使用虚拟时钟，QEMU 暂停时发送推进也暂停；墙钟设备则要明确暂停期间是否继续走时。timer 对象包含宿主回调和指针，能够迁移的是 deadline 或剩余时间以及足以重建它的设备状态。异步 DMA、bottom half 和 chardev watch 也遵循同一规则：reset 前要取消或排空，unrealize 前还要保证迟到回调不再访问对象。

## Reset 是一次有顺序的协议

QEMU 的 [`Resettable`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/docs/devel/reset.rst) 把复位分为 enter、hold、exit。enter 只改本地状态，不能升降 IRQ 或访问其他对象；整棵 reset 树完成 enter 后，hold 可以处理跨对象副作用；exit 在对象离开复位态时执行。这样的顺序让一组设备先各自回到可解释状态，再改变连接关系。

SiFive UART 在 enter 中清寄存器、接收数组和两个 FIFO，在 hold 中降低 IRQ。它没有重新创建 MemoryRegion、chardev 或 timer。构造、暂停、reset、迁移和 unrealize因此有五种不同目标：构造取得资源，暂停保留状态，reset恢复规范初值，迁移复制运行状态，unrealize撤销资源。

直接 `memset(s, 0, sizeof(*s))`会清掉父类、MemoryRegion、timer 指针和后端连接，也无法表达非零复位值。即使只清“寄存器区域”，仍要处理 FIFO、pending、in-flight DMA 与 timer。reset 测试必须先制造非默认状态；空闲设备在没有 reset 回调时也可能看起来正确。

对于 DMA 设备，Resettable 文档还给出次序约束：未完成 DMA 应在 enter 或 hold 阶段取消，IOMMU 通常在 exit 阶段恢复翻译，避免尚未停止的请求撞上已经清空的映射。这个规则是审查基准，不是对现有设备的自动证明。固定基线中的 RISC-V PCI 与 system IOMMU 包装器都在 reset `hold` 回调里调用 `riscv_iommu_reset()`；审查时必须继续证明上游 DMA 已经停止，或把 phase 差异作为需要修正的生命周期问题，而不能只凭通用文档宣布顺序成立。

## VMState 是线上的兼容协议

客户机可观察状态与 C 结构体不能画等号。`VMStateDescription`逐字段定义迁移流，版本、条件 subsection 和 load hook 都会成为兼容承诺。结构体可以重排，线上字段不能随意删除或换语义；宿主指针、`MemoryRegion`、`qemu_irq` 和 chardev 句柄由目标配置重建。

SiFive UART 的 version 3 保存接收数组及长度、`ie/txctrl/rxctrl/div/txfifo`、发送 `Fifo8` 和 timer。它没有保存 MMIO、IRQ 句柄、chardev，也没有保存可由队列与控制寄存器算出的 `IP`。这份字段表提供了一个待验证的设计假设：恢复后读到的 FIFO、watermark 和 timer 应连续，IRQ 应与派生条件一致。字段齐全只能证明序列化入口存在，实际 save/load 才能证明恢复时序正确。

添加字段时要问旧目标如何读取、新目标如何加载旧流、默认值是否与旧行为一致。对动态数组先传长度、校验上界、分配，再读取内容。迁移输入来自另一进程，必须按不可信数据处理；版本号不能代替范围检查。

:::: {.quick-quiz}
为什么 `qemu_irq`、`QEMUTimer *` 和 `MemoryRegion` 不能作为原始字节写入 VMState？

::: {.quick-answer}
它们包含目标进程重新创建的对象关系、回调和宿主地址。迁移流应保存客户机能观察的状态及时间关系，目标根据相同 machine 配置重建这些资源。
:::
::::

## 从 UART 走向 APLIC 和 RISC-V IOMMU

复杂设备没有另一套建模方法，只是状态所有者更多。当前 APLIC 的 `TypeInfo`仍然继承 `TYPE_SYS_BUS_DEVICE`，realize 根据 hart 数和 IRQ 数分配数组，VMState 以可变数组保存 source、target、enable 与每 hart delivery 状态。`.needed`只在 APLIC 由 QEMU 模拟时发送这些字段；若 live owner 在 KVM，用户态影子不能冒充权威状态。

RISC-V IOMMU 进一步引入寄存器镜像、只读/清零掩码、context cache、IOTLB、命令/故障/页请求队列、AddressSpace、HPM timer 和 PCI/system 两种包装。realize 建立地址空间和能力寄存器，reset 清 DDTP、queue 状态、pending 与缓存。固定基线中的 PCI 包装明确标成 `.unmigratable = 1`；system 包装没有一份足以证明完整迁移的设备 VMState。书中因此只确认 reset 实现，不把“能启动、能做 DMA”扩写成“可以迁移”。

从最小 finisher 到 IOMMU，开发者始终在回答同一组问题：输入是否合法，谁拥有持久状态，输出怎样派生，异步动作在哪里完成，reset和迁移如何建立边界，失败能否回滚。QOM API 名称只是这些答案在 QEMU 中的落点。

## 用测试和 trace 关闭证据链

设备测试应从寄存器契约逐层扩展。qtest 适合验证合法/非法宽度、保留位、write-one-to-clear、FIFO 边界、IRQ 升降和 reset；迁移测试要在 FIFO 非空、timer armed、pending 被 mask 等状态保存恢复；功能测试再运行真实 RISC-V firmware、RTOS 或 Linux driver。每层失败都能定位到不同责任。

trace event 应记录状态转折所需的标识，例如对象 ID、寄存器偏移、旧值/新值、queue、IRQ 来源和 DMA 地址。对不合法客户机输入使用限量日志，避免恶意 guest 造成无界输出。错误路径也要测试：realize 缺属性、后端断开、DMA 返回失败、迁移流长度越界、unrealize 时仍有 callback。

一份可评审的外设补丁通常按以下顺序收敛：先提交寄存器与 reset 测试，再放入最小 QOM 类型和 MMIO；接着接线 IRQ、clock、DMA 与板卡；随后补 trace、VMState 和负向测试；文档写出仍未实现的位与迁移限制。reviewer 可以逐步核对不变量，贡献者也不必用一次真实系统启动覆盖全部论证。

## 实验：让 UART 在非默认状态复位

::: {.hands-on}
配套手册：[`trace-reset-phases`](../experiments/part-04-machine-and-device-models/chapter-17-device-lifecycle/trace-reset-phases/README.md)。

用带调试符号和 tracing 的 `qemu-system-riscv64` 让选定设备进入非默认状态，再从 monitor 执行 `system_reset`。配套脚本默认启动 `virt`，因此动态对象是 16550 UART 与可选 APLIC，不能在这台 machine 上期待进入 SiFive UART 回调。若要跟随本章的 SiFive UART 状态机，应另用包含该设备的 `sifive_u`，再在 `sifive_uart_reset_enter()`、`sifive_uart_reset_hold()`设置源码断点；留在 `virt` 时则观察实际的 16550/APLIC reset 路径。两条分支都要记录 machine、QOM 路径、enter/hold/exit 与 IRQ 变化，不能把一个 machine 的断点结果移植到另一个。

预期对象与 MMIO 映射继续存在，本地状态先恢复，外部 IRQ 在允许跨对象动作的阶段改变。报告需要区分构造初值、reset 前状态和 reset 后状态，不能按 callback 注册先后猜测 reset 树顺序。
:::

## 实验：审计 SiFive UART 的 VMState

::: {.hands-on}
配套手册：[`inspect-vmstate-fields`](../experiments/part-04-machine-and-device-models/chapter-17-device-lifecycle/inspect-vmstate-fields/README.md)。

从 `SiFiveUARTState`列出所有成员，分别标记持续状态、派生状态、宿主资源、timer 和对象连接；再与 `vmstate_sifive_uart`、reset 和 realize/unrealize 对照。对每个未迁移字段写出“目标重建”“可从哪些字段推导”或“仍需运行验证”，不要用“结构体里没有变化”代替证据。

有运行环境时，让发送 FIFO 非空、接收 FIFO 达到 watermark，并把 timer 留在 pending 状态后执行 save/load。恢复后检查字符顺序、`IP`、IRQ 与 timer 只触发一次。只有源码时将结果标成静态审计；字段表加运行现象形成闭环后，才可以声明这组状态可恢复。
:::

建模完成的判断标准也随之清楚：一页寄存器规范已经变成了可观察、可复位、可迁移或明确拒绝迁移、可诊断并能被自动测试的状态机。客户机跑过一次启动日志，只完成了其中一项验证。
