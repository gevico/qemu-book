# Rust 设备建模与 C/Rust 边界

给 RISC-V `virt` 增加一个四寄存器 SysBus 设备，用纯 Rust 写状态机并不难。真正费力的部分从“把它放进 QEMU”开始：对象由 QOM 分配，父类必须排在结构体首部，MemoryRegion 把 C 的 `void *` 送回 callback，设备状态在 BQL 下共享，IRQ 与 reset 有生命周期，迁移框架还会按 offset 读取字段。任何一条约束写错，Rust 编译器都可能看不到，因为错误发生在 FFI 另一侧。

QEMU 的 Rust 接入选择渐进路径。C 主体、QOM、qdev、MemoryRegion、QAPI 与 VMState 仍然存在，Rust crate 为其中一部分建立类型化封装。语言能把局部借用、寄存器位域和锁条件变得更清楚，也能把 unsafe 压缩进适配层；它不能从一个裸指针推导 QOM 引用有效，不能替设备规范决定寄存器语义，也不会自动生成跨版本迁移 ABI。

本章目标版本为 QEMU `v11.1.0`，当前代码锚定官方 GitLab [`v11.1.0-rc0`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0)，commit `eca2c16212ef9dcb0871de39bb9d1c2efebe76be`。上游首个 Rust 设备案例只用于追踪语言边界的历史，所有平台装配、客户机行为和源码实例都以 RISC-V/riscv64 教学设备为主。

## 本章目标

- 理解 Meson/Kconfig、rustc、Cargo workspace、bindgen 与 `*-sys` crate 的分工；
- 把 QOM 继承、对象生命周期、MemoryRegion callback、BQL 和 IRQ 映射到 Rust 类型；
- 为 RISC-V SysBus 教学设备设计显式寄存器状态机、reset 与错误输入；
- 审计每个 `unsafe` 边界的指针、别名、线程、错误和生命周期条件；
- 使用 Rust VMState helper 时仍保留字段版本、加载校验和迁移测试。

## 先看上游把 Rust 放在哪里

当前 [`rust/Cargo.toml`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/rust/Cargo.toml) 定义 edition 2021、最低 rustc `1.83.0`、workspace 依赖与 lint；成员列出具体设备和测试。[`rust/meson.build`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/rust/meson.build) 组织 `common`、`bindings`、`bql`、`migration`、`qom`、`hw/core`、`system`、`trace` 与设备子目录。`rust` 构建选项默认关闭，且当前 Rust 代码只进入 system emulator。

