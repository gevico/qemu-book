# 从停住的 PC 到完整因果链：QEMU 调试方法

凌晨两点，RISC-V `virt` 的串口停在 OpenSBI 最后一行。QEMU 进程仍在，宿主 CPU 也有负载。这个现场只能说明字符终端没有新输出：hart 也许停在 `wfi`，也许反复进入 trap，UART 也许根本没有收到写访问，I/O 线程还可能独自忙碌。若第一步就打开全部日志，几百万行 TB 输出会盖住真正的状态变化，额外 I/O 还会改变原来的时序。

调试 QEMU 需要同时辨认三套程序：客户机里的固件、内核或应用，QEMU 的设备与执行引擎，以及宿主内核里的 KVM、线程和后端。Monitor、日志、trace event、gdbstub 和宿主调试器分别从不同位置观察它们。本章把这些工具排成一条逐步收窄的路径，并始终使用 `v11.1.0-rc0`（commit `eca2c16212ef9dcb0871de39bb9d1c2efebe76be`）的 RISC-V 实现作为源码锚点。

## 停住的 PC 只是调查起点

先把“系统卡住了”改写成可验证的问题。两次暂停之间，PC 有没有变化？若 PC 固定，它位于 `wfi`、异常入口、锁循环还是设备轮询？若 PC 在变化，变化发生在同一组地址，还是客户机仍在正常执行而输出路径断了？RISC-V 的 `sepc`、`scause`、`stval`、`sstatus` 与 `satp` 可以把异常进一步落到指令、原因、地址和翻译上下文。

接着寻找“谁拥有下一次进展”。CPU 等中断时，检查设备电平、中断控制器 pending/enable/threshold 和 CPU interrupt request；驱动轮询 MMIO 时，检查访问是否到达 [`MemoryRegionOps`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/include/system/memory.h)，以及回调更新了什么状态；后端未完成时，检查 AioContext、线程与文件描述符。每轮只验证一个预测。例如：“制造一次已知外部中断后，设备 pending 会先变化，随后 hart 离开 `wfi`。”pending 没变就回到设备，pending 已变而 PC 不动则继续查路由。

这条链条有一个很实用的结构：输入、内部状态、输出。客户机写 doorbell 是输入，队列索引或 pending 位是内部状态，DMA、IRQ 或字符输出是结果。三个位置各留一个观测点，通常比在每个函数入口加打印更容易找到第一个偏离。

## 先选观测面，再运行命令

不同工具回答的问题并不重合：

| 要回答的问题 | 首选入口 | 典型产物 | 主要限制 |
|---|---|---|---|
| VM 是否运行、对象怎样连接 | HMP / QMP | 状态快照、对象树、事件 | 查询本身经过调度与锁 |
| 某条翻译、异常或 MMU 分支是否发生 | `-d` / `-D` | 文本日志 | 输出量大，格式不适合作长期接口 |
| 一次设备状态怎样跨组件传播 | trace event | 带字段的事件序列 | 时间相邻不自动构成因果 |
| 客户机控制流和寄存器为何停在这里 | QEMU gdbstub | PC、寄存器、断点、内存 | 加速器决定可见能力 |
| QEMU 自身为何崩溃、死锁或耗时 | 宿主 GDB / profiler | C/Rust 栈、线程、样本 | 看不到完整客户机语义 |
| 客户机应用自身为何失败 | guest 内 GDB / gdbserver | 进程级符号与线程 | 看不到早期固件和设备模型内部 |

调查通常从低扰动快照开始，再升级到局部日志或 trace，最后才单步。发现 PC 停在驱动轮询时，gdbstub 能确认循环条件；需要知道轮询一秒发生多少次，trace 或采样更合适；需要知道 MMIO 返回值从哪个设备字段生成，再转到宿主源码和设备 trace。工具切换依据问题，而非个人习惯。

:::: {.quick-quiz}
串口不再输出时，为什么不能直接认定客户机 CPU 已经停止？

::: {.quick-answer}
串口只代表一条输出路径。hart 可能仍在执行，UART MMIO、字符后端或中断路径也可能单独失效。至少要交叉检查 PC/runstate、设备状态和宿主线程，才能判断进展停在哪个所有者手里。
:::
::::

## Monitor：先看机器仍处于什么状态

