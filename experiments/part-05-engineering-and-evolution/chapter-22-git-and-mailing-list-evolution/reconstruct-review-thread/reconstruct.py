#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Extract review-thread identifiers from one accepted QEMU commit."""

from __future__ import annotations

import argparse
import pathlib
import re
import subprocess

URL = re.compile(r"https?://\S+")
MESSAGE_ID = re.compile(
    r"^\s*Message-ID:\s*(<[^<>\s]+@[^<>\s]+>)\s*$", re.IGNORECASE | re.MULTILINE
)


def git(qemu: pathlib.Path, *arguments: str) -> str:
    return subprocess.run(
        ["git", "-C", str(qemu), *arguments],
        text=True,
        capture_output=True,
        check=True,
    ).stdout


def main() -> None:
    default_output = pathlib.Path(__file__).resolve().parent / "results/review-thread.md"
    parser = argparse.ArgumentParser()
    parser.add_argument("--qemu-src", type=pathlib.Path, required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--output", type=pathlib.Path, default=default_output)
    args = parser.parse_args()
    qemu = args.qemu_src.resolve()
    commit = git(qemu, "rev-parse", f"{args.commit}^{{commit}}").strip()
    message = git(qemu, "show", "-s", "--format=fuller", commit)
    patch_subject = git(qemu, "show", "-s", "--format=%s", commit).strip()
    urls = sorted(set(URL.findall(message)))
    message_ids = sorted(set(MESSAGE_ID.findall(message)))

    lines = [
        "# Review thread ledger",
        "",
        f"- Commit: `{commit}`",
        f"- Merged subject: {patch_subject}",
        "- Evidence class: merged Git fact",
        "",
        "## Commit-provided archive anchors",
        "",
    ]
    if urls or message_ids:
        lines.extend(f"- {item}" for item in [*urls, *message_ids])
    else:
        lines.append("- No URL or Message-ID is present; search by exact subject and author.")
    lines += [
        "",
        "## Revision ledger",
        "",
        "| Revision | Message-ID | Author rationale | Reviewer request | Resulting change |",
        "|---|---|---|---|---|",
        "| v1 | TODO | TODO | TODO | TODO |",
        "",
        "## Classification rule",
        "",
        "Keep patch-author rationale, reviewer requests, merged facts, and book-author inference in separate cells.",
        "",
        "## Raw commit message",
        "",
        "```text",
        message.rstrip(),
        "```",
        "",
    ]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(lines), encoding="utf-8")
    print(args.output)


if __name__ == "__main__":
    main()
