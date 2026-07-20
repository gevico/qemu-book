# 怎样证明模型在升级后仍正确

一个容易漏掉的回归可以这样发生：外设模型今天能让 Linux 启动，明天改完 reset 逻辑仍然能启动；直到活动状态迁移测试才发现，源端已经 pending 的中断在目标端没有形成相同输出。原来的启动测试一直是绿的，因为客户机每次都从 reset 值开始，从未让 IRQ、timer 和队列处于活动状态。这是本章用来设计反例的教学场景，不是对 K230 当前实现已经存在该缺陷的断言。

“能启动”只覆盖了一条很长的正常路径。QEMU 模型还要面对非法 MMIO、复位、并发、迁移、旧版本、不同 accelerator 和恶意客户机输入。本章以 RISC-V K230 watchdog 与 `virt` 平台为参照，把测试组织成一组接口契约。源码基线仍固定为 `v11.1.0-rc0`，避免用主线后续变化替固定版本作保证。

## 先写可能被破坏的契约

测试设计从客户机可见行为开始。若一个 32 位小端 watchdog 的规格与模型承诺下列行为，就要把它们逐条写成待验证契约：规定宽度和对齐的访问；控制寄存器只保存可写位；restart magic 重装计数器；interrupt mode 到期后置 pending 并拉高 IRQ；EOI 清 pending；reset 停止 timer、恢复寄存器并降低输出；迁移后剩余时间、pending 和输出保持连续。契约来自规格与对外承诺，不能仅从结构体字段反推；每一条都要构造输入和观察结果。

契约还要标出状态所有者。寄存器属于设备对象，倒计时由 `ptimer` 推进，IRQ 线路连接到 RISC-V 中断控制器，Machine 决定 MMIO 地址和 source，迁移框架负责传输字段。若测试失败，所有者信息能告诉我们应该查寄存器回调、timer、Machine wiring 还是 VMState。

最后写反例。reset 测试不能只调用 reset，它要先把控制位、counter 和 IRQ 置为非默认，再验证清理；迁移测试不能只搬运 idle VM，它要让计数器运行、pending 被 mask 或请求尚未完成。缺陷存在时仍然通过的测试，只是执行了一遍代码。

判据还应独立于被测实现。若设备函数和测试都调用同一个 timeout helper，helper 算错时两边会一起给出相同答案。测试可以从数据手册列出几个边界常量，或用一份很小的独立规格函数计算期望值。真实 Linux 驱动也能提供行为反馈，但驱动只使用寄存器子集，不能替代完整规格。oracle 的来源和适用范围应与测试结果一起保存。

:::: {.quick-quiz}
为什么用 reset 状态做迁移冒烟，容易得到虚假的安全感？

::: {.quick-answer}
目标端重新创建对象时本来就会得到 reset 值。即使某个字段完全没有进入迁移流，结果也可能碰巧相同。把计数器、pending、队列和 timer 置为非默认，才能证明状态确实跨过边界。
:::
::::

## 四层测试分别守住一段边界

QEMU 没有一种测试能独自证明模型正确。更实用的分层如下：

| 层次 | RISC-V 例子 | 主要回答的问题 | 不覆盖什么 |
|---|---|---|---|
| 纯状态/单元测试 | 寄存器 mask、timeout 算法 | 局部转换是否符合规则 | QOM、总线和 IRQ wiring |
| qtest | K230 WDT MMIO、虚拟时钟 | 寄存器、reset 路径与 STAT/EOI 行为是否可从总线观察 | 外部 IRQ pin 与固件/真实驱动发现流程 |
| functional test | K230 direct boot、U-Boot 启动 | Machine、固件、DTB、内核能否组合工作 | 所有非法访问与活动迁移 |
| migration/兼容测试 | 两个 riscv64 QEMU 进程 | 状态能否保存、恢复并继续 | 未列入矩阵的版本和宿主能力 |

每增加一个所有者，就增加一层测试。纯寄存器逻辑通过、qtest 失败，范围通常落在访问宽度、endianness 或 callback；qtest 通过、Linux probe 失败，继续查地址图、DTB 和中断连接；同版本运行通过、迁移后失败，则沿“权威状态—pre-save—字段—post-load—输出重算”查找。分层的价值在于让红灯指向一个可以行动的范围。

