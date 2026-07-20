# Build a RISC-V MMIO device-to-board path

Status: runnable host model and static checks; optional tree-out QEMU build,
qtest, FDT inspection, and bare-metal run.

Target release: QEMU `v11.1.0`; source-review baseline `v11.1.0-rc0`, commit
[`eca2c162`](https://gitlab.com/qemu-project/qemu/-/commit/eca2c16212ef9dcb0871de39bb9d1c2efebe76be);
RISC-V `riscv64` only.

## Purpose

This lab answers one continuous modeling question: how does a register
contract become a QEMU device, then a mapped and interrupt-wired device on a
RISC-V board that firmware can discover and exercise?

It can falsify the claim that implementing `MemoryRegionOps` alone completes a
device model. The checks require all of these boundaries to remain visible:

1. register masks, reset-phase ordering, pending state, and the IRQ level;
2. QOM type registration, SysBus MMIO and IRQ initialization, and VMState;
3. an explicit board address and interrupt source;
4. opt-in realization on `virt` and a matching FDT node;
5. qtest and RISC-V bare-metal observations of the same contract.

The patch is a **teaching-only tree-out template**. It has not been submitted
to or merged by QEMU upstream. The invented `qemu,qb-mmio-demo` binding and
machine property are not public ABIs. A real upstream proposal would first
need a real hardware or virtualization contract, binding review, compatibility
analysis, documentation, migration tests, and maintainer agreement.

## Prerequisites

For the deterministic host path:

- Python 3.10 or newer;
- Git, only when `QEMU_SRC` is set.

For exact source and integration checks:

- a QEMU Git worktree at commit
  `eca2c16212ef9dcb0871de39bb9d1c2efebe76be` in `QEMU_SRC`;
- QEMU build dependencies, Meson, and Ninja if compiling the patch.

For the optional live RISC-V path:

- a patched `qemu-system-riscv64` in `QEMU_SYSTEM_RISCV64`;
- `riscv64-unknown-elf-gcc` or `riscv64-linux-gnu-gcc`, or an executable path
  in `RISCV_CC`;
- `dtc` for human-readable FDT inspection.

No QEMU tree, QEMU binary, cross compiler, guest image, or non-RISC-V target is
needed for `./run.sh`. The live path uses TCG so it also does not require KVM.

## Files

- `README.md`: this manual and the end-to-end boundary map.
- `riscv_mmio_model.py`: executable register-level reference model.
- `test_riscv_mmio_model.py`: deterministic mask, reset enter/hold ordering,
  pending, IRQ, W1C, access-width, and alignment tests.
- `integration-checks.json`: exact commit, upstream path anchors, and required
  patch-layer markers.
- `verify_lab.py`: static artifact check, optional real-source API/path check,
  and read-only `git apply --check --cached` runner.
- `run.sh`: host test and static-check entry point.
- `qemu/0001-riscv-virt-add-teaching-mmio-demo.patch`: tree-out patch pinned to
  the source-review baseline. It adds the QOM/SysBus device, board mapping,
  opt-in machine property, FDT node, and qtest.
- `guest/start.S`, `guest/probe.c`, and `guest/linker.ld`: freestanding
  RISC-V probe. It exits through the existing SiFive test finisher.
- `build-baremetal.sh`: optional cross-build with an explicit skip status when
  no RISC-V compiler exists.
- `run_qemu.py`: bounded QEMU runner for the freestanding probe.
- `run-live.sh`: optional patched-QEMU and bare-metal entry point.
- `build/` and `results/`: ignored local outputs, created only by optional
  build and inspection steps.

The tree-out patch deliberately separates device facts from board facts:

| Boundary | Device side | RISC-V `virt` side |
| --- | --- | --- |
| Type and ownership | `OBJECT_DECLARE_SIMPLE_TYPE`, `TypeInfo` | opt-in `qb-mmio-demo` machine property |
| MMIO | `MemoryRegionOps`, 4-byte little-endian accesses | `0x10010000`, size `0x1000` |
| Interrupt | pending plus IRQ-enable derives one `qemu_irq` level | SysBus IRQ 0 connects to interrupt source 12 |
| Reset and migration | enter clears local fields; VMState saves them | hold updates the externally owned IRQ line |
| Discovery | no board address in the reusable device | generated FDT node contains `compatible`, `reg`, and interrupt properties |
| Verification | register behavior is qtested | PLIC pending bit, FDT, and bare-metal probe test the wiring |

## Steps

1. Run the toolchain-independent contract and artifact checks from this
   project directory:

   ```sh
   ./run.sh
   ```

   This runs seven Python unit tests. With no `QEMU_SRC`, the real-source branch
   prints one explicit `SKIP` and the command still succeeds.

2. Point the same command at an exact, unmodified baseline index:

   ```sh
   export QEMU_SRC=/absolute/path/to/qemu-v11.1.0-rc0
   ./run.sh
   ```

   `verify_lab.py` checks the commit, reads the actual source anchors, and runs:

   ```sh
   git -C "$QEMU_SRC" apply --check --cached --whitespace=error-all \
       "$PWD/qemu/0001-riscv-virt-add-teaching-mmio-demo.patch"
   ```

   `--check --cached` reads the baseline index and does not modify the source
   tree or index.

3. Trace one operation through the model before building QEMU. In
   `riscv_mmio_model.py`, follow a doorbell write through `pending` to the
   derived `irq_level`. In the patch, find the corresponding path:

   ```text
   qb_mmio_demo_write
     -> qb_mmio_demo_update_irq
     -> qemu_set_irq
     -> sysbus_create_simple(... qdev_get_gpio_in(..., 12))
   ```

   Then locate `create_fdt_qb_mmio_demo`. The address and interrupt number must
   agree with the board mapping; neither value belongs in the reusable device
   state machine.

   Follow reset separately. `reset_enter` clears only `control`, `data`, and
   `pending`; it must not mutate another object's IRQ input. `reset_hold` then
   recomputes and lowers the external line. The Python phase-ordering test
   deliberately observes the line still raised between those two calls.

4. To compile the teaching patch, create a disposable worktree rather than
   changing the source used for evidence review. Save this lab directory before
   changing directories:

   ```sh
   LAB_DIR="$PWD"
   export QEMU_LAB_TREE=/tmp/qemu-book-qb-mmio-rc0
   git -C "$QEMU_SRC" worktree add --detach "$QEMU_LAB_TREE" \
       eca2c16212ef9dcb0871de39bb9d1c2efebe76be
   git -C "$QEMU_LAB_TREE" apply \
       "$LAB_DIR/qemu/0001-riscv-virt-add-teaching-mmio-demo.patch"
   cd "$QEMU_LAB_TREE"
   ./configure --target-list=riscv64-softmmu --disable-docs
   ninja -C build qemu-system-riscv64 tests/qtest/qb-mmio-demo-test
   ```

5. Run the in-tree qtest against the patched RISC-V binary:

   ```sh
   QTEST_QEMU_BINARY=./build/qemu-system-riscv64 \
       ./build/tests/qtest/qb-mmio-demo-test
   ```

   The first case proves that the default `virt` machine does not map the
   teaching device. The second checks ID, control, and data masks. The third
   raises the device IRQ, observes PLIC pending bit 12, clears the device's W1C
   status, and verifies the completed system-reset state. Phase ordering is
   constrained separately by the host test and patch-layer markers.

6. Inspect guest discovery. Return to the lab directory, create the ignored
   results directory, and dump the generated RISC-V device tree:

   ```sh
   cd "$LAB_DIR"
   mkdir -p results
   "$QEMU_LAB_TREE/build/qemu-system-riscv64" \
       -machine virt,qb-mmio-demo=on,dumpdtb="$PWD/results/qb-mmio-demo.dtb" \
       -display none -nodefaults
   dtc -I dtb -O dts results/qb-mmio-demo.dtb | \
       rg -A5 -B1 'qb-mmio-demo@10010000'
   ```

   Repeat with `qb-mmio-demo=off` or without the property. The node and device
   must both disappear; the default `virt` machine contract remains unchanged.

7. Run the freestanding RISC-V probe against the same patched binary:

   ```sh
   export QEMU_SYSTEM_RISCV64="$QEMU_LAB_TREE/build/qemu-system-riscv64"
   ./run-live.sh
   ```

   The script compiles only RISC-V code, verifies that the opt-in property
   exists, and bounds QEMU execution. The probe checks masks, pending state,
   PLIC input 12, and W1C before requesting a successful shutdown.

## Expected results

The host-only path reports seven passing unit tests, six passing patch-layer
groups, a passing reset-phase partition check, three contract-alignment files,
a passing bare-metal fixture check, and one QEMU-tree skip when `QEMU_SRC` is
absent. With the exact baseline set, it additionally reports five source-anchor
groups and:

```text
PASS git-apply-check: eca2c16212ef9dcb0871de39bb9d1c2efebe76be
```

The compiled qtest reports three passing RISC-V cases. The FDT contains this
invariant structure; phandle values can differ:

```dts
qb-mmio-demo@10010000 {
    interrupts = <0x0c>;
    interrupt-parent = <...>;
    reg = <0x00 0x10010000 0x00 0x1000>;
    compatible = "qemu,qb-mmio-demo";
};
```

The live run ends with:

```text
PASS bare-metal probe: register masks, pending state, and PLIC input
```

When the optional live steps are run, they cover only TCG with the default
PLIC. The source-review baseline label records source anchors and patch
applicability; it does not claim a published rc0 runtime result. The device is
written against accelerator-independent QEMU APIs, and the FDT helper includes
the AIA interrupt-cell shape, but those facts do not replace RISC-V KVM-host or
AIA tests.

## Cleanup

`./run.sh` creates no durable result files. The optional scripts create only
`build/` and `results/` under this project; both are ignored and may be removed
after inspection.

Remove the disposable QEMU worktree through the source repository that created
it, after stopping every process launched from that tree:

```sh
git -C "$QEMU_SRC" worktree remove "$QEMU_LAB_TREE"
```

This lab never applies the patch to `QEMU_SRC` itself.

## Troubleshooting

- If `run.sh` prints `SKIP qemu-tree`, set `QEMU_SRC` only when an exact QEMU
  Git worktree is available. A different revision is intentionally not treated
  as proof that this pinned patch still applies.
- If the commit matches but `git apply --check` fails, inspect staged changes
  or index replacements in that worktree. The checker uses the index so
  unrelated unstaged edits do not affect the result.
- If Ninja cannot find `qb-mmio-demo-test`, rerun `configure` after applying
  the patch; Meson must regenerate the qtest target list.
- When invoking the qtest binary directly, set `QTEST_QEMU_BINARY`, not an
  architecture-suffixed variable.
- Exit status 77 from `build-baremetal.sh` or `run-live.sh` is an intentional
  skip for a missing cross compiler or patched QEMU binary. The host tests are
  still the deterministic validation path.
- If a compiler rejects `rv64imac_zicsr`, use a current RISC-V GCC through
  `RISCV_CC`; do not replace the guest with a non-RISC-V target.
- If the bare-metal probe times out, first verify that
  `-machine virt,help` lists `qb-mmio-demo`, then run the qtest. A stock QEMU
  binary does not contain this teaching device.
- QEMU may print version `11.0.90` for this release candidate. Record the Git
  commit, not only the version string.
