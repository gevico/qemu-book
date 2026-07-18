# QOM 对象模型

QEMU 用 C 组织出一套运行时类型系统，既要承担多态调用，也要承接命令行和 QMP 的对象配置。QOM 的代码不难读，容易混淆的是类型关系、组合关系和设备拓扑经常同时出现。

## 本章目标

- 区分 `Object`、`ObjectClass`、class 初始化和 instance 初始化；
- 理解继承、接口、child、link 与引用计数的不同用途；
- 把 RISC-V CPU 和 machine 的运行时对象映射回类型注册代码。

## 从 TypeInfo 到实例

类型注册先描述父类型、class 大小、instance 大小和初始化回调。class 数据由同类实例共享，instance 数据随对象分配。对象创建之后还会经历属性设置和 realize，直到依赖完整才进入运行状态。

:::: {.quick-quiz}
class 初始化为什么不能依赖某个具体实例？

::: {.quick-answer}
class 通常在首个实例创建前完成，并由该类型的所有实例共享。它只能依赖类型、父类和全局类型信息；如果读取某个实例，其他实例会看到不确定或错误的共享状态。
:::
::::

## 类型关系与对象关系

继承解决布局和虚函数复用，接口描述可由不同类型实现的能力。child 表达组合和生命周期，link 表达对象之间的关联，总线拓扑又描述设备如何连接。三者不是同一棵树。

:::: {.quick-quiz}
为什么 QOM 接口通常不保存实例状态？

::: {.quick-answer}
接口 class 是共享的能力契约，具体状态属于实现接口的对象实例。把状态留在对象中，生命周期和所有权仍由对象负责，也避免为接口额外创造一套实例管理规则。
:::
::::

## 属性是控制面接口

属性把字符串、QMP visitor 和 C 字段连接起来。静态属性适合类型声明时确定，动态属性可以在实例初始化期间添加，link 属性保存对象关联。结构性属性一旦参与 realize，通常就不能再自由修改。

:::: {.quick-quiz}
composition child 和 link 的所有权语义有什么不同？

::: {.quick-answer}
child 表达组合和强所有权，父对象决定子对象生命周期，并为它提供 canonical path。link 表达关联或引用，通常不转移目标对象所有权，也不把目标纳入当前组合子树。
:::
::::

## 用 RISC-V CPU 观察 QOM

`RISCVCPU` 继承通用 CPU 对象，具体 CPU model 再通过类型和属性选择扩展、特权版本与缺省配置。machine 保存 CPU 类型名，hart 容器负责按拓扑创建实例，这条路径能同时看到继承、组合和用户配置。

::: {.source-path}
结合 [`qom/object.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/qom/object.c)、`target/riscv/cpu.c`、`target/riscv/cpu-qom.h` 和 `hw/riscv/riscv_hart.c` 阅读。历史证据关注类型注册、属性冻结和声明宏为什么被重构。
:::

::: {.hands-on}
实验目录与验收项见英文手册 [Inspect QOM tree](../experiments/part-01-system-foundations/chapter-04-qom-object-model/inspect-qom-tree/README.md)。启动 RISC-V `virt` 后导出 QOM tree 与 qtree，中文报告选择 `RISCVCPU`、hart 容器和一个中断控制器，分别标出父类型、QOM owner、父总线、属性来源与 realize 回调。无法从运行时查询直接证明的关系，回到固定 tag 源码核对，并注明是静态事实。
:::

## 为什么一个 C 工程需要运行时对象系统

QEMU 编译时无法知道用户最终会选择哪台 Machine、哪颗 CPU、哪些设备和后端。命令行用字符串命名类型，模块可能按构建配置注册，QMP 又需要在运行时枚举对象和属性。普通 C 结构体嵌入可以表达一部分继承，却不能单独完成名称查找、动态构造、接口查询、属性访问和统一生命周期。固定版本的 [`QOM` 文档](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/devel/qom.rst) 与当前 `object.c` 共同定义这套约定，让各子系统不必各写一份类型注册表。

运行时类型也服务跨体系结构复用。通用 `CPUState` 定义调度、breakpoint、运行状态等公共能力，`RISCVCPU` 增加 RISC-V 环境与扩展，具体 CPU model 再设置默认属性。Machine、设备、总线和后端也沿各自父类扩展。调用者可以持有公共父类型，在需要架构特性时做受检查的转换，不必把所有目标代码编进一个巨型联合体。

这套灵活性有成本。类型错误可能从编译期推迟到运行期，class 与 instance 容易混淆，引用和组合关系需要纪律，属性字符串还可能把错误带到 realize。QOM 并不尝试把 C 变成另一门语言，它只为 QEMU 的动态装配提供统一底座。阅读时始终落回结构体、函数指针和引用计数，抽象就不会显得神秘。

## `TypeInfo` 描述的是类型，不是对象

类型通常通过 `TypeInfo` 提供名称、父类型、instance/class 大小、初始化和清理回调，也可以声明接口。`type_register_static()` 或相关宏把描述注册进全局类型表。注册动作并不会立刻分配一颗 RISC-V CPU，它只是告诉 QOM：以后有人按这个名字创建对象时，应使用什么布局和回调。

当前 [`qom/object.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/qom/object.c) 中可以看到 `type_table`、`type_new()`、`type_register_internal()`、`type_register_static()` 与 `type_initialize()` 等符号。`type_initialize()` 会确保父类型先准备好，建立 class 对象，继承父类内容，再执行当前类型的 class 初始化。初始化可以按需发生，因此“注册顺序”与“class 初始化顺序”也不能简单等同。

类型名是全局身份，父类型决定结构布局前缀与基本转换。子类 instance 大小必须容纳父类部分，class 大小也要满足继承链。QOM 宏把常见声明、转换和注册样板生成出来，但宏没有改变内存布局；遇到类型转换问题，展开到 `Object`/`ObjectClass` 头部和 TypeInfo 才是最终依据。

:::: {.quick-quiz}
某个类型的 TypeInfo 已经注册，能否在 QOM tree 中找到对应节点？