## qtest 把设备从客户机软件中剥离出来

qtest 启动 QEMU 后，通过协议直接读写物理地址、操作 IRQ、推进虚拟时钟。它不需要先写固件或驱动，适合验证 MMIO 设备。固定锚点的 [`tests/qtest/k230-wdt-test.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/tests/qtest/k230-wdt-test.c) 会在 `-machine k230` 上检查 CR/TORR/protection mask、restart、STAT/EOI 寄存器行为、两个 watchdog 和 enable/disable；它没有直接探测输出 IRQ pin。

读测试源码比看到测试名更重要。当前 `test_interrupt_mode()` 推进 qtest clock，读取 STAT，并在 EOI 后确认中断位清零，这是一条明确断言。`test_reset_mode()` 则推进时钟后直接退出，没有对 reset 事件或 reset 后状态作断言；它可以执行该路径，却不能单独证明 reset mode 的客户机契约。这种差距很适合训练 review：先让测试在故障版本上红，再讨论补什么观测点。

timer 测试使用 `qtest_clock_step()`，避免宿主 `sleep()` 把 CI 调度抖动混进设备时间。非法输入仍应覆盖 8/16 位访问、未对齐地址、只读寄存器写入、错误 restart magic 和越界 offset，但预期要服从真实事务契约。当前 [`k230_wdt_ops`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/watchdog/k230_wdt.c) 声明 little-endian，并只在 `.impl` 中把回调实现粒度设为 4 字节，没有用 `.valid` 宣布较窄客户机事务无效；内存核心可能拆分或合并访问。若硬件契约要求直接拒绝 8/16 位事务，模型要补 `.valid`，qtest 再验证拒绝行为，不能从 `.impl` 推导结论。

## functional test 验证平台契约

qtest 可以证明 watchdog 回调工作，却无法证明固件能找到它。functional test 把 Machine 地址图、CPU、启动方式、DTB、串口和真实客户机软件装在一起。当前 [`test_k230.py`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/tests/functional/riscv64/test_k230.py) 覆盖两条启动链：QEMU 直接装载 Linux 所需资产，以及先进入 K230 SDK U-Boot 再启动 OpenSBI/Linux。两条路径都等待明确的 initramfs 标记和 shell prompt。

外部资产必须固定内容。K230 测试把 URL 锁定到具体仓库 commit，并为 kernel、DTB、initrd、U-Boot 和 firmware 写 SHA-256。网络能够下载文件，只证明 URL 可访问；哈希相同才说明输入没有被悄悄替换。CI 失败时还要保存完整命令、串口尾部、退出码与阶段判据，区分固件未起、内核未解压、驱动 probe 失败和 shell 未出现。

QEMU 把 functional tests 分为 quick 与 thorough，是为了同时控制反馈时延和资产成本。快速测试进入普通提交反馈，下载大镜像、长时间运行和多版本矩阵放到专门任务。框架如何演进只是这项工程选择的背景；对设备作者而言，决定分类的依据是失败价值、运行时间和外部依赖。

## reset、错误路径和模糊输入要主动制造

reset、realize 失败和迁移 load 失败都处在生命周期边界。设备 reset 应清理本地状态和对外副作用；realize 在属性非法、后端缺失时应返回具体 Error，并撤销已经注册的资源；迁移流不合法时，目标必须在 vCPU 运行前拒绝。只跑一次正常创建和进程退出，晚到 timer、未降低 IRQ、fd 泄漏和半初始化对象都可能被进程销毁遮住。

错误测试应制造正在发生的工作。让 watchdog 即将到期时 reset，确认旧 callback 不会在新周期抬起 IRQ；让 virtio 请求 in-flight 时取消迁移，确认源端恢复执行；让一个 device realize 在最后一步失败，再创建合法实例，确认前一次没有污染对象树。重复数十次负面路径还能暴露 fd、线程和 socket 泄漏。

性质测试和 fuzz 适合探索状态组合。可以声明“只读位在任意写入后不变”“reset 两次与一次结果相同”“EOI 只清目标 pending”，再生成 MMIO、clock step 和 reset 序列。qtest fuzzer 的客户机输入包括地址、大小、数据和时序，发现 crash 后保存 seed、缩减序列并加入固定回归。Rust 能减少局部越界，也不能替设备验证 guest-controlled offset、长度和状态机。

差分测试需要独立参照。教学设备可让 C、Rust 两种实现执行同一寄存器序列，也可与独立规格函数比较。两份代码若复制了同一位运算，可能一起出错；出现差异时仍要回到硬件资料和客户机契约判断。TCG 与 KVM 也可提供行为对照，但宿主 capability、未定义行为和时间源先要归一。

## VMState 保存行为所需的状态

迁移不会复制一个 C/Rust 结构体。指针、锁、padding、MemoryRegion、宿主 fd 和缓存到目标进程都没有原语义。[`VMStateDescription`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/include/migration/vmstate.h) 显式列出字段、版本、存在条件和 pre/post hook；目标先创建同构对象图，再加载决定客户机下一步行为的状态。

K230 watchdog 的当前 VMState 包含 `ptimer`、控制/超时/状态寄存器、pending、enabled 与计数值。固定基线的 reset 路径没有显式调用 `qemu_set_irq(..., 0)`，VMState 也没有专门的 `post_load` 重驱 IRQ；PLIC 自己又保存部分 pending 状态，所以这些事实既不能直接证明存在缺陷，也不能证明输出连续。源端 counter 由谁持有、timer 如何冻结、reset 后输出是否降低、目标端怎样重建 IRQ、非法组合在哪个 hook 被拒绝，都需要非默认活动状态实验闭合。

版本字段服务于流格式演进。新增字段要定义旧流默认，改变语义时要保留旧版本解释，optional subsection 的条件应来自稳定配置。测试至少包含当前到当前、旧到当前、当前到旧三个方向；产品若只承诺单向升级，也要把反向写成预期拒绝。`query-migrate` 返回 `completed` 只说明控制面完成，恢复后的计数、IRQ、timer 和 I/O 还要继续运行多个周期。

RISC-V CPU 状态也按所有者拆开。TCG 的大部分状态在 `CPURISCVState`，KVM 的最新 GPR、CSR、Vector 与 timer 可能在内核。[`target/riscv/machine.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/machine.c) 为 PMP、H、Vector、KVM timer 和 debug 等状态定义不同 section/条件。TCG 迁移通过不能覆盖 KVM one-reg 同步，普通 S 态通过也不能覆盖活动 VS/H 上下文。

