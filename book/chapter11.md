# 正确性怎样塑造 TCG 执行引擎

两颗 RV64 hart 正在运行。hart 0 修改页表，在本地执行 `sfence.vma`，再向 hart 1 发 IPI；hart 1 此时可能还在一串直接链接的 TB 中，用 software TLB 的旧条目访问内存。只有 hart 1 处理通知、执行自己的地址转换 fence 并确认，远程 shootdown 才完成。与此同时，timer 变为 pending，管理线程又请求暂停虚拟机。每个动作单独看都能找到函数，真正难点是它们何时对另一条线程可见，哪一个客户机 PC 应接收异常，旧 TB 和旧地址转换何时失去资格。

SoftMMU、精确异常、自修改代码和 MTTCG 常被分成四组组件。沿这个现场看，它们共同维护一条执行合同：生成代码可以跑得很远，但只能在状态仍有效时继续；合同变化以后，控制权必须回到能够重建一致状态的位置。

## 一条 RV64 `lw` 怎样命中 software TLB

RISC-V 前端为 `lw` 生成 `qemu_ld` 类 IR，后端把 software TLB 查找展开进宿主代码。客户机虚拟地址先按页面位计算 per-vCPU TLB 索引，加载对应 entry，比较读 tag；条目匹配且没有 MMIO、watchpoint、notdirty 等慢路径标志时，地址加上缓存的 offset 就得到 host pointer，随后执行宿主 load。

这张 TLB 是 QEMU 的执行缓存，不模拟某颗真实 RISC-V CPU 的硬件 TLB 容量和替换策略。客户机看不到 `CPUTLBEntry` 数量，也不能用硬件性能计数器观察它。QEMU 可以采用 direct-mapped fast table、victim table 和动态 resize，只要 `sfence.vma`、权限、异常与最终内存结果满足 ISA。

