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

-- Parse the YAML in a fence by handing it back to pandoc as front matter.
-- A Lua filter has no YAML parser of its own, but pandoc does, and this is the
-- only way to reach it from here.
local function fence_meta(text)
  local ok, doc = pcall(pandoc.read, '---\n' .. text .. '\n---\n', 'markdown')
  if not ok then return nil end
  return doc.meta
end

local function escape_html(s)
  return (s:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'))
end

-- ```quiz fences define the question where it is shown, so the deck and the
-- quiz cannot drift apart. The placeholder is ours rather than the author's,
-- since the fence body is the question itself.
function CodeBlock(el)
  if not el.classes:includes('quiz') then
    return nil
  end

  local meta = fence_meta(el.text)
  local question = meta and meta.key and pandoc.utils.stringify(meta.key) or nil
  if not question or question == '' then
    io.stderr:write(
      "quiz-filter.lua: a ```quiz fence has no `key:` — cannot place its panel\n"
    )
    return nil
  end

  return pandoc.RawBlock(
    'html',
    '<table data-quiz="' .. question .. '"><tbody>'
      .. '<tr><td>Waiting for responses…</td></tr>'
      .. '</tbody></table>'
  )
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