::: {.quick-answer}
不能据此保证。类型表保存“可以创建什么”，QOM tree 展示“本次进程实际创建并接入组合树的对象”。一个已注册设备可能从未实例化，一个对象也可能已创建但尚未成为某个父对象的 child，需要分别查询类型和实例。
:::
::::

## Class 是每种类型共享的一组行为

每个已初始化类型通常拥有一份 class 对象，同类型实例共享它。父 class 中的虚函数指针先被继承，子类型的 class_init 可以覆盖，实现类似 C++ 虚函数的分派。`MachineClass` 的 `init`、`DeviceClass` 的 `realize`、`CPUClass` 的 reset 或执行辅助，都以这种方式让公共框架调用具体实现。

class_init 不能依赖某个具体实例，也不应保存“这次虚拟机有几颗 CPU”之类状态，因为所有实例会共享。它适合设置默认方法、类型级元数据和属性描述。实例相关配置放进 instance 结构，用户属性在创建后写入，realize 再根据本次值建立资源。

父类与子类协作时，子类可能保存父实现函数指针，在覆盖方法里先后调用；也可能完全替换某项行为。审查要确认父方法的前置条件和清理是否仍满足。只看到 `dc->realize = foo_realize` 不能断言父类工作自动执行，QOM 不会替开发者猜测组合顺序。

class 数据虽然共享，也不等于永不改变。QOM 初始化阶段可以设置它，某些兼容机制还会影响类型或属性默认；运行期随意改虚函数则会同时影响所有实例，通常属于危险设计。把可配置行为做成 instance 属性或明确 strategy 对象，更容易推理和迁移。

## Instance 初始化只建立不会失败的局部基础

`object_new()` 按类型分配并初始化对象。QOM 会沿继承链执行 instance_init，让父类部分先建立，再由子类准备自己的字段；后续 post-init 可在整条实例链完成后工作。这个阶段适合初始化列表、锁、默认值和不依赖外部资源的子对象，不适合打开文件、占用总线地址或做可能失败的宿主操作。

原因来自错误契约。instance_init 没有普通 `Error **` 返回通道，对象分配框架假定它能够建立一个可安全 finalize 的实例。若一个设备可能因为后端缺失或属性非法而失败，应把检查放到 qdev realize。这样调用者能收到结构化错误，并对已创建对象执行一致回滚。

初始化与 realize 分开还允许先设置属性。用户创建对象后，Machine 或命令行把 `cpu-type`、地址、后端 link 等写入，所有依赖就绪后才 realize。若 instance_init 已按默认值分配了不可调整资源，属性机制只剩表面配置，修改时要拆掉半个对象；这正是阶段边界要避免的情况。

finalize 顺序与继承相反地释放各层资源，前提是每层只清理自己建立的内容，并能处理部分初始化。外部回调若还持有引用，单纯进入 finalize 就太晚；unparent、unrealize、取消事件和引用计数需要在此之前确保对象不再被使用。

## 强制转换其实是运行时类型检查

QOM 常见的 `RISCV_CPU(obj)`、`OBJECT(obj)` 和 `DEVICE(obj)` 宏最终围绕对象头和类型信息工作。向父类型转换在布局上通常只是同一地址，向具体子类型转换则要确认实际类型兼容。调试构建中的动态检查能较早发现错误，优化构建也依赖程序遵守同一约定。

转换成功只证明类型关系，不证明生命周期、realize 状态或线程归属。一个 `DeviceState *` 可以确实指向 UART，却尚未 realize；也可能类型正确但对象已经被另一线程 unparent，调用者没有引用。把“类型安全”扩展成“什么都安全”，会忽略 QOM 最难的部分。

接口转换又不同于继承转换。对象可实现一个或多个无状态接口，查询后得到相应 interface class 行为，具体实例状态仍位于原对象。接口适合表达“可以 reset”“可热插拔”等横向能力，避免为了复用一组方法强行改变单继承树。

## 接口提供横向能力，不建立第二份实例

QOM 类型只有一条父类型继承链，接口可以由不同分支实现。接口 class 保存方法契约，不另有与对象并行的实例状态。实现方法接收原对象或可回到原对象，状态生命周期继续由那个对象负责。这种设计让多个设备共享能力，又不引入多重继承布局的复杂度。

接口声明并不表示每个方法都有同样默认行为。调用者要确认接口存在，具体实现要满足文档的线程、错误和生命周期约定。一个空实现若只为通过类型检查，可能让管理层误判能力。上游 review 通常会追问接口到底代表可调用能力，还是仅用来分类。

RISC-V Machine 类型也可通过接口声明目标架构等信息，设备则使用 reset、hotplug 等公共能力。阅读 TypeInfo 的 `.interfaces` 时，应沿接口定义看方法与调用者，不能只在注册数组旁写一句“实现了接口”就结束。

## 属性把文本控制面接到类型化状态

QOM 属性由名称、类型、getter、setter 与可选 release 等信息组成，Visitor 负责在 QAPI、字符串或其他表示与 C 值之间转换。命令行 `-object`、Machine 属性、QMP 查询最终都能经过统一属性接口。统一不意味着所有属性都能在任意时间读写，setter 仍需检查对象状态和约束。

属性大致有三种来源。父类可注册所有子类共享的属性，具体 class 可增加类型级属性，instance_init 也能按对象条件添加动态属性。默认值可能来自字段初始化、class 约定或 Machine 兼容属性。分析一个属性时，先用名称搜索注册点，再找 setter 实际写了什么，以及 realize 在哪里消费。

结构性属性通常在 realize 前冻结。CPU 扩展会影响寄存器与执行后端，hart 数影响对象数组和设备树，MemoryRegion 大小影响地址拓扑。运行后若允许改变，就必须有完整的重配置、客户机通知和迁移语义；没有这些机制，setter 应明确拒绝。只把属性标成 writable 而不处理下游，是控制面最常见的设计漏洞。

