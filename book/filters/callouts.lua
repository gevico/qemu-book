-- Convert selected fenced divs into PDF callout boxes.

local boxes = {
    ["design-note"] = "designnotebox",
    ["source-path"] = "sourcepathbox",
    ["hands-on"] = "handsonbox",
}

function Div(element)
    if not FORMAT:match("latex") then
        return nil
    end

    for class_name, environment in pairs(boxes) do
        if element.classes:includes(class_name) then
            local blocks = {
                pandoc.RawBlock("latex", "\\begin{" .. environment .. "}"),
            }

            for _, block in ipairs(element.content) do
                table.insert(blocks, block)
            end

            table.insert(
                blocks,
                pandoc.RawBlock("latex", "\\end{" .. environment .. "}")
            )
            return blocks
        end
    end

    return nil
end
