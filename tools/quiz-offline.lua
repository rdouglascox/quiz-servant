-- quiz-servant · print the questions on the slides instead of polling for them
--
-- Turns a live deck into one you can teach from with no server at all: each
-- quiz panel becomes the question itself, written out, to be answered by show
-- of hands. The joining panel goes entirely — there is nothing to join.
--
--     pandoc talk.md \
--            --metadata-file=my-quiz.yaml \
--            --lua-filter=tools/quiz-offline.lua \
--            --template=minpressive_basic.html -o talk-offline.html
--
-- (`make offline` does this for every slides/*.md.)
--
-- Questions written into the deck as ```quiz fences are read straight from the
-- fence. Panels placed by reference — ::: {.quiz question=key} — need the quiz
-- passed with --metadata-file, since the question is defined elsewhere.
--
-- Either way pandoc does the YAML parsing: a Lua filter has none of its own,
-- but front matter can be handed back to pandoc.read. The deck's own metadata
-- wins any clash, so its `title:` survives the quiz file's.
--
-- **Build this whenever you change a quiz, not when you need it.** Its whole
-- purpose is to exist already on the morning the network does not.

local utils = pandoc.utils

-- Parse a fence's YAML by wrapping it as front matter and reading it back.
local function fenceMeta(text)
  local ok, doc = pcall(pandoc.read, '---\n' .. text .. '\n---\n', 'markdown')
  if not ok then return nil end
  return doc.meta
end

-- Metadata values arrive as inline lists, plain strings, or numbers depending
-- on how they were written in the YAML. Normalise to inlines so a prompt that
-- uses *emphasis* survives rather than being flattened.
local function inlines(value)
  if value == nil then return {} end
  if type(value) == 'string' then return { pandoc.Str(value) } end
  if type(value) == 'table' and value.t == nil and value[1] ~= nil then
    return value -- already a list of inlines
  end
  return { pandoc.Str(utils.stringify(value)) }
end

local function text(value)
  if value == nil then return '' end
  return utils.stringify(value)
end

-- A muted aside, matching how the deck's own notes read.
local function note(str)
  return pandoc.Para { pandoc.Emph { pandoc.Str(str) } }
end

-- "1..5" -> "1", "5"
local function rangeParts(value)
  return text(value):match('^%s*(%-?%d+)%s*%.%.%s*(%-?%d+)%s*$')
end

-- "from 1 (Not at all) to 5 (Very)". Parenthesised rather than dashed so the
-- labels do not run into the numbers when the slide is read aloud.
local function rangePhrase(value, labels)
  local lo, hi = rangeParts(value)
  if not lo then return text(value) end
  local function point(n)
    local label = labels and labels[n]
    if label then return n .. ' (' .. text(label) .. ')' end
    return n
  end
  return 'from ' .. point(lo) .. ' to ' .. point(hi)
end

local function bullets(items, render)
  local out = {}
  for _, item in ipairs(items or {}) do
    table.insert(out, { pandoc.Plain(render(item)) })
  end
  return pandoc.BulletList(out)
end

-- Each question type, written out as something answerable by hand.
local function render(q)
  local blocks = { pandoc.Para { pandoc.Strong(inlines(q.prompt)) } }
  local qtype = text(q.type)

  local function add(b) table.insert(blocks, b) end

  if qtype == 'choice' or qtype == 'multi' then
    add(bullets(q.options, function(o) return inlines(o.text) end))
    if qtype == 'multi' and q.select then
      local lo, hi = rangeParts(q.select)
      if lo == hi then
        add(note('Choose exactly ' .. lo .. '.'))
      elseif lo then
        add(note('Choose ' .. lo .. ' to ' .. hi .. '.'))
      else
        add(note('Choose ' .. text(q.select) .. '.'))
      end
    end
  elseif qtype == 'scale' then
    -- Endpoints only. The full 1..5 as a list would be five reveal steps of
    -- bare numbers, which is noise on a slide you are talking over.
    add(note('Rate ' .. rangePhrase(q.range, q.labels) .. '.'))
  elseif qtype == 'grid' then
    add(bullets(q.items, function(i) return inlines(i.text) end))
    add(note('Rate each ' .. rangePhrase(q.range, q.labels) .. '.'))
  elseif qtype == 'text' then
    add(note('Free response.'))
  else
    -- A type this filter has not been taught about. Say so on the slide
    -- rather than silently dropping the question: this deck is the fallback,
    -- and a silently missing question is exactly what must not happen.
    io.stderr:write("quiz-offline.lua: unknown question type '" .. qtype .. "'\n")
    add(note('[' .. qtype .. ' question — see the quiz file]'))
  end

  return blocks
end

function Pandoc(doc)
  -- Index the questions once, by key.
  local byKey = {}
  for _, q in ipairs(doc.meta.questions or {}) do
    byKey[text(q.key)] = q
  end

  local blocks = doc.blocks:walk {
    -- A question defined where it is shown.
    CodeBlock = function(el)
      if not el.classes:includes('quiz') then return nil end
      local q = fenceMeta(el.text)
      if q and q.key then return render(q) end
      io.stderr:write('quiz-offline.lua: could not read a ```quiz fence\n')
      return note('[unreadable question]')
    end,

    -- A panel placed by reference, resolved against --metadata-file.
    Div = function(el)
      if not el.classes:includes('quiz') then return nil end

      local key = el.attributes['question']
      if key == 'join' then
        return {} -- nothing to join when there is no server
      end

      local q = byKey[key or '']
      if q then return render(q) end

      -- Named a question the quiz file does not define — or no quiz file was
      -- passed at all. Loud on both counts, for the same reason as above.
      io.stderr:write(
        "quiz-offline.lua: no question '" .. tostring(key) ..
        "' in the quiz metadata (did you pass --metadata-file?)\n"
      )
      return note('[missing question: ' .. tostring(key) .. ']')
    end,
  }

  return pandoc.Pandoc(blocks, doc.meta)
end