属性错误要带对象路径和期望类型。用户面对的是 `-machine virt,aia=aplic-imsic` 或 `-device ...`，内部字段名并不够。QOM 提供统一路径与 Error 传播，使错误能从 setter 或 realize 返回到命令行/QMP。错误信息质量也是对象模型的工程收益。

:::: {.quick-quiz}
一个属性 setter 能成功把字符串转成整数，是否说明这个值可以在已 realize 设备上修改？

::: {.quick-answer}
不说明。类型转换只验证表示，设备还可能要求范围、组合和生命周期约束。若值影响地址、IRQ、队列或迁移状态，setter 应在 realize 后拒绝，或者实现完整的运行期重配置协议。
:::
::::

## Child、link 与普通引用回答三个不同问题

child 属性把对象放入 QOM 组合树，父对象给子对象提供 canonical path，并承担组合生命周期。Machine 下的 peripheral 容器、设备内部创建的子对象都可借此表达“属于谁”。同一对象不能同时作为两个父对象的组合 child，因为它只有一个规范位置。

link 属性表达对象间关联，例如设备引用一个后端或总线相关对象。link 不把目标搬入当前组合子树，是否持有强引用取决于属性定义和 flags，不能一概写成“link 永远不拥有”。分析时分别记录路径关系、引用计数与业务关联，避免从一条 link 推导生命周期。

普通 `object_ref()`/`object_unref()` 只管理存活，不提供命名和拓扑。异步回调为了让对象活到完成，可以持有引用，却不因此成为对象 child；父对象拥有 child，也不表示任意线程无需同步就能访问。三种关系放在一张表里写明“路径、存活、连接”，比画一棵混合树清楚。

unparent 会从组合树移除对象，并触发相应生命周期；当最后引用消失，finalize 才真正发生。若外部仍有强引用，对象可以离开 QOM tree 后继续存活，此时 canonical path 可能不再可用。调试器只看树找不到对象，不代表内存已释放。

## 对象路径让控制面能够精确指向实例

QOM root 与容器形成规范路径，`object_resolve_path()` 等函数可按绝对或局部路径查找。QMP 查询和属性 link 能借路径定位对象。路径是组合关系的投影，不等于设备在客户机中的地址，也不等于 qdev bus 路径。

模糊解析会在多个同名对象时遇到歧义，因此管理工具最好保存 canonical path。匿名 peripheral 容器解决的是用户设备未显式命名时的拥有位置，不应该被当成稳定业务 ID。需要长期引用的对象应有明确 id 或通过 QAPI 返回的标识，而不是依赖某次创建顺序生成的路径。

路径查找后仍要取得合适引用。解析函数返回的对象若只受树拥有，另一个线程随即热拔除，调用者会拿到悬空指针。许多 QMP handler 在 BQL 下串行，正是把查找和使用放在受保护区；无 BQL 路径则需要专门引用与生命周期协议。

## qdev 在 QOM 之上增加“设备成为机器一部分”的语义

QOM 可以创建普通对象，qdev 的 `DeviceState`/`DeviceClass` 增加 realize、unrealize、reset、总线、GPIO/IRQ 与迁移等设备约定。一个设备对象刚 `object_new()` 时只是可配置实例，属性和后端就绪后调用 `qdev_realize()`，设备才注册 MemoryRegion、连接中断、创建子设备并进入运行拓扑。

realize 可以通过 `Error **` 失败，因此适合检查属性组合、寻找后端和申请外部资源。失败后，对象必须保持可安全清理，不能留下已注册 handler 或半连接 IRQ。实现常按步骤建立，并在错误出口逆序回滚；使用自动清理只能帮助 C 资源，已发布到全局拓扑的状态仍要显式撤销。

unrealize 面向热拔除或销毁，先停止事件和数据面，再断开外部可见资源。它不等于 finalize，设备可能在 unrealize 后仍因引用存活。reset 又是另一种动作：保留对象和连接，只恢复客户机可见状态。把三个回调混在一起，会让运行中 reset 意外释放后端，或热拔除留下 timer。

官方 QOM/qdev 文档强调设备不应被重复 realize，instance_init 也不应把无法失败的构造与 realize 混在一起。当前实现的准确允许状态仍应以 `hw/core/qdev.c` 和 `include/hw/core/qdev-core.h` 为准，正文不靠旧版路径猜测。

## 总线拓扑不是 QOM 组合树

一块 virtio 设备可以在 QOM 树中由 Machine 的 peripheral 容器拥有，同时作为某条系统总线或 PCIe bus 的 qdev child。前者负责对象命名与生命周期，后者表达客户机硬件连接、地址分配和总线规则。两棵树的父节点完全可能不同。

`qtree` 更接近 qdev 总线视图，`qom-tree` 展示组合对象。实验若只导出一份，容易把“对象由谁拥有”误写成“设备插在哪条总线”。PCIe bridge 下的设备尤其能显示差别：QOM owner 可以保持在机器容器，总线父子关系却跨多级 bridge。

IRQ 和 MemoryRegion 又不是总线树本身。设备 realize 时把 MMIO 区域映射到容器，把 irq 输出接到控制器，这些连接构成图。一个设备的完整拓扑至少有类型继承树、QOM 组合树、qdev bus 树、内存区域图和 IRQ 图。需要哪张图取决于问题，合并成“对象树”会失去边的语义。

## 用 RISC-V `virt` 看 Machine 类型与实例

`virt_machine_typeinfo` 声明 RISC-V `virt` Machine 的父类型和 class 初始化，`virt_machine_class_init()` 设置板级入口、默认 CPU、属性与限制。启动选择 `-machine virt` 后，`qemu_create_machine()` 创建本次 `MachineState`，再由 `virt_machine_init()` 读取实例配置装配平台。类型、class、instance 和 realize/board init 在这条路径上都能找到实际位置。

Machine 对象是组合根之一，却不亲自实现每个设备。它创建 hart array、内存与中断控制器，设置 child/link 和 qdev 连接，各设备 class 再执行自己的 realize。平台地址集中于 `virt_memmap[]`，设备寄存器行为留在对应文件。这种分工让 Machine 审查连接，设备审查局部协议。

