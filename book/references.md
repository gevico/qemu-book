# 参考资料 {.unnumbered}

本书在正文中直接链接能够支持当前结论的源码、提交和邮件。下面列出贯穿多章的主要材料；单个设备或补丁系列的完整版本记录保存在 `book/research/`，不在这里重复铺开。链接最后核验于 2026 年 7 月。

## QEMU 起源与当前源码 {.unnumbered}

- Fabrice Bellard，2003 年早期 *QEMU x86 Emulator Reference Documentation*：[固定提交中的原文](https://gitlab.com/qemu-project/qemu/-/blob/386405f78661e0a4f82087196c7b084b8c612b48/qemu-doc.texi)。
- Fabrice Bellard，*QEMU 0.4 release*，2003 年 6 月：[qemu-devel 邮件](https://lists.gnu.org/archive/html/qemu-devel/2003-06/msg00123.html)。
- Fabrice Bellard，*QEMU, a Fast and Portable Dynamic Translator*，USENIX 2005：[会议论文](https://www.usenix.org/conference/2005-usenix-annual-technical-conference/qemu-fast-and-portable-dynamic-translator)。
- QEMU Project，`v11.1.0-rc0`：[固定源码树](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0)。
- QEMU Project，*About QEMU*：[官方文档](https://www.qemu.org/docs/master/about/)。
- QEMU Project，*QEMU System Emulation User's Guide*：[官方文档](https://www.qemu.org/docs/master/system/index.html)。

## TCG 与动态翻译 {.unnumbered}

- Fabrice Bellard，*TCG*，2008 年 2 月：[引入公告](https://lists.gnu.org/archive/html/qemu-devel/2008-02/msg00011.html)。
- Fabrice Bellard，*TCG code generator*：[初始提交](https://gitlab.com/qemu-project/qemu/-/commit/c896fe29d6c8ae6cde3917727812ced3f2e536a4)与[初始 README](https://gitlab.com/qemu-project/qemu/-/blob/c896fe29d6c8ae6cde3917727812ced3f2e536a4/tcg/README)。
- QEMU Project，*Translator Internals*：[当前文档](https://www.qemu.org/docs/master/devel/tcg.html)。
- QEMU Project，*TCG Intermediate Representation*：[当前 IR、优化和编码规则](https://www.qemu.org/docs/master/devel/tcg-ops.html)。
- QEMU Project，RISC-V TCG 当前实现：[固定版本源码](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/target/riscv/tcg)。

## KVM 与硬件虚拟化 {.unnumbered}

- Avi Kivity，*[PATCH 0/7] KVM: Kernel-based Virtual Machine*，2006 年 10 月：[最初 LKML patchset](https://lkml.iu.edu/hypermail/linux/kernel/0610.2/1369.html)。
- Avi Kivity、Yaniv Kamay、Dor Laor、Uri Lublin、Anthony Liguori，*kvm: the Linux Virtual Machine Monitor*，Linux Symposium 2007：[论文 PDF](https://www.kernel.org/doc/ols/2007/ols2007v1-pages-225-230.pdf)。
- Linux Kernel，*The Definitive KVM API Documentation*：[当前 UAPI](https://docs.kernel.org/virt/kvm/api.html)。
- Avi Kivity，*The Shadowy Depths of the KVM MMU*，KVM Forum 2007：[演讲 PDF](https://gitlab.com/qemu-project/kvm-forum/-/raw/main/_attachments/2007/KvmForum2007%24shadowy-depths-of-the-kvm-mmu.pdf)。
- Dor Laor，*KVM PV Devices*，KVM Forum 2007：[演讲 PDF](https://gitlab.com/qemu-project/kvm-forum/-/raw/main/_attachments/2007/KvmForum2007%24kvm_pv_drv.pdf)。
- Anthony Liguori、Uri Lublin，*KVM Live Migration*，KVM Forum 2007：[演讲 PDF](https://gitlab.com/qemu-project/kvm-forum/-/raw/main/_attachments/2007/KvmForum2007%24Kvm_Live_Migration_Forum_2007.pdf)。
- Anthony Liguori，*QEMU upstream KVM support*，2008 年 2 月：[qemu-devel patchset](https://lists.gnu.org/archive/html/qemu-devel/2008-02/msg00038.html)。
- Anthony Liguori，*Building a Better Userspace*，KVM Forum 2008：[演讲 PDF](https://linux-kvm.org/images/6/65/KvmForum2008%24kdf2008_4.pdf)。
- QEMU Project，RISC-V KVM 当前实现：[固定版本源码](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/target/riscv/kvm)。

## RISC-V 架构与平台 {.unnumbered}

- RISC-V International，*The RISC-V Instruction Set Manual, Volume II: Privileged Architecture*：[官方规范](https://docs.riscv.org/reference/isa/priv/priv-index.html)。
- RISC-V International，*Hypervisor Extension*：[H 扩展](https://docs.riscv.org/reference/isa/priv/hypervisor.html)。
- RISC-V International，*RISC-V IOMMU Architecture Specification*：[正式规范](https://docs.riscv.org/reference/iommu/index.html)。
- QEMU Project，*RISC-V System Emulator*：[target 文档](https://www.qemu.org/docs/master/system/target-riscv.html)。
- QEMU Project，*`virt` Generic Virtual Platform*：[machine 文档](https://www.qemu.org/docs/master/system/riscv/virt.html)。
- QEMU Project，RISC-V machine 当前实现：[固定版本源码](https://gitlab.com/qemu-project/qemu/-/tree/v11.1.0-rc0/hw/riscv)。

## 设备、I/O、迁移与安全 {.unnumbered}

- OASIS，*Virtual I/O Device (VIRTIO) Version 1.3*：[规范正文](https://docs.oasis-open.org/virtio/virtio/v1.3/virtio-v1.3.html)。
- QEMU Project，*Virtio devices and drivers*：[官方概览](https://www.qemu.org/docs/master/system/devices/virtio.html)。
- QEMU Project，*Virtio backend implementations*：[后端边界](https://www.qemu.org/docs/master/devel/virtio-backends.html)。
- QEMU Project，*Vhost-user Protocol*：[互操作协议](https://www.qemu.org/docs/master/interop/vhost-user.html)。
- QEMU Project，*Migration framework*：[开发文档](https://www.qemu.org/docs/master/devel/migration/main.html)。
- QEMU Project，*Security*：[支持范围与威胁模型](https://www.qemu.org/docs/master/system/security.html)。

## Rust 与长期维护 {.unnumbered}

- Stefan Hajnoczi，*Why QEMU should move from C to Rust*，2020 年：[维护者文章](https://blog.vmsplice.net/2020/08/why-qemu-should-move-from-c-to-rust.html)。
- Manos Pitsidianakis，*Rust support and PL011 device model, v11*，2024 年：[完整 patch series](https://patchew.org/QEMU/cover.1727961605.git.manos.pitsidianakis%40linaro.org/)。
- QEMU Project，*Rust in QEMU*：[当前开发文档](https://www.qemu.org/docs/master/devel/rust.html)。
- Miguel Ojeda，*[PATCH 00/13] [RFC] Rust support*，2021 年：[Linux 初始 RFC](https://www.spinics.net/lists/kernel/msg3906485.html)。
- Linux Kernel，初始 Rust merge：[commit `8aebac82933f`](https://git.kernel.org/linus/8aebac82933ff1a7c8eede18cab11e1115e2062b)。
- Miguel Ojeda，结束 Linux Rust 实验：[commit `9fa7153c31a3`](https://git.kernel.org/linus/9fa7153c31a3e5fe578b83d23bc9f185fde115da)。

## 社区协作与研究边界 {.unnumbered}

- QEMU Project，*Submitting a Patch*：[邮件提交流程](https://www.qemu.org/docs/master/devel/submitting-a-patch.html)。
- QEMU Project，*The Role of Maintainers*：[角色和维护状态](https://www.qemu.org/docs/master/devel/maintainers.html)。
- QEMU Project，*Code provenance*：[DCO、署名与生成式 AI 政策](https://www.qemu.org/docs/master/devel/code-provenance.html)。
- GEVICO，*qemu-camp-tutorial*：[QEMU 技术训练营公开讲义](https://github.com/gevico/qemu-camp-tutorial)。

思考题放在相关知识点附近，答案由构建脚本汇总到附录。实验目录沿用“每个项目可独立运行”的组织方式，正文只选择能够验证关键原理的入口，不以实验数量代替论证。
