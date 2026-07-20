# 第一篇证据账本：QEMU 起点、机器契约与公共边界

本账本服务 `chapter1.md` 至 `chapter6.md`。正文源码事实固定在 QEMU `v11.1.0-rc0`，tag 指向提交 `eca2c16212ef9dcb0871de39bb9d1c2efebe76be`。历史材料只用于回答当前结构为何出现；没有邮件、提交说明或论文直接支持的动机，保留为综合判断，不替参与者补写观点。

## 证据等级

- **当前事实**：固定 tag 的源码、项目文档或可重复运行结果直接显示。
- **上游陈述**：提交说明、patch revision notes、邮件或论文由当事人明确写出。
- **综合判断**：把多项当前事实与历史材料连接起来的解释，必须同时写出适用边界。
- **开放项**：材料尚不足，正文不得写成确定历史。

角色按具体 patch 记录：`Author`、`Committer`、`Reviewed-by`、`Acked-by`、`Signed-off-by`。这些 trailer 只约束对应版本的补丁，不用来推断某人对整章观点的认可。

## QEMU 用户态起点

| 主张 | 等级 | 一手依据 | 角色与边界 |
|---|---|---|---|
| 2003-03 文档将目标写为在非 x86 Linux 上运行 x86 Linux 进程，并点名 Wine | 上游陈述 | [`386405f78661e0a4f82087196c7b084b8c612b48:qemu-doc.texi`](https://gitlab.com/qemu-project/qemu/-/blob/386405f78661e0a4f82087196c7b084b8c612b48/qemu-doc.texi) | Fabrice Bellard，作者与提交者；文档也明确当时不能启动 OS |
| 初始边界同时包含 CPU 动态翻译与 Linux syscall/signal/clone 转换 | 当前事实＋上游陈述 | 同一份 `qemu-doc.texi` 的 “QEMU Internals” | 适用于 2003 user-mode；当前 RISC-V 路径需另由固定 tag 核验 |
| 多指令翻译与 translation cache 在 2003-03 已出现 | 当前事实 | [`1017ebe9cb38ae034b0e7c6c449abe2c9b5284fb`](https://gitlab.com/qemu-project/qemu/-/commit/1017ebe9cb38ae034b0e7c6c449abe2c9b5284fb)、[`7d13299d07a9c3c42277207ae7a691f0501a70b2`](https://gitlab.com/qemu-project/qemu/-/commit/7d13299d07a9c3c42277207ae7a691f0501a70b2) | 提交说明极短，只证明动作与时间，不足以单独证明完整性能动机 |
| 测试基础和 hello world 与早期实现同期出现 | 当前事实 | [`ba1c6e37fc5efc0f3d1e50d0760f9f4a1061187b`](https://gitlab.com/qemu-project/qemu/-/commit/ba1c6e37fc5efc0f3d1e50d0760f9f4a1061187b)、[`0ecfa9930c7615503ba629a61f7b94a0c3305af5`](https://gitlab.com/qemu-project/qemu/-/commit/0ecfa9930c7615503ba629a61f7b94a0c3305af5) | Fabrice Bellard；早期文档说明 `test-i386` 与真实 CPU 输出做差分 |
| 动态翻译、ABI 转换共同构成 user-mode 边界 | 综合判断 | 上述文档与当前 RISC-V `cpu_loop.c` | 用于解释边界，不声称这是上游原句 |

### 当前 RISC-V 落点

- 入口与装载：[`linux-user/main.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/linux-user/main.c)、[`linux-user/elfload.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/linux-user/elfload.c)。
- 系统调用：[`linux-user/riscv/cpu_loop.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/linux-user/riscv/cpu_loop.c) 在 `RISCV_EXCP_U_ECALL` 路径读取目标寄存器并调用 `do_syscall()`；通用转换位于 [`linux-user/syscall.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/linux-user/syscall.c)。
- 目标地址与信号：[`linux-user/mmap.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/linux-user/mmap.c)、[`linux-user/riscv/signal.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/linux-user/riscv/signal.c)。
- 指令翻译：[`target/riscv/tcg/translate.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/tcg/translate.c)。
- 验证范围：user-mode 不创建 RISC-V `virt`、PLIC、UART 或 DTB；系统调用覆盖以当前实现和构建目标为准。

## 从进程到完整系统

| 主张 | 等级 | 一手依据 | 角色与边界 |
|---|---|---|---|
| 2003-06-24 的 `vl.c` 已含 Linux 启动参数、RAM、PIC、PIT 与串口 | 当前事实 | [`0824d6fc674084519c856c433887221be099c549`](https://gitlab.com/qemu-project/qemu/-/commit/0824d6fc674084519c856c433887221be099c549) | Fabrice Bellard；初始代码有专有演示声明，不能套用当前架构 |
| QEMU 0.4 宣布可启动 Linux kernel、模拟串口和 NE2000，并给出 kernel testing/debugging 与 virtual hosting 用途 | 上游陈述 | [QEMU 0.4 release 邮件](https://lists.gnu.org/archive/html/qemu-devel/2003-06/msg00123.html) | Fabrice Bellard；邮件脚注明确仍需改两个字节重映射内核 |
| 2005 年 QEMU 已同时支持 full-system 与 Linux user-mode，并列出跨 OS、调试、嵌入式设备模拟和交叉编译器测试用途 | 上游陈述 | [Bellard, “QEMU, a Fast and Portable Dynamic Translator”](https://www.usenix.org/conference/2005-usenix-annual-technical-conference/qemu-fast-and-portable-dynamic-translator) | Fabrice Bellard；论文主要讨论翻译器，系统用途与子系统描述可直接引用 |
| 完整系统出现是因为目标内核需要特权 CPU、物理地址、中断、时间和设备 | 综合判断 | 0.4 源码、邮件、2005 论文与当前启动路径 | 这是从需求与实现连接出的解释，正文不写成 Bellard 原话 |

### 当前 RISC-V 启动落点

- 进程入口与配置：[`system/main.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/system/main.c)、[`system/vl.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/system/vl.c)。
- Machine 装配：[`hw/riscv/virt.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/virt.c)。
- 固件、内核、initrd、FDT 与 reset vector：[`hw/riscv/boot.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/boot.c)。
- 当前生态边界：[`docs/system/introduction.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/system/introduction.rst)说明 Machine、accelerator、virtio/vhost/VFIO、QMP 与 libvirt 的关系。

## RISC-V `virt` 的机器契约

| 主张 | 等级 | 一手依据 | 角色与边界 |
|---|---|---|---|
| `virt` 于 2018 年以 DT、CLINT、PLIC、16550A 和 virtio-mmio 的合成平台引入 | 当前事实 | [`04331d0b56a0cab2e40a39135a92a15266b37c36`](https://gitlab.com/qemu-project/qemu/-/commit/04331d0b56a0cab2e40a39135a92a15266b37c36) | Author/Committer Michael Clark；Acked-by Richard Henderson；Signed-off-by Palmer Dabbelt 与 Michael Clark |
| 当前 `virt` 不对应真实硬件，并要求客户机通过生成 DTB 发现设备 | 上游陈述 | [`docs/system/riscv/virt.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/system/riscv/virt.rst) | 固定 tag 项目文档；选项与默认值只适用于该版本 |
| Machine 契约需让地址图、对象连接与 FDT/ACPI 描述互相一致 | 综合判断 | `virt_memmap[]`、`virt_machine_init()`、`create_fdt()`/`finalize_fdt()` | 适用于当前 `virt`；周期精确和实体板勘误超出该 Machine 文档承诺 |
| `virt` 在当前基线没有公开逐版本 Machine 名称 | 当前事实 | `virt_machine_typeinfo` 注册 `MACHINE_TYPE_NAME("virt")`；`-machine help` 可验证 | 不由此推导“没有兼容责任”；非版本机型仍适用通用弃用与用户可见行为审查 |

兼容性参考：[`docs/devel/migration/compatibility.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/devel/migration/compatibility.rst)说明迁移两端需匹配 Machine 类型与硬件配置。正文只用它解释兼容机制，不宣称当前 RISC-V `virt` 提供所有跨版本迁移组合。

## QOM 与生命周期

| 主张 | 等级 | 一手依据 | 角色与边界 |
|---|---|---|---|
| 基础 Object class 受 GObject 启发，v2 根据 Paolo Bonzini 的多项建议调整类型表、接口与缓存 | 上游陈述 | [`2f28d2ff9dce3c404b36e90e64541a4d48daf0ca`](https://gitlab.com/qemu-project/qemu/-/commit/2f28d2ff9dce3c404b36e90e64541a4d48daf0ca) | Author/Committer Anthony Liguori；v2 notes 记录 Paolo 的建议，无 `Reviewed-by: Paolo`，角色不扩大 |
| property 从 qdev 下沉到 Object，使 Object 能在 qdev 外使用 | 上游陈述 | [`57c9fafe0f759c9f1efa5451662b3627f9bb95e0`](https://gitlab.com/qemu-project/qemu/-/commit/57c9fafe0f759c9f1efa5451662b3627f9bb95e0) | Anthony Liguori |
| CPUState 作为抽象 QOM CPU class 引入并准备虚拟 reset | 上游陈述 | [`dd83b06ae61cfa2dc4381ab49f365bd0995fc930`](https://gitlab.com/qemu-project/qemu/-/commit/dd83b06ae61cfa2dc4381ab49f365bd0995fc930) | Author Andreas Färber；Reviewed-by Anthony Liguori |
| QOM 解决运行时类型、属性、共同生命周期；并发与地址连接仍由其他机制负责 | 综合判断 | 当前 QOM/qdev 源码与 RISC-V hart array | 防止把类型检查扩展成线程安全、realized 状态或状态新鲜度保证 |

### 当前 RISC-V 落点

- 类型、class、实例与 ref：[`qom/object.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/qom/object.c)、[`docs/devel/qom.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/devel/qom.rst)。
- qdev realize/unrealize：[`hw/core/qdev.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/core/qdev.c)。
- `virt_machine_typeinfo`：[`hw/riscv/virt.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/virt.c)。
- hart child 创建与 CPU realize：[`hw/riscv/riscv_hart.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/riscv_hart.c)、[`target/riscv/cpu.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/cpu.c)。

## MemoryRegion 与地址图

| 主张 | 等级 | 一手依据 | 角色与边界 |
|---|---|---|---|
| Hierarchical MemoryRegion API 将 region 属性同位置/enabled 分开，并支持父总线映射和子区域组合 | 上游陈述 | [`093bc2cd885e4e3420509a80a1b9e81848e4b8fe`](https://gitlab.com/qemu-project/qemu/-/commit/093bc2cd885e4e3420509a80a1b9e81848e4b8fe) | Author Avi Kivity；Reviewed-by/Committer Anthony Liguori |
| Transaction 让多项层次变化一次可见，并减少 accelerator 参与时的重复计算 | 上游陈述 | [`4ef4db860362ce9852c20b343e9813897ecdefce`](https://gitlab.com/qemu-project/qemu/-/commit/4ef4db860362ce9852c20b343e9813897ecdefce) | Avi Kivity；Signed-off-by Anthony Liguori |
| 物理图观察 API用于通知 region/logging 变化，后来成为 listener 边界 | 当前事实＋上游陈述 | [`7664e80c84700d8b7e88ae854d1d74806c63f013`](https://gitlab.com/qemu-project/qemu/-/commit/7664e80c84700d8b7e88ae854d1d74806c63f013) | Avi Kivity；“后来成为”需由当前 MemoryListener 实现核验 |
| `current_map` 改由 RCU 保护，以避免大型系统/多 IOThread 的 futex 争用 | 上游陈述 | [`374f2981d1f10bc4307f250f24b2a7ddb9b14be0`](https://gitlab.com/qemu-project/qemu/-/commit/374f2981d1f10bc4307f250f24b2a7ddb9b14be0) | Author/Committer Paolo Bonzini；Reviewed-by Fam Zheng |
| MemoryRegion 配置图、FlatView 执行快照、RAMBlock 后备身份承担不同职责 | 综合判断 | 当前 `system/memory.c`、`system/physmem.c` 与文档 | RCU 只保护视图读者；设备回调、DMA 和 Object 生命周期需额外收束 |

当前落点：[`system/memory.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/system/memory.c)、[`system/physmem.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/system/physmem.c)、[`docs/devel/memory.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/devel/memory.rst)、RISC-V `virt_memmap[]` 和板级映射。

## Accelerator、线程与状态所有权

| 主张 | 等级 | 一手依据 | 角色与边界 |
|---|---|---|---|
| `AccelClass` 处理实例/Machine 级回调，`AccelOpsClass` 抽象 vCPU 创建、kick、中断、reset、同步、时钟与调试 | 当前事实 | [`include/accel/accel-ops.h`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/include/accel/accel-ops.h)、[`include/accel/accel-cpu-ops.h`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/include/accel/accel-cpu-ops.h) | 不是所有可选回调都由每个后端实现；能力需逐项核验 |
| 同步接口明确区分 QEMU 为参考与 accelerator 为参考 | 当前事实 | `AccelOpsClass` 头文件注释 | `post_reset/post_init` 推向后端；`synchronize_state/pre_loadvm` 从后端取回 |
| BQL 旧 API 的 `iothread` 名称来自早期 KVM vCPU/main-loop 分离，后与 `--object iothread` 产生歧义 | 上游陈述 | [`195801d700c008b6a8d8acfa299aa5f177446647`](https://gitlab.com/qemu-project/qemu/-/commit/195801d700c008b6a8d8acfa299aa5f177446647)；Message-ID `20240102153529.486531-2-stefanha@redhat.com` | Author/Committer Stefan Hajnoczi；Reviewed-by Paul Durrant、Cédric Le Goater、Harsh Prateek Bora、Akihiko Odaki；另有多项 Acked-by |
| `AccelState` 显式传给 `init_machine()`，减少 `current_accel()` 隐式依赖 | 上游陈述 | [`9d01d2e86d450f12f275bd64aeb022e8423e220c`](https://gitlab.com/qemu-project/qemu/-/commit/9d01d2e86d450f12f275bd64aeb022e8423e220c) | Author Philippe Mathieu-Daudé；Reviewed-by Richard Henderson、Alex Bennée、Zhao Liu |
| `AccelClass` 持有 `AccelOpsClass` 引用 | 当前事实＋上游陈述 | [`487b25c9d93add2e0e58275d7c1ef89810fad763`](https://gitlab.com/qemu-project/qemu/-/commit/487b25c9d93add2e0e58275d7c1ef89810fad763) | 同一作者与 reviewer |
| `CPURISCVState` 是公共架构表示，TCG/KVM 运行时权威副本与新鲜度不同 | 综合判断 | RISC-V TCG/KVM 源码、同步接口、`system/cpus.c` | 读取任意字段前仍需检查具体同步点；不宣称所有字段遵循同一 eager/lazy 策略 |

### 当前 RISC-V 落点

- CPU realize 与能力收敛：[`target/riscv/cpu.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/cpu.c)。
- vCPU 创建、queued work 与 BQL：[`system/cpus.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/system/cpus.c)。
- TCG：[`accel/tcg/`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/accel/tcg)、[`target/riscv/tcg/`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/target/riscv/tcg)。
- KVM：[`accel/kvm/`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/accel/kvm)、[`target/riscv/kvm/kvm-cpu.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c)。
- 其他 accelerator 的宿主/架构矩阵以固定 tag [`docs/system/introduction.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/system/introduction.rst) 为准；第一篇不把其机制类推到 RISC-V。

## 实验覆盖与未覆盖项

| 章节 | 可执行入口 | 能证明 | 不能扩展的结论 |
|---|---|---|---|
| 1 | `trace-riscv-virt-boot`，另加本地 `qemu-riscv64 -strace` 对照 | 两种边界的入口与 I/O 路径 | 单个 hello 不能证明全部 syscall/signal/atomic |
| 2 | `stop-at-reset-vector`、`inspect-cli-to-machine` | 配置消费阶段、reset PC 与启动交接 | 缺少 KVM 宿主时不能声称动态验证 KVM boot |
| 3 | `trace-riscv-virt-boot` 加 DTB/QOM/mtree 对照 | 本次 `virt` 配置的对象、地址和发现信息 | 一次配置不能覆盖全部 Machine 属性组合 |
| 4 | `inspect-qom-tree`、`create-minimal-qom-type` | 类型/组合关系与 ref/finalize | QOM tree 不证明 bus、线程和地址连接 |
| 5 | `map-memory-regions`、`test-overlap-alias-resolution` | 本次 FlatView；显式 priority/alias 模型 | Python 模型不等同完整 QEMU renderer |
| 6 | `inspect-accelerator-contract`、`map-thread-topology` | 回调边界；当前主机的线程拓扑 | 静态 KVM 调用图不能冒充 RISC-V KVM 实机结果 |

开放项：本账本尚未找到 2003 年最初 user-mode 与 full-system 切换的完整 review 邮件链，正文只引用作者文档、合入代码和发布邮件；RISC-V `virt` 具体地址选择若没有提交说明，不写成某位维护者的设计理由。
