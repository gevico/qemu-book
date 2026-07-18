-- Build inline chapter quizzes and a linked answer appendix.

local chapters = {}
local current_chapter = nil
local answers_inserted = false

local function has_class(element, class_name)
    return element.classes:includes(class_name)
end

local function append_blocks(target, source)
    for _, block in ipairs(source) do
        table.insert(target, block)
    end
end

local function quiz_labels(chapter_number, quiz_number)
    local suffix = tostring(chapter_number) .. "-" .. tostring(quiz_number)
    return "quiz-question-" .. suffix, "quiz-answer-" .. suffix
end

local function quiz_title(number, answer_label)
    return "\\hyperref[" .. answer_label .. "]{\\textcolor{QEMUDark}{思考题 " ..
        number .. "}}"
end

local function inline_quiz(entry)
    local blocks = {
        pandoc.RawBlock(
            "latex",
            "\\phantomsection\\label{" .. entry.question_label .. "}" ..
            "\\begin{quickquizbox}{" .. quiz_title(entry.number, entry.answer_label) .. "}"
        ),
    }

    append_blocks(blocks, entry.question)
    table.insert(
        blocks,
        pandoc.RawBlock(
            "latex",
            "\\par\\hfill\\hyperref[" .. entry.answer_label .. "]{\\quizfilledsquare}" ..
            "\\end{quickquizbox}"
        )
    )
    return blocks
end


local function answer_entry(entry)
    local blocks = {
        pandoc.RawBlock(
            "latex",
            "\\phantomsection\\label{" .. entry.answer_label .. "}" ..
            "\\begin{quickquizanswerbox}{" ..
            "\\hyperref[" .. entry.question_label .. "]{\\textcolor{QEMUDark}{思考题 " ..
            entry.number .. "}}}{" .. entry.question_label .. "}"
        ),
    }

    append_blocks(blocks, entry.question)
    table.insert(blocks, pandoc.RawBlock("latex", "\\end{quickquizanswerbox}"))
    table.insert(blocks, pandoc.RawBlock("latex", "\\noindent\\textbf{参考答案：}"))
    append_blocks(blocks, entry.answer)
    table.insert(
        blocks,
        pandoc.RawBlock(
            "latex",
            "\\par\\hfill\\hyperref[" .. entry.question_label .. "]{\\quizopensquare}\\par\\medskip"
        )
    )
    return blocks
end


local function answer_appendix()
    local blocks = {}

    for _, chapter in ipairs(chapters) do
        if #chapter.quizzes > 0 then
            table.insert(
                blocks,
                pandoc.Header(
                    2,
                    pandoc.Inlines({pandoc.Str(chapter.title)})
                )
            )

            for _, entry in ipairs(chapter.quizzes) do
                append_blocks(blocks, answer_entry(entry))
            end
        end
    end

    return blocks
end


local function parse_quiz(element)
    if current_chapter == nil then
        error("quick-quiz must appear inside a numbered chapter")
    end

    local question = {}
    local answer = nil

    for _, block in ipairs(element.content) do
        if block.t == "Div" and has_class(block, "quick-answer") then
            if answer ~= nil then
                error("quick-quiz contains more than one quick-answer")
            end
            answer = block.content
        else
            table.insert(question, block)
        end
    end

    if #question == 0 then
        error("quick-quiz question is empty")
    end
    if answer == nil or #answer == 0 then
        error("quick-quiz must contain a non-empty quick-answer")
    end

    local quiz_number = #current_chapter.quizzes + 1
    local number = tostring(current_chapter.number) .. "." .. tostring(quiz_number)
    local question_label, answer_label = quiz_labels(current_chapter.number, quiz_number)
    local entry = {
        number = number,
        question = question,
        answer = answer,
        question_label = question_label,
        answer_label = answer_label,
    }

    table.insert(current_chapter.quizzes, entry)
    return inline_quiz(entry)
end


function Pandoc(document)
    local output = {}

    for _, block in ipairs(document.blocks) do
        if block.t == "Header" and block.level == 1 and not has_class(block, "unnumbered") then
            current_chapter = {
                number = #chapters + 1,
                title = pandoc.utils.stringify(block.content),
                quizzes = {},
            }
            table.insert(chapters, current_chapter)
            table.insert(output, block)
        elseif block.t == "Div" and has_class(block, "quick-quiz") then
            append_blocks(output, parse_quiz(block))
        elseif block.t == "Div" and has_class(block, "quiz-answers") then
            if answers_inserted then
                error("document contains more than one quiz-answers placeholder")
            end
            answers_inserted = true
            append_blocks(output, answer_appendix())
        else
            table.insert(output, block)
        end
    end

    local quiz_count = 0
    for _, chapter in ipairs(chapters) do
        quiz_count = quiz_count + #chapter.quizzes
    end
    if quiz_count > 0 and not answers_inserted then
        error("document has quick-quiz blocks but no quiz-answers placeholder")
    end

    document.blocks = output
    return document
end
