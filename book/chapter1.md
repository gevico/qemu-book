# 让一段异构程序先跑起来

2003 年 3 月，QEMU 文档给出的第一个测试只有一条命令：`qemu tests/hello`。终端打印出 `Hello world`，实验就算通过。这里没有虚拟主板、BIOS、磁盘控制器和管理协议。Fabrice Bellard 当时写下的目标，是在 PowerPC、Arm 等非 x86 Linux 机器上运行 x86 Linux 进程；文档还特意点出 Wine，因为它承载着大量只能在 x86 上执行的程序。

这个起点值得停下来多看一会儿。今天我们从 `qemu-system-riscv64` 进入源码，很容易把完整机器当成理所当然，再按目录学习 CPU、内存和设备。早期代码提醒我们，QEMU 先解决的是“现有二进制带不走”这个问题。处理器指令集不同，Linux 用户态 ABI 也不同。一段程序既需要有人执行它的指令，还需要有人接住系统调用、信号、线程和 ELF 装载。QEMU 最初的边界，正是沿这两类责任画出来的。

## 二进制为什么不能跟着源码一起搬家

同一份 C 源码可以为 RISC-V 重新编译，已经发布的闭源程序、旧工具链和依赖特定 ABI 的测试镜像却未必具备这个条件。可执行文件里保存的是目标 ISA 指令，寄存器用法、函数调用、系统调用号、结构体布局和信号帧也服从目标 ABI。宿主 RISC-V CPU 无法直接执行 x86 指令；即便逐条解释了指令，程序发出的 x86 Linux 系统调用也不能原样交给宿主内核。

