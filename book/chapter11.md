# TCG 异常、中断与 MTTCG

TCG 最快的时候，vCPU 在一串已链接 TB 之间连续跳转，几乎看不到 QEMU 的 C 执行循环。偏偏虚拟机最需要管理的时候，控制权必须及时回来：一条 load 产生 page fault，timer 到期，另一线程请求暂停，调试器插入断点，页表 shootdown 要清 TLB。执行引擎既要跑得连续，又要在正确的客户机指令边界停住，这两件事共同塑造了 `cpu_exec()`、TB exit 和跨线程 kick。

多 vCPU 以后，问题还多一层。一个 hart 写页表并发 IPI，另一个 hart 正在宿主代码里使用旧映射；设备线程拉高中断，halted vCPU 睡在条件变量；管理线程发布 stop，执行线程要先看见请求再退出。把共享字段换成原子变量只解决单次读写，完整状态转换仍依赖内存序、安全点和锁域。

## 本章目标

- 区分同步异常、体系结构中断、调试事件与 QEMU 内部退出请求；
- 跟踪 TB 返回、`cpu_loop_exit()`、`cpu_handle_exception()` 与 RISC-V trap；
- 理解 delegation、HS/VS 状态切换和 trap CSR 更新；
- 说明设备 IRQ、pending/enable、`has_work`、WFI 与 vCPU kick；
- 分析 MTTCG 中 exit request、TLB shootdown、TB invalidation 与原子执行。

## 四类“停下来”先分开

同步异常由当前客户机指令触发，例如非法指令、取指 page fault、未对齐 load、`ecall`。它必须归因到精确 PC，trap handler通常需要知道是否可修复并重试。外部中断来自 timer、软件 IPI或外设，可以在架构允许的指令边界接收，它不属于当前指令的执行失败。

调试事件包括单步、trigger、断点和 watchpoint。它们可能映射为 RISC-V debug mode或由 GDB stub接管，停止原因要能区分。QEMU内部退出请求则是管理机制，例如暂停虚拟机、处理排队工作、TB flush或线程终止，客户机通常不应看到一个 trap。

四类事件最后都可能让生成代码回到 C，所以调用栈表面相似。若把它们压成一个 `exit=true`，执行循环就要重新猜原因，精确异常和管理状态很容易串线。QEMU使用 `exception_index`、interrupt request bits、TB exit reason与 `exit_request` 等不同通道，分别携带语义。

一个调试技巧是问“谁应该观察到”。客户机 trap handler能看到同步异常和已注入中断；GDB能看到 debug stop；管理层能看到暂停完成；QEMU内部 flush不应凭空改变客户机 CSR。沿这个问题查状态，常比从 `longjmp` 机械展开更快。

## 从宿主代码返回 `cpu_tb_exec`

`cpu_tb_exec()` 调用 TCG prologue进入 TB，宿主代码从若干出口返回，带回 TB指针与 exit code。正常 branch可查找下一个 TB，已建立 direct chaining时甚至不立即回 C；请求退出、异常或特殊原子路径则回到外层处理。

生成代码会在约定位置检查退出条件。每条客户机指令都检查最及时，却增加热路径负担；只在很长 TB末尾检查，响应延迟又不可控。TCG利用有限 TB长度、入口/出口检查和必要的 helper exit组合，在吞吐与及时性之间折中。

TB return时，`cpu_tb_exec()`还要从编码结果中取出实际退出原因。若宿主 PC指向 TB内部异常点，恢复逻辑借翻译元数据把 `env->pc` 等目标状态还原到对应 RISC-V 指令。连续宿主代码因此可以延迟部分状态写回，只要所有可离开路径都遵守恢复协议。

直接链接并没有绕开这项协议。外部线程发布退出请求并 kick vCPU后，执行链在检查点离开；TB失效也会解除链接。若某个后端出口遗漏检查，问题只会在热链上出现，关闭 chaining或单步时反而消失。

## `cpu_loop_exit()` 为何使用非局部跳转

访存 slow path、helper深层函数可能发现客户机异常。逐层返回错误码会让每个 helper、每个 TCG调用点携带分支，正常路径变重。QEMU的 `cpu_loop_exit()` 设置异常状态后，通过 `siglongjmp` 返回 `cpu_exec()`建立的恢复点，由统一代码清理锁和处理 trap。

非局部跳转要求严格资源纪律。越过的栈帧不会执行普通清理，helper不能在可能 exit前持有无人释放的局部锁或资源；需要清理的状态应在统一恢复点处理，或使用能承受 longjmp的协议。源码注释常标明函数是否可能 `noreturn`，review不能把 helper当普通 C调用。

