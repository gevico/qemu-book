# QEMU/KVM 历史与当前实现证据账本

核验日期：2026-07-19。

当前实现基线：QEMU [`v11.1.0-rc0`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0)，commit `eca2c16212ef9dcb0871de39bb9d1c2efebe76be`。历史材料用于解释接口为何形成，当前能力只以固定标签、对应 Linux UAPI 与可重复实验为准。

状态标记：

- **已验证**：原始邮件、commit、会议材料或固定源码直接支持；
- **综合判断**：多份已验证材料共同支持，来源未逐字给出该结论；
- **开放**：固定基线不足以证明，需要新源码、内核或实验继续核验。

## KVM 要解决的约束

### KVM-ORIGIN-001：VM 进程、vCPU 线程与 QEMU 设备模型

- **问题**：同 ISA 客户机如何使用硬件执行，同时复用成熟的宿主管理与设备模型？
- **已验证**：Avi Kivity 于 2006-10-19 发布 [KVM 初始 patch series](https://lkml.iu.edu/hypermail/linux/kernel/0610.2/1369.html)，提出 `/dev/kvm` 字符设备；VM 对应宿主进程，vCPU 对应线程；客户机 I/O 截获后交给用户态，经修改的 QEMU 提供设备模拟与 BIOS。
- **已验证**：邮件把 guest mode 加入 Linux 已有 user/kernel mode，并明确可复用 `kill`、`nice`、`top`、调度与内存管理。
- **人物**：Avi Kivity 是 series 作者与早期维护者；Yaniv Kamay 与 Avi 共同签署早期 VM/vCPU/MMU 数据结构；QEMU 承担用户态 VMM。
- **当前落点**：[`kvm_init()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/kvm/kvm-all.c#L2893)、[`kvm_cpu_exec()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/kvm/kvm-all.c#L3427)与 RISC-V [`kvm_arch_handle_exit()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c#L1730)。
- **综合判断**：KVM 的持久生态位来自 Linux/KVM 执行与隔离、QEMU machine/设备/管理的分层，不能缩成“QEMU 里的一条 CPU 快路径”。

### KVM-ORIGIN-002：不采用“Xen 不能运行 Windows”的叙事

- **已验证**：初始邮件已经报告 Windows 现有镜像可运行，并能执行 pinball/Flash；安装蓝屏涉及 virtual APIC，Windows 64 位问题也被指向 QEMU 设备模型。
- **已验证**：最初 Intel VT 定义有内容来自 Xen。Steven Rostedt 在 review 中要求分离架构相关与通用内容，Avi [回应并接受方向](https://lkml.iu.edu/hypermail/linux/kernel/0610.2/2323.html)。
- **综合判断**：KVM 与 Xen 的差别应描述为工程组织、内核复用和用户态 VMM 边界；“Xen 不能运行 Windows，因此诞生 KVM”与原始材料矛盾。

### KVM-ORIGIN-003：Type-1/Type-2 标签的口径

- **已验证**：[2007 KVM 论文](https://www.kernel.org/doc/ols/2007/ols2007v1-pages-225-230.pdf)把 KVM 描述为 Linux 子系统，为 Linux 提供 hypervisor capability；论文作者为 Avi Kivity、Yaniv Kamay、Dor Laor、Uri Lublin、Anthony Liguori。
- **综合判断**：按 CPU 控制与二阶段映射观察，内核/硬件处于 hypervisor 路径；按 VMM/设备管理进程观察，QEMU 位于宿主用户态。单独标成 Type-1 或 Type-2 会隐藏责任分层。
- **正文规则**：使用“Linux KVM 子系统”“KVM accelerator”或“QEMU/KVM 栈”；如出现分类标签，必须同时说明边界口径。

## UAPI 为什么形成对象层级

### KVM-UAPI-001：版本与能力查询

- **已验证**：Avi Kivity 的 [`KVM: API versioning`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=0b76e20b27d20f7cb240e6b1b2dbebaa1b7f9b60)在 2006-12 引入编译期/运行期版本，当时 API 为 1。
- **已验证**：随后接口很快演进，Linux 2.6.22 已使用 API 12；当前 QEMU `kvm_init()` 要求 `KVM_GET_API_VERSION` 精确匹配基础版本。
- **已验证**：[`KVM_CHECK_EXTENSION`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=5d308f4550d9dc4c236e08b0377b610b9578577b)提供向后兼容的功能查询。
- **综合判断**：基础版本保持稳定，新功能依靠 capability、device attribute 和 one-reg 协商；新 UAPI 头文件不证明运行宿主拥有能力。

### KVM-UAPI-002：VM fd、vCPU fd 与共享运行页

- **已验证**：[`Create an inode per VM`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=f17abe9a44425ff9c9858bc1806cc09d6b5dad1c)把全局与 VM ioctl 分开，让 `KVM_CREATE_VM` 返回 VM fd。
- **已验证**：[`Per-vcpu inodes`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=bccf2150fe62dda5fb09efa2f64d2a234694eb48)给每个 vCPU 独立 fd，提交说明提到减少共享 file cacheline 争用并为 SMP 建立清楚身份。
- **已验证**：[`mmap shared run page`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=9a2bb7f486dc639a1cf2ad803bf2227f0dc0809d)用共享页承载运行/退出数据，降低复制并为扩展保留空间。
- **当前落点**：system fd 探测全局能力；VM fd 承载 memory slot、dirty log 与 irqchip；vCPU fd 承载寄存器、MP state、`KVM_RUN` 与 `struct kvm_run`。
- **综合判断**：对象 fd 同时解决生命周期、并发身份和 ABI 范围，不应写成“若干 ioctl 的形式偏好”。

### KVM-UAPI-003：memory slot 与地址命名

- **已验证**：Yaniv Kamay 与 Avi Kivity 的[早期数据结构 patch](https://lkml.iu.edu/hypermail/linux/kernel/0610.2/1374.html)明确区分 GVA/GPA/GFN/HVA/HPA/HFN，并定义 VM、vCPU、MMU 与 memory slot。
- **当前源码**：[`kvm_set_phys_mem()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/kvm/kvm-all.c#L1631)筛选 RAM/ROMD；[`kvm_set_user_memory_region()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/kvm/kvm-all.c#L369)提交 slot、GPA、大小、用户态地址与 flags。
- **综合判断**：QEMU AddressSpace 定义客户机资源图，KVM slot 提供硬件二阶段映射的 RAM 后端与 dirty policy；两者不能互换。

## 从 shadow MMU 到 RISC-V G-stage

### KVM-MMU-001：客户机模式没有解决内存虚拟化

- **已验证**：初始邮件称当时 MMU 性能“non-stellar”，因为地址空间切换会丢弃 shadow 条目；计划缓存 shadow，并等待 nested page table。
- **已验证**：2007 论文解释 shadow MMU 合成 GVA→HPA，写保护客户机页表并 trap/emulate 更新，需要反向映射与缓存。
- **已验证**：Avi Kivity 在 2007 KVM Forum 的 [Shadowy Depths of the KVM MMU](https://gitlab.com/qemu-project/kvm-forum/-/raw/main/_attachments/2007/KvmForum2007%24shadowy-depths-of-the-kvm-mmu.pdf)将目标列为正确性、性能、可接受最坏情况和可维护性。
- **当前 RISC-V**：H 扩展用 VS-stage 完成 GVA→GPA，用 G-stage 完成 GPA→HPA；memory slot 仍提供 GPA 后端和权限/脏页政策。
- **综合判断**：EPT/NPT/G-stage 消除了大量 shadow page-table 维护，没有取消 QEMU/KVM 之间的内存注册与生命周期协议。

## exit 经济学与 I/O 边界

### KVM-IO-001：退出必须按消费层分类

- **已验证**：2007 论文描述三层循环：硬件进入客户机；KVM 在内核处理宿主中断和 shadow fault；I/O、信号等返回用户态。
- **当前源码**：`kvm_cpu_exec()` 释放 BQL 后执行 `KVM_RUN`；通用 exit switch 处理 MMIO/system event，RISC-V 架构函数处理 SBI、CSR_SEED、debug。
- **综合判断**：性能分析要统计 exit reason、批量大小、线程唤醒、后端与重新进入，单次 ioctl 时间不足以定位瓶颈。

### KVM-IO-002：virtio 是协议决策

- **已验证**：Dor Laor 在 2007 KVM Forum 的 [PV devices 演讲](https://gitlab.com/qemu-project/kvm-forum/-/raw/main/_attachments/2007/KvmForum2007%24kvm_pv_drv.pdf)报告 RTL8139 约 55 Mbps 且产生大量 exit，e1000 仍约每包 2–3 次 exit；目标包括近原生、进入 Linux、复用、用户态后端、脱离 KVM 可工作。
- **当前 RISC-V**：`virt` 使用 virtio-mmio/PCI transport，descriptor 与 ring 位于已注册 RAM；notify 可经用户态 MMIO 或 ioeventfd，完成中断可经 QEMU 或 irqfd。
- **综合判断**：virtio 的主要转折是共享队列、批处理和 feature negotiation；vhost 再移动数据面位置。任何移动都要补 reset、dirty log、in-flight 和迁移协议。

### KVM-IO-003：RISC-V AIA full/split

- **已验证**：Yong-Xuan Wang 的 [KVM AIA v7 series](https://patchew.org/QEMU/20230727102439.22554-1-yongxuan.wang%40sifive.com/)形成 `emul`、`hwaccel`、`auto`；Jim Shu、Daniel Henrique Barboza、Andrew Jones review，Alistair Francis 签入，主提交 [`9634ef7e`](https://gitlab.com/qemu-project/qemu/-/commit/9634ef7eda5f5b57f03924351a213b776f6b8a23)。
- **已验证**：Daniel Henrique Barboza 的 [split v2](https://patchew.org/QEMU/20241119191706.718860-1-dbarboza%40ventanamicro.com/)由 Alistair Francis review/签入；提交 [`3fd619db`](https://gitlab.com/qemu-project/qemu/-/commit/3fd619db239fb37557dcd51a4b900417b893d706)、[`ce7320bf`](https://gitlab.com/qemu-project/qemu/-/commit/ce7320bf5641bfcf864c2ad9a31358c41a686c10)。
- **当前源码**：split 下 QEMU 模拟 APLIC，KVM 负责 IMSIC；`kvm_riscv_aia_create()` 跳过内核 APLIC source/address 配置。
- **综合判断**：irqchip 可按状态访问频率、硬件能力与迁移要求拆分；“全部进内核”不是唯一方向。

## qemu-kvm 上游合流

### KVM-UPSTREAM-001：accelerator 接入涉及全局协议

- **已验证**：Anthony Liguori 于 2008-11 提交 [`Add KVM support to QEMU`](https://gitlab.com/qemu-project/qemu/-/commit/7ba1e61953f4592606e60b2e7507ff6a6faf861a)，以 opt-in 方式加入最小 KVM 启动路径并给出 TCG/KVM 对比。
- **已验证**：[review 线程](https://lists.gnu.org/archive/html/qemu-devel/2008-11/msg00174.html)中，Avi Kivity追问 live migration dirty bitmap、信号与寄存器状态；Anthony Liguori 讨论 I/O thread 与避免全局状态。
- **综合判断**：将 KVM 放入 QEMU 主线需要 accelerator、线程、AddressSpace、设备与 migration 共同收敛，无法靠独立 CPU 文件完成。

### KVM-UPSTREAM-002：fork 同步成本

- **已验证**：历史 [`qemu-kvm` 仓库](https://kernel.googlesource.com/pub/scm/virt/kvm/qemu-kvm/)长期承载先行功能。
- **已验证**：Paolo Bonzini 在 [FOSDEM 2012 报告](https://archive.fosdem.org/2012/schedule/event/444/82_fosdem12.pdf)提出优先上游、尽早上游、频繁合并，并展示剩余 fork 差异已小于约七千行。
- **综合判断**：fork 的主要长期成本是同步 machine、设备、block、migration、安全修复和测试；当前上游 `accel/kvm/` 共享公共基础设施，是合流后的维护选择。

## 状态、dirty log 与迁移

### KVM-MIG-001：迁移是状态所有权协议

- **已验证**：Anthony Liguori、Uri Lublin 的 [KVM Forum 2007 live migration](https://gitlab.com/qemu-project/kvm-forum/-/raw/main/_attachments/2007/KvmForum2007%24Kvm_Live_Migration_Forum_2007.pdf)说明 pre-copy、停机、QEMU/KVM 脏页合并、版本化设备 save/load、KVM 状态同步到 QEMU，以及避免 split brain 的源/目标握手。
- **当前源码**：`kvm_cpu_synchronize_state()` 从内核 get CPU 状态并设置 `vcpu_dirty`；put 成功后清除；[`kvm_physical_sync_dirty_bitmap()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/kvm/kvm-all.c#L932)读取 bitmap 或配合 dirty ring。
- **已验证**：RISC-V runtime put 跳过 FP/Vector，注释说明 KVM 已持有正确值且 QEMU exit handler 不修改，可省约 68 次 one-reg ioctl；reset/full 路径仍同步。
- **综合判断**：每项热路径优化都依赖一个状态 invariant，review 必须同时检查暂停、reset、迁移和未来修改者能否维持它。

### KVM-MIG-002：timer frequency 边界

- **当前源码**：RISC-V timer get 读取 time/compare/state/frequency；[`vmstate_kvmtimer`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/machine.c#L212)只传输 time/compare/state；迁移 put 时比较目标 frequency，不同则报告错误，注释称当前不支持。
- **结论**：**已验证**固定基线没有跨不同 timer frequency 的转换协议。部署应预检，不能从两端都有 timer one-reg 推导兼容。

### KVM-MIG-003：in-kernel AIA save/restore

- **当前源码**：`kvm_riscv_aia_create()`含创建、配置和初始化，固定文件中没有完整的 KVM AIA runtime state get/put 与 VMState 接线。
- **后续线索**：标签之后出现 [AIA save/restore v3 series](https://patchew.org/QEMU/20260602142709086IsQxEt0LYI9ygtpFnj-XN%40zte.com.cn/)。
- **状态**：**开放**。不能从 in-kernel AIA 可启动推导 live migration；也不能仅凭后续 patch 声称每种旧配置必然有同一 bug。需要固定 QEMU/内核/mode 实测。

## 当代 RISC-V KVM 接入案例

### KVM-RISCV-001：最小 series 的拆分

- **已验证**：Yifei Jiang 的 RISC-V KVM 支持经过多个版本，2022-01 合入的 [v5 series](https://patchwork-proxy.ozlabs.org/project/kvm-riscv/list/?order=name&series=280661&state=%2A)拆为 UAPI header、公共接口、register get/put、direct boot、timer、accelerator enable 等 13 项。
- **人物**：Yifei Jiang 为主要 Contributor；Mingwang Li 共同签署；Alistair Francis review 并经维护路径签入；Anup Patel 提供 review。
- **当前落点**：direct boot reset 设置 kernel PC、`a0=hartid`、`a1=FDT`；scratch vCPU 提前探测 ISA/one-reg；RISC-V KVM 与通用 `accel/kvm/` 分层。
- **综合判断**：拆分顺序让 reviewer 分别验证 ABI、CPU 状态、timer 与 machine 启动契约，适合作为社区协作案例。

### KVM-RISCV-002：H capability 与 nested 的边界

- **当前源码**：`kvm_misa_ext_cfgs` 映射 `RVH` 到 `KVM_RISCV_ISA_EXT_H`；[`vmstate_hyper`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/machine.c#L87)保存 TCG 架构模型中的 H/VS 状态；当前 KVM get/put 路径没有完整对应的 H/VS nested 状态组。
- **上游线索**：Linux RISC-V nested KVM [v1 series](https://lists.infradead.org/pipermail/linux-riscv/2026-January/084034.html)仍处于开发，并明确 v1 尚不能运行 L2。
- **状态**：**开放**。必须分开验证：L0 用 H 加速 L1；L1 看见 H；L1 运行 L2；活跃 L2 迁移。前一项不能证明后一项。

## 正文引用清单

第三篇只保留四类历史转折：

1. 2006 初始 `/dev/kvm`：解释 Linux 进程/vCPU 线程/QEMU 设备分层；
2. API v1 到对象 fd/共享运行页：解释当前 UAPI；
3. 2007 virtio 与 live migration：解释 exit 优化和状态所有权；
4. 2008 KVM 入 QEMU、qemu-kvm 合流：解释 accelerator 上游化与 fork 成本。

其余提交、review 角色和开放问题留在本账本。正文任何当前行为都应回到 RISC-V `v11.1.0-rc0` 源码与实验，不用 x86 历史材料代替当代实现验证。