[`docs/devel/rust.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/devel/rust.rst) 明确说明，正式构建由 Meson 直接调用 rustc 生成静态库，再与 C 代码链接。Cargo 主要服务 lint、rustfmt、rustdoc 与开发工作流；QEMU Rust 测试需要 C 支持代码，不能把普通 `cargo test` 当作权威集成入口，应通过 Meson 或 `make check-rust`。书中独立安全状态 crate 可以单独跑 Cargo，它验证的是树外纯 Rust 逻辑，不能冒充 QEMU 集成测试。

构建边界本身就是产品选择。Kconfig 决定具体设备是否选中，Meson 根据 target、feature 和依赖把 crate 接进某个 system emulator，Cargo 的 package graph 不负责 QEMU 最终二进制拓扑。开发者在 `rust/` 下运行 clippy 成功，只能证明当前开发环境中的 Rust 代码满足 lint；禁用 Rust、最小 riscv64 target 和完整链接仍需 QEMU 构建验证。

工具链版本也属于兼容面。当前 Meson 检查 rustc 至少为 1.83.0，文档还说明 bindgen 旧版本限制。使用更新语言特性前要考虑最低支持版本，不能只在个人 nightly 上通过。`Cargo.lock` 固定依赖解析，QEMU 还通过 Meson subproject 和发行环境管理依赖，更新 crate 需要审查许可证、供应链、MSRV 与离线构建。

## 历史从一个构建开关开始

提交 [`764a6ee9`](https://gitlab.com/qemu-project/qemu/-/commit/764a6ee9feb428a9759eaa94673285fad2586f11) 的 [review 邮件](https://lore.kernel.org/r/14642d80fbccbc60f7aa78b449a7deb5e2784ed9.1727961605.git.manos.pitsidianakis@linaro.org) 先加入 Rust feature 选项，为后续代码准备构建开关。它没有一次性引入完整设备栈。提交 [`6fdc5bc1`](https://gitlab.com/qemu-project/qemu/-/commit/6fdc5bc173188f5e4942616b16d589500b874a15) 的 [review 邮件](https://lore.kernel.org/r/1be89a27719049b7203eaf2eca8bbb75b33f18d4.1727961605.git.manos.pitsidianakis@linaro.org) 再把 bindgen 作为 Meson 依赖，保证 bindings 在使用它的 crate 前生成。

随后 [`5a5110d2`](https://gitlab.com/qemu-project/qemu/-/commit/5a5110d290c0f2dca3d98c608b0ec9a01d2181b9) 通过 [对应 review](https://lore.kernel.org/r/0fb23fbe211761b263aacec03deaf85c0cc39995.1727961605.git.manos.pitsidianakis@linaro.org) 加入初始 bindings/interface crate。提交说明能确认它暴露 bindgen 生成的 FFI，并提供向 QEMU 其余部分声明符号的宏。构建开关、生成顺序和接口 crate 分成提交，说明边界可分别审查。

首个设备证明由 [`37fdb2f5`](https://gitlab.com/qemu-project/qemu/-/commit/37fdb2f56a90c7d5ea7093b920a7bf72c03aff17) 及其 [v1 review](https://lore.kernel.org/r/20241024-rust-round-2-v1-2-051e7a25b978@linaro.org) 合入；迁移支持另由 [`93243319`](https://gitlab.com/qemu-project/qemu/-/commit/93243319db276bb424b7f9ad0bdfa8dc4b3368bd) 与 [邮件](https://lore.kernel.org/r/20241024-rust-round-2-v1-4-051e7a25b978@linaro.org) 补充。这里的直接历史结论是：能运行的设备与迁移契约是两个交付物。本文不复用该设备的平台寄存器，只研究它推动形成的通用 Rust 接口。

接口仍在演进。提交 [`c899071b`](https://gitlab.com/qemu-project/qemu/-/commit/c899071b5a86fca3c59e5abe04deaa3c9d77edb6) 把 raw binding 生成拆到多个 `*-sys` crate，提交说明给出两个目的：按 C 头文件依赖组织，减少头文件变化触发的全量重编。提交 [`1713498c`](https://gitlab.com/qemu-project/qemu/-/commit/1713498c0d7f41ce81387e47d60db0d8420f6233) 又把 sysbus wrapper 移到 `system` crate，使 Rust 依赖方向与 C 侧 system library 对齐，并修复特定平台链接问题。当前目录不能用初版文章解释，必须跟到锚点。

作者由这组历史推断，Rust 接入的首要工程约束是与现有构建和 C 子系统依赖共存，API 安全性与编译增量逐步提升。上游提交分别陈述了开关、生成顺序、crate 拆分和链接原因；“首要约束”是对这些事实的总结，不是 cover letter 原句。

:::: {.quick-quiz}
为什么 QEMU 的 Rust 设备仍要理解 QOM 和 qdev 生命周期？

::: {.quick-answer}
对象仍由 QOM 创建、继承、引用和销毁，由 qdev realize、reset、迁移并与 C 设备连接。Rust 只能检查进入类型系统的所有权；FFI 裸指针、父类布局、回调时机和引用计数仍由 QOM/qdev 契约保证。
:::
::::

## bindgen 只生成 raw 入口

当前 [`rust/bindings/`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/rust/bindings) 包含 `util-sys`、`qom-sys`、`hwcore-sys`、`migration-sys`、`system-sys` 等 crate。每个 wrapper header 选择 C API，Meson 按依赖顺序生成绑定。拆分减少无关重编，也防止不同 crate 重复生成同一依赖声明后形成互不相同的 Rust 类型。

bindgen 能把 C struct、常量和函数签名转成 Rust 声明，不能验证运行时调用条件。`*mut Object` 是否真指向目标子类，`MemoryRegionOps` 的 opaque 在 callback 期间是否存活，某函数是否要求 BQL，错误指针由谁释放，这些都不在 C 类型中。raw `*-sys` crate 保留危险，安全 wrapper 需要把条件放进类型、生命周期、guard、Result 或 safety comment。

FFI ABI 要匹配布局和 calling convention。映射 C 对象的 Rust struct 通常使用 `#[repr(C)]`，透明 wrapper 使用 `#[repr(transparent)]`。字段顺序、对齐、bitfield 表示与函数签名不能凭“看起来一样”判断；静态断言、bindgen 测试和 C/Rust 边界测试共同验证。跨语言结构若由 C 分配，Rust 不得用自己的 allocator 释放。

生成绑定也是构建产物。直接在源码树执行 Cargo，可能找不到 Meson 生成的文件；文档建议进入 Meson development environment 或设置 `MESON_BUILD_ROOT`。IDE 能解析不等于最终编译使用相同 `--cfg` 和 include，提交前以 Meson 构建为准。生成文件通常不手改，变更 wrapper header 或生成参数，再检查 diff。

unsafe wrapper 的审查格式可以固定五项：指针来源与 non-null、实际动态类型、对象存活期、线程/锁上下文、错误和 unwind。每一项都有谁保证。若保证来自 C 注释或调用约定，safety comment 链接对应 API；若只是当前设备恰好这样调用，不应包装成对所有调用者安全的 public 方法。

## QOM 布局怎样进入 Rust 类型

[`rust/qom/src/qom.rs`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/rust/qom/src/qom.rs) 用 `ObjectType`、`ObjectImpl`、`IsA`、class struct 与 derive 宏映射 QOM。`ObjectType` 是 unsafe trait，因为实现者必须保证 Rust struct 为 `#[repr(C)]`，首字段对应父类，class struct 首字段也匹配父 class。错误的 `IsA` 声明会让静态 cast 在错误布局上工作，编译器无法自行证明继承关系。

Rust 子类首字段使用 `ParentField<T>`。它封装 `ManuallyDrop`，配合 QOM 在 C 侧逐层 deinit 的顺序，避免 Rust 自动先把父类按普通字段销毁。`drop_object<T>` 只 drop 当前 Rust 类型，父层由 QOM 后续处理。这里的类型设计把一条 C 生命周期规则集中起来，仍依赖 QOM 调用 finalize 时传入正确类型。

初始化阶段更微妙。QOM 先初始化父类，再进入子类 `instance_init`；对象内存部分仍未初始化。`ParentInit` 使用不变 lifetime token 限制初始化引用逃逸，`MaybeUninit` 表达尚未完成的字段。它减少把未初始化对象长期借出的机会，unsafe callback 仍要保证传入指针属于 T，设备 init 也不能调用会读取未初始化子字段的父类方法。

class init 把 Rust trait 中的虚函数放进 C class vtable。`DeviceImpl::REALIZE`、reset phases、properties 与 VMState 最终成为 C 函数指针或静态结构。泛型 wrapper 在回调时把 C 指针转回 `&T`。类型参数让每个设备得到专门函数，却不能验证 C 调用者真的传 T；这条动态类型保证来自 QOM registration。

`Owned<T>` 包装 QOM 引用计数，clone 增加引用，drop 减少引用。当前源码注释强调 drop 需要 BQL；从 raw 指针构造还要求调用者确实拥有引用，并且嵌入对象的外层生命周期足够长。把任意借用指针塞进 `Owned::from_raw()` 会造成重复 unref 或悬空，智能指针名称不会修复错误来源。

普通设备方法倾向使用 `&self`。QOM 对象很早就进入 composition tree，存在多个共享引用；从 callback 的 raw `*mut` 随意恢复 `&mut self` 会与共享引用重叠，违反 Rust alias 规则。可变寄存器放进 interior mutability 容器，外层对象继续共享。这是 QEMU Rust 文档明确强调的常见陷阱。

## BQL 是类型安全证明的一部分

[`rust/bql/src/cell.rs`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/rust/bql/src/cell.rs) 提供 `BqlCell<T>` 和 `BqlRefCell<T>`。它们把 BQL 视作外置互斥，允许类型实现 `Sync`；get/set/borrow 会检查当前线程持有 BQL，调试配置还跟踪动态借用。相比普通 `Cell`/`RefCell`，它们表达跨线程 QEMU 环境中的锁条件。

小型 Copy 字段可放 `BqlCell`，复杂寄存器块适合 `BqlRefCell`，一次 mutable borrow 内完成读—改—写。借用期间调用可能重入同一设备的 C API 会再次 borrow，产生 panic；因此先在局部计算新状态，释放 borrow，再更新 IRQ 或调用外部对象。锁正确不代表重入安全，动态 borrow 的范围需要刻意缩短。

BQL wrapper 不能用于所有线程模型。某设备 dataplane 在 AioContext 或独立 I/O 线程运行，BQL 未必持有；强行断言会在调试构建失败，绕过断言又可能数据竞争。当前文档也把其他锁上下文的 cell 留作未来方向。教学设备先限定回调在 BQL 下，若要脱离 BQL，重新设计所有者、消息传递或适当同步，不在 `unsafe impl Sync` 上写一句假设了事。

`unsafe impl Send/Sync` 是高风险审查点。透明 C wrapper 常声明 Send/Sync，因为实际同步由 QEMU 锁保证；任何 safe 方法都必须维护该保证，或在调用前 assert BQL。增加一个无锁读取方法会破坏整个 impl 的论证。review 应从 impl 反向列出全部可达方法，而非只看新方法内部没有 `unsafe`。

锁序也跨语言。Rust 先 borrow BqlRefCell，再调用 C，C 可能获取另一个锁或回调；另一线程反向获取便会死锁。编译器不会分析 C 锁图。safety/locking 文档记录 BQL、AioContext、后端锁顺序，trace 或 lockdep 类工具验证。局部内存安全无法替代系统并发设计。

## MemoryRegion callback 的真实边界

当前 [`rust/system/src/memory.rs`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/rust/system/src/memory.rs) 定义泛型 `MemoryRegionOps<T>` 与 builder。`read`/`write` 接受零捕获函数类型，通过专门的 `unsafe extern "C"` wrapper 把 opaque `void *` cast 成 `&T`，再调用 Rust 函数。`PhantomData<fn(&T)>` 让类型记录 callback 逻辑上接收 T，C vtable 本身仍擦除了类型。

`MemoryRegion::init_io()` 把 owner 指针同时作为 opaque，要求 owner 是 `T` 且在 MemoryRegion 可调用期间存活。这个关系由初始化和 QOM 生命周期保证，并没有一个普通 Rust lifetime把二者绑在一起。审查教学设备时，要确认 MemoryRegion 是对象字段、owner 不会先销毁、unparent/unrealize 后 callback 不再发生。

builder 还能声明 endianness、valid/implemented access size 与 unaligned 支持。RISC-V 教学设备若只实现 32 位小端寄存器，应显式设置 4..4，并在设备函数继续检查 offset；MemoryRegion 层验证宽度不替代寄存器范围。客户机输入的 `addr`、`data` 和 `size` 全不可信，转换 `usize`、数组索引和长度前检查溢出。

当前 callback wrapper 直接调用 `F::call()`，路径中没有捕获 panic。设备逻辑不能依赖 `unwrap()` 处理客户机可触发错误，动态 borrow 冲突也应通过设计避免。panic 在 FFI 边界的具体终止行为受编译与 ABI 规则影响，工程结论很简单：所有 guest-controlled 分支返回规定值或记录错误，不能让 unwind 穿过 C。

MMIO callback 的 Result 语义也有限，当前简化 wrapper 返回 `u64` 或 `()`；需要 MemTxResult、attrs 或更复杂语义时，先确认锚点 API 是否提供安全接口。缺少 wrapper 不等于可以假装访问永远成功。可以扩展通用 binding 并单独评审，或把教学设备范围限定为当前接口能准确表达的行为。

:::: {.quick-quiz}
把设备写成 Rust 后，非法 MMIO 访问会自动变安全吗？

::: {.quick-answer}
不会。客户机仍能提供任意 offset、size 和 data，C callback 还传入类型擦除的裸指针。Rust 可以保护检查后的状态访问；设备仍要验证范围、对齐、宽度和转换，并为指针有效、对象存活及锁条件提供 FFI 证明。
:::
::::

## 为 RISC-V 设计一个显式寄存器状态机

教学设备命名为 `riscv-bookdev`，映射一页 MMIO，先实现 `CONTROL`、`STATUS`、`VALUE`、`IRQ_ACK` 四个 32 位小端寄存器。`CONTROL.ENABLE` 启动一次确定性运算，`STATUS.DONE/PENDING` 只读，`VALUE` 保存输入或结果，`IRQ_ACK` 写一清 pending。寄存器表同时写 reset、读写掩码、副作用和迁移要求。

offset 用枚举或 `TryFrom<u64>` 转换，未知地址返回规范约定的值并记录 guest error；bitfield 用窄类型或集中 helper，保留位在写入时掩掉。读写函数接收 `&self`，在一次 `BqlRefCell` 借用内完成纯状态变化，计算“是否需要更新 IRQ”的布尔结果，释放借用后再驱动 `InterruptSource`。这样避免外部回调重入时持有寄存器 mutable borrow。

设备不能把 RISC-V CPU 细节塞进通用寄存器逻辑。它只产生一个 SysBus IRQ，Machine 在 `hw/riscv/` 的本地实验补丁中选择地址并连接 PLIC/APLIC source。CPU 模型、hart ID 与 FDT 节点属于平台装配。未来若同设备挂到另一 RISC-V Machine，状态机不需复制。

realize 读取 QOM properties 并检查配置，初始化阶段只建立字段和 MemoryRegion。任何可失败且依赖用户属性的动作放 realize，错误通过 QEMU Error 返回。reset 的 HOLD 阶段清寄存器并降低 IRQ，避免在不允许对外副作用的阶段操作线路。unrealize/unparent 若注册 timer 或后端，要先阻止新 callback，再释放资源。

纯状态 crate 可以先完全脱离 QEMU。`RegisterBlock::read/write/reset` 使用安全 Rust，单元测试覆盖 reset、合法写、只读位和越界；它不含 raw pointer、QOM 或 IRQ。接入适配层负责 MemoryRegion、BQL 和 InterruptSource。分层让绝大多数 guest input 逻辑可用 Cargo 快速验证，unsafe 审计集中在很薄的 glue。

## IRQ、timer 与回调所有权

`InterruptSource` 表达设备拥有的输出，Machine 连接到目标中断控制器。设备更新 pending 后计算输出电平，enable 与 pending 同时为真才拉高；ACK 清 pending 后降低。线路更新要幂等，reset 和迁移 post-load 都可调用同一 `update_irq()`，不要把“上次已拉高”藏在未迁移的宿主缓存。

输入 IRQ callback 与 MMIO 类似，从 C 传 opaque 和电平。回调不应保存临时引用，也不把 `u32` 电平当任意布尔而忽略协议。多输入用编号验证范围。若 callback 可能来自非 BQL 线程，当前设备的 BqlCell 设计就不成立，需在注册前确认调用上下文。

timer 对象包含宿主/虚拟时钟关系，callback 稍后访问设备。对象在 timer 活跃期间必须存活，销毁前删除 timer；reset 决定取消还是重排。callback 若仅保留 raw owner 指针，QOM 引用与 timer 生命周期需由设备保证。更安全的 wrapper 可以收紧 API，不能让 `'static` 闭包掩盖借用对象其实会销毁。

虚拟时间是客户机 ABI。教学设备若增加延迟完成，使用 QEMU virtual clock，qtest 可精确推进；宿主 wall clock 会让 pause、迁移和 CI 调度改变行为。迁移保存剩余/到期时间或框架要求的 timer 状态，post-load 重新计算 IRQ。只迁移 `DONE` 而漏掉未到期 timer，会让请求永远不完成。

外部后端进一步扩大所有权。文件描述符、线程、channel 和 async task 不能直接写进 VMState，unrealize 和迁移要 quiesce/recreate。Rust 的 `Drop` 能帮助释放本地资源，却不自动遵循 QEMU stop 顺序；对象可能在 Drop 前由 C 移除连接。生命周期协议仍要映射到 realize、reset、migration 和 finalize。

## unsafe 审计逐条写不变量

第一类是 cast。`opaque.cast::<T>()` 要求非空、对齐、动态类型为 T、T 在调用期间已完整初始化。MemoryRegion 注册点提供来源，QOM 对象字段保证对齐和存活，回调注销保证结束时机。若其中一项只靠约定，safety comment 写出约定和 C 函数。

第二类是布局。`ObjectType`、`IsA` 和 class struct 要求 `repr(C)` 与父字段首位。derive 宏减少样板，不会检查一个手写 unsafe impl 是否撒谎。静态 size/offset 测试、QOM dynamic cast 和实际实例化共同验证。升级 binding 后重新检查，不把旧布局结果永久沿用。

第三类是别名。QOM 对象存在共享引用，所以 callback 取 `&T`，内部通过 BqlRefCell 变更；不得从 raw `*mut T` 制造全对象 `&mut T`。借用只覆盖局部状态，不跨外部 C 调用。这个规则比“unsafe 块很短”更具体，也能被 code review检查。

第四类是线程。`Send/Sync` 依赖 BQL 或其他锁，所有 safe 方法要 assert 或持 guard。callback 注册 API 的线程语义需要确认，Rust 类型不能凭函数名推断。性能优化要把路径移出 BQL 时，先更换状态容器和协议，再修改 unsafe impl。

第五类是错误和 panic。C 的 `Error **` 映射到 Rust `Result`，所有权由 wrapper 传播；客户机非法输入不使用 `unwrap`。FFI callback 不 unwind，allocation failure、borrow conflict和整数转换都设计可控路径。日志不得输出未验证长度的数据。

第六类是生命周期。`Owned<T>` 表示持有 QOM 引用，普通 `&T` 只在调用期间借用，raw pointer 存入 C 前必须有外部对象保证。timer、BH、AioContext callback 和 chardev handler 都可能晚到，注销与对象销毁形成 happens-before。找不到明确结束点时，安全 wrapper 尚未闭合。

一份审计表每个 unsafe 块一行，列输入、保证者、验证方式与失败后果。宏展开产生 unsafe 也要追到生成代码或宏定义。`cargo geiger` 一类计数可以导航，数量少不等于安全；一个错误 `unsafe impl Sync` 的影响远大于几十个局部 FFI 调用。

## Rust 迁移仍然是 VMState

[`rust/migration/src/vmstate.rs`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/rust/migration/src/vmstate.rs) 提供 `VMState` trait、`vmstate_of!`、builder 与对应 C 宏的 helper。文档直接警告，一部分 C 等价宏不具备类型安全；`VMState` 本身也是 unsafe trait，因为生成的 C 结构会按 offset introspect Rust struct。宏把样板缩短，没有改变流 ABI。

`vmstate_of!` 利用字段类型计算 size、info 与 offset，支持标量、数组、BqlCell/BqlRefCell 等 wrapper。`#[repr(C)]` 与稳定字段布局仍必需。运行态结构与迁移表示可以通过 `ToMigrationState` 分开，快照时把 bitfield/内部状态转换成明确整数，恢复时校验版本并重建。这比直接依赖 Rust enum 的内存表示更稳妥。

教学设备的流只保存 `control` 中客户机可见位、`value`、`done/pending` 和 timer 必需状态。IRQ 输出是 pending/enable 的派生值，目标 post-load 调 `update_irq()`；BQL borrow flag、QOM parent、MemoryRegion、指针与 host fd 不保存。新增字段提升版本，旧流给默认，非法组合在 vCPU 运行前拒绝。

当前 `rust/tests/tests/vmstate_tests.rs` 验证 builder 生成的字段名称、offset、flags、版本、数组与 wrapper。它证明 Rust helper 映射到预期 C VMState 元数据，不证明某个具体设备选择了正确字段。设备仍需同版本往返、旧/新版本和 active-state 测试。

迁移安全还要求同步权威状态。若 Rust 设备的回调全部在 BQL 下，pre-save 可在同一锁上下文快照；若后端线程拥有最新队列，先 quiesce 或通过消息取回。`Migratable<T>` 和 interior mutability helper 能表达恢复方式，不能替开发者决定何时冻结。

:::: {.quick-quiz}
为什么 Rust 结构体或派生序列化不能直接成为 QEMU 迁移格式？

::: {.quick-answer}
迁移是跨版本客户机 ABI，只应包含决定后续行为的状态。Rust 字段布局、enum 表示、缓存、borrow 容器和宿主句柄属于实现；仍需显式 VMState 字段、版本、默认、加载校验与恢复顺序。
:::
::::

## 构建与测试矩阵

第一列是 `--disable-rust`。新增 Rust 设备未选择时，QEMU 的 C-only 和 riscv64 system target 应继续构建；Kconfig 不应留下未解析符号，Meson 不应无条件要求 rustc/bindgen。渐进接入的前提是未使用者不承担强制工具链。

第二列是启用 Rust 的最小 riscv64 system build。确认 rustc 版本、bindgen、subproject、生成顺序与静态链接，运行 `make check-rust` 或 Meson 列出的 Rust 测试。只在包含上游首个设备的平台 target 成功，不能证明 RISC-V 集成依赖正确。

第三列是纯状态 crate。仓库实验目录中的依赖最小 crate 执行 fmt、clippy 和 unit tests，验证寄存器状态机。它没有 QOM 和 C 支持，结果在报告中标“safe core”；可选集成补丁再通过 QEMU Meson、qtest 与 functional test 标“adapter/system”。

第四列是 qtest。合法/非法 MMIO、reset、IRQ 和 clock 逐项覆盖；运行 debug cell 配置能提前发现缺 BQL 或 borrow 重入。故意违反宽度、offset 和保留位，确保错误不会 panic。若 qtest 使用的 Machine 没接教学设备，先用本地 RISC-V Machine variant 或命令行可创建方式，装配补丁单独保存。

第五列是迁移。在非默认 pending、timer 和 value 状态下源目标往返，验证 IRQ 重算；再修改字段版本做负面用例。Rust helper 单测、设备 migration test 与整机 RISC-V 迁移三层各有责任，不能合并成一次 `cargo test`。

第六列是 sanitizer/Miri 能覆盖的纯 Rust 部分与常规 QEMU sanitizer。Miri 无法直接执行完整 QOM/C 环境，却能检查独立状态 crate 的 unsafe（理想情况下为零）；ASan/UBSan 等可帮助发现 FFI 布局和 C 侧错误。工具通过是补充证据，不取代 QOM 生命周期审计。

## 渐进式 API 的工程权衡

把 unsafe 全部推给每个设备，会重复错误；把每种 C API 都包装成“安全”接口，又可能在契约未明时承诺过早。上游当前聚焦 safe SysBusDevice，文档把模块标为 complete、stable、proof of concept 或 initial，并提醒 C API 自身也不稳定。设备作者应按锚点实际状态选择，不用“Rust 已支持 QEMU”概括所有设备类型。

安全 wrapper 越高层，越可能限制合法用法。例如 MemoryRegion builder 只提供简单 read/write，能保证 callback 形状，却暂时不表达所有 attrs/result；强行绕过会扩散 raw binding，等待/扩展 API又增加工作。选择依据是教学设备真实语义和上游可复用性，扩展通用接口时带测试和文档。

crate 拆分减少增量编译，也增加依赖管理。`*-sys` 依赖要与 C static library 层次一致，否则链接或重复类型出错。提交 `c899071b` 与 `1713498c` 展示上游会为编译和链接反馈重排边界。书中不把当前 crate 图当永恒架构，每次升级 tag 重新读 Meson 与 Cargo。

宏能把 QOM/VMState 模板变短，也会隐藏生成的 unsafe。适合把已经理解且重复的布局规则封装，不适合掩盖尚未确定的生命周期。审查宏调用时展开关键 TypeInfo、callback 和 VMStateField，至少知道 C 最终看到什么。

采用 Rust 的收益应有具体指标：guest-controlled 输入越界能否被类型/检查阻止，unsafe 是否集中，状态机是否更易测，FFI wrapper 是否被多个设备复用，构建时间与二进制体积怎样变化。语言偏好不替代数据。保留 C 实现或逐步替换时，也要比较迁移格式和客户机行为，避免形成两个不一致模型。

## 从 configure 到最终 riscv64 二进制

构建开始于 feature 选择。`--enable-rust` 或对应 Meson option 要求可执行 rustc、rustdoc、bindgen 与依赖，Meson 检查最低版本；没有 system emulator 时 Rust 子树不会进入。接着 target list 和 Kconfig 决定哪些设备 crate 有机会编译。一个 crate 出现在 workspace，不代表它自动进入 `qemu-system-riscv64`。

bindings 先于 safe crate 生成。每个 `*-sys` wrapper header 通过 bindgen 产生 Rust 声明，生成参数要包含本构建的 C 配置、include 与 target 信息；上层 `qom`、`system`、`hwcore` 等 crate 再依赖这些 raw 类型。顺序错时常见症状是缺文件、重复类型或链接 undefined symbol，不能用在源码树复制一份旧 `bindings.rs` 修复，那会让 Rust 与当前 C 头文件脱节。

Meson 直接调用 rustc 编静态库，并把 Cargo.toml 中的 lint 转成 rustc 参数。正式编译的 `--cfg MESON`、target、生成文件目录和 native link 与普通 Cargo 不同。`meson devenv` 让 Cargo 工具拾取同一构建环境，仍以 Meson 产物为集成事实。IDE 分析报错时，先确认 build root 和生成步骤，不修改 API 去迁就一个缺配置的编辑器视图。

最终链接还受 C static library 分层影响。sysbus wrapper 移到 `system` crate 的提交，就是因为 Rust/C 依赖方向与链接平台反馈不一致。新增教学设备时，先依赖最小 crate，不从底层 `common` 反向引用 system；循环依赖在 Cargo 侧可能直接失败，在 Meson/C 静态库侧还可能表现为平台相关链接顺序问题。

禁用配置同样运行。`--disable-rust`、缺 bindgen 的 auto 配置、只建 riscv64、关闭默认设备，各自检查。Kconfig symbol 只在 Rust feature 可用时选择，C Machine 代码不能无条件引用 Rust 符号。若本地 RISC-V `virt` variant 想创建教学设备，创建代码也放相同条件或让设备通过通用命令行添加，保持无 Rust 构建完整。

可重复构建保存 rustc/bindgen 版本、Cargo.lock、Meson summary 与 subproject wrap 版本。Rust crate 下载不应在每次编译随网络变化，发行版离线构建也要能找到依赖。升级依赖单独提交，先审 API 和许可证，再跑全部 target；不要把依赖大升级藏在设备功能 diff 中。

## 一个 QOM Rust 对象的一生

类型注册时，derive/trait 生成 `TypeInfo`，其中含类型名、父类型名、instance/class size、init/finalize 和 class init callback。QOM 根据它分配零初始化存储、建立 class vtable。Rust 的 `ObjectType` unsafe impl 宣称这些 size、布局和父类关系真实；类型名与 C 端重复或父类写错，可能在运行时注册或 cast 才暴露。

实例创建先初始化父层，再调用 Rust `rust_instance_init<T>`。wrapper 将 `Object *` cast 到 `MaybeUninit<T>`，用 `ParentInit` 限制初始化 token。设备在此阶段初始化自己的 MemoryRegion 字段、cell 和 owned child，不能假定用户 properties 已完成，也不执行可能失败的后端动作。部分字段初始化后 panic 会让跨 FFI 清理极难，init 路径避免 panic 和复杂资源。

instance post-init 发生在各层 init 完成后，可以读取完整对象，仍不是 realize。properties 通常在创建与 realize 之间由命令行、Machine 或 QMP 设置。教学设备的 mmio size 若是常量，可在 init 建 MemoryRegion；IRQ 数与字段也在此确定。依赖属性的校验留到 realize，以 QEMU Error 报告。

class init 在 class struct 中安装 `REALIZE`、VMState、properties 与 reset interface。Rust 方法通过泛型 extern C trampoline 进入 vtable。父 class 的方法是否先被调用、子类是否覆盖，由对应 class extension trait 决定。新 wrapper 不能默认“Rust trait 继承”等同 QOM 虚函数链，实际函数指针要检查。

realize 阶段对象开始与外部世界连接。SysBus device 暴露 MemoryRegion 和 IRQ，由 Machine 映射/连接；任何失败应传播 `Error **`。部分连接已完成后失败，需要 QEMU/qdev 生命周期按约定清理，设备不得在 Drop 中重复释放 C 拥有资源。测试故意让最后一步失败，检查先前步骤没有留下活动 callback。

运行阶段 QOM tree 持有共享对象，MMIO、IRQ、timer、reset 和迁移从 C 回调。所有 callback 只拿短期 `&T`，可变字段走 interior mutability。若设备注册 BH/timer，C 可能在当前方法返回后再回调，raw owner 指针的有效期延伸；unrealize/unparent 必须取消并等待，或由引用计数确保对象活到回调结束。

reset 不销毁对象。enter/hold/exit 按 QEMU reset protocol 调用，设备清状态、更新外部线路，再继续运行。迁移 load 也不重新 init/realize，它覆盖已构造对象的运行状态。把 reset helper直接拿来 post-load，只有当两者语义相同才安全；通常 post-load应恢复 pending和timer，而 reset会清空。

unparent、unrealize 与 finalize 的顺序取决于对象如何创建和挂树。Rust `Drop` 执行时父类字段仍需有效，因此 `ParentField`、`Owned` 和 QOM deinit 配合。Drop 中需要 BQL 的 `Owned<T>` 会让销毁线程也成为安全条件。对象生命周期测试重复创建/删除设备，监控 callback、fd 和引用计数，单次进程退出会掩盖泄漏。

## 把寄存器规范翻成类型，而非翻成语法

寄存器 offset 是客户机 ABI，使用 `#[repr(u64)]` enum 或 `TryFrom<hwaddr>` 可以集中合法集合；未知值返回 error 分支。不要直接 `offset as usize / 4` 索引数组，guest 可给极大地址，算术和索引都有边界。若寄存器存在稀疏空洞，match 比数组更准确。

位域类型可以限制可表示值，仍要区分 raw 写入与规范状态。写 `CONTROL` 时先把 u32 转成 raw，应用 writable mask，验证互斥字段，再生成内部类型；只读和保留位不从 guest 覆盖。读回是否把保留位固定为零、返回硬件 ID 或保留上次写值，由规范决定，类型不会替你选择。

write-one-to-clear 常被误写成赋值。`pending &= !written_mask` 才表达清除，其他位保持；若条件电平仍存在，更新 IRQ 时可能重新 pending。单元测试用零、单 bit、多 bit 和超出 mask 的值，qtest 再验证线路。Rust 的 `!` 在类型宽度内工作，先转换成明确 u32，避免 usize 宿主宽度渗入 ABI。

访问大小和 endian 由 MemoryRegionOps 与设备函数共同控制。RISC-V 客户机通常小端，设备也显式小端；QEMU 将总线数据按 ops 约定传入，设备 match offset。若将来支持 byte/halfword，必须定义它们怎样映射 32 位寄存器，不能靠主机字节序切片内存。测试在 riscv64 目标上发具体字节序列。

状态机用事件命名比布尔堆积清楚。`Idle`、`Busy`、`Done` 可限制非法组合，迁移格式则用稳定整数和显式转换，不直接保存 Rust enum layout。若 `pending` 与 `Done` 可独立存在，单一 enum 反而丢信息，应保留正交位。类型设计服从硬件状态空间，不追求形式漂亮。

副作用从纯转换结果返回。例如 write 得到 `Action { irq_changed, schedule_timer, log_error }`，适配层在释放 borrow 后执行。这样单元测试能验证 action，C 调用集中，重入窗口清晰。Action 不是迁移字段，它是一次操作的派生计划；迁移保存完成后的稳定状态。

## callback、重入与锁序

QEMU 设备方法调用 C 后，C 可能同步回调同一设备。拉高 IRQ 可能触发中断控制器更新，字符后端发送可能调用 handler，属性设置也可能触发 notifier。Rust 方法若仍持 `BqlRefMut`，回调再次 borrow 会 panic。每次 FFI 调用前检查局部 guard 是否已 drop，必要时用内层 scope 明确结束。

异步回调带来另一种重入：当前操作安排 timer/BH，未来在同一或另一线程执行。状态中的 generation counter 可让旧 callback 发现 reset/unrealize 后已过期；销毁前仍要保证指针安全，generation 只解决语义，不解决 use-after-free。callback registration 与 cancellation 的 C 契约必须进入 safety proof。

BQL 下执行慢后端会阻塞全部 vCPU/设备，Rust safe 并不代表调度合理。要把工作下沉到 I/O 线程时，设备状态拆成 BQL 控制面与线程安全数据面，通过 channel/atomic/Mutex 交换。MemoryRegion callback 只验证并提交，不把 BqlRefCell 引用跨线程发送。结果回主循环后再更新 IRQ。

锁序写在类型周围。若 callback 持 BQL 再取 backend Mutex，工作线程不得持 backend Mutex 同步等待 BQL；可复制请求数据后释放 BQL，或使用单向消息。`Mutex<T>` 实现 Send/Sync 只说明内存访问互斥，无法阻止循环等待。测试用压力和 timeout，review 用锁图。

原子字段也需要内存序。客户机 doorbell 发布 descriptor，设备线程读取；Rust `Atomic*` 的 Relaxed/Acquire/Release 应与 QEMU/guest memory barrier 协议对应。随手用 SeqCst 可能正确却代价高，随手用 Relaxed 可能在某宿主失效。架构示例保持 RISC-V，需同时考虑客户机 fence 与宿主线程同步，它们位于两个层次。

FFI callback 期间对象可否被 hot-unplug，也是生命周期问题。QOM/qdev 通常安排删除在安全上下文，设备仍要停止新的进入并等待活动回调。若 wrapper只提供 `&T` 无计数，安全性依赖 C 保证调用期间 object alive；把引用存出 callback 会越过保证。API 文档应明确“不可逃逸”。

## 错误、panic 与资源回滚

用户属性错误通过 `util::Result` 映射 C `Error **`，错误信息包含属性与合法范围。客户机 MMIO错误通常不能让 QEMU realize 失败，应按 MemoryRegion语义返回、记录 `LOG_GUEST_ERROR` 或忽略。两种错误域分开，避免恶意客户机通过写寄存器触发宿主进程退出。

整数转换用 `try_from`，但不对 guest 输入 `unwrap()`。offset、size、长度、队列索引和乘法先检查；数组边界返回设备定义错误。`NonNull::new(...).unwrap()` 只适合由 C 契约明确保证 non-null 的内部 wrapper，safety comment 要说明；若 public FFI 允许 null，应返回 Option/Error。

内存分配失败的处理受 QEMU 与 Rust allocator 策略影响。设备不能接受无界 guest 长度后直接 `Vec::with_capacity`，即使 OOM 最终 abort，拒绝超限仍是安全边界。固定 FIFO 用定长数组，动态队列设最大值并在 realize/写入时校验。

panic 不作普通错误机制。callback wrapper没有 catch，`RefCell` borrow、数组索引、assert 和 `unwrap` 都可能由客户机路径触发。调试断言可用于开发者不变量，但要证明 guest 无法直接破坏；可恢复协议错误返回值。fuzz/qtest 专门尝试使每个边界 panic。

realize 中多步资源申请使用局部 owner 或 guard，成功后转移进对象；失败时局部 Drop 回滚。对于 C 资源，确认谁拥有并用对应 API 释放，不能让 Rust guard与 QOM 都释放。`ManuallyDrop`、raw fd 和 `Owned::from_raw` 出现时，逐分支画所有权转移。

日志与错误格式也过 FFI。C string 要无内部 NUL、生命周期覆盖调用；临时 CString 指针不能被 C 长期保存。guest 提供字符串先限制长度与编码，不直接作为 format string。错误消息可诊断，不能泄露宿主路径或未初始化内存。

## 迁移版本怎样随 Rust 结构演进

第一版设备流设 `version_id = 1`，字段顺序按 VMState 描述，不按 Rust struct 视觉顺序推断。运行结构可以重排，只要 offset 在本构建正确、流顺序和语义保持。`vmstate_of!` 计算 offset，减少手写错误；字段名称与类型仍决定外部格式。

第二版新增 `deadline`。若旧流没有它，目标可以根据 `busy` 和设备默认延迟重建，或把旧请求视为立即完成，选择需要符合兼容承诺。字段设置 version 2，post-load 根据收到版本填默认；新源到旧目标是否允许，要看 Machine/迁移策略，不能假设旧代码会跳过未知数据。

字段删除时不要直接从流消失。旧目标/旧流可能需要占位，可保留 unused bytes，或通过 version/subsection 兼容。运行 Rust struct 可删除缓存字段，migration representation 仍保留旧格式。代码看似多余的 `vmstate_unused!` 可能是在维护流位置，历史和测试要说明。

内部类型变化也需转换。例如 `u32` status 改为 bitfield类型，迁移仍可序列化稳定 u32；`ToMigrationState` snapshot/restore完成转换并验证保留位。直接让新类型实现透明 VMState，只有在布局和语义完全相同且有 unsafe proof 时才合理。语言抽象升级不应改变客户机状态。

subsection 用于可选功能，predicate来自稳定 property，而非瞬时 pending。教学设备可选 timer若由 `has-timer` property 决定，源目标必须一致；仅在 timer active 时发送会让 inactive状态缺少配置，恢复更难。feature协商在迁移前完成，stream只携带运行状态。

post-load 先验证组合，再产生外部副作用。确认 control合法、timer deadline范围、pending与state一致，随后重排timer和IRQ；任一验证失败，vCPU不得运行。验证函数对恶意流使用 checked arithmetic，不因“流来自可信源”省略，因为迁移通道和存档可能损坏。

兼容测试保留黄金流要谨慎。二进制 blob能验证读取旧格式，但会增加仓库体积和更新难度；也可启动旧QEMU动态生成。无论哪种，都记录生成commit、Machine与字段激活。仅保存 reset状态的golden几乎测不到新增字段。

## 安全 Rust 能保证什么，不能保证什么

安全状态函数能保证在输入检查后不发生普通越界和悬空引用，enum/match 可迫使处理所有已知寄存器，借用规则限制同时可变访问。BqlRefCell 把锁与动态借用结合，Owned 封装引用计数，builder减少错误 offset。这些收益具体且可测试。

设备规范正确性仍由人和测试保证。writable mask、IRQ时序、DMA顺序、reset值写错，全是内存安全的逻辑bug。类型可以让非法状态难表示，前提是开发者把规范正确编码；错误模型会被Rust稳定执行。

QOM与FFI有效性位于unsafe边界。错误父类、错误cast、过期opaque、错误Send/Sync可使安全设备方法在无效引用上运行。安全API的可信计算基扩大到C实现和注册契约，审计不能只跑clippy。每个safe wrapper都应说明为何对所有调用者安全。

客户机ABI也不会自动稳定。修改enum、默认property、迁移field或错误返回会改变行为，semver不替代QEMU Machine/VMState策略。crate是内部工程组织，不代表客户机看到Rust版本接口。兼容测试仍按寄存器和迁移流执行。

实时性和性能也不由类型系统保证。BQL借用可能范围过大，clone/分配可能落在热路径，生成wrapper可能阻止优化，bindgen拆分影响构建。基准、trace和宿主采样负责这些问题。发现性能差不能简单归因语言，先分解FFI、锁、算法和构建优化。

供应链是另一层。外部crate可能有漏洞、许可证或MSRV变化，Cargo.lock固定版本不等于安全。QEMU的依赖策略、vendoring/subproject和CI共同管理。教学设备优先使用已有crate与标准库，新增依赖需证明收益超过长期维护成本。

## 为上游拆分一组可评审补丁

第一份补丁只扩展通用wrapper时，包含API、safety文档和Rust测试，不带RISC-V设备。若现有API足够，这步省略。通用接口的命名与C层次一致，限制明确，review者可以独立判断soundness。

第二份补丁加入纯寄存器状态和unit tests。它不注册QOM，review集中在设备规范、输入验证和状态机。若设备完全是书中教学用途，这部分保留实验仓库，不假装上游硬件。真实上游设备还需公开规范或硬件依据。

第三份补丁接QOM/SysBus、MemoryRegion、properties和reset，Kconfig/Meson同时加入。qtest验证MMIO与生命周期，禁用Rust构建通过。commit message列每个unsafe块的保证，避免把审计散在review回复里。

第四份补丁接RISC-V Machine或文档化命令行创建，包含地址、IRQ和DTB。平台相关代码留`hw/riscv/`，设备crate不认识hart或PLIC。若修改默认Machine，单独讨论兼容；实验Machine可以明确标非上游。

第五份补丁加入IRQ/timer和对应qtest，随后第六份加入VMState与migration test。分开让“设备能运行”“有异步行为”“可迁移”三项各有验收。首个Rust设备历史中迁移独立合入，给这种拆分提供直接先例。

每版回应review写changelog：soundness、API、构建、设备语义、测试分别列。不要把“addressed comments”当完整说明。最终提交清理临时debug与树外假设，保留必要trace和测试；邮件中的未合入方案不进入书中当前源码描述。

## 测试要跨过 FFI

纯Rust单测构造任意offset、size和data，覆盖所有状态分支，运行快。它应完全不需要QEMU生成bindings，方便发现逻辑bug。若为了复用QEMU类型把整个sys crate拉入，单测又失去独立性；在边界用本地窄类型转换更清楚。

Rust集成测试验证QOM macro、VMState builder和wrapper元数据，通过Meson运行。当前`vmstate_tests`直接检查字段offset/flags，说明上游也把生成的C结构作为测试对象。新增wrapper测试应故意构造错误或边界，不能只实例化成功。

qtest第一次真正穿过C/Rust回调。QEMU C memory core调用Rust extern wrapper，再进入设备状态；断言寄存器与IRQ。启用debug cell时，缺BQL或重复borrow会更早panic，因此测试同时跑debug配置。release配置仍跑，确认优化和cfg没有改变行为。

functional test让RISC-V固件/驱动使用设备。教学设备可配一个很小的bare-metal或Linux test module，读取ID、触发操作、等待IRQ、reset后再读。它证明地址、DTB和中断路由，不替代非法MMIO qtest。镜像与源码、hash一起保存。

迁移test让callback和VMState相遇。源端在Busy/pending状态迁移，目标恢复timer与IRQ，再继续MMIO。测试如果只保存Idle，许多字段仍为默认。旧/新版本再验证迁移representation，而不是Ruststruct布局。

fuzz从qtest协议生成操作序列：read/write/reset/clock step/migration边界。每个seed限制长度和时间，crash缩减后加固定回归。目标包括panic、assert、hang与错误外部状态。safe core fuzz通过，FFI层仍可能因opaque/lifecycle崩溃，两层都要跑。

销毁测试反复device_add/device_del（若设备支持热插拔）或重复创建Machine，安排timer后立即reset/unparent，寻找late callback。教学SysBus若不支持动态删除，明确限制，不用不合法QMP命令宣称生命周期通过。对应wrapper的适用范围写进API。

## 性能和等价性

寄存器热路径比较Rust与既有C语义时，固定相同RISC-V工作负载、编译优化和trace。测每次MMIO延迟、吞吐与BQL持有时间，分开callback trampoline、borrow检查和设备逻辑。debug cell检查可能在release优化掉，报告构建类型，不能拿debug Rust对release C下结论。

生成代码大小和链接时间也值得记录。crate拆分旨在减少头文件变化引发的全量重编，可通过触碰一个wrapper header测增量；最终二进制体积受LTO、panic策略与重复monomorphization影响。一次数据只能说明该配置，更新工具链后重测。

行为等价比速度更先。若替换已有设备，qtest对两实现运行同一寄存器序列，比较读值、IRQ、trace和迁移流；规范允许差异的部分单列。书中设备是新教学模型，没有C oracle，就用独立规格函数和真实RISC-V驱动判据。

性能优化不能扩大unsafe。为省一次borrow而缓存裸指针，为省BQL而随意标Sync，短基准可能变快，生命周期证明已破坏。优化提交写原不变量、变化后的同步与回归压力；没有证据时保留清楚边界更划算。

## 威胁模型与故障隔离

客户机控制MMIO值、队列地址、长度、触发频率和时序，可以多vCPU并发访问，也能在reset/迁移附近制造边界。宿主配置者控制QOM properties、后端路径和热插拔。迁移流可能来自受信集群，也可能损坏；三类输入分别校验，不能因为Rust代码safe就信任。

攻击目标包括越界/整数溢出、use-after-free、数据竞争、死锁、资源耗尽、panic/abort和信息泄露。safe core主要减少前两类的局部机会，FFI和unsafe仍可能重新引入；BQL有助竞争，锁序仍可能死锁；限额与错误路径负责资源；日志脱敏负责泄露。每个测试映射到一类风险。

设备读取guest memory或DMA时，GPA到host pointer必须走QEMU Memory API/IOMMU，不能从guest整数构造slice。长度先限额并checked add，映射可能分段或失败，访问完成后释放。教学第一版没有DMA，文档明确不支持；未来加入时应扩展安全API和独立章节，不在MMIO callback里临时unsafe。

FFI字符串和数组同样受限。C给出的指针只有在长度和生命周期保证下才能变slice，NUL字符串也要验证；Rust生成给C长期保存的数据必须拥有稳定存储。临时Vec/CString离开scope后指针失效，是常见跨语言悬空。

错误隔离优先让单个虚拟机收到设备错误或管理层拒绝，不让宿主进程panic。某些QEMU内部不变量破坏确实应abort，前提是guest无法直接触发。review逐个assert追输入来源，fuzzer验证。把所有assert改Result也不对，内部soundness破坏继续运行可能扩大损害。

日志和trace避免输出完整guest buffer、host pointer或后端秘密。对象相关可用稳定ID/offset，数据只输出长度和有限摘要。Rust `Debug` derive很方便，却可能把整个结构和敏感字段打印；生产日志手写格式。故障报告保留版本与状态，不泄露payload。

## 审查当前 API 状态，而非想象未来

`docs/devel/rust.rst` 的状态表是锚点事实：不同模块成熟度不同，且文档明确说API稳定性不是永久承诺，unsafe接口未来可能被safe替换。使用者要引用具体模块和tag，不能说“QEMU Rust API已经稳定”或“都只是实验”。

当前重点是safe SysBusDevice，文档把PCI、DMA、整板与后端列为以后可能扩展的方向。这是一条上游范围陈述。RISC-V教学设备选择简单SysBus、无DMA，正好落在当前能力中心；若需求本来是PCIe加速器，不能为追求Rust强行套用尚未表达的wrapper。

源码中的TODO/FIXME属于开放问题，不自动承诺实现日期。比如GuestAddress类型、更多virtual method或初始化reference改进，说明维护者已识别边界；书稿可以解释当前 workaround，不能以TODO设计未来API。新tag若解决，再沿commit和review更新。

一个wrapper标safe，仍要读safety foundation。`SysBusDevice::init_mmio` assert BQL，`MemoryRegionOps<T>`要求T: Sync，QOM cast依赖unsafe IsA，Owned drop依赖BQL。safe方法把调用者unsafe移到底层，底层证明必须持续成立。API review从这些unsafe impl开始，比只数设备代码中的unsafe更有效。

开放问题应带实现条件。AioContext cell需要明确线程/锁契约，DMA slice需要映射生命周期，PCI config需要QOM/qdev层次和迁移，panic策略需要整个QEMU构建决定。条件未满足前，书中实验停在可审计范围，不用占位代码制造“支持”。

## RISC-V 集成的验收边界

第一条边界是设备与架构解耦。crate 只实现寄存器、MemoryRegion、IRQ source 和迁移，`hw/riscv/` 的本地补丁选择 base address、interrupt source、DTB compatible 与 hart 路由。审查时 `rg 'RISCV|hart|PLIC|APLIC' rust/device` 应只命中必要文档或没有命中；平台知识若进入状态机，说明层次泄漏。

第二条边界是客户机描述一致。Machine 创建了设备，DTB 也要给相同地址、size、IRQ 与 compatible；命令行可选时，设备 absent 不应留下幽灵节点。functional test 从客户机读取设备树，再访问寄存器。只在 QOM tree 看到对象，不能证明 RISC-V 软件能发现。

第三条边界是 accelerator 中立。简单 MMIO SysBus 设备原则上可被 TCG 与 KVM 客户机访问，实际 IRQ 后端和线程路径可能不同。先在 TCG 完成可移植测试；具备 RISC-V KVM 宿主时再跑同一 qtest/guest，记录 irqchip 模式。TCG 通过不替代 KVM，KVM 缺环境写 skip，不改成 pass。

第四条边界是 reset 与启动。OpenSBI、内核和设备可能经历多次 reset，Rust 对象不能假设仅在进程创建时初始化。客户机在 reset 前置非默认状态，Machine reset 后核对寄存器和 IRQ，再继续一次操作。若 timer callback跨 reset 到达，generation 或取消协议应阻止旧结果污染新周期。

第五条边界是迁移。固定锚点的 RISC-V `virt` 没有常见版本化 Machine 入口，教学设备先承诺同构建、同配置往返。流字段和版本仍按长期 ABI设计，以便未来双二进制测试；当前实验结果不写成上游跨版本保证。设备若尚未 VMState 闭环，应在管理层明确不可迁移。

第六条边界是退出和错误。非法 property 在 realize 失败，非法 MMIO 不 panic，目标 load 损坏流在 vCPU 前拒绝，禁用 Rust 的 riscv64 构建仍工作。四条完整清晰、可重复的负面用例常比一次正常启动更能证明渐进接入没有把宿主稳定性押在新语言路径上。

## 实验一：审计一条 C/Rust 回调

::: {.hands-on}
配套英文实验手册：[`inspect-c-rust-boundary`](../experiments/part-05-engineering-and-evolution/chapter-23-rust-device-modeling/inspect-c-rust-boundary/README.md)。

从锚点的 `rust/system/src/memory.rs` 选择 MMIO read callback，沿 `MemoryRegionOpsBuilder`、泛型 extern C wrapper、opaque cast、`MemoryRegion::init_io()` 到 C `memory_region_init_io()`。在表中记录指针来源、动态类型、对齐、owner 存活、BQL/线程、alias、panic 与错误语义，给每项标“类型保证、运行断言、C 契约或待验证”。

再选择 SysBus `init_mmio` 或 `connect_irq`，确认当前 wrapper 的 BQL 断言与 `Owned<IRQState>` 生命周期。运行 Meson 实际列出的 Rust 测试，保存构建配置；不要用普通 Cargo 结果替代完整 QEMU 测试。最终提出一项能缩小 unsafe 的改进，先验证不会排除 RISC-V 教学设备所需语义。
:::

## 实验二：构建 RISC-V Rust 设备骨架

::: {.hands-on}
配套英文实验手册：[`build-rust-device-skeleton`](../experiments/part-05-engineering-and-evolution/chapter-23-rust-device-modeling/build-rust-device-skeleton/README.md)。

先在独立实验 crate 运行 `cargo fmt --check`、clippy 与四个 unit tests，阅读寄存器 offset、访问校验、reset 和只读位。正文用中文说明哪些不变量由 Rust 类型/测试保证，哪些仍是设备协议。该阶段不声称存在 QOM、IRQ、DMA 或迁移支持。

可选集成在一次性 QEMU worktree 中完成：增加 `#[repr(C)]` QOM SysBus 类型、BqlRefCell 状态、一个 32 位小端 MemoryRegion 与 reset，Meson/Kconfig 仅在明确选择时构建；再由本地 RISC-V `virt` 变体映射地址和 IRQ。先加 qtest 合法/非法访问与 reset，后续 patch 才加 IRQ、timer 和 VMState。每一步保留 C/Rust 审计表与禁用 Rust 构建结果。
:::

## 证据边界与开放问题

固定源码能确认 Meson/rustc 构建、Cargo lint/workspace、`*-sys` bindings、QOM/MemoryRegion/BQL/VMState wrapper 的当前实现。2024 初始系列与后续 crate 重排 commit 能解释若干明确动机。由此推断“渐进接入优先封装可复用不变量”很有根据，仍属于作者总结。

开放问题包括 PCI/DMA 等更多设备类型的安全 API、AioContext 对应的 interior mutability、Rust API 稳定策略、panic 边界、跨语言 sanitizer 和 RISC-V 上游设备案例。当前文档把部分模块标为 proof of concept，后续 tag 可能快速变化；实验始终使用锚点 API，树外教学代码不宣称已上游。

::: {.source-path}
当前集成从 [`docs/devel/rust.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/devel/rust.rst)、[`rust/Cargo.toml`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/rust/Cargo.toml)、[`rust/meson.build`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/rust/meson.build)、[`rust/bindings/`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/rust/bindings)、[`rust/qom/`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/rust/qom)、[`rust/system/`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/rust/system)、[`rust/bql/`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/rust/bql)、[`rust/migration/`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/rust/migration) 与 [`rust/hw/core/`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/rust/hw/core) 读取。平台装配和客户机实例限定 RISC-V/riscv64。
:::

## 小结

Rust 进入 QEMU 后，最有价值的变化远超文件扩展名：可反复检查的不变量有了更集中的表达。QOM 父类布局、初始化 token、引用计数、BQL cell、typed MemoryRegion callback 和 VMState builder 把一部分 C 契约带进类型与测试；每个 unsafe trait 和 extern callback 仍要说明 C 侧保证。

RISC-V 教学设备把边界缩到可审查范围：安全状态 crate 处理寄存器，薄适配层接 QOM/SysBus，Machine 负责地址与 IRQ，迁移显式选择字段。构建、qtest、functional 与迁移逐层验证。这样的渐进方案不会承诺语言自动解决生命周期和 ABI，却能让错误集中、证据清晰，也更符合 QEMU 在固定锚点中的实际演进。