HMP 面向人在终端中探索。`info registers` 查看当前 CPU 状态，`info qom-tree` 看对象组成，`info mtree` 看地址空间，`stop`、`cont` 和 `system_reset` 控制运行边界。调查 RISC-V 地址翻译时，`gva2gpa` 可提供线索，但记录中仍要带 CPU、特权级、`satp`，涉及 H 扩展时还要带 `vsatp`、`hgatp` 和访问类型。同一个虚拟地址在不同 hart 和上下文里可以得到不同结果。

QMP 使用 QAPI schema 表达命令、返回、错误和异步事件，适合自动采集。客户端先完成 `qmp_capabilities` 协商，每个请求带唯一 `id`，再保存 `query-status`、`query-cpus-fast` 及相关事件的原始 JSON。若需要较一致的断面，先发 `stop` 并等到停止事件，再查询 CPU 与设备，结束后按原 runstate 恢复。多个查询仍不是硬件级原子快照，报告要写清这一点。

HMP 输出服务于阅读，列宽和措辞可能调整；自动化脚本应优先消费 QMP。QMP 并非绕过 QEMU 调度的窥视孔：请求先经过 dispatcher，再依据命令契约进入 BQL、coroutine 或目标子系统自己的同步边界；OOB 命令也不能被概括成与普通命令完全相同的加锁路径。高频事件不宜依赖密集轮询，可由 trace 承担数据流，QMP 只负责开启窗口、施加刺激和关闭窗口。

## `-d` 与 `-D`：观察执行引擎的分支

[`include/qemu/log.h`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/include/qemu/log.h) 定义了 `int`、`mmu`、`in_asm`、`op`、`exec`、`unimp`、`guest_errors`、`invalid_mem` 等日志类别。运行 `qemu-system-riscv64 -d help` 先读取当前二进制支持的名称，再按问题选择。异常或页表调查可以从 `-d int,mmu` 开始；TCG 翻译调查才考虑 `in_asm,op,op_opt`；设备非法访问更适合 `unimp,guest_errors,invalid_mem`。

`-D qemu.log` 把 QEMU 日志与串口分开。若已知故障 PC 或地址区间，可配合地址过滤缩小记录。不要把 `-d exec` 当作通用“详细模式”，它能在短时间内产生大量输出；热路径的格式化和文件写入也会改变线程竞争。关闭日志后仍能复现，才说明探针没有成为修复条件。

文本日志靠近分支，字段却没有稳定 schema。一次性调查可接受，长期统计应转成 trace event 或 QMP 字段。多线程代码若把一条消息拆成多次 `qemu_log()`，片段还可能交错；当前头文件提供 `qemu_log_trylock()`/`qemu_log_unlock()` 来保护需要连续构造的消息。半行错位首先是日志并发问题的线索，不能直接推出设备状态损坏。

## trace event：把状态转移串成数据链

QEMU 在各子目录的 `trace-events` 文件里声明事件，`tracetool` 在构建阶段生成 probe。当前 [`tracing.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/devel/tracing.rst) 建议记录状态变化、客户机操作和 correlator。一次 virtio 请求可以用队列号、descriptor 索引或对象标识连接“通知—取请求—完成—中断”；只记录“进入函数”很难区分请求代际。

先执行：

```console
$QEMU_SYSTEM_RISCV64 -trace help | rg 'riscv|memory_region|virtio|irq'
```

启动早期故障用 `-trace events=events.txt,file=trace.log` 预先开启；运行期故障可在 HMP 中用 `info trace-events` 和 `trace-event NAME on|off` 划定窗口。默认 `log` 后端方便阅读，`simple` 后端适合低开销离线解析，`ftrace` 可与宿主调度/KVM 事件对齐。原始数据要连同该构建的 `trace-events-all` 保存。

时间戳只说明记录器看到的顺序。跨线程判断因果还需要相同请求标识、源码调用关系或受控刺激。两颗 hart 并发写设备时，最好由客户机加入序列号和正确的 RISC-V `fence`，设备侧记录实际消费的索引；否则三行相邻事件可能来自三笔请求。trace 也会泄露 GPA、队列和客户机数据，提交或公开故障报告前应删减敏感字段。

## gdbstub：从寄存器走到第一条错误指令

`-s` 是 `-gdb tcp::1234` 的简写，空 host 通常会监听通配地址，不能直接作为安全的默认示例。`-S` 让客户机在复位后暂停；下面把 TCP 明确限制在 loopback：

```console
$QEMU_SYSTEM_RISCV64 -machine virt -cpu rv64 -accel tcg \
    -m 128M -bios none -kernel guest.elf -S \
    -gdb tcp:127.0.0.1:1234 -nographic
$ riscv64-unknown-elf-gdb guest.elf
(gdb) target remote localhost:1234
(gdb) break trap_entry
(gdb) continue
(gdb) info registers pc sp ra sepc scause stval
(gdb) x/8i $pc
(gdb) x/16gx 0x80000000
(gdb) stepi
```

[`target/riscv/gdbstub.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/gdbstub.c) 暴露 x0–x31 和 PC，并按 CPU 配置增加浮点、Vector 与 CSR 描述。寄存器集合会随 XLEN、扩展和 accelerator 变化。当前锚点把 RISC-V CSR、virtual mode 以及动态 CSR feature 放在 `CONFIG_TCG` 内；因此“能连接 KVM vCPU”和“能以 TCG 的方式读取全部 CSR”不能合成一句话。

