# quiz-servant

Live quizzes for lectures, in about as little machinery as the job allows.

Write a quiz as YAML. Push it with a CLI. Students answer on their phones at a
short URL. Results appear on your slides as they arrive, in your deck's own
fonts and colours. Afterwards you pull the responses down as JSONL.

No accounts, no database, no websockets, no JavaScript build. Students are
anonymous, and the data is expected to be short-lived.

For *why* it is built this way — and for the mistakes already made and paid
for — see [DESIGN.md](DESIGN.md).

---

## Contents

- [Quick start](#quick-start)
- [Writing a quiz](#writing-a-quiz)
- [Running a lecture](#running-a-lecture)
- [Putting results on slides](#putting-results-on-slides)
- [`quizctl` reference](#quizctl-reference)
- [Deploying](#deploying)
- [Data and privacy](#data-and-privacy)
- [Troubleshooting](#troubleshooting)

---

## Quick start

You can run the whole thing on your laptop — no account, no hosting, nothing to
pay for. Deploying comes later, and only when you want students on their own
phones.

Requires GHC 9.10.3 and stack (snapshot `lts-24.12`); pandoc too, if you want
slides.

```bash
stack install
```

`stack install` rather than `stack build`, so `quizctl` and `quiz-servant` land
on your `PATH`. **If you rebuild after changing anything, run it again** — a
stale `quizctl` fails in confusing ways, typically by rejecting a question type
it is too old to know about.

### 1. Write and check a quiz

`validate` needs no server, so this works before anything is running:

```bash
quizctl validate examples/ethics-week3.yaml
```

It reports *every* problem at once rather than stopping at the first. Add
`--html preview.html` to eyeball the questions in a browser.

### 2. Start a server

In its own terminal:

```bash
QUIZ_ADMIN_TOKEN=dev \
QUIZ_LOG=/tmp/quiz.jsonl \
QUIZ_BASE_URL=http://localhost:8080 \
  quiz-servant
```

### 3. Point the CLI at it

```bash
export QUIZ_URL=http://localhost:8080
export QUIZ_TOKEN=dev
```

For a real deployment, put these in files instead so every shell picks them up:

```bash
mkdir -p ~/.config/quizctl
echo "https://your-app.fly.dev" > ~/.config/quizctl/url
echo "<the admin token>"        > ~/.config/quizctl/token
chmod 600 ~/.config/quizctl/token
```

### 4. Run a quiz

```bash
quizctl push examples/ethics-week3.yaml
quizctl session ethics-week3 --label "2026 S2 W3"
```

That prints everything the lecture needs: the join code, the student URL, the
slide URL, your presenter link, and a QR code you can scan **straight from the
terminal** to check the join flow before class.

Open the presenter link, press **Open** on a question, and answer it yourself
at the student URL. Then:

```bash
quizctl pull --out week3.jsonl
```

When you want students on their own phones rather than just your laptop, see
[Deploying](#deploying).

---

## Writing a quiz

Start from [`quiz_template.yaml`](quiz_template.yaml), which carries a
commented-out example of every question type with notes on each:

```bash
cp quiz_template.yaml phil201-week3.yaml
```

It is a valid one-question quiz as it stands, so you can `validate` and `push`
it immediately to see the tooling work, then uncomment whichever types you
need. For a complete quiz with nothing commented out, see
[`examples/ethics-week3.yaml`](examples/ethics-week3.yaml).

A quiz is one YAML file. It is the source of truth: nothing is ever edited on
the server, and pushing the same file twice is harmless.

```yaml
quiz: ethics-week3          # stable slug — appears in slide URLs
title: "Week 3 — Consequentialism"
feedback: after_close       # none | after_close | immediate

questions:
  - key: trolley            # stable — appears in slide URLs
    type: choice
    prompt: "Do you pull the lever?"
    options:
      - { key: pull,    text: "Pull the lever" }
      - { key: refrain, text: "Do nothing" }
      - { key: unsure,  text: "I don't know" }
```

`quiz` and every `key` must match `[a-z0-9-]+`, because they appear in URLs.
**`join` is reserved** — the join panel occupies that path.

### Question types

| `type:` | Fields | Notes |
| --- | --- | --- |
| `choice` | `options:`, optional `correct: <key>` | One answer |
| `multi` | `options:`, optional `select: 1..3`, optional `correct: [a, b]` | Checkboxes |
| `text` | optional `max_length:` (default 240) | Always moderated before display |
| `scale` | `range: 1..5`, optional `labels:` | Likert; labels keyed by integer |
| `grid` | `items:`, `range: 1..5`, optional `labels:` | One scale applied to several propositions |

```yaml
  - key: which-consequentialist
    type: multi
    prompt: "Which of these claims are consequentialist?"
    select: 1..3
    correct: [outcomes, aggregate]
    options:
      - { key: outcomes,  text: "An act is right if it produces the best outcome" }
      - { key: duty,      text: "Some acts are wrong whatever their effects" }
      - { key: aggregate, text: "We should maximise total welfare" }

  - key: define-utility
    type: text
    prompt: "In one sentence, what does 'utility' mean here?"
    max_length: 200

  - key: confidence
    type: scale
    prompt: "How confident are you?"
    range: 1..5
    labels:
      1: "Not at all"
      5: "Very"

  - key: how-compelling
    type: grid
    prompt: "How compelling do you find each of these objections?"
    range: 1..5
    labels:
      1: "Not at all"
      5: "Very"
    items:
      - { key: demandingness, text: "It asks too much of ordinary people" }
      - { key: rights, text: "It permits sacrificing an innocent" }
```

A `grid` is a poll rather than a quiz: it has no correct answer, and it rates
several propositions on one shared scale. The slide shows the **mean per
proposition**, so the room can rank them against each other at a glance. That
deliberately hides disagreement — an evenly split room and an indifferent one
both average to the middle — so use it to compare propositions, not to find
out whether the room agrees with itself.

Students must rate every proposition. A partial grid would give each row a
different denominator, and nothing on the slide would say so.

Option **keys** are what get recorded, never positions — so you can reorder or
reword options later without corrupting last year's data.

`feedback:` controls whether students learn if they were right: `none`,
`after_close` (the default), or `immediate`.

### Checking it

```bash
quizctl validate examples/ethics-week3.yaml
quizctl validate examples/ethics-week3.yaml --html preview.html
```

Validation reports *every* problem at once — duplicate keys, correct answers
that are not options, scale labels outside the range — rather than stopping at
the first. `--html` renders a static preview with no server involved, which
doubles as your fallback if the server is unreachable mid-lecture.

`push` runs the same checks, so nothing invalid can leave your machine.

---

## Running a lecture

Before class:

```bash
fly status                     # deployed only: confirm exactly one machine
quizctl push slides/ethics-week3.yaml
quizctl session ethics-week3 --label "2026 S2 W3"
```

The `push` also wakes a sleeping server, so no student meets a cold start
(~1.4s). Skip the `fly status` line when running locally — but do not skip it
when deployed; see [the two rules](#two-rules).

During class, drive it from the **presenter page** — the secret URL printed by
`session`. It has one obvious control per question: Open, Close, Reveal answer,
Reopen. Free-text answers appear there held back, each with a Show button;
nothing reaches the projector unread.

**Never put the presenter URL on the projector.** The page says so in a red
banner, because the secret is the entire authentication.

Everything the page does is also available from the CLI, if you would rather
not alt-tab:

```bash
quizctl open trolley
quizctl close trolley
quizctl reveal which-consequentialist
quizctl status
```

Afterwards:

```bash
quizctl pull --out week3.jsonl
```

Worth doing promptly while the lecture is fresh — though nothing expires on its
own; see [Data and privacy](#data-and-privacy).

### Multiple cohorts

Exactly one session is live server-wide, and creating one makes it live.
Starting week 4's session supersedes week 3's, but nothing is discarded —
`quizctl sessions` lists every session with its presenter link, and reactivating
an old one restores its tallies for a make-up class.

---

## Putting results on slides

Slides fetch a fragment and inject it, so panels inherit your deck's
typography, scale, theme, and — in a reveal-based deck — its build.

Wire in the script and the filter once, per deck:

```bash
pandoc talk.md \
       --lua-filter=tools/quiz-filter.lua \
       --template=minpressive_basic.html \
       --include-after-body=tools/quiz-embed.html -o talk.html
```

or just `make slides`, which does that for every `slides/*.md`.

Configure it in the deck's metadata block:

```yaml
---
title: "Week 3 — Consequentialism"
header-includes: |
  <meta name="quiz-base" content="https://quiz-servant.fly.dev">
  <meta name="quiz-slug" content="ethics-week3">
---
```

Then drop a panel wherever you want results, naming a question key — or `join`
for the joining address — as a fenced div:

```markdown
::: {.quiz question=trolley}
Waiting for responses…
:::
```

`tools/quiz-filter.lua` turns that into the `<table data-quiz="trolley">` the
embed script looks for, using the div's own content as the placeholder row —
no HTML to hand-write in the deck at all. A `.quiz` div with no `question=`
attribute is left untouched and warns on stderr during the build, rather than
silently producing a panel that never does anything.

If you would rather not run the filter, the equivalent by hand is:

```html
<table data-quiz="trolley"><tbody>
  <tr><td>Waiting for responses…</td></tr>
</tbody></table>
```

Either way, the placeholder is not decoration: it is what shows before the
first fetch, what shows if JavaScript never runs, and what gives the table
enough height to be recognised as a reveal step.

Slide URLs name a quiz and a question but **never a session**, so a deck is
written once and runs every year the unit is taught.

The `question=join` panel — primarily what students use — includes a QR code
for the join address alongside the text, so a phone can scan rather than type.
It is plain inline SVG, coloured with the deck's own ink, so it follows light
and dark themes the same way the tally bars do and needs no image file or
external request.

`tools/quiz-embed.html` ships a default stylesheet — bars drawn from a `--pct`
the server sets — which you can edit or delete. The server sends structure and
numbers only.

### If your deck cannot run JavaScript

`GET /embed/<slug>/<question>` returns a whole page suitable for an `<iframe>`,
for contexts that accept nothing else, such as an LMS. It cannot inherit the
surrounding page's styling, and in a reveal-based deck it will show results
before you reach them.

### Checking a lecture machine

Locked-down machines and university networks vary. Upload
`tools/embed-check.html` to wherever you host slides and open it on the lectern:
it tests reachability, CORS, framing, and CSP, and tells you which techniques
survive.

---

## `quizctl` reference

| Command | Does |
| --- | --- |
| `validate FILE [--html OUT] [--json OUT]` | Check a quiz; optionally render a preview |
| `push FILE` | Validate, then send to the server |
| `session SLUG [--label L]` | Create a session and make it live |
| `open QUESTION` | Start accepting answers |
| `close QUESTION` | Stop accepting answers |
| `reveal QUESTION` | Close and disclose the correct answer |
| `status` | The live session and its questions |
| `sessions` | Every session, with presenter links |
| `pull [--out FILE]` | Download the response log as JSONL |
| `clear [--yes]` | **Delete** every session, response and pushed quiz |

Server location and token come from `QUIZ_URL` / `QUIZ_TOKEN`, falling back to
`~/.config/quizctl/url` and `~/.config/quizctl/token`.

---

## Deploying

The app runs on fly.io as a single machine with a small volume, costing roughly
**$0.45/month** with auto-stop between lectures.

```bash
fly apps create quiz-servant
fly volumes create quiz_data --size 1 --region syd

mkdir -p ~/.config/quizctl
openssl rand -hex 24 > ~/.config/quizctl/token
chmod 600 ~/.config/quizctl/token
fly secrets set QUIZ_ADMIN_TOKEN="$(cat ~/.config/quizctl/token)"

fly deploy --remote-only
fly scale count 1
fly status
```

Pushing to `main` also deploys, via GitHub Actions.

### Two rules

**Exactly one machine.** `fly deploy` provisions two by default. State is
machine-local, so two machines split the room in half — students answer into a
world the projector is not showing, with nothing visibly broken. Re-check
`fly status` after any deploy.

**Never deploy during a lecture.** The volume survives, but the machine is gone
for a minute or two.

### Server configuration

| Variable | |
| --- | --- |
| `QUIZ_ADMIN_TOKEN` | **Required.** Bearer token for `/api/*`; also derives the form-signing key |
| `QUIZ_LOG` | Path to the JSONL log. **Must be on a volume** — a Fly rootfs does not survive stop/start |
| `QUIZ_BASE_URL` | Public origin, so the join panel can print a typable URL |
| `PORT` | Defaults to 8080 |

---

## Data and privacy

**Students are completely anonymous.** No accounts, no names, no server-side
pseudonyms. A response is `(session, question, answer, timestamp)` and nothing
more.

Consequences worth understanding before you rely on this:

- **The number on screen is *responses*, not *students*.** Nothing
  distinguishes thirty students answering once from three answering ten times.
- **Ballot-stuffing is possible.** Post-redirect-get prevents accidental
  double submission and signed form tokens prevent stale replay, but a
  determined student can vote twice. Closing questions promptly is the real
  defence. This is a lecture, not an election.
- **You can never analyse individuals.** Per-question distributions, timing,
  drop-off, and cohort-vs-cohort comparison are available. Individual
  trajectories and per-student participation are not, and adding them would be
  a new promise to your students as much as a schema change.
- **Free text is anonymous and projected**, so it is held back until you
  approve each answer.

**Nothing expires on its own.** Responses live on a volume that survives
restarts *and* redeploys, and there is no retention policy or rotation. They
accumulate across every lecture until you remove them, and `quizctl pull` only
downloads a copy — it deletes nothing.

To actually remove them:

```bash
quizctl pull --out week3.jsonl   # keep a copy first; clear cannot be undone
quizctl clear
```

`clear` asks you to type `clear` to confirm, having first told you how much is
about to go. `--yes` skips the prompt, for a script or a cron job.

It leaves the server blank, exactly as if it had just booted for the first
time. Gone: every pushed quiz, every session — including old ones you could
otherwise reactivate — every response, and the log itself.

**Nothing local is touched.** Your YAML files are the source of truth and stay
on your machine, along with any `quizctl pull` copies and your slide decks. So
recovery is the ritual you run before each lecture anyway:

```bash
quizctl push examples/ethics-week3.yaml
quizctl session ethics-week3 --label "2026 S2 W3"
```

Two things to expect:

- **Every existing join code and presenter link stops working.** A new session
  means a new code and a new secret. Your decks need no editing, since embed
  URLs never name a session — but a QR already on screen is stale until you
  start one.
- **There is no partial clear.** You cannot drop responses and keep quizzes:
  the log is append-only, so preserving some events would mean rewriting
  history rather than discarding it. `push` is idempotent and cheap precisely
  so this is not a problem.

If you have told students their answers are short-lived, this is the command
that makes that true. Nothing runs it for you.

---

## Troubleshooting

**A command fails in a way that makes no sense** — a question type "expected
choice, multi, text, or scale", or `sessions` reported as an unknown command.
Your installed `quizctl` is older than your checkout. Run `stack install`.

**Students see "Nothing running."** No session is live, or the join code is
from an older one. `quizctl status`.

**A slide says "Not live."** The live session belongs to a different quiz — or
none is running. This is deliberate and loud: if the wrong deck is projected,
the room should be able to tell you.

**Panels stay on "Waiting for responses…".** In a reveal-based deck, polling
only starts once the panel is revealed. If it persists after that, run
`tools/embed-check.html` on that machine.

**Tallies look wrong or too low.** Check `fly status` for a second machine.

**A student says "please rate every one."** A `grid` requires every
proposition to be rated — see [Question types](#question-types) for why.

**"That form did not come from this server."** The admin token changed, which
invalidates outstanding form tokens. Students need only reload.

**`quizctl` says the server is unreachable.** Check `~/.config/quizctl/url`,
and that `fly status` shows a started machine.
