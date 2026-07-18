# K230 与 G233 SoC 建模

真实 SoC 很适合检验前面各章是否真正连在一起：CPU 扩展、复位地址、片上存储、UART、中断控制器、设备树和固件只要有一处不一致，启动就会在远离根因的地方停住。K230 已进入 QEMU 当前上游，G233 则作为本书的树外综合模型。两者必须分开陈述证据，不能把教学实现包装成官方支持。

## 本章目标

- 从数据手册、固件和 Linux 驱动提取 SoC 的最小可启动契约；
- 复盘 K230 补丁从 v1 到 v8 如何在审查中修正模型；
- 用同一方法规划 G233 的分阶段实现、验证和上游准备。

## 四种材料，四种语气

本章沿用全书固定口径：目标版本写作 QEMU `v11.1.0`，源码审计锚定官方 GitLab [`v11.1.0-rc0`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0) 的 commit `eca2c16212ef9dcb0871de39bb9d1c2efebe76be`。能够在该树直接核对的类型、地址、设备连线和测试，标作“源码事实”；补丁作者在提交说明、cover letter 或 qemu-devel 中写出的动机，标作“上游陈述”；根据代码和启动现象归纳的取舍，标作“作者推断”；缺少公开资料或实机结果的内容，放进“开放问题”。这套标记不是修辞，它决定读者能否复现结论。

K230 已有当前上游模型，因此我们可以对照代码、文档、测试和补丁演进。G233 在固定标签中没有 Machine、SoC 类型或 CPU 型号，检索 `hw/riscv/`、`target/riscv/` 与全树均得不到同名实现；本章研究基线也没有找到足以确认其地址图、hart 配置和启动协议的公开一手规格。由此只能确认“G233 是本书计划研究的名称”，不能确认任何硬件参数。后文的 G233 部分只设计证据表和分阶段骨架，所有字段初始状态保持 unknown。

同一段文字中还要区分实物能力和 QEMU 支持范围。厂商产品页可能列出双核、KPU、GPU、VPU 或 ISP，固定源码中的 Machine 却可能只建模一个 hart，并把加速器区域设为占位。实物清单可以帮助发现缺口，不能直接证明 QEMU 的行为；QEMU 中存在地址常量，也不能证明对应硬件功能。每次写“支持”之前，都应回答支持到哪条寄存器、哪种启动路径、由哪个测试证明。

:::: {.quick-quiz}
为什么“数据手册说有该外设”和“QEMU 内存图有同名常量”仍不能合并为“QEMU 支持该外设”？

::: {.quick-answer}
数据手册描述实物，地址常量只说明模型为范围留了位置。还要看到设备类型、寄存器语义、IRQ/DMA 连线及可复现测试，才能说明 QEMU 支持到什么程度。
:::
::::

## 建一个可以审计的事实账本

SoC 资料经常来自多个版本。工程开始时可为每条结论记录对象、值、来源、版本、证据定位、可信等级和验证状态。例如“reset PC 为某地址”要能落到当前 `k230.c` 的赋值或公开 ROM 规范；“串口能输出”还要有启动命令、固件哈希和预期文本。若只有一张二手框图，就把它记作线索，不填入 verified。账本允许值冲突，因为冲突本身会告诉我们需要找哪类证据。

源码事实也要写完整上下文。常量在 memmap 中出现，可能只被 `create_unimplemented_device()` 使用；IRQ 编号在枚举里出现，设备却未连接；Machine 属性有缺省值，也可能被命令行覆盖。只摘一行会制造错误确定性。账本最好包含调用点和运行检查，随后由小脚本验证路径仍存在、标签仍是预期 commit，防止书籍更新时链接悄悄漂移。

上游邮件适合解释演进，却不能取代当前代码。补丁 v3 曾采用一个值，v7 又改掉，读者若只读旧 cover letter，就会把历史状态误写为当前行为。正确顺序是先在固定 tag 得到现状，再执行 `git log --follow` 找引入和修改提交，然后回到对应 Message-ID 或 Patchew 系列看审查语境。最后仍以当前实现和测试收口，未合入的建议保持候选状态。

开放问题也要可操作。不要只写“G233 资料不足”，应列出复位地址未知、hart 数未知、中断控制器未知、UART 兼容类型未知、固件许可未知，并为每项写出可接受证据，例如公开手册章节、厂商设备树、可再分发固件源码或实机 trace。这样的 unknown 能驱动调查；凭经验填入一个看似常见的十六进制地址，只会让后续所有代码围绕未经证明的常量生长。

## K230 给出的第一课：最小模型也要一致

QEMU `v11.1.0-rc0` 的 K230 入口位于 `hw/riscv/k230.c`，还包含看门狗模型、qtest、functional test 和系统文档。当前代码没有完整模拟芯片上的每个模块，它围绕可支持的启动路径选择 CPU、内存、UART、中断和必要控制寄存器。没有实现的部分需要明确处理，既不能让访问无声落空，也不应伪造超出证据的功能。

K230 上游补丁经历多轮审查。系列中陆续修正 CPU 扩展、PLIC/CLINT 地址、reset vector、未实现 UART MMIO、hart 数、直接启动、WDT IRQ 与 M-mode 判定，并补充 Machine 接口和启动测试。这些变化说明板级模型的正确性不是“地址表抄完”就完成，固件实际行为、异常路径和测试结果会反过来修订最初假设。

