# RISC-V 设备、板卡与 I/O 建模证据账本

核验日期：2026-07-19。

当前实现基线：QEMU `v11.1.0-rc0`，commit [`eca2c16212ef9dcb0871de39bb9d1c2efebe76be`](https://gitlab.com/qemu-project/qemu/-/commit/eca2c16212ef9dcb0871de39bb9d1c2efebe76be)。本账本服务第 17–19 章；正文只保留能解释现行设计的因果，路径、角色和开放问题留在这里。

状态定义：

- **已验证**：固定源码、项目文档、commit、patch 版本或实验手册直接支持；
- **综合判断**：多条已验证事实共同支持，原始材料没有逐字给出该句；
- **开放**：固定基线没有形成完整证明，需补源码、协议或运行证据。

## 基线与角色口径

| ID | Claim | Primary evidence | Role | Reasoning boundary | Status |
| --- | --- | --- | --- | --- | --- |
| MODEL-BASE-001 | `eca2c162` 是 `v11.1.0-rc0` 指向的 commit，K230 初始提交 `6cf0d08c` 是其祖先。 | 本地完整历史执行 `git rev-parse 'v11.1.0-rc0^{commit}'` 与 `git merge-base --is-ancestor 6cf0d08c... eca2c162...`；[rc0 commit](https://gitlab.com/qemu-project/qemu/-/commit/eca2c16212ef9dcb0871de39bb9d1c2efebe76be)。 | annotated tag 要显式 peel 到 commit；release commit 只提供版本锚点。 | `v11.1.0` 正式版截至核验日尚未发布，不能把 rc0 描述成正式版。 | 已验证 |
| MODEL-ROLE-001 | 当前文件责任按固定基线 `MAINTAINERS` 判断：SiFive machine由 Alistair Francis、Palmer Dabbelt维护；RISC-V目录落在 RISC-V TCG CPUs 条目；K230由 Chao Liu维护；virtio、vhost、virtio-blk、VFIO各有独立条目。 | [`MAINTAINERS`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/MAINTAINERS)，条目 `RISC-V TCG CPUs`、`SiFive Machines`、`K230 Machines`、`virtio`、`vhost`、`virtio-blk`、`VFIO`。 | `M:`、`R:`按文件匹配表达当前维护/审查责任。 | 当前角色不能反推某段历史代码由该人设计；正文不以头衔替代 patch 和测试。 | 已验证 |

## 第 17 章：一页寄存器怎样变成设备

| ID | Claim | Primary evidence | Role | Reasoning boundary | Status |
| --- | --- | --- | --- | --- | --- |
| DEV-MIN-001 | SiFive test finisher没有持续寄存器状态；偏移零的写入解码 PASS、FAIL、RESET，其余写入记录 guest error。 | [`hw/misc/sifive_test.c`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/misc/sifive_test.c)：`sifive_test_read/write`、`sifive_test_ops`、`sifive_test_info`。 | 当前文件由 `SiFive Machines`匹配；文件版权记录 SiFive。 | 该例只说明当前设备无需持续状态，不能推广成所有 action device 都无需 reset 或 VMState。 | 已验证 |
| DEV-QOM-001 | QOM 将类型、class虚函数、实例状态与 properties分开；qdev生命周期使 machine先配置、后realize。 | [`docs/devel/qom.rst`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/docs/devel/qom.rst)，[`hw/char/sifive_uart.c`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/char/sifive_uart.c) 的 property、instance init、realize、unrealize。 | QOM文档是项目维护文档；SiFive UART匹配 SiFive machine责任。 | 文档给出框架语义；每个设备是否完整撤销 timer、handler和异步任务仍需逐文件审计。 | 已验证 |
| DEV-MMIO-001 | `MemoryRegionOps`中的端序与合法/实现访问宽度属于客户机总线契约。 | `sifive_test_ops`允许2–4字节并使用native endian；`sifive_uart_ops`只允许4字节且为little endian，均见固定源码。 | 同上。 | 源码证明当前声明，不能替硬件规范判断声明是否正确；需用规格和qtest交叉验证。 | 已验证 |
| DEV-UART-001 | SiFive UART 的可观察行为来自 FIFO、watermark、chardev、虚拟 timer 与派生 IRQ；`IP`由状态计算。 | [`hw/char/sifive_uart.c`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/char/sifive_uart.c)：`sifive_uart_ip`、`sifive_uart_update_irq`、`sifive_uart_xmit`、`sifive_uart_trigger_tx_fifo`、RX回调。 | 当前维护责任见 `SiFive Machines`。 | chardev接受字符只证明宿主前端完成一层动作，不代表远端已经消费；正文只描述当前QEMU边界。 | 已验证 |
| DEV-RESET-001 | Resettable以enter、hold、exit分离本地状态与跨对象副作用；SiFive UART在enter清本地字段/FIFO，在hold降低IRQ。 | [`docs/devel/reset.rst`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/docs/devel/reset.rst)；UART的`reset_enter/reset_hold`。 | 项目文档定义通用规则，设备实现提供当前实例。 | UART没有实现的phase不等于框架缺失；设备是否还需取消timer要通过运行状态审计。 | 已验证 |
| DEV-MIG-001 | `vmstate_sifive_uart` version 3保存RX数组/长度、控制字段、TX FIFO与timer，省略MMIO、IRQ句柄和chardev。 | UART固定源码；[`docs/devel/migration/main.rst`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/docs/devel/migration/main.rst) 的 VMState 与兼容规则。 | 当前设备维护者与migration通用维护责任分开。 | 字段表只证明序列化描述存在；恢复后的派生IRQ、timer时序与后端关系还需save/load实验。 | 已验证字段；运行闭环开放 |
| DEV-APLIC-001 | APLIC 在QEMU模拟时以动态数组保存source、state、target与每hart控制字段；VMState `.needed`按当前模拟所有者决定。 | [`hw/intc/riscv_aplic.c`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/intc/riscv_aplic.c)：realize、reset、`riscv_aplic_state_needed`、`vmstate_riscv_aplic`。 | 文件匹配固定基线 RISC-V 条目。 | `.needed`证明QEMU流的条件，无法证明KVM内AIA状态已有完整迁移接口。 | 已验证 |
| DEV-IOMMU-001 | RISC-V IOMMU common core含寄存器掩码、context/IOT cache、AddressSpace、queue与HPM timer；reset恢复DDTP、停止queue并清pending/cache。 | [`hw/riscv/riscv-iommu.c`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/riscv/riscv-iommu.c)：realize、unrealize、`riscv_iommu_reset`；PCI/system wrapper 的 reset hold 回调。 | 文件匹配固定基线 RISC-V 条目。 | 通用 reset 文档建议 IOMMU 在 exit 恢复翻译，当前两个 wrapper 却在 hold 调用 common reset；需继续审计 DMA quiesce，不能把文档建议写成实现已满足。PCI wrapper明确不可迁移，system wrapper没有完整VMState证据。 | 已验证reset与phase偏差；system迁移开放 |

## 第 18 章：设备怎样组合成板卡

| ID | Claim | Primary evidence | Role | Reasoning boundary | Status |
| --- | --- | --- | --- | --- | --- |
| BOARD-VIRT-001 | RISC-V `virt`集中定义memmap，按socket创建hart/irqchip，连接UART、RTC、virtio-mmio、GPEX PCIe，并通过Machine properties选择AIA、ACPI和system IOMMU。 | [`hw/riscv/virt.c`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/riscv/virt.c)：`virt_memmap`、`virt_machine_init`、`virt_machine_class_init`。 | 文件匹配 `RISC-V TCG CPUs`；当前M/R见固定MAINTAINERS。 | `virt`是抽象平台，不能用其便利地址或默认设备证明真实SoC具有相同硬件。 | 已验证 |
| BOARD-BOOT-001 | `virt`在machine-init-done阶段finalize FDT、加载firmware/kernel/FDT并建立reset vector；KVM当前只接受direct kernel boot。 | `virt_machine_done`；[`hw/riscv/boot.c`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/riscv/boot.c)。 | RISC-V machine与KVM代码各有责任边界。 | 这是固定基线能力，未来KVM firmware支持需重新核验。 | 已验证 |
| BOARD-K230-001 | K230 machine当前支持一颗C908小核、CLINT、PLIC、五个UART、两个WDT；direct boot要求OpenSBI与外部DTB，firmware boot由U-Boot/软件提供DTB。 | [`hw/riscv/k230.c`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/riscv/k230.c)，[`docs/system/riscv/k230.rst`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/docs/system/riscv/k230.rst)。 | 固定基线 `K230 Machines`：Chao Liu为maintainer。 | 物理芯片有更多处理单元和外设；正文只能把文档列出的当前实现称为supported。 | 已验证 |
| BOARD-UNIMP-001 | K230用priority -1000的unimplemented region覆盖未建模窗口，真实UART子区域可以叠加；占位访问记录日志并返回零。 | [`include/hw/misc/unimp.h`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/include/hw/misc/unimp.h)，[`hw/misc/unimp.c`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/misc/unimp.c)，`k230_create_uart`。 | unimplemented helper为通用设备；K230 machine负责范围与叠加。 | 占位提供日志和探针兼容，不提供设备功能、IRQ、DMA或迁移语义。 | 已验证 |
| BOARD-K230-REVIEW-001 | K230 v3修正PLIC/CLINT地址，v5修复reset-vector ROM跳转，v7处理未实现UART访问、hart数量、direct boot并明确该流的DTB所有权；v8完成rebase、M-mode检查与Machine interface等收尾后形成最终提交。 | [v7 patch](https://patchew.org/QEMU/cover.1778516731.git.chao.liu.zevorn%40gmail.com/98d3e3f8d931712fd9148411595608b9bba81053.1778516731.git.chao.liu.zevorn%40gmail.com/)，[v7对v8系列比较](https://patchew.org/QEMU/cover.1778516731.git.chao.liu.zevorn%40gmail.com/diff/cover.1781246408.git.chao.liu%40processmission.com/)，[v8 patch](https://patchew.org/QEMU/cover.1781246408.git.chao.liu%40processmission.com/a161697a249b896e44e2748435f6c0caec12c9f4.1781246408.git.chao.liu%40processmission.com/)，[commit `6cf0d08c`](https://gitlab.com/qemu-project/qemu/-/commit/6cf0d08c3953ee447cb215edc3a384834cbe48db)。 | final commit：Chao Liu作者；Peng Jiang `Tested-by`；Alistair Francis `Acked-by`并签入；Nutty Liu `Reviewed-by`；提交同时登记K230维护责任。 | changelog说明变化，不能把每项都归因于某一位reviewer，除非线程有直接回复；正文只列已确认角色。 | 已验证 |
| BOARD-PCIE-001 | `virt`的GPEX提供ECAM、PIO和低/高MMIO窗口；FDT中的`iommu-map`把PCI requester ID交给RISC-V IOMMU。 | `virt.c`的`gpex_pcie_init`、`create_fdt_pcie`、`create_fdt_iommu*`；[`hw/pci-host/gpex.c`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/pci-host/gpex.c)。 | RISC-V machine选择平台接线，PCI/IOMMU子系统维护各自模型。 | 一次BAR分配值可能来自firmware或guest，不能写成machine固定ABI；ECAM、BDF和BAR是不同地址/身份。 | 已验证 |
| BOARD-IOMMU-001 | PCI RISC-V IOMMU明确设置`.unmigratable = 1`；system wrapper实现realize/reset，但固定文件没有设备VMState。 | [`riscv-iommu-pci.c`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/riscv/riscv-iommu-pci.c)，[`riscv-iommu-sys.c`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/riscv/riscv-iommu-sys.c)。 | 当前维护责任归固定RISC-V条目。 | “没有找到VMState”只支持“迁移未证明”；system形式是否由其他机制完整覆盖需独立实验和migration inventory。 | PCI已验证；system开放 |

## 第 19 章：I/O 分层与状态所有权

| ID | Claim | Primary evidence | Role | Reasoning boundary | Status |
| --- | --- | --- | --- | --- | --- |
| IO-LAYER-001 | virtio transport处理发现/queue/notify，virtio device解释设备请求，服务backend完成宿主操作；实现可位于QEMU、kernel vhost或vhost-user。 | [`docs/devel/virtio-backends.rst`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/docs/devel/virtio-backends.rst)，[`virtio-mmio.c`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/virtio/virtio-mmio.c)，[`virtio-pci.c`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/virtio/virtio-pci.c)。 | 固定MAINTAINERS：virtio由 Michael S. Tsirkin维护。 | “backend”在文档中可能指整段模拟；正文显式区分服务backend与执行主体。 | 已验证 |
| IO-RING-001 | split ring通过desc/avail/used转移所有权；QEMU的`VirtQueueElement`保留in/out scatter-gather与guest地址，`virtqueue_pop/push`形成消费/完成。 | [OASIS Virtio 1.3](https://docs.oasis-open.org/virtio/virtio/v1.3/virtio-v1.3.html)，[`include/hw/virtio/virtio.h`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/include/hw/virtio/virtio.h)，[`hw/virtio/virtio.c`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/virtio/virtio.c)。 | OASIS 规范定义协议，QEMU 源码说明固定实现；virtio维护责任同上。 | ring索引不包含全部异步副作用；迁移还需device/backend in-flight。 | 已验证 |
| IO-BLK-001 | virtio-blk从queue解析type/sector/SG，交给block layer，完成后写status、push used并notify；drain参与reset与生命周期。 | [`hw/block/virtio-blk.c`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/block/virtio-blk.c)。 | 固定MAINTAINERS：Stefan Hajnoczi维护virtio-blk。 | 同一queue机制不能推导flush、discard与普通读写具有相同完成语义。 | 已验证 |
| IO-NOTIFY-001 | ioeventfd/irqfd搬运kick/call唤醒，feature、queue配置和请求验证仍由virtio/QEMU协议维护；通知可批处理和抑制。 | `virtio.c`、`virtio-mmio.c`、`virtio-pci.c`中的host/guest notifier与ioeventfd路径；`hw/virtio/trace-events`。 | virtio与KVM/irqchip维护责任交叉。 | ioeventfd在具体accelerator/host上的可用性需能力探测，不能当成所有运行模式的固定路径。 | 已验证源码；运行组合需实验 |
| IO-VHOST-001 | `vhost_dev_start`设置feature、memory table、vring、notifier、IOMMU listener与log；通用stop停止queue、取得base并同步used/log，in-flight须由支持它的具体路径显式取得。QEMU继续拥有控制面和迁移结果。 | [`hw/virtio/vhost.c`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/virtio/vhost.c)，官方virtio backend与security文档。 | 固定MAINTAINERS：Michael S. Tsirkin维护vhost，Stefano Garzarella为reviewer。 | vhost-user是运维/故障域，不是受支持的安全边界；不同backend的dirty log、in-flight和device state支持不能互相推导。 | 已验证 |
| IO-VHOST-MIG-001 | vhost迁移至少需要guest RAM、QEMU transport/device、vring/log/in-flight与backend私有状态四类边界。固定core提供in-flight VMState和backend state接口。 | `vhost.c`的`vmstate_vhost_inflight_region*`、`vhost_dev_prepare/get/set_inflight`、start/stop/log路径。 | vhost core提供公共接口，设备backend各自实现。 | 接口存在不证明每个backend支持迁移；缺能力时应有blocker或失败证据。 | 综合判断；逐backend开放 |
| IO-IOMMU-001 | vhost在`vdev->dma_as`登记IOMMU listener；memory table限制可访问RAM，IOTLB表示IOVA映射，两类授权不能合并。 | `vhost.c`的`vhost_dev_has_iommu`、`vhost_iommu_region_add/del`、start/stop listener；RISC-V IOMMU固定源码。 | vhost、virtio、RISC-V IOMMU三方责任交叉。 | 固定源码支持接口关系，完整的RISC-V IOMMU + vhost迁移顺序仍需运行和backend证据。 | 已验证接口；迁移开放 |
| IO-VFIO-001 | VFIO把物理设备交给guest，QEMU仍管理PCI配置/BAR/IRQ/reset/migration；迁移采用 `VFIO_DEVICE_FEATURE_MIGRATION` 能力与设备状态流；宿主IOMMU隔离与guest可见RISC-V IOMMU属于两道边界。 | [`hw/vfio/pci.c`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/hw/vfio/pci.c)，[`docs/devel/migration/vfio.rst`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/docs/devel/migration/vfio.rst)，[`docs/devel/vfio-iommufd.rst`](https://gitlab.com/qemu-project/qemu/-/blob/eca2c16212ef9dcb0871de39bb9d1c2efebe76be/docs/devel/vfio-iommufd.rst)。 | 固定MAINTAINERS：Alex Williamson、Cédric Le Goater维护VFIO；IOMMUFD有独立维护者。 | 固定 IOMMUFD 文档未列 riscv64 host；能否直通和迁移取决于host架构、IOMMU group、设备与内核能力，源码通用性不能替代实测。 | 已验证边界；riscv64 host与具体设备开放 |

## 实验闭环

| ID | Claim | Primary evidence | Role | Reasoning boundary | Status |
| --- | --- | --- | --- | --- | --- |
| EXP-DEV-001 | reset与VMState实验分别观察“恢复初态”和“恢复运行态”。 | [`trace-reset-phases`](../../experiments/part-04-machine-and-device-models/chapter-17-device-lifecycle/trace-reset-phases/README.md)，[`inspect-vmstate-fields`](../../experiments/part-04-machine-and-device-models/chapter-17-device-lifecycle/inspect-vmstate-fields/README.md)。 | 书内可重复实验，不改变上游角色。 | 只有静态脚本输出时标静态审计；不能代替save/load运行现象。 | 手册已验证；运行视环境 |
| EXP-BOARD-000 | 一个寄存器合同可以连续经过QOM/SysBus、MMIO、reset enter/hold、VMState、板级地址/PLIC连线与FDT，再由qtest和RISC-V裸机探针从外部核对。 | [`build-riscv-mmio-board-path`](../../experiments/part-04-machine-and-device-models/chapter-18-pcie-and-riscv-iommu/build-riscv-mmio-board-path/README.md)及其固定到rc0的教学patch、状态机与测试。 | 书内教学实验；虚构binding与设备ABI不是上游事实。 | 源码审查基线只证明锚点与patch适用性；TCG/default PLIC的运行记录不能推广到KVM、AIA或迁移往返。 | host模型与固定fixture已验证；live结论按运行记录 |
| EXP-BOARD-001 | PCIe四种视图与RISC-V IOMMU正向DMA可以独立验证。 | [`map-pcie-topology`](../../experiments/part-04-machine-and-device-models/chapter-18-pcie-and-riscv-iommu/map-pcie-topology/README.md)，[`trace-iommu-translation`](../../experiments/part-04-machine-and-device-models/chapter-18-pcie-and-riscv-iommu/trace-iommu-translation/README.md)。 | 同上。 | 合成fault只验证解析器；live fault结论需要真实`riscv_iommu_flt`。 | 手册已验证；live fault开放 |
| EXP-IO-001 | 一笔QEMU virtqueue与一组vhost对照可以观察owner变化。 | [`trace-virtqueue`](../../experiments/part-04-machine-and-device-models/chapter-19-virtio-and-vhost/trace-virtqueue/README.md)，[`compare-virtio-and-vhost`](../../experiments/part-04-machine-and-device-models/chapter-19-virtio-and-vhost/compare-virtio-and-vhost/README.md)。 | 同上。 | backend缺失或权限不足应标skip；路径变化与性能提升分别报告。 | 手册已验证；性能结果依环境 |

## 仍需继续核验的问题

1. SiFive UART 在 FIFO、timer 与 IRQ均为非默认状态时，跨版本迁移是否完整重算派生输出；
2. RISC-V system IOMMU是否存在由父层或其他机制覆盖的完整迁移状态，以及应如何设置明确的 blocker；
3. RISC-V IOMMU、vhost IOTLB、in-flight 与 backend私有状态的共同停机顺序；
4. riscv64 KVM host上具体 VFIO设备的reset、interrupt和migration能力矩阵。

这些问题在得到固定源码或运行证据前只留在账本，不扩写成正文能力。
