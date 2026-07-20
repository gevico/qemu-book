# RISC-V 源码、建模与调试速查

本附录把全书反复使用的环境、命令和核对项放在一起。它只提供入口；每个选项能支持什么结论，仍要回到对应章节和固定版本源码。

## 工作树与构建目录

```text
workspace/
├── qemu/                 # upstream QEMU source
├── build-riscv-debug/    # debug TCG/system build
├── build-riscv-release/  # performance build
├── images/               # firmware, kernel, RTOS, rootfs
├── results/              # logs, traces, test environment
└── qemu-book/
    └── experiments/
```

QEMU 使用 out-of-tree build。源码研究固定到 `v11.1.0-rc0` 时，可以准备一份调试构建：

```console
$ mkdir build-riscv-debug
$ cd build-riscv-debug
$ ../qemu/configure \
    --target-list=riscv64-softmmu,riscv64-linux-user \
    --enable-debug --enable-trace-backends=log,simple
$ ninja
$ ./qemu-system-riscv64 --version
$ ./qemu-system-riscv64 -accel help
```

RISC-V KVM 需要 RISC-V 宿主 CPU、支持 H 扩展的硬件和内核 KVM。其他宿主可以编译、阅读和运行 TCG 实验，不能把 `-accel kvm` 失败解释成 QEMU 功能缺失。

## 四种常见调试入口

| 工具 | 更适合回答的问题 | 常用入口 |
| --- | --- | --- |
| HMP/QMP monitor | VM 是否运行、对象和地址图怎样装配、设备和 block backend 当前状态 | `-monitor stdio`、`-qmp unix:/tmp/qmp.sock,server=on,wait=off` |
| QEMU log | guest 执行了哪些指令、产生了什么 TCG op、异常或未实现访问在哪里出现 | `-d help`、`-d in_asm,op,op_opt,int,guest_errors`、`-D qemu.log` |
| trace event | 某类状态转移、MMIO、KVM exit 或 virtqueue 事件按什么顺序发生 | `-trace help`、`-trace enable=PATTERN,file=trace.log` |
| gdb stub | 在 guest 指令级暂停、读写寄存器和内存、设置断点与观察点 | `-S -gdb tcp:127.0.0.1:1234`；`-s` 的通配监听简写不作安全默认值 |

先根据问题选择工具。长时间打开 `-d cpu,exec` 或全部 trace event 会改变时序并制造大量无关输出；性能实验尤其要记录观测开销。

### Monitor

下面这些 HMP 命令适合建立系统坐标：

```text
(qemu) info status
(qemu) info registers
(qemu) info qtree
(qemu) info qom-tree
(qemu) info mtree -f
(qemu) info trace-events
(qemu) stop
(qemu) cont
(qemu) system_reset
```

HMP 面向人工操作。需要脚本化、长期兼容或并发管理时使用 QMP，并先发送 `qmp_capabilities`。Monitor 能改变 VM 状态，QMP/HMP socket 必须限制访问权限。

### Log 与地址过滤

```console
$ qemu-system-riscv64 ... \
    -d in_asm,op,op_opt,out_asm,int,guest_errors,unimp \
    -dfilter 0x80000000..0x80000fff \
    -D results/qemu.log
```

`in_asm`、`op`、`op_opt`、`out_asm`分别观察 guest 指令、优化前后 TCG IR 和 host code。`int`、`guest_errors`、`unimp`适合异常及设备 bring-up。实际可用项目以当前二进制的 `-d help` 为准。

### Trace event

```console
$ qemu-system-riscv64 -trace help > results/trace-events.txt
$ qemu-system-riscv64 ... \
    -trace enable=memory_region_ops_read \
    -trace enable=memory_region_ops_write \
    -trace file=results/mmio.trace
```

运行后还可以通过 HMP 调整事件：

```text
(qemu) trace-event riscv_* on
(qemu) trace-event virtio_* off
```

事件时间戳能够证明记录顺序，跨线程的因果关系仍要结合锁、线程模型和源码判断。

### GDB stub

裸机或 RTOS 常用启动方式：

```console
$ qemu-system-riscv64 \
    -M virt -cpu rv64 -m 256M -bios none \
    -kernel demo.elf -display none -serial stdio \
    -S -gdb tcp:127.0.0.1:1234
$ riscv64-unknown-elf-gdb demo.elf
(gdb) target remote 127.0.0.1:1234
(gdb) info registers
(gdb) x/10i $pc
(gdb) continue
```