固定标签中的入口是 [`hw/riscv/k230.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/k230.c) 与 [`include/hw/riscv/k230.h`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/include/hw/riscv/k230.h)。`k230` Machine 当前把 `default_cpus` 设为 1，SoC 创建一组 hart，并选择 `TYPE_RISCV_CPU_THEAD_C908`。因此“当前模型默认一个 C908 hart”是源码事实。实物资料里的其他核心或异构单元不能被写进这句话；若要讨论它们，应单列为硬件背景或未支持能力。

`k230_soc_init()` 在对象阶段初始化 hart array，并创建两个看门狗 child；reset vector 设为 `K230_DEV_BOOTROM`，其地址为 `0x91200000`。realize 阶段再建立内存、PLIC、ACLINT、串口和看门狗。这个分工体现 QOM 生命周期：init 适合创建子对象和缺省关系，realize 才依据 machine 参数连接需要失败报告的资源。把所有工作塞入 init，会使错误传播和清理变得困难。

当前模型实现 SRAM 与 boot ROM，建立 PLIC，以及 ACLINT 的软件中断和 machine timer。PLIC 基址是 `0xF00000000`，CLINT/ACLINT 区域从 `0xF04000000` 展开。正文引用这些值，只是帮助读者追踪当前代码，不能把它们泛化为“所有 RISC-V SoC 的标准地址”。`virt`、K230 和香山昆明湖各自有平台契约，复用控制器模型不代表复用地址图。

五段 UART 窗口由辅助函数创建。值得细看的是，代码先用 `create_unimplemented_device()` 覆盖完整 `0x1000` 大小的窗口，再在相应位置映射 16550 兼容串口，`regshift` 为 2，输入频率参数为 399193，端序为 little endian。上游 v7 变更记录提到修正未实现 UART MMIO 引起的 Oops。作者推断，完整窗口占位用于让串口实现未覆盖的访问得到可诊断行为，避免落入不可预测的空洞；它不意味着整段寄存器都已实现。

:::: {.quick-quiz}
K230 UART 窗口已经被 `create_unimplemented_device()` 覆盖，为什么还要在其中映射串口设备？

::: {.quick-answer}
占位处理串口模型没有覆盖的地址，真正的 16550 兼容区域仍需设备实现寄存器和字符输出。两层重叠表达“局部已实现、其余明确未实现”，不是两个完整 UART。
:::
::::

## 一张内存图里有三种对象

读 `k230_memmap` 时应给每个条目分类。RAM、boot ROM、PLIC、ACLINT、UART 和 WDT 有实际 MemoryRegion 或设备类型，属于当前模型能执行的路径；KPU L2/cache/config、FFT、AI 2D engine、DMA、ISP、VPU、`gpu`、3D engine、RTC、timer 和若干存储控制器，在当前实现中由 `create_unimplemented_device()` 建立区域；还有一些硬件能力可能根本未在枚举出现。已实现、占位和缺席是三个不同状态。

unimplemented 设备很有用。固件探测未知寄存器时，QEMU 可以记录设备名和地址，让开发者知道启动卡在何处；地址范围也不会无声地落到其他 region。它的返回值和日志行为仍不是硬件规范，驱动若依赖该值继续启动，只能说明这一固件路径碰巧容忍占位。文档应列明占位范围，让读者看到串口打印或 Linux shell 时，不会误以为所有探测过的加速器都能工作。

将占位升级为设备实现时，不能直接在 `k230.c` 堆寄存器数组。先判断该控制器是否也出现在其他 SoC，若语义通用，应建立独立 QOM 类型、文档和 qtest，Machine 只负责地址与 IRQ 连线。若只是系统控制器的一小段，仍要有状态结构、访问掩码和 reset。升级后移除相应占位，测试访问边界，避免两个 MemoryRegion 的优先级掩盖错误。

地址重叠需要主动审计。SoC 手册可能把一个大模块窗口分成若干子块，QEMU 的 container/subregion 能表达层级；若简单按扁平顺序添加，后加入区域可能覆盖先前模型。实验脚本可以导出 base、size、实现类型，按半开区间检查交叠，再人工判断交叠是否有意。对 UART 这类有意覆盖，账本记录父窗口、子设备和 priority；对无证据重叠则阻止提交。

:::: {.quick-quiz}
固件访问 KPU 寄存器后继续启动，能否据此把 KPU 从“占位”改写成“最小实现”？

::: {.quick-answer}
不能。继续启动只证明该固件路径容忍当前返回行为，没有计算、状态或中断语义。仍应标作占位，并记录软件为何没有依赖它。
:::
::::

## 两条启动路径，两组契约

当前 Machine 在 machine-done 阶段根据是否提供 kernel 选择 direct boot 或 firmware boot。直接启动要求 OpenSBI，并显式提供 DTB；固定加载地址包括 OpenSBI `0x08000000`、kernel `0x08200000`、DTB `0x0a000000`，实现还检查固件与 kernel 是否重叠。这些是当前源码事实，适合让实验通过 PC、内存内容和串口逐段检查，不代表 K230 实物 ROM 永远采用同一开发启动布局。

firmware boot 路径不接受 direct-kernel 所需的 `-dtb` 和 `-append` 组合，Machine 会拒绝不一致配置。这样的早期报错很重要：若让参数静默生效一半，用户可能在固件内部追查根本不存在的问题。文档应把两条完整命令分开，CI 也分别覆盖，而不能把一条路径的参数复制到另一条后再靠偶然行为启动。

直接启动的检查点可以细分。创建 Machine 后确认 reset PC 指向 boot ROM，ROM stub 跳转到 OpenSBI，OpenSBI 进入下一阶段，kernel 读取外部 DTB，UART 打印首个稳定标志。每个节点都能用 `-d` 日志、GDB、串口正则或内存读取观察。若 kernel 没有打印，先看 PC 是否到达 `0x08200000`，比立即怀疑 UART 更有效。

固件启动则应固定镜像来源、哈希和许可，记录它是否内嵌 DTB，以及固件期待哪些占位寄存器。不可再分发的厂商镜像不应塞进仓库或 Release，实验手册可以要求用户自行提供，并说明校验方式。若 CI 需要稳定自动化，优先使用公开可再分发的测试资产或自建最小固件，不能让秘密下载链接成为上游测试依赖。

:::: {.quick-quiz}
direct boot 已把 DTB 放到固定地址，为什么仍要在命令行强制要求 `-dtb`？

::: {.quick-answer}
地址只规定“放在哪里”，不会产生与 Machine 和客户机内核匹配的设备树。当前路径把外部 DTB 作为明确输入，缺失时早期失败，避免内核拿到未知内容后才挂住。
:::
::::

## MAEE 是一个诚实的兼容边界

[`docs/system/riscv/k230.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/system/riscv/k230.rst) 说明，K230 SDK 的一些 Linux kernel 使用 T-HEAD 私有 MAEE 页表属性，而通用 QEMU RISC-V MMU 没有实现这套私有 PTE 解释，需要用标准 RISC-V PTE 位重新构建内核。这个限制直接影响“镜像能否启动”，因而必须出现在用户文档，不能隐藏在源码注释里。

这里也展示 CPU 与 SoC 模型的边界。Machine 可以把 CPU type 设为 C908，仍不表示 target/riscv 已覆盖该实物的所有私有 MMU 行为。若为了跑一个 SDK 镜像，在通用页表路径里猜测 MAEE 位含义，可能改变其他 RISC-V CPU 的语义。更稳妥的实现需要公开规范、扩展开关、译码与页表测试，并经过 target/riscv 维护者审查；当前文档选择重建标准 PTE 内核，是明确的使用约束。

实验报告应记录内核来源与配置。两个名为 `Image` 的文件，一个使用标准 PTE，一个带厂商属性，表现可能完全不同。出现早期页故障时，保存 `scause`、`stval`、`satp` 与相关页表项，才能判断是地址图、固件传参还是 PTE 解释。只截取“Kernel panic”最后一行，无法复核 MAEE 假设。