[`accel/tcg/cputlb.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/accel/tcg/cputlb.c) 把常用 tag 与 offset 放进 fast entry，丰富的 MemoryRegion section、访问属性和大页信息放在 full entry。热 RAM load 通常只碰紧凑结构，MMIO 与特殊访问再取完整信息。这种冷热分离让最常见路径留在生成代码中，不必每次回到 C。

同一个虚拟地址在 M、S、U、HS、VS 等上下文中可能得到不同映射和权限。`mmu_idx` 把当前 translation regime 带进 TLB 选择；页表根、ASID/VMID 等变化则配合 flush 保持一致。把所有 CSR 值都塞进 key 会破坏命中率，把上下文压得太粗又容易复用旧权限，RISC-V target 要在两边建立明确协议。

fast path 还要先判断访问是否跨页。RV64 的八字节 load 若从页尾倒数四字节开始，两半可以映到不同 RAMBlock，其中一页也可能 fault 或具有不同端序属性。后端不能只用首地址 TLB entry 做一次宿主 load；slow path会拆分访问，按客户机端序组合，并保证应先发生的 fault 与副作用顺序。

entry 中的 addend/offset 只在对应 MemoryRegion 映射有效期间成立。迁移 dirty logging 打开、ROM 写保护变化、watchpoint 安装或内存拓扑 transaction 提交时，listener 与 flush 协议要让旧 fast entry 失效。software TLB 位于 CPU 与全局 AddressSpace 之间，不能把一个 host pointer 当永久映射保存。

动态 resize 也服务这个取舍。更大的表降低冲突 miss，却增加 flush 时间、宿主 cache 占用和扫描成本；小表在大工作集下频繁 miss。当前实现只在 flush 时做 resize bookkeeping，利用过去的 miss/flush 观察调整。客户机看不到这项策略，性能实验却要记录 resize 点，否则曲线突变会被误判为页表算法变化。

:::: {.quick-quiz}
为什么 QEMU software TLB 不能用来预测真实 RISC-V 芯片的 TLB miss rate？

::: {.quick-answer}
它是模拟器内部的地址转换缓存，条目布局、索引、victim table 与 resize 都按宿主执行性能设计。客户机可见合同只有转换结果、权限、fault 与 fence 后的一致性，真实芯片的微架构由具体实现决定。
:::
::::

## miss 以后，RISC-V 接管架构语义

fast lookup 失败后，公共 slow path 调用 `TCGCPUOps.tlb_fill`。在 `v11.1.0-rc0` 的 [`target/riscv/tcg/tcg-cpu.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/tcg/tcg-cpu.c) 中，这个 hook 指向 `riscv_cpu_tlb_fill()`；实现位于 [`target/riscv/tcg/cpu_helper.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/tcg/cpu_helper.c)。它根据 address、访问类型、size 与 `mmu_idx` 执行页表规则，并结合 PMP 等保护。

fill 接口还有 probe 与 host return address 等参数。调试地址查询可以探测映射而不注入客户机异常，真实执行失败则要退出 TB；return address 用于把 fault 对回生成代码位置。调用者若在 probe 路径意外提交 exception，GDB 读内存就可能改变客户机状态；真实路径丢掉 return address，又会失去精确 PC。

普通 Sv39 下，GVA 经 `satp` 指向的页表得到 system physical address；H 扩展 V=1 时，VS-stage 先把 guest virtual address 变成 guest physical address，G-stage 再用 `hgatp` 转成 hypervisor 管理的 system physical address。读取 VS-stage PTE 本身也是 guest physical access，还要经过 G-stage。一次 `lw` 因而可能在第一阶段 leaf、隐式 PTE 的第二阶段或最终 GPA 的第二阶段失败。

转换成功后，`tlb_set_page_full()` 结合 QEMU AddressSpace 找到 RAM、ROM 或 MMIO MemoryRegion。RAM entry 形成 host offset，设备 entry 保留 I/O 分派信息；转换失败则设置 RISC-V exception 与 fault address。H 扩展还要区分 guest-page fault 的 `tval`、`htval` 等字段，不能把所有失败压成一个“地址无效”。

页表 walk 与 MemoryRegion 分派是相邻的两层。PTE 允许访问，只说明得到一个 system physical address；该地址仍可能落在 UART、PCIe window、ROM 或空洞。设备 transaction failure 最终要映射回合适的 RISC-V access fault。定位错误时先标出 GVA、GPA、system physical address 和 host virtual address，避免同一个“物理地址”跨层使用。

software TLB 缓存的是已经核验的常见结果。页表或 privilege 改变以后，QEMU 必须在再次使用前 flush 相关 entry；MemoryRegion 拓扑、dirty logging 和 watchpoint 变化也会更新 fast-path flag。缓存让正确路径更快，不会减少目标对完整页表语义的责任。

## fault 如何回到准确的客户机指令

TB 中可能有几十条客户机指令，PC 与部分架构状态没有每条都写回 `env`。当第七条 `lw` 在 TLB fill 中发现 page fault，RISC-V trap 必须把 `xepc` 指向第七条；落在 TB 起点会重复前六条已提交副作用，落在下一条会跳过故障访问。

translator 在可异常 op 前用 `decode_save_opc()` 保存恢复信息，TCG 记录客户机 instruction boundary 与宿主代码 offset。slow path 收到宿主 return address，`cpu_restore_state()` 找到所属 TB 和 op，调用 RISC-V `restore_state_to_opc` 恢复 PC 等延迟状态。随后 `cpu_loop_exit_restore()` 通过非局部跳转回到 `cpu_exec()` 的恢复点。

非局部退出省掉了 helper 调用链逐层返回错误码的成本，也带来资源纪律。可能调用 `cpu_loop_exit()` 的 helper 不能把普通局部锁留在被越过的栈帧，CPU state 与 `exception_index` 要在统一恢复点形成有效状态。review 一段 helper 时，看到 `noreturn` 或 `GETPC()` 就要同时检查锁、状态保存和恢复路径。

回到外层后，通用执行循环把体系结构异常交给 `riscv_cpu_do_interrupt()`。目标代码选择 M、HS 或 VS trap 入口，写 `xepc`、`xcause`、`xtval` 及 H 扩展字段，更新 privilege/V 状态和 interrupt enable，最后跳到 vector。trap 改变了翻译相关状态，旧 TB key 通常不再匹配，执行从新 PC 与新 flags 重新 lookup。

:::: {.quick-quiz}
为什么 translator 可以不在每条指令后写回 PC？

::: {.quick-answer}
连续执行时可用 TB 元数据和翻译上下文推导 PC，减少热路径写内存。所有可能离开的路径必须保留宿主位置到客户机指令的映射，并在异常、调试或管理退出前恢复准确状态；缺少这套恢复协议就不能延迟写回。
:::
::::

## 异常、中断和管理退出走相似出口却有不同语义

同步异常由当前指令触发，例如 illegal instruction、load page fault 与 `ecall`；架构中断来自 timer、IPI 或设备，可在允许的指令边界接收；debug stop 服务 GDB 或 trigger；QEMU 内部退出处理暂停、排队工作、TB flush 与线程终止。四类事件都可能让宿主代码返回 C，客户机观察范围却不同。

QEMU 用不同状态通道保存原因：目标 exception、interrupt request bits、TB exit code、`exit_request` 与 runstate 各有职责。若全部压成一个布尔值，外层无法判断要写 trap CSR、通知调试器还是只完成管理工作。调试时可以先问“谁应该看到这次停止”：客户机 trap handler、GDB、管理层，或仅 QEMU 内部。

中断注入也分两步。设备控制器改变 pending/line，QEMU 设置 CPU interrupt request 并 kick 可能正在睡眠或生成代码中运行的 vCPU；真正进入 RISC-V trap 时，`riscv_cpu_exec_interrupt()` 再检查 enable、delegation、priority 与当前 privilege。line 拉高不等于客户机已经处理，中间还可能被 mask、委托或延后。

WFI 展示了这层差异。hart 没有可处理工作时可以阻塞等待，interrupt becoming pending 要唤醒线程；醒来后仍要按 RISC-V 规则决定是否 trap。把 wakeup 与 interrupt delivery 合成一步，可能让 masked event 错误进入 trap，也可能让已经满足条件的 hart 永远睡着。

直接链接的 TB 也不能让退出请求饿死。有限 TB 边界、生成代码检查点和 vCPU kick 共同保证控制权最终回到主循环。每条指令都检查会拖慢热路径，只在无限长链尾检查又没有延迟上界，当前设计依靠可控块长与安全点折中。

`cpu_tb_exec()` 返回值还编码最后执行 TB 与 exit reason。主循环借它判断能否把前一块 jump slot 链到下一块，或必须先处理 interrupt、atomic path 与内部请求。链接只消掉重复 lookup，不会取消 TB 边界的状态恢复责任；异步事件到来时，已 patch 的链仍要在检查点可撤销地返回。

## 自修改代码怎样让旧 TB 失去资格

QEMU 生成 TB 后会把它与客户机物理代码页关联。system emulation 的写路径能够识别对已翻译页面的修改，失效相关 TB，解除指向它们的 direct jump，并清理 lookup 结构。旧宿主代码即使仍在代码缓存里，也不能再被新 lookup 选中。

RISC-V 客户机还承担 ISA 规定的指令一致性。当前 `trans_fence_i()` 检查 Zifencei，然后结束当前 TB；源码注释称 FENCE.I 在 QEMU 内部是 no-op，但必须结束翻译块。原因在于页面写入路径已经负责 QEMU 侧代码失效，`fence.i` 的执行边界仍要阻止当前 TB 继续携带旧取指假定。

“no-op”不能理解为客户机可省略 `fence.i`。规范决定软件何时承诺后续取指看见写入，QEMU 的实现可以用写保护、dirty flag 与 TB invalidation 提前完成一部分工作。故意省略同步的测试只展示当前时机，不能成为架构保证。

跨页 TB 和 direct chaining增加了账本。失效一页时要找到覆盖该页的块，撤销所有 incoming jump，让 per-vCPU jump cache 与全局 lookup 不再返回它。MTTCG 下另一颗 vCPU 可能正在执行旧块，回收还要遵守并发与生命周期协议。简单地把 `valid=false` 写入一个字段，无法完成全部工作。

精确失效比全局 flush 复杂，却保留无关热代码。验证时放一页被修改代码和一页无关热循环，断言前者重译、后者继续复用。只看新代码生效，无法区分精确失效与“每次写都清空整个缓存”。

## 多核把隐含串行假设暴露出来

早期 system-mode TCG 在一个线程中轮转多颗 vCPU。多个 hart 看似并行，宿主同一时刻只有一颗在执行，许多共享数据结构无需并发保护。随着客户机核数增长、宿主单核性能提升放缓，round-robin 不能利用多核吞吐，模拟一台多核机器仍被锁在一颗宿主核上。

2017 年的 MTTCG 系列把这项限制变成显式设计。提交 [`372579427a`](https://gitlab.com/qemu-project/qemu/-/commit/372579427a5040a26dfee78464b50e2bdf27ef26) 为每颗 vCPU 建立线程，保留旧的 round-robin 函数作为 single-thread 模式。提交记录 Frederic Konrad、Paolo Bonzini、Alex Bennée 的 Signed-off-by，并带 Richard Henderson 的 Reviewed-by，角色链在现代 Git 历史中可以核验。

相邻提交 [`8d4e9146b3`](https://gitlab.com/qemu-project/qemu/-/commit/8d4e9146b3568022ea5730d92841345d41275d66) 先加入 `thread=multi|single` 选项，默认只对已声明支持的 frontend/backend 组合开启；[`2f16960660`](https://gitlab.com/qemu-project/qemu/-/commit/2f1696066049c25f7f7d75352aa0cad3b0b1d87e) 为 SoftMMU 的 TB 生成和 PageDesc 共享结构加锁；[`e3b9ca8109`](https://gitlab.com/qemu-project/qemu/-/commit/e3b9ca810980851f93f5719a7df2044c9435f003) 把跨 vCPU TLB flush 改为异步工作。每一步对应一个从前被单线程掩盖的共享状态。

当前 [`docs/devel/multi-thread-tcg.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/devel/multi-thread-tcg.rst) 延续这条设计：每颗 vCPU 独立线程，只有 guest memory model 能由 host/backend 承担、target 已完成安全工作时才启用。RISC-V 的 `riscv_tcg_ops` 明确设置 `.mttcg_supported = true`，并提供 guest default memory order；这是一项实现声明，还要由 barrier、atomic、TLB 与设备锁共同兑现。