Bellard 在 2003 年 3 月 23 日提交的[第一版完整参考文档](https://gitlab.com/qemu-project/qemu/-/blob/386405f78661e0a4f82087196c7b084b8c612b48/qemu-doc.texi)把问题拆成两半。CPU 模拟器负责目标指令、寄存器和异常；Linux user-mode 层负责 ELF、系统调用、`ioctl`、信号与 `clone()`。目标程序调用 `write()` 时，QEMU 取出目标寄存器中的参数，按目标 ABI 解释它们，再调用宿主能力。宿主内核继续管理文件、进程和调度，QEMU 不需要在进程里再造一个 Linux 内核。

这种边界有直接收益。用户态程序不需要等待一台机器完成启动，文件和网络沿用宿主进程环境，目标线程还能映射到宿主线程并使用宿主调度器。它也带来明确限制：目标内核、设备驱动和裸机固件没有可依赖的系统调用层，无法在这里运行。早期文档甚至把“不支持启动操作系统”列为相对于 Bochs 的取舍，而不是一项尚未勾选的普通功能。

:::: {.quick-quiz}
目标 RISC-V 程序与宿主都运行 Linux，能否把目标 `ecall` 中的系统调用号和参数原样传给宿主内核？

::: {.quick-answer}
不能按这个假设实现。目标与宿主可能使用不同 ISA、位宽和 ABI，系统调用号、结构体布局、指针大小、端序及可用调用也可能不同。QEMU 要按目标 ABI 解码，再为宿主接口准备参数并转换结果。
:::
::::

## 第一项设计选择：翻译，还是逐条解释

跨 ISA 执行至少有一条朴素路线：取一条目标指令，解释一条，再进入下一轮。解释器容易搭起原型，重复执行循环时仍要重复取指、译码和分派。QEMU 选择动态翻译，把一段目标代码先转换为宿主代码，存进翻译缓存，后续命中时直接复用。

本书第二篇会专门追踪 dyngen 到 TCG 的演进。这里只需要抓住 2003 年已经出现的两个动作。提交 [`1017ebe9`](https://gitlab.com/qemu-project/qemu/-/commit/1017ebe9cb38ae034b0e7c6c449abe2c9b5284fb) 开始一次转换多条 x86 指令；第二天的 [`7d13299d`](https://gitlab.com/qemu-project/qemu/-/commit/7d13299d07a9c3c42277207ae7a691f0501a70b2) 加入 translation cache。两条提交信息都很短，不能替作者补写一套宏大动机；它们与同期文档放在一起，至少可以确认一条工程路线：把译码成本摊到多次执行上，同时让移植宿主后端的工作保持可控。

早期文档还比较了几个相邻项目。Bochs 提供完整 x86 系统，边界更宽；Valgrind 同样使用动态翻译，重点在内存调试且翻译器紧贴 x86 宿主；EM86 只面向 Alpha，并使用专有解释器。Bellard 的选择是在性能、可移植性与实现规模之间取一个可工作的点。dyngen 借助 GCC 预先编译微操作，运行时拼接宿主代码；文档把移植难度形容为接近动态链接器。这个方法后来暴露了对编译器输出形态的依赖，才会引出 TCG，但在项目起步阶段，它让一个人能快速覆盖多种宿主。

这里还有一项常被性能叙事盖住的设计：测试与实现几乎同时出现。2003 年 3 月 3 日的提交 [`ba1c6e37`](https://gitlab.com/qemu-project/qemu/-/commit/ba1c6e37fc5efc0f3d1e50d0760f9f4a1061187b) 建立测试基础，几小时后的 [`0ecfa993`](https://gitlab.com/qemu-project/qemu/-/commit/0ecfa9930c7615503ba629a61f7b94a0c3305af5) 让 `hello world` 跑通。参考文档随后解释 `test-i386` 如何在真实 CPU 与模拟 CPU 上产生输出并做差分。对于指令模拟器，代码“看起来符合手册”远远不够；真实执行结果必须能持续对照。

## 为什么用户态边界至今还保留着

完整系统模拟出现以后，Linux user-mode 没有被淘汰。它解决的任务更窄，启动成本也更低：交叉编译器刚生成一个 RISC-V ELF，可以先用 `qemu-riscv64` 检查指令与 ABI；发行版可以在另一种宿主架构上运行构建工具；CPU 前端开发者也能绕开固件和设备，尽快验证一条新指令。Bellard 在 [2005 年 USENIX 论文](https://www.usenix.org/conference/2005-usenix-annual-technical-conference/qemu-fast-and-portable-dynamic-translator)中已经把交叉编译器测试和 CPU 模拟器测试列为主要用途。

到了 `v11.1.0-rc0`，同一条边界仍能在 RISC-V 源码里看见。[`linux-user/main.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/linux-user/main.c) 解析目标程序并调用 loader，[`linux-user/elfload.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/linux-user/elfload.c) 处理目标 ELF，通用系统调用转换集中在 [`linux-user/syscall.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/linux-user/syscall.c)。RISC-V 的用户态 CPU 循环位于 [`linux-user/riscv/cpu_loop.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/linux-user/riscv/cpu_loop.c)：`RISCV_EXCP_U_ECALL` 到来时，它从 `a7` 取得系统调用号，从 `a0` 到 `a5` 取得参数，调用 `do_syscall()`，再把结果写回 `a0`。非法指令、断点和信号沿各自分支返回目标进程语义。

指令翻译则进入 [`target/riscv/tcg/translate.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/tcg/translate.c)。这个文件同时服务 RISC-V 用户态与系统模拟中的 TCG 路径，调用者给它的机器环境不同。复用点位于 CPU 指令语义，Linux 系统调用层和 `virt` 设备层各自留在边界之外。理解这一点以后，我们就不会因为两个二进制都使用 TCG，便把 `qemu-riscv64` 和 `qemu-system-riscv64` 当成两种启动参数。

## 进程地址空间也需要一层转换

用户态模拟借用宿主进程，并不等于目标指针可以直接解引用。目标 ELF 指定自己的虚拟地址，`mmap()` 又能请求固定范围、保护位与共享语义；宿主进程同时要给 QEMU 可执行代码、栈、库和翻译缓存留空间。目标程序传来一个 `0x400000`，QEMU 必须先确认这段目标地址已映射、长度没有溢出、访问方向合法，再取得宿主可用范围。

[`linux-user/mmap.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/linux-user/mmap.c)维护目标进程的映射操作，loader 又要按 ELF program header 建立代码、数据、解释器和栈。宿主与目标页大小不同，固定地址和 `MAP_GROWSDOWN` 等语义也需要适配。为了调用宿主 `read()` 或 `write()` 而暂时锁定一段目标内存时，调用结束还要按方向解锁；把目标指针永久保存在宿主后端，会绕过 unmap 与生命周期。

信号会反向穿过地址边界。[`linux-user/riscv/signal.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/linux-user/riscv/signal.c)按 RISC-V ABI 构造与恢复目标 signal frame，通用 [`linux-user/signal.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/linux-user/signal.c)协调宿主事件与目标信号队列。宿主收到 `SIGSEGV`，原因可能是目标程序的非法访存，也可能是 QEMU 自身缺陷；只有结合当前翻译区间、目标映射和异常路径分类，才能决定向目标进程投递信号还是终止模拟器。

这条路径把“复用宿主内核”的真实含义说清了。QEMU 借用宿主的资源管理和系统调用实现，同时在边界处维护目标 ABI。复用减少了要实现的内核功能，也把正确性压力集中到地址、结构体和异步事件转换上。

:::: {.quick-quiz}
`qemu-riscv64` 和目标程序位于同一个宿主进程地址空间，是否意味着目标地址 `0x1000` 就是 QEMU 可以读取的宿主地址 `0x1000`？

::: {.quick-answer}
没有这种保证。目标虚拟地址要经过 linux-user 的映射与保护检查，实际宿主地址可能带 guest base 或落在另一段保留范围。直接解引用目标数值还会绕过长度、权限和 unmap 生命周期。
:::
::::

## 一个成功输出背后有两次翻译

以 RISC-V 用户程序调用 `write(1, buf, len)` 为例。第一层翻译发生在 CPU 上：目标 RISC-V 指令经过前端和 TCG 生成宿主代码，直到 `ecall` 触发异常退出。第二层转换发生在 ABI 上：QEMU 识别目标系统调用号，验证客户机地址，把目标缓冲区映射或复制到宿主可访问范围，再调用宿主接口。返回值和错误码还要按目标 ABI 写回。

这两层不能互相代替。只做指令翻译，`ecall` 会落到没有接收者的边界；只转换系统调用，宿主 CPU 又无法走到那条 `ecall`。信号更能暴露这种组合：宿主信号先成为待处理事件，QEMU 要按 RISC-V ABI 在目标栈上构造 signal frame，目标 handler 返回时再模拟 `rt_sigreturn`。线程也要同时保存目标 CPU 状态与宿主调度关系。

用户态模拟因此并非“把系统调用号改一下”。文件路径、字节序、32/64 位宽度、`ioctl` 结构体、原子操作、信号屏蔽和自修改代码都会穿过边界。QEMU 选择逐步覆盖 Linux ABI，并接受一项停止条件：它承诺的是受支持目标上的 Linux 用户态语义，不承诺目标内核内部行为，也不生成任何虚拟 UART、PLIC 或 PCIe 总线。

## 如何证明一条用户态语义真的成立

单个 `hello` 只覆盖 ELF 入口、少量指令和一次输出。处理器前端还要面对整数、浮点、向量、原子、非对齐访问与异常；ABI 层要面对线程、信号、文件系统、网络和结构体转换。QEMU 当前把目标程序测试放在 [`tests/tcg/`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/tests/tcg)，其中许多用例会为目标架构交叉编译，再由对应 user-mode 或 system-mode 执行。测试名称中有 TCG，也不能由此推断它们都经过完整 Machine。

可靠的检查通常需要两个参照。指令测试可在真实 RISC-V CPU 与 QEMU 上运行同一程序，比较架构可见输出；系统调用测试还要固定目标 rootfs、宿主内核与 QEMU 版本，避免把 libc 或宿主策略差异归因到翻译器。遇到信号和线程问题，再记录目标 PC、宿主线程、信号来源和当前锁，单看最终退出码难以定位边界。

测试还要主动覆盖失败。目标程序传入越界指针，QEMU 应返回目标 ABI 规定的 `EFAULT` 或信号，宿主进程不应越界崩溃；目标调用宿主缺少的功能，QEMU 应给出明确未实现结果；一条非法指令应成为目标 `SIGILL`。失败路径正好检验 QEMU 是否把目标错误挡在模拟边界内。

:::: {.quick-quiz}
同一个 RISC-V 程序在 QEMU 与真实硬件上都打印相同文本，是否足以证明其中的原子与信号语义正确？

::: {.quick-answer}
只能证明本次输入走过的可见路径。原子操作需要并发与内存序用例，信号需要异步投递、嵌套和 frame 恢复测试。测试应针对要证明的语义设计反例，不能由一行输出扩展结论。
:::
::::

## 这条路线在哪里停止

用户态模拟适合进程级兼容与工具链验证，无法回答需要整机上下文的问题。程序若直接访问 MMIO，期待特权 CSR，修改页表或处理中断，宿主 Linux 进程接口没有相应语义。某些目标系统调用与宿主能力也不存在一一映射，QEMU 只能实现明确支持的组合。性能上，动态翻译和 ABI 转换仍有成本，目标程序频繁跨系统调用边界时尤其明显。

另一个边界是隔离。这里的“客户机”仍是宿主上的普通进程，QEMU 持有宿主文件描述符并替它发出系统调用。路径映射、资源限制和沙箱配置决定它能接触什么，不能仅凭 ISA 不同就推断安全隔离已经成立。需要运行不受信任的完整操作系统时，还要单独审查系统模拟、加速器和设备模型的攻击面。

这些限制没有削弱 2003 年那条路线。它们恰好说明设计从一个可闭环问题开始：先让目标进程执行，再观察需求是否真的越过进程边界。三个月后，Linux 内核启动把这个边界推开，QEMU 才开始承担一台机器的责任。

## 实验：用第一条系统指令看见边界

::: {.hands-on}
现有实验手册 [Trace RISC-V `virt` boot](../experiments/part-01-system-foundations/chapter-01-qemu-boundaries/trace-riscv-virt-boot/README.md) 会记录 `qemu-system-riscv64` 从 reset path 到 payload 的指令。运行前先增加一组用户态对照：选择一个静态 RISC-V `hello` ELF，用 `qemu-riscv64 -strace` 执行，保存 `write` 与 `exit_group` 等系统调用；随后按手册运行系统模拟，记录 reset PC 和第一条 payload 指令。

报告只回答三个问题。用户态命令是否出现 Machine、MROM 或 DTB；系统模拟的第一条指令是否直接等于 ELF 的 C 入口；两条路径各在什么位置向宿主请求 I/O。对照结果应能证明：用户态程序从 ELF 入口进入目标进程语义，系统模拟先经过机器定义的复位与启动交接。实验若缺少 `qemu-riscv64`，保留系统模拟结果并标记对照未完成，不用静态源码替代实际输出。
:::

## 小结

QEMU 的第一项工作，是把目标 CPU 语义和 Linux 用户态 ABI同时带到另一种宿主上。动态翻译解决“指令怎样执行”，系统调用与信号转换解决“进程怎样继续生活”。Fabrice Bellard 在 2003 年留下的文档、翻译缓存提交和差分测试，已经显出此后长期保留的工程取向：先划定可验证的边界，再用缓存、宿主复用和自动测试控制成本。

今天的 RISC-V user-mode 仍沿用这条分工。CPU 前端可以与系统模拟共享，进程环境继续由 `linux-user` 承接。下一章要处理那条无法在此处闭合的需求：当目标软件本身就是内核，它不再向宿主 Linux 请求服务，而是要求处理器、内存、中断和设备共同组成一台可启动的机器。
