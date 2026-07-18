# Engineering, tests, history, and Rust evidence

Research anchor: QEMU `v11.1.0-rc0`, commit `eca2c16212ef9dcb0871de39bb9d1c2efebe76be`.

## Observability layers

- QEMU `-d` logging, trace events, QMP/HMP, the GDB stub, and host sampling expose different contracts. Current source entry points are `util/log.c`, `trace/`, `monitor/`, `qapi/`, `target/riscv/gdbstub.c`, and [`docs/devel/tracing.rst`](https://gitlab.com/qemu-project/qemu/-/blob/v11.1.0-rc0/docs/devel/tracing.rst).
- QMP is a versioned machine protocol described by the QAPI schema; HMP is primarily a human-facing command interface. Automation should not treat HMP presentation text as a stable data schema.
- Trace events are declared data with event names and fields. Adding an event to a hot path creates cost and maintenance considerations that differ from temporary logging.
- **Strong inference:** debugging should begin with state ownership and a falsifiable question. Enabling every logger at once can alter timing and obscure the event sequence it is meant to reveal.

## Functional tests are a deliberately independent framework

- Base classes: commit [`fa32a634`](https://gitlab.com/qemu-project/qemu/-/commit/fa32a634329f4b2cdab8e380d5ccf263b1491daa), Message-ID [`20240830133841.142644-9-thuth@redhat.com`](https://lore.kernel.org/qemu-devel/20240830133841.142644-9-thuth@redhat.com/), removed the Avocado dependency from the new base while passing emulator/build paths through environment variables.
- Build integration: commit [`14973778`](https://gitlab.com/qemu-project/qemu/-/commit/1497377857ae4f41688f112903387032d939fb6e), Message-ID [`20240830133841.142644-12-thuth@redhat.com`](https://lore.kernel.org/qemu-devel/20240830133841.142644-12-thuth@redhat.com/), explicitly separated quick and thorough tests because asset downloads and runtime cost differ.
- Direct execution: commit [`cce85725`](https://gitlab.com/qemu-project/qemu/-/commit/cce85725f10fbe92481e8314986e69dbe6ca0dd1), Message-ID [`20240830133841.142644-13-thuth@redhat.com`](https://lore.kernel.org/qemu-devel/20240830133841.142644-13-thuth@redhat.com/), made converted tests independently executable for easier debugging.
- Asset discipline: commit [`9903217a`](https://gitlab.com/qemu-project/qemu/-/commit/9903217a4ed013228d95d8b1876b6053b2bc5e95), Message-ID [`20240830133841.142644-15-thuth@redhat.com`](https://lore.kernel.org/qemu-devel/20240830133841.142644-15-thuth@redhat.com/), introduced content-hash-based cached assets.
- **Strong inference:** test layering is an ownership decision. qtest constrains register/reset/IRQ behavior without a full guest; functional tests constrain firmware/OS integration; neither substitutes for the other.

## Migration compatibility is an intersection

- Current source: `migration/`, `include/migration/vmstate.h`, `tests/qtest/migration/`, and versioned Machine definitions.
- Cross-binary testing: commit [`dcf389cb`](https://gitlab.com/qemu-project/qemu/-/commit/dcf389cbc84c2b714d49887775918c5f03f73864), Message-ID [`20231018192741.25885-7-farosas@suse.de`](https://lore.kernel.org/qemu-devel/20231018192741.25885-7-farosas@suse.de/), added `find_common_machine_version()` because two QEMU binaries need a Machine version supported by both.
- **Fact:** a VMState description explicitly lists guest-relevant fields and versions; serializing an in-memory C or Rust structure layout is not the migration protocol.
- **Strong inference:** migration support is the intersection of source state extraction, stream schema, destination reconstruction, Machine compatibility, and backend capability. A device working at runtime does not imply it can migrate.

## Git and qemu-devel research method

- Start from a fixed source symbol and use `git log --follow`, `git log -S`, and `git log -G`; then read the full commit message and diff.
- Resolve Message-ID or `Link:` trailers to qemu-devel/lore/Patchew, compare v1 through the merged revision, and record whether a review request changed the final code.
- Include later fixes and regression tests. Initial intent alone is not a sufficient account of the current invariant.
- Classify prose as current-source fact, upstream statement, strong author inference, or open question. A fluent explanation does not raise the evidence level.

## Rust integration is incremental

- Build option: commit [`764a6ee9`](https://gitlab.com/qemu-project/qemu/-/commit/764a6ee9feb428a9759eaa94673285fad2586f11), [review link](https://lore.kernel.org/r/14642d80fbccbc60f7aa78b449a7deb5e2784ed9.1727961605.git.manos.pitsidianakis@linaro.org).
- Bindgen as a Meson dependency: commit [`6fdc5bc1`](https://gitlab.com/qemu-project/qemu/-/commit/6fdc5bc173188f5e4942616b16d589500b874a15), [review link](https://lore.kernel.org/r/1be89a27719049b7203eaf2eca8bbb75b33f18d4.1727961605.git.manos.pitsidianakis@linaro.org).
- Initial bindings/interface crate: commit [`5a5110d2`](https://gitlab.com/qemu-project/qemu/-/commit/5a5110d290c0f2dca3d98c608b0ec9a01d2181b9), [review link](https://lore.kernel.org/r/0fb23fbe211761b263aacec03deaf85c0cc39995.1727961605.git.manos.pitsidianakis@linaro.org).
- First device case: commit [`37fdb2f5`](https://gitlab.com/qemu-project/qemu/-/commit/37fdb2f56a90c7d5ea7093b920a7bf72c03aff17), [PL011 v1 review](https://lore.kernel.org/r/20241024-rust-round-2-v1-2-051e7a25b978@linaro.org). Migration followed in commit [`93243319`](https://gitlab.com/qemu-project/qemu/-/commit/93243319db276bb424b7f9ad0bdfa8dc4b3368bd), showing that a device implementation and its migration contract are separate deliverables.
- Current source is organized under `rust/bindings/`, `rust/qom/`, `rust/system/`, `rust/migration/`, `rust/hw/core/`, and concrete Rust devices. Meson/Kconfig still select what enters the QEMU binary; Cargo describes the Rust workspace.
- **Fact:** the upstream PL011 example is associated with Arm. The book may study it to understand the language boundary, but architecture-dependent examples and the book-owned teaching device remain RISC-V.
- **Strong inference:** Rust can encode local borrowing, locking, and register invariants, but it cannot infer QOM lifetime, guest ABI, VMState meaning, or FFI validity. These stay explicit review obligations.
