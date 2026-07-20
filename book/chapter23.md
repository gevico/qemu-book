# 为什么 QEMU 现在引入 Rust

一个 MMIO 回调收到客户机控制的 offset 和 size，从 C 的 `void *opaque` 找回 QOM 对象，修改寄存器，再通过 IRQ 回调进入另一组对象。设备 reset、迁移或热拔插可能同时改变生命周期，另一个 I/O 线程还可能持有后端状态。C 可以把这些事情实现得很可靠，长期成本落在人工维护的约定上：指针何时有效，哪个锁保护字段，回调能否重入，哪些值可以跨迁移保存。

Rust 进入 QEMU 的目标，是把其中一部分约定搬进类型、安全封装和测试。它无法替开发者选择正确的寄存器语义，也不会自动修复 QOM、FFI、BQL、迁移和设备并发。本章从这些边界出发解释 QEMU 为什么在此时接入 Rust，并把一个教学设备放进 RISC-V `virt` 语境。源码锚点固定在 `v11.1.0-rc0`；截至该版本，上游没有 RISC-V Rust 设备，书中的 `riscv-bookdev` 是练习和设计草图。

## 先看 rc0 已经具备什么

固定锚点的 [`meson_options.txt`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/meson_options.txt) 把 `rust` feature 默认设为 `disabled`；[`rust/meson.build`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/rust/meson.build) 又明确 Rust 当前只进入 system emulator。采用者要主动开启、提供 rustc/bindgen 与依赖，未使用 Rust 的构建路径仍需完整工作。