Linux 内核调试应向 GDB 加载带符号的 `vmlinux`，QEMU 仍加载可启动的 `Image`。为了避免地址随机化干扰，可以在受控实验中加入 `nokaslr`，同时记录 OpenSBI、内核加载地址和启动 hart。SMP guest 还要用 `info threads` 确认当前 vCPU。

QEMU gdb stub 默认按当前地址翻译查看内存。需要查看 guest physical memory 时，可以使用：

```text
(gdb) maintenance packet qqemu.PhyMemMode
(gdb) maintenance packet Qqemu.PhyMemMode:1
```

TCG system emulation支持软件之外的大量断点和观察点；KVM、HVF 等路径的能力取决于 `AccelOpsClass` 对 guest debug hooks 的实现。GDB socket 没有认证和加密，自动化实验优先使用权限受控的 Unix socket。

## RISC-V 外设建模核对表

1. 从规范或真实软件行为列出 guest 可见寄存器、访问宽度、端序和错误语义；
2. 定义 `TypeInfo`、实例状态和 class 回调，区分配置属性与运行状态；
3. 用 `MemoryRegionOps` 实现 MMIO，拒绝未支持的宽度和越界访问；
4. 明确 IRQ 是电平还是脉冲，何时置位、何时由 guest 清除；
5. DMA 通过设备所属 `AddressSpace`，不要直接把 guest 地址当 host 指针；
6. 将 timer、bottom half、AioContext 和 BQL 的执行上下文写进设计；
7. 为 cold reset、warm reset、失败回滚和重复 reset 定义不变量；
8. 只把 guest 可观察且不能重建的状态放进 VMState，给版本和 subsection 留出依据；
9. 添加 trace event、qtest 和至少一个非法访问用例；
10. 最后才把设备接进 RISC-V machine，板级地址和 IRQ 不应藏进可复用设备。

## RISC-V 板卡建模核对表

1. 固定 CPU/hart 拓扑、内存图、复位入口和固件启动协议；
2. 列出中断控制器、timer、UART、存储、PCIe/IOMMU 等依赖顺序；
3. 决定哪些设备由 machine 固定创建，哪些允许用户通过 `-device` 添加；
4. 从同一份硬件事实生成 FDT 或 ACPI，逐项核对 address/size cell 与 IRQ 编码；
5. 处理 `-bios`、`-kernel`、initrd、U-Boot/OpenSBI 等启动组合；
6. 将未实现区域显式建模或记录，不用静默返回零掩盖固件错误；
7. 给 machine 属性定义组合约束、错误信息和默认值；
8. 用 qtest/functional test 覆盖复位、直接内核启动、固件启动和至少一种失败路径；
9. 如果承诺跨版本迁移，使用 versioned machine 与 compat properties 保存旧 guest ABI；
10. 在提交说明中区分真实硬件事实、QEMU 选择和暂未建模的功能。

## 一次实验至少记录什么

| 项目 | 需要保存的内容 |
| --- | --- |
| QEMU | tag、完整 commit、构建参数 |
| 宿主 | CPU、内核、发行版、编译器、可用 Accelerator |
| guest | machine、CPU model、固件、内核或 RTOS、rootfs |
| 命令 | 完整 QEMU、GDB、trace 或测试命令 |
| 预期 | 运行前写出的可证伪判断 |
| 结果 | stdout/stderr、日志、trace、退出码和时间戳 |
| 解释 | 观察直接支持什么，还不能支持什么 |

## 源码与历史检索

1. 从类型名查 `TypeInfo`、class init 和 instance init；
2. 从状态结构体查 owner、realize/reset/unrealize 与 VMState；
3. 从 `MemoryRegionOps`、IRQ 或 trace event 反查客户机交互入口；
4. 从 QAPI 命令查 schema、generated marshal 和实现函数；
5. 从错误字符串定位失败分支；
6. 用 `git log -S`、`git log -G`、`git blame` 和路径历史定位行为变化；
7. 根据完整 Message-ID 返回邮件线程，用 `range-diff` 比较 v1 到最终版本；
8. 核对当时 `MAINTAINERS`、commit trailer 和 review 内容，不追认角色；
9. 历史只保留解释当前边界的转折，其余材料写进研究账本。

## 章节完成标准

一章进入可评审状态前，应具备：

- 一个清楚的问题和能够闭合的结论范围；
- RISC-V 当前实现中的主要状态、调用或数据路径；
- 至少一条读者可以独立复核的实验或源码验证入口；
- 二到四道检查设计边界的随文思考题；
- 固定版本源码和必要的上游决策证据；
- 对性能、兼容、安全或维护代价的说明；
- 没有为展示资料数量而保留的历史段落。