`-accel tcg,thread=single` 仍然有用途。icount 等模式可能要求 round-robin 带来的确定调度，调试并发差异时也能作为对照。single-thread 消除了宿主并行，却没有改变客户机程序的内存模型；一个数据竞争程序在该模式下碰巧得到稳定结果，不能把结果提升为 RISC-V 保证。

MTTCG 的启用判断也包含 frontend/backend 组合。guest 前端声明默认 memory order，host backend 声明本机生成代码能够提供的 order，公共层检查二者是否兼容。target 设置 `mttcg_supported` 表示相关共享状态路径已经审查，仍不代表所有设备无锁；MMIO 进入 BQL 或设备锁后，vCPU 线程可以局部串行。

## MTTCG 要同步哪些状态

第一类是 TB 与代码缓存。lookup 是极热路径，需要尽量无锁或低争用；生成、发布、direct jump patch 与失效则会修改共享结构。当前实现使用 per-vCPU cache、并发安全哈希、原子 jump patch 和更细的锁/RCU 协议。读线程命中一个 TB 时，要保证对象已完全初始化且生命周期仍有效。

第二类是 per-vCPU software TLB 与多缓存失效协议。RISC-V 客户机执行 `sfence.vma`、`hfence.vvma` 或 `hfence.gvma` 时，QEMU 只刷新当前 vCPU；远程 shootdown 由客户机先发布页表更新，再通过 SBI remote fence 或 IPI 让目标 hart 执行本地 fence 并返回确认。QEMU 自身修改全局地址空间或处理其他全局失效时，可以调用 `tlb_flush_*_all_cpus_synced`，通过 safe work 让目标 vCPU 到达安全点并完成 flush。这个内部 API 不是普通客户机 fence 的实现，两种协议不能混用。

