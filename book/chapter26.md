# AI 加速器与 Agent 辅助外设建模

生成式工具可以很快产出寄存器结构、QOM 样板、测试骨架和文档，但设备模型最危险的错误往往也能“看起来很像代码”：位宽错一位、reset 值来自旧手册、DMA 长度未经验证、迁移字段遗漏，编译器都不会替我们发现。本章把 Agent 放在证据驱动的工作流中，让它缩短机械劳动，而不替代架构判断和上游审查。

## 本章目标

- 为 RISC-V AI 加速器定义最小、可测试、可迁移的设备契约；
- 设计 Agent 参与资料提取、代码生成、测试和审查的可追溯流程；
- 建立防止幻觉、越权修改和不可复现结果进入仓库的门禁。

## 先声明模型与工具的边界

本章目标版本仍写作 QEMU `v11.1.0`，源码事实固定在官方 GitLab [`v11.1.0-rc0`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0)，commit `eca2c16212ef9dcb0871de39bb9d1c2efebe76be`。能在这个树中核对的 QOM、PCI、DMA、IRQ、VMState、qtest 和 fuzzing 接口，称为“源码事实”；提交作者和开发文档表达的要求，称为“上游陈述”；本书根据这些材料制定的 Agent 工作流，称为“作者方案”或“作者推断”；没有公开设备规范、维护者结论或运行证据的部分保留为开放问题。

固定源码中没有本章这块 RISC-V AI 加速器。K230 Machine 虽为 KPU、AI 2D engine、`gpu` 等地址范围创建 unimplemented region，这些对象只标示未实现窗口，不含张量寄存器、命令队列、DMA 计算或中断语义。`virtio-gpu` 和 `edu` 属于其他设备类型，不能充当这块加速器。实验提供的 Python 模型是宿主侧功能 oracle，只实现有界的 `2×2` 整数矩阵乘法；它不会构建 QEMU，更不能证明上游存在相同设备。

Agent 的边界也要同样明确。它可以检索固定源码、整理带定位的证据、根据已审查 schema 生成重复样板、运行测试并归纳 diff；它不能创造缺失寄存器语义，不能替维护者作兼容承诺，也不能用“看起来和现有设备相似”把猜测升级为事实。任何产物的责任仍由提交者承担，验证命令、输入版本和未决问题要与代码一起交付。

:::: {.quick-quiz}
Agent 找到 K230 内存图中的 `KPU` 名称，为什么不能据此生成一套 KPU 寄存器模型？

::: {.quick-answer}
名称与地址占位没有给出寄存器宽度、reset、命令、DMA、IRQ 或错误语义。缺少公开规范时，Agent 应输出证据缺口和验证计划，不能把相似设备布局填进空白。
:::
::::

## 先做威胁模型，再决定自动化范围

设备模型的输入来自客户机，Agent 的输入还包括网页、PDF、邮件、issue、源码注释和用户 prompt。前一类可能触发越界、资源耗尽与竞态，后一类可能过时、互相冲突，甚至包含要求工具越权操作的文本。工作流需要同时保护运行时和开发过程：设备拒绝不可信描述符，自动化则只读取授权资料、限制写入目录，并把外部文本当作数据而非命令。

资产清单应列出源码仓库、固定 tag、规格版本、测试镜像、生成器、外部库和许可证。每项记录来源 URL、commit 或 SHA256，不能用“最新版”做输入。Agent 在新会话开始时先复述边界，执行后报告实际读取与修改的文件；若仓库已有未提交变更，保留并避开无关区域。可审计性从文件范围开始，最后才是代码风格。

风险按能力分级。只生成候选寄存器表，影响局限在评审草稿；直接改设备 C 文件，可能引入客户机 ABI；运行本地测试属于可恢复操作；上传固件、推送分支或发送邮件会改变外部状态，需要明确授权。将能力拆开，Agent 即使误解一条资料，也无法自动跨过所有门禁把错误发布出去。

输出也可能泄露信息。DMA buffer、模型参数、固件路径和私有手册内容不应无上限写入 prompt、trace 或 CI artifact。调试记录优先保存长度、哈希、请求 ID 和受控片段，错误报告不打印整个张量。若外部模型服务参与 review，先确认源码与资料是否允许发送；不能确认时使用本地工具或只传最小公开上下文。

:::: {.quick-quiz}
为什么“Agent 只有仓库写权限，没有 shell root”仍不足以说明流程安全？

::: {.quick-answer}
它仍可能覆盖未提交工作、嵌入受限资料、修改 ABI、泄露日志或触发外部发布。权限边界要覆盖文件范围、输入来源、网络与外部状态，不只看操作系统身份。
:::
::::

## 用 evidence packet 喂给 Agent

一次设备任务应有小而完整的 evidence packet：目标 QEMU tag、要改的目录、规格章节或源码链接、已确认寄存器表、软件访问序列、预期测试、明确未知项和禁止事项。Agent 回答每条设计结论时引用 packet 中的定位，超出材料便标 `unknown`。这样上下文不靠聊天记忆，另一位审查者也能重放输入。

证据条目至少包含 `claim`、`kind`、`source`、`locator`、`version`、`confidence` 和 `open_questions`。`kind` 可取 source-fact、upstream-statement、author-inference 或 open-question。source-fact 要落到固定 blob/行或可运行输出；upstream-statement 要保留 Message-ID/commit；inference 列出依赖的证据；open-question 给出提升等级所需材料。schema validator 只能查字段齐全，真实性仍由人打开原文核对。

冲突不能在摘要阶段消失。手册 A 写 reset 为 0，驱动总在启动时写 1，实机读取又是 3，packet 应保留三条及版本，不能让 Agent投票选一个最常见值。可能原因包括芯片修订、只读状态位或文档错误，下一步是寻找 errata、修订 ID 与实机序列。代码在结论前暂停，看似降低产出速度，实际避免把冲突固化成迁移 ABI。

证据包还应带负面检索结果。本章写明在固定 QEMU 树没有目标 AI accelerator type，并附搜索范围；这不能证明未来或树外永远不存在，却能约束当前表述。Agent 生成文档时必须保留“不在该 tag 中”的限定，不能压缩成“QEMU 没有 AI 支持”这种过宽结论。

## 中间表示让错误提早显形

