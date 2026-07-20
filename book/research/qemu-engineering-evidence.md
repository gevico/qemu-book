# 第五篇工程证据台账

研究锚点：QEMU `v11.1.0-rc0`，commit
`eca2c16212ef9dcb0871de39bb9d1c2efebe76be`。复查日期：2026-07-19。

台账中的“事实”只覆盖固定锚点或指定提交；“上游陈述”转述 commit、
cover letter、review 或项目文档；“作者推断”必须保留可替代解释。

| 章节 | Claim | Evidence | Role / provenance | Reasoning boundary | Status |
|---|---|---|---|---|---|
| 20 | `-s` 等价于 TCP 1234 的 gdbstub，`-S` 暂停客户机；TCG system emulation 的断点/watchpoint 能力与其他 accelerator 不同 | [`docs/system/gdb.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/system/gdb.rst) | QEMU 当前文档；源码事实/上游说明 | 文档不证明某个 RISC-V KVM 宿主支持全部 CSR、breakpoint 或 watchpoint | verified |
| 20 | RISC-V GPR/PC 由 RISC-V target callback 暴露；CSR、virtual 与动态 CSR feature 在锚点中受 `CONFIG_TCG` 限制 | [`target/riscv/gdbstub.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/gdbstub.c) | 固定锚点源码 | 只能描述显式 QEMU 路径；KVM UAPI/内核调试能力需另查 | verified |
| 20 | RISC-V KVM 支持软件断点；硬件断点/watchpoint 路径仍为 TODO 并返回不支持；single-step 取决于宿主 KVM capability | [`target/riscv/kvm/kvm-cpu.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/kvm/kvm-cpu.c) 的 guest debug callbacks | 固定锚点源码 | 不能把 TCG 的 `qqemu.sstep` IRQ/timer mask 或 CSR 可见性推广到 KVM | verified |
| 20 | `-d` 是分类日志掩码，trace event 是生成的带字段观测点，HMP 可动态控制 trace | [`include/qemu/log.h`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/include/qemu/log.h), [`util/log.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/util/log.c), [`docs/devel/tracing.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/devel/tracing.rst) | 固定锚点源码与文档 | 类别帮助文本不只在头文件；时间戳顺序不能单独证明跨线程因果，日志/trace 均有观测成本 | verified |
| 20 | gdb socket 无认证、授权或加密，连接者可以控制客户机 | [`docs/system/gdb.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/system/gdb.rst) security section | QEMU 上游安全说明 | 书中建议 Unix socket 是部署建议，不能被写成 gdbstub 自带认证 | verified |
| 20 | 裸机、Linux内核、RTOS与Linux进程需要不同的符号、停止层和调试器语义；实验入口分别保存artifact hash、accelerator与不可见状态 | [`debug-riscv-gdbstub`](../../experiments/part-05-engineering-and-evolution/chapter-20-debugging-and-observability/debug-riscv-gdbstub/README.md)、[`debug-riscv-linux-kernel`](../../experiments/part-05-engineering-and-evolution/chapter-20-debugging-and-observability/debug-riscv-linux-kernel/README.md)、[`inspect-riscv-rtos-tasks`](../../experiments/part-05-engineering-and-evolution/chapter-20-debugging-and-observability/inspect-riscv-rtos-tasks/README.md)、[`debug-riscv-linux-process`](../../experiments/part-05-engineering-and-evolution/chapter-20-debugging-and-observability/debug-riscv-linux-process/README.md) | 书内RISC-V实验合同；static-check与live运行分层 | 静态fixture通过不能冒充guest已运行；TCG结果不能证明KVM断点/CSR能力，RTOS helper任务不能冒充QEMU hart | static verified; live depends on artifacts/host |
| 21 | K230 qtest 覆盖寄存器、restart、STAT/EOI 寄存器行为等；没有直接探测 IRQ pin，且 `test_reset_mode()` 未对 reset 事件或结果作断言 | [`tests/qtest/k230-wdt-test.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/tests/qtest/k230-wdt-test.c) | 固定锚点测试源码 | “未直接断言”不等于 reset 实现一定错误，也不排除其他测试间接覆盖 | verified |
| 21 | `k230_wdt_ops` 只在 `.impl` 指定 4 字节回调粒度，没有用 `.valid` 拒绝较窄客户机事务；reset 未显式降 IRQ，VMState 无专用 post-load 重驱 | [`hw/watchdog/k230_wdt.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/watchdog/k230_wdt.c), [`include/system/memory.h`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/include/system/memory.h) | 固定锚点源码 | `.impl` 不能推出 8/16 位访问无效；PLIC 也保存 pending，故 reset/迁移输出是否连续必须用活动状态实验验证，不能直接判定 bug | verified source; runtime open |
| 21 | K230 functional test 覆盖 direct boot 和 U-Boot 两条路径，外部资产固定到仓库 commit 并校验 SHA-256 | [`tests/functional/riscv64/test_k230.py`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/tests/functional/riscv64/test_k230.py) | 固定锚点测试源码 | 两条启动成功不证明全部设备、迁移和非法输入正确 | verified |
| 21 | VMState 显式描述字段、版本、存在条件和 hook；RISC-V CPU 又按 PMP/H/Vector/KVM timer/debug 拆 section | [`include/migration/vmstate.h`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/include/migration/vmstate.h), [`target/riscv/machine.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/target/riscv/machine.c) | 固定锚点源码 | 字段存在仍需检查权威状态同步、恢复顺序和行为测试 | verified |
| 21 | 固定锚点的 RISC-V `virt` 未注册常见的 `virt-X.Y` Machine 系列 | [`hw/riscv/virt.c`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/hw/riscv/virt.c) | 固定锚点源码，检索 `MACHINE_TYPE_NAME` 与 compat 定义 | 仅限 rc0；不能推断未来不会增加版本化 Machine | verified |
| 22 | K230 从 v1 到 v8 处理 CPU 扩展、PLIC/CLINT、reset vector、UART、hart、direct boot、WDT IRQ 与 Machine interface | [K230 v8 cover letter](https://patchew.org/QEMU/cover.1781246408.git.chao.liu%40processmission.com/) | Chao Liu 的逐版 changelog；上游陈述 | changelog 不自动标明每项意见由哪位 reviewer 提出；人物归因需目标回复 | verified |
| 22 | v8 被 Alistair Francis 应用到 `riscv-to-apply.next`；最终板卡提交由 Chao Liu authored、Alistair committed | [v8 thread](https://patchew.org/QEMU/cover.1781246408.git.chao.liu%40processmission.com/), [`6cf0d08c`](https://gitlab.com/qemu-project/qemu/-/commit/6cf0d08c3953ee447cb215edc3a384834cbe48db) | 维护分支回复与最终 Git metadata | Patchew 对当前 master 的 apply 结果不代表当时维护分支状态 | verified |
| 22 | 最终 commit 包含 Peng Jiang `Tested-by`、Alistair Francis `Acked-by`、Nutty Liu `Reviewed-by` | [`6cf0d08c`](https://gitlab.com/qemu-project/qemu/-/commit/6cf0d08c3953ee447cb215edc3a384834cbe48db) | 合入 commit trailers | trailers 有流程语义，不证明书中全部动机陈述 | verified |
| 22 | rc0 中 Chao Liu 是 K230 Machines maintainer，也是 RISC-V TCG CPUs reviewer | [`MAINTAINERS`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/MAINTAINERS) | 固定锚点社会/责任边界 | 当前身份不能倒推旧线程中的意见 | verified |
| 22 | QEMU 拒绝包含或派生自 AI 生成内容的贡献；研究 API/算法、静态分析和调试在输出不进入贡献时不受该禁令约束 | [`docs/devel/code-provenance.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/devel/code-provenance.rst) | QEMU 当前项目政策 | 政策可能演进；任何例外仍须查当时上游文档与讨论 | verified |
| 23 | Rust feature 默认 disabled，只用于 system emulator；最低 rustc 为 1.83 | [`meson_options.txt`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/meson_options.txt), [`rust/meson.build`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/rust/meson.build), [`rust/Cargo.toml`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/rust/Cargo.toml) | 固定锚点构建源码 | 默认关闭不等于每个 Rust 模块都不成熟 | verified |
| 23 | qom/system::memory/hwcore/bql/vmstate 多项模块标 stable，migration::migratable 与 util::log 标 proof of concept | [`docs/devel/rust.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/devel/rust.rst) status table | QEMU 当前文档 | 文档明确说 API stability 不是永久承诺；应逐模块表述 | verified |
| 23 | rc0 workspace 的设备成员是 PL011 与 HPET；未发现 `rust/hw/riscv` 上游设备 | [`rust/Cargo.toml`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/rust/Cargo.toml), [`rust/hw/`](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/rust/hw) | 固定锚点源码与目录检索 | 负面结论仅限固定锚点显式目录；教学 `riscv-bookdev` 是 tree-out 设计草图 | verified |
| 23 | Linux 2021 RFC 提出 Rust 支持；v6.1 合入最小基础设施；社区在 2025 Maintainers Summit 判断实验阶段结束，并于 2026 由主线提交落实文档状态 | [2021 RFC](https://lore.kernel.org/lkml/20210414184604.23473-1-ojeda@kernel.org/), [v6.1 merge `8aebac82`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=8aebac82933ff1a7c8eede18cab11e1115e2062b), [`9fa7153c`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=9fa7153c31a3e5fe578b83d23bc9f185fde115da) | Miguel Ojeda RFC/commit；Kees Cook pull summary；Linus Torvalds merge | 用于比较渐进引入方法，不用于宣称 QEMU 与 Linux 成熟度相同 | verified |

## 复查命令

```console
git -C "$QEMU_SRC" cat-file -e COMMIT^{commit}
git -C "$QEMU_SRC" merge-base --is-ancestor COMMIT \
    eca2c16212ef9dcb0871de39bb9d1c2efebe76be
git -C "$QEMU_SRC" ls-tree -r --name-only \
    eca2c16212ef9dcb0871de39bb9d1c2efebe76be -- PATH
```

网页可访问只验证入口存在。人物动机仍要读取完整线程，实验观察仍要记录
QEMU commit、构建、RISC-V Machine/CPU、accelerator 和输入哈希。