能力面的成熟度并不相同。[`docs/devel/rust.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/devel/rust.rst) 将 `qom`、`system::memory`、`hwcore::qdev`、`hwcore::sysbus`、`bql::cell` 和 `migration::vmstate` 列为 stable；`migration::migratable`、`util::log` 仍是 proof of concept。文档同时提醒，模块状态不是永久 API 承诺，底层 C API 也会变化。描述现状时应逐模块说能力，不能用一个“实验性”标签覆盖整棵 Rust 目录。

当前 workspace 的设备成员只有 [`pl011`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/rust/hw/char/pl011) 与 [`hpet`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/rust/hw/timer/hpet)。文档称它们为相应 C 设备的 functional replacement 和绑定示例，同时注明两者缺 tracing。它们证明 QOM、SysBus、MemoryRegion、timer 与 VMState 能组合使用，不能证明 PCI、DMA、整板或所有后端已经覆盖。`rust/hw/riscv` 在锚点中不存在，后文不会伪造一个“上游案例”。

:::: {.quick-quiz}
为什么“Rust feature 默认关闭”和“若干 Rust 模块已标 stable”可以同时成立？

::: {.quick-answer}
构建开关描述整项能力是否默认进入产品，模块状态描述已实现 API 的局部成熟度。QEMU 可以保留 opt-in 集成，同时让 QOM、SysBus、MemoryRegion 等具体封装达到可用于新设备的稳定程度。
:::
::::

## QEMU 要解决的是跨语言工程边界

设备模型长期接收不可信客户机输入。offset、长度、descriptor、队列索引和时序都可能越界或形成异常组合。安全 Rust 能让数组访问、整数转换和借用经过显式检查，match 也能迫使开发者处理已知寄存器。收益最明显的区域通常是纯状态机和协议解析：它们输入多、分支多，又可以脱离 QEMU 做快速单元测试。

QEMU 还具有动态对象模型。QOM 对象放进 composition tree 后会有多个共享引用，MemoryRegion callback 却从裸指针回到具体设备；普通 `&mut T` 无法随意重建。Rust 接入必须提供符合 QOM 布局与共享语义的类型，并把内部可变性放进能表达 BQL 条件的 cell。若包装层做错，设备代码全部写着 safe 也可能在无效引用上运行。

第三个压力来自生命周期。instance init、properties、realize、reset、migration load、unrealize、finalize 各有允许动作和失败方式。Rust 的 `Drop` 只能帮助释放拥有的局部资源，无法替 QEMU 决定何时停止 timer、断开 IRQ、撤销 MemoryRegion 或等待晚到 callback。接入工作的价值在于把每个阶段需要的契约做成共享 API，而非把 C 函数逐个翻译成 Rust 拼写。

最后还有构建和供应链。QEMU 支持多宿主、多 target、离线发行包和可选功能，新增语言不能让所有构建强制下载 crate。依赖版本、许可证、Meson subproject、最低 rustc、bindgen 与生成顺序都要进入维护范围。这些约束解释了上游为何逐层接入，而没有启动一次全仓重写。

新代码是否选择 Rust，也需要逐项判断。寄存器状态机、解析器和新 SysBus 设备能从安全抽象与独立测试中获益；一段稳定 C 代码若缺少等价 wrapper、迁移兼容又已长期承诺，立刻改写会同时增加语言、行为和审查变量。渐进策略允许新功能先积累接口经验，再由测试决定旧实现是否值得替换。语言选择因此落在维护成本和风险模型上。

这项选择最好形成可复查的决策记录：客户机可控制哪些输入，现有 C 实现发生过什么类型的缺陷，Rust wrapper 是否覆盖所需 QEMU API，谁愿意长期 review，关闭 Rust 的构建是否仍完整，以及迁移流能否保持不变。若主要风险位于尚无安全封装的 DMA 或多线程后端，先补抽象和测试可能比立刻写设备更有价值；若边界已经由 stable 模块覆盖，新设备就能成为检验接口的窄切口。这样，采用 Rust 的理由可以由后续缺陷、审查成本和测试结果检验。

## 渐进接入怎样形成今天的结构

上游先合入构建开关，再加入 bindgen 依赖和初始 interface/bindings，随后才让设备使用。提交 [`764a6ee9`](https://gitlab.com/qemu-project/qemu/-/commit/764a6ee9feb428a9759eaa94673285fad2586f11) 建立 Rust feature，[`6fdc5bc1`](https://gitlab.com/qemu-project/qemu/-/commit/6fdc5bc173188f5e4942616b16d589500b874a15) 处理 bindgen 生成顺序，[`5a5110d290`](https://gitlab.com/qemu-project/qemu/-/commit/5a5110d290c0f2dca3d98c608b0ec9a01d2181b9) 加入初始 bindings/interface。首个设备和迁移能力又由不同提交交付。历史在这里说明一个设计选择：构建、raw FFI、安全封装、设备行为和迁移契约可以分别 review、分别回退。

当前 [`rust/bindings/`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/rust/bindings) 已拆成 `util-sys`、`qom-sys`、`hwcore-sys`、`migration-sys`、`system-sys` 等 crate，依赖方向映射 C 静态库。bindgen 只生成 raw 声明，上层 crate 再提供带类型和锁条件的接口。拆分还能减少某个 C 头文件变化触发的无关重编，并防止各 crate 重复生成互不兼容的同名 Rust 类型。

正式构建由 Meson 直接调用 rustc 生成静态库，再与 C 代码链接。[`rust/Cargo.toml`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/rust/Cargo.toml) 统一 edition 2021、最低 rustc 1.83 和 lint；Cargo 主要用于 rustfmt、clippy、rustdoc 与开发环境。QEMU Rust 测试依赖 C 支持代码，权威入口是 Meson 或 `make check-rust`，普通 `cargo test` 只能验证独立 crate。

## Linux 的经验提供方法参照

Linux 在 2021 年公开了 `[RFC PATCH 00/13] Rust support`（Message-ID [`20210414184604.23473-1-ojeda@kernel.org`](https://lore.kernel.org/lkml/20210414184604.23473-1-ojeda@kernel.org/)），讨论构建、kernel crate、bindings、samples 和 Binder 原型。2022 年进入 v6.1 的 [初始合并提交 `8aebac82`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=8aebac82933ff1a7c8eede18cab11e1115e2062b) 明确称其为让 Rust 代码能在内核构建的最小基础设施，更多抽象与驱动随后演进。

2025 Linux Kernel Maintainers Summit 判断实验阶段已经结束；Miguel Ojeda 的提交 [`9fa7153c`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=9fa7153c31a3e5fe578b83d23bc9f185fde115da) 在 2026 年进入主线，删除 “The Rust experiment” 一节，并把编程语言文档从 “experimental support” 改为 “support”。当前 [Linux Rust 文档](https://docs.kernel.org/rust/index.html) 反映这一状态，同时该提交也提醒某些架构、工具链和混合构建仍需继续工作。

类比的价值在演进方法：可选构建开关、C bindings、安全抽象、很小的可运行例子、逐子系统 review、工具链与 CI 一起推进。QEMU 的第一落点是 SysBus 设备，Linux 的边界是内核抽象与驱动；两者对象模型、锁和发布周期不同，成熟度也不宜用口号横向排序。读 Linux 的经验，是为了学会怎样缩小可信边界和交付范围。

:::: {.quick-quiz}
Linux 社区在 2025 年判断 Rust 实验阶段结束，并在 2026 年由主线提交落实，能否据此宣布 QEMU Rust 已达到同样状态？

::: {.quick-answer}
不能。两个项目的对象模型、设备范围、构建矩阵和维护节奏不同。可以比较可选接入、安全抽象与分阶段 review 的方法；QEMU 现状仍要依据 rc0 的默认开关、模块状态表和已有设备范围逐项描述。
:::
::::

## QOM 与 FFI 把安全证明放在适配层

Rust QOM 类型仍要符合 C 布局。设备结构使用 `#[repr(C)]`，父对象字段位于开头，class 结构也要匹配父 class；`ObjectType` 与 `IsA` 是声明布局/类型关系的 unsafe trait，`ObjectImpl` 则是普通 trait，不能把三者笼统写成同一类 unsafe 接口。derive macro 可以检查一部分形状并生成 TypeInfo，动态类型、实例存活和 C 回调约定仍属于安全证明的一部分。

MemoryRegion 展示了最典型的 FFI 边界。[`rust/system/src/memory.rs`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/rust/system/src/memory.rs) 用泛型 `MemoryRegionOps<T>` 接收 Rust read/write 函数，再由 `unsafe extern "C"` wrapper 把 C 的 opaque 指针转换为 `&T`。注册点必须保证指针非空、对齐、动态类型为 `T`，并在区域可访问期间保持 owner 存活。Rust lifetime 没有自动跨进 C 的 vtable，这些保证要由 QOM/MemoryRegion 生命周期和审计说明闭合。

设备回调通常使用 `&self`，可变字段放进 `BqlCell` 或 `BqlRefCell`。[`rust/bql/`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/rust/bql) 把“访问时持有 BQL”做成运行断言和内部可变性规则。它能约束局部借用，不能分析跨 C 调用的锁序。若方法持有 mutable borrow 再调用 `qemu_set_irq()`，同步回调可能重新进入同一对象；更稳妥的写法是先计算 action，释放 borrow，再产生外部副作用。

callback 也不能让 panic 穿过 C 边界。客户机可触发的未知 offset、非法 size、整数溢出和 borrow 冲突都要返回规定值、记录 guest error 或安全忽略。`unsafe impl Send/Sync` 必须列出锁前提，新增一个无锁 safe 方法会改变整项证明。审查 Rust 设备时，先读 wrapper 的 unsafe trait 与 extern callback，往往比数设备文件里有多少 `unsafe` 更有效。

## 在 RISC-V `virt` 上画一台教学设备

本书实验定义一个 `riscv-bookdev`：一页 32 位 little-endian MMIO，初版只有一个寄存器，高 16 位只读、低 16 位可写，reset 值为 `0x51454d55`。安全状态逻辑可以很短：

```rust
pub fn write(&mut self, offset: u64, size: u32, value: u32)
    -> Result<(), AccessError>
{
    validate_access(offset, size)?;
    self.register = (self.register & !WRITABLE_MASK)
        | (value & WRITABLE_MASK);
    Ok(())
}
```

这段代码能验证 offset、访问宽度和 writable mask，尚未成为 QEMU 设备。适配层还要定义 `#[repr(C)]` QOM/SysBus 类型、BQL cell、MemoryRegion owner、realize/reset 和错误传播。RISC-V Machine 在一次性 `virt` 变体中选择 base address；若加入 IRQ，Machine 负责连接到 PLIC/APLIC source 并生成一致的 DTB 节点。设备 crate 不应知道 hart、PLIC 或 FDT 布局。

第一版刻意没有 DMA、PCI 和外部后端。这让当前 stable 的 SysBus/MemoryRegion/QOM 能力覆盖完整需求，unsafe 集中在很薄的 adapter。加入 timer 后要说明 callback 存活与虚拟时间，加入 IRQ 后要处理重入，加入 DMA 后还要设计 guest memory 映射和 IOMMU 生命周期。能力应随测试和安全证明逐层增长。

当前上游的 PL011/HPET 只能作为 Rust API 现状证据。教学设备不会复制 Arm UART 或 x86 timer 的平台寄存器，也不会宣称已经进入 `hw/riscv/virt.c`。若未来出现真实 RISC-V Rust 设备，再沿其 commit、邮件、qtest 与 Machine wiring 更新本章。

## 生命周期和迁移仍遵守 QEMU 契约

类型注册建立 QOM class 和 vtable；instance init 初始化自身字段，不能依赖尚未设置的 properties；realize 校验配置并连接外部资源；reset 恢复客户机规定状态；unrealize/finalize 停止 callback 并释放所有权。Rust `Drop` 只有在对象真正销毁时执行，reset 和 migration load 都不会重建对象。把所有清理塞进 Drop，会漏掉 QEMU 生命周期中的大部分边界。

迁移也不会自动序列化 Rust struct。[`rust/migration/src/vmstate.rs`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/rust/migration/src/vmstate.rs) 提供 `VMState`、builder 和宏，最终仍生成 QEMU 的显式 VMState 描述。字段要有稳定宽度、版本和旧流默认；QOM parent、MemoryRegion、锁、borrow flag、宿主 fd，以及裸宿主地址或资源身份本身不属于迁移 ABI。该模块也为 `*const T`、`*mut T`、`NonNull<T>` 和 `Box<T>` 提供带 `VMS_POINTER` 的描述；这个标志让迁移代码沿指针找到并保存显式选择的状态，流中不会传输地址值。unsafe trait 的原因可以沿 C 访问路径核对：迁移代码会按 offset 访问 `#[repr(C)]` Rust 对象。

教学设备只保存客户机可见寄存器。未来加入 pending、timer 时，保存决定行为的值，IRQ 电平由 post-load 重算，timer 依据虚拟时间恢复。加载先检查非法组合，再产生外部副作用，vCPU 在此之前不能运行。Rust 类型可以让迁移表示与运行状态之间的转换更清楚，兼容策略仍由设备作者负责。

:::: {.quick-quiz}
为什么不能给 Rust 设备直接使用通用序列化框架保存整个结构体？

::: {.quick-answer}
QEMU 迁移流是跨版本客户机 ABI。Rust 布局、enum 表示、borrow 容器、裸宿主地址和资源身份属于实现细节；即使 VMState 通过 pointer field 访问数据，也必须显式选择行为状态，定义版本、默认、加载校验和恢复顺序。
:::
::::

## 构建、测试和 unsafe 审计要形成矩阵

第一列永远是 Rust 关闭：riscv64 system target 仍能构建，Kconfig/Meson 不要求 rustc 与 bindgen。第二列主动开启 Rust，记录 rustc 1.83+、bindgen、subproject 与 Meson summary，运行 `make check-rust`。第三列才是独立 safe core 的 `cargo fmt`、clippy 和 unit tests；它们验证寄存器逻辑，不能冒充 QOM 集成。

接入 QEMU 后，用 qtest 穿过 C/Rust callback，覆盖合法/非法 MMIO、reset 与 IRQ；functional test 让 RISC-V bare-metal 或内核从 DTB 发现设备；migration test 在非默认状态往返。TCG 先提供可移植基线，具备 RISC-V KVM 宿主时再运行同一客户机，记录 irqchip 与 capability。两条 accelerator 的设备语义应该一致，状态同步路径仍需分别验证。

unsafe 审计表为每个块记录输入、保证者、验证方法和失败后果。重点包括 opaque cast、QOM 布局、共享别名、BQL/锁序、callback 存活、panic、整数转换和 C string。Miri 可检查独立 pure-Rust 逻辑，ASan/UBSan/TSan 与 fuzz 帮助发现 FFI 和并发问题；工具通过不构成完整 soundness 证明。

依赖也是维护接口。新增 crate 要评估许可证、最低 Rust、离线发行、Meson wrap、增量构建和供应链；guest-controlled 长度不能转成无界分配。安全 Rust 减少一类局部错误，资源耗尽、死锁、设备规范错误和敏感 trace 仍要由限额、锁设计、测试和审查解决。

## 两个实验从状态逻辑走到 FFI

### 实验一：审计 C/Rust callback

::: {.hands-on}
配套英文实验手册：[`inspect-c-rust-boundary`](../experiments/part-05-engineering-and-evolution/chapter-23-rust-device-modeling/inspect-c-rust-boundary/README.md)。

从 `MemoryRegionOpsBuilder` 追到 extern C wrapper、opaque cast 和 `memory_region_init_io()`，逐项记录指针来源、动态类型、对齐、owner 存活、BQL、alias、panic 与错误语义。再检查 SysBus 的 MMIO/IRQ wrapper，区分类型保证、运行断言、C 契约和待验证条件。
:::

### 实验二：构建 RISC-V Rust 设备骨架

::: {.hands-on}
配套英文实验手册：[`build-rust-device-skeleton`](../experiments/part-05-engineering-and-evolution/chapter-23-rust-device-modeling/build-rust-device-skeleton/README.md)。

先运行依赖为零的 safe register crate，确认四个单元测试覆盖 reset、writable mask、错误 offset 和错误 size。可选阶段在一次性 QEMU worktree 中接 QOM/SysBus/MemoryRegion，再由本地 RISC-V `virt` 变体装配；qtest 通过以后才增加 IRQ、timer 与 VMState。实验材料明确标注 tree-out，不能写成上游已有设备。
:::

## 小结

QEMU 引入 Rust，是为了让设备模型中反复出现的布局、所有权、锁和输入检查拥有更集中的表达。rc0 已经提供多项 stable 的 QOM、SysBus、MemoryRegion、BQL 和 VMState 模块，构建 feature 仍默认关闭，模块成熟度与设备范围也各不相同。PL011、HPET 证明一条设备路径可运行；PCI、DMA、整板以及 RISC-V 上游设备仍需独立证据。

Linux 的演进说明了分阶段引入第二语言怎样降低工程风险，QEMU 则把方法落实到自己的对象和设备体系。RISC-V 教学设备把范围收窄到一个可测试寄存器、薄 FFI adapter 和明确的 Machine wiring。安全收益由类型和测试支撑，剩余 unsafe、生命周期、迁移兼容和规范正确性继续接受人类 review。
