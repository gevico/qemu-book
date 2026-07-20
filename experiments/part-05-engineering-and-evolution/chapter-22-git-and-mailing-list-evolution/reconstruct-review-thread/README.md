# Reconstruct a review thread

Status: source-and-archive research; network access to qemu-devel archives is
required.

Target release: QEMU `v11.1.0`; source-review baseline `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Connect an accepted RISC-V commit to its patch series, review comments, revised
versions, and final design choices.

## Prerequisites

- Full QEMU Git history and access to a qemu-devel archive preserving
  Message-IDs and thread relationships.
- One accepted commit selected by the preceding history lab.

## Files

- `README.md`: review-reconstruction procedure.
- `reconstruct.py`: commit identity, URL/Message-ID extraction, and a
  classification-safe ledger template.
- `test_reconstruct.py`: extraction-boundary regression tests.
- `results/review-thread.md`: generated starting ledger.

## Steps

1. Run `python3 -m unittest -v test_reconstruct.py`, then run
   `./reconstruct.py --qemu-src "$QEMU_SRC" --commit COMMIT`. Inspect the
   extracted mailing-list links, explicitly labeled Message-IDs, and merged
   metadata; search the archive by exact subject and author when absent.
2. Record cover letter plus each relevant `v1`, `v2`, and later patch.
3. Extract reviewer concerns in paraphrase and link each to the next code or
   commit-message change.
4. Mark statements as patch-author rationale, reviewer request, merged fact,
   or book-author inference.

## Expected results

Both extraction tests pass. The completed ledger explains at least one
concrete revision caused by review and cites stable Message-IDs rather than an
untraceable search result.

## Cleanup

Remove local archive copies and notes if they are not intended as book
evidence; do not alter upstream history.

## Troubleshooting

- Subject lines can change between versions; search by author and patch diff.
- Silence in a thread is not evidence that reviewers endorsed a design claim.