从规格到 C 代码之间加入机器可读设备描述。寄存器项包含 offset、width、access、reset、field mask、side effects、endianness、来源和状态；队列项描述结构布局、所有权、长度上限与错误；IRQ 项说明触发条件、mask、pending 与 clear；DMA 项说明地址空间、方向、对齐和部分失败语义。状态机另列 reset、ready、busy、error 和 quiesced 的合法转换。

生成前执行纯结构检查：offset 对齐，区间不重叠，field 不越过 width，reset 不设置保留位，枚举值不重复，数组大小不溢出，引用的 IRQ 和 region 存在。检查通过只说明表示内部一致，不能证明与硬件相符。因此报告应写“schema validation passed”，避免写“spec verified”。人工审查来源列后，才允许生成常量和测试向量。

生成文件顶部记录生成器版本和输入哈希，不写模糊的工具宣传。CI 重新运行生成器并要求 diff 为空，手工修改生成输出会被发现；需要例外时改 schema 或生成器。手写行为和生成表分开，避免一次重新生成覆盖复杂状态机。若上游维护者不接受生成代码，可保留 schema 用于验证，再提交展开后的手写实现；这属于目录维护决策，本书流程不能冒充统一上游规则。

中间表示也能生成文档对照表和 qtest 数据。寄存器 reset、读写 mask 与非法宽度来自同一条目，减少文档和测试分别抄写造成的漂移。不过测试 oracle若完全由错误 schema 自动生成，会与实现一起错。至少挑选关键寄存器，由人根据原始规格写独立断言，并用客户机驱动或参考模型提供第二条证据链。

:::: {.quick-quiz}
寄存器 schema、C 常量和 qtest 都由同一个生成器产生，三者完全一致说明了什么？

::: {.quick-answer}
只能说明它们共享同一输入和转换，不能证明输入正确。若 offset 在 schema 中就错了，代码与测试会一起通过，需要原始规格或独立实现反驳。
:::
::::

## AI 加速器仍然先是一个设备

教学加速器通过 RISC-V `virt` 的 PCIe 或 SysBus 暴露控制寄存器、命令队列、模型与张量缓冲区，完成后产生中断。客户机可见的 feature、数据格式、对齐、错误码和完成顺序必须先写成规范。内部可以从矩阵乘加的功能模型开始，不能因为名称里有 AI 就跳过普通设备建模原则。

模型和张量尺寸来自客户机，乘法溢出、地址越界和资源耗尽是首要安全问题。处理前应逐项验证维度、步长、元素类型和总字节数，设置队列深度与单任务预算。后端错误要转成设备状态，不能让宿主异常直接穿透为进程崩溃。若使用真实 NPU 或外部服务，还要把信任边界、超时和取消写入接口。

教学 ABI 只允许一个固定操作码和 `2×2` 有符号整数矩阵，刻意不处理模型加载、动态 shape 或量化参数。缩小功能有两个好处：合法输入空间能穷举一部分，计算 oracle 能独立阅读；控制面仍保留发现、请求、完成和错误四个阶段。后续若增加尺寸，必须先定义 `rows × cols × element_size` 的 checked arithmetic 和资源上限，不能把 Python 大整数的安全错觉带进 C。

寄存器可分 capability、queue configuration、doorbell、interrupt status 和 device status。capability 表明 ABI/version 与固定矩阵限制，队列配置在 enable 前写入，doorbell 只提示新工作，完成项携带 request ID 与标准化错误。未定义 offset、错误访问宽度、队列未启用便敲 doorbell，都得到确定状态。这个概念接口是作者方案，没有对应上游 device ID 或寄存器号，正文不会给它分配虚假的 PCI vendor/device ID。

矩阵输入输出由 DMA 地址引用，前端按元素总数复制到宿主缓冲区，再调用纯函数 oracle。复制增加成本，却让 worker 不再持有客户机映射，reset 和迁移边界更容易证明。结果 `(19, 22, 43, 50)` 来自手册给定的两个 `2×2` 示例矩阵，只验证功能 oracle；将来接入 QEMU 后，还需另测端序、地址转换、部分写和中断。

错误码是 ABI 的一部分。非法操作、shape、长度、地址翻译、队列状态、后端失败与设备致命错误应可区分，驱动才能决定重试、reset 或上报。宿主 `errno` 和第三方库异常不能直接透传，因为数值与文本会随平台变化。前端把它们映射到固定枚举，详细宿主错误进入受控日志，迁移后客户机仍看到相同类别。

## 用 `edu` 学设备结构，也学历史教训

固定树的 [`hw/misc/edu.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/misc/edu.c) 和 [`docs/specs/edu.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/specs/edu.rst) 提供一块教学 PCI 设备。它有 MMIO、阶乘 worker、DMA、timer、MSI/INTx 和 BAR，适合阅读 `pci_edu_realize()`、`edu_mmio_read/write()`、`edu_fact_thread()`、`edu_dma_timer()` 与 uninit 清理。我们借它学习 QEMU 设备骨架，仍不把它称为 AI accelerator 或 RISC-V 专用设备；它只是挂到 riscv64 `virt` 上的架构中立样本。

