# 从一个进程走向一台机器

用户态模拟跑通以后，有一个问题很快就越过了原来的边界：能不能把 Linux 内核也放进去？内核不会调用宿主 Linux 的 `open()` 或 `write()` 请求服务。它从复位地址取指，建立页表，配置中断控制器，读写串口寄存器，再通过驱动访问磁盘和网络。原先由宿主内核免费提供的进程环境，现在都要由模拟器交付。

2003 年 6 月 24 日，Fabrice Bellard 提交了一个 1383 行的 [`vl.c`](https://gitlab.com/qemu-project/qemu/-/commit/0824d6fc674084519c856c433887221be099c549)，提交标题写着“a new user mode linux project”。这句带玩笑意味的描述容易让人误读。文件里已经有 x86 Linux 启动参数、PIC、PIT、串口、物理 RAM、内核与 initrd 装载，目标是让内核处在一个由 QEMU 控制的虚拟地址空间里。一天后的 QEMU 0.4 发布邮件宣布它能启动 Linux 内核。QEMU 从进程兼容工具走向完整系统，工程责任也在这里发生了第一次大扩张。

## 内核拿走了哪些“免费服务”

用户程序运行时，宿主内核已经安排好虚拟地址、调度、系统调用、文件描述符与信号。目标内核运行时，这些接口不存在。它首先要求 CPU 提供特权级、异常、中断和地址转换；要求一段可发现、可读写的物理内存；要求定时器推动时间；还要有一种启动协议，把固件、内核和硬件描述连起来。

随后出现的是设备。串口输出一个字符，客户机驱动会访问约定地址或端口，设备更新寄存器并可能触发中断。网络数据到来时，宿主网卡不会自动变成目标机器的 NE2000、virtio-net 或其他控制器。QEMU 需要在客户机看到的设备协议与宿主后端之间转换，同时保持 DMA、端序、复位和错误语义。

这解释了完整系统模拟为何无法靠“给 user-mode 增加几个系统调用”完成。内核恰恰是系统调用的提供者，它依赖的接口位于更低一层。QEMU 必须把 CPU 执行放进一套机器状态中，让每次物理访问、中断和复位都有接收者。

:::: {.quick-quiz}
一份 RISC-V Linux ELF 已经能在 `qemu-riscv64` 下运行，为什么仍不能把同一架构的 Linux 内核直接交给这个命令？

::: {.quick-answer}
Linux user-mode 提供的是目标进程 ABI，缺少内核需要的特权状态、页表控制、物理地址空间、中断、定时器和设备。ISA 相同只能解决指令语义，不能补出整机启动环境。
:::
::::

## 0.4 版本交付了一个最小闭环

[QEMU 0.4 发布邮件](https://lists.gnu.org/archive/html/qemu-devel/2003-06/msg00123.html)里，Bellard 列出的设备只有串口和 NE2000，运行不需要宿主内核补丁和特殊权限。他还给出两个用途：更快地测试、调试内核，以及 virtual hosting。邮件说“unpatched Linux kernel”，脚注同时注明为了把内核重映射到用户地址要改两个字节。这处限定很重要，它告诉我们当时的完整系统仍在摸索宿主地址约束，不能用今天的能力倒写早期状态。

这个版本已经形成最小闭环：装入内核和 initrd，准备 x86 启动参数，给 CPU 一段 RAM，通过 PIC/PIT 提供中断与时间，经串口观察输出，经网络连接外界。每个组件都服务一个可验证目标。代码仍集中在 `vl.c`，全局变量很多，设备复用和生命周期还没有后来那样的框架。先把内核启动跑通，再从真实扩展压力中拆接口，是当时可观察到的演进顺序。

2005 年的 [USENIX 论文](https://www.usenix.org/conference/2005-usenix-annual-technical-conference/qemu-fast-and-portable-dynamic-translator)记录了边界扩展后的用途：在另一种宿主上运行未修改的 Windows 或 Linux；暂停、检查、保存和恢复虚拟机做调试；添加机器描述与设备来模拟嵌入式系统；继续用 user-mode 测交叉编译器。论文列出的子系统也从 CPU 增长到设备、宿主后端、Machine 描述、调试器和用户界面。用途并非后来给组件找的宣传语，它们分别提出了停机可观察、状态可保存、设备可组合和宿主可移植等工程要求。

## 今天的生态位是一组可组合边界

在 `v11.1.0-rc0` 的[系统模拟导言](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/system/introduction.rst)中，QEMU 把完整机器模型与执行加速器分开描述。机器模型提供 CPU、内存和设备，TCG 可以跨 ISA 执行，KVM、HVF、WHPX 等加速器在合适宿主上使用硬件能力。virtio 面向虚拟化负载，vhost-user 或多进程设备可以把数据面移出主进程，VFIO 又能把真实设备交给客户机。QMP 提供版本化管理接口，libvirt 等上层工具据此创建和控制虚拟机。

这些组合让 QEMU 同时出现在几类场景。体系结构开发者用 TCG 在 x86 或 Arm 宿主上启动 RISC-V 固件和内核；操作系统开发者用可暂停的机器重现启动与驱动问题；云平台把 QEMU 的机器模型、KVM 的 vCPU 执行和 virtio/vhost 的 I/O 组合起来；硬件团队用真实板模型验证固件，也会用 `virt` 这类合成平台减少厂商差异。

每种场景依赖的边界不同。跨 ISA 模拟依赖 CPU 语义完整度，云虚拟化关心退出、迁移与稳定机器类型，固件验证关心寄存器和复位细节。QEMU 的生态位由这些能力的交集形成，不能压成一句“模拟器”或“虚拟机软件”。后续各篇会逐项解释它们为何在同一工程里会合。

:::: {.quick-quiz}
KVM 已经能让 RISC-V 客户机指令在硬件上执行，为什么启动命令中仍要选择 QEMU Machine？

::: {.quick-answer}
KVM 提供 vCPU、内存槽和中断等内核机制，不负责为客户机拼出完整的 `virt` 平台。固件装载、设备树、UART、PCIe、virtio、后端和管理接口仍需用户态机器模型。硬件执行解决了 CPU 数据面的一部分。
:::
::::

## 回到 RISC-V：启动是一连串交接

当前 RISC-V `virt` 的进程入口位于 [`system/main.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/system/main.c)。短小的 `main()` 把主要工作交给 [`system/vl.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/system/vl.c) 中的 `qemu_init()`。命令行先形成配置，QEMU 选择 Machine 类型并创建 `MachineState`；早期后端建立、machine properties 应用以后，accelerator 才以这台 machine 为输入完成初始化，具体板级初始化仍在后面。到了 [`hw/riscv/virt.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/virt.c) 的 `virt_machine_init()`，这份配置才被装配成 hart、DRAM、MROM、中断控制器、串口、PCIe、virtio-mmio 与设备树。

“参数解析完成”和“机器已经存在”之间故意留有距离。`-m 2G` 要结合 Machine 与内存后端决定 RAM；`-smp` 要转换为 socket 与 hart 拓扑；`-device` 需要等目标总线和后端可用后再 realize。加速器也要在 CPU 能力冻结前参与校验。若每个选项在解析瞬间就修改全局硬件，组合检查、失败回滚和管理工具复用都会变得困难。

RISC-V 启动材料在 [`hw/riscv/boot.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/boot.c) 中分工。固件、内核、initrd 和 DTB 有各自的格式与放置规则；`riscv_setup_rom_reset_vec()` 在 MROM 写入一小段真实指令，准备 hartid、设备树地址和固件动态信息，再跳到下一阶段。第一条客户机指令通常属于 reset path，内核入口还在后面。

OpenSBI 处在另一次交接上。QEMU Machine 提供平台与启动数据，OpenSBI 建立 M-mode 环境并向 S-mode 软件提供 SBI，Linux 再按 RISC-V 启动约定接收 hartid 与 DTB。串口出现 OpenSBI banner，只能说明 CPU、部分启动代码和 UART 已经走通；内核入口、设备树和页表仍需分别检查。

## 四类启动材料不能合成一个“镜像”

固件、内核、initrd 和 DTB 都会被放进客户机地址空间，职责却不同。固件通常先获得 M-mode 控制权，决定怎样进入下一阶段；内核的 ELF 或 raw Image 包含可执行代码和入口；initrd 只是内核早期挂载的数据；DTB 描述本次平台。把四者统一称作“boot image”，调试时就会把装载成功误当成入口和协议都正确。

`hw/riscv/boot.c` 对应地拆出固件查找、内核装载、initrd 放置与 FDT 装载。ELF 有 program header 和 entry，装载器按段地址放置；raw Image 没有这类元数据，只能依平台约定选择基址。initrd 要落在 DRAM 内且不能与内核、FDT 重叠，DTB 还要留出对齐与最终大小。每项检查都应使用半开区间 `[start, end)`，只比较起点会漏掉尾部越界。

默认固件会让命令显得更短，也增加环境变量。`-bios default` 从 QEMU 安装数据中寻找适合 `virt` 的固件，`-bios /path/to/fw` 固定具体文件，`-bios none` 则要求其他启动材料能够承担入口。实验若研究 reset 到内核的交接，最好保存固件文件哈希；只记录 `default`，换一份安装目录就可能得到不同 OpenSBI。

MROM 也不等于普通 RAM。QEMU 在机器初始化与 reset 管理下准备其中的启动指令，客户机不能把它当可随意覆盖的 DRAM。pflash 又实现擦写和持久化规则，fw_cfg 通过设备协议把配置交给固件。它们都能传递启动数据，客户机可见接口和生命周期各不相同。第五章讨论地址空间时会再看到这组差别。

多 hart 还会让交接从一条线变成并行协议。每颗 hart 都有自己的 `mhartid`，设备树 CPU 节点、中断 context 与 hart array 编号必须一致；启动 hart 进入下一阶段时，其他 hart 可能在固件定义的等待路径中。单 hart 命中内核入口，只验证了启动 hart。SMP 故障还要检查次级 hart 的 reset PC、等待/唤醒方式和中断连线。

## 为什么启动路径分成这么多阶段

每个阶段掌握的信息不同。类型注册知道“有哪些 Machine 可以创建”，命令行知道用户请求，Machine 实例知道本次内存和 CPU 拓扑，板级代码知道地址与中断连接，装载器知道镜像格式，reset 框架知道设备初态，runstate 最后决定 vCPU 能否前进。阶段的价值在于把失败放到有能力解释和回滚的位置。

以一个非法 CPU 扩展组合为例。字符串本身可以成功解析，RISC-V CPU realize 才能结合扩展依赖与加速器能力拒绝；固件文件能打开，也可能因 ELF 段越过 DRAM 而在装载阶段失败；设备创建成功，后端缺失则应在设备 realize 返回结构化错误。若错误拖到第一条设备访问，用户只会看到黑屏或客户机异常，原始配置来源已经离得很远。

阶段也提供调试窗口。`-S` 让 Machine、地址空间和设备已经建立，同时保持 vCPU 停止。此时可以读取 MROM、导出 DTB、查看对象树和内存树，再决定从哪条指令开始。QEMU 能用于系统调试，靠的不只是 GDB stub；可暂停的生命周期和可查询的机器状态同样关键。

## 用失败位置反推是哪次交接断了

“没有串口输出”包含的范围太大。QEMU 若在 vCPU 运行前退出，先看选项、属性、realize 与镜像布局；reset PC 无法反汇编，问题落在 Machine 或启动 ROM；能到 OpenSBI、到不了内核入口，检查 next address、镜像 entry 与固件协议；已经进入内核、没有早期 console，再检查 `a0/a1`、DTB、页表和驱动。每个断点都把责任分到交接前后。

差分配置能进一步缩小范围。ELF 失败而 raw Image 成功，重点转向格式和 entry；单 hart 成功、多 hart 失败，重点转向 hartid、FDT 拓扑和固件唤醒；TCG 成功、RISC-V KVM 失败，重点检查 CPU 能力、直接内核启动和内核寄存器同步。一次只改变一个条件，比同时打开所有 trace 更容易保留因果。

日志也要注明观察层。OpenSBI banner 是客户机串口输出，QEMU `-d in_asm` 是 TCG 执行日志，GDB 读取的是停止点的 CPU 状态，`info mtree` 展示已提交地址图。四份材料时间和含义不同。把它们按 reset、firmware entry、kernel entry 和首个设备访问几个因果点排列，比强行对齐宿主时间戳可靠。

自动化测试也应围绕交接写断言。reset vector 可以静态检查生成的指令和数据布局，再用最小固件验证 hartid、FDT 与跳转目标；装载器要覆盖 ELF entry、raw fallback、过大 initrd 和范围重叠；系统测试最后启动 Linux，验证这些局部契约能够组合。只保留“Linux 打印登录提示”会让错误范围过宽，重构失败时难以定位。

失败实验本身应该留下。保存 QEMU、OpenSBI 与内核哈希、完整命令、三个入口、寄存器和 DTB 地址，下一次上游提交修改 boot helper 后就能逐项比较。用后来成功的一次输出覆盖早期失败，会丢掉最能说明阶段边界的证据。

:::: {.quick-quiz}
`-kernel` 指定的 ELF 已成功装入 DRAM，能否据此确认客户机将从 ELF entry 执行？

::: {.quick-answer}
还要检查 Machine 的 reset vector、固件入口和下一阶段协议。RISC-V `virt` 常先执行 MROM 与 OpenSBI，再跳到内核 entry。装载范围正确只完成了数据放置，执行交接仍需验证 PC、特权级及参数寄存器。
:::
::::

## 工程代价和停止边界

完整系统模拟扩大了可运行软件范围，也把维护成本带到所有客户机可观察的地方。一个设备寄存器写错，会破坏驱动；一个默认地址变化，会影响固件和 DTB；一项状态漏进迁移流，会让恢复后的机器偏离源端；一次不受控回调，还可能让恶意客户机触发宿主进程漏洞。功能数量增长时，测试矩阵会同时跨 Machine、CPU、加速器、设备和宿主。

QEMU 也没有试图在一个进程里重新实现所有宿主能力。块、网络和字符后端继续复用宿主接口；KVM 接管适合由硬件执行的 vCPU；vhost 与 VFIO让数据面进一步下沉。QEMU 保留配置、机器语义、状态协调和管理边界，再通过接口连接各后端。每次下沉都要重新回答迁移、错误恢复与状态所有者，性能收益不能免除这些契约。

本章到这里停止在“完整机器为什么出现”。各设备为何有多种模型、TCG 如何翻译、KVM 如何进入内核，分别留给后文。现在更迫切的问题是：QEMU 说自己创建了一台 RISC-V `virt` 机器时，究竟向固件和操作系统承诺了什么。

## 实验：停在机器准备完毕的那一刻

::: {.hands-on}
按照 [Stop at reset vector](../experiments/part-01-system-foundations/chapter-02-startup-path/stop-at-reset-vector/README.md) 启动 `qemu-system-riscv64 -machine virt -S -gdb tcp:127.0.0.1:1234`，保存 QEMU 版本、完整命令、初始 PC、`a0`、`a1`、`a2` 和 reset vector 附近反汇编。再用 [Inspect CLI to machine](../experiments/part-01-system-foundations/chapter-02-startup-path/inspect-cli-to-machine/README.md) 选择 `-machine`、`-cpu`、`-smp`、`-m` 与 `-kernel` 五项，分别记录解析位置、最终消费者和可能失败的阶段。

报告应画两条短线。一条是配置线：字符串到 Machine/CPU 属性，再到 realize；另一条是执行线：reset PC 到固件入口，再到内核入口。两条线在启动代码中相交，却回答不同问题。若镜像或交叉 GDB 不可用，仍可完成源码配置线；执行线必须标为未验证，不能用预期地址补齐。
:::

## 小结

完整系统的出现，源于目标内核要求一组比进程 ABI 更低的接口。QEMU 因此接管特权 CPU、物理内存、设备、中断、启动与生命周期，并继续把宿主 I/O、硬件加速和管理工具接在边界外侧。2003 年的最小 `vl.c` 先让 Linux 内核闭环，今天的 RISC-V `virt` 则把同样的责任拆进 Machine、设备、对象和后端框架。

读启动代码时，最有效的问题是“下一阶段开始前，当前阶段已经承诺什么”。当配置、装载、reset 和执行交接分别有证据，黑屏就能落到某一次承诺前后。下一章会把这套方法用于 Machine 本身：客户机看到的地址、设备树、复位行为和默认设备，怎样共同构成一份需要长期维护的平台契约。