Machine 属性如 AIA 模式、ACLINT、IOMMU 选择会改变创建分支和设备树。它们必须在 `virt_machine_init()` 消费前确定，运行后不能随意切换。属性 setter、Machine instance 字段和板级条件三处应保持同一枚举语义；增加新值时还要更新帮助、文档与迁移/兼容讨论。

## Hart array 把拓扑配置转换为 CPU 对象

[`hw/riscv/riscv_hart.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/riscv_hart.c) 中的 hart array 是很好的组合案例。`virt` 按 socket 创建容器对象，设置 `num-harts`、`hartid-base` 与 `cpu-type`，realize 时再生成多个 `RISCVCPU`。容器拥有 CPU 实例，Machine 决定容器数量与编号，CPU class 提供架构行为。

这里至少有三种“父”。`RISCVCPU` 的类型父类是 `CPUState` 所在继承链，组合父对象是 hart array，运行时调度还把 CPUState 交给 vCPU 线程。三者回答复用、生命周期和执行上下文，不能交换。实验报告若写“CPU 的父是 hart array”，必须注明这是 QOM child，不是类型继承。

hart array realize 若在第 N 个 CPU 失败，需要清理此前实例；CPU realize 又会与所选 TCG/KVM 后端交互。容器让这组批量生命周期集中管理，也让其他 RISC-V Machine 复用。hart array 并非 ISA 概念，它是 QEMU 为拓扑装配选择的工程抽象。

## `RISCVCPU` 如何承载 ISA 扩展与实现后端

[`target/riscv/cpu.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/cpu.c) 注册基础 CPU 与具体模型，`target/riscv/cpu-qom.h` 提供类型声明。`RISCVCPU` 实例包含架构环境和配置，`RISCVCPUClass` 在通用 `CPUClass` 之上设置 realize、reset、dump 等行为。扩展属性决定 ISA 字符串、CSR 和执行能力，realize 再校验组合并接入加速器。

TCG 与 KVM 都使用 RISC-V CPU 对象，却可能从不同来源确定属性。TCG 软件模型有编译实现的扩展，KVM 要查询宿主内核支持并限制不可实现组合。QOM 属性提供共同控制面，后端 realize 负责给出准确拒绝。共同属性名称不保证两种加速器能力相同，用户仍需读取错误和运行查询。

CPU reset 通过 class 方法恢复 RISC-V 特权状态，Machine 启动路径再安排 PC 与启动参数。CPU 类不应硬编码 `virt` 的 UART 或 DRAM 地址，Machine 也不应直接实现每条 CSR。对象边界与第一章的 ISA/平台边界在这里重合。

:::: {.quick-quiz}
hart array 是 `RISCVCPU` 的组合父对象，能否据此把 hart array 强制转换成 `CPUState`？

::: {.quick-answer}
不能。组合 child 只表示对象拥有关系，不创建类型继承。能否转换由 TypeInfo 父链或接口决定。hart array 可以保存和管理 CPU child，却不是 CPU 子类；应从 child 属性取得具体 CPU 对象后再按其实际类型转换。
:::
::::

## 生命周期与异步回调必须同时成立

第四章不能脱离第三章谈引用。设备 schedule 一个 BH 或 timer 时，回调参数常指向设备实例。unrealize 必须取消事件并等待不再执行，或者回调持有对象引用并能识别设备已停止。只依赖 QOM parent 的强拥有不够，父对象 teardown 可能正是删除发生的原因。

工作线程和协程同样需要明确引用。取得 `object_ref()` 可以延长存活，却可能让对象离开机器后继续存在；回调不能再假定总线、MemoryRegion 或后端仍连接。常见做法把“存活”和“可运行”分成两个状态，unrealize 先切断运行能力，在最后异步完成释放引用后 finalize。

反向引用容易形成环。父拥有 child，child 又以强 link 引用父，最后引用计数无法归零。组合关系通常允许 child 访问父但不额外持有永久强引用，或在 unrealize 显式断开 link。审查对象图时标出强引用方向，能在运行之前发现泄漏。

## 热插拔把对象阶段重新带回运行期

启动时创建对象大多在主线程和 BQL 下，热插拔则发生在运行中的 Machine。QMP 解析新配置，找到 hotplug handler，创建并设置设备，realize 后接入总线、地址和中断，再通知客户机。每一步失败都要恢复已有机器，不能像进程启动失败那样直接退出。

热拔除通常还需要客户机合作。管理端提出请求，设备进入 pending 状态，固件或操作系统确认后才真正 unrealize。QOM 对象可能在等待期间继续出现在树中，属性却显示状态变化。把 QMP 命令返回当成对象已释放，会让管理工具过早复用地址或后端。

RISC-V `virt` 对具体设备的 hotplug 能力受当前实现限制，应逐项查询，不能从 qdev 通用框架推断所有设备都可插拔。正文使用热插拔解释生命周期，不声称当前 `virt` 支持任意 CPU、内存或中断控制器运行期替换。

## Introspection 是运行证据，不是全部真相

`info qom-tree`、`qom-list`、`qom-get` 等接口能观察实例路径和属性，`info qtree` 展示设备与总线。它们非常适合回答本次配置创建了什么，却不会直接显示所有 C 引用、线程所有权或未暴露属性。一个对象不在 QOM tree 中，也可能由内部引用暂存；一个 class 方法更不会因为查询树而显示调用来源。

运行时结果应与源码注册点配对。先从路径和 type 名找到实际对象，再到 TypeInfo、class_init、instance_init、属性与 realize；反向则从源码推测路径，再由本次运行确认条件分支。两种方向互相校验，可以避免把“代码可能创建”误写成“此次已经创建”。

