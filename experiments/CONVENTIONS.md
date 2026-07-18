# Experiment Conventions

## Naming

- Part directories use `part-NN-topic`.
- Chapter directories use `chapter-NN-topic`.
- Project directories use a short imperative or investigative kebab-case name.
- Manuals are always named `README.md` and written in English.
- Scripts use lowercase kebab-case names and include `set -euo pipefail` when
  written in Bash.
- New source and scripts include `SPDX-License-Identifier: Apache-2.0` when
  the language supports comments without changing the fixture semantics.

Book prose refers to the same experiment in Chinese and links to its project
directory. Do not duplicate the English manual in the manuscript.

## Project contract

Every project manual contains these sections, in this order:

1. Purpose
2. Prerequisites
3. Files
4. Steps
5. Expected results
6. Cleanup
7. Troubleshooting

A project may be source-inspection-only, host-executable, guest-executable, or
planned. Planned work must say so explicitly and must not imply that missing
scripts, firmware, kernels, or device models already exist.

## Reproducibility

The book targets QEMU `v11.1.0`; the source-review anchor is
`v11.1.0-rc0`. Prefer an exact commit ID in result records. Architecture-
specific examples use RISC-V, normally `riscv64` and the `virt` machine.

Use the following environment variables rather than embedding workstation
paths:

```sh
export QEMU_SRC=/absolute/path/to/qemu
export QEMU_BUILD=/absolute/path/to/qemu/build
export QEMU_SYSTEM_RISCV64="$QEMU_BUILD/qemu-system-riscv64"
export RISCV_GUEST_IMAGE=/absolute/path/to/a/reproducible/guest-image
```

Each lab must identify optional dependencies and provide a skip condition when
the host lacks KVM, tracing support, a RISC-V cross-toolchain, or a suitable
guest image.

## Safety

- Use disposable images or overlays for write tests.
- Never run destructive storage commands against an unresolved variable.
- Stop a QEMU process with the monitor or a bounded signal; do not use broad
  process-name matching.
- KVM labs must check `/dev/kvm` and RISC-V host support before execution.
- Keep external source trees read-only unless a lab explicitly creates a work
  branch for a patch exercise.

## Evidence

Source citations point to the official GitLab project:
`https://gitlab.com/qemu-project/qemu`. Historical claims should record a Git
commit and, when available, a qemu-devel Message-ID or archive URL. Lab output
is evidence of observed behavior, not by itself proof of design intent.