`cpu_exec()` 入口用 `sigsetjmp(cpu->jmp_env, 0)` 建立环境，longjmp后重置当前 CPU和异常相关状态，再进入 exception loop。2025 年提交 [`67cf90efc3`](https://gitlab.com/qemu-project/qemu/-/commit/67cf90efc3) 在恢复 vCPU前重置 `exception_index`，提交标题本身说明旧异常若未清理会污染下一轮。一个整数索引的生命周期，必须与非局部退出边界一致。

作者推断，`cpu_loop_exit` 应被视为执行引擎的“异常 ABI”。调用者不仅声明要离开，还承诺 CPU state已足够恢复、锁状态符合约定、`exception_index` 表达正确原因。这个说法不是上游术语，却能解释为何移动一段 helper代码时必须审查 longjmp可能性。

:::: {.quick-quiz}
同步异常为什么要求精确的客户机 PC？

::: {.quick-answer}
trap handler要保存故障指令地址，修复页表或模拟指令后可能返回重试。PC落到前一条，会重复已经提交的副作用；落到后一条，又会跳过故障指令。TCG可以在 TB内延迟写 PC，但异常出口必须通过生成时元数据恢复到准确的 RISC-V 指令。
:::
::::

## `cpu_handle_exception()` 分流什么

回到 C后，`cpu_handle_exception()`检查 `exception_index`。某些值表示目标体系结构异常，调用 `CPUClass` 或 `TCGCPUOps` 的目标中断处理；某些值表示 debug、halt、atomic或内部退出，返回上层。通用执行循环不理解每个 RISC-V cause，它只知道何时交给目标。

目标异常处理前，CPU state要处于可报告状态。RISC-V translator在生成可能 fault的 op前记录当前 PC，SoftMMU helper带 return address，restore路径重建 `env`。目标 `riscv_cpu_do_interrupt()`再读取 exception code、fault address与当前特权状态，选择 trap目标并写 CSR。

异常处理本身可能结束当前 TB并改变 MMU index。进入 M、HS或VS后，页表、端序、中断 enable都可能变化，旧翻译 flags不再适用。trap完成后回到 lookup，以新 PC和状态寻找或生成 TB。试图从原 TB中直接跳 trap vector，会绕过状态 key更新。

## RISC-V trap 目标如何选择

没有虚拟化时，M-mode可通过 `medeleg/mideleg` 把部分异常和中断委托给 S-mode。目标函数先区分 interrupt bit与 cause number，再检查 delegation和当前 privilege，选择写 `mepc/mcause/mtval` 或 `sepc/scause/stval`，更新 status中的 previous privilege与 interrupt enable，最后跳到 `mtvec` 或 `stvec`。

H 扩展加入 HS与VS视图，`hedeleg/hideleg` 可以继续把合适事件交给 VS-mode。V=1 时，S级 CSR在客户机视角映射到 VS状态；trap进 HS可能需要交换或切换 hypervisor寄存器视图，保存 SPV、SPVP等字段。`riscv_cpu_swap_hypervisor_regs()` 与 `riscv_cpu_set_mode()` 是当前实现的重要节点。

delegation不是单纯“位为一就下放”。目标 mode不能低于当前执行上下文不允许的层级，某些异常不可委托，virtual instruction与guest-page fault有H扩展专属规则。向量地址还根据 direct/vectored mode和 cause计算，异常通常使用 base，中断可按编号偏移。

当前 [`riscv_cpu_do_interrupt()`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/tcg/cpu_helper.c) 代码较长，因为它同时提交 PC、cause、tval类字段、status栈和 mode切换。读时先画三条路径：进M、进HS、进VS，再分别加入异常/中断差异，比顺序解释每个 if更容易。

## trap CSR 是一笔原子提交

从客户机视角，trap发生后应看到一组自洽状态：`xepc` 指向规定位置，`xcause` 原因正确，`xtval` 附加信息匹配，status保存旧 enable与 privilege，PC落到 vector。实现若先切 mode再用“当前 mode”选择旧 CSR来源，可能把值写到错误 bank。

QEMU在一个 C函数中顺序更新字段，但MTTCG其他 vCPU通常不能直接读取这颗hart的私有 CSR，客户机观察点仍在下一条指令。调试器和管理线程却可能并发请求停止，所以 CPU线程要在安全点形成一致状态再报告。BQL并不自动保护所有 CPU私有字段，停止协议负责让执行线程交出所有权。

2024 年提交 [`1525d8aa3a`](https://gitlab.com/qemu-project/qemu/-/commit/1525d8aa3a) 修复 H扩展下 VS-mode exception cause被错误调整，提交说明指出只有 interrupt cause需要相应转换。这个历史说明，异常和中断即使共享 trap提交代码，也不能把 cause编码规则完全统一。

异常附加值也有尺寸风险。2026 年提交 [`98eccd8353`](https://gitlab.com/qemu-project/qemu/-/commit/98eccd8353) 让 `riscv_cpu_get_trap_name()` 的 cause参数使用与 `env->mcause` 匹配的64位类型，邮件 [`20260520125406.28693-19-anjo@rev.ng`](https://lore.kernel.org/qemu-devel/20260520125406.28693-19-anjo@rev.ng/) 给出证据。日志辅助函数若截断 interrupt bit，调试输出会误导，即使实际 trap仍正确。

## RISC-V 中断从设备走到 hart

timer、软件中断和外部设备先进入不同控制器。`virt` machine可使用 ACLINT提供软件/timer源，PLIC或AIA的APLIC/IMSIC负责外部和消息信号。控制器更新 pending，连接到 CPU IRQ input，RISC-V CPU代码再把对应位反映到 `mip`、`sip`、`hvip`或AIA状态。

pending不等于立即接受。`mie/sie/vsie` enable、全局 status IE、当前 privilege、delegation、优先级和AIA规则共同决定 `riscv_cpu_local_irq_pending()` 返回哪一个。`riscv_cpu_exec_interrupt()` 在通用执行循环看到 hard interrupt request后调用它，有合格中断才设置 exception并进入 `riscv_cpu_do_interrupt()`。

设备电平与CSR pending必须保持关系。level-triggered IRQ在处理器清 pending后若设备线仍高，应再次出现；edge或MSI则由控制器保存。把所有来源直接 OR进一个字段，清除路径会丢失来源。当前 `riscv_cpu_update_mip()` 及中断控制器回调围绕 mask/value维护状态，AIA又有独立ireg接口。

2026 年 RISC-V TCG拆分系列在提交 [`6c91b423a9`](https://gitlab.com/qemu-project/qemu/-/commit/6c91b423a9) 为 `riscv_cpu_update_mip` 加 `tcg_enabled()`门，提交说明指出它是TCG-only，KVM有等价路径；邮件 [`20260703180538.3346781-17-daniel.barboza@oss.qualcomm.com`](https://lore.kernel.org/qemu-devel/20260703180538.3346781-17-daniel.barboza@oss.qualcomm.com/) 提供审查上下文。客户机中断语义共享，软件pending实现并不共享，这正是加速器边界。

## `interrupt_request` 是调度提示

公共 `CPUState::interrupt_request` 告诉执行循环有事件值得检查，它不保存全部RISC-V优先级语义。目标 hook仍需读CSR和控制器状态决定是否接受。这样通用循环无需理解RISC-V AIA，也能让生成代码及时返回。

读取和修改 request bits必须原子，并保持发布顺序。2025 年提交 [`87511341c3`](https://gitlab.com/qemu-project/qemu/-/commit/87511341c3) 增加 `cpu_test_interrupt()`、`cpu_set_interrupt()` helper并全树使用，提交说明强调 helper形成 load-acquire/store-release配对；[`602d5ebba2`](https://gitlab.com/qemu-project/qemu/-/commit/602d5ebba2) 又用 `cpu_reset_interrupt()` 清位，避免开放编码在BQL不持有时出错。

上游事实是公共字段访问被收拢并加强内存序。作者推断，helper名称也在限制调用者：设备发布详细pending状态后，再用 release set request；CPU acquire看到request后，随后读取目标状态。若顺序相反，执行线程可能看到“有中断”却暂时看不到对应cause。

## halted 与 WFI 为什么仍需唤醒

RISC-V `wfi` 表示等待中断提示，具体可被实现当作nop或让hart休眠。QEMU TCG通常设置 halted并离开执行循环，vCPU线程等待条件。设备中断到来时必须 kick，让线程重新执行 `has_work`与中断判定。

被屏蔽的pending是否足以唤醒，涉及RISC-V WFI语义与实现策略。`riscv_cpu_has_work()`不能只检查一个通用bit，还要看目标pending组合。与此同时，暂停、关机、debug和排队work即使不是客户机中断，也要唤醒halted线程。kick是调度机制，接受trap是架构机制，两者不要合并。

:::: {.quick-quiz}
halted 的 RISC-V vCPU 为什么仍可能需要被 kick？

::: {.quick-answer}
halt只表示当前没有继续执行客户机指令，外部中断、跨CPU工作、暂停、调试和runstate变化都可能让线程采取行动。kick唤醒或打断阻塞，随后vCPU再由 `has_work`、interrupt enable和管理请求决定继续、注入trap或保持停止。
:::
::::

2026 年提交 [`e49b1e25fa`](https://gitlab.com/qemu-project/qemu/-/commit/e49b1e25fa) 把一些IRQ helper移到公共RISC-V CPU文件，提交说明指出 `riscv_cpu_has_work()` 使用它们，且KVM关心的中断控制器也会调用。邮件 [`20260703180538.3346781-14-daniel.barboza@oss.qualcomm.com`](https://lore.kernel.org/qemu-devel/20260703180538.3346781-14-daniel.barboza@oss.qualcomm.com/) 展示边界审查。不能因为函数读取pending就自动归类TCG-only，要看语义是否由两条accelerator共享。

## MTTCG 改变了什么

早期单线程TCG可以轮流运行多个vCPU，设备和CPU操作天然串行，许多代码隐含依赖这一点。MTTCG让每颗vCPU在独立线程上执行TB，多核客户机的并行更真实，宿主多核也能提供吞吐。代价是共享内存、设备状态和全局缓存必须有明确并发协议。

RISC-V guest memory的普通并行访问由TCG内存模型和原子op保证；QEMU内部元数据如TLB、TB page list、interrupt request、CPU work queue各有锁或原子规则。BQL仍保护很多设备控制面，但vCPU不在每条指令上持有BQL，否则MTTCG失去意义。代码审查必须知道当前函数运行在哪个线程、是否持BQL、是否可能从helper longjmp。

`accel/tcg/tcg-accel-ops-mttcg.c` 的vCPU thread loop围绕 `qemu_wait_io_event()`、`qemu_process_cpu_events()` 和 `cpu_exec()`。线程先处理外部事件，再进入长时间执行，退出后重新检查。这个循环是管理控制面与生成代码数据面交接的位置。

## exit request 的发布与消费

另一个线程希望vCPU回到事件循环，会设置 `exit_request`并kick。CPU在TB边界或生成代码检查点用 acquire读取，看到后离开执行。事件处理完成后清除请求，再决定是否继续。若清得太早，后来的请求可能丢；若永不清，vCPU会每次立即退出。

提交 [`ac6c8a390b`](https://gitlab.com/qemu-project/qemu/-/commit/ac6c8a390b) 为跨线程 `exit_request` 使用 store-release/load-acquire。提交说明坦率地说，旧代码“可能”通过BQL间接得到保护，但关系不清楚，因此显式统一。这个上游动机很有代表性：并发正确性不应建立在调用者碰巧稍后拿某把锁上。

提交 [`f084ff128b`](https://gitlab.com/qemu-project/qemu/-/commit/f084ff128b) 又让 exit_request使用原子访问，`6bb8f2c51b` 将清理集中到 `tcg_cpu_exec()`，`9a191d3782` 最终在 `qemu_process_cpu_events`处理后清除，使accelerator调用方式趋同。沿这串历史能看到，字段类型、内存序和生命周期位置是一起调整的。

:::: {.quick-quiz}
为什么把每个共享字段换成原子变量，仍不足以获得正确的 MTTCG？

::: {.quick-answer}
原子变量只保证该次读写不会撕裂，不自动规定“先发布详细状态、再发布请求”，也不保护多个字段组成的状态机。设备回调顺序、TB生命周期和客户机内存模型仍需 release/acquire、锁、安全点与等待完成协议。单字段原子是工具，不是完整设计。
:::
::::

## kick 还要覆盖不同 TCG 线程模式

MTTCG一vCPU一线程，kick可针对线程；round-robin TCG可能让多个CPU共享执行线程，需要遍历CPU或唤醒共同线程。若公共调用者知道所有模式并分支，抽象会泄漏。提交 [`9cf342b491`](https://gitlab.com/qemu-project/qemu/-/commit/9cf342b491) 建立TCG thread-kick函数，提交说明说多线程直接使用，round-robin通过 `CPU_FOREACH`，也复用到user mode。

随后 [`61d996da50`](https://gitlab.com/qemu-project/qemu/-/commit/61d996da50) 内联 `cpu_exit()`，为跨accelerator可用做准备。这项改动进一步把“设置请求与唤醒哪些线程”收口到执行引擎。作者推断，这让未来修改退出内存序时有较少调用点，也避免round-robin漏掉某颗CPU。

kick可能通过条件变量、信号或平台事件实现，属于宿主机制。客户机不能依赖kick次数或时机，只能依赖中断和管理操作最终生效。实验记录应观察事件顺序，不把一次宿主signal当作一个RISC-V interrupt。

## work queue 与安全点

`run_on_cpu`/`async_run_on_cpu` 把需要在目标vCPU上下文执行的工作排队，例如TLB flush、寄存器操作或某些调试任务。发布者入队并kick，vCPU离开TB后在 `qemu_process_cpu_events()` 消费。同步版本还会等待完成，调用者必须避免持有目标工作需要的锁，否则死锁。

把工作放到vCPU线程，能避免并发读写其私有TLB和环境；代价是等待安全点。对于必须立刻停止的操作，kick缩短延迟，但不能任意在宿主指令中间修改env。精确客户机边界比微秒级抢占更重要。

work item数据的发布也依赖内存序和队列锁。vCPU看见exit_request后，应能看见已入队节点；处理完节点再通知等待者。只对exit_request使用原子，不代表队列本身无锁，二者各自承担协议一部分。

## TLB shootdown 的跨 hart 路径

客户机hart A修改共享页表，执行 `SFENCE.VMA`并通过IPI要求hart B也flush。QEMU先模拟客户机IPI送达，B运行内核handler后执行自己的fence；某些QEMU内部内存拓扑变化则直接使用all-cpus flush API。两者不要混淆：前者是客户机软件协议，后者是模拟器维护缓存。

内部 `tlb_flush_by_mmuidx_all_cpus_synced()` 向各CPU排工作并等待，保证返回后目标software TLB不再使用旧entry。异步版本只安排工作，调用者必须知道何时可以继续释放相关对象。大页和range无法精确时扩大flush，正确性优先。

MTTCG下页表写与fence的客户机内存序还要映射到宿主。若A的PTE写在宿主上晚于B的flush观察，B清表后重新walk仍可能读旧PTE。RISC-V guest fence、TCG barrier、IPI设备与work queue共同建立顺序，不能只验证数组被清空。

## TB invalidation 与 software TLB flush 不同

页表改变使虚拟到物理映射过期，需要flush software TLB；客户机写可执行物理页使已有宿主代码内容过期，需要invalidate TB。两者可能同时发生，但数据结构和范围不同。`fence.i`处理指令可见性，`sfence.vma`处理地址翻译，规范语义也不同。

TB invalidation要解除direct jump并等待正在执行的读者，page collection与RCU负责生命周期；TLB flush针对每vCPU fast/full/victim表。粗暴地全清二者可保功能，却让性能严重抖动，也掩盖调用者真正需求。

跨线程自修改代码测试应让hart A写代码，执行规定的fence与IPI协议，hart B重新执行。只在单hart写后立即跳转，无法覆盖MTTCG发布顺序；只改页表不改物理代码，又无法覆盖TB页面反向关系。

## 原子单步为何需要串行上下文

某些客户机原子操作在host缺少直接能力时，需要让一条指令在排除其他vCPU干扰的上下文执行。TCG可请求 `cpu_exec_step_atomic()`，临时进入exclusive/serial区，只生成或执行一条受控TB。这里的“atomic step”服务模拟器兑现客户机原子语义，不等于调试单步。

当前 `cpu_exec_step_atomic()` 同样建立 `sigsetjmp`，因为该指令仍可能fault或longjmp。执行前后要恢复并发状态，异常时也必须释放exclusive。提交 [`0ffd9742fb`](https://gitlab.com/qemu-project/qemu/-/commit/0ffd9742fb) 将该TCG专属声明移出公共 `exec/cpu-common.h`，上游动机是让TCG函数留在TCG头文件，目录边界再次跟随执行语义。

serial fallback保证正确，却会暂停并行vCPU，频繁触发会影响扩展性。后端原生原子支持和公共atomic helpers能减少fallback，实验要记录触发次数，不能只看最终共享计数正确。

## 客户机内存模型与 QEMU 内部内存序分开谈

RISC-V RVWMO规定客户机hart之间可观察的load/store顺序，`fence`和`aq/rl`加强它；QEMU C代码中的release/acquire保护 `exit_request`、interrupt request和队列。这两套内存序作用对象不同。前者属于被模拟程序语义，后者保证模拟器自身状态机。

它们会在边界相遇。例如客户机store PTE、fence、发IPI，设备模型将IPI变成QEMU interrupt request；执行线程acquire看到request后进入客户机handler。若QEMU内部发布协议错误，客户机规范正确的程序也可能失败。修复时要指出哪一层缺barrier，避免用最强全局锁模糊解决。

TCGCPUOps提供 `guest_default_memory_order` 一类信息，公共原子与barrier根据guest模型决定生成；2025 年提交 [`9c1f8062d4`](https://gitlab.com/qemu-project/qemu/-/commit/9c1f8062d4) 将 guest default order通过TCGCPUOps设置，不再在 `tb_gen_code()`直接依赖旧宏。这项历史说明客户机内存模型属于target对TCG的显式合同。

## AIA 虚拟中断让 pending 关系更复杂

AIA允许M与HS通过 `mvip/mvien`、`hvip/hvien` 等机制插入和过滤虚拟中断，IMSIC还提供每hart消息中断文件。pending可能来自真实设备、软件注入或虚拟位，目标逻辑要合成，再按delegation与priority选择。

2023 年提交 [`1697837ed9`](https://gitlab.com/qemu-project/qemu/-/commit/1697837ed9) 加入M-mode虚拟中断与过滤，[`40336d5b1d`](https://gitlab.com/qemu-project/qemu/-/commit/40336d5b1d) 加入HS-mode路径。提交说明强调规范不要求相应中断一定有真实硬件来源，软件可断言虚拟pending。随后相关修复说明，直接把 `mip`当所有pending真源已经不够。

2026 年拆分又把 `riscv_cpu_set_geilen` 与 AIA ireg回调移到 `riscv_imsic`，提交 [`beecb30958`](https://gitlab.com/qemu-project/qemu/-/commit/beecb30958) 和 [`6dd762b415`](https://gitlab.com/qemu-project/qemu/-/commit/6dd762b415) 的上游说明都是“只有 IMSIC调用，不应坐在TCG-only helper里”。作者从这段演进推断，虚拟中断语义跨CPU与设备，API位置应跟唯一所有者和accelerator需求一起决定。

## debug trigger 与执行退出

RISC-V trigger可按执行地址、load/store地址等条件进入debug。TCG translator可能在TB生成时插入检查，SoftMMU watchpoint路径也会触发。trigger配置变化后，旧TB若没有检查就要失效或让flags改变。GDB单步则限制TB并在每条指令后返回。

2026 年提交 [`3bcd11adae`](https://gitlab.com/qemu-project/qemu/-/commit/3bcd11adae) 将debug trigger数组动态分配，前置提交 [`820552a92e`](https://gitlab.com/qemu-project/qemu/-/commit/820552a92e) 先增加CPU unrealize callback，邮件系列 [`20260617131710.1855353-2-daniel.barboza@oss.qualcomm.com`](https://lore.kernel.org/qemu-devel/20260617131710.1855353-2-daniel.barboza@oss.qualcomm.com/) 展示资源生命周期如何为可配置trigger数量铺路。debug功能并非只多一个检查，它还改变CPU对象销毁和迁移状态。

`singlestep_enabled` 在当前版本更名为 `singlestep_flags`，提交 [`7e28b7c897`](https://gitlab.com/qemu-project/qemu/-/commit/7e28b7c897) 说明字段早已含多个flag。准确命名有助于执行路径不把非零值当简单布尔，从而丢掉具体step模式。

## icount、虚拟时间与确定性

`icount` 按客户机指令推进虚拟时间，TB入口检查预算，执行后扣减。timer interrupt因此与客户机进度关联，不直接随宿主wall clock漂移。为了不让一个大TB越过事件点，translator会限制指令数或插入退出。

MTTCG与严格确定性存在张力。多vCPU真实并发顺序受宿主调度影响，replay要记录或约束非确定事件；round-robin单线程更容易复现，吞吐较低。实验比较两种线程模式时，不能把事件顺序不同自动判为错误，要用RISC-V内存模型允许结果集合判断。

icount exit request有独立检查，当前 `cpu-exec.c` 将它与通用exit request并列。日志和trace会改变宿主时序，却不应改变按icount定义的客户机事件点。若测试依赖wall-clock timer，就不属于严格确定性验证。

## BQL 仍然在哪里重要

MTTCG没有消灭Big QEMU Lock。大量设备配置、machine runstate和管理控制面仍在BQL保护下，vCPU进入设备MMIO slow path时可能获取它。目标是让纯RAM和生成代码并行，把需要全局序列化的设备操作收拢，而不是无锁化全部QEMU。

依赖BQL的代码要明确调用上下文。vCPU持BQL等待另一个vCPU同步work，而对方处理work又需要BQL，会死锁；释放BQL后访问受保护设备字段，又会竞态。`qemu_process_cpu_events()`、等待条件和kick路径的锁顺序是审查重点。

提交 `ac6c8a390b` 的说明说旧exit_request“可能通过BQL被某种方式保护，但不清楚”，最终选择显式原子序。这个案例告诉我们，锁的传递性若无法在局部看懂，就不适合承载热路径协议。BQL应该保护有清晰范围的状态，不是并发不确定性的兜底说明。

## MTTCG bug 为什么难复现

竞态需要特定交错，日志、断点和单步会改变时序。一次运行正确没有证明，跑一万次失败也只给出现象。实验应构造能放大窗口的协议，例如两hart循环页表shootdown、共享LR/SC、IPI与WFI交替，并为每个事件记录单调序号和hart ID。

结果判断必须基于允许集合。RISC-V弱内存模型允许某些重排，缺少fence的litmus测试出现不同值可能完全合法。先用规范或验证工具确定预期，再检查TCG是否产生禁止结果。为了让测试稳定而添加超强fence，会把真正模型问题遮掉。

ThreadSanitizer能发现QEMU C数据竞争，却不理解guest memory model，也可能不适用于全部JIT路径。它是辅助证据；trace能证明事件先后，却可能错过未插点状态；源码审查解释协议，三者组合比单一工具可靠。

## 把 `cpu_exec()` 的两层循环画出来

外层循环先处理已经记录的exception，内层循环反复处理interrupt/request并执行TB。同步异常通过longjmp回到外层，普通TB exit留在内层找下一个块，管理条件满足时函数返回accelerator线程。这个结构让目标trap完成后可以继续执行新PC，也让内部请求不用伪造成客户机exception。

`cpu_handle_interrupt()` 名称容易误导，它不仅处理客户机hard interrupt，还检查debug、halt、exit TB和其他公共request bit。部分请求会清bit并继续，部分要求返回。随后目标 `cpu_exec_interrupt` 才把可接受的RISC-V pending变成trap。读代码要区分公共request dispatch和目标IRQ arbitration。

`last_tb` 参数帮助执行循环管理chaining。发生异步事件时清空或阻止新链，避免处理后继续沿旧假设；正常路径可把上一个出口连接当前TB。异常longjmp则统一重置局部链接状态，不依赖被越过栈帧清理。

循环中的原子load/store顺序是协议一部分。先清某request、再读exit_request，还是反过来，会影响并发发布是否丢失。当前注释明确说明清零与读取的顺序要求，修改“看起来重复”的原子操作前必须重建竞态时序。

## `exception_index` 是短生命周期消息

目标helper发现illegal、page fault等，将code放入 `exception_index`，附加地址放目标env字段，然后退出。执行循环消费后，目标trap函数将其写入CSR，再把index复位。debug、halt和内部标识也可能使用特殊值，但不会都进入RISC-V cause。

短生命周期意味着任何成功返回路径不应遗留旧值。若一次probe设置后没有退出，下一次普通TB return可能误处理；若trap完成后未清，恢复执行立即再次进入。提交 `67cf90efc3` 在resume前重置，正是补这种状态机边界。

附加字段要与index绑定。load fault设置badaddr，illegal设置opcode，guest fault设置guest physical address；下一种异常不使用某字段时应清或trap handler忽略。调试dump看到旧值不一定客户机可见，代码却不应依赖“该cause不会读取”作为永久保证。

作者建议把exception准备看成一次message construction：先填完整payload，最后发布index并longjmp。其他线程不直接消费这份CPU私有消息，执行线程在安全点提交。这个模型能避免先设置index、后面helper又可能失败导致半消息。

## 精确状态恢复依赖每条指令的元数据

生成代码可能把RISC-V PC保存在宿主寄存器，多个guest运算合并，直到TB出口才写 `env->pc`。page fault发生在第三条load时，`env->pc`或许仍是TB起点。`cpu_restore_state()`用宿主return PC定位TB，再查 `insn_start`表，调用目标restore hook把PC与附加translation state恢复到第三条。

host signal也走类似路径。直接RAM load触发宿主SIGSEGV，signal handler判断地址是否属于QEMU可处理的page protection或guest fault，取得ucontext PC，恢复后longjmp。若信号发生在helper C代码而非JIT区，处理方式不同，不能任意把host fault转guest fault。

优化器可删除纯指令，但保留下来的可能fault op必须仍关联正确insn metadata。将load跨 `insn_start`移动会破坏归因，TCG side effect规则限制这类重排。后端slow path保存的return address也要落在可查范围。

实验可在一条TB内放两个load，第一条成功，第二条fault，并在两者之间修改寄存器。trap handler检查PC和已提交第一条结果，验证恢复不是简单回到TB起点。再用单步比较，排除日志误标。

## 异常与中断同时到达时的优先顺序

同步异常由当前指令产生，通常先完成该指令的trap语义；异步中断在指令边界选择。若load page fault的同时timer pending，处理器应先报告同步fault还是中断，要按RISC-V规范和实现允许规则。QEMU的执行顺序由helper longjmp与下一轮interrupt检查共同形成。

多个pending中断也有优先级，不是最低bit或最高bit通用选择。M、S、VS delegation与AIA priority改变候选，`riscv_cpu_local_irq_pending()`集中计算。新增中断cause时，应更新priority、enable、delegation、trap vector和名称，不只拉一根CPU线。

NMI和debug可能高于普通maskable interrupt，有独立状态与返回指令。2026 年拆分提交 [`e26e53b4ab`](https://gitlab.com/qemu-project/qemu/-/commit/e26e53b4ab) 将 `riscv_cpu_set_nmi()` 移到TCG CPU文件，邮件 [`20260703180538.3346781-13-daniel.barboza@oss.qualcomm.com`](https://lore.kernel.org/qemu-devel/20260703180538.3346781-13-daniel.barboza@oss.qualcomm.com/) 说明Smrnmi和non-masked实现当前属于TCG。KVM若支持相同客户机能力，会走不同注入。

优先级实验必须在可控同一边界发布两个事件，多次重复确认。宿主线程先后发signal不是客户机优先级证据，最终 `xcause`顺序才是。

## ACLINT timer 的时间怎样变成中断

ACLINT MTIMER比较mtime与mtimecmp，达到条件后拉起每hart timer IRQ。mtime来源可能关联QEMU虚拟时钟，icount模式按guest进度推进，普通模式随虚拟时间。设备定时器回调通常运行在主循环/AioContext，不在vCPU线程，拉线后要发布pending并kick。

客户机写mtimecmp清或重排timer，设备取消旧宿主timer并设置新deadline。若回调与写并发，锁和timer framework保证不会在清除后又发布旧事件。CPU接受后，pending是否保持取决于比较条件，软件通常更新mtimecmp才去线。

暂停虚拟机时虚拟时钟可能停止，恢复后deadline重新计算。若用host wall clock验证trap延迟，会混入暂停和调度；icount实验更适合精确指令点，普通timer实验则记录虚拟clock。

提交 [`cb1b461838`](https://gitlab.com/qemu-project/qemu/-/commit/cb1b461838) 将 `riscv_cpu_set_rdtime_fn` 移到ACLINT，邮件 [`20260703180538.3346781-21-daniel.barboza@oss.qualcomm.com`](https://lore.kernel.org/qemu-devel/20260703180538.3346781-21-daniel.barboza@oss.qualcomm.com/) 的理由是只有ACLINT调用，无需留在TCG helper。timer读回连接CPU与设备，所有者审计把回调靠近唯一设备。

## IPI 从 hart A 到 hart B 的完整链

hart A向ACLINT MSWI或相应AIA接口写B的software interrupt位，设备模型在其AioContext更新line；CPU input callback更新B的pending表示与公共interrupt request，kick B线程。B离开TB，目标arbitration检查enable和priority，进入trap，软件handler清设备位。

若B在WFI睡眠，kick负责唤醒；若B正运行direct chain，exit/request检查负责返回；若B屏蔽software interrupt，可能醒来检查后继续或再次等待，pending仍保留。每个阶段有不同状态，丢任一边都会出现“偶发IPI不达”。

清pending与设备level要协调。handler先清CPU CSR镜像、设备线仍高，callback会重新置；先清设备再返回，pending应消失。测试应故意延迟设备清除，验证level行为，不把一次trap自动等同edge消费。

跨hart页表shootdown在IPI handler里执行fence，形成第二条协议。IPI到达只证明控制消息，B的software TLB何时清完要看handler完成。QEMU内部同步flush用于machine变化，不应代替guest OS的IPI/fence。

## WFI 的丢唤醒竞态

经典竞态是B检查“没有work”，准备睡；A在两步之间设置pending并kick；若B尚未进入wait，signal丢失，随后B睡死。正确wait协议在同一mutex/condition规则下再次检查谓词，或用事件计数确保先到kick也留下状态。pending/request本身是持久谓词，条件变量只是通知。

反向竞态是B被无关管理kick唤醒，检查没有可接受interrupt后再次睡，这完全正常。代码不能把每次wakeup都当guest中断，也不能清掉仍被屏蔽的pending。spurious wakeup必须允许。

pause请求与WFI并发时，B应先报告停止，不能因为 `has_work=false`继续睡而让管理命令卡住。等待条件综合stop、queued work和target work，目标 `has_work`只负责一部分。

实验让B在循环中快速WFI，A随机时点发IPI，跑大量轮次并给每轮序号。超时后记录pending、exit_request、halted与线程栈，能区分设备未置、kick丢、wait谓词错或目标屏蔽。

## host signal、条件变量与 kick 抽象

正在JIT里运行的vCPU需要被打断，平台可向thread发送signal，让宿主执行离开阻塞系统调用或尽快检查；正在条件变量睡眠的vCPU需要cond signal；round-robin线程还可能代表多CPU。TCG thread-kick把这些宿主细节封装在accelerator。

signal handler应尽量async-signal-safe，不在其中执行复杂QEMU逻辑。它只促使控制回到安全路径，详细request已在线程间状态中发布。若把TLB flush直接放signal handler，会碰锁、malloc和longjmp限制。

kick可以合并。十个请求在vCPU处理前只需一次唤醒，只要每个请求都有持久状态；因此不能用“收到几个signal”统计客户机事件。处理循环消费bit和queue，若仍有work会继续，不依赖kick计数。

发布者顺序通常是写payload、入队或置bit、release设置退出、kick。消费者醒来、acquire读请求、读取payload。这个模板贯穿interrupt、work和pause，具体锁仍不同。

## 同步 `run_on_cpu` 的死锁审查

调用线程排work到vCPU并等待完成，vCPU执行work前可能需要BQL。若调用线程持BQL等待，形成死锁。API有async、安全或在特定锁上下文使用的变体，调用点必须读注释，不按名字猜。

vCPU也可能正因另一个同步work等待调用线程持有的设备锁，产生跨锁环。审查时画“持有什么—等待谁—对方需要什么”三列，尤其migration、debug和memory topology更新会同时涉及多线程。

同步完成通知要发生在work全部状态可见之后，通常由mutex/cond建立happens-before。发布者返回后可以释放旧对象或读取结果；异步版本没有此保证。把sync改async优化延迟，需要重新证明对象生命周期。

TLB all-cpus synced使用这套机制，返回语义强；普通异步flush只保证已排队。书中实验记录API名称与等待点，不能把“函数已调用”当“所有hart已经完成”。

## BQL 与 RCU 各保护什么

BQL适合设备控制面和全局runstate，RCU适合读多写少的MemoryRegion FlatView、TB查找等对象生命周期。两者不是替代关系。vCPU可以在RCU read-side无BQL读取稳定视图，更新线程在transaction中建立新对象，grace period后释放旧对象。

持RCU read lock时不能进行会无限阻塞的操作，持BQL时也要避免等待需要BQL的线程。helper从JIT进入MMIO可能先退出RCU区再取BQL，路径上的注释与lock assertion说明前置条件。

TB invalidation使用page locks和RCU，不应为方便把整个流程搬回BQL；设备模型字段无RCU发布，也不能因vCPU无BQL就裸读。MTTCG正确性来自多种机制按对象分工。

作者推断，看到共享字段先问“读频率与生命周期”，再选BQL、局部mutex、atomic或RCU。把所有竞争升级为BQL能短期止错，长期会把多核执行重新串行。

## RVWMO litmus 怎样用于 TCG

两hart各写一个变量再读另一个，RVWMO允许的结果比顺序一致模型多。加入 `fence rw,rw` 或用 `aq/rl`原子后，允许集合缩小。TCG必须不产生规范禁止结果，也不必强制禁止所有规范允许结果。

litmus程序要避免C编译器重排，使用汇编或可靠原子接口；变量对齐和初值固定，每轮有同步起点但同步本身不能污染被测顺序。结果统计跑足够多轮，未观察到允许弱结果不证明TCG过强，只能说明这次调度没出现。

对同一程序比较single-thread与MTTCG，前者自然更序列化，后者更可能出现弱结果。正确结论是各自结果属于允许集合；性能与覆盖另外讨论。若出现禁止结果，再沿RISC-V前端barrier、TCG memory op和host RISC-V64 fence定位。

host与guest同为RISC-V也不能删除QEMU层barrier，因为helper、software TLB和C编译器在中间。实验 `out_asm` 可核对fence落地，最终oracle仍是guest观察。

## `cpu_exec_step_atomic()` 与全局排他

当guest原子无法用host原子直接实现，TCG从普通TB请求专门退出，进入exclusive context执行一条指令。其他vCPU到安全点停止，当前CPU生成限制为一条的TB，完成或fault后释放。这个过程把多条host操作包装成客户机不可分割效果。

exclusive请求本身也需kick其他vCPU并等待，不能由当前CPU单方面设bool。若另一CPU在WFI或MMIO，要确保它能响应；若持设备锁等待当前CPU，又可能死锁。fallback应尽量只包必要指令，不在排他区做长I/O。

异常longjmp必须走finally式释放。`cpu_exec_step_atomic()`内自己建立jump环境并在两条返回路径恢复，源码注释值得逐行阅读。新增helper在atomic step中再次请求exclusive，需防递归。

性能trace统计atomic step次数和停顿hart数。若常见RV64 A扩展操作频繁fallback，优先补host原子或优化alignment，不用扩大排他批次改变客户机interleaving。

## replay 记录的不是全部线程调度

确定性replay关注外部非确定输入、时钟和设备事件，无法简单记录每条host线程交错。TCG icount提供客户机指令进度，事件在指定count注入；多vCPU并发仍需序列化策略或额外记录。使用replay时应确认当前配置支持范围。

中断注入记录event与目标CPU，回放时在相同客户机进度发布，执行循环通过exit检查及时处理。TB边界变化不应改变总icount语义，translator和helper都要正确报告指令数。

调试日志、宿主负载和代码地址ASLR可以变化，客户机结果仍应重现。若实验直接比较host timestamp或thread ID，会把不属于replay承诺的细节当失败。

异常是确定的客户机执行结果，通常不需事件记录；MMIO读来自外部设备可能需要。分类再次回到“谁产生、客户机能否从状态推导”。

## 调试 stop 怎样取得一致寄存器

GDB发stop，管理线程设置debug/exit请求并kick所有vCPU。每个vCPU离开TB，在安全点恢复必要CPU state并报告stopped；只有全部停止后，GDB读取RISC-V寄存器才是一致快照。直接从运行中的 `env`读，可能看到一半宿主寄存器未写回。

单步设置flags后，已有TB可能不满足一指令边界，需要cflags或flush避免direct chain。执行一条后产生debug exit，而非客户机breakpoint trap，GDB看到的stop reason要正确。移除单步再恢复正常TB策略。

watchpoint从SoftMMU slow path退出，访问副作用提交时机按类型处理。硬件trigger模型又可能进入RISC-V debug语义，两者最终都接GDB，却不是同一实现。测试应分别覆盖软件break、trigger和watch。

多hart non-stop debug允许部分CPU运行，状态所有权更复杂。书中基础实验采用all-stop，若扩展non-stop必须注明读取哪颗hart、其他CPU是否可改变共享内存。

## 用 trace 建立跨线程因果链

每条关键事件记录CPU index、hart ID、host thread、单调序号和request bits：发布pending、set interrupt request、kick、TB exit、处理request、选择cause、进入trap。不同线程timestamp不能完全代表happens-before，序号由各自原子计数也需解释；锁/queue边界提供真正因果。

日志量要可控，按实验case或特定hart过滤。中断风暴下逐条printf改变调度，trace backend或ring buffer更合适。溢出要报告，缺事件不能默认“没有发生”。

因果图中把设备状态、公共调度状态、RISC-V CSR分三条泳道。IPI卡住时，最后一条事件会指向层级：设备未拉线、request未kick、vCPU未退出、目标判定屏蔽，或trap后软件未清。

作者推断，这种三泳道方法比一条调用栈更适合异步中断，因为调用跨线程断开。它是实验组织方法，不是QEMU正式trace规范。

## 为并发补丁准备审查证据

补丁说明先写失败交错，明确线程A/B每步读写与缺失happens-before，再给修复后的顺序。只写“add atomic to fix race”不足，reviewer无法判断memory order强度。若依赖BQL，列出持锁调用链；若改release/acquire，说明payload与发布变量。

测试应在修复前可高概率失败、修复后长期通过，并配源码或sanitizer证据。睡眠扩大窗口可用于复现，不应留在生产修复；全局barrier能止错，也要证明没有更小顺序。

性能影响单独评估。热TB每次多一个seq-cst load可能显著，release/acquire或仅slow path检查也许足够。正确性优先，QEMU上游仍会要求避免无依据最强原子。

邮件引用最终Message-ID并保留reviewer质疑。例如 `ac6c8a390b` 的价值在于提交说明公开承认旧BQL保护不清，选择显式配对；我们不能把它改写成“旧代码已被证明错误”这种超出证据的结论。

## 手工推导一次 VS load fault 的 trap

让VS-mode在PC `0x80200100` 执行一条load，VS页表有效，G-stage拒绝目标GPA。TCG load进入SoftMMU，`riscv_cpu_tlb_fill`记录原GVA、guest physical fault address和load guest-page cause，通过 `cpu_loop_exit`回 `cpu_exec()`。恢复逻辑把PC定到这条load，而非TB起点或下一条。

目标trap判定该cause是否由 `hedeleg`委托。若未委托，V切到0进入HS，`sepc`/hypervisor视图保存原PC，`scause`记录guest-page fault，`stval`与 `htval`按规范保存地址，status记录SPV/SPVP，PC取 `stvec`。若委托条件允许进入VS，则写VS bank并取 `vstvec`，字段集合不同。

整个过程中timer可能已pending，它不应覆盖同步load fault。trap handler修正G-stage页表、执行hfence并返回，原load重试，目的寄存器这次才更新。实验检查第一次fault前目的寄存器保持、第二次成功后变化，能验证副作用提交。

把每个字段与源码赋值行对应，再与RISC-V特权规范对照。若日志只显示“exception 21”，无法证明V状态、地址与PC；手工推导表应成为实验oracle。

## interrupt controller 的 reset 与迁移

CPU pending只是中断状态的一部分，PLIC/APLIC/IMSIC/ACLINT还保存enable、priority、claimed、pending file和timer compare。迁移若只保存CPU `mip`，目的端控制器状态不一致，会丢中断或重复注入。设备VMState与CPU状态在全机暂停点共同保存。

level IRQ迁移后，设备源仍高，控制器与CPU应恢复同样pending；edge/MSI已排队则要保存队列或位。迁移装载顺序不能让控制器在CPU尚未恢复enable时永久丢通知，通常连接线状态在load完成后重算。

reset同样跨设备。CPU清pending、控制器清状态、timer重设，外设line按reset值重新驱动。只调用CPU reset的单元测试不代表system reset正确。RISC-V `virt`实验可在pending未处理时触发reset，确认新固件不收到幽灵中断。

KVM irqchip路径的状态所有者不同，下一篇会展开；本章TCG事实不能直接外推。公共machine迁移格式仍要提供同样客户机可见结果，这也是加速器汇合点。

## pause、stop 与 resume 的状态机

管理线程请求pause，设置runstate与各CPU stop/exit条件，kick运行或halted线程，等待它们报告stopped。vCPU在安全点离开TB、处理events，不再推进guest；设备AioContext也按runstate停止虚拟时间或数据面。只有所有参与者到位，管理命令才返回。

resume清stop条件并广播线程，CPU重新检查queued work、interrupt和has_work。若WFI CPU没有可接受事件，它可以保持halted，但虚拟机整体已running。`running` 与“每颗CPU正在执行”不是同义。

请求在pause过程中叠加，例如migration、debug和shutdown，状态机要规定优先级。简单bool在并发清除时可能丢后来的stop，当前公共request bits和runstate分工。实验同时发timer与pause，客户机是否先处理timer可有边界，pause完成后绝不能继续计数。

读取寄存器、保存迁移和修改debug状态都依赖pause完成的happens-before。管理层提前读取 `env`会得到运行中快照，TCG host寄存器尚未同步。状态所有权由执行线程在stop确认时交回。

## 中断延迟怎样测才有意义

从设备设置pending到trap handler第一条指令，可拆为AioContext调度、request发布与kick、当前TB剩余、目标priority判定和trap提交。wall-clock总延迟受host调度，guest指令延迟可用icount，二者回答不同问题。

TB长度影响最坏检查点，direct chaining仍有退出观察；宿主线程被抢占可能远大于TB成本。报告分位数而非一次最小值，记录CPU绑定、host负载与timer来源。trace本身增加延迟，先用于分段，再用轻量时间戳测量。

MTTCG与single-thread比较时，round-robin调度周期会影响IPI，MTTCG有真实并发与kick开销。不能只说哪一个“更快”，应解释延迟来自哪段。正确性上，两者都要在规定条件最终接收。

中断风暴还要测吞吐和公平性。一个hart持续高优先级pending，不应让管理pause永远无法处理；执行循环在trap之间仍检查exit request。客户机软件若不清level IRQ导致反复trap，是guest行为，可由trace区分。

## 一份 MTTCG review 清单

先标线程：vCPU、main loop、iothread、migration或signal handler；再标每个共享对象的保护：BQL、局部锁、atomic、RCU或仅vCPU私有。没有保护且跨线程访问，就是需要解释的点，不一定立即是bug，可能由暂停协议保证。

对原子字段写出memory order与payload。release发布什么，acquire后读什么，relaxed为何足够；多个字段组成状态机时列允许转换。对cond wait写谓词与循环，证明先到kick不丢。对sync work写锁和等待图。

检查所有退出，包括normal TB、helper longjmp、host signal、atomic step fault、shutdown。每条都释放exclusive/RCU/锁并重置current CPU。只修正常return，压力下异常路径会挂死。

最后设计RISC-V guest oracle：RVWMO允许集合、trap字段、IPI计数、shootdown后mapping。host trace解释机制，不能代替guest结果。patch cover letter引用上游问题、复现和最终Message-ID，作者推断单列。

## 当前目录重构给出的边界信号

`77bdae789a` 把 `cpu_exec()` 声明移出公共头文件，`0ffd9742fb` 同样移动atomic step，`d45b9bc655` 搬RISC-V TCG文件。它们共同指向一件事：执行循环、翻译helper和软件trap实现属于TCG，公共CPU只保留accelerator共享生命周期与架构接口。

但 `riscv_cpu_has_work` 与部分IRQ helper留公共层，因为KVM相关设备也需要客户机级pending判断。目录没有按“中断/CPU”名词机械切，而按实现所有者与调用者拆。未来代码再移动，设计问题仍可用这两项判断。

作者由此推断，头文件可见性是架构约束。把私有声明从广泛包含的 `cpu-common.h` 移走，不只缩短编译依赖，也让其他accelerator难以误调TCG函数。事实是提交完成移动，约束效果是作者解释。

正式 `v11.1.0` 发布时，应重新检查这一系列后续是否继续迁移IRQ或trap代码。正文引用功能边界和固定hash，避免目录一次调整就让整章失效。

## 阅读复核：一次事件写三份时间线

以IPI为例，客户机时间线写A发送、B trap、handler清除；QEMU时间线写设备pending、request、kick、TB exit、target arbitration；宿主时间线写AioContext、vCPU线程、signal/cond与调度。三份时间线描述同一事件，却不能混用时间单位。

客户机正确性看trap和共享状态，QEMU协议看happens-before与安全点，宿主延迟看调度。host signal先到不等于guest interrupt先接受，trace timestamp相邻也不替代release/acquire。把证据放回对应时间线，许多“顺序异常”会自然澄清。

再为同步page fault、debug stop、pause各写一次，会发现它们都离开TB，但发布者、消费者和客户机可见性不同。执行循环统一出口，语义仍由独立状态携带。若新增路径只设置一个通用exit而没有原因，就无法落入任何完整时间线。

这项复核也约束实验手册：原始日志保留三类ID，正文中文解释因果，不能用一次wall-clock曲线替代trap字段与并发协议。

::: {.source-path}
主要入口：`accel/tcg/cpu-exec.c`、`accel/tcg/tcg-accel-ops-mttcg.c`、`system/cpus.c`、`include/hw/core/cpu.h`、`target/riscv/tcg/cpu_helper.c`、`target/riscv/tcg/op_helper.c`、`target/riscv/cpu.c`、`hw/intc/riscv_*` 与 `hw/timer/riscv_aclint.c`。历史重点是exit/interrupt原子访问、kick抽象、AIA pending和TCG-only边界。
:::

## 实验：注入并核对 RISC-V trap

::: {.hands-on}
实验名称：`inject-riscv-trap`。使用英文手册 [`inject-riscv-trap`](../experiments/part-02-tcg-execution-engine/chapter-11-exceptions-and-mttcg/inject-riscv-trap/README.md)。在RV64 TCG裸机测试中依次触发非法指令、load page fault、timer interrupt、software IPI和外部中断；再启用H扩展，构造委托到VS、trap到HS和guest-page fault。每个用例保存故障PC、cause、tval类CSR、trap前后priv/V状态与vector目标，并与规范预期表逐字段比较。
:::

实验要让同步异常与异步中断落在相邻指令附近，验证优先级和精确PC。timer测试使用可控mtime步进或icount，避免wall-clock偶然性；外部中断记录控制器pending与CPU interrupt request，说明设备线、调度提示和最终trap不是同一个状态。

## 实验：比较 TCG 线程模式

::: {.hands-on}
实验名称：`compare-tcg-thread-modes`。使用英文手册 [`compare-tcg-thread-modes`](../experiments/part-02-tcg-execution-engine/chapter-11-exceptions-and-mttcg/compare-tcg-thread-modes/README.md)。用两个RV64 hart运行共享内存、LR/SC、IPI、WFI和页表shootdown测试，分别选择single-thread round-robin与MTTCG。记录vCPU线程拓扑、kick、exit request、IPI到trap延迟、TLB flush完成点与允许的共享内存结果；压力循环至少覆盖一次hart休眠时收到IPI。
:::

比较结论不写成“MTTCG顺序更乱”。单线程提供一种序列化实现，MTTCG允许规范内并行交错；正确性标准是两者都不出现禁止结果，管理暂停与shootdown都完成。性能数据需关闭细粒度trace后另跑，并记录宿主CPU、线程绑定与QEMU commit。

## 用历史记录约束推断

本章的源码事实包括longjmp异常出口、目标trap hook、interrupt request与exit request、MTTCG vCPU线程和run-on-CPU work。上游提交直接说明release/acquire、helper收口、KVM/TCG中断边界与VS cause修复。作者提出“cpu_loop_exit是一种异常ABI”“kick把发布与唤醒绑定”，属于对这些事实的工程解释。

邮件审查还应查看patch v1到最终版是否改变锁和原子语义。最终commit正文可能只写简短理由，reviewer曾指出的丢唤醒、BQL锁序或user-mode影响，往往留在thread中。引用Message-ID时，要确认它对应最终系列，若后续提交重写方案，应在证据账本注明。

## 小结

TCG让宿主代码连续运行，异常和管理事件则通过TB exit与非局部跳转把控制权带回统一循环。RISC-V目标代码按delegation、特权与虚拟化状态提交trap，设备中断经过控制器pending、公共request和目标优先级三层才真正进入hart。

MTTCG把隐含串行假设变成显式协议。release/acquire保证请求与详细状态的可见性，kick唤醒执行线程，work queue在安全点修改vCPU私有状态，TLB与TB各自维护跨线程失效。到这里，TCG软件执行主线形成闭环；下一篇将用同样的状态所有权和退出观察点，对照RISC-V H扩展与KVM硬件虚拟化。
