#!/usr/bin/env bash

set -euo pipefail

book_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "${book_dir}/.." && pwd)"
output_dir="${OUTPUT_DIR:-${project_dir}/output/pdf}"
book_version="${BOOK_VERSION:-持续更新}"
output_filename="${OUTPUT_FILENAME:-深入理解-QEMU-设计原理.pdf}"
output_file="${output_dir}/${output_filename}"

chapters=(
    introduction.md
    chapter1.md
    chapter2.md
    chapter3.md
    chapter4.md
    chapter5.md
    chapter6.md
    chapter7.md
    chapter8.md
    chapter9.md
    chapter10.md
    chapter11.md
    chapter12.md
    chapter13.md
    appendix-a.md
    afterword.md
)

for command_name in pandoc xelatex; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        echo "error: ${command_name} is required" >&2
        exit 1
    fi
done

for chapter in "${chapters[@]}"; do
    if [[ ! -f "${book_dir}/${chapter}" ]]; then
        echo "error: missing chapter: ${chapter}" >&2
        exit 1
    fi
done

mkdir -p "${output_dir}"
cd "${book_dir}"

echo "Building ${output_file} from ${#chapters[@]} Markdown files..."

pandoc "${chapters[@]}" \
    --from=markdown+fenced_divs+link_attributes+smart \
    --metadata-file=metadata.yaml \
    --metadata=date="${book_version}" \
    --pdf-engine=xelatex \
    --top-level-division=chapter \
    --resource-path="${book_dir}" \
    --lua-filter=filters/callouts.lua \
    --include-in-header=preamble.tex \
    --syntax-highlighting=tango \
    --fail-if-warnings \
    --output="${output_file}"

echo "Done: ${output_file}"
