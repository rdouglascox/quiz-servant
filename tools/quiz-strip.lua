-- quiz-servant · remove every quiz panel
--
-- Builds a deck with no live quiz in it at all:
--
--     pandoc talk.md --lua-filter=tools/quiz-strip.lua \
--            --template=minpressive_basic.html -o talk-noquiz.html
--
-- (`make noquiz` does this for every slides/*.md.)
--
-- For handing slides out after the lecture, or printing them, where a panel
-- that says "Waiting for responses…" for ever is worse than no panel. Note
-- that the deck's own prose is untouched, so any sentence introducing a
-- question stays — read the result before circulating it.
--
-- See tools/quiz-offline.lua for the other direction: keeping the questions
-- but printing them on the slide instead of polling for answers.

function Div(el)
  if el.classes:includes('quiz') then
    return {} -- drop the block entirely
  end
end