| 调试能力 | RISC-V TCG | RISC-V KVM（固定基线） |
| --- | --- | --- |
| 软件断点 | 由 QEMU 管理客户机断点 | 支持通过改写客户机指令设置软件断点 |
| 硬件断点、watchpoint | 由软件执行路径提供较完整的观察能力 | 目标实现仍留有 TODO，相关请求返回不支持 |
| 单步 | 使用 TCG gdbstub 策略；`qqemu.sstep` 可调整 IRQ/timer mask | 依赖宿主 KVM single-step capability，不继承 TCG 的 IRQ/timer mask 语义 |
| 扩展寄存器 | QEMU 用户态拥有架构状态，CSR 描述较完整 | 可见集合取决于 one-reg、同步点和 target gdbstub 路径 |

断点会改变执行。软件断点可能改写客户机内存；“单步默认抑制部分 IRQ/timer”特指 TCG gdbstub 的默认策略，只有这条路径才使用 `qqemu.sstep` 调整。KVM 单步与断点能力必须按宿主 capability 单独探测。普通单 cluster SMP 通常把各 hart 暴露为同一 inferior 的线程，GDB 调度设置决定继续一条还是全部线程；multi-cluster 还会形成多个 inferior，需要显式连接并使用 `set schedule-multiple on` 才能共同恢复。检查物理内存可切换 `qqemu.PhyMemMode`，切回虚拟模式后再读同一地址，避免把 GPA 与 GVA 混在记录里。

## 三个 GDB 站在三条边界上

QEMU gdbstub 调试客户机 CPU。它适合固件、内核、trap、页表和驱动与硬件交界处；它不了解 Linux 进程的完整调度语义，也不能解释 QEMU C 函数为何死锁。

宿主侧 GDB 调试 QEMU 进程：

```console
$ gdb --pid "$(cat qemu.pid)"
(gdb) info threads
(gdb) thread apply all bt
(gdb) break memory_region_dispatch_write
```

这里看到的是 vCPU 线程、I/O 线程、QOM 对象和 C/Rust 回调。TCG 生成代码中的宿主 PC 需要额外映射；KVM 运行时 vCPU 可能停在 `ioctl(KVM_RUN)`，客户机最新寄存器仍由内核持有。宿主 GDB 也会停止整个 QEMU 进程，时间敏感问题可能随之改变。

guest 内 GDB 或 gdbserver 调试普通应用。它理解进程、共享库、线程和用户态符号，适合 Linux/RTOS 上已经建立调试通道的任务。QEMU 官方文档也建议：若问题只在客户机用户程序中，优先使用 guest 内调试；只有问题跨越系统调用、页表、驱动或设备时，再升到 gdbstub。三者可以配合，但每份断点记录都要注明它停住的是客户机 CPU、客户机进程还是 QEMU 宿主进程。

:::: {.quick-quiz}
Linux 客户机中的一个应用崩溃，为什么通常先选 guest gdbserver？

::: {.quick-answer}
guest gdbserver 能直接使用进程、线程和共享库语义。QEMU gdbstub 停在虚拟 CPU 层，内核抢占和地址空间切换会让用户态跟踪变得困难；只有故障跨进内核、MMU 或设备模型时，才需要把观察面下移。
:::
::::

## 四类 guest 的调试入口

bare metal 最适合建立第一套心智模型。保留带符号 ELF，使用 `-bios none -kernel guest.elf -S`，在 `_start`、trap vector 和 MMIO 写函数设断点。ELF 的链接地址要落在 `virt` RAM，GDB 读到的符号地址必须与 QEMU 装载位置一致。串口尚未初始化时，寄存器和内存仍可观察，所以它也是验证新设备模型的好入口。

