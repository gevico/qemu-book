#!/usr/bin/env bash

set -euo pipefail

book_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "${book_dir}/.." && pwd)"
output_dir="${OUTPUT_DIR:-${project_dir}/output/pdf}"
book_version="${BOOK_VERSION:-持续更新}"
build_date="${BOOK_DATE:-$(date '+%Y-%m-%d')}"
book_repository_ref="${BOOK_REPOSITORY_REF:-main}"
output_filename="${OUTPUT_FILENAME:-深入理解-QEMU-设计原理-${book_version}.pdf}"
output_file="${output_dir}/${output_filename}"

chapters=(
    introduction.md
    part1.md
    chapter1.md
    chapter2.md
    chapter3.md
    chapter4.md
    chapter5.md
    chapter6.md
    part2.md
    chapter7.md
    chapter8.md
    chapter9.md
    chapter10.md
    chapter11.md
    part3.md
    chapter12.md
    chapter13.md
    chapter14.md
    chapter15.md
    part4.md
    chapter16.md
    chapter17.md
    chapter18.md
    chapter19.md
    part5.md
    chapter20.md
    chapter21.md
    chapter22.md
    chapter23.md
    part6.md
    chapter24.md
    chapter25.md
    chapter26.md
    quiz-answers.md
    appendix-a.md
    references.md
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

"${book_dir}/check_content.sh" --enforce

mkdir -p "${output_dir}"
cd "${book_dir}"

echo "Building ${output_file} from ${#chapters[@]} Markdown files..."

pandoc "${chapters[@]}" \
    --from=markdown+fenced_divs+link_attributes+smart \
    --metadata-file=metadata.yaml \
    --metadata=title="${book_version}" \
    --metadata=title-meta="深入理解 QEMU 设计原理" \
    --metadata=subtitle="" \
    --metadata=date="${build_date}" \
    --metadata=book-repository-ref="${book_repository_ref}" \
    --pdf-engine=xelatex \
    --top-level-division=chapter \
    --resource-path="${book_dir}" \
    --lua-filter=filters/quizzes.lua \
    --lua-filter=filters/callouts.lua \
    --lua-filter=filters/repository-links.lua \
    --include-in-header=preamble.tex \
    --syntax-highlighting=tango \
    --fail-if-warnings \
    --output="${output_file}"

echo "Done: ${output_file}"
