# Device-model review checklist

Use this checklist on the committed fixture and on a disposable candidate
patch. A checked item means the reviewer found evidence, not that the code
merely contains a similarly named function.

## Provenance and scope

- [ ] Every register, bit, reset value, and address cites a versioned source.
- [ ] Generated files, generator inputs, and hand-written logic are separated.
- [ ] The patch changes only the stated device, tests, build glue, and docs.
- [ ] Reused code and test vectors have compatible licenses.

## Guest input and memory

- [ ] Length and dimension arithmetic is checked before allocation or DMA.
- [ ] MMIO offsets, access sizes, alignment, and byte order are validated.
- [ ] DMA uses QEMU AddressSpace APIs and handles partial/error results.
- [ ] Queue depth and per-request resources have explicit upper bounds.

## Lifetime and concurrency

- [ ] Request ownership is clear across MMIO, BH, coroutine, and timer callbacks.
- [ ] Reset and unrealize cancel work before freeing state.
- [ ] BQL or AioContext assumptions are documented and testable.
- [ ] Error paths unmap memory, release references, and complete requests once.

## Compatibility and verification

- [ ] VMState contains guest-visible state, versions, and load validation.
- [ ] qtests cover reset, invalid input, IRQ, queue wrap, and migration.
- [ ] Functional tests pin redistributable assets by content hash.
- [ ] Git history and qemu-devel review are cited without invented rationale.