开放问题包括未来是否会出现公开 MAEE 规范和上游实现，以及它应作为哪种 CPU extension 暴露。没有相应合入提交前，本书不把可能性写成路线图承诺。读者可以把标准 PTE 镜像作为可重复基线，再在树外分支研究私有扩展，结果要明确版本和补丁集。

## 看门狗把时间、中断和复位串起来

K230 看门狗有独立实现 [`hw/watchdog/k230_wdt.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/watchdog/k230_wdt.c) 与头文件。设备包含 MMIO 操作、ptimer、IRQ/复位模式和 VMState，这些源码事实让它比单纯地址占位更适合学习。驱动写寄存器改变计数和模式，虚拟时间推进触发到期，设备再按配置拉起 IRQ 或请求复位；每条边都可以单测。

[`tests/qtest/k230-wdt-test.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/tests/qtest/k230-wdt-test.c) 提供寄存器与行为检查。读测试时不要只看最终 PASS，应整理 reset 值、访问序列、虚拟时钟推进量和 IRQ 预期。qtest 使用可控时钟能避免宿主负载让超时用例漂移，也能把“计数器没有走”与“中断线没有连”分开。

迁移要求保存客户机能观察的计数与配置状态，同时在目标端重建 timer 关系。保存宿主 timer 指针没有意义，遗漏剩余时间又会让迁移后提前或延迟复位。当前 VMState 是源码事实；它是否覆盖所有未来扩展状态，仍需迁移测试证明。可设计一次预迁移启动 WDT、在半程迁移、目标端继续推进虚拟时钟的用例，检查到期点和 IRQ 次数。

看门狗还有危险的全局效果。测试复位模式时，若只观察 QEMU 进程退出，可能混淆 guest reset、设备 reset 和测试框架结束。更清楚的做法是在 boot ROM 或 SRAM 放一个跨 reset 可判定的计数协议，串口打印代次，并用 QMP 事件辅助观察。设备模型本身不应为测试添加隐藏寄存器，测试钩子要沿已有可见行为建立。

:::: {.quick-quiz}
为什么看门狗寄存器 qtest 全部通过，仍需迁移和整机复位测试？

::: {.quick-answer}
寄存器测试覆盖局部读写，迁移涉及剩余时间重建，整机复位还跨越 IRQ、Machine 和启动固件。三者观察的是不同契约，局部通过不能代替跨组件验证。
:::
::::

## functional test 把启动命令变成证据

固定树中的 [`tests/functional/riscv64/test_k230.py`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/tests/functional/riscv64/test_k230.py) 覆盖 direct boot 与 U-Boot 路径，并为下载资产固定来源提交和 SHA256。哈希让“同名文件”变成确定输入，串口模式则把启动成功写成机器可判断的条件。测试仍受网络、资产可用性与超时影响，手工实验要保存缓存和日志，避免下载失败被误诊为设备模型回归。

系统测试的价值在于连通 CPU、ROM、内存、UART、固件和内核。它不会自动覆盖 PLIC 每个优先级、UART 所有访问宽度或 WDT 边界，因此 qtest 仍然必要。反过来，单设备 qtest 全绿也不能证明启动链。维护时可把测试矩阵分为对象级、Machine 级和软件启动级，每类失败都有较短的责任范围。

稳定断言应选择软件承诺的标志，避免匹配时间戳、内存大小自动探测细节或随机地址。若上游固件更新改变文案，先核对启动里程碑是否相同，再调整正则；若 QEMU 行为改变，应有源代码和 trace 证据。让测试只等待 shell prompt 虽然简单，却会把前面所有阶段压成一个长超时。

对本书 Release，实验 README 只描述如何复用上游源码与公开资产，实际 PDF 构建不应下载大镜像。这样文档生成保持确定、快速，运行实验由读者显式选择。CI 可以另设实验 job，按缓存和哈希管理资产；若网络不可用，它应报告 skipped 或基础设施失败，不能伪装成内容构建失败。

## 从 v1 到 v8，审查改变了什么