safe work 的价值在于状态所有权。每颗 vCPU 线程最了解自己的 TLB 和执行位置，外部线程先发布 work、设置退出请求并 kick；vCPU 到安全点后在自己的上下文执行更新。调用者需要同步保证时等待完成。直接从 hart 0 任意改写 hart 1 正在读取的多字段 entry，会产生 tag 已更新、offset 仍旧的中间状态。

第三类是客户机内存模型。RVWMO 允许一部分重排，也要求 fence、acquire/release 与原子指令建立规定顺序。TCG IR 要表达 barrier 和 atomic，backend 根据宿主模型发射足够强的操作。若 guest 比 host 要求更强，后端补 fence；若前端漏掉 ordering，单线程模式可能一直通过，MTTCG 才会暴露旧值或禁用结果。

第四类是设备与跨 CPU 状态。MMIO 通常进入设备模型并由 BQL 或设备自身锁保护；中断控制器、reset、power control 与某些 CSR helper会同时触碰多个对象。把 BQL 提到所有 TCG 热路径会失去并行收益，推得太深又会留下竞态。当前原则是普通生成代码尽量并行，进入共享设备状态时在最窄位置串行。

:::: {.quick-quiz}
把共享字段改成原子变量，是否就完成了 MTTCG 支持？

::: {.quick-answer}
原子变量只保证一次读写的原子性。TB 发布、TLB shootdown、trap 状态提交、设备中断和暂停都包含多步状态转换，还需要内存序、生命周期、锁域与安全点。必须为完整协议说明“谁发布、谁等待、何时可以继续”。
:::
::::