QOM trace 进一步展示对象分配、finalize、属性和 child 增删。当前历史中的提交 [`e89cff07a902`](https://gitlab.com/qemu-project/qemu/-/commit/e89cff07a902) 增加相关生命周期 trace。使用时要控制输出并保存对象身份，地址复用会让不同实例看似同一个指针；配合类型名、路径与创建序号更可靠。

## 从 QOM 初始提交看设计取向

2011 年提交 [`2f28d2ff9dce3c404b36e90e64541a4d48daf0ca`](https://gitlab.com/qemu-project/qemu/-/commit/2f28d2ff9dce3c404b36e90e64541a4d48daf0ca) 引入基础 Object class，提交说明明确提到受 GObject 启发，并记录从前一版 review 吸收的哈希表、父类型缓存与接口可见性等调整。[同一系列的审查线程](https://lists.nongnu.org/archive/html/qemu-devel/2012-01/msg03649.html)还追问，把头文件移到 `include/` 是否会被理解成对外部程序承诺稳定 API；讨论最后收敛到“供 QEMU 内部其他子系统共享”的边界。前一项是提交记录的实现变化，后一项是邮件中的接口范围讨论。由此可以判断，目录可见性服务于树内复用，但不能据此把 QOM 声明成独立、稳定的外部 SDK。

2012 年提交 [`57c9fafe0f759`](https://gitlab.com/qemu-project/qemu/-/commit/57c9fafe0f759) 把属性能力从 qdev 移到 Object，使非设备对象也能使用统一属性。当前 Machine、内存后端以及其余 object 的配置都能从这条演进理解。上游陈述能支持“属性需要服务 qdev 之外的对象”，不能直接支持今天每个属性设计都合理；具体属性仍要逐项审查。

类型注册、声明宏和目录此后继续重构，当前 `object.c` 已与早期代码差异很大。研究某个宏时，可先从当前展开与 TypeInfo 找语义，再用 Git 历史解释为何减少样板或增强类型检查。若旧邮件使用 `TypeImpl`、qdev property 等术语，需映射到当前结构，不能机械照搬 API。

::: {.design-note}
已核对事实：QOM 基础提交说明引用 GObject 作为灵感，属性随后从 qdev 下沉到 Object；当前 RISC-V CPU、Machine 和 hart array 都注册为 QOM 类型。作者推断，这种统一底座让动态配置和 introspection 能跨设备与非设备对象复用，同时把运行期错误和生命周期复杂度集中到一套规则。它是收益与成本的判断，不是上游承诺 QOM 会消除所有样板。
:::

## 实验二：实现一个最小 QOM 类型

::: {.hands-on}
按照英文手册 [Create a minimal QOM type](../experiments/part-01-system-foundations/chapter-04-qom-object-model/create-minimal-qom-type/README.md) 检查仓库中已经提交的最小类型、Meson 接入片段与源码校验脚本。正文用中文解释 TypeInfo、父类型、class_init、instance_init、一个可读写属性与 finalize；接入固定 QEMU 树后创建两个实例，验证 class 数据共享而 instance 字段独立。若只执行静态校验，应把结论限定在 API 形态，不能冒充运行时创建已经完成。

第二步给其中一个实例添加 child 或 link，观察 canonical path、引用计数和 unparent 后的变化；再故意在 realize 检查一个非法属性，让错误通过 `Error **` 返回。不要在 instance_init 主动制造不可恢复失败，实验目标正是比较两个阶段。最后用 trace 或最小日志记录创建、属性设置、realize、unrealize、unparent 与 finalize 的顺序。
:::

若要让实验更贴近主线，可以让类型成为简单的 RISC-V 教学设备，但不要在本章实现完整 MMIO。这里只验证对象机制，地址映射留到第五章。一个实验同时引入 QOM、MemoryRegion、IRQ 和迁移，任何失败都会让生命周期结论含糊。

## 动态思考题

:::: {.quick-quiz}
两个同类型设备的 class 指针相同，其中一个实例修改自己的寄存器字段，另一个实例会同步变化吗？

::: {.quick-answer}
不会，只要寄存器正确放在 instance 结构中。class 指针共享的是类型级方法和元数据，实例字段各自分配。若把可变寄存器误放进 class，才会让所有实例互相污染，这正是 class_init 不能依赖具体实例的原因。
:::
::::

:::: {.quick-quiz}
对象已经从 QOM tree unparent，是否可以立即释放所有回调使用的数据？

::: {.quick-answer}
不能仅凭 unparent 判断。对象可能还有强引用，已排队的 BH、timer、协程或工作线程也可能持有参数。应先按设备协议 unrealize、取消并收束异步工作，再断开组合关系，最后引用归零才进入 finalize。
:::
::::

:::: {.quick-quiz}
为什么 qtree 中的父设备和 qom-tree 中的父对象可能不同？

::: {.quick-answer}
qtree 表达 qdev 总线连接，qom-tree 表达组合所有权与路径。设备可以由 Machine 的 peripheral 容器拥有，同时插在 PCIe bridge 下的总线上。两种父关系服务不同问题，没有必要重合。
:::
::::

:::: {.quick-quiz}
一个接口由多种设备实现，接口 class 能否保存“当前设备的队列长度”？

::: {.quick-answer}
不能把实例状态放在共享接口 class。队列长度属于具体对象实例，接口方法可接收对象并读取其字段。否则同类或不同实现实例会共享错误状态，生命周期也没有清楚归属。
:::
::::

## 抽象类型负责共享骨架，具体类型承担可创建承诺

有些 QOM 类型只为了组织共同字段和虚函数，不应由用户直接实例化。把它标成 abstract，可以让子类继承骨架，同时在 `object_new()` 时拒绝没有完整行为的基类。`CPU`、某类总线或设备家族经常需要这种层次，否则用户可能创建一个类型检查通过、却没有 realize 实现或客户机语义的对象。

抽象不等于没有 class。抽象类型仍需初始化 class，给子类提供默认方法和属性，也能参与类型转换。它只禁止直接构造实例。审查新基类时应问：是否真的存在有意义的独立对象；若所有使用点都要求子类覆盖关键方法，就应考虑 abstract，尽早把错误从运行期设备访问推到创建阶段。

具体类型则作出更强承诺：在满足属性和后端条件时，它能够创建、realize 并按接口工作。某个具体 CPU model 可以因 KVM 能力不足拒绝 realize，却不应因为 class 忘了填必要方法而在第一条指令崩溃。abstract 标记与 realize 校验分别覆盖“实现是否完整”和“本次环境是否允许”。

## 类型初始化需要处理继承链与并发首次使用

类型可能在模块初始化时注册，class 则在首次查询或创建时按需初始化。`type_initialize()` 先确保父类就绪，再分配当前 class、复制可继承部分、建立接口并调用 base/class 初始化。按需方式避免为永不使用的类型完成全部工作，也要求全局类型系统对首次访问有明确串行化。

父到子的初始化顺序允许子 class 读取并覆盖父方法，instance 的父到子初始化则让子字段建立在完整父对象上。清理通常反向展开，让子层先释放自己对父资源的依赖。任何一层越权释放父类拥有的字段，都会在另一个子类或部分失败路径中出现双重释放。

class_base_init 与 class_init 的差别在复杂继承层次中很重要：前者可针对从父 class 复制出的部分逐级调整，后者属于声明该类型的初始化。普通设备很少需要手写全部细节，但阅读公共基类时不能把所有 class 回调当作同一时点。若结论依赖精确顺序，应直接核对当前 `object.c`，并用最小类型 trace 验证。

## 声明宏减少样板，也可能遮住真实注册

QEMU 使用 `OBJECT_DECLARE_*`、`DEFINE_TYPES` 等宏生成类型声明、转换辅助与注册函数。宏让命名一致，降低手写 size 和 cast 的错误，代码搜索却容易停在展开前。看到 `DEFINE_TYPES(foo_types)` 时，要继续找数组中的 TypeInfo；看到 `RISCV_CPU()` 时，要知道它仍是从 Object 做受检查转换。

宏会随项目重构。旧邮件可能使用 `OBJECT_CHECK` 与手写 `type_init()`，当前源码已换成更强的声明宏。研究设计动机时，先区分机械迁移和语义变化：若 TypeInfo 名称、父类与回调都没变，客户机行为通常不变；若宏同时引入自动 class size 或接口声明，就要检查类型布局。

书中引用符号而不大量展开宏，是为了保持可读性；实验遇到编译错误时则应查看预处理结果和宏定义。尤其是 C 的 container cast，一处类型名拼错可能只在运行检查触发。理解宏背后的 `Object` 前缀布局，才能判断错误来自声明、注册还是实例实际类型。

## 全局属性与兼容属性在实例创建前施加策略

QEMU 可以按类型/属性应用 global property，Machine 兼容机制也会为某些设备设置旧行为。这类策略不需要每个板级调用者逐项写 setter，却增加了属性来源。最终字段值可能来自 class 默认、instance 默认、Machine compat、全局选项和用户显式配置，优先顺序必须由框架规则决定。

追踪属性时只找最近的 `object_property_set_*()` 很可能漏掉全局覆盖。应先查看命令行是否有 `-global` 或 Machine 兼容表，再看设备创建过程中何时应用。调试输出最好同时显示“当前值”和“用户是否显式设置”，因为默认值变化与用户选择在兼容性上意义不同。

RISC-V `virt` 当前没有一串公开版本 Machine，仍会使用通用属性和兼容框架的部分能力。不能由此假定每个设备默认可随版本改变。新增 CPU 扩展、IOMMU 或中断模式时，维护者仍要决定默认、显式 opt-in 与迁移影响，并在当前 Machine 属性中表达。

## Realize 的依赖顺序是一张有向图

设备 A 若在 realize 中取得设备 B 的 link、把 MemoryRegion 映到 Machine 容器、连接 IRQ 并注册 VMState，那么 B、容器和迁移框架的相关基础必须先可用。父设备创建 child 后，也常先设置 child 属性再 realize。这个顺序由依赖图决定，不该靠碰巧的源码排列。

循环依赖是危险信号。A realize 等 B 已实现，B realize 又要求 A 的运行状态，两者无法找到合法起点。可以把共享资源提升到父容器，分出“创建/连接/启动”阶段，或用明确 link 在双方都创建后统一 realize。延迟到首个 I/O 才偷偷补连接，只会让错误更难报告。

错误回滚按依赖图逆序进行。已添加 MemoryRegion 就先撤映射，已注册 handler 就注销，已取得对象引用就 unref，最后释放本地缓冲。若某一步由 child 所有，父不应重复清理。最小 QOM 实验可以故意让中间检查失败，用 trace 观察是否还留下对象路径或引用。

## Reset 是对象关系上的传播，不是重新构造

系统 reset 需要遍历 CPU 与设备，让客户机可见状态回到规范值，同时保留命令行配置、对象连接和宿主后端。QEMU 的 reset 框架支持分阶段或接口化回调，父设备与 child 要遵守传播顺序。设备若在 reset 中重新创建 child，会改变路径和引用，通常说明把配置与运行状态混在了一起。

复位值可能依赖只读属性。例如 UART 时钟频率由板级配置，reset 清空 FIFO，却不应把频率改回某个硬编码默认。CPU reset 清特权状态，Machine 启动代码再安排 reset vector。把所有字段 `memset(0)` 既可能破坏锁和引用，也可能违反寄存器非零复位值。

异步工作让 reset 更复杂。timer、BH 和线程池请求可能引用设备，reset 需要取消或标记 generation；完成回调看到旧 generation 时丢弃或按协议收尾。对象仍然同一个，引用计数无法区分 reset 前后两代请求，所以运行状态需要额外序号或 drain。

## 迁移字段不等于 QOM 属性

QOM 属性面向配置与管理，VMState 面向运行状态迁移，两者可能引用同一字段，却有不同稳定性。一个用户可写属性不一定需要迁移，因为目标命令行已重建配置；一个内部 FIFO 指针没有 QOM 属性，却必须保存，客户机恢复后才能继续。不能遍历属性就自动得到正确迁移流。

类型名和设备路径帮助目标端重建对象，迁移版本、字段条件和 post-load 回调则处理状态演进。class 方法常保存 VMStateDescription 指针，让同类型实例共享格式，实际数据仍取自各 instance。新增字段要考虑旧源到新目标、新源到旧目标和默认恢复，不能只让本版本自迁移通过。

KVM/TCG 共享 CPU 对象时，迁移前还要把执行后端状态同步回可序列化 instance，加载后再推入目标后端。QOM 提供对象身份和方法分派，不自动知道内核寄存器何时最新。迁移边界再次说明“类型正确”与“状态权威”是两回事。

## 普通 Object 让后端不必伪装成设备

内存后端、IOThread、密钥或其他宿主资源可以是 QOM Object，却不必成为客户机 qdev 设备。它们需要名称、属性、生命周期和 QMP 管理，但没有客户机总线、寄存器或 reset 语义。2012 年把属性下沉到 Object，正好支持这种分层。

前端设备通过 link 或属性引用后端，realize 时检查类型与能力。一个块后端可在设备之前创建，也可被管理面单独查询；设备热拔除后，后端是否保留由引用与配置决定。前后端分离允许多个设备模型复用 I/O 实现，也让数据面迁移到 IOThread，而不把宿主线程暴露成客户机硬件。

分离仍要约束共享。两个前端同时引用不允许共享的后端，应该在 realize 报错；后端关闭时要等在途请求；属性 link 变更要有状态限制。QOM 提供表达关系的工具，业务规则仍由具体 class 实现。

## QOM 错误常落在四类边界

第一类是类型边界：错误 cast、父类大小不匹配、接口声明与实现不一致。第二类是阶段边界：instance_init 做可能失败工作、realize 后修改结构属性、finalize 才取消回调。第三类是所有权边界：child/link/ref 混淆、引用环、unparent 后悬空访问。第四类是拓扑边界：把 QOM parent 当成总线父，把对象路径当成客户机地址。

诊断时按四类分类，比从崩溃点直接补 ref 更可靠。类型错误查看 TypeInfo 和实际 type；阶段错误记录创建到清理时间线；所有权错误画强引用图；拓扑错误并排导出 qom-tree、qtree、mtree 与 IRQ。一个 bug 可能跨两类，例如热拔除时 qtree 已断开，排队 BH 仍因引用存活访问已经撤销的 MemoryRegion。

修复也要选择正确层。若多个设备都需要相同生命周期约束，可以放进 qdev 公共框架；若只是一项设备后端规则，留在具体 realize；若对象关系无法表达所有权，先改 child/link，而不是用全局表延长所有对象寿命。最小 diff 的标准是解决根边界，不是改动行数最少。

## 如何为 QOM 代码设计测试

类型测试先验证注册、父类和接口查询，实例测试验证默认值与两个实例隔离，属性测试覆盖类型、范围、只读和 realize 后写入，生命周期测试覆盖成功、各阶段失败、unparent 与最后 unref。设备再增加 realize/unrealize/reset、总线和迁移。把这些场景拆开，失败时才知道哪条契约破了。

错误注入很有价值。让后端打开失败、child 第 N 次创建失败或属性组合非法，检查 QOM tree、handler 和引用是否回到起点。只测试最后一个成功对象，无法发现批量 hart 创建中前几个实例泄漏。AddressSanitizer 与对象 trace 可配合使用，前者发现释放错误，后者解释路径。

运行时 introspection 也可成为测试接口，但不要匹配易变的匿名路径或完整树顺序。测试应关注稳定 type、属性与必须的组合关系。内部重构若不改契约，应允许路径局部调整；管理 API 若公开承诺路径，则需要更严格兼容，这要由文档明确。

## 研究一项 QOM 演进的证据顺序

先在当前 tag 找 TypeInfo、class_init、instance_init、属性和 realize，再运行最小配置确认实例确实出现。随后用 `git log -S'TYPE_NAME'` 找引入与改名，用 `git log -G'property_name'` 找属性语义变化。若代码经过机械宏转换，跳过该提交继续向前，直到找到行为变化。

合入提交带 Message-ID 时回到 qemu-devel 系列，关注 review 对错误处理、热插拔、迁移和命名的质疑。没有邮件链接时，提交说明仍是上游一手材料，但不要推断未写出的动机。早期 QOM 提交可以解释框架目标，不能代替 2026 年 RISC-V CPU 属性的具体审查。

最后把解释写成三列：当前事实、上游明确理由、作者综合判断。比如“属性从 qdev 下沉到 Object”是提交事实，“让 Object 在 qdev 外有用”来自提交说明，“因此后端可以共享统一控制面”是结合当前使用作出的解释。列清来源，文字反而可以写得轻快，不必在每句后堆满防御性限定。

## 沿 `object_new()` 走一遍当前实现

在 `v11.1.0-rc0` 的 `qom/object.c` 中，从 `object_new()` 可以进入按类型分配和 `object_initialize_with_type()` 一类路径。类型若尚未初始化，先完成 class；对象内存清零并建立 `Object` 基础字段后，沿父到子调用 instance 初始化，最后完成 post-init。调用者拿到的对象已经具备类型和局部默认，却未必已设置用户属性，更不表示 qdev realize。

对象接入组合树时，`object_property_add_child()` 等路径建立 child 属性和 parent 关系；属性 get/set 通过 Visitor 与具体回调访问；路径解析函数从 root 或指定对象遍历 child/link。`object_unparent()` 撤掉组合关系，`object_unref()` 在最后引用消失时进入 deinit/finalize。把这些符号串在一起，可以用普通 C 生命周期理解 QOM，不必依靠抽象比喻。

调试时在分配、child add、realize、unparent 和 finalize 五处设置断点，通常已经足够。若 finalize 未出现，查看剩余引用；若对象从未进入树，查看 child 添加；若属性值正确而设备没有资源，查看 realize 是否调用。五个点比在每个宏上单步更有效，也能与当前新增的 QOM trace 相互核对。

## 一次 RISC-V CPU 属性审查应问什么

假设要给 `RISCVCPU` 增加一个扩展开关。首先确认它属于 ISA 能力还是 `virt` 平台属性，决定注册在 CPU 还是 Machine；再确认 TCG 是否实现、KVM 如何探测，默认值是否随具体 CPU model 变化。属性名、帮助文本和设备树 ISA 描述要保持一致，非法扩展组合应在 realize 期间给出清楚错误。

随后检查生命周期与兼容。属性是否只能在 realize 前写，reset 是否保留配置，迁移是否需要保存相关 CSR，目标端缺少能力时怎样拒绝。多 hart 是否要求所有 CPU 一致，hart array 是复制 CPU 类型名还是逐实例设置。若扩展影响中断或内存平台，还要让 Machine 明确连接，不能从 CPU 对象偷偷创建板级设备。

最后看历史证据。找到扩展规范、QEMU TCG/KVM 实现系列和 qemu-devel review，区分规范要求与 QEMU 默认策略。运行实验分别查询 type 属性、创建两个实例、尝试非法组合，再在 TCG 与可用 KVM 上对照。到这一步，一个看似简单的布尔属性才真正落入对象模型，而不是在结构体中多了一个字段。

## 反过来设计：哪些东西不该成为属性

如果一个值只在函数内部临时计算，没有用户配置、管理查询或对象组合需求，把它暴露成 QOM 属性会扩大兼容表面。若一个动作具有副作用和异步完成，例如“开始迁移”或“弹出介质”，用 QAPI 命令和状态机往往比写一个布尔属性清楚。属性适合描述对象状态与配置，不适合把所有方法伪装成赋值。

高频数据面计数也未必适合通用 property getter。读取需要跨 IOThread 或暂停 vCPU时，getter 的同步成本和一致性要明确；专用 QAPI 查询可以返回快照语义与错误。把内部指针暴露为 link 更危险，用户可能建立框架未准备处理的引用环。

决定“不做属性”同样是工程设计。统一机制带来发现性和工具复用，过度统一则让生命周期与兼容变模糊。审查时先写消费者、读写阶段和稳定性，再选择 QOM property、QAPI 命令、设备寄存器或纯内部字段，避免从手边最熟悉的 API 倒推需求。

:::: {.quick-quiz}
一个耗时数秒且可能失败的设备操作，是否适合通过普通 property setter 同步完成？

::: {.quick-answer}
通常不合适。setter 适合受约束的状态写入，长操作需要取消、进度、异步完成与错误状态，专用 QAPI 命令或 job 更清楚。若属性只记录目标配置，也应把实际执行放到明确生命周期阶段，而不是让一次 get/set 隐藏阻塞。
:::
::::

## 小结

QOM 让类型分派、配置和生命周期遵循一套运行时约定。阅读时先分清正在处理的是共享 class、独立实例、组合所有权，还是设备连接关系。

对 RISC-V `virt` 而言，Machine 类型提供板级策略，Machine 实例保存本次配置，hart array 把拓扑变成若干 CPU child，`RISCVCPU` class 提供架构行为，TCG/KVM realize 再校验执行能力。UART、中断控制器和其他设备沿 qdev 规则进入总线、内存与 IRQ 图。它们都借 QOM 组织，却没有因此变成同一种对象职责。

排查时可以依次回答六个问题：类型在哪里注册，class 共享哪些方法，instance 初始化了哪些局部字段，哪些属性在 realize 前写入，realize 发布了哪些外部资源，最后一个引用在什么条件下消失。再另画 child/link/ref、qdev bus 和执行线程，避免一条“父子关系”承担所有含义。

两个实验留下的 QOM tree、qtree 和生命周期 trace，将在第五章加入 mtree。届时一个设备会同时拥有类型身份、对象路径、总线位置和 MemoryRegion；CPU 也会从 `RISCVCPU` 实例发出访问，进入与对象树完全不同的地址分派。QOM 负责让参与者存在并可配置，内存 API 负责决定某个客户机地址最终由谁响应。

如果新增类型或属性，先用失败路径检验设计：非法配置能否在 realize 清楚返回，前几个已建 child 能否回滚，排队回调是否在 unrealize 收束，最后 unref 是否真的 finalize。成功创建只覆盖对象生命的一半，安全离开机器才完成另一半。

还要保留一项克制：对象模型能表达某种关系，不代表就应该公开它。稳定的属性和路径会成为管理接口，强引用会改变释放时机，新增接口会承诺所有实现遵守同一能力。先确定真正的消费者和生命周期，再决定是否进入 QOM，往往比事后收回一个已经可见的接口便宜得多。当前代码、运行时树和历史 review 三者共同约束这项判断，任何单独一项都不够完整。

实验笔记中建议给每个对象保留一行“类型、组合父、总线父、强引用、事件域”。五项并排后，许多名字相近的关系会立刻分开，也方便在热拔除或失败回滚时逐项核对谁先断开、谁最后释放。

若某一格暂时无法回答，不要用“框架管理”带过。回到 `object.c`、`qdev.c`、具体 TypeInfo 与运行 trace，找到实际的 ref、child 添加和回调注册；仍缺上游理由时，保留为作者待验证项。对象模型最怕含糊的所有权，写作也一样，明确未知比给一个错误父节点更容易在下一轮研究中修正。

章末可以任选一个没有客户机寄存器的后端 Object，与一个 qdev 设备并排比较。两者都能有类型、属性和引用，只有设备需要总线、realize/reset 与迁移协议。这个对照能检验读者是否真正理解 QOM 是公共底座，而不是把所有 Object 都当成虚拟硬件。

再为一个结构性属性写出状态表：创建后可写，realize 期间被消费，运行中只读，unrealize 后是否允许重新配置。若代码行为和文档状态表不一致，优先修正契约或实现，不要让调用者靠试错发现冻结时点。属性生命周期清楚，错误信息和热插拔设计也会顺下来。
