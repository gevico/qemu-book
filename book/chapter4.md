# 为什么 C 代码库需要 QOM

给 RISC-V `virt` 增加一个可选 IOMMU 时，板级代码至少要做几件事：根据 Machine 属性决定是否创建，按字符串找到正确类型，先设置地址、中断与后端，再让设备建立资源；任何一步失败，都要把前面已经创建的对象安全撤回。虚拟机关闭或设备拔除后，排队的回调也不能继续访问它。

如果 QEMU 只有几种固定设备，C 结构体、函数指针和手写初始化已经够用。项目发展到数百种可选类型以后，调用者还需要在运行时按名字创建对象、检查继承关系、枚举属性、统一报告错误，并让 QMP 看见它们。每个子系统各自维护一套注册表和生命周期，组合机器时就会产生大量不兼容的局部约定。QEMU Object Model，简称 QOM，正是在这类压力下进入工程。

QOM 没有隐藏 C。对象仍是一块结构体内存，继承依靠父结构体位于开头，虚方法仍是函数指针，存活依靠引用计数。它增加的是一套运行时共同语言：什么类型能够创建，当前实例属于谁，哪些属性可以配置，何时允许失败，什么时候客户机已经能看到设备，以及最后一个引用何时离开。

## 运行时装配提出了哪些要求

QEMU 构建完成时，并不知道用户会选择 `virt`、哪一种 RISC-V CPU、几颗 hart、PLIC 还是 AIA、是否接入 IOMMU，以及块和网络后端来自哪里。命令行与 QMP 使用字符串命名对象，模块还可能按构建配置延迟装入。编译期 C 类型无法独自回答“字符串 `riscv-iommu-sys` 对应哪个构造过程”。

第二项要求来自公共调用。Machine 框架需要面对所有 Machine，CPU 调度层需要面对所有目标 CPU，qdev 要面对所有设备。调用者只能持有父类型，通过 class 方法进入具体实现。若每次都写目标枚举和 `switch`，新增一个类型会修改大量中央代码，模块化构建也会失去意义。

第三项要求来自失败和离开。打开后端、占用总线资源、注册 MemoryRegion 都可能失败，instance 初始化却需要保证对象至少能够安全释放；运行中的 reset 要保留配置和连接，只恢复客户机状态；unrealize 要先让设备退出机器，finalize 才能回收内存。没有共同阶段，错误回滚与热拔除会由每个设备临时发明。

:::: {.quick-quiz}
把设备型号做成一个 C `enum`，再在 Machine 中用 `switch` 创建，为什么难以支撑 QEMU 当前的配置方式？

::: {.quick-answer}
中央枚举要求所有可选类型在编译期集中可知，新增模块还要修改公共分支；字符串查找、继承查询、属性枚举与 QMP introspection 也要另写机制。QOM 让类型自行注册，公共代码通过父类和接口调用。
:::
::::

## 2012 年的转折：先建立共同的 Object