## RISC-V fence 把 IR、TLB 与线程协议接在一起

普通 `fence` 在 RISC-V translator 中生成 `tcg_gen_mb(TCG_MO_ALL | TCG_BAR_SC)`，host backend 兑现内存屏障。`sfence.vma` 检查 privilege 与 TVM/VTVM 等条件，再进入 TLB flush helper；H 扩展的 `hfence.vvma` 与 `hfence.gvma` 还要区分 VS-stage/G-stage 语义。三类 fence 名字相近，作用对象并不相同。

普通 memory fence 约束 load/store 的观察顺序，通常无需清 QEMU software TLB；地址转换 fence 让页表更新与当前 hart 后续的 translation 建立关系，只刷新当前 vCPU。其他 hart 需要由客户机显式完成 remote-fence 或 IPI—local-fence—ack 协议。`fence.i` 在当前实现中结束 TB，配合取指一致性重新进入翻译。把三类 fence 都实现成一个“全局清空”也许容易通过基础测试，却会损失性能并模糊异常条件。

RISC-V H 扩展让测试更容易分层。同一个 GVA 经 VS-stage 与 G-stage 到 RAM，hart 0 修改 `vsatp` 指向的 leaf，先执行对应的本地 VS translation fence；修改 `hgatp` 或 G-stage leaf，则先执行本地 GVMA fence。若还要更新 hart 1，客户机必须再请求远程 fence，或发送 IPI 让 hart 1 执行相应本地 fence并确认。每次只改变一层，分别记录确认前后的 old/new translation 和 trap CSR，才能知道缓存失效发生在哪个阶段。

fence helper 还可能抛 illegal 或 virtual instruction exception。translator 在调用前保存 opcode，异常恢复回到 fence 自身；在固定基线中，`sfence.vma` 与 `hfence.*` 成功后不会因此强制结束 TB，只有 `fence.i` 在这里显式生成 TB exit。性能优化不能删除 privilege check 或把 flush 越过相关访存，也不能从 helper 调用反推出一个源码中不存在的退出。

## 调试一次并发故障需要三条时间线

只记录 hart 1 的调用栈，通常看不到 hart 0 何时发布页表、设备线程何时拉高中断。更有效的日志分三条泳道：客户机事件记录 PC、hart、CSR 与内存操作；QEMU vCPU 线程记录 TB exit、safe work、TLB flush 与 trap；设备/管理线程记录 IRQ、pause、reset 和 kick。

三条线通过稳定 ID 对齐：CPU index、客户机地址、TB start PC、work item 和 interrupt source。host timestamp 只能辅助排序，不能证明 happens-before；内存序与锁协议仍从源码、原子操作和同步 API 得出。trace 溢出也要报告，缺一条事件不自动等于没有发生。

复现程序应减少竞争源。页表 shootdown 每轮只改一个 PTE，用 barrier 确保发布顺序，再发 IPI；目标 hart 在 handler 中执行匹配的本地 fence，写入 ack 后才能判定 shootdown 完成。timer 使用 icount 或可控步进，避免 wall-clock 抖动；设备中断选择可观察 pending 的控制器。若故障在日志打开后消失，先怀疑时序被 I/O 扰动，改用 trace backend或计数器。

