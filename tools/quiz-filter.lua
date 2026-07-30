-- quiz-servant · deck-side Lua filter
--
-- Turns
--
--     ::: {.quiz question=trolley}
--     Waiting for responses…
--     :::
--
-- into the <table data-quiz="trolley"> that tools/quiz-embed.html looks for,
-- with the div's own content as the placeholder row. Use question=join for
-- the joining-address panel.
--
--     pandoc talk.md --lua-filter=tools/quiz-filter.lua \
--            --template=minpressive_basic.html \
--            --include-after-body=tools/quiz-embed.html -o talk.html
--
-- (`make slides` already wires this in.)
--
-- The placeholder is not decoration: it is what shows before the first fetch,
-- what shows if JavaScript never runs, and — in minpressive — what gives the
-- table enough height to be recognised as a reveal step at all. See
-- tools/quiz-embed.html and DESIGN.md for why the container must be a
-- <table> rather than a <div>.

local function escape_html(s)
  return (s:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'))
end

function Div(el)
  if not el.classes:includes('quiz') then
    return nil -- an ordinary div; leave it alone
  end

  local question = el.attributes['question']
  if not question then
    io.stderr:write(
      "quiz-filter.lua: a .quiz div has no question=... attribute — " ..
      "write ::: {.quiz question=trolley} (or question=join)\n"
    )
    return nil -- fail visibly in the deck rather than emit a broken table
  end

  local placeholder = escape_html(pandoc.utils.stringify(el.content))
  if placeholder == '' then
    placeholder = 'Waiting for responses…'
  end

  local html = '<table data-quiz="' .. question .. '"><tbody>'
    .. '<tr><td>' .. placeholder .. '</td></tr>'
    .. '</tbody></table>'

  return pandoc.RawBlock('html', html)
end
