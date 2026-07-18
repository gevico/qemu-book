# Expected fixture findings

The review should identify at least these independent defects:

1. MMIO access size and alignment are ignored.
2. `guest_length * 16` can overflow before allocation and DMA.
3. Guest-controlled allocation has no protocol limit.
4. `address_space_read()` completion status is ignored.
5. A new doorbell overwrites `request_buffer` without ownership checks.
6. Reset does not cancel the timer or lower the IRQ.
7. A callback scheduled before reset can complete after reset.
8. The request buffer is not freed on success, reset, or unrealize.
9. Guest-visible state has no VMState description or load validation.
10. No negative qtest establishes the expected error contract.

Some findings share a line of code but represent different invariants. Keep
them separate in the review ledger, then propose the smallest patch ordering
that makes each stage buildable and testable.