K230 初始板级支持合入提交是 [`6cf0d08c3953`](https://gitlab.com/qemu-project/qemu/-/commit/6cf0d08c3953ee447cb215edc3a384834cbe48db)，对应 Message-ID [`a161697a...`](https://lore.kernel.org/qemu-devel/a161697a249b896e44e2748435f6c0caec12c9f4.1781246408.git.chao.liu%40processmission.com/)。看门狗提交为 [`dace398674df`](https://gitlab.com/qemu-project/qemu/-/commit/dace398674df8af11df13f2554e8566e9de3f8c7)，qtest 为 [`43f99dc7fd30`](https://gitlab.com/qemu-project/qemu/-/commit/43f99dc7fd30cae42c43cc76f1a41beb8fd47e23)，文档为 [`b3fe55196f08`](https://gitlab.com/qemu-project/qemu/-/commit/b3fe55196f080e113129065dc19896e5cac8a3cc)。这些 commit 在固定标签可达，因而能把邮件系列与最终源码连起来。

最终 v8 系列可以从 [Patchew cover](https://patchew.org/QEMU/cover.1781246408.git.chao.liu%40processmission.com/) 阅读。其 changelog 记录多轮调整：v2 涉及 Svpbmt 与文档，v3 对齐 C908 extension 并修正 PLIC/CLINT 地址，v5 修正 reset vector 的 trap-handler 跳转，v7 处理未实现 UART MMIO、hart 数、direct boot、WDT IRQ 和文档，v8 又修正 M-mode 检查与 machine interfaces。这些是补丁作者的上游陈述，当前 commit 则用实现结果验证哪些修改最终落地。

hart 数从讨论到当前单核缺省，是很典型的工程收敛。建模目标在于让现有 CPU model、固件路径和中断拓扑形成可测试集合，产品宣传页的数字不会自动进入模型。作者推断，v7 调整体现了“只承诺已经验证的核心”这一取舍；若邮件没有明确写出完整理由，推断就停在这里，不能替作者补造性能或产品规划动机。

reset vector 修订也说明异常路径会反向检验启动 stub。短短几条 ROM 指令需要满足当前 hart 特权状态、跳转范围和 trap 行为，能从一种固件进入下一阶段，不代表异常路径正确。复盘时应把每轮差异变成测试：检查 reset PC、首条跳转目标、非法访问后的 trap，以及直接启动和固件启动分别走哪段 ROM。

functional test 后续由提交 [`a539bb911ee1`](https://gitlab.com/qemu-project/qemu/-/commit/a539bb911ee1085c69ce00781acd2f13bd3cb82b) 加入。它说明 board 合入与系统启动覆盖可以分阶段推进，也提醒读者不要用“已有 test 文件”反推初版 patch 已包含同等验证。查历史时记录提交时间和父关系，书中陈述才能保持时序正确。

:::: {.quick-quiz}
补丁 v3 的 changelog 写了一个地址修正，写书时应直接引用 v3 的值吗？

::: {.quick-answer}
应先查看固定 tag 的当前值，再用 v3 邮件解释它何时、为何被修改。历史邮件是演进证据，当前源码才是本章现状，后续版本还可能再次调整。
:::
::::

:::: {.quick-quiz}
为什么 SoC 模型拥有正确的外设地址仍可能无法启动？

::: {.quick-answer}
启动还依赖 CPU 扩展、hart 数、复位 PC、固件运行特权级、中断连线、时钟和未实现访问的处理。地址图只是跨组件契约的一部分。
:::
::::

## 从启动链反推最小集合

建模前先写出启动链：复位后在哪个地址取指，片上 ROM 或 SRAM 放什么，OpenSBI 或厂商固件如何找到下一阶段，UART 何时可用，中断和计时器由谁初始化，Linux 从设备树获得哪些节点。每一步都对应可观察检查点，例如 PC 区间、串口字节、寄存器写入和设备树内容。

最小集合不是静态清单。若固件在探测一个尚未实现的寄存器后能够降级，它可以先作为受控的 unimplemented 区域；若同一访问会决定时钟或复位，返回全零就可能把软件引向错误分支。模型应根据软件契约选择“实现、明确报错、记录未实现或暂不支持”，并用测试固定选择。

一个实用办法是为每个启动阶段设置“最早可见证据”。reset 阶段看 PC 和 ROM 字节，OpenSBI 阶段看域与下一阶段入口，内核解压阶段看 PC 区间和串口，驱动阶段看 MMIO trace 与 IRQ。上一个证据没有出现，就不必继续猜下游设备。日志要带 QEMU tag、machine 参数、镜像哈希和超时，便于另一台机器复演。

设备树是启动链中的接口文档。节点 compatible、reg、interrupts、clock-frequency 与 hart topology 必须和 Machine 实例化一致。若 DTB 由外部提供，测试要反编译并核对这些字段；若未来改成 Machine 生成，则生成代码和 binding 共同审查。设备模型“能够容忍错误 DTB”不算优点，错误描述会让客户机绕过真实连线，留下更难诊断的隐患。

固件中的轮询循环可用来判断最小实现优先级。若它只读取 UART LSR 并写 THR，先实现这条路径；若它配置时钟门控后才访问 UART，系统控制寄存器就进入最小集合。实现寄存器时仍要依据公开语义，不能仅返回让固件前进的常量。通过一次镜像的 hard-code 会把软件版本固化成隐藏 ABI，换固件便崩。

多 hart 应在单 hart 启动稳定后引入，但不是简单把 `-smp` 增大。要确认 hart ID、reset/hold 状态、CLINT software interrupt、timer context、PLIC context、设备树 CPU 节点与固件启动协议。当前 K230 缺省单 hart 是固定事实；G233 的 hart 数未知，概念草图不会预设多核，只把“如何取得与验证数量”列进证据计划。

## 用香山昆明湖检查装配思路

固定树还包含 [`hw/riscv/xiangshan_kmh.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/xiangshan_kmh.c) 和对应系统文档。它建模香山昆明湖 FPGA prototype，可配置多达 16 个 Xiangshan 核，并装配 APLIC/IMSIC、UART、CLINT、ROM 与 DRAM。这里引用它，是为了比较 RISC-V Machine 如何组织 CPU、AIA 和固件集成 DTB，不把其地址或启动协议移植给 K230/G233。

初始支持提交 [`29abd3d112`](https://gitlab.com/qemu-project/qemu/-/commit/29abd3d112) 提供另一个历史入口。对比两个 Machine 可以看到，平台代码常复用通用 CPU、中断和串口设备，却保留自己的内存图、固件约定和兼容属性。作者推断，G233 若未来取得可信资料，也应从“哪些语义真正相同”决定复用，而不是从芯片都属于 RISC-V 决定复制。

比较表应只放可核对字段。K230 当前一个 C908 hart、PLIC/ACLINT 和外部 DTB direct boot，是本章已核对事实；昆明湖的 AIA、hart 上限和固件集成 DTB 来自当前源码；G233 对应单元保持 unknown。空白不是失败，它能阻止读者把相邻列的值顺手抄过去。

:::: {.quick-quiz}
为什么 G233 可以复用一个通用 UART 设备，却不能直接复制昆明湖的 UART 地址？

::: {.quick-answer}
设备寄存器语义相同才支持复用模型，地址属于各 SoC 的装配契约，需要 G233 自身一手证据。相同 ISA 或相似启动日志不能证明地址相同。
:::
::::

## G233 的证据边界

官方 `v11.1.0-rc0` 的 `hw/riscv/` 和 `target/riscv/` 中没有 G233 Machine。本书把它作为综合工程，所有目录、提交和实验都标为“book model”。它可以借鉴 `virt`、K230 和香山昆明湖模型的装配方式，却不能声称其地址、CPU 特性或启动协议已经得到 QEMU 上游确认。

G233 的输入证据需要形成清单：公开手册版本、RTL 或寄存器描述、固件源码与镜像、Linux 设备树和驱动、真实板级日志，以及已知缺失。不同来源冲突时先记录冲突，不用一个看似合理的常量掩盖它。对无法公开的材料，也不能把结果写成可由读者复现的上游事实。

本章不会给 G233 分配 CPU type、reset PC、RAM base、UART compatible、中断控制器或设备地址。即便某个二手网页展示了类似名字，也无法替代厂商公开规范、可审计源码或实机证据。实验中的 JSON 计划故意让所有条目从 `unknown` 开始，validator 要求任何 `verified` 或 `inferred` 条目携带证据；空 evidence 的“已验证”会直接失败。

证据等级可以逐步提高。公开设备树中的 `reg` 能证明某个软件版本描述了地址，但未必证明寄存器语义；驱动源码能说明访问序列，未必说明 reset 值；实机 trace 能验证一次运行，未必覆盖保留位。将三类材料交叉，才可能把某条从 inferred 提升为 verified。若资料带有保密限制，书中只能描述验证方法和公开结论，不能泄露寄存器表或暗示读者可独立复现。

名称冲突也要防范。G233 可能是内部项目、板卡、SoC 或某个核的称呼，在没有权威命名来源前，QOM type 和 machine 名也属于开放问题。概念目录使用 `g233` 只是仓库导航，不是上游命名提案。未来得到正式名称时，应允许调整树外实验，避免早期字符串成为兼容承诺。

需要实机时，最小采集程序只读已确认安全的寄存器，保存访问地址、宽度、返回值、特权级、固件版本和时间；不要扫描整个 MMIO 空间，读取型寄存器也可能有副作用。串口和 JTAG trace 要与可公开资料对应，任何会改变硬件状态的实验先做风险评估。本书当前没有这些结果，所以不会填写虚构日志。

:::: {.quick-quiz}
Linux 设备树给出一个 UART 地址，是否足以把该条目标成 fully verified？

::: {.quick-answer}
它能验证该软件版本的地址声明，仍需核对 compatible、寄存器布局、时钟、中断和实机行为。证据等级应说明验证的是哪一层，不能用一个 `reg` 属性覆盖完整设备语义。
:::
::::

## G233 概念草图只描述工作顺序

阶段零不写 C 代码，只建立 evidence plan。字段包括 machine 名称来源、CPU/ISA、hart topology、复位流程、RAM/ROM、UART、timer、interrupt controller、DTB、固件许可和测试资产。每项给出 owner、期望一手来源、冲突与下一步。validator 只检查分类和证据完整性，不判断硬件值正确；人工审查仍要打开原始材料。

阶段一的代码也必须等待最小事实集合：可确认的 CPU model 或可接受替代、reset PC、可执行 ROM 内容、至少一段 RAM 和稳定退出办法。若 CPU 私有扩展尚无模型，可以先用明确标注的近似 CPU 做“装配 smoke test”，但输出必须写“无法验证真实启动”，也不能发布成兼容镜像。替代模型只检验 QOM 和地址空间代码，不能验证 SoC。

阶段二才接 UART。选择现有 16550、SiFive UART 或新设备，依据 compatible 和寄存器访问序列；若只是串口输出长得相同，不足以复用。qtest 检查 reset、合法宽度和 IRQ，最小固件写固定字节。阶段三加入 timer 与中断控制器，先验证单个源、单个 hart，再扩展拓扑。存储、网络和加速器等大模块留到启动骨架稳定以后。

每个阶段都能被删除而不影响前一阶段的测试，这是一条很实用的补丁边界。Machine 骨架、通用设备、Machine 连线、设备树、文档和 functional test 分开提交；中间每个 commit 可构建。若某个新设备只为 G233 使用，也先给独立 qtest，Machine patch 只实例化它。审查者可以分别判断设备语义和板级地址来源。

完成定义随证据增长。阶段一不是“G233 支持”，只能写“tree-out skeleton realizes”；UART 字符出现后也只说明最小固件路径；到达 Linux shell，需要再列出未实现设备和镜像限制。README 的 supported/unsupported 表必须跟代码更新，Release PDF 不应凭章节标题暗示上游接受或完整芯片兼容。

## 设备树、固件与许可一起审查

设备树常从厂商 SDK 取得，文件本身有来源和许可，节点内容也可能针对私有内核。引入仓库前记录原始 commit、许可证和改动，最好用可读 DTS 生成 DTB，让差异能够 review。若只能提供二进制 DTB，实验手册写明如何由用户路径传入和核对哈希，不能把未知 blob 当作源码事实。

固件决定模型会访问哪些寄存器，却不是规范替身。通过 trace 观察到“写 1 后轮询 bit 3”，只能形成行为假设；要实现 bit 的副作用，仍需手册或驱动语义。若为了推进启动加入临时 hack，代码名和日志要标 `experimental`，默认关闭，并在证据账本列出删除条件。临时行为一旦进入默认 ABI，后续很难纠正。

BIOS/bootloader 的重新分发权也影响 CI。公开源码可在 workflow 中构建，预编译资产要有稳定 URL、哈希和许可；需要用户从厂商包提取的，不上传到仓库、Actions cache 或 Release。测试可以分为 always-run 的无固件 qtest 与 opt-in 的系统启动，缺少资产时给清楚提示。

设备树和 Machine 的演进要保持兼容。新增设备节点可能改变中断编号或地址布局，旧固件是否需要旧 machine version，取决于项目兼容策略。树外 G233 尚未建立兼容承诺，可以在实验早期调整；一旦准备上游，应在 cover letter 说明可用软件和预期 machine 稳定性，不能把所有未知留给 review 猜。

:::: {.quick-quiz}
为什么书中的 G233 模型必须反复标注为树外实现？

::: {.quick-answer}
当前官方 QEMU 基线没有该模型，其接口和验证未经过上游审查。明确来源边界可以防止读者把教学假设当成官方兼容承诺，也便于将来比较真正的上游版本。
:::
::::

## 分阶段实现减少错误组合

第一阶段只建立 Machine、RAM/ROM、CPU 和稳定退出点，让复位 PC 可观察。第二阶段加入 UART 与最小启动固件，形成串口标志。第三阶段加入计时器和中断控制器，验证单个 IRQ，再扩大到多 hart。第四阶段才接入存储、网络或专用加速器。每一步都新增一个失败位置清楚的测试。

这种顺序看起来慢，实际能避免多个未验证组件同时变化。若一次提交同时加入 CPU、十个设备、设备树和 Linux 启动，审查者很难判断某个魔数来自手册还是碰巧让镜像跑过。可审查的补丁需要按逻辑拆分，Machine 装配与通用设备模型也应分开。

调试节奏同样分层。对象 realize 失败先查 QOM path 与 region overlap，reset 后 PC 不对先查 ROM 和 hart reset vector，串口无字节再看访问 trace 与时钟，中断不达则沿设备输出、控制器 pending/context、CPU cause 三段追踪。每次只改变一个假设，日志中标注改动，避免靠一串魔数试到能启动后失去解释。

验证矩阵要包含负例。错误 RAM 大小应在命令行阶段报错，缺失 DTB 的 direct boot 应拒绝，越界 MMIO 应得到 guest error 而不崩溃，未实现区域访问应可定位。固件启动超时也要有上限和最后检查点。负例能证明错误被约束在接口边界，常比又多启动一个镜像更能提高模型质量。

性能暂时不是早期 SoC 模型的核心指标。TCG 启动慢可能来自 CPU 翻译、轮询延迟或日志，不能靠删除设备语义换速度。先保证虚拟时钟和轮询行为正确，再用 trace 找热点；可加入 icount 或测试超时参数，却要记录对可观察时序的影响。硬件 cycle accuracy 若没有模型目标和校准数据，保持为开放问题。

## 让审查意见变成长期资产

准备投稿时运行 `scripts/checkpatch.pl`，用 `scripts/get_maintainer.pl` 和 `MAINTAINERS` 找收件人，cover letter 给出硬件背景、公开资料、启动命令和测试结果。工具能检查格式和路由，不能证明设备语义。每个 commit 的说明应回答为什么需要、来源在哪、如何验证，DCO 只确认贡献声明，不能替技术审查。

审查者若质疑一个地址，回应应链接手册页、DTS commit 或 trace，再在代码注释保留最必要来源；若指出接口应复用现有设备，比较寄存器与 reset 语义，不能只说名字不同。尚无公开证据时就降级或删除功能。上游接受一个更小却可证明的模型，通常比维护一大片推测寄存器更有价值。

把 review 发现转成仓库检查项。K230 的 hart 数、UART 空洞、reset vector、WDT IRQ 和 M-mode 判断，分别对应拓扑、MMIO 边界、启动 stub、连线和特权状态测试。未来 G233 审查若发现新类别，也加入 evidence schema 和实验模板。这样历史不会只留在邮件里，下一块 SoC 能在提交前复用经验。

邮件归档的链接要使用 Message-ID 或系列页面，避免搜索结果随时间变化。书中引用当前 commit，实验 README 记录补丁版本和日期；若下一版 QEMU 已改变实现，再新增“后续演进”段落，不重写旧标签的事实。读者因此能复现当时结论，也能看到模型为什么继续变化。

## 把 K230 清点做成可重复实验

实验开始先确认源码目录的 `git describe --tags --exact-match` 或目标 commit，不在固定标签就停止，避免脚本在开发分支得到额外设备后污染结论。随后用 `rg` 找 Machine type、CPU type、memmap、`create_unimplemented_device()`、UART、PLIC/ACLINT、WDT 和 boot 路径。输出不要只列文件名，还要给出分类依据：创建了真实 QOM 设备、建立 RAM/ROM、仅有占位，或由外部固件决定。

运行时清点分为无需镜像和需要镜像两组。前者可检查 `-machine help`、设备属性、无效参数报错和对象 realize；后者按 direct boot、firmware boot 分开，记录镜像哈希、DTB 和串口里程碑。没有 OpenSBI、kernel 或 U-Boot 资产时，实验仍能完成源码清点，但报告把 boot 标为 not-run，不能用上游 functional test 的存在替代本机执行。

对 unimplemented range，可在受控最小固件中访问一个已知占位地址，确认当前 QEMU 的诊断，再停止。不要遍历整张 MMIO 图，某些已实现寄存器读写带副作用；也不要把占位返回值写成硬件预期。观察只用于验证“固定模型将该范围分类为未实现”，不是验证芯片。

WDT 清点应连接三条证据：设备源码说明有哪些寄存器和模式，qtest 给出受控虚拟时间行为，Machine 代码说明两个实例的地址与 IRQ。若只找到类型定义而未找到实例化，设备存在于 QEMU 也不等于 K230 使用它。用 object path 或 trace 确认当前 Machine 创建的实例，报告再写“board support”。

实验的末尾选择一个历史问题做闭环。例如 hart 数，在 v8 cover 的 changelog 中找到 v7 调整，打开当前 `default_cpus`，再检查 functional test 的启动参数；三条一致时可写“该修改落入当前 tag”。若邮件说法与当前实现冲突，保留两者，继续找后续提交，不用主观选择。

:::: {.quick-quiz}
源码清点发现 WDT 文件和 qtest，为什么还要在 `k230.c` 中找实例化？

::: {.quick-answer}
通用设备可存在却未被某个 Machine 使用。只有实例创建、地址和 IRQ 连线进入 K230 装配，才能说明当前 K230 模型暴露该设备。
:::
::::

## 从一个启动失败收敛根因

假设 direct boot 没有串口输出，先保存完整命令与 stderr，确认 Machine 没因缺 DTB、镜像重叠或参数冲突提前退出。进程仍运行，再用 GDB 或执行日志看 reset PC 是否在 `0x91200000`，ROM stub 是否跳到 OpenSBI 地址。PC 未离开 ROM，问题集中在 reset/stub；已进入 OpenSBI，才检查固件格式与下一阶段参数。

PC 到达 kernel 地址而无输出，检查 DTB 指针和 UART 节点，再追踪 UART MMIO。完全没有 UART 访问，根因更可能在内核早期或设备树；有写入但后端无字符，才查 16550 region、访问宽度和字符设备配置。访问落在窗口中未实现部分时，日志会提示 offset，这也是 v7 UART 空洞修订值得保留的诊断价值。

若启动在启用分页后停止，采集 `scause`、`stval`、`sepc`、`satp` 和页表项。SDK kernel 使用 MAEE 的限制此时进入候选，但不能看到页故障便直接定因；DTB 地址、RAM 映射和权限也可能错误。换用已知标准 PTE kernel 是控制变量，若它启动，再把差异缩到页表编码与配置。

中断问题沿线检查。设备是否拉高输出，PLIC source 是否 pending，相应 context 是否 enable、priority 超过 threshold，CPU 是否允许并收到外部中断。timer 则从 ACLINT 比较值、虚拟时间、hart context 到 trap。一次只观察一段，避免修改多个寄存器后“碰巧恢复”。

最终故障报告写首个偏差，不写最后症状。例如“reset PC 正确，ROM 跳转目标比 OpenSBI load address 高 4 字节”比“Linux 无输出”可操作。附最短命令、tag、镜像哈希、寄存器和相关源码；如果是推断，列下一步反证实验。

## 为 G233 设计证据门禁

evidence plan validator 只允许 `unknown`、`inferred` 和 `verified` 等定义状态，并要求后两者有来源。更严格的项目还可以要求 verified 至少有一条一手材料，inferred 必须列出推理和反例。URL 本身不够，locator 要给章节、节点、commit 或日志步骤；来源失效时条目自动降为 stale，等待复核。

CPU/ISA 条目不能只写“RISC-V”。需要 XLEN、基础与扩展、privileged spec、私有 extension、MMU mode、reset privilege、hart 数和 boot coordination。每项可能来自不同材料，尚无证据就分别 unknown。选择 QEMU CPU type 时列出准确匹配与近似差异，近似只用于装配实验，不能生成兼容宣称。

内存和设备条目采用半开区间 `[base, base + size)`，validator 使用 checked arithmetic 查回绕与重叠。条目还记录属性、端序、访问宽度、IRQ/DMA 和证据状态。一个大范围手册窗口可作为 container，子设备分别验证；未知 gap 明确保留，不自动变 RAM 或返回零。

启动条目是有向图：reset source、ROM、下一阶段、DTB 来源、OpenSBI/bootloader、kernel 和参数传递。每条边记录入口寄存器与可观察 checkpoint。资料只证明某个二进制镜像的 PC 路径时，标 image-specific，不泛化为 SoC 规范。固件许可与下载稳定性也是字段，无法再分发会改变 CI 方案。

中断条目要从设备 source 到控制器 input、context 和 CPU cause 全链描述。看到 DTS 的 `interrupts = <N>`，只能填一个软件声明，控制器类型、编码和实际连线仍需验证。多 hart 时为每个 context 建矩阵，不能复制第一个 hart。未知控制器不会被默认成 PLIC 或 AIA。

:::: {.quick-quiz}
G233 evidence plan 中，某字段有两个互相冲突的一手来源，validator 应选择日期较新的那个吗？

::: {.quick-answer}
不应自动选择。它们可能对应不同芯片修订或软件分支，应保留冲突并补版本、revision 和实机验证，直到能解释适用范围。
:::
::::

## 复用判断要看语义指纹

决定是否复用现有设备，可比较一组“语义指纹”：寄存器 offset/width/access、reset、FIFO 深度、IRQ 条件、DMA 描述符、clock/reset 输入和迁移状态。compatible 名字相同提供强线索，仍需核对芯片修订；名字不同但指纹一致，也可能通过 property 复用。差异若只是一两个有证据的配置项，property 合理；差异贯穿状态机，强行塞条件会让两个平台都难维护。

串口常被过早当作 16550。固件只写一个字节且屏幕有输出，最多说明最小发送路径相似；LSR 位、FIFO、中断、regshift、时钟和端序还要核对。K230 当前实现明确传入 regshift 与频率，正说明“16550 兼容”也需要平台参数。G233 没有资料时，UART type 保持 unknown。

中断控制器更不能按 RISC-V 标签选择。PLIC、APLIC/IMSIC 和厂商控制器在发现、context、消息与线中断语义上不同，选错后可能靠 polling 启动，却在 SMP 或设备负载下失败。证据 plan 先收集 DTS compatible、固件初始化和 CPU interrupt mode，再决定复用哪个上游设备。

系统控制器通常最难复用。一个寄存器可能同时管理 clock、reset、pinmux 与电源域，返回常量能推进一版固件，却掩盖写入副作用。可先实现公开且启动必需的位，其余保留位按规范处理，文档列出限制。若缺公开语义，宁可让 Machine 明确 unsupported，也不要伪造“always ready”。

## 建模精度是一份预算

SoC 模型服务的场景要写在文档里。若目标是固件和 Linux 启动，CPU 功能、计时器、中断、UART、存储和必要 system control 优先；若目标是驱动开发，对某个外设的寄存器与错误路径要求更高；若目标是性能研究，功能 QEMU 可能根本不提供所需 cycle accuracy。没有场景，团队会按模块数量追求“完整”，却无法判断何时完成。

占位也是预算选择。它保留地址并提供诊断，适合固件可绕过的模块；对决定启动的 clock/reset，简单占位可能让软件走错分支；对安全敏感 DMA，伪实现更危险。每个占位写出已知访问者、当前返回影响和升级条件，定期用启动 trace 复核。

实现一个通用设备的成本包括文档、qtest、迁移、安全审查和长期维护，不只是几百行寄存器回调。若没有公开软件使用和验证资产，上游维护者难以防止回归。树外模型可先积累这些材料，再讨论投稿。G233 当前停在证据计划，正是因为连最小可验证契约尚未建立。

精度预算也影响 PDF 叙述。章节可以说明理想的分阶段路线，却要在每段写清哪些命令今天可跑，哪些是未来设计。实验链接只指向真实存在的 validator，不让读者以为仓库里已有 G233 C 代码。文档的诚实边界本身就是工程质量。

## 章节实验的验收表

K230 实验通过条件包括：固定 tag 检查成功，至少列出一项 implemented、一项 stubbed 和一项 firmware-dependent，所有分类有源码定位；若运行启动路径，命令、资产哈希和里程碑齐全；历史复盘能从当前 commit 回到一个稳定邮件链接。脚本退出零只证明机械检查通过，报告还需人工解释分类。

G233 实验通过条件更克制：validator 接受全 unknown 基线；人为把一个条目标 verified 且不加 evidence 时必须失败；加入一条示例证据后能通过 schema 检查，但报告明确该示例是否真实硬件证据。若手头没有权威资料，最终成果仍可全部 unknown，并列出下一步来源。

两项实验都要检查相对 README 链接、英文命令和中文正文是否一致。README 负责环境、运行、预期与清理，正文负责为什么这样分层、如何解释输出、哪些结论不能得出。CI 可运行轻量脚本，实机或大镜像步骤保持 opt-in。

验收最后执行禁用词与来源检查：不出现未经证实的 G233 地址/CPU，不把 K230 加速器占位写成实现，不引用非官方 QEMU 镜像仓库替代 GitLab，不把邮件 patch 写成已合入。任何一项失败，先修证据表述，再谈增加功能。

## 从工程考量解释“为什么只做这么多”

K230 当前模型只覆盖一个 C908 hart和有限外设，不能简单评价为“遗漏”。源码能确认范围，补丁演进能确认多轮收敛；至于维护者是否基于人力、软件需求或硬件资料作出具体优先级，若邮件没有直接陈述，本书只给作者推断：较小模型更容易形成可启动、可测试、可维护的闭环。推断不替代上游动机，也不阻止未来扩展。

`create_unimplemented_device()` 同样是一种边界选择。它让已知地址访问可诊断，避免大量无证据寄存器进入 ABI；代价是某些固件会读到与实物不同的行为。是否使用占位，应依据启动软件能否安全降级和未来调试价值，不能把“返回某个值能启动”当作实现依据。文档列出占位，用户才能判断 workload 是否落入支持范围。

外部 DTB 的 direct boot 让当前模型少承担一套自动生成设备树，却把一致性责任交给用户输入。强制 `-dtb`、检查镜像重叠和区分 firmware boot，是把错误尽量前移。作者推断，这比接受含糊参数后在内核深处失败更利于支持；若未来生成 DTB，仍需维护 binding、compatibility 和测试，不能只删参数检查。

MAEE 限制体现另一种克制：通用 RISC-V MMU 没有私有语义证据时，让用户重建标准 PTE kernel。代价是厂商 SDK 镜像不能原样运行，收益是不会把猜测行为扩散到其他 CPU model。要改变这条边界，需要公开规格、CPU feature、翻译与页表测试、迁移影响和上游审查，单个镜像启动不足以证明方案。

对 G233，目前“只做 evidence plan”也是工程结果。没有权威 CPU、地址和启动资料时，写空 Machine 只能验证 QOM 样板，无法验证平台；若连样板也用猜测常量，后续 contributor 还要先清债。validator 让未知显式、让证据升级可审计，等材料出现再按阶段编码，这比制造一个貌似丰富的目录更接近可维护工作。

## 更新本章时的回归路线

升级到新的 QEMU tag，先运行 K230 清点脚本并比较 implemented/stubbed/absent 分类，再看 `git log v11.1.0-rc0..NEW -- hw/riscv/k230.c hw/watchdog/k230_wdt.c`。每个变化打开 commit 与测试，新增能力单列，不覆盖旧基线。若 hart 数、boot 地址或设备状态改变，检查文档、functional test 和 PDF 实验描述是否同步。

随后全树检索 G233。出现同名字符串也不能立刻宣布上游支持，要确认它是 Machine、测试、文档还是无关文本；若有 patch 但未合入，保留为上游提案；若 commit 已进入新 tag，逐行建立事实账本，并把本书概念草图与真实接口做差异分析。旧实验的 unknown 状态仍保留在历史版本。

最后重跑两个轻量实验，检查英文 README 命令、相对链接、JSON schema 和输出。需要网络或固件的 K230 路径单独记录资产状态。更新报告列出“事实变化、文档变化、实验变化、仍开放问题”，读者可以看到版本升级带来了什么，而非只得到一份悄然重写的章节。

## 一个跨组件设计题

设想未来有公开证据表明 G233 含两个 hart、一段 ROM、一个非 16550 UART 和一种尚未进入 QEMU 的中断控制器。合理的第一批补丁仍不应一次把四部分全写完。可以先提交带 qtest 的通用 UART，随后提交中断控制器骨架与单源测试，再提交只装配 CPU、ROM、RAM 的 Machine，末尾连接串口和中断。每一步都要说明暂时无法启动到哪里，避免中间 commit 靠未提交代码才能构建。

如果固件在 UART 实现前就依赖中断控制器，顺序可调整，但理由来自启动 trace，不来自模板。也可以在 Machine 骨架中使用 test-only ROM 写固定退出码，先验证 reset PC 与内存，再等待设备补丁。测试资产必须公开可再分发；无法提供时，qtest 检查对象和地址，系统启动保持 opt-in。

审查者可能建议复用现有控制器，作者要给语义指纹对比：寄存器、context、claim/complete 或 message、reset 与迁移。只有地址不同可由 Machine 处理，语义差异可由有证据的 property 表达；核心协议不同就创建新设备。回答“两个都是 RISC-V 中断控制器”没有技术含量。

当四部分最终连通，成功标准仍分层：Machine realize、ROM 跳转、UART 字节、单个外部中断、多 hart 启动、固件里程碑。Linux shell 可以作为综合结果，却不能吞掉前面测试。若某阶段只在实机私有镜像上验证，文档写清限制，上游事实仍限于公开代码与可重放检查。

:::: {.quick-quiz}
为什么一个只能启动 test ROM 的 G233 骨架仍可能是有价值的补丁阶段？

::: {.quick-answer}
它能独立验证 QOM 装配、reset PC、ROM/RAM 地址和错误处理，为后续设备建立稳定底座；前提是文档明确它尚不代表真实固件兼容或完整平台支持。
:::
::::

## 从本书实现走向上游

准备上游前，先检查已有模型能否复用，设备是否属于通用目录，维护者和测试框架是谁。cover letter 解释硬件、可用软件与测试方式，每个补丁保持可构建，文档列出已支持和未支持功能。提交中不能捆绑不可再分发的固件，测试下载也要使用稳定来源和哈希。

K230 的多版本审查提醒我们，review 会持续提供设计信息，远超发布前的一次形式检查。地址、CPU feature 和启动路径被质疑时，应补证据或测试，“在我的环境能跑”无法回答接口依据。最终模型的可信度来自可复查材料，不取决于功能列表长度。

:::: {.quick-quiz}
为什么 Machine 和一个新的通用设备通常应拆成不同补丁？

::: {.quick-answer}
通用设备有独立接口、测试和维护范围，Machine 只负责实例化与连线。拆分后每一步可构建、可审查，设备也能被其他平台复用，错误责任更清楚。
:::
::::

::: {.source-path}
K230 事实入口为 [`hw/riscv/k230.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/k230.c)、[`include/hw/riscv/k230.h`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/include/hw/riscv/k230.h)、[`hw/watchdog/k230_wdt.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/watchdog/k230_wdt.c)、[`tests/qtest/k230-wdt-test.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/tests/qtest/k230-wdt-test.c)、[`tests/functional/riscv64/test_k230.py`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/tests/functional/riscv64/test_k230.py) 与 [`docs/system/riscv/k230.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/system/riscv/k230.rst)。G233 在固定标签中无同名上游模型，本章没有为它虚构 CPU、地址、启动或加速器能力；所有草图只描述收集证据和验证的顺序。
:::

::: {.hands-on}
实验一使用英文手册 [Inspect the K230 Machine](../experiments/part-06-heterogeneous-systems/chapter-25-k230-and-g233-socs/inspect-k230-machine/README.md)。脚本对固定 QEMU 树执行源码与运行时清点，把项目分类为 implemented、stubbed、firmware-dependent 和 absent。正文用中文记录 `k230` Machine、单 C908 hart、boot path、UART、PLIC/ACLINT、WDT 与加速器占位，随后选择一个当前 commit 和对应邮件，核对审查结论落在何处。若本机缺少镜像，只做源码清点，不把未运行路径写成已验证。
:::

::: {.hands-on}
实验二使用英文手册 [Sketch a G233 Evidence Plan](../experiments/part-06-heterogeneous-systems/chapter-25-k230-and-g233-socs/sketch-g233-platform/README.md)。它运行 JSON evidence-plan validator，不编译 G233 Machine，也不宣称上游存在该 SoC。初始 CPU、hart、复位地址、RAM、UART、中断和固件字段全部为 unknown；读者只有附上可公开复查的证据，才可把条目提升为 inferred 或 verified。实验报告用中文说明每次升级依据、冲突和仍缺的验证，禁止从 K230、`virt` 或昆明湖复制常量来填空。
:::

## 小结

SoC 模型的可信度来自跨组件一致性、逐步验证和清晰来源。K230 展示了上游审查如何改变最终实现，G233 则用同一纪律约束本书自己的工程推断。