QOM 的基础提交是 Anthony Liguori 的 [`2f28d2ff`](https://gitlab.com/qemu-project/qemu/-/commit/2f28d2ff9dce3c404b36e90e64541a4d48daf0ca)，作者说明它受 GObject 启发。提交保留了 v1 到 v2 的修改记录：Paolo Bonzini 提议去掉公开 `Type`、用哈希表保存类型、缓存父类型并统一接口注册等。这里可以看见 review 如何改变框架形状；提交没有正式的 `Reviewed-by: Paolo`，因此只能说 v2 记录了他的具体建议。

紧接着的 [`57c9fafe`](https://gitlab.com/qemu-project/qemu/-/commit/57c9fafe0f759c9f1efa5451662b3627f9bb95e0) 把 property 从 qdev 下沉到 Object。Anthony 在提交说明中给出直接理由：普通 Object 也能在 qdev 之外有实际用途。后来的内存后端、IOThread 等宿主对象可以获得名称、属性、路径和生命周期，同时无需伪装成客户机设备。

Andreas Färber 的 [`dd83b06a`](https://gitlab.com/qemu-project/qemu/-/commit/dd83b06ae61cfa2dc4381ab49f365bd0995fc930) 又把 `CPUState` 引入 QOM，定义抽象 CPU class 和虚拟 reset 方法，Anthony Liguori 给出 `Reviewed-by`。这项变化解释了当前 RISC-V CPU 为何能同时参与运行时类型、通用调度和目标专属状态。历史在这里已经足以解释转折，后面直接看当前实现。

## 从 `TypeInfo` 到一组 RISC-V hart

在 `v11.1.0-rc0` 的 [`qom/object.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/qom/object.c) 中，类型先通过 `TypeInfo` 注册。它记录名称、父类型、instance/class 大小、初始化与清理回调，以及接口。注册只声明“以后能够创建什么”，不会立即分配对象。`type_initialize()` 在需要 class 时先初始化父类，复制父 class 的方法，再运行当前类型的 `class_init`。

[`virt_machine_typeinfo`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/virt.c)把 `virt` 声明为 `TYPE_MACHINE` 的子类型，指定 class init、instance init、finalize 和实例大小。class 中的 `mc->init = virt_machine_init` 由所有 `virt` 实例共享；本次启动的 RAM 大小、FDT、AIA 与 IOMMU 选择则保存在 `RISCVVirtState` 实例里。把实例配置写进 class，会让所有同类型对象共享一份错误状态。

hart array 展示了组合过程。[`hw/riscv/riscv_hart.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/riscv_hart.c) 注册 `TYPE_RISCV_HART_ARRAY`，realize 时根据 `num-harts`、`hartid-base` 和 `cpu-type` 调用 `object_initialize_child()` 创建各个 `RISCVCPU`，再逐个 `qdev_realize()`。Machine 处理拓扑，容器负责 child 生命周期，CPU 类型负责 ISA 与加速器约束。

这里同时存在三种容易混淆的“父”。`RISCVCPU` 在类型上继承通用 CPU；实例在 QOM 组合树中由 hart array 拥有；作为 qdev 设备时还参与相应总线和执行框架。类型父决定布局和方法，组合父决定规范路径与所有权，总线或调度关系决定连接。把三条边画成一棵树，热拔除和错误回滚很快就会失去依据。

:::: {.quick-quiz}
`RISCVCPU` 在 `info qom-tree` 中位于 hart array 下，能否由此推出它的 C 父类型也是 hart array？

::: {.quick-answer}
不能。QOM tree 展示实例组合，C/QOM 继承由 `TypeInfo.parent` 决定。hart array 拥有 CPU child，`RISCVCPU` 的类型链则通向通用 CPU/Device/Object 层，两条关系服务不同问题。
:::
::::

## 生命周期为什么要分段

对象创建先分配内存并运行 instance 初始化。这个阶段适合初始化锁、列表、默认字段和不会失败的局部 child；它没有普通 `Error **` 返回通道，调用者假定对象能进入安全的释放路径。需要打开文件、检查后端或连接平台资源的动作应留给 realize。

创建与 realize 之间是配置窗口。Machine 或用户把 CPU 类型、hartid、设备 link、地址与功能属性写进对象，所有依赖准备好后再调用 [`qdev_realize()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/core/qdev.c)。DeviceClass 的 realize 可以返回结构化错误，qdev 框架会处理 child bus 和监听器，并在失败路径调用相应清理。设备被标记 realized 后，客户机才应能通过地址、中断或总线看到它。

reset、unrealize 和 finalize回答三种不同变化。reset 保留对象、属性、后端和连线，恢复客户机可见寄存器与队列；unrealize 停止数据面、撤销 MemoryRegion/IRQ/handler，让对象离开运行机器；finalize 在最后引用消失且对象已经 unparent 后释放实例资源。把关闭文件放到 reset，会让系统复位后设备无法继续工作；把 timer 取消拖到 finalize，又可能让已经离开机器的对象被回调。

RISC-V hart 批量创建尤其考验失败路径。第 N 颗 CPU realize 失败时，前 N−1 颗已经经过部分生命周期。容器必须让它们都能按拥有关系清理，不能留下半个 CPU 在全局列表或 QOM tree 中。成功启动覆盖的是正向路径，工程质量往往藏在第 N 步失败、reset 与退出中。

:::: {.quick-quiz}
一个设备的属性值需要打开宿主文件并可能失败，适合放在 `instance_init` 里立即处理吗？

::: {.quick-answer}
更合适的做法是在 instance 阶段保存默认和局部状态，属性设置后由 realize 获取外部资源并通过 `Error **` 报错。这样调用者能得到清楚诊断，也能对部分构造执行统一回滚。
:::
::::

## 属性把控制面接到类型化状态

QOM property 把命令行、QMP Visitor 和 C 字段连接起来。Machine 的 `aia`、`iommu-sys`，CPU 的扩展开关，普通 Object 的后端参数，都可以通过同一套发现和读写机制暴露。setter 仍要检查类型、范围与阶段；统一 property API 没有消除具体对象的业务约束。

结构性属性通常只允许在 realize 前改变。hart 数会决定 child 数量，CPU 扩展会改变译码和迁移状态，MemoryRegion 大小会改变地址图。设备运行后再写这些值，需要完整的暂停、重配、客户机通知和迁移语义。没有这套协议，setter 应在 realized 状态下拒绝，而不是只改一个字段留下陈旧资源。

属性也会成为兼容表面。管理工具可能按名字查询，Machine compat property 可能覆盖旧默认，用户会把对象 id 和路径写进脚本。因此，内部临时变量不应为了“方便查看”全部公开成 property；具有副作用和异步完成的动作也更适合专用 QAPI 命令。QOM 提供工具，接口是否值得长期承诺仍需独立判断。

## 沿 `object_new()` 看一遍当前实现

`object_new(typename)` 先按名称找到 `TypeImpl`，必要时初始化 class，再根据 instance size 分配内存。`object_initialize_with_type()` 建立 Object 头部并沿父到子运行 instance init；调用返回时，对象具有合法类型和局部默认，但用户属性、父对象和 qdev realize 可能都还没有发生。看到 `object_new()` 成功，不能把它记成“设备已经加入机器”。

对象成为 child 时，`object_property_add_child()` 建立组合关系和 canonical path。用户可创建对象还会先检查 id、抽象类型和 property，再接到合适容器。路径查询只遍历当前可见组合树，一个对象因额外 ref 留在内存、却已经 unparent 时，`info qom-tree` 找不到它。运行树是生命周期观测，不是堆内全部对象清单。

最后一次 `object_unref()` 把 ref 降到零，QOM 要求对象已经没有 parent，随后按子到父方向运行 instance finalize 并释放内存。这个断言迫使调用者先拆组合、再结束存活。引用环会让 ref 永远不到零，遗漏引用则可能在回调尚未结束时提前 finalize；两者都需要沿实际 ref/unref 查找，单看 QOM tree 发现不了。

class 的初始化时点也值得区分。类型注册可以发生在模块装入时，class 通常按需创建，父 class 方法会先复制给子类，子 `class_init` 再覆盖。覆盖方法不会自动调用父实现，具体 class 若需要父逻辑，要保存并显式调用。设备 realize/reset 的父子顺序因此来自代码约定，不能由“面向对象”四个字推断。

这条实现线给调试提供了五个锚点：type register、object new、add child、qdev realize、unparent/finalize。类型名查不到，从注册和模块开始；属性存在、资源缺失，检查 realize；对象离开树却没有 finalize，查剩余引用；退出时 use-after-free，查异步工作是否持有合适引用及是否在 unrealize 前取消。

## child、link、ref 与设备连接各有用途

child 表达组合拥有关系，父对象给 child 提供 canonical path，并在生命周期上承担责任。link 表达对象之间的关联，可以按 flags 决定是否持有引用；普通 `object_ref()` 只延长存活，不创建路径。qdev bus、IRQ 和 MemoryRegion 又表达客户机硬件连接。一个设备可能由 `/machine/peripheral` 拥有，同时插在 PCIe bus 上，并把 MMIO region 映到另一个地址容器。

这几类关系不能靠命名猜测。异步回调持有 ref，只能保证对象内存尚在，不能保证设备仍 realized；对象作为 Machine child，也不能保证任意线程可无锁访问；link 指向后端，还要由设备 realize 检查是否允许共享。排查 use-after-free 时，应画强引用和回调；排查客户机找不到设备时，应看 bus、地址和中断；两类图的边不同。

类型检查同样只覆盖一段。`RISCV_CPU(obj)` 成功，说明实例兼容该类型，不说明它已经 realize、当前线程有访问权或寄存器是最新状态。QOM 让一类错误尽早暴露，没有承诺替调用者解决并发和加速器状态所有权。

## 异步工作让“活着”和“可用”分成两件事

设备把请求交给 IOThread 或线程池后，回调可能晚于主线程的 reset、unrealize 甚至 unparent。给请求增加一个 Object ref，可以保证内存活到完成；设备已经 unrealize 时，MemoryRegion、IRQ 和后端连接可能撤销，回调仍不能继续按正常路径访问。存活只解决悬空指针，可用性还要靠状态机、generation 或 drain。

reset 更容易制造误会。对象保持 realized，旧请求却可能属于 reset 前一代状态。完成回调要识别 generation，按设备规范丢弃、报错或收尾；引用计数无法区分两代请求。unrealize 则要停止新请求，等待或取消在途工作，撤销外部 handler，最后才让 Object 进入可释放状态。

热拔除还会跨多个图。qdev bus 先不再枚举设备，MemoryRegion 从地址图移除，IRQ 与后端 link 断开，QOM child 最终 unparent。任何旧 FlatView、timer 或 BH 都可能晚到。设计 teardown 时应写逆序依赖，而不是在 finalize 里集中 `free()`；finalize 已经太晚，外部系统需要提前收到撤销动作。

这也是为什么 QOM 无法单独证明线程安全。组合 parent 可以在 BQL 下提供稳定生命周期，IOThread 快路径却可能在 BQL 外；普通 ref 原子地维护计数，不保护实例中的多个字段。执行上下文、锁和 RCU 要与 Object 生命周期一起审查，第六章会把这些边连接到 accelerator。

## 设计一个新类型前先问消费者

新抽象类型应当确实有多个实现共享布局和方法，并把未完成行为标成 abstract；只有一处调用的 helper 未必需要进入继承树。新接口适合横跨不同继承分支的无状态能力，接口 class 不应保存实例队列长度或当前错误。新 property 要有明确的用户或管理消费者，并写清可写阶段和兼容期限。

接着写失败图。第几个 child 创建失败，已建立的 link、MemoryRegion、timer 和引用如何逆序撤销；后端断开时对象是否仍可查询；重复 reset、unrealize 是否安全。把这些问题放进 patch cover letter，reviewer能从生命周期检查 API 选择，而不用等一次随机退出崩溃来暴露所有权。

最后再决定公开程度。纯内部字段可以随重构改变，QOM property 与类型名可能被命令行和 QMP 使用，canonical path 也可能进入管理脚本。统一机制提高发现性，同时扩大稳定表面。项目愿意长期维护的内容才应进入公开 Object 接口。

## QOM 付出的代价

运行时类型把部分错误从编译期移到启动期，宏和转换函数增加阅读门槛，class/instance/child/bus 名称接近，引用环还会让 finalize 永远不发生。对象与属性一旦对管理面公开，重命名和删除也要遵守兼容流程。QOM 的收益来自统一装配和生命周期，使用范围越宽，纪律要求越高。

因此，数据面热路径通常不会为每次访存做一次 QOM 属性查找。对象在初始化阶段找到 class、设置回调和连接，运行时使用已保存的类型化指针、函数表与专用结构。QOM 适合控制面和生命周期，不负责把所有 C 访问改成动态消息发送。

本章也到此停止。QOM 能说明对象怎样存在、配置和离开，不能说明客户机地址如何落到设备，也不会自动保存迁移状态。下一章的 MemoryRegion 图和后续 VMState 会继续补上这些关系。

## 实验：让运行时树与生命周期对得上

::: {.hands-on}
先运行 [Inspect QOM tree](../experiments/part-01-system-foundations/chapter-04-qom-object-model/inspect-qom-tree/README.md)，在 RISC-V `virt` 中选择 Machine、一个 hart array、一个 `RISCVCPU` 和一个中断控制器。每个实例记录 TypeInfo 父类、QOM parent、对象路径、qdev bus、关键属性与 realize 回调。两棵树无法回答的内容回到固定 tag 源码，不按缩进猜关系。

随后按 [Create a minimal QOM type](../experiments/part-01-system-foundations/chapter-04-qom-object-model/create-minimal-qom-type/README.md) 在一次性 QEMU worktree 运行现有 fixture。先验证正常构造和 finalize，再故意保留一份引用，观察 finalize 断言或 trace 怎样变化。实验不需要把示例扩成 MMIO 设备；目标是验证“类型已注册、实例已创建、属性可读、最后引用已释放”四个阶段。
:::

## 小结

QOM 出现，是因为 QEMU 要在运行时组合大量类型，并对配置、失败和离开建立共同约定。Anthony Liguori 的基础 Object、property 下沉和 Andreas Färber 的 CPU class 把 qdev 之外的对象与处理器逐步接入同一框架。当前 RISC-V `virt` 由 Machine 类型、hart 容器和 CPU/设备实例沿这套生命周期装配。

阅读对象代码时，先问类型与 class，再问实例配置和 realize，最后分别画组合所有权、总线/地址连接与异步引用。一个对象能被找到，只说明它已经走过其中一段。下一章将沿 `RISCVCPU` 发出的一次物理访问进入另一张图，看看 QEMU 为什么不能用宿主指针直接代表客户机内存和设备。