:::: {.quick-quiz}
为什么 VMState 中出现了某个字段，仍然不足以证明迁移正确？

::: {.quick-answer}
字段可能只是用户态旧镜像，源端需要先从内核或后端取回权威状态；目标还要校验、重建 timer/IRQ 等派生状态，并在完成前阻止 vCPU 运行。保存、传输、加载和恢复缺一段都可能在下一次事件上偏离。
:::
::::

## 兼容性要拆成矩阵

“兼容”至少包含四个维度：客户机看到的硬件接口、QMP 管理接口、迁移流格式、宿主执行能力。相同 Machine 名称下，CPU 扩展、AIA/PLIC 模式、virtio 后端和 KVM capability 仍可能不同；迁移流能读取，也不代表目标宿主能恢复同样的 Vector 长度或 irqchip。

Machine version 常用来固定旧默认和 compat properties，VMState version 则描述运行状态格式。两者不能互相代替。固定锚点的 [`hw/riscv/virt.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/virt.c) 注册 `virt`，没有常见的 `virt-X.Y` 版本系列。于是本书实验必须显式固定 CPU、扩展、hart 数、AIA/PLIC、IOMMU、内存、固件与设备，结论限定到所测的两个二进制和方向。

矩阵中的格子只允许四种状态：有源码闭环且运行验证、只有源码审查、预期不支持、尚未验证。skip 不能算 pass，找不到测试也只能写“未找到直接覆盖”。负面用例还要规定失败时机：目标缺必要 CPU 扩展，最好在源端停机前拒绝；损坏流只能在 load 时发现，也必须保证 vCPU 尚未运行。

矩阵本身也要能复现。每个已验证格子至少保存源端和目标端的完整版本、Machine 与 CPU 参数、accelerator、固件和镜像哈希、迁移 URI、运行判据及宿主 capability。测试失败后若只留下“riscv64 migration failed”，维护者无法判断是模型回归、内核能力变化还是输入漂移。配置清单与串口、QMP 记录共同构成测试证据；以后扩大承诺时，新增的是一格有边界的结果，而非一句笼统的“兼容”。

## 一项 RISC-V 模型怎样长出测试

新增寄存器时，先用纯状态测试覆盖 mask、reset 和非法值，再用 qtest 穿过 MemoryRegion。加入 IRQ 后，分别验证 pending 逻辑、qemu_irq 电平和 Machine 到 PLIC/APLIC 的 source；functional test 最后让真实驱动处理中断。加入 timer 后，用虚拟时钟推进边界；加入 DMA/队列后，覆盖长度、地址溢出、IOMMU fault、短读和 in-flight migration。

测试与功能补丁可以分层提交。第一组给寄存器与 qtest，第二组接平台与 functional，第三组列 VMState 和活动迁移。每一组都能由相应 reviewer 独立检查。安全相关输入放在最快的单元/qtest，真实启动放 quick 或 thorough，跨版本与低概率竞态交给定时 CI。

CI 绿色之外还要维护覆盖债务：RISC-V KVM runner 缺失、某种 in-kernel AIA 状态未验证、functional asset 暂时不可用，都应有负责人和退出条件。flaky 先保存 seed、宿主和最后进展，再定位同步或资源问题；无限重试只会降低报警概率。测试代码同样要 review：断言是否能在缺陷存在时失败，skip 是否过宽，cleanup 是否只停止自己启动的进程。

:::: {.quick-quiz}
为什么 qtest 已经通过以后，还需要 RISC-V functional test？

::: {.quick-answer}
qtest 能直接验证设备寄存器、时钟和 IRQ，却绕过了固件、DTB、驱动发现及整机 wiring。functional test 负责证明这些组件能按 Machine 契约组合运行，两层失败对应不同的修复入口。
:::
::::

## 两个实验建立可执行证据

### 实验一：运行并审查 RISC-V qtest

::: {.hands-on}
配套英文实验手册：[`run-riscv-qtests`](../experiments/part-05-engineering-and-evolution/chapter-21-testing-and-compatibility/run-riscv-qtests/README.md)。

脚本先从当前 Meson 构建列出真实测试名，再选择 RISC-V CSR/IOMMU 等窄测试。运行以后不要停在 pass：打开测试源码，记录每条 assertion、Machine/accelerator 和未覆盖边界。可在一次性分支中制造 reset 不清 pending 或保留位可写，确认最小测试先红、修复后变绿。
:::

### 实验二：迁移一个正在运行的 riscv64 计数器

::: {.hands-on}
配套英文实验手册：[`migration-compatibility-smoke`](../experiments/part-05-engineering-and-evolution/chapter-21-testing-and-compatibility/migration-compatibility-smoke/README.md)。

实验用两个 RISC-V TCG 进程迁移带串口校验的 bare-metal 计数器。匹配配置要求目标计数继续增长；故意改变内存大小的负面路径要求迁移明确失败。它证明指定同版本配置的状态连续与拒绝行为，尚未覆盖磁盘、网络、KVM、跨版本或复杂 irqchip。
:::

## 小结

模型正确性来自一组能在缺陷出现时失败的契约。单元测试守局部状态，qtest 守设备与总线，functional test 守 RISC-V 平台组合，migration test 守跨进程连续；性质、fuzz 和负面用例探索正常启动看不到的边界。测试越接近具体所有者，失败越容易转化为修复。

升级后的保证也必须带范围。Machine、VMState、QMP 和宿主 capability 属于不同兼容维度，TCG 与 KVM 又拥有不同状态。把版本、方向、活动状态和 skip 写进矩阵，绿色结果才不会被转述成超出证据的承诺。