RTOS 通常共享一个地址空间，却有调度器、tick 和多个任务。gdbstub可以看 hart 和异常，任务名、栈和就绪队列则依赖 RTOS 的 GDB awareness 或调试脚本。卡在 `wfi` 时同时检查 timer/IRQ trace；任务切换错误时保存调度器符号、当前任务指针和各任务栈。单步会改变 tick，重现竞态时应改用 trace 和逻辑序列号。

Linux 内核调试需要未剥离的 `vmlinux`，QEMU 仍装载 `Image` 或相应 ELF。地址随机化会使符号与运行地址错开，实验环境可用 `nokaslr`，并保留准确的内核配置。RISC-V 启动链依次经过复位代码、OpenSBI、内核入口与早期异常，断点应跟着当前阶段移动。内核已经启动后，`earlycon=sbi`、trace 与 `-d int,mmu` 可以分别验证输出、设备和异常。

一般 guest 包括发行版系统和任意可运行负载。应用问题留在 guest 内，驱动与设备交互问题用客户机日志加 QEMU trace，固件或内核早期问题再用 gdbstub。若只能拿到生产镜像，先复制为一次性镜像或 overlay，保存镜像哈希；调试器写内存、软件断点和故障注入都不应作用于唯一数据副本。

## TCG、KVM 与多 vCPU 改变可见性

TCG 中，RISC-V 架构状态主要位于 `CPURISCVState`，TB、SoftTLB 与 helper 都在 QEMU 进程里。gdbstub 可以提供大量软件实现的断点和 watchpoint，`-d in_asm,op` 也能看到翻译过程。KVM 中，大段客户机执行发生在硬件和宿主内核，用户态只有在退出或显式同步后取得状态；断点、watchpoint、CSR 和单步能力取决于 KVM 与 QEMU 的 accelerator 支持。

比较两条路径时，先比较端到端现象，再使用各自指标。TCG 关注 TB 生成、链接、SoftTLB 与 helper；KVM 关注 VM exit、设备模拟、irqchip 和宿主调度。KVM 下没有出现 TCG helper 调用，不能作为异常路径未执行的证据。一个故障只在某 accelerator 出现时，差异本身就是缩小所有权范围的线索。

多 vCPU 的快照也有取舍。停止整个 VM 可读取较一致的寄存器和设备状态，却截断并发；只停一颗 hart，其他 hart 和设备继续修改共享内存。调试记录必须注明暂停范围。需要重现确定性执行时，可评估 TCG 的 `icount`/record-replay，但它受设备、时间源和配置限制，也不能把原有的多线程竞态原样保存成通用录像。

:::: {.quick-quiz}
为什么 TCG 下读取到某个 CSR，不能推出 KVM 下同名 CSR 也具有相同可见性？

::: {.quick-answer}
TCG 的架构状态由 QEMU 用户态维护，KVM 的最新状态可能在宿主内核 vCPU。两条路径需要不同的同步和寄存器接口；当前 RISC-V 锚点还显式把一部分 CSR gdbstub 代码限定在 `CONFIG_TCG`。
:::
::::

## 证据要可复现，也要守住安全边界

每次调查保存 QEMU commit、构建摘要、完整命令、Machine/CPU/accelerator、固件/内核/DTB/镜像哈希、宿主内核和 vCPU 数。接着写故障判据、假设、预测顺序以及会推翻它的结果。原始 QMP JSON、trace、GDB 批处理输出和日志保持只读，分析脚本记录版本。修复以后关闭探针再跑一次，防止把观测扰动当成修复。

gdbstub 没有认证、授权和加密，连接者可以控制客户机；QEMU 文档还特别提醒 TCG 调试接口不应被当作安全边界。实验优先使用权限受控的 Unix socket。若使用 TCP，只绑定隔离网络或 loopback，绝不把 `-s` 暴露到不可信网络。QMP、HMP、trace 与 core dump 同样可能泄露客户机内存、GPA 和后端路径，采集目录要有访问控制和保留期限。

调试结束的判据也应明确：稳定刺激能够复现，最小观测面指出第一个错误状态转移，单一修正只改变该转移，关闭诊断后仍通过。若“加一行日志就不再出现”，当前只证明问题受时序影响；若补丁让系统启动，却没有找到第一个偏离，绕过症状的可能性仍在。

## 六个实验把工具连起来

### 实验一：用 gdbstub 调试最小 RISC-V 裸机程序

::: {.hands-on}
配套英文实验手册：[`debug-riscv-gdbstub`](../experiments/part-05-engineering-and-evolution/chapter-20-debugging-and-observability/debug-riscv-gdbstub/README.md)。