初始提交 [`b30934cb52a7`](https://gitlab.com/qemu-project/qemu/-/commit/b30934cb52a72a763da21dccc9994c64517d6f25) 把 `edu` 定位为帮助学习 Linux driver 的设备。后续提交 [`2482aeea4195`](https://gitlab.com/qemu-project/qemu/-/commit/2482aeea4195ad84cf3d4e5b15b28ec5b420ed5a) 在工作唤醒路径加入内存屏障，提交说明针对 lost wakeup。上游历史告诉我们，小设备也会遇到并发排序，Agent 若只复制当前代码，看不到这一行背后的失败模式。

范围校验还经历了 [`2c5107e1b455`](https://gitlab.com/qemu-project/qemu/-/commit/2c5107e1b455d4a157124f021826ead4e04b4aea) 和 [`698267415936`](https://gitlab.com/qemu-project/qemu/-/commit/69826741593644f6e9ee735cff37599c33764d67) 的修正，后者有可追踪的 [qemu-devel 邮件](https://lore.kernel.org/qemu-devel/20221018122551.94567-1-cfriedt%40meta.com/)。这组证据应被 Agent 转成检查题：区间使用闭还是半开端点，加法是否回绕，最后一个字节是否合法，零长度如何处理。仅把最终 `edu_check_range()` 复制过来，不说明目标设备的地址契约。

提交 [`42f599172ae0`](https://gitlab.com/qemu-project/qemu/-/commit/42f599172ae023924f288e20af0ceed681674747) 进一步把 DMA 限制到设备 buffer，提交说明指出旧路径允许任意 QEMU address-space 读写，对应讨论可由 [Message-ID](https://lore.kernel.org/qemu-devel/aQtAotYvzFY0Vpft@tcarey.uk/) 核对。这项演进具体展示了安全边界：通用 DMA helper 会执行设备请求，却不会自动知道哪段地址属于设备协议。Agent review 必须从客户机可控字段一路追到最终 AddressSpace 操作。

:::: {.quick-quiz}
为什么阅读 `edu.c` 的当前实现后，还要查看它的范围检查和内存屏障提交？

::: {.quick-answer}
当前代码展示“怎么写”，历史提交和邮件展示哪些旧假设曾失败、审查关注什么。两者结合才能把经验转成新设备的测试和不变量。
:::
::::

:::: {.quick-quiz}
为什么 AI 加速器模型不能把“张量形状合法”交给客户机驱动保证？

::: {.quick-answer}
客户机属于不可信输入源，驱动可能有 bug 或被恶意控制。设备必须自己验证维度、乘法溢出、缓冲区范围和资源上限，否则会把客户机错误扩大为宿主越界或拒绝服务。
:::
::::

## Agent 最适合处理有证据的机械工作

给定明确版本的数据手册，Agent 可以提取寄存器表并生成待核对的机器可读描述；给定现有 QEMU 设备，它可以列出 QOM、MemoryRegion、IRQ、reset 和 VMState 模式；给定接口规范，它可以生成 qtest 用例矩阵。每项输出都必须携带来源页码、源码路径或需求编号，使审查者能够回到原始证据。

不适合直接委托的是“猜出维护者为什么这样设计”或“补齐手册没有公开的寄存器”。若材料不足，正确输出是缺口和验证计划。Agent 的流畅文字不能提高证据等级，编译成功也不能证明寄存器语义正确。

适合自动化的任务通常有清楚输入和可判定输出。例如把固定源码中的 QOM type、MemoryRegionOps、IRQ 和 VMState 字段列成表，检查每个 realize 资源在失败路径是否清理；从已审查 schema 生成宏与 reset 测试；把 review checklist 应用到一个 diff；运行 `meson test`、qtest 与风格工具并保留命令。Agent 可扩大覆盖面，人负责判断输入证据和兼容含义。

任务说明应限制修改范围和停止条件。比如“只改 `hw/misc/foo.c`、头文件、qtest 和文档；不改通用 DMA；遇到未定义 reset 值就停止并列问题”。没有停止条件，模型容易用合理猜测继续填充。完成报告列出修改、测试、未验证路径和证据引用，不能用一句“实现完成”覆盖遗留问题。

让 Agent 解释现有代码时，可要求每个结论标注 certainty。它说“该字段在 reset 中清零”要给函数位置；说“这样做可能避免旧 callback”应标作者推断；说“维护者要求”要链接邮件原话所在系列。无法定位时删除因果措辞，只描述观察到的控制流。语言约束能减少流畅叙述把推断伪装成历史事实。

机械工作仍需抽样。生成一百个寄存器用例后，随机选若干与手册逐位核对；提取维护者名单后运行官方脚本复核；总结 Git log 后检查父提交与当前 tag 可达性。解析器、OCR、Agent 和人工抄录都可能出错，独立检查应成为流程的一部分。

## 生成 QOM 样板时保留生命周期

一个设备骨架至少需要状态类型、class/type 注册、instance init、realize、reset、unrealize、MemoryRegionOps 和迁移声明。Agent 很容易生成“能编译”的 realize，却遗漏中途失败的 unwind。资源获取顺序应配对：初始化 region、注册 BAR、初始化 MSI-X、创建 timer/worker；任一步失败，都释放已经完成的步骤。unrealize 与错误路径复用小型 cleanup，重复调用不产生 double free。

对象引用和 callback 生命周期要显式。timer、bottom half、thread completion 或外部库 callback 可能在设备 reset/unplug 后到达；请求保存 generation 和弱化后的完成 token，回到设备 AioContext 后再次确认对象状态。不要把裸 `DeviceState *` 交给无法取消的后台服务。Agent review 应搜索所有异步注册点，再寻找对应 cancel、join、drain 或 generation gate。

MemoryRegionOps 需要访问宽度、unaligned 与 endianness 约束。每次 read/write 先验证 offset/size，再按寄存器动作执行，保留位不随意保存。回调返回一个值并不代表 guest access 合法，错误可通过 guest-error 日志或设备状态反映。测试覆盖 1/2/4/8 字节与边界，确保宽访问不会跨越两个有副作用寄存器。

reset 不是对状态结构 `memset`。队列地址、feature、error、pending IRQ、timer、worker 请求和迁移阶段各有顺序；只清字段会留下 callback 或已映射 DMA。Agent 可以根据状态列表生成 reset checklist，人再逐项决定行为。若规范没有说明 function reset 是否保留模型参数，就列开放问题，不能从另一个 PCI device 猜。

:::: {.quick-quiz}
设备 `realize()` 已成功创建 worker，随后 MSI-X 初始化失败，为什么只从 `realize()` 返回错误还不够？

::: {.quick-answer}
worker 及相关 callback 仍可能存活，设备对象却不会正常使用。失败路径要停止并释放已创建资源，且顺序与回调所有权匹配，否则会泄漏或访问半初始化状态。
:::
::::

## 从规范生成代码，中间要有可审查表示

直接从 PDF 跳到 C 或 Rust 会把识别错误藏进代码。更稳妥的流水线先生成寄存器清单：名称、偏移、宽度、访问类型、reset 值、字段、来源和未决问题。脚本验证地址重叠、位域越界和重复名称，人再审查，随后才生成常量、读写表和测试向量。

生成文件与手写逻辑分开。生成器、输入清单和输出一起版本化，CI 检查重新生成后无差异。这样手册更新时能看见真正变化，也避免维护者修改生成文件后下次被覆盖。QEMU 上游是否接受某种生成形式仍需遵循目录维护者意见，本书实验不能把自己的流程称作既定上游规则。

代码生成模板应尽量无判断。offset 宏、字段 mask、名称表和测试向量可直接由 schema 展开，状态机、副作用、DMA 与并发仍由手写代码承担。模板里若出现大量设备特例，说明中间表示没有表达真实语义，或这部分不适合生成。把复杂逻辑藏在 Jinja 条件中，会让 review 从 C 文件转移到更难读的模板。

更新规格时先 diff schema。新增寄存器可能与旧保留区重叠，reset 改变会影响迁移与旧 machine，字段从 RW 变 W1C 会改变驱动行为。Agent 可以列出 ABI-sensitive changes，人决定是否需要 property、machine version 或拒绝迁移。自动把新手册覆盖旧值，会在没有兼容讨论时改变既有客户机可见语义。

OCR 结果永远标为候选。表格跨页、上标脚注、十六进制 `0`/字母 `O` 和位范围连字符都可能识别错。提取脚本保留页码与原始片段，review UI 并排显示；没有完成两人或独立来源核对的条目，不进入 verified schema。公开 PDF 的引用也受许可和引用长度约束，仓库保存定位与必要摘要，不复制整章受版权保护内容。

## 测试矩阵需要独立来源

每一类接口对应一类 oracle。reset 和访问掩码来自规格，矩阵运算来自独立纯函数，队列状态来自协议不变量，DMA 错误来自受控 AddressSpace/IOMMU 配置，迁移来自源目标状态对比。Agent 能生成组合，却不能用设备实现自身计算 expected。测试若调用同一个 helper 得到期望值，会让 helper 的 bug 同时出现在两边。

[`docs/devel/testing/qtest.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/devel/testing/qtest.rst) 描述 qtest 基础设施。AI 设备 qtest 可枚举 PCI 配置与 BAR、reset、合法请求、中断、非法长度、地址回绕、完成队列满和 reset 竞态；它无需启动 Linux，运行快，适合作为每个补丁的门禁。RISC-V 系统实验再用 riscv64 驱动覆盖 probe、DMA API、fence 和 IOMMU。

模糊测试入口可参考 [`docs/devel/testing/fuzzing.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/devel/testing/fuzzing.rst) 与 [`tests/qtest/fuzz/`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/tests/qtest/fuzz)。输入要有步数、分配量和队列深度上限，保存 seed 与最小化样本。fuzzer 找到 crash 后，先把样本固化成确定 qtest，再修代码；“运行若干小时未崩”只能作为特定构建的观察，不能写成安全证明。

差分测试把同一矩阵请求送给纯 Python oracle 和设备，比较固定宽度整数位模式。metamorphic test 还能检查零矩阵、单位矩阵、分块组合和输入复制不改变结果。非法请求没有数学 oracle，就检查设备不变量：不写输出、只完成一次、资源有界、reset 可恢复、错误码稳定。并发用例控制调度点，避免靠宿主运气等待竞态出现。

sanitizer、静态分析、checkpatch 和编译告警各自覆盖不同问题。Agent 汇总结果时列出工具版本、目标和跳过项，不能把它们合成“全部安全检查通过”。例如 AddressSanitizer 不证明 VMState 完整，checkpatch 不检查 DMA 权限，qtest 通过也不说明线程无 data race。门禁是证据集合，每条结论保持范围。

:::: {.quick-quiz}
为什么设备模型和测试共用同一个矩阵乘法 helper 会削弱差分验证？

::: {.quick-answer}
helper 若把行列索引写反，设备与 expected 会一起得到错误结果。独立 oracle 使用不同实现路径，差异才有机会揭露共同假设之外的问题。
:::
::::

:::: {.quick-quiz}
为什么要在手册和设备代码之间增加寄存器清单这一层？

::: {.quick-answer}
清单能保存来源、未决问题和机器可检查约束，让识别错误在生成代码前暴露。它还使输入、生成器和输出可重复，避免把来源不明的常量固化进实现。
:::
::::

## 测试让生成结果接受反驳

每个寄存器至少需要 reset、读写掩码、保留位和非法访问测试；队列需要空、满、回绕、错误描述符与 reset 中断测试；DMA 需要零长度、跨页、越界、IOMMU 拒绝和取消测试；计算需要已知向量、溢出与确定性测试。Agent 可以扩大组合覆盖，但预期结果必须来自规范或参考实现。

差分测试把同一输入送给教学模型和可信参考，比较结果与错误。但参考也可能有 bug，差异只能触发调查，不能自动把一方判为正确。模糊测试则要限制资源、保存 seed 和最小化失败输入，确保任何发现都能在 CI 重放。

把失败用例写成“最短反例”。记录寄存器动作序列、内存初值、虚拟时钟推进和预期状态，删除与失败无关的请求。若只保存完整 Linux 镜像与十分钟日志，其他人很难复现。Agent 可协助 delta-debugging，但每次缩减后重新运行，并保留最初 seed，防止缩掉真正触发条件。

错误路径的覆盖率需要按状态统计，而不只看代码行。描述符读取失败、输入 DMA 失败、计算失败、输出部分失败、完成队列满、中断被 mask、reset 中取消和迁移 quiesce 都应有预期。一个 `goto fail` 被某个测试走到，不表示所有入口都释放了相同资源。review 表把每个资源所有权与错误阶段交叉，容易发现遗漏。

测试资产本身也受信任。Agent 从网络下载的参考模型可能变化或执行任意代码；CI 只使用固定 commit/hash、可再分发许可和最小权限。能用几十行纯函数表达的 oracle，没必要引入庞大模型框架。若真实后端是研究目标，把它放在 opt-in integration job，基础 qtest 不依赖宿主 NPU。

## 迁移与兼容不能等功能完成后再补

客户机可见的寄存器、队列索引、错误、IRQ pending、feature 和已发布完成属于迁移候选状态；锁、指针、线程、宿主 buffer 与外部服务句柄不能直接序列化。VMState 需要 version 和字段条件，post-load 重建 timer、AioContext 与派生状态。Agent 可以从状态结构列候选字段，人必须判断哪些由客户机观察、哪些能从其他字段重算。

在途 AI 请求可排空、重算或阻止迁移。排空适合有界纯函数，仍需超时；重算要求输入已保存、结果确定且没有外部副作用；阻止迁移则在设备 busy 时明确报告。教学模型选择排空概念方案，宿主 oracle实验没有真正 VMState，不能把设计写成已验证。加入 QEMU 后需 migration qtest，比较迁移前后 request ID、输出与中断次数。

ABI 版本从首版就出现。未知 feature 的处理、保留位读值、非法命令错误和 reset 后缺省值都可能被旧驱动依赖。Agent 生成新字段时先输出 compatibility report，列出布局、行为和 migration 变化。若无法兼容，使用新的 machine/device version 或拒绝组合，具体方案交给维护者审查。

真实 AI 后端的可迁移性是开放问题。宿主设备上下文、模型缓存和厂商 runtime 可能无法跨机复制；远程服务还涉及身份和完成去重。未设计协议前，启动时明确标记 unmigratable，比迁移时静默丢请求可靠。文档需分别列功能后端和代理后端能力，不能因为共享前端便宣称特性相同。

## 审查 Agent 生成的补丁

review 从 diff 范围开始。是否只改了任务允许文件，是否混入格式化大改，是否新增二进制或网络依赖，是否改变全局 API。随后沿客户机输入追踪：MMIO offset、descriptor 字段、长度乘法、DMA 地址、queue index 和 feature，直到分配、循环、AddressSpace 和 callback。每一步写出上限和失败动作，找不到便是待修项。

第二条线是生命周期。realize 每个资源在哪里释放，reset 如何处理在途任务，unrealize 是否 drain callback，timer 与 bottom half 是否取消，IRQ 在错误后是否降下，迁移前如何 quiesce。Agent 常生成顺畅的 happy path，缺陷集中在 halfway initialized 和 late completion。刻意让每个初始化步骤失败，运行泄漏与崩溃检查，比阅读正常启动更容易发现问题。

第三条线是并发与内存排序。哪一上下文拥有队列索引，worker 读取哪些不可变副本，completion 如何切回 AioContext，锁序是否可能与 reset 反转，原子操作是否有明确 happens-before。客户机 fence 和宿主同步必须分开。只在单一强序宿主运行一次无法验证弱序问题，可借历史提交的 lost-wakeup 模式设计压力测试。

第四条线是错误与日志。未知操作不会 abort，地址错误不会输出客户机数据，重复失败不会刷爆日志，第三方库错误映射为稳定设备状态。测试断言错误码和可恢复性，不只断言“QEMU 没退出”。安全敏感的地址可按请求 ID 和区间类别记录，调试构建需要详细值时由显式 trace 开关控制。

实验中的 review fixture 故意不可构建，包含多个明显标记与更深的设计缺陷。目标是练习发现越界长度、任意 DMA、缺失 reset/迁移/错误处理等问题，不是把它修成生产设备。README 明确禁止复制 fixture 到 QEMU；报告应按 severity、evidence、impact 和 suggested test 排序，避免只列代码风格。

:::: {.quick-quiz}
审查一个无法编译的示例补丁还有价值吗？

::: {.quick-answer}
有。它可训练输入边界、生命周期、DMA、安全和迁移检查，但结论只能针对 fixture。不可把发现数量当作真实 QEMU 设备质量，也不能把示例复制进生产树。
:::
::::

## 审查 Agent 自己的变更范围

自动化工具应在隔离分支或明确目录工作，变更前列出计划，变更后给出 diff、测试和未解决问题。它不能擅自下载不可再分发固件，不能修改与任务无关的代码，也不能把生成身份写进上游提交。所有提交遵守项目 DCO 和作者责任，最终评审者对内容负责。

代码审查可按不变量清单进行：客户机输入是否有界，回调线程与锁是否明确，reset 是否取消异步工作，迁移是否保存全部客户机状态，错误路径是否释放映射，日志是否泄露数据，测试是否覆盖失败路径。清单比“再看一遍代码”更能稳定复用经验。

提交准备应遵循 [`docs/devel/submitting-a-patch.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/devel/submitting-a-patch.rst)，用 `scripts/checkpatch.pl` 检查格式，用 `scripts/get_maintainer.pl` 与 `MAINTAINERS` 确认路由，运行目标测试并保存结果。Agent 可以执行和汇总这些步骤，提交者要阅读完整 diff 与邮件。工具输出不是审批票，维护者 review 也可能要求重新设计接口。

补丁系列按可审查逻辑拆分：规范与文档、通用设备、qtest、RISC-V `virt` 接入、系统测试分别成片，并确保每个 commit 可构建。若设备是纯 PCI，无需为 riscv64 写体系结构特例，RISC-V 只在 Machine/测试命令中出现。把加速器和无关 target/riscv 改动捆绑，会模糊维护边界，也让回退困难。

commit message 说明问题、设计和验证，引用公开规格或 Message-ID。不能捏造审查者意见，也不添加工具宣传或自动生成身份；DCO、作者和版权遵从项目规则，真实提交者对变更负责。若某段来自兼容许可证代码，记录来源与许可，不能让 Agent 改写变量名后抹去出处。

review 反馈进入 evidence packet。维护者说某接口不适合上游，要保存邮件定位和适用版本；代码按建议修改后，增加回归测试或设计注释，避免下次自动生成又恢复旧写法。若反馈只是建议、补丁尚未合入，书中标作上游陈述，不提前写成当前事实。

## 资料许可、隐私与供应链

公开可读不等于可以整份纳入仓库。规格、图表、固件与测试模型各有许可证，引用保持必要长度，派生表记录来源；无法确认再分发权时，只保存链接、版本、哈希和读者本地提取步骤。Agent 生成摘要也可能接近原文复现，人工 review 要检查版权边界。

厂商 SDK 中可能有密钥、服务器 URL、用户名和内部路径，提交前运行 secret scan，并人工查看二进制与大文件。CI 日志不打印 token，Actions artifact 不上传受限固件。若 Agent 调用了外部服务，记录数据发送范围和保留策略；含未公开设计的 packet 默认不离开授权环境。

依赖也要最小化。一个寄存器生成器若引入几十个未固定包，供应链风险和复现成本会超过收益。优先用仓库已有工具或小型脚本，锁定版本，验证下载哈希。实验的 Python oracle只用标准库，读者更容易检查每一行，也不会把某个机器学习框架的宿主行为误认为设备语义。

模型文件尤其敏感。真实神经网络可能含个人数据、商业权重或不允许再分发的算子。本书实验只使用手写小矩阵，不下载模型。未来代理后端测试应使用明确许可的最小资产，报告中不保存原始客户机 tensor，只保存必要哈希与统计。

## 把 Agent 当成可替换的流水线部件

流程可以拆成检索、提取、schema 验证、代码候选、静态检查、构建、测试、diff review 和证据回填。每一步输入输出落盘并可由普通脚本检查，某个 Agent 或模型更换后，后续门禁仍然成立。若整个过程依赖一段无法重放的长对话，维护者很难判断下次更新为何得到不同代码。

prompt 也应版本化为任务模板，包含范围、tag、事实分类、禁止猜测、所需测试和完成报告格式。模板不是设备规范，不能把 prompt 里的常量当证据。Agent 输出若修改了假设，必须回到 evidence packet，而非只在聊天里解释。最终仓库应让没有这段会话的人也能读懂。

质量指标以发现问题和减少重复劳动为主，不统计生成行数。可观察指标包括 schema 冲突在编码前被拦截的数量，review fixture 中高危问题召回，自动生成与手工独立测试的差异，失败样本是否可重放，以及人工 review 耗时。行数增长可能只表示模板重复，不能证明设备更完整。

当 Agent 给出不确定答案，流程不惩罚它停下。恰当的结果可能是三条缺失证据、一段最小复现和一个询问维护者的问题。强迫每次任务都输出 patch，会鼓励填空式幻觉。完成定义应允许“调查结束，实施被证据阻断”，并明确怎样解除阻断。

:::: {.quick-quiz}
为什么把 prompt 和输出保存下来，仍不足以完全复现实验？

::: {.quick-answer}
还需要固定源码、工具/模型版本、资料版本、环境、生成器和测试资产。prompt 只是输入的一部分，外部检索结果与未记录依赖变化也会改变产物。
:::
::::

:::: {.quick-quiz}
Agent 生成的 qtest 全部通过，为什么仍不能直接合入设备模型？

::: {.quick-answer}
测试可能复刻了同一个错误假设，也可能遗漏并发、迁移、安全和兼容边界。还需核对原始规范、检查生成来源、人工审查不变量，并让独立测试或参考实现提供反证机会。
:::
::::

## 综合项目的完成定义

本书最终项目不是“启动一次就结束”。完成条件包括：英文实验手册和可再分发输入齐全，RISC-V 客户机驱动能探测设备，功能与错误路径有 qtest，启动测试可复现，迁移策略明确，Fuzz 输入可重放，关键设计结论有 Git 或邮件证据，树外部分清楚标注。

Agent 生成的每项产物进入仓库前都经过相同门禁。若某功能缺少公开规格、真实硬件或参考输出，就保留为实验性 feature，并在正文说明证据边界。这种克制不会妨碍探索，反而让后续贡献者知道从哪里继续。

完成报告要分“已经验证”“只做设计”“尚未验证”。宿主 Python oracle通过测试，只能进入第一栏的功能模型部分；QEMU PCI realize、RISC-V 客户机 probe、DMA/IOMMU、IRQ、reset、迁移和 fuzzing 若尚未实现，全部留在后两栏。标题可以雄心勃勃，证据表不能越级。

对上游提交，还需在固定 QEMU tree 实际构建，运行新增 qtest 与受影响测试，检查文档链接和 migration compatibility。外部代理后端若不在基础 CI，至少要有纯功能 fallback 和清楚的 optional 标记。任何依赖私有 SDK 才能复现的功能，不满足公开上游项目的独立审查条件，应留在树外研究层。

从历史看设计，不能让 Agent 搜到一个 commit 就写因果。先用 `git log` 找引入与后续修复，再读 commit message、Message-ID 和当前代码；邮件中的设想若未合入，标为上游陈述或开放方向。`edu` 的 ordering、边界和 DMA 限域修订提供可用案例，本章目标设备却仍需自己的证据和测试。

最后的人工签核回答五个问题：客户机 ABI 是否逐字段有来源，所有输入是否有界，异步生命周期是否可证明，reset/迁移是否明确，实验是否能由未参与开发的人重放。任何一项只能靠“Agent 说没问题”回答，项目都尚未完成。

## 常见的 Agent 失败模式

第一类是相似性填空。Agent 看到 `edu` 有 DMA，便为 AI 设备复制同样的 buffer 限制；看到 K230 有 KPU 地址，便生成一组猜测寄存器；看到另一个 SoC 用 PLIC，便给新平台安排同样拓扑。代码可能整齐，证据却断裂。review 应要求每个常量和复用点回答“相同语义由何处证明”，只能回答“通常如此”时降为开放问题。

第二类是版本混合。搜索结果可能来自 QEMU master、旧 tag 和未合入 patch，Agent 把它们拼成一个不存在的当前实现。防线是所有 blob 链接固定 `v11.1.0-rc0`，commit 先验证可达，候选系列标明状态和日期。代码生成只读固定 clone；演进研究在独立笔记中进行，不能自动覆写 source-fact。

第三类是测试镜像。Agent 根据实现生成 expected，再用相同 helper 运行，得到漂亮的全绿；或只测 happy path，把编译成功写成完成。验收表要求独立 oracle、负例、reset 和错误资源上限，测试报告列出未运行项目。coverage 数字可辅助定位空白，不能替代协议不变量。

第四类是范围漂移。任务原本只让补 qtest，Agent 顺手重构 DMA helper、格式化整目录或更新 submodule。大 diff 隐藏语义变化，也可能覆盖协作者工作。开始前固定文件 allowlist，结束后用 `git diff --name-only` 对照；超出范围的改动撤回或另开提案，不能靠最终摘要轻描淡写。

第五类是因果虚构。commit message 只说修复边界，Agent 写成“为了支持某厂商 NPU”；邮件中有人建议一个方案，摘要变成“上游决定采用”。所有“因为、为了、维护者要求”都要有直接来源，否则改成控制流事实或作者推断。技术写作的自然流畅不能牺牲证据等级。

:::: {.quick-quiz}
Agent 找到一个 2027 年 master 分支的设备类型，能否用来解释本章固定 tag 的现状？

::: {.quick-answer}
只能作为后续演进线索，并注明晚于基线。它不能改写 `v11.1.0-rc0` 的源码事实，代码也不能在固定 tag 上假定新接口存在。
:::
::::

## 用 Git 历史建立审查问题库

历史研究的重点在于提取曾经失效的不变量，commit 数量本身没有解释力。以 `edu` 为例，初始设备说明教学用途，后续 ordering 提交暴露 worker 唤醒约束，两个 range 修复暴露端点与回绕，DMA 限域提交暴露信任边界。把每个案例写成“旧假设—触发条件—修复—回归测试问题”，Agent 在新 diff 上逐项询问。

检索顺序从当前符号开始。`git log -S` 或 `-G` 找字段变化，打开完整 commit 与父版本，确认改动范围；commit message 引用 Message-ID 时进入邮件线程，查看 review 是否提出替代方案；最后回到当前代码确认后续是否又修改。只看单个 diff 容易把临时修复当最终设计。

问题库要保存适用条件。`edu` 的 buffer 限域与它的教学 ABI 相关，新 AI 设备若规范允许任意客户机 RAM，不能机械复制同一范围；真正可复用的问题是“最终地址是否被限制在设备契约允许集合”。同理，某个内存屏障位置不能通用复制，可复用的是 producer/consumer 间的 happens-before 证明。

Agent 可按问题库生成 review 注释草案，注释必须指向当前行、说明风险并建议最小测试，避免只贴历史链接。人决定是否适用、语气和严重度。发现真实缺陷后，把最小复现加入 qtest，再更新问题库；没有复现时标 pending，不能让猜测长期以 blocker 形式存在。

## 从 Python oracle 到 QEMU 设备的七个台阶

台阶一只运行纯函数与参数检查，建立固定宽度矩阵语义。台阶二写设备规范和 schema，不生成 C；台阶三创建 PCI QOM、配置空间和只读 capability，qtest 检查 realize/reset；台阶四加入 BAR 与队列配置，尚不访问 DMA；台阶五读取描述符和输入，调用 oracle，写回完成；台阶六加入 IRQ、reset 竞态与 IOMMU 负例；台阶七再考虑迁移和异步后端。每级有独立完成定义，失败时可以停留。

第二级到第三级之间需要决定身份。没有公开硬件或标准，就不能冒用厂商 vendor/device ID；树外实验可使用明确的实验标识并避免形成对外兼容承诺。是否值得进入 QEMU 上游，要先和维护者讨论用例。本章没有完成这一步，因此不提供虚构 ID，也不声称计划已获认可。

第五级的 DMA 要先复制小缓冲区，限制每次请求和队列总内存，所有乘法使用 checked arithmetic。qtest 建立输入输出 RAM，分别制造未映射、只读和跨页失败。只有这些用例通过，才考虑 scatter-gather 或 zero-copy。性能优化不能删除前端边界检查，后端始终只看到规范化宿主 buffer。

第六级引入可控异步点。worker 收到输入后等待测试门，主线程触发 reset，再放行完成；generation gate 应丢弃旧结果。另一个用例让完成写入后再 mask/unmask 中断，确认 completion 不丢。并发不靠 `sleep` 猜窗口，测试钩子只存在于受控构建或内部状态机，客户机 ABI 不暴露。

第七级前先写迁移策略。若排空，请求最长执行时间必须有界；若保存并重算，要证明整数 oracle 确定且输出尚未发布；若阻止迁移，管理层得到清楚错误。VMState review 列出全部 guest-visible 字段，目标端重建 IRQ 和 timer。完成 migration qtest 后，文档才可把迁移从 design 提升到 verified。

:::: {.quick-quiz}
为什么原型已算出正确矩阵，还要把 BAR-only 和 queue-only 分成两个台阶？

::: {.quick-answer}
它们分别验证总线发现、寄存器 ABI 和队列状态，错误责任范围很小。一次加入所有数据路径，probe、端序、队列和计算任一错误都会表现成同一个“结果不对”。
:::
::::

## 人工审查会议如何进行

审查者会前收到 evidence packet、规范 diff、代码 diff、测试命令和 Agent 未决问题，不接收只有结论的幻灯片。会议先过客户机 ABI，再过数据流和生命周期，末尾看风格与命名。若 offset 来源都未确认，立即暂停代码细节，回到证据；这样不会在错误前提上讨论几十个实现选择。

每个争议记录 decision、alternatives、evidence、owner 和 revisit condition。例如“首版采用复制输入”可依据尺寸上限和 reset 简化，重新评估条件是 profiling 显示复制占比超过阈值。decision record 是作者方案，不假装上游意见；未来补丁系列若获得 review，再附 Message-ID 提升证据。

严重度根据客户机到宿主影响判断。任意 DMA、整数溢出、use-after-free 与无界分配通常阻断；迁移字段遗漏在宣称 migratable 时阻断；缺文档或测试也可能阻断上游投稿。命名偏好和重构建议与功能缺陷分开，避免一长串同级评论淹没安全问题。

Agent 负责会后把结论映射到 issue 或 patch task，人核对措辞。每项修复附新增测试，无法测试的说明观察方法。关闭问题前打开最终 diff，确认修复没有扩大范围；会议纪要本身不等于代码完成。

## 两个实验怎样相互约束

oracle 实验给 review fixture 提供一个最小正确核心：固定输入、固定输出、非法 shape 被拒绝、资源规模有界。review 时若 fixture 直接信任任意维度，可以引用 oracle 的契约说明它偏离了已审查范围。反过来，fixture 中的 DMA、生命周期和迁移缺陷提醒读者，纯函数测试通过还离设备完成很远。

运行 oracle 时保存命令、Python 版本和全部测试输出。手工增加边界向量，例如零矩阵、负数和接近 32 位边界，先写预期位模式，再运行；Python 整数不会溢出，若设备契约选择模 `2^32`，oracle 必须显式掩码。当前实验若尚未实现该扩展，就记录为后续任务，不擅自宣称覆盖。

review fixture 不编译，也无需修复。先独立阅读，按输入、DMA、并发、reset、迁移和错误分类；再运行 README 提供的 marker/checklist，比较漏项。找到超过 expected findings 的问题，可以提交文档改进，但必须说明它来自故意错误样本，不能发布安全公告影射 QEMU 上游。

两份实验报告都用中文写解释，链接的 README 保持英文文件名、命令与预期。正文中的 hands-on 段直接指向确切路径，CI 检查链接存在。若未来加入真正 QEMU prototype，建立新的英文实验目录和 README，不悄悄把现有 host-only 手册改写成已经构建设备。

## 本章验收清单

内容验收要求每个上游事实有固定 GitLab 入口，历史结论有 commit 或邮件，作者方案用明确语气，开放问题没有被示例值填满。禁用陈述包括“QEMU 已有 AI 加速器”“K230 KPU 已实现”和“Agent 生成代码通过测试即可合入”。任何二手资料只能作为定位线索，最终引用回到官方源码、开发文档或邮件。

代码验收要求 host oracle 测试真实运行，review fixture 明确 non-buildable，README 链接存在。未来 QEMU patch 才需要构建、qtest、fuzz、迁移与 riscv64 系统测试；当前章节把它们写成台阶和完成条件，不伪报结果。每条未运行检查在报告中列出原因。

流程验收要求文件范围可审计、输入固定、外部资料许可清楚、无秘密进入日志、生成产物可重放。Agent 输出包含 diff、命令、结果和 unresolved list，人完成最终 review。发布前执行样式、链接、内容计数与禁用来源扫描，确保自动化没有破坏书籍结构。

长期验收看下一位贡献者能否接手。他应能从 evidence packet 找到当前事实，从 decision record 看见取舍，从最小实验重放结果，从 open questions 选择下一项工作。若只有一段聊天和一个大补丁，哪怕功能暂时能跑，也没有形成可维护工程。

## 一份最小 Agent 任务契约

任务开头写明：“只读 QEMU `v11.1.0-rc0`；只修改指定设备、测试和文档；RISC-V `virt` 是唯一平台上下文；目标加速器为 book tree-out；未知寄存器不得猜测；不得上传、推送或发送邮件。”随后列出 evidence packet 路径、允许命令、必须运行的测试和停止条件。这样的契约让 Agent 能主动推进，也让越界行为容易被 diff 发现。

任务结束必须回答：实际改了哪些文件，哪条结论来自源码、邮件或作者推断，运行了哪些命令，哪些测试未运行，是否发现规格冲突，下一步需要谁提供什么。若输出只有代码，没有证据和未决项，review 退回。报告可以短，字段不能缺；自动化效率不能靠隐藏不确定性换取。

对于纯研究任务，完成物可以没有 patch。Agent 找到固定标签中没有目标设备、K230 相关区域是占位、`edu` 历史包含哪些修复，并给出可复查链接，已经完成一个有价值的调查。只有获得足够设备契约后才进入 schema 和代码阶段。把“没有实现”当作失败，会诱使工具跨越证据空白。

对于 review 任务，Agent 的建议也要接受反驳。每条评论附当前代码路径、触发输入、可能影响和最小测试；若只是样式偏好，标 nit；若无法证明可达，标 question。人可以拒绝建议并记录理由，问题库随真实修复更新。Agent 是可替换审查者之一，不是自动批准器。

## 版本升级时怎样重审自动化

QEMU 新 tag 可能移动 API、改变维护者、补充安全文档或合入新的设备。升级时先重建 source-fact，不把旧摘要直接替换路径；再运行历史查询，判断变化是重命名、行为修复还是兼容扩展。Agent prompt 和 schema validator也要版本化，旧生成物能由旧环境重放。

若未来上游出现 AI accelerator，先确认真实 type、总线、客户机 ABI、测试和迁移支持，再与本书 oracle 比较。名称相近不代表协议相同，不能让新设备“证明”旧概念设计正确。章节应新增上游实现分析，host-only 实验继续标教学 oracle；需要新的 QEMU 实验时另建英文目录。

自动化模型自身升级也需要回归。用同一故意错误 fixture 测试高危问题是否仍能识别，用固定 evidence packet 检查是否仍区分事实和推断，用 allowlist 检查是否出现范围漂移。结果变化记录工具版本和 prompt diff，不能悄悄选择更顺眼的一次输出。

最终发布仍由确定性工具收口：链接存在、内容计数、风格、代码测试和 Git diff。Agent 可帮助解释失败，门禁本身尽量由脚本给出明确状态。这样即使生成工具变化，书籍和实验仓库仍有稳定的最低质量线。

最后可做一次角色互换：让 Agent 只提交 evidence packet 与测试计划，人手写二十行核心逻辑；再让另一位审查者在看不到生成对话的情况下复核。如果他能从仓库解释每个常量、重放 oracle、指出 fixture 为什么危险，并知道哪些路径尚未实现，说明流程留下了工程资产。若他必须询问“当时模型为什么这么猜”，证据链仍有缺口，应先补材料而非继续扩写设备。

:::: {.quick-quiz}
怎样判断 Agent 辅助真正降低了维护成本？

::: {.quick-answer}
看后续贡献者能否用版本化证据、生成输入、独立测试和决策记录重放与修改，而非看初次生成速度或代码行数。可接手性比一次性的产出量更可靠。
:::
::::

::: {.source-path}
综合项目的当前源码入口包括 [`hw/riscv/virt.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/virt.c)、[`hw/misc/edu.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/misc/edu.c)、[`docs/specs/edu.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/specs/edu.rst)、[`docs/devel/testing/qtest.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/devel/testing/qtest.rst)、[`docs/devel/testing/fuzzing.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/devel/testing/fuzzing.rst)、[`docs/devel/migration/`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/docs/devel/migration) 与 [`docs/system/security.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/system/security.rst)。AI 加速器是本书树外概念模型，K230 的相关地址均为未实现占位；当前章节不宣称 QEMU 上游已有 AI accelerator。
:::

::: {.hands-on}
实验一使用英文手册 [Prototype an AI Accelerator Oracle](../experiments/part-06-heterogeneous-systems/chapter-26-ai-agent-device-modeling/prototype-ai-accelerator/README.md)。它运行宿主侧 `accelerator_model.py` 与测试，验证有界 `2×2` 整数矩阵乘法，预期结果为 `(19, 22, 43, 50)`，并检查非法 shape 与输入。该实验没有 QEMU 设备、PCIe、DMA、IRQ 或迁移实现。正文用中文记录功能契约、边界用例和未来接入清单，禁止把 oracle 测试通过写成上游设备完成。
:::

::: {.hands-on}
实验二使用英文手册 [Review an Agent-Generated Patch](../experiments/part-06-heterogeneous-systems/chapter-26-ai-agent-device-modeling/review-agent-generated-patch/README.md)。仓库中的 C fixture 被故意设计为不可构建、不可复制的审查样本，包含越界、任意 DMA、生命周期、reset、迁移和错误处理等缺陷。读者按中文审查表给每项标 severity、证据、影响与建议测试，再和 README 的 expected findings 对照。实验目标是训练 review，不是修补或提交该 fixture。
:::

## 小结

Agent 能加速提取、生成和覆盖组合，不能替代证据、边界判断和维护责任。把来源、中间表示、生成器、测试与人工审查串起来，AI 辅助才会成为可复现的工程方法，而不是另一层难以追踪的猜测。
