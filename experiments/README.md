# Experiments

This tree contains the hands-on companion material for *Understanding QEMU
Design Principles*. The prose in the book introduces every lab in Chinese;
the directories, filenames, code comments, and lab manuals here use English.

## Baseline

- Target QEMU release: `v11.1.0`
- Research and source-review anchor: `v11.1.0-rc0`
- Primary guest architecture: RISC-V 64-bit (`riscv64`)
- Primary system model: the RISC-V `virt` machine, unless a manual says
  otherwise

Record the exact QEMU commit, host architecture, compiler, kernel, and
accelerator in every result. Until the final `v11.1.0` tag is available, run
source-sensitive labs against `v11.1.0-rc0` and label the result accordingly.

## Layout

```text
experiments/
├── part-01-system-foundations/
│   └── chapter-01-qemu-boundaries/
│       ├── README.md
│       ├── compare-accelerators/
│       │   └── README.md
│       └── trace-riscv-virt-boot/
│           └── README.md
├── ...
└── part-06-heterogeneous-systems/
    └── chapter-26-ai-agent-device-modeling/
```

Each chapter owns at least two project directories. A project is the unit of
execution: open its `README.md`, satisfy its prerequisites, and follow its
steps without having to infer instructions from another chapter. Shared
helpers are limited to environment validation, source reporting, and small
shell precondition helpers; a lab manual must still state every
experiment-specific command and expected result.

## Quick start

```sh
export QEMU_SRC=/absolute/path/to/qemu
export QEMU_BUILD=/absolute/path/to/qemu/build
export QEMU_SYSTEM_RISCV64="$QEMU_BUILD/qemu-system-riscv64"

./experiments/tools/check-environment.sh
./experiments/tools/source-report.sh
```

Then choose a chapter from the index below and enter one of its project
directories.

| Part | Chapters | Theme |
| --- | --- | --- |
| `part-01-system-foundations` | 01-06 | Process, objects, memory, and CPU models |
| `part-02-tcg-execution-engine` | 07-11 | TCG translation and SoftMMU |
| `part-03-riscv-hardware-virtualization` | 12-15 | RISC-V H extension and KVM |
| `part-04-machine-and-device-models` | 16-19 | Machines, buses, devices, and I/O |
| `part-05-engineering-and-evolution` | 20-23 | Debugging, tests, history, and Rust |
| `part-06-heterogeneous-systems` | 24-26 | GPGPU, SoCs, and AI accelerators |

## Result discipline

Keep generated data out of Git unless the manual explicitly names a fixture.
Use a local `results/` directory and include at least:

1. `source-report.txt` from `tools/source-report.sh`;
2. the exact command line;
3. stdout/stderr or trace output;
4. a short observation that separates measured facts from interpretation.

See [CONVENTIONS.md](CONVENTIONS.md) for naming, reproducibility, and safety
rules. Use [MANUAL_TEMPLATE.md](MANUAL_TEMPLATE.md) for new labs.
