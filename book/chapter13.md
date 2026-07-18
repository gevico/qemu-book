# Linux KVM 与 QEMU RISC-V 加速器

H 扩展规定处理器如何运行虚拟监督态，Linux KVM 把这些能力组织成文件描述符、ioctl 和共享运行页，QEMU 再把 machine、CPU model、内存与设备接到 KVM。三层缺一不可：硬件负责直接执行与二阶段转换，内核负责调度、状态和隔离，QEMU负责客户机配置与用户态设备语义。`KVM_RUN` 看起来只是一次 ioctl，实际是一条不断在三层之间移交状态所有权的循环。

本章仍以 `riscv64` 为主，目标版本为 QEMU `v11.1.0`，当前源码锚为 `v11.1.0-rc0` 的 [`eca2c162`](https://gitlab.com/qemu-project/qemu/-/commit/eca2c16212ef9dcb0871de39bb9d1c2efebe76be)。源码事实只来自该固定标签；历史提交使用 QEMU 官方 GitLab；patch 版本与 review 使用 qemu-devel 或 Patchew。上一章建立的四层能力矩阵继续有效：宿主 H 加速 L0、向 L1 暴露 H、L1 运行 L2、nested migration 必须分别验证。

## 本章目标

- 理解 `/dev/kvm`、VM fd、vCPU fd 和 `struct kvm_run` 的生命周期；
- 跟踪 RISC-V CPU 从 QOM instance、scratch vCPU 探测到真实 `KVM_RUN`；
- 分清通用 KVM 层与 `target/riscv/kvm/kvm-cpu.c` 的责任；
- 解释 one-reg、`vcpu_dirty` 和延迟同步背后的状态所有权；
- 从初始 KVM 支持、目录拆分和 capability 探测演进中还原当前结构。

## 三层边界先于调用链

物理 CPU 知道 H 的特权状态、G-stage 和 trap 条件，却不知道 QEMU 的 UART、virtio 队列或迁移流。Linux KVM 知道进程创建了一个虚拟机、哪些用户页注册成 guest RAM、每个 vCPU 的寄存器与运行状态，却不负责解析完整 QEMU machine 命令行。QEMU知道用户选择了 `virt`、多少 hart、哪种 AIA、哪些磁盘和网卡，却不直接安排物理 hart 进入 VS-mode。

因此，“KVM 加速 QEMU”不是把 QEMU设备模型搬进内核。更准确的表述是：QEMU把可直接执行的 CPU 和 RAM 热路径委托给 KVM，遇到内核不能或不应完成的设备与管理语义时再返回用户态。这个边界可以随功能移动，例如 irqchip、ioeventfd 和 vhost 会让更多路径留在内核；边界移动后，配置、调试和迁移协议也必须跟着变化。

在当前源码中，通用机制集中在 [`accel/kvm/kvm-all.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/kvm/kvm-all.c) 与 [`accel/kvm/kvm-accel-ops.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/kvm/kvm-accel-ops.c)，RISC-V 架构钩子集中在 [`target/riscv/kvm/kvm-cpu.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c)。前者负责打开 KVM、创建 VM/vCPU、映射运行页、注册 memory listener 和处理通用 exit；后者负责 RISC-V 寄存器 ID、ISA 属性、SBI/CSR exit、timer、AIA 与 reset。

:::: {.quick-quiz}
为什么 QEMU 必须在运行时探测 KVM capability，不能根据编译时 `linux-headers` 直接调用？

::: {.quick-answer}
头文件只说明构建时知道哪些 UAPI 编号，实际宿主内核、硬件和配置可能只实现其中一部分。运行时 capability 和 one-reg 探测决定功能能否启用、需要回退还是必须报错；否则同一二进制换到旧内核就会调用不存在或不完整的接口。
:::
::::

## `/dev/kvm`、VM fd 与 vCPU fd

QEMU首先打开 `/dev/kvm`，确认 KVM API，创建一个 VM fd。VM fd 表示共享地址空间、memory slots、irqchip 和 VM 级 capability。每个虚拟 hart 再通过 VM fd 执行 `KVM_CREATE_VCPU`，得到独立 vCPU fd。寄存器、`KVM_RUN`、MP state 等操作以 vCPU fd 为目标。

文件描述符不是普通编号表，它们把对象生命周期交给内核引用计数。关闭 vCPU fd 释放相应内核对象，关闭 VM fd 终止 VM 级资源。QEMU 在热拔、重建或错误回滚中必须按顺序解除映射并关闭 fd；只释放用户态 `CPUState` 会留下内核资源，只关闭 fd 却保留可访问的 `kvm_run` 指针会造成悬空映射。

每个 vCPU fd 对应一块由 `KVM_GET_VCPU_MMAP_SIZE` 决定大小的共享区域，QEMU通过 [`map_kvm_run()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/kvm/kvm-all.c#L650) 映射到 `cpu->kvm_run`。进入前，用户态可以设置输入字段；退出后，内核在同一结构写 `exit_reason` 及 MMIO、SBI、debug 等联合体。共享页避免每次 exit 再复制一大块可变参数，但双方必须遵守字段只在何时有效的 UAPI协议。

`KVM_RUN` 是 vCPU fd 上的阻塞 ioctl。它不保证“运行一条指令”，而是尽量持续执行，直到需要用户态、收到信号、出现调试事件或其他退出条件。一个高效 workload 可能在一次 `KVM_RUN` 中执行很久；一个频繁访问用户态 MMIO 的 workload 会反复进出。

## KVM 初始化与 machine 初始化如何交错

KVM accelerator 的 QOM class 把 `init_machine` 指向通用 [`kvm_init()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/kvm/kvm-all.c)。它建立 `KVMState`、打开设备、创建 VM、探测 capability、决定 irqchip 策略，并注册 KVM memory listener。随后 machine 和设备 realization 创建 AddressSpace、RAM 与 MMIO，listener 把合适的 RAM 区间同步成 KVM slots。

RISC-V 的 [`kvm_arch_init()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c#L1555) 当前主要记录 `KVM_CAP_MP_STATE`。`kvm_arch_required_capabilities` 没有列出额外硬性 capability，意味着很多功能通过后续按需探测决定，而不是在 accelerator 初始化一开始统一拒绝。这个策略让较旧内核仍可运行基础配置，也把错误处理分散到具体功能启用点。

通用 `kvm_init()` 在允许 kernel irqchip 时调用架构钩子。RISC-V 的 `kvm_arch_irqchip_create()` 检查 `KVM_CAP_DEVICE_CTRL`，真正的 RISC-V AIA device 要等 `virt` machine 知道 hart、地址布局和 `aia-guests` 后由 `kvm_riscv_aia_create()` 配置。这说明“内核支持 irqchip”与“某个 machine 已创建 AIA”是两个阶段。

## 为什么还要创建 scratch vCPU

CPU QOM 属性需要在用户解析 `-cpu` 和 machine realize 期间可见，但真实 vCPU 的创建通常发生在 vCPU 线程启动时。RISC-V KVM 又需要先问内核：宿主支持哪些 ISA 扩展、SATP 模式、vendor/arch/imp ID、Vector 长度、SBI extension 和 CSR one-reg。若等真实 vCPU 已完全创建才发现用户要求不兼容，错误出现得太晚，machine 已经部分 realize，回滚复杂。

当前实现引入 [`KVMScratchCPU`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c#L956)，保存临时的 KVM、VM 和 vCPU fd。[`kvm_riscv_create_scratch_vcpu()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c#L966) 独立打开 `/dev/kvm`，执行 `KVM_CREATE_VM`、`KVM_CREATE_VCPU`；探测完成后关闭三者。它不会运行客户机，只借助真实内核 vCPU对象访问 capability-dependent one-reg。

scratch 方案的代价是实例初始化期间会创建临时内核对象，而且多 CPU 属性共享的探测结果需要一致。收益是探测走与真实 vCPU 相同的 UAPI，不维护另一套“猜测宿主能力”的接口。它也允许 QEMU在构造用户可见 CPU 属性时，把 KVM 不认识的扩展标成 unavailable。

[`riscv_init_kvm_registers()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c#L1320) 的顺序是读取 machine IDs、MISA mask、多扩展与 CSR配置、最大 SATP mode。顺序有依赖：只有知道 Vector 存在，才读取 `vlenb`；只有在 register list 中发现某个 CSR，后续 get/put 才访问它。

## `KVM_GET_REG_LIST` 与兼容回退

早期实现会为每个已知扩展调用 `KVM_GET_ONE_REG`，用 `EINVAL` 判断不支持。扩展数量增加后，这种探测变成大量 ioctl，也难区分“ID 不存在”和其他错误。当前 [`kvm_riscv_init_cfg()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c#L1231) 先以零长度调用 `KVM_GET_REG_LIST`，由内核返回所需数量，再分配数组、读取并排序，之后用二分查找确认扩展和 CSR是否存在。

旧内核可能不支持 `KVM_GET_REG_LIST`。代码把 `EINVAL` 解释成需要 legacy 路径，回退到逐个读取；第一次返回 `E2BIG` 则是查询长度的正常协议。其他 errno 视为真实失败。这段分支体现兼容 UAPI 的常见写法：同一个错误码只有结合调用阶段才有意义，不能把所有负返回都静默当作“不支持”。

寄存器列表只告诉 QEMU某个 ID 存在，扩展的当前开关值仍需 `KVM_GET_ONE_REG`。QEMU将结果写入 `KVMCPUConfig.supported` 和 `RISCVCPUConfig`，再创建 QOM bool 属性。这样 `-cpu ...,zba=off` 等用户选择最终可以映射到 KVM ISA extension one-reg。

:::: {.quick-quiz}
scratch vCPU 为什么不直接复用将来要运行的真实 vCPU？

::: {.quick-answer}
CPU 属性和兼容性需要在真实 vCPU 线程创建之前确定，machine realize 失败也应尽早报告。scratch vCPU提供与真实内核对象相同的探测接口，却不绑定客户机运行生命周期；探测完即可销毁，避免为获得属性而提前启动完整 vCPU。
:::
::::

## RISC-V CPU 属性进入 KVM

[`KVMCPUConfig`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c#L134) 把属性名、描述、QEMU字段偏移、KVM register ID、字段宽度、`user_set` 和 `supported` 放在一起。单字母 MISA 扩展与多字母扩展使用不同表，因为 Linux KVM UAPI 的 ID 和开关方式不同，但对用户都表现为 CPU 属性。

H 位于 `kvm_misa_ext_cfgs`，映射 `RVH` 到 `KVM_RISCV_ISA_EXT_H`。setter 允许用户保持宿主值或请求关闭宿主已有位，拒绝启用宿主没有的位。realize 时 [`kvm_riscv_update_cpu_misa_ext()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c#L205) 才对真实 vCPU执行 `KVM_SET_ONE_REG`。多字母扩展也记录用户是否显式修改，避免把每个宿主默认值重复写回。

这个方向性约束有明确理由。TCG 可以通过软件实现宿主没有的指令，KVM 的普通执行则依赖宿主硬件和内核；QEMU不能仅修改设备树字符串就创造硬件语义。关闭某扩展通常是为了构造可迁移的共同 CPU 集合或测试兼容性，但即使关闭也要确认内核允许，并且相关依赖扩展不会留下不一致。

CPU type `host` 在 [`riscv_kvm_cpu_type_infos`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c#L2151) 注册。当前 `virt` machine 的 class 默认 CPU 仍是基础 `rv64`/`rv32` 类型，KVM accel 的 instance hook 会为 CPU注入宿主探测属性。`host` 类型在真实 vCPU初始化时跳过写 machine IDs，其他 CPU type 可以把配置的 vendor/arch/imp ID 写给 KVM。不能把“使用 KVM”与“命令行必然是 `-cpu host`”混为一谈。

QEMU当前还把 RISC-V profile 属性标为 KVM unavailable，因为所需的 KVM profile 支持没有建立。profile 是一组带版本语义的能力契约，不等同于若干 bool 恰好为真；没有内核接口前，QEMU宁可拒绝 profile 名称，也不应伪装成已经满足。

## CPU realize 的双分支

[`riscv_cpu_realize()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/cpu.c) 先进入通用 CPU realize，再调用 `riscv_cpu_finalize_features()`。后者按当前 accelerator 分支：TCG 进入 TCG feature finalize 和 decoder 构造，KVM 进入 [`riscv_kvm_cpu_finalize_features()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c#L2029)。同一个 `RISCVCPU` 对象因此共享 machine/ISA 配置入口，但不会同时激活两套执行实现。

KVM finalize 对 CBO block size 和 Vector length 做宿主一致性检查。用户可以选择是否启用扩展，却不能让 KVM vCPU使用与宿主不兼容的 `vlen` 或 cache-block size。Vector 存在时，KVM CPU realize 还通过 `prctl(PR_RISCV_V_SET_CONTROL, ...)` 允许 QEMU所在宿主线程使用 Vector state相关接口。失败会中止 realize，而不是等到首次迁移或寄存器同步才暴露。

这种检查位置体现“尽早失败”。若属性在启动后才发现不可实现，客户机可能已经看到 FDT 并开始运行，管理层很难把错误解释成配置问题。realize 把用户意图、宿主能力和 machine 约束收敛成不可再随意改变的 vCPU 配置。

## `virt` machine 在 KVM 下怎样启动 hart

`virt_machine_init()` 创建 `RISCVHartArrayState`，为每个 socket 设置 `cpu-type`、`hartid-base` 和 `num-harts`，随后 [`riscv_harts_realize()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/riscv_hart.c#L142) 实例化每个 `RISCVCPU`。CPU QOM instance 阶段触发前述 KVM探测，device realize 阶段完成 feature 校验。

KVM 当前只支持直接启动 kernel。[`virt_machine_done()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/virt.c#L1202) 在 KVM 下拒绝非 `none` 的 machine-mode firmware，并把 firmware 设置成 `none`；加载 kernel 和 FDT 后调用 [`riscv_setup_direct_kernel()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/boot.c#L533)，为所有 CPU保存入口与 FDT 地址。

reset 时 [`kvm_riscv_reset_vcpu()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c#L1754) 清 GPR，设置 PC 为 kernel entry、`a0` 为 vCPU/hart ID、`a1` 为 FDT 地址，并把监督态 CSR复位、`priv` 设为 S。若支持 MP state，CPU 0设为 runnable，其他 CPU为 stopped，后者由 SBI HSM 或相应启动协议唤醒。

直接启动是当前实现边界，不是 RISC-V 架构要求。它减少 QEMU/KVM 对 M-mode firmware 状态的模拟与迁移，也意味着 KVM 与 TCG 的启动路径并不完全相同。比较两种 accelerator 时，必须把 firmware 差异列入环境，不能把启动时长差全部归因于执行引擎。

## vCPU 线程从哪里开始

KVM accelerator 在 [`kvm_accel_ops_class_init()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/kvm/kvm-accel-ops.c#L95) 把 `create_vcpu_thread` 指向 `kvm_start_vcpu_thread()`。每个 CPU得到名为 `CPU n/KVM` 的线程，入口 [`kvm_vcpu_thread_fn()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/kvm/kvm-accel-ops.c#L31) 注册 RCU、取得 BQL、建立线程身份，然后调用 `kvm_init_vcpu()`。

[`kvm_init_vcpu()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/kvm/kvm-all.c#L710) 依次执行架构 pre-create、创建或取回 parked vCPU、映射 `kvm_run`、映射可选 dirty ring、调用 `kvm_arch_init_vcpu()`。RISC-V init 注册 VM runstate handler，必要时写 machine IDs，应用 MISA和多扩展开关，并启用 SBI DBCN。

创建完成后线程通知主线程，进入循环：先处理排队的 CPU work；若 `cpu_can_run()`，调用 `kvm_cpu_exec()`；调试 exit 则进入通用 guest debug。直到 CPU被 unplug 且不能再运行，线程才销毁或 park vCPU、解除映射并退出。

这里的 BQL 使用容易误读。vCPU线程入口和事件协调会持有 BQL，但 [`kvm_cpu_exec()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/kvm/kvm-all.c#L3427) 在真正进入运行循环前释放 BQL，使多个 vCPU可并行在内核执行；退出循环后再获取。MMIO handler 的注释明确说明某些路径在 BQL 外调用，因此设备与 AddressSpace 代码必须遵守自己的并发约束。

## `KVM_RUN` 前后发生了什么

`kvm_cpu_exec()` 先处理架构异步事件。若 QEMU侧 `cpu->vcpu_dirty` 表示用户态修改了 CPU镜像，就调用 `kvm_arch_put_registers(..., KVM_PUT_RUNTIME_STATE)` 写回。然后执行 `kvm_arch_pre_run()`，检查 `exit_request`，必要时 self-kick，最后在 vCPU fd 上调用 `KVM_RUN`。

`exit_request` 与 `immediate_exit` 之间使用内存序。另一个线程写退出请求后发信号，signal handler 让 KVM尽快退出；vCPU线程需要保证不会看见“要求立即退出”却看不见对应 QEMU请求。代码中的 acquire/release在用户态原子变量、信号和内核共享页之间建立先后关系，这属于正确性要求。

返回后调用 `kvm_arch_post_run()` 获取架构相关 memory attributes，再检查 ioctl 错误。`EINTR/EAGAIN` 通常表示信号或重试，转成 QEMU中断返回；其他错误可能停止 VM。随后按 `run->exit_reason` 分派：通用层直接处理 IO、MMIO、shutdown、system event、dirty ring full 和 memory fault，未知架构 exit 交给 `kvm_arch_handle_exit()`。

MMIO exit 的读写结果通过共享 `kvm_run` 传递。KVM要求某些 I/O exit 后再次进入内核以完成原指令，因此 QEMU即使已经收到外部退出请求，也可能需要先 re-enter，再尽快被 self-kick 拉出。若在用户态处理完 MMIO 后直接认为客户机指令已经提交，可能破坏精确执行语义。

:::: {.quick-quiz}
KVM exit 次数越少是否一定越好？

::: {.quick-answer}
减少高频无意义 exit 通常提高吞吐，但把状态下沉内核会增加迁移、调试和恢复复杂度，批处理还可能增加延迟。必须同时测量 exit 类型、频率、单次成本、暂停同步成本和 workload 目标，不能只优化一个计数器。
:::
::::

## RISC-V 架构 exit

[`kvm_arch_handle_exit()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c#L1730) 当前处理 `KVM_EXIT_RISCV_SBI`、`KVM_EXIT_RISCV_CSR` 和 `KVM_EXIT_DEBUG`。常规 MMIO不在这个 switch，因为通用 KVM 层已经完成 AddressSpace 分派。

SBI handler 支持 legacy console getchar/putchar 和 Debug Console Extension。DBCN 传入 guest physical 缓冲区，QEMU通过 `cs->as` 的 `address_space_read/write()` 与客户机内存交换，再调用 chardev frontend。32 位 guest 在 64 位地址环境下需要组合两个参数。未处理的 SBI extension 会记录 `LOG_UNIMP` 并返回失败。

CSR exit 当前处理 `CSR_SEED`，用 QEMU随机源相关逻辑生成返回值。把这类 CSR留在用户态，是因为语义需要 QEMU资源或内核尚不直接实现；高频 CSR若全部 exit 会很昂贵，所以 UAPI通常只把必要项目交回用户态。

Debug exit 首先调用 `kvm_cpu_synchronize_state()` 确保 PC 最新，再检查软件断点。调试是状态所有权切换的典型场景：vCPU运行时 PC在内核，GDB需要用户态可靠观察，于是必须先同步，不能直接读陈旧 `env->pc`。

## 状态所有权与 `vcpu_dirty`

KVM运行期间，最新 PC、GPR、CSR、FP和 Vector 在内核/硬件。QEMU保留同名 `CPURISCVState` 作为配置与同步镜像，却不能假定每次 exit 后镜像自动更新。通用 [`kvm_cpu_synchronize_state()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/kvm/kvm-all.c#L3207) 只在 `vcpu_dirty` 为假且客户机状态可读取时，通过目标 vCPU线程调用 `kvm_arch_get_registers()`；成功后把 `vcpu_dirty` 置真，表示用户态镜像现在有效并可能被修改。

再次进入 KVM 时，若镜像 dirty，`kvm_cpu_synchronize_put()` 调用架构 put，成功后清掉标记，表示状态所有权回到内核。这个名字容易反直觉：`dirty`在这里表示 QEMU侧拥有需要写回的有效状态。读代码要结合 get/put 转换判断。

RISC-V [`kvm_arch_get_registers()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c#L1341) 读取 core、探测到的 S CSR、FP和 Vector。core 包括 PC及 x1到 x31；CSR表包括 `sstatus/sie/stvec/sscratch/sepc/scause/stval/sip/satp/scounteren/senvcfg`。timer 不在这里，而由 VM runstate handler 单独同步。

[`kvm_arch_put_registers()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c#L1386) 在 runtime level 写 core 和 CSR后直接返回，不重复写 FP/Vector。源码注释说明，前一次 `KVM_RUN` 退出时内核已有正确 FP/Vector，RISC-V exit handler 不修改它们，跳过可节省约 68 次 `KVM_SET_ONE_REG`。reset、初始化或完整恢复级别仍会写 FP/Vector。

这项优化利用了状态所有权不变式，并未降低向量寄存器的重要性：只有当用户态没有修改某类状态，才能省略写回。未来若某个 exit handler 开始修改 FP/Vector，必须同时撤销或细化优化，否则下一次运行使用旧内核状态。

## H 状态在当前 KVM 同步中的边界

当前 `kvm_misa_ext_cfgs` 可以表达 `H`，FDT生成逻辑也会把启用的单字母扩展写给 L1。但上述 get/put 表没有 H CSR或 VS CSR；随 QEMU携带的 [`linux-headers/asm-riscv/kvm.h`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/linux-headers/asm-riscv/kvm.h) 中，general CSR结构同样只有 S CSR，没有独立 H/VS register group。

这是源码事实，能够支持的结论是“当前 QEMU用户态显式同步路径未展示完整 H/VS 状态”，不能直接推出内核绝对不能在任何开发分支运行 L2，也不能假定状态由别处自动迁移。结合 2026 年 Linux nested v1 系列明确“尚不能运行 L2”的上游陈述，本书把 L1运行 L2标记为演进中，把 nested migration 标记为未闭环。

普通宿主 H 加速 L1不要求把物理 H CSR原样暴露为客户机状态。Linux KVM可以在宿主 H 上运行普通 S-mode L1，而 QEMU只同步 S 级状态。向 L1暴露 H 后，问题才升级为虚拟 H state。再次说明，第一层能力不能替第二、三、四层背书。

## 初始 RISC-V KVM 支持如何形成

RISC-V KVM 的早期 QEMU系列经过多版 review。2022 年的 [v5 patch series](https://lists.nongnu.org/archive/html/qemu-riscv/2022-01/msg00203.html) 对应初始支持的重要提交包括 [`91654e61`](https://gitlab.com/qemu-project/qemu/-/commit/91654e61)、[`0a312b85`](https://gitlab.com/qemu-project/qemu/-/commit/0a312b85) 和 [`4eb47125`](https://gitlab.com/qemu-project/qemu/-/commit/4eb47125)。它们逐步建立 KVM CPU、寄存器接口和 `virt` 集成，而不是把所有逻辑一次塞入通用 KVM层。

早期实现需要同时面对 Linux RISC-V KVM UAPI 尚在发展、QEMU CPU扩展快速增加和 `virt` 启动路径差异。review 的核心约束可从当前结构反推：架构特定 ID不能泄漏到通用层；用户请求必须受宿主能力限制；KVM不能沿用 TCG 的 M-mode firmware 假设；CPU状态需要接入通用 synchronize 协议。

[`ad40be27`](https://gitlab.com/qemu-project/qemu/-/commit/ad40be27) 是 direct boot 演进的重要锚。它解释当前 `virt_machine_done()` 为何在 KVM下把 kernel entry 和 FDT直接交给 vCPU，并拒绝 M-mode firmware。这个限制看似板级细节，实际减少了 KVM首版必须虚拟化的特权状态面。

## 目录拆分表达执行边界

初期 RISC-V KVM文件和 target中的其他代码混在一起。提交 [`fb80f333`](https://gitlab.com/qemu-project/qemu/-/commit/fb80f33377df221728d6c3c298f19b0da7ba277a) 将 KVM-only 文件移入 `target/riscv/kvm/`，对应[邮件说明](https://lists.nongnu.org/archive/html/qemu-riscv/2023-09/msg00351.html)。当前该目录只有 `kvm-cpu.c`、`kvm_riscv.h` 和 Meson文件，TCG-only 文件则在 `target/riscv/tcg/`。

目录移动没有直接改变客户机语义，却改善了编译依赖和阅读模型。`CONFIG_KVM` 只编译 KVM hook，TCG helper不会被误当作 KVM执行路径；共同的 CPU state和 machine代码留在上层。对于本书，这个提交提供了一条上游明确的分层证据，而不是作者仅凭文件名猜测。

分目录也暴露共享边界的质量。如果一个新功能必须在 `tcg/` 和 `kvm/` 互相 include 私有 header，说明架构状态或公共接口可能放错位置。`CPURISCVState`、CPU扩展描述和 VMState属于公共架构模型，具体译码 helper与 one-reg 操作分别属于各自加速器。

## scratch vCPU 与 register list 的演进

[`492265ae`](https://gitlab.com/qemu-project/qemu/-/commit/492265ae) 引入或重构 scratch vCPU能力探测，对应 [v9 系列](https://patchew.org/QEMU/20230706101738.460804-1-dbarboza%40ventanamicro.com/)。补丁到 v9说明接口边界经过反复审查：何时创建临时 VM、错误如何传播、属性属于 CPU class还是 instance、不同内核如何回退，都比“调用一个 ioctl”更复杂。

[`608bdebb`](https://gitlab.com/qemu-project/qemu/-/commit/608bdebb) 增加 `KVM_GET_REG_LIST` 路径，对应 [v2 系列](https://patchew.org/QEMU/20231003132148.797921-1-dbarboza%40ventanamicro.com/)。当前代码仍保留 legacy fallback，说明新接口用于扩展和效率，而没有立即切断旧内核。兼容策略不是永久零成本：两条探测路径都要测试，错误语义要保持一致。

从最终代码看，register list 还改善了 CSR安全访问。QEMU只同步列表中存在的 CSR，避免旧内核对新增 `senvcfg/scounteren` 返回错误。2025 年 `kvm_csr_cfgs` 一系列重构继续把字段宽度、支持位和环境偏移数据化，说明扩展增长后，手写一组 get/put 很难维护。

## 运行时同步优化的 review 证据

提交 [`e2beafde`](https://gitlab.com/qemu-project/qemu/-/commit/e2beafde9e782b051355975f444c986b1b788925) 在 `KVM_PUT_RUNTIME_STATE` 跳过 FP/Vector 写回，对应 [v3 邮件系列](https://patchew.org/QEMU/20260518102118.2768383-1-mengzhuo%40iscas.ac.cn/)。最终注释给出约 68 次 ioctl 的节省，并引用其他架构的类似做法。

这项历史适合说明性能优化应如何证明安全。第一，识别开销来源是每次 vCPU exit后的重复 one-reg，而非指令执行本身。第二，建立不变量：内核刚退出时拥有最新 FP/Vector，QEMU架构 exit不修改。第三，只在 runtime level跳过，reset和恢复仍完整同步。第四，通过多版 review检查迁移、调试和异常路径。若只提交“减少 ioctl”而没有状态所有权论证，优化不可接受。

## 错误路径也是接口设计

KVM调用可能因 capability 缺失、宿主资源不足、参数不合法、信号或内核错误失败。QEMU需要区分可回退与不可恢复。scratch `GET_REG_LIST` 的 `EINVAL` 可以回退，真实 vCPU `KVM_CREATE_VCPU` 失败则应终止 CPU创建；`KVM_RUN` 的 `EINTR` 可以回到事件循环，未知执行错误通常停止 VM并打印 CPU state。

错误信息应包含 vCPU ID、寄存器或扩展名和 errno。只有“ioctl failed”很难判断是哪个能力与宿主不匹配。当前 KVM extension setter在宿主不支持用户请求时尽早生成 QAPI Error，而真实写 one-reg意外失败会报告属性并退出。前者是配置错误，后者意味着探测与执行之间出现不一致或内核拒绝已声明支持的操作。

部分 error path 还涉及安全。DBCN 从 guest提供的物理地址读写，必须经过 guest AddressSpace，而不能把数值当宿主指针。MMIO 长度和方向来自 `kvm_run` UAPI，也要由 memory subsystem验证。KVM降低了 CPU模拟量，却没有降低所有不可信输入的审查要求。

## 可观测性：不要只用 `strace` 数 `KVM_RUN`

`strace -e ioctl` 可以确认 `KVM_CREATE_VM/VCPU`、one-reg 和 `KVM_RUN`，但难以解释每个 ioctl 对应哪个 QEMU阶段，也可能显著扰动时序。QEMU tracepoint 能把 vCPU index、exit reason和 memory slot事件放入语义上下文；GDB可以在 `kvm_arch_init_vcpu`、`kvm_cpu_exec` 与 `kvm_arch_handle_exit` 断下；`-d` 日志用于 RISC-V未实现 SBI/CSR。

观察时要把“进入次数”和“退出原因”分开。`KVM_RUN` 返回一万次可能全是预期 MMIO，也可能是信号 kick；只数 ioctl无法定位。还要记录 workload 时间和 vCPU数，因为一个四核客户机天然有四个并行运行线程。

若要测 one-reg 优化，选择会频繁产生用户态 exit且使用 Vector 的 workload，分别比较提交前后 `KVM_SET_ONE_REG` 数。只运行纯计算 workload，几乎没有 exit，优化效果会被隐藏。测量命令、宿主内核和 QEMU commit必须一并记录。

## KVM UAPI 的对象协议

从调用形式看，KVM UAPI 是一组 ioctl；从工程语义看，它是一套分层对象协议。系统 fd 回答 API 版本和全局 capability，VM fd承载地址空间、memory slot与 VM级设备，vCPU fd承载寄存器、运行页与执行。QEMU只把操作发给定义该状态的对象。例如 `KVM_SET_USER_MEMORY_REGION` 作用于 VM fd，`KVM_GET_ONE_REG` 与 `KVM_RUN` 作用于 vCPU fd；把对象层次写错，内核即使返回统一的 `EINVAL`，含义也完全不同。

通用 `kvm_init()` 首先检查 `KVM_GET_API_VERSION`，再用 `KVM_CHECK_EXTENSION` 获取能力。检查版本只能说明基础 ioctl协议兼容，不能替代逐项 capability。一个宿主可以提供相同 API 版本，却因架构、内核配置或硬件差异缺少某个设备类型。反过来，QEMU编译时携带的新 UAPI头文件也不会让旧内核凭空实现对应 ioctl。这里的源码事实是 QEMU同时执行版本检查和运行时能力检查；工程推断是这种双重协商降低了二进制与宿主内核解耦后的部署风险。

capability 的查询位置也有层次。有些能力在系统 fd查询，有些能力只有 VM建立后才有实际意义，某些功能还需要对 VM调用 enable capability。读日志时应记录 ioctl落在哪个 fd，不能只保存常量名。若迁移源端与目标端都打印“支持某 capability”，仍要核对返回值语义、VM type、irqchip模式以及关联属性；布尔存在性经常不足以描述可迁移的参数范围。

fd 生命周期给错误回滚增加了次序约束。scratch 探测若在创建 VM 后、创建 vCPU前失败，必须关闭 VM与系统 fd；真实 vCPU若在映射 `kvm_run` 后架构初始化失败，还要解除映射，再关闭或 park vCPU。QEMU把一部分回收集中在通用层，就是为了避免每个 target重复实现一套不完整的 unwind。源码阅读时，成功路径和 `goto err` 路径应成对检查；资源只在正常退出释放，启动失败仍会泄漏。

`struct kvm_run` 是共享页，不是持久快照。字段的有效性取决于本次 `exit_reason`，下一次 `KVM_RUN` 可以覆盖它。QEMU必须在处理当前 exit时消费地址、长度、方向和返回值，迁移代码不能把整个共享页原样保存。它还包含用户态向内核提交的输入字段，这使得重新进入前的写顺序和内存可见性成为协议的一部分。

:::: {.quick-quiz}
为什么同一个 `KVM_CHECK_EXTENSION` 返回正数，仍不足以证明功能可以迁移？

::: {.quick-answer}
返回值可能表示数量、模式或参数上限，功能还可能依赖 VM type、CPU model、内核设备属性及可保存状态接口。迁移需要源端可读、目标端可写且语义兼容，单个运行 capability只能证明调用入口存在。
:::
::::

## one-reg ID 是一份跨层类型系统

RISC-V KVM把许多 CPU状态编码成 64 位 one-reg ID。ID中组合架构标识、数据宽度、寄存器组和组内索引，用户缓冲区地址另行传入 `struct kvm_one_reg`。这套编码让内核逐步增加扩展，不必每次扩大一个固定 C结构；QEMU也能通过 register list识别稀疏能力。

宽度位不能忽略。RV32与 RV64的 XLEN寄存器长度不同，Vector寄存器和某些标量配置又有自己的数据规模。QEMU的 `KVMCPUConfig` 记录字段宽度，get/put helper据此选择宿主缓冲区。若把所有值都当作 `uint64_t`，小端宿主上简单整数也许暂时可用，数组、向量或跨端序场景会暴露错误。UAPI ID、QEMU字段类型和客户机 XLEN必须三者一致。

register list的两阶段调用值得单独观察。QEMU先提交容量为零的列表，内核通过 `E2BIG` 和 `n` 告知数量；分配足够空间后再次调用取得所有 ID。随后排序让大量扩展查询可以使用二分查找。扩展表增长到数百项时，这比对每一项做一次失败 ioctl稳定得多，也让“不在列表中”与“读取已有寄存器失败”成为两类错误。

legacy fallback保留了部署兼容性，也制造了一条需要持续测试的旁路。新内核路径以列表为真值，旧内核路径逐项试探；如果新增扩展只接入其中一条路径，同一 QEMU二进制会在不同内核上给出不同 CPU属性。审查新增 `kvm_riscv` 扩展时，应检查配置表、list查找、legacy读取、setter、realize、FDT和迁移兼容，而不只是增加一个 UAPI宏。

one-reg 的存在不代表它天然进入迁移。`KVM_GET_ONE_REG` 可以服务调试、初始化或运行时配置；只有 `kvm_arch_get_registers()` 在暂停后的同步路径读取它，并且对应字段位于合适的 VMState中，源端值才会进入迁移流。目标端还需在 vCPU开始前调用相应 put。H/VS状态缺口正是沿这条链审查出来的：扩展开关 ID存在，完整运行状态 ID与同步代码没有同时出现。

## CPU model、设备树与客户机 ABI

QEMU在启动阶段把宿主能力转成 CPU属性，再把最终启用集合写进客户机设备树。三个集合不能混为一张表：宿主支持集描述“可以提供什么”，用户配置集描述“希望提供什么”，客户机可见集描述“最终承诺什么”。setter拒绝打开宿主不存在的位，realize检查扩展依赖，FDT只应发布收敛后的结果。

设备树中的 `riscv,isa-extensions` 会被客户机内核当作启动能力。若 QEMU在 FDT声明 `h`，L1可能加载 hypervisor相关代码并访问 H CSR；此时只允许 `KVM_RISCV_ISA_EXT_H` 属性读为真还不够，内核必须实现相应虚拟状态和 trap语义。当前上游开发状态要求本书继续把“看到 H”与“运行 L2”分开。这是由源码与 Linux nested邮件共同支持的结论，不是从 ISA字符串作出的乐观推断。

`-cpu host` 直接跟随宿主，适合本机性能和能力探索，却会让跨主机迁移集合随硬件变化。稳定部署通常需要选择两端交集并显式关闭差异扩展；QEMU当前 RISC-V KVM CPU属性已经允许关闭一部分宿主位，但“可关闭”仍不等于已经定义长期 machine ABI。Vector长度、CBO block size和定时器频率等数值参数也必须进入比较。

machine version与 CPU model共同约束 ABI。一个新 QEMU版本可能认识更多宿主扩展，如果默认把它们全部暴露，已有命令行在升级后会生成不同 FDT与迁移状态。上游因此倾向由属性、兼容设置和用户显式选择控制变化。阅读一个“默认启用扩展”的提交时，要同时检查 machine compatibility；只看目标 CPU初始化函数会漏掉旧 machine如何维持行为。

对于尚无稳定 profile UAPI 的能力，当前代码把 profile属性标为 unavailable。这样做会让某些命令行启动失败，却避免向客户机承诺一组无法验证的组合。工程上，可诊断的早期拒绝优于运行数小时后在迁移或罕见指令上失败。

## vCPU 的进入、退出与重新进入

一次 vCPU循环可以拆成五个所有权阶段。第一阶段，QEMU处理排队工作和停止请求；第二阶段，若用户态镜像为 dirty，架构 put把必要状态交给内核；第三阶段，pre-run准备中断与退出控制；第四阶段，`KVM_RUN` 让内核和硬件拥有执行状态；第五阶段，退出后 QEMU按原因处理，并决定立即重入、回事件循环或停止 VM。

这五个阶段解释了为何在 `KVM_RUN` 两侧散布多个 hook。目标架构需要在进入前提交特殊状态，在退出后读取内核更新的属性；通用层则处理 MMIO、系统事件和 dirty ring。若把架构 exit全部移入目标文件，memory subsystem会重复；若把 RISC-V SBI硬塞进通用 switch，其他架构被迫理解无关 UAPI。当前分层由 exit语义决定，而不是单纯按文件数量决定。

用户态处理完一次 MMIO读后，结果写回 `kvm_run` 的 data字段。原指令的完成可能发生在下一次内核进入，因此这次重入带有提交语义。类似地，某些 I/O exit在下一次 `KVM_RUN` 前不能被随意丢弃。QEMU的 `immediate_exit` 可以让这次重入很快返回，却仍要给内核机会完成协议。审查暂停和迁移竞态时，应关注“已从内核退出”与“上一次退出对应指令已完成”之间的差别。

信号 kick解决另一个竞态：vCPU可能正阻塞在 `KVM_RUN`，主线程已经要求停止。QEMU设置退出请求、用原子顺序发布，再向 vCPU线程发信号；signal handler触发 immediate exit。vCPU返回后再次检查请求。若先发信号再发布状态，vCPU可能被唤醒、看不到请求、又进入内核；若只设置标志不发信号，计算密集型客户机可能很久不产生自然 exit。

BQL并不串行化硬件执行。vCPU在进入 KVM前释放 BQL，多个 host线程可并行运行各自 vCPU；设备配置、主循环和某些 exit处理再按需要获取锁。RCU注册保证 AddressSpace和设备拓扑读侧可以与更新协调。由此得到一个可验证推断：KVM多核扩展性取决于宿主调度和内核虚拟化路径，也受用户态 exit是否争用 BQL影响；仅观察 guest CPI无法解释后者。

QEMU排队到 vCPU线程的 work用于在正确线程上下文执行同步操作。寄存器 get/put不能随意由主线程直接对正在运行的 vCPU fd操作，否则内核状态与该线程的进入过程会竞争。通用同步 helper把请求投递并等待，形成暂停、调试与迁移的线程间屏障。这个机制也是 `vcpu_dirty` 能代表明确所有权的前提。

:::: {.quick-quiz}
为什么 vCPU已经因 MMIO退出后，迁移代码仍不能立刻把它视为处于精确指令边界？

::: {.quick-answer}
部分 KVM I/O协议要求用户态填入结果并再次执行 `KVM_RUN`，内核才提交原指令。退出只说明需要用户态协助，未必说明指令已经完成；暂停流程要完成或显式处理这段未决协议。
:::
::::

## RISC-V exit 的控制面性质

RISC-V SBI exit把一部分固件式服务交回 QEMU。legacy console与 DBCN最终连接 chardev，属于用户态拥有的外设和管理资源。DBCN参数指向客户机物理内存，handler必须经 AddressSpace拷贝；这同时保留内存属性检查，也避免客户机数值被误当成宿主地址。若缓冲区跨越不可访问区域，返回值应反映失败，不能部分越界访问宿主。

CSR exit目前覆盖的范围很窄，这反映性能边界。每次 CSR访问都退回用户态会使指令热路径失去 KVM意义，内核通常直接实现稳定、高频的特权语义，只把需要用户态资源或尚无内核实现的操作上送。新增 CSR exit时，review除了检查功能，还应问访问频率、是否可批量、是否存在 side channel以及迁移时状态由谁拥有。

debug exit要求先同步 PC和通用寄存器，因为 GDB操作的是 QEMU镜像。软件断点还可能修改客户机内存或 PC，处理完后镜像保持 dirty，下一次运行必须 put。由此可见，debug不是被动读取；它可能改变执行状态，因此会穿过完整所有权协议。

未知 exit不能默认继续。内核与 QEMU UAPI若出现版本不匹配，静默忽略会让同一指令反复退出，形成高占用死循环。当前代码对未处理 RISC-V exit和异常 errno给出错误或停止路径。可观测性设计要保留 `exit_reason`、vCPU index和关键参数，但日志中不得直接泄漏不受信任的大块 guest内存。

## 三个同步级别为什么不能合并

通用 KVM接口使用 runtime、reset和 full等 put级别传达调用场景。runtime发生在一次用户态处理后重新运行，目标是写回可能变化的最小状态；reset需要建立架构规定的初始值；full用于迁移恢复或要求完整重建的阶段。三者都叫“写寄存器”，安全假设和成本不同。

RISC-V当前 runtime路径写 core与支持的 S CSR，然后跳过 FP/Vector。reset会清理或写入启动所需寄存器，设置 PC、`a0/a1`和特权级；full恢复则不能依赖目标内核已有正确扩展状态。若将 runtime优化扩展到 full，目标 vCPU中的未初始化 Vector值会污染恢复；若每次 runtime都写所有向量，又会放大 exit成本。

get路径也并非每个 exit自动运行。普通 MMIO handler不需要查看 CPU寄存器，保持内核所有权更便宜；调试、QMP寄存器读取、reset和迁移才触发同步。QEMU镜像一旦取得有效状态便标为 dirty，即使调用者只读，也要假设后续用户态可能修改并按协议交回。这种保守标记简化了多种调用者之间的别名分析。

timer采用独立 runstate handler，说明它的生命周期跨越单次寄存器同步。虚拟时间与 VM运行/暂停状态耦合，简单在 `kvm_arch_get_registers()` 中读一次无法表达暂停期间是否推进。下一章会把 timer与迁移顺序放在一起分析；在本章只需记住“one-reg 列表”不等于“全部 vCPU状态都由同一函数同步”。

H/VS状态同样不能靠 `vmstate_hyper` 名称推定已获得。TCG执行时这些字段就是权威值；KVM执行时若内核未通过 one-reg导出，QEMU字段可能只是初始化镜像。VMState序列化一个陈旧字段比完全没有字段更危险，因为迁移流表面完整，恢复后才出现静默偏差。

## 从提交史还原当前边界

初始 KVM系列把最小可运行路径拆成 CPU、寄存器与 `virt` machine等提交。多版 review表明上游首先收敛职责边界，再逐步扩大 capability。`ad40be27` 的 direct boot收窄启动状态面，避免首版同时承担 M-mode firmware；`fb80f333` 的目录拆分则把已形成的执行边界写进源码结构。这些是提交与邮件能够直接支持的历史事实。

scratch vCPU到 v9才形成当前方案，`KVM_GET_REG_LIST` 又在后续 v2系列加入。由此可以作出强推断：RISC-V扩展数量增长使“静态假设宿主能力”变得不可维护，属性构造必须依赖真实内核对象。推断的限制是，patch版本数量本身不证明某个具体方案更优；真正证据仍是最终代码保留了临时 vCPU、列表协议和 legacy fallback。

运行时跳过 FP/Vector的 `e2beafde` 更接近一次局部性能工程。邮件给出 ioctl数量和状态不变量，最终代码把优化限制在 runtime。它说明提交史可用于回答“为什么现在这样设计”：注释描述当前条件，review记录还展示了替代方案、风险与范围变化。书中引用邮件时应优先链接 cover letter和最终提交，避免只摘取某一版尚未采纳的说法。

历史证据也有时间边界。2026 年 Linux nested v1在 QEMU候选标签之后出现，并明确当时尚不能运行 L2；它能说明上游正在补哪一层，不能被写成 `v11.1.0-rc0` 已有功能。固定源码没有完整 H/VS同步，邮件又没有宣称闭环，两者共同支持“演进中”标签。未来若新系列合入，本书仍需以新的 QEMU tag、内核 tag和复现实验更新结论。

## 一张面向审查的证据清单

审查 KVM CPU功能时，先定位用户入口：命令行属性、machine默认值或 QMP接口。接着找到宿主探测：`KVM_CHECK_EXTENSION`、register list或 one-reg读取。然后追踪真实 vCPU配置：何时 `SET_ONE_REG`，失败是否在运行前报告。再检查客户机描述：FDT是否只发布最终值。最后检查运行、reset、调试和迁移的 get/put。任何一环缺失，都应在正文标成受限能力。

审查性能改动时，记录它省掉了哪类 exit、ioctl或锁争用；列出赖以成立的所有权不变量；检查 reset/full路径是否保持完整；寻找上游测试与回归。只给 benchmark提升而没有状态论证，不能解释为何安全。只给状态论证而没有 workload测量，也无法判断复杂度是否值得。

审查 nested能力时，坚持四行结果。第一行记录宿主是否用 H运行普通 L1；第二行记录 QEMU是否向 L1暴露 H；第三行记录 L1能否创建并执行 L2；第四行记录活动 L2的全部状态能否迁移。每行附内核与 QEMU commit、硬件型号、命令和失败点。这样以后更新版本时，可以替换某一行证据，不会因为“nested supported”四个字抹掉层次。

最后检查负面证据。某个 one-reg组未出现在当前 UAPI头文件，证明的是固定源码没有使用该组；它不能证明未来或厂商内核永远不存在。某个 patch series写“尚不能运行 L2”，证明的是该版作者声明的状态；它不能排除另一开发树。把限定条件写在结论旁，读者才能复查和推翻。

## 多 hart 把运行循环变成并发协议

`-smp 1` 很容易掩盖 KVM集成问题。单 hart时，停止请求、寄存器同步和设备 exit都发生在同一 vCPU线程；多 hart时，每个线程可能处于不同阶段：一个正在 `KVM_RUN`，一个处理 MMIO，一个等待 CPU work，另一个因 SBI HSM处于 stopped。主线程要等全部 vCPU到达安全点，才能把共享设备和 RAM视为静止。

每个 vCPU fd和 `kvm_run`共享页只属于一个 hart，VM fd与 memory slots则由所有 hart共享。对 vCPU寄存器的 one-reg操作应在对应 CPU线程协调，修改 VM级内存和 irqchip则要考虑所有正在运行的 hart。对象层次与锁层次在这里重合：混用会产生某个 hart状态正确、共享映射仍在变化的半同步状态。

vCPU线程释放 BQL后并行运行，硬件可以让多个 hart同时修改同一客户机 cache line。内存一致性由 RISC-V客户机架构、宿主硬件和 KVM保证，QEMU不逐次仲裁普通 RAM访问。只有 exit进入用户态设备时，MemoryRegionOps的线程安全与 BQL策略才重新出现。设备补丁若在单核下工作，仍要检查两个 vCPU同时访问寄存器是否需要原子或锁。

kick也要逐 CPU执行。一个全局停止标志不会自动让正在不同物理 CPU上运行的 `KVM_RUN`返回；信号或 immediate-exit机制必须送达每个目标线程。退出后还要确认它没有因竞态重新进入。通用 CPU层把 stop请求、work队列与线程条件变量组织在一起，target hook只处理 RISC-V状态，避免每个架构重写整套并发协议。

MP state给多 hart增加了另一种“未运行”。次级 hart直接启动时通常为 stopped，等待 SBI HSM；暂停 VM则是所有 hart暂时不能执行。两者不能用同一个 QEMU布尔字段粗略替代。迁移、reset和 hot-unplug都需要保留“客户机主动停止的 hart”和“管理层暂停的 VM”之间的差别。

SBI exit可能改变其他 hart状态。L1发起 hart start时，QEMU或 KVM要设置目标入口、参数和 MP state，并唤醒对应线程。此时调用 vCPU同步 helper的顺序会影响目标看到的第一条指令。即使当前部分 HSM语义由内核直接实现，源码审查仍应沿目标 vCPU的状态写入和 kick路径验证，而不只看发起 hart的返回值。

多 hart调试会强制同步多个镜像。GDB all-stop模式需要所有 vCPU退出，再读取寄存器；non-stop模式允许部分继续，读取某个 hart不应意外覆盖另一个。`vcpu_dirty`是每 CPU字段，不能提升为 VM级单标志。测 runtime one-reg优化时也要按 vCPU统计，否则一个繁忙 hart会掩盖其他 hart的同步异常。

:::: {.quick-quiz}
为什么 VM已经设置全局停止状态，仍要等待每个 vCPU确认退出？

::: {.quick-answer}
全局状态只表达管理意图，正在不同宿主线程中的 `KVM_RUN`仍可能执行并写共享 RAM。只有逐个 kick并确认线程到达安全点，寄存器、设备和内存快照才属于同一时刻。
:::
::::

## 直接启动也是一份 ABI 契约

RISC-V KVM的 direct boot不只是省略固件文件。QEMU选择 kernel入口、放置 FDT、给 `a0`传 hart ID、给 `a1`传 FDT地址，并让首 hart以 S态开始。客户机 Linux依赖这组入口契约建立页表、解析 ISA与设备节点，再通过 SBI或内核协议启动其他 hart。

FDT内容来自 machine与最终 CPU能力的交集。memory节点要与 KVM slots投影同一 GPA布局，CPU节点要反映实际扩展，`timebase-frequency`要来自 KVM timer，PLIC/AIA节点要匹配选定 irqchip。任何一项只在 QEMU对象中改变、没有同步到 FDT，都会让客户机驱动按另一套硬件运行。

direct boot限制 M-mode firmware减少了初始 KVM状态面。若允许任意 OpenSBI以 M态启动，KVM需要表达 M CSR、PMP、M-mode trap和固件切换状态，并考虑其迁移。当前路径把这些语义留在宿主/内核边界之外，让首版集中支持 S态客户机。这个设计理由由 `ad40be27`及最终 `virt_machine_done()`路径共同支持。

限制也带来测试差异。TCG常通过 OpenSBI启动，KVM直接进入内核；两者控制台早期输出、hart启动顺序和 timer初始化可能不同。定位 accelerator差异时，应先让启动协议尽量可比，不能看到第一条 PC不同就判断 KVM执行错误。

kernel、initrd与 FDT地址还要避开彼此和 RAM边界。QEMU加载器在 machine完成阶段计算并写入，reset只把已保存地址送给 vCPU。迁移恢复则不重新执行一次新加载，否则目标端可能覆盖已迁移 RAM；它恢复源端 PC和 RAM内容。这个差异再次说明 reset路径与 full restore路径不能共享默认值。

## 用故障场景验证分层

第一类故障发生在 accelerator初始化。`/dev/kvm`不存在、API版本不符或创建 VM失败时，QEMU应在 machine启动前退出，并说明宿主前提。此时还没有真实 vCPU和 guest RAM运行，错误回滚主要检查系统/VM fd与 KVMState。

第二类发生在 scratch探测。旧内核对 `KVM_GET_REG_LIST`返回约定中的 `EINVAL`时应进入 legacy路径；创建 scratch vCPU失败、第二次列表读取失败或已声明寄存器读取失败则应中止。不能把所有错误都当作“扩展不支持”，否则资源不足和 UAPI损坏会被伪装成较小 CPU模型。

第三类发生在 CPU属性收敛。用户显式请求宿主没有的 H、Vector或其他扩展，应在 realize阶段给出属性名；vlen或 CBO block size不兼容也应在首个 `KVM_RUN`前失败。若 QEMU仍生成包含该扩展的 FDT再在运行时失败，客户机已经看见无法兑现的 ABI。

第四类发生在真实 vCPU创建与初始化。`KVM_CREATE_VCPU`成功不保证后续 one-reg设置、SBI DBCN或 MP state成功。回滚要解除 `kvm_run`映射、dirty ring和 fd，并通知等待 CPU线程启动的主线程。只让工作线程静默退出会使主线程永久等待。

第五类发生在运行中。`EINTR`与 `EAGAIN`通常进入重试/事件处理，未知 errno或未处理 exit要停止并记录 vCPU。MMIO设备错误需要按设备总线语义反馈，不能统一变成 KVM fatal error。DBCN访问无效 GPA时也应返回 SBI失败，而非解引用宿主地址。

第六类是同步失败。调试或迁移期间某个 `GET_ONE_REG`失败，用户态镜像不完整，继续保存会生成表面合法的坏快照。正确策略是终止该操作并保留 VM暂停状态。put失败同样不能清 `vcpu_dirty`后继续运行，否则 QEMU认为所有权已经交回，内核却只收到部分寄存器。

每一类都可以用故障注入复现：移除 capability、限制 fd/内存资源、请求不存在扩展、让一个已探测寄存器返回错误、向未处理 exit注入测试值。实验重点是错误发生在哪一层、资源是否释放、客户机是否曾开始运行。这样的负面测试比单次成功启动更能验证当前分层。

## 把“为什么这样设计”写成可推翻结论

本章有几类设计解释。目录拆分的理由有提交和邮件直接说明，属于上游事实；scratch vCPU减少过晚失败，是由创建时序与最终代码支持的强推断；runtime跳过 FP/Vector则有提交说明、代码注释和限定级别，证据更强。写作时应标明证据等级，避免把作者推断写成维护者原话。

一个设计往往同时有收益和成本。register list减少 ioctl并支持稀疏扩展，成本是保留 legacy分支；direct boot缩小 M-mode状态面，成本是与 TCG固件路径不同；KVM下沉执行提高性能，成本是状态同步和迁移接口。工程考量只有把这两面与可测指标一起写出，才足以解释当前结构。

历史还可能留下暂时性限制。profile unavailable、H/VS同步缺口和 nested内核未完成，都不等于架构方向被否定。它们说明当前 UAPI与测试闭环尚未达到发布声明。未来补丁应改变“待验证”标签，而不应让旧书稿提前预测结果。

可推翻意味着给出条件。例如“scratch探测减少过晚失败”可以用初始化时序和错误注入验证；若未来 KVM提供无需 vCPU的系统级能力枚举，设计可能改变。“nested migration未闭环”可由新 one-reg组、QEMU同步、内核合入与活动 L2迁移测试推翻。明确条件让历史分析保持可维护。

## 固定一套可以重复的最小环境

复现本章调用链时，先记录宿主硬件是否真的提供 H、内核是否启用 RISC-V KVM、`/dev/kvm`权限以及 QEMU完整 commit。QEMU标成 `v11.1.0`而源码实际来自候选版或附带补丁，会让 one-reg列表与邮件结论对不上；实验表同时保存 tag和提交哈希。

客户机选择直接启动的最小 RISC-V Linux，命令行显式写 `-machine virt -accel kvm -cpu host`或明确 CPU属性、`-smp`与 kernel路径。为了观察初始化，先关闭不相关网络和存储设备，只保留串口；跟踪运行循环时再逐项加入 virtio。一次改变一个变量，可以区分 CPU探测、machine启动和设备 exit。

日志分三层保存。QEMU层记录 tracepoint、错误与 QMP runstate；系统调用层只过滤 `/dev/kvm`相关 ioctl并按线程标识；内核层按需开启 KVM tracepoint。完整 `strace`会改变时序并产生大量字符设备调用，不能作为性能数据。每条关键记录都附 vCPU index与时间戳，scratch vCPU和真实 vCPU才不会混在一起。

能力快照至少包含 API版本、关键 `KVM_CHECK_EXTENSION`、`KVM_GET_REG_LIST`、每个最终 CPU扩展开关、vlen、SATP模式与 timebase。FDT反编译结果用于核对客户机可见集合。宿主宣称、QEMU配置和 FDT三者出现差异时，先定位收敛阶段，不要直接进入客户机调试。

最后保留预期失败样本：请求一个宿主缺少的扩展、使用旧内核回退 register list、让次级 hart保持 stopped、通过 QMP触发 stop/cont。成功与失败日志一起构成基线，后续升级 QEMU或内核时才能判断行为改变来自功能新增、错误处理变化还是回归。

重跑基线时不要复用上一次生成的 FDT和 capability缓存。scratch vCPU探测的是当前内核对象，升级内核后结果可能变化；FDT又由最终 CPU配置生成。清理构建目录不是必需条件，确认 QEMU二进制、模块与符号来自同一 commit才是。报告中保存二进制哈希，可以避免调试器源码和实际进程不一致。

最后用客户机自检闭合观察。宿主日志显示 `KVM_RUN`成功，只能证明进入内核；客户机应验证每个 hart启动、扩展指令、timer和基本中断。若宿主调用链正常而客户机失败，问题可能位于 FDT、direct boot契约或设备语义。把两侧结果放在同一时间线上，比单看 ioctl更容易找到责任边界。

测试结束后保存实际 one-reg列表，而不是只保留人工挑选项。新增内核寄存器、消失的 legacy ID或宽度变化都能从全量差异中发现。列表属于宿主能力快照，不直接成为迁移流，但它是解释 CPU属性和同步覆盖变化的关键证据。

## 实验一：重建创建与运行调用链

::: {.hands-on}
配套英文实验手册：[`probe-riscv-kvm`](../experiments/part-03-riscv-hardware-virtualization/chapter-13-linux-kvm-riscv/probe-riscv-kvm/README.md)。

在支持 RISC-V KVM 的 riscv64 宿主上构建 QEMU `v11.1.0-rc0` debug 版本，使用 `-machine virt -accel kvm -smp 2 -kernel <Image> -append ... -nographic` 启动最小 Linux。开启 KVM相关 tracepoint，并用受限 `strace -f -e trace=ioctl` 只观察启动早期；不要把完整控制台数据混入日志。

按线程整理 `/dev/kvm`、`KVM_CREATE_VM`、scratch `KVM_CREATE_VCPU`、真实 `KVM_CREATE_VCPU`、`KVM_GET_VCPU_MMAP_SIZE`、one-reg 和首个 `KVM_RUN`。在 QEMU源码中分别对应 `kvm_init()`、`riscv_init_kvm_registers()`、`kvm_init_vcpu()`、`kvm_arch_init_vcpu()` 和 `kvm_cpu_exec()`。预期 scratch vCPU在 CPU属性探测阶段创建并销毁，真实 vCPU在线程入口创建；两者用途不同。
:::

## 实验二：验证状态所有权与同步级别

::: {.hands-on}
配套英文实验手册：[`trace-kvm-run-loop`](../experiments/part-03-riscv-hardware-virtualization/chapter-13-linux-kvm-riscv/trace-kvm-run-loop/README.md)。

在 `kvm_arch_get_registers()`、`kvm_arch_put_registers()`、`kvm_riscv_get_regs_vector()` 和 `kvm_riscv_put_regs_vector()` 设置断点或临时 trace。让客户机执行 Vector workload，先正常运行，再通过 QMP `stop`、读取寄存器、`cont`，最后执行一次 reset。

记录每个阶段调用的 get/put 组和 `KvmPutState`。预期普通 runtime re-entry只写 core与支持的 S CSR，不写 FP/Vector；暂停后读取状态会拉取 FP/Vector；reset或完整恢复会写回它们。这个实验验证 `e2beafde` 的状态所有权前提，不用于证明 H/VS 状态已经同步。
:::

## 实验三：分开验证 H 的四层能力

::: {.hands-on}
本实验复用 [`probe-riscv-kvm`](../experiments/part-03-riscv-hardware-virtualization/chapter-13-linux-kvm-riscv/probe-riscv-kvm/README.md) 的 capability 采集步骤，并在其结果表上增加 L1、L2 与迁移三列。

在同一宿主记录 `KVM_GET_ONE_REG` 探测到的 `KVM_RISCV_ISA_EXT_H`、QEMU `query-cpu-model-expansion` 或 CPU属性、客户机 FDT 的 `riscv,isa-extensions`，再尝试运行公开 nested 测试。环境表写明宿主 CPU、Linux commit、是否应用 2026 nested patch series、QEMU commit和命令行。

结果必须分成四项：宿主 H 是否让普通 L1通过 KVM运行；L1 是否看见 H；L1 是否真正进入并运行 L2；活动 L2能否迁移。按照公开 Linux nested v1 的上游陈述，不能运行 L2时第三项应标“未完成”，第四项自然是“未闭环”。即使前两项为真，也不得合并写成“nested 支持”。
:::

:::: {.quick-quiz}
为什么 runtime 可以跳过 FP/Vector 写回，却不能据此跳过所有 CSR？

::: {.quick-answer}
优化依赖“前次 `KVM_RUN` 后内核值最新，且用户态 exit handler 不修改该组状态”。RISC-V 用户态路径可能修改 PC、通用寄存器或某些 CSR以完成 exit，因而仍需写回；FP/Vector 当前没有这种修改。若未来 handler改变它们，优化也必须调整。
:::
::::

## 小结

KVM 把硬件虚拟化变成一组有生命周期的 Linux对象。QEMU通用 KVM层创建 VM/vCPU、映射 `kvm_run`、管理执行循环；RISC-V 层把 ISA属性、one-reg、SBI、timer与 AIA 接入。scratch vCPU和 `KVM_GET_REG_LIST` 解决的是“真实 vCPU创建前如何可靠知道宿主能力”，`vcpu_dirty` 解决的是“状态何时由内核或用户态拥有”。

历史演进说明当前分层不是一次写定：初始 KVM系列建立最小运行路径，direct boot收窄首版边界，目录拆分明确 TCG/KVM职责，scratch与 register list让扩展探测可维护，runtime同步优化再降低控制面开销。当前源码能确认 H capability 的表达，却没有完整 H/VS one-reg同步；结合 Linux nested上游状态，本书仍把 L2运行与 nested migration列为演进中。下一章转向 memory slots、MMIO、PLIC/AIA、irqfd和ioeventfd，观察 CPU热路径之外的边界如何移动。
