# Authoring quiz-servant panels — for an LLM working in a *different* repo

You are helping someone write a lecture deck (pandoc Markdown → HTML slides) in
a course repo that is not this one. The deck needs one or more live quiz
panels, backed by [quiz-servant](.) — a separate tool, checked out somewhere
else on this machine, referenced by absolute path from the course repo's build
script. You will not have this repo's source open. This file is what you need
instead.

If anything here conflicts with what you find in the course repo's own build
script (paths, filter order, existing conventions), **trust the build script**
— it is the ground truth for that repo, this file is background.

## The three ways a panel appears on a slide

**1. A question written into the deck** — the normal case. A fenced code
block *is* the question and *is* its own position on the slide:

````markdown
```quiz
key: trolley
type: choice
prompt: "Do you pull the lever?"
options:
  - { key: pull,    text: "Pull the lever" }
  - { key: refrain, text: "Do nothing" }
```
````

**2. A reference to a question defined in a standalone `.yaml`** — for a quiz
shared across decks:

```markdown
::: {.quiz question=trolley}
Waiting for responses…
:::
```

**3. The joining panel** — always this reference form, never a fence, because
it isn't a question (nothing to define, just somewhere to show the address):

```markdown
::: {.quiz question=join}
Waiting…
:::
```

**Default to form 1.** It's the right choice almost always: the deck and the
quiz can never drift apart, because they're the same file. Only reach for form
2 if the same quiz genuinely needs to appear in more than one deck.

⚠️ **If the course repo's build pipeline strips empty content before quiz
panels are filled in** — e.g. a filter that turns full lecture notes into
slides by deleting top-level paragraphs/divs that have nothing shown yet — a
form-2 `::: {.quiz question=…}` div can be **deleted before the quiz filter
ever sees it**, silently vanishing from the built deck with no error. A fenced
`quiz` block is immune to this, since it already carries visible content.
Check the build script's filter order before assuming form 2 will survive; if
in doubt, use form 1. (The join panel is exempt from this concern only for the
*offline* build, where it's meant to disappear — there's no server to join.)

## The YAML a fenced block or standalone file needs

Front matter, once per deck (or once per standalone file):

```yaml
quiz: ethics-week4        # stable slug — appears in slide/session URLs, [a-z0-9-]+
title: "Week 4 — Rights and constraints"
feedback: after_close     # none | after_close | immediate — whether/when students learn if they were right
```

Each question:

```yaml
key: transplant           # stable — appears in URLs, [a-z0-9-]+. "join" is reserved.
type: choice               # choice | multi | text | scale | grid
prompt: "Should the surgeon operate?"
```

| `type` | Extra fields | Notes |
|---|---|---|
| `choice` | `options:` (list of `{key, text}`), optional `correct: <key>` | pick one |
| `multi` | `options:`, optional `select: 1..3`, optional `correct: [a, b]` | checkboxes |
| `text` | optional `max_length:` (default 240) | free writing; always held back for the presenter to approve before it's projected |
| `scale` | `range: 1..5`, optional `labels:` (map of int → text) | one Likert item; label at least the endpoints |
| `grid` | `items:` (list of `{key, text}`), `range: 1..5`, optional `labels:` | several propositions rated on one shared scale; a poll, not a quiz — no `correct:`; slide shows the **mean per proposition**; students must rate every item |

Option/item **keys** are what gets recorded — never positions — so reordering
or rewording later doesn't corrupt existing data.

Full example, one of each type, is [`quiz_template.yaml`](quiz_template.yaml)
in this repo (commented-out except `choice`) and
[`examples/ethics-week3.yaml`](examples/ethics-week3.yaml) (all five, nothing
commented out).

## Two separate configuration knobs — don't conflate them

**`quiz:` in the front matter** is read directly from the deck's Markdown by
`quizctl push deck.md` / `quizctl validate deck.md` — the server-side identity
of the quiz. This is *not* what makes panels poll live; it only matters when
someone actually pushes the file.

**`quiz-base` / `quiz-slug` meta tags**, via `header-includes`, are what the
*browser* JS (`quiz-embed.html`) reads to know which server and which quiz to
poll for live results:

```yaml
header-includes: |
  <meta name="quiz-base" content="https://quiz-servant.fly.dev">
  <meta name="quiz-slug" content="ethics-week4">
```

A deck missing this builds fine and validates fine — the panels just sit on
"Waiting…" forever, silently, with no error anywhere. **If you write panels
into a deck meant to run live (not just offline/handout), add both.** If you
aren't sure whether the target build is the live one, ask, or add them anyway
— they're inert in an offline build.

## Checking your own work

If `quizctl` is on `PATH` (`which quizctl`), use it — it is the actual parser,
not a description of one:

```bash
quizctl validate path/to/deck.md
```

It reports every problem at once: duplicate keys, a `correct:` that isn't
among the options, scale labels outside `range:`, a missing `key:`/`type:`,
`join` used as a question key. Run it after editing and read the output —
don't assume the YAML is well-formed because it looks right.

If `quizctl` is *not* on `PATH`, say so explicitly rather than silently
skipping validation — that's a fact about this machine's setup the person you're
helping should know, not something to paper over.

## Things that fail quietly, so check them explicitly

- A `.quiz` div with no `question=` attribute, or a fence with no `key:`, is
  left as-is and only warns on the build's stderr — the panel visibly does
  nothing, easy to miss in a long build log.
- `join` cannot be used as an ordinary question key — reserved for the joining
  panel's path.
- A `grid` question that a student partially rates is rejected client-side
  ("please rate every one") — not a bug, by design.
- Slide/embed URLs name a quiz and a question but never a session, so nothing
  about the deck needs to change between semesters — only the pushed quiz
  behind it does.