调试器读取寄存器也要取得状态所有权。all-stop 模式先让各 vCPU 离开 JIT code，在安全点恢复延迟 CPU state，再向 GDB 报告；若一颗 hart 仍在运行，另一线程直接读 `env` 可能看到部分 global 已写回、部分仍在宿主寄存器。non-stop debug 的合同更复杂，实验应明确哪颗 hart 已停止、共享内存是否仍可变化。

pause、migration 与 reset 同样依赖交接。管理线程发出请求以后，要等每颗 vCPU 报告 quiescent，设备和 CPU state 才形成可保存快照；resume 前又要保证 queued flush 与 interrupt 状态已经发布。把“命令返回”与“线程真正停住”混淆，会生成偶发不可迁移或幽灵中断问题。

最后建立客户机 oracle。架构允许的共享内存结果列成集合，禁止结果一旦出现就保存 seed 与完整配置；page fault 要逐字段核对 PC、cause、tval/htval 和 privilege；管理 pause 完成后，所有 vCPU 计数必须停止。内部 TB 数或线程调度顺序只能作为实现证据。

## 实验：让 RV64 trap 逐字段落地

::: {.hands-on}
使用 [`inject-riscv-trap`](../experiments/part-02-tcg-execution-engine/chapter-11-exceptions-and-mttcg/inject-riscv-trap/README.md)。在 RV64 TCG 裸机环境依次触发 illegal instruction、load page fault、timer interrupt、software IPI 与外部中断；再启用 H 扩展，构造委托到 VS、trap 到 HS 和 guest-page fault。

每个 case 保存故障指令机器码、TB 起始 PC、触发指令 PC、`cause`、`tval` 类 CSR、trap 前后 privilege/V 状态和 vector。同步 load fault 与 timer pending 放在相邻位置，验证先提交正确同步异常，再按架构规则处理异步中断。目的寄存器设置哨兵，fault 前不能提前写回，修复页表返回后才得到 load 值。

静态路径同时标出 `decode_save_opc()`、`qemu_ld`、`riscv_cpu_tlb_fill()`、restore 与 `riscv_cpu_do_interrupt()`。动态日志覆盖不到的分支明确标成源码证据，不用一次成功启动替代异常矩阵。
:::

## 实验：比较 single-thread 与 MTTCG

::: {.hands-on}
使用 [`compare-tcg-thread-modes`](../experiments/part-02-tcg-execution-engine/chapter-11-exceptions-and-mttcg/compare-tcg-thread-modes/README.md)。两个 RV64 hart 运行共享内存计数、LR/SC、IPI、WFI 与页表 shootdown，分别指定 `-accel tcg,thread=single` 和 `thread=multi`。保存 vCPU 线程拓扑、允许的内存结果、从 IPI 到目标 hart 本地 fence 再到 ack 的事件链、TLB flush 完成点与 QEMU commit。

无同步共享计数在 single-thread 下碰巧通过，不构成正确程序；MTTCG 出现丢失更新反而能暴露测试缺少原子保护。加入正确 LR/SC 或 AMO 后，两种模式都应满足 oracle。页表用例要求目标 hart 的 fence ack 返回后不再访问旧映射；只执行发起 hart 的 `sfence.vma` 时，不能提出这项保证。WFI 用例要求 sleeping hart 能被 IPI 唤醒并按 enable/priority 决定 trap。

性能数据分开报告。single-thread 不能利用多宿主核，却可能没有锁争用；MTTCG 吞吐随 workload、设备 BQL 和 host topology 变化。实验重点先验证并发合同，再讨论扩展性，避免用一张加速比曲线掩盖禁止内存结果。
:::

## 小结

TCG 生成的代码能够连续运行，前提是 TB 身份、地址转换、客户机代码和共享状态仍然有效。SoftMMU 把常见地址转换留在生成代码，miss 回到 RISC-V 页表语义；恢复映射把宿主 fault 点带回准确客户机 PC；页面失效撤销旧 TB；MTTCG 用线程、原子、锁与 safe work 让这些合同在多 vCPU 下继续成立。

到这里，第二篇的路径已经闭合：RISC-V 指令经过 decode 生成强类型 IR，optimizer 与 liveness 清理，regalloc/backend 发射宿主代码，TB 缓存并执行；访存通过 SoftMMU，异常按元数据恢复，多核通过 MTTCG 协调。TCG 的性能来自整条链共同缩短热路径，它的边界也由整条链共同约束。
