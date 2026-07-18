-- SPDX-License-Identifier: Apache-2.0
-- Convert repository-relative experiment links into stable PDF hyperlinks.

local function metadata_text(metadata, key, default_value)
    local value = metadata[key]

    if value == nil then
        return default_value
    end
    return pandoc.utils.stringify(value)
end

function Pandoc(document)
    local repository_url = metadata_text(
        document.meta,
        "book-repository-url",
        "https://github.com/gevico/qemu-book"
    )
    local repository_ref = metadata_text(document.meta, "book-repository-ref", "main")

    repository_url = repository_url:gsub("/$", "")

    document.blocks = pandoc.walk_block(
        pandoc.Div(document.blocks),
        {
            Link = function(link)
                if link.target:match("^%.%./experiments/") then
                    local path = link.target:gsub("^%.%./", "")
                    link.target = repository_url .. "/blob/" .. repository_ref .. "/" .. path
                end
                return link
            end,
        }
    ).content

    return document
end
