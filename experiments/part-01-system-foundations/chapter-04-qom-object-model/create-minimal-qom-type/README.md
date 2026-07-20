# Create a minimal QOM type

Status: source fixture with an upstream-API checker; QEMU integration is kept
as an explicit exercise so that the repository never edits a source tree
silently.

Target release: QEMU `v11.1.0`; source-review baseline `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Build the smallest QOM object that exposes one property and makes construction
and finalization observable without pretending it is a complete device.

## Prerequisites

- A disposable QEMU worktree and a successful RISC-V system build.
- Familiarity with QEMU's coding style and Meson source lists.
- `rg` for the non-mutating API check.

## Files

- `README.md`: design and review procedure.
- `test-qemu-book-counter.c`: a focused GLib/QOM lifecycle test and its type.
- `meson-snippet.build`: the entry to add to QEMU's unit-test source map.
- `check-source.sh`: checks the fixture against the selected upstream API.

## Steps

1. Point `QEMU_SRC` at a QEMU `v11.1.0` or `v11.1.0-rc0` source tree and run
   `QEMU_SRC=/path/to/qemu ./check-source.sh`.
2. Create a disposable Git worktree from the same tag. Copy
   `test-qemu-book-counter.c` into its `tests/unit/` directory.
3. Add the line from `meson-snippet.build` to the `tests` dictionary in
   `tests/unit/meson.build`; do not add a second dictionary with the same key.
4. Reconfigure the existing build if needed, then run
   `meson compile -C build tests/unit/test-qemu-book-counter` and
   `build/tests/unit/test-qemu-book-counter`.
5. Change the initial value or remove `object_unref()`, rerun the focused test,
   and explain which lifecycle assertion catches the change.

## Expected results

The checker reports a matching QOM API, and the integrated unit test reports one
passing case. The fixture demonstrates registration, construction, property
access, reference release, and finalization without adding MMIO, IRQ, or
migration behavior prematurely.

## Cleanup

Remove the disposable worktree with `git worktree remove` after preserving any
notes. Do not run cleanup commands against the primary QEMU checkout.

## Troubleshooting

- If the type is not registered, inspect its module/source-set integration.
- A leaked reference is a failed result even if the property test passes.
- If the Meson key is duplicated, place the snippet inside the existing
  `tests` dictionary instead of appending a new one.
