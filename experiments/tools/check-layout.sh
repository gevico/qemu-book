#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

experiments_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
status=0

part_readmes=("${experiments_dir}"/part-*/README.md)
chapter_readmes=("${experiments_dir}"/part-*/chapter-*/README.md)
project_readmes=("${experiments_dir}"/part-*/chapter-*/*/README.md)

check_count()
{
    local label="$1"
    local expected="$2"
    local actual="$3"

    printf '%-18s expected=%-3d actual=%d\n' "${label}" "${expected}" "${actual}"
    if (( actual != expected )); then
        status=1
    fi
}

check_count "parts" 5 "${#part_readmes[@]}"
check_count "chapters" 23 "${#chapter_readmes[@]}"
check_count "projects" 51 "${#project_readmes[@]}"

required_sections=(
    "Purpose"
    "Prerequisites"
    "Files"
    "Steps"
    "Expected results"
    "Cleanup"
    "Troubleshooting"
)
markdown_tick=$'\x60'
qemu_release_pattern="QEMU ${markdown_tick}v11\\.1\\.0${markdown_tick}"
qemu_baseline_pattern="${markdown_tick}v11\\.1\\.0-rc0${markdown_tick}"

for manual in "${project_readmes[@]}"; do
    relative_manual="${manual#"${experiments_dir}/"}"
    project_dir="${manual%/README.md}"

    for section in "${required_sections[@]}"; do
        if ! grep -Eq "^## ${section}$" "${manual}"; then
            printf 'missing section %s: %s\n' "${section}" "${relative_manual}" >&2
            status=1
        fi
    done

    if ! grep -Eq "${qemu_release_pattern}" "${manual}" ||
       ! grep -Eq "${qemu_baseline_pattern}" "${manual}" ||
       ! grep -Eq 'RISC-V|riscv64' "${manual}"; then
        printf 'missing baseline metadata: %s\n' "${relative_manual}" >&2
        status=1
    fi

    if [[ -z "$(find "${project_dir}" -type f \
            ! -name README.md ! -name '*.md' \
            ! -name Cargo.toml ! -name Cargo.lock -print -quit)" ]]; then
        printf 'missing experiment implementation: %s\n' "${relative_manual}" >&2
        status=1
    fi

    while IFS= read -r command_ref; do
        command_path="${project_dir}/${command_ref#./}"
        if [[ ! -x "${command_path}" ]]; then
            printf 'missing or non-executable manual command %s: %s\n' \
                "${command_ref}" "${relative_manual}" >&2
            status=1
        fi
    done < <(grep -Eo '`\./[A-Za-z0-9_.-]+' "${manual}" | tr -d '`' | sort -u)

    if grep -Eqi '\bplanned\b|no .*committed|not .*committed|absent now' "${manual}"; then
        printf 'stale planned-only wording: %s\n' "${relative_manual}" >&2
        status=1
    fi

    if LC_ALL=C perl -CSDA -ne 'exit 1 if /\p{Han}/' "${manual}"; then
        :
    else
        printf 'non-English Han text in manual: %s\n' "${relative_manual}" >&2
        status=1
    fi
done

while IFS= read -r source_file; do
    relative_source="${source_file#"${experiments_dir}/"}"
    if ! head -n 8 "${source_file}" |
         grep -Eq 'SPDX-License-Identifier: Apache-2\.0'; then
        printf 'missing Apache-2.0 SPDX header: %s\n' \
            "${relative_source}" >&2
        status=1
    fi
done < <(find "${experiments_dir}" -type f \
    \( -name '*.sh' -o -name '*.py' -o -name '*.c' -o -name '*.S' \
       -o -name '*.rs' -o -name '*.ld' -o -name Makefile \
       -o -name '*.toml' \) | LC_ALL=C sort)

while IFS= read -r relative_path; do
    if [[ "${relative_path}" =~ [^A-Za-z0-9_./-] ]]; then
        printf 'non-English or unsafe path: %s\n' "${relative_path}" >&2
        status=1
    fi
done < <(cd "${experiments_dir}" && find . -mindepth 1 -print | LC_ALL=C sort)

if (( status != 0 )); then
    printf 'experiment layout gate failed\n' >&2
    exit 1
fi

printf 'experiment layout gate passed\n'