实验在 RISC-V `virt` 上运行一个带符号的最小循环。先执行静态检查；具备交叉 GCC、GDB 与 `qemu-system-riscv64` 时，构建 ELF，通过权限受控的 Unix gdb socket 启动 `-S`，在 `store_counter` 处停住，读取 PC、`s0` 和内存中的计数器，再单步一次 store。报告分别保存构建版本、GDB transcript 与 QEMU stderr。
:::

### 实验二：跨过 OpenSBI 与 Linux 内核入口

::: {.hands-on}
配套英文实验手册：[`debug-riscv-linux-kernel`](../experiments/part-05-engineering-and-evolution/chapter-20-debugging-and-observability/debug-riscv-linux-kernel/README.md)。

实验把可启动的 `Image`、带符号的 `vmlinux`，以及本次 boot path 实际使用的可选 OpenSBI/DTB 分别校验和记录。先在物理 kernel entry 检查 `a0` hart ID 和 `a1` DTB 指针，建立页表后再切到 `start_kernel`、`handle_exception` 等虚拟符号；KVM direct boot 另存一份 manifest，不能用 TCG/OpenSBI 的调用栈补齐缺失阶段。
:::

### 实验三：区分 RISC-V hart 与 RTOS task

::: {.hands-on}
配套英文实验手册：[`inspect-riscv-rtos-tasks`](../experiments/part-05-engineering-and-evolution/chapter-20-debugging-and-observability/inspect-riscv-rtos-tasks/README.md)。

先把 QEMU gdbstub 的 `info threads` 当作 hart 视图，再在调度函数断点读取当前 TCB、保存的栈指针与任务名。启用 FreeRTOS、Zephyr 或其他 RTOS awareness 以后，新增 task 行必须能够回到本次构建的 scheduler 结构；来自调试插件的任务视图不能改写成 QEMU 原生线程。
:::

### 实验四：在一般 Linux guest 内调试进程

::: {.hands-on}
配套英文实验手册：[`debug-riscv-linux-process`](../experiments/part-05-engineering-and-evolution/chapter-20-debugging-and-observability/debug-riscv-linux-process/README.md)。

实验让 guest `gdbserver` 只监听客户机 loopback，再经 SSH 隧道暴露到宿主 loopback。用匹配的 RISC-V ELF 和 sysroot 检查进程线程、共享库、信号与用户断点，同时分别记录 guest process、QEMU vCPU 和宿主 QEMU pthread 三种身份；只有证据跨进系统调用、驱动或设备时才切换调试层。
:::

### 实验五：用窄 trace 观察一次 reset

::: {.hands-on}
配套英文实验手册：[`use-qemu-tracing`](../experiments/part-05-engineering-and-evolution/chapter-20-debugging-and-observability/use-qemu-tracing/README.md)。

脚本先从当前二进制取得事件清单，只启用实际存在的 reset/runstate 事件，再通过 Monitor 执行一次 `system_reset`。阅读事件定义与调用点，确认哪些行表示刺激、内部状态和结果。若时间戳相邻但没有 correlator，结论保留为顺序观察。
:::

### 实验六：给 TCG 热点建立反证

::: {.hands-on}
配套英文实验手册：[`profile-tcg-workload`](../experiments/part-05-engineering-and-evolution/chapter-20-debugging-and-observability/profile-tcg-workload/README.md)。

固定 RISC-V 镜像、工作量和 TCG 配置，采样三轮宿主 profile。把翻译、生成代码、SoftTLB/helper、等待和未知样本分开，再只改变一个变量验证解释。火焰图提供样本分布；客户机校验值、方差、trace 计数和源码调用链共同决定结论强度。
:::

## 小结

QEMU 调试的难点在于同一现象横跨多套状态所有者。Monitor 给出机器和控制面，`-d` 靠近执行分支，trace event 记录带字段的状态转移，gdbstub观察客户机 CPU，guest gdb理解客户机进程，宿主 GDB 与 profiler解释 QEMU 进程。先问“下一次进展由谁产生”，再选择一个能推翻假设的观测点，材料会逐轮减少。

RISC-V 也把 accelerator 边界暴露得很清楚。TCG 和 KVM 可以运行同一台 `virt`，寄存器所有权、断点能力和性能指标却不同。把版本、加速器、暂停范围和时间域写进记录，停住的 PC 才会沿设备、IRQ、trap 和线程逐步连成可复查的因果链。
