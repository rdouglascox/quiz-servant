# quiz-servant — design

A deliberately small alternative to Mentimeter for lectures. Quizzes are
authored locally as YAML, pushed to a server with a CLI, and answered by
students on a plain HTML page. Results appear live on the lecture slides.

This file records decisions and, more importantly, why they were made — so that
a future change knows what it is trading away.

## The load-bearing idea

**Presenter state lives on the server; every client is a dumb poller; every
student action is a plain `<form method=POST>`.**

That single choice removes websockets, SSE, a JS build step, and client-side
state management. A phone submitting an answer is a form POST returning a
"thanks" page — no JS required, works on any device. Live-ness is a
2-second `location.reload()` inside an iframe.

## Decisions

### Students are fully anonymous

No identity is stored: no accounts, no names, no server-side pseudonyms. A
response is `(session, question, answer, timestamp)` and nothing more.

Consequences, accepted deliberately:

- **No deduplication.** The number on the projector is *responses*, not
  *students*. Nothing distinguishes 30 students answering once from 3 students
  answering ten times. Label it honestly.
- **Ballot stuffing is possible.** Mitigations are cheap and partial: POST →
  303 → terminal page (kills accidental refresh-resubmit), an HMAC-signed
  hidden form token carrying `(session, question, issued-at)` (kills stale and
  cross-question replay, needs no server state), and closing questions
  promptly, which is the real defence. A determined student can still stuff the
  ballot. This is a lecture, not an election.
- **No per-IP rate limiting**, or only an extremely generous one. A lecture
  theatre is behind one NAT; a naive per-IP limit locks out the whole room.
- **"Which questions have I answered?" is browser-local only** — a
  `localStorage` flag per question, never sent to the server. It is a boolean
  in the student's own browser, not a pseudonym, so it cannot be joined to
  anything.
- **Analytics are bounded.** Available: per-question distributions, response
  timing, drop-off across a lecture, cohort-vs-cohort comparison of the same
  quiz. Permanently unavailable: individual trajectories, per-student
  participation, "did students who missed Q1 also miss Q4". Changing this is a
  schema migration *and* a new promise to students.

### Free-text answers are moderated before display

Anonymous free text projected on a lecture screen needs an approval step.
Text responses default to hidden; the presenter promotes each one into the
embed. Choice/multi/scale auto-project safely because the answer space is
closed.

### The presenter opens and closes questions

Hybrid pacing: the presenter opens and closes individual questions, and the
student page shows whatever is currently open, refreshing every few seconds.
Same implementation as strict one-at-a-time pacing, but it also supports "here
are three questions, take five minutes", and it degrades sanely if a question
is left open.

### Data is ephemeral; there is no database

Responses that are not pulled shortly after the lecture are expected to be
lost. That permits:

- **No SQLite and no migrations.** The schema can be reshaped freely and
  redeployed.
- Live state is an in-memory value behind a `TVar`; STM handles concurrent
  increments.
- Every response is also appended to a JSONL file. **The storage format is the
  export format** — `quizctl pull` downloads the file, and JSONL drops straight
  into jq, pandas, or R.

The log is not for archival durability. Its job is to survive an auto-stop
*within* a lecture: pure in-memory state would vanish if the machine idled out
during twenty minutes of non-quiz slides, taking the session and every answer
so far with it.

**That requires a volume, and this was originally got wrong.** The first
design put the log on the machine rootfs, on the assumption that Fly preserves
it across stop/start. It does not. Verified on the deployed app: after an
auto-stop the server came back logging `starting from an empty log` and a
lecture's responses were gone. A 1GB volume mounted at `/data` fixes it for
$0.15/month, and the fix is verified the same way — a stop/start now logs
`replayed 9 event(s)` and the tallies come back intact.

Never assert this property again without testing it: seed some responses,
`fly machine stop` then `start`, and check the boot log says `replayed`.

**Ephemerality does not permit more than one instance.** State is
machine-local either way, so two machines would serve two different tallies to
two halves of the room. Exactly one machine, `strategy = "immediate"`, no
autoscaling. The constraint was never the disk — it is state locality.

### Quiz and session are distinct

A *quiz* is the authored artifact; a *session* is one delivery of it to one
cohort. The same lecture runs in 2026 and 2027 and the responses must not
mingle.

**Exactly one active session server-wide.** Activating a session deactivates
any other. Embed URLs carry the quiz slug and question key but no session id,
which is the simplification that lets slides be authored once and run for
years.

Consequences of global rather than per-quiz scope:

- **An embed whose slug is not the active session's must render a visible "not
  live" panel** — never a blank space, and never the active session's numbers
  under the wrong slide. If the wrong deck is projected, the room should see
  "not live" and say so. Note that since slide embeds are unstyled (below),
  that warning is carried by the words alone, not by anything alarming to look
  at.
- Two quizzes cannot be live at once, so back-to-back units need an explicit
  activation between them. The "not live" panel is what makes forgetting
  survivable.
- Sessions are kept in memory as `Map SessionId SessionState` with a single
  `active :: Maybe SessionId`. Deactivating never discards anything, so
  re-activating an earlier session for a make-up class restores its tallies.
  A lecture's worth of responses is small enough that retaining all of them
  costs nothing.

### Student pages are styled; slide embeds are not

Two audiences, opposite needs, so two stylesheets and no shared layout beyond
the document shell.

**Student pages get proper styling.** Students meet them on their own phone or
laptop, in a dark room, in a hurry. Large tap targets with the whole row as the
label, an obvious selected state, visible focus rings for keyboard users, and a
readable measure.

**Slide embeds set no fonts, sizes, or colours.** The deck owns presentation
entirely; the server sends structure and numbers.

Presenter pages are styled too, but for a different reason: information density
on a lectern laptop.

### Decks fetch a fragment; they do not frame one

`GET /embed/:slug/:question/frag` returns bare `<tr>` rows — no document, no
styles. The deck owns a `<table data-quiz="…">` and a small script swaps the
rows in. `tools/quiz-embed.html` is that script, included with
`--include-after-body`.

This replaced an iframe, which turned out to be **functionally broken** against
minpressive, the deck framework in use:

- **It defeats the reveal engine.** minpressive hides un-revealed blocks with
  `color: rgba(0,0,0,0)`. Inheritance stops at a document boundary, so a framed
  panel stays lit while everything around it is blank — results on screen
  before you reach them. Injected rows inherit the colour and reveal correctly.
- **It ignores the deck's scale.** `html { font-size: clamp(20px, 2.3vw, 40px) }`
  with everything else in em/rem. A framed document restarts at 16px, so on a
  projector the panel is a quarter the size of the text beside it.
- **Fixed heights in a fluid layout**, and a full-document reload every refresh.

The whole-document form at `/embed/:slug/:question` is kept for contexts that
accept nothing else — an LMS embed, say.

Three details that are load-bearing rather than cosmetic:

- **The container is a `<table>`.** It is both in minpressive's transparent-ink
  selector and in its `STEP_TAGS`, so it participates in the reveal. `<figure>`
  is in `STEP_TAGS` but *not* the colour selector, so its contents would leak
  early; nesting the two makes one panel consume two clicks.
- **The placeholder row must be there.** minpressive computes its steps once at
  load and rejects zero-size elements, so an empty container never becomes a
  step and never reveals. It is also the no-JS fallback.
- **Bars are painted in `currentColor`**, mixed toward transparent. A literal
  colour would be visible before its step; `currentColor` is transparent until
  revealed and then inherits the deck's ink, so it works in light and dark
  without knowing which it is.

`join` is a reserved question key — the join panel occupies that path.
`Quiz.Validate` rejects it rather than letting it silently shadow.

### A Lua filter removes the boilerplate

`tools/quiz-filter.lua` turns

```
::: {.quiz question=trolley}
Waiting for responses…
:::
```

into the `<table data-quiz="trolley">` above, using the div's own content as
the placeholder row. This exists purely to avoid hand-writing HTML in an
otherwise all-Markdown deck; it changes nothing about the wire format or the
server. A `.quiz` div with no `question=` attribute is left as an ordinary div
and warns on stderr during the pandoc build — silently emitting a panel that
would never do anything seemed worse than a noisy build.

`make slides` wires the filter in; by hand it is
`pandoc --lua-filter=tools/quiz-filter.lua ...`, ahead of `--template` so the
transform runs before the document is otherwise assembled.

### QR codes, rendered rather than fetched as images

The join panel — the one students actually use — carries a QR code for the
join address alongside the text. `Quiz.Qr` wraps `qrcode-core`, which hands
back only a bit matrix, and nothing more is pulled in: no image codec, no PNG.

Two renderers, from the same matrix:

- **Inline SVG** (`qrSvg`), used by both the whole-document join embed and the
  injected fragment. Modules are filled with `currentColor` — the same trick
  as the tally bars — so the code inherits the deck's ink and needs no
  light/dark handling of its own. A dark deck yields light-on-dark modules,
  which scanners read exactly as readily as the reverse. An `<img>` pointing
  at a rendered PNG could not do this any more than an iframe could; that is
  precisely the problem the rest of this server's embedding was built to
  avoid, and it would have been an odd place to reintroduce it.
- **Unicode half-blocks** (`qrAnsi`), for `quizctl session` to print directly
  in the terminal — a way to test the join flow, or to hold up a laptop screen
  in front of a room, before any slide is open. Two module rows share one
  character row (▀▄█ and space), since a terminal cell is about twice as tall
  as it is wide. No ANSI colour codes: a dark module is the terminal's default
  foreground, a light module is a plain space, so it reads correctly in both
  light and dark terminal themes without asking which — the same policy as
  the SVG, carried into a different medium.

An un-sized `<svg>` defaults to a 300×150 box in most browsers, which would
squash the code into an unscannable rectangle. The `.quiz-qr` `aspect-ratio: 1`
rule in `embedCss` is therefore structural, not decorative — the minimum
needed for the code to render as a QR code at all — unlike everything else in
that stylesheet, which is deliberately silent on sizing.

The QR always encodes the join URL *with* its scheme (`joinFullUrl`), unlike
the text beside it (`joinUrl`), which drops the scheme because it is meant to
be read aloud. A reader needs an actual URI to offer opening it as a link
rather than running the text through a search.

Verified by decoding the server's actual rendered SVG with a real QR reader
(Chrome's `BarcodeDetector`) rather than trusting the pattern by eye: it
returned the exact join URL. The terminal and SVG renderers consume the same
matrix from the same encoding call, so that one check covers both.

### Matching minpressive's own look

`tools/quiz-embed.html`'s stylesheet targets the injected fragment
specifically — the whole-document `/embed/...` pages (`Quiz.Server.Html`'s
`embedCss`) are a separate, deliberately plain stylesheet for the iframe
fallback, and are not this.

Because a fragment is injected into a `<table>` the deck already owns, most of
"matching the deck's look" happens for free by inheritance — confirmed by
inspecting the actual computed styles in a real minpressive build rather than
assuming it: the injected cells came back `font-family: Times` (minpressive
sets none itself, so both templates' choice of serif/Gill Sans passes straight
through), `border-radius: 0` (minpressive uses none anywhere — every rounded
corner in this project belongs to the *student*-facing pages, a different
stylesheet with a different job), and the `<tbody>` picked up minpressive's
own top/bottom ink-coloured rule with no extra CSS at all. The QR's square
sizing is likewise already handled by minpressive's own blanket
`svg { height: auto; max-width: 100% }` rule, which fixes the classic
unsized-SVG-defaults-to-300×150 problem — nothing needed there either. Neither
`_basic` nor `_fancy` supports a dark theme (both hardcode a light "paper"
palette), which is why `currentColor`-relative tints are used throughout
rather than that being a light/dark concession.

Two things were not free, and are what this stylesheet actually adds:

- **"Correct" needs a second signal.** Bold weight alone reads as noise at
  lecture-room distance, and this is the one property where reveal timing
  matters — an `.is-correct` fill of a literal colour would show through
  before its step, so it has to stay `currentColor`-based like the base tint.
  The fix is more of the same device rather than a different one: 38% tint
  instead of the base 18%, alongside the bold. Verified by forcing the
  ancestor's ink colour and reading back the resolved `background-image` — the
  two are 0.18 vs 0.38 alpha, clearly distinct, still monochrome.
- **A free-text answer is, structurally, a quotation.** It gets minpressive's
  own device for one — a left rule — rather than sitting as undecorated
  italic. `currentColor`-relative rather than minpressive's literal `#e6e6e6`,
  so it stays correct if a deck ever uses a template with a different palette.
  The rule has to live on the `<td>`, not the `<tr>` that actually carries the
  `quiz-text` class: a border-left on a table row is not reliably rendered
  under the default (non-collapsed) table border model minpressive uses,
  where a table-cell border always is. Caught by checking the rendered border
  computed to zero-alpha until retargeted — not visible by inspection, since
  the row and cell occupy the same space either way.

### Cross-origin

The `/embed` endpoints send `Access-Control-Allow-Origin: *` so a deck hosted
anywhere can read them. Scoped to `/embed`: those responses are already public
and unauthenticated, so letting a script read what a person could read anyway
grants nothing. The admin API gets no such header.

Whether this survives a locked-down lecture machine is a question about that
environment, not one to reason about — `tools/embed-check.html` tests
reachability, CORS, framing, and CSP and reports which techniques work. Run it
on the lectern before relying on any of this.

### Option keys, never indices

Responses record the option *key* from the YAML. Options can then be reordered
or reworded without silently corrupting last year's data.

### YAML is the source of truth

Nothing is ever edited server-side. `push` is idempotent. Quiz definitions live
in memory on the server, having arrived by push — consistent with the fact that
they are ephemeral too, and re-pushing is part of the pre-lecture ritual
anyway.

### Parse permissively, validate strictly

`Quiz.Parse` accepts anything structurally well-formed. `Quiz.Validate` reports
every semantic problem at once — duplicate keys, correct answers that are not
options, out-of-range scale labels — so one `quizctl validate` run surfaces all
of them rather than the first.

FromJSON instances are hand-written, not derived: aeson's generic sum encoding
produces YAML no human wants to author, and hand-rolling lets errors name the
offending question.

## Question types (v1)

| YAML `type:` | Meaning |
| --- | --- |
| `choice` | Single answer, optional `correct:` |
| `multi` | Checkboxes, optional `select: 1..3` and `correct: [...]` |
| `text` | Free text, `max_length:`, always moderated |
| `scale` | Likert, `range: 1..5`, optional integer-keyed `labels:` |

## Routes

| Group | Auth | Routes |
| --- | --- | --- |
| Student (HTML) | none | `GET /s/:code`, `GET/POST /s/:code/:qkey`, `GET /s/:code/:qkey/done` |
| Embed (HTML, for slides) | none | `GET /embed/:slug/join`, `GET /embed/:slug/:qkey` |
| Presenter (HTML) | secret URL | `GET /p/:secret`, `POST /p/:secret/{open,close,reveal}/:qkey`, `POST /p/:secret/text/:id/{show,hide}`, `POST /p/:secret/activate` |
| Admin (JSON) | bearer token | `PUT /api/quiz`, `POST /api/session`, `POST /api/session/:id/activate`, `GET /api/session/:id/responses` |

The presenter URL is a secret, so it must never appear on the projector. The
presenter page should say so.

Presenter controls use post-redirect-get, since the page also auto-refreshes.

## Operating model

Semester-long app with auto-stop enabled (~$0.30/month; always-on is ~$3.50).
The cold start is absorbed by a command that runs anyway:

```bash
# before the lecture — also wakes the machine, and prints the join code
fly status                        # confirm exactly one machine
quizctl push examples/ethics-week3.yaml && quizctl session ethics-week3 --label "2026 S2 W3"

# after the lecture
quizctl pull > week3-responses.jsonl
```

At the end of semester, `fly scale count 0` or destroy the app.

## Toolchain

- **stack**, `snapshot: lts-24.12` (GHC 9.10.3, matching the local toolchain).
  Chosen over cabal because Stackage snapshots give a co-tested dependency set
  for free, and because hpack's module globbing keeps the Docker dependency
  layer stable when modules are added — with a hand-written `.cabal`, adding a
  module invalidates it and costs a full dependency rebuild.
- `lucid` (not `lucid2`) for HTML, because `servant-lucid` targets `lucid` and
  both packages export a module named `Lucid`.
- `ReaderT Env Handler` via `hoistServer`. No effect system.
- Deployment: multi-stage Dockerfile → GHCR via GitHub Actions with a
  **registry-backed** layer cache (not `type=gha`, whose entries expire after 7
  days of inactivity — precisely a lecture-app cadence) → `fly deploy --image`.

Measured on the full dependency set (arm64, local):

| Layer | Time |
| --- | --- |
| `stack build --only-dependencies` | **1070s (~18 min)** |
| `stack install` (application code) | **9.8s** |
| Final image | 246MB |

That 100:1 ratio is the entire justification for the two-stage split, and for
insisting on a cache that does not expire. An 18-minute cold build is not
something to discover twenty minutes before a lecture.

## Footguns already paid for

Keep these; they were found the hard way.

- **Locale encoding.** GHC derives its default encoding from the locale, so a
  container with no `LANG` gets ASCII and dies with `commitBuffer: invalid
  argument` on the first em dash. Quiz titles, prompts, and student free-text
  answers are full of dashes, curly quotes, and emoji, so this would have
  crashed the response handler mid-lecture, not merely garbled a CLI message.
  Fixed twice over: `Quiz.Encoding.forceUtf8` must be the first action in every
  `main`, and the image sets `LANG=C.UTF-8`.
  **A container run is the only thing that catches this** — a Mac shell has a
  UTF-8 locale, so tests and local runs pass regardless.
- **Never hold the response log open.** GHC locks files per process, so a
  `Handle` kept open in `AppendMode` makes `readFile` on the same path throw
  `resource busy` — which silently breaks `GET /api/log`, and therefore
  `quizctl pull`, the one operation that must never fail. The store reopens the
  file for each append instead; at a few hundred writes per lecture the cost is
  irrelevant. There is a regression test for this.
- **`stack -j` needs an argument**, unlike cabal's bare `-j`. Stack already
  parallelises across cores, so just omit it.
- **Servant parses the request body before the handler runs**, so a bad body on
  an authenticated route returns 400 rather than 401. Not a hole — the handler
  still enforces auth — but do not read a 400 as "the token was accepted".
- **Lucid's `Term` class needs monomorphic helpers.** `where`-bound HTML
  fragments without type signatures fail to typecheck with an ambiguous `m`.
  Give them `:: ... -> Html ()`.
- **Local Docker layer caching is not reliable on this machine.** BuildKit
  holds pulled base layers in the build cache rather than as tagged images, and
  OrbStack evicts them; a 1.4GB base plus a ~1GB snapshot store exceeds its
  budget. When the `FROM` layer is evicted and re-pulled, everything beneath it
  invalidates no matter what the content hashes say, so a local rebuild can
  cost the full ~6 minutes.
  Mitigations if local iteration on the Dockerfile ever gets painful:
  `docker pull haskell:9.10.3-bookworm` to hold the base as a tagged image
  (tagged images are not pruned as build cache), and raise OrbStack's cache
  limit. **This does not affect CI**, which imports an explicit
  registry-backed cache from GHCR onto a fresh runner.

## Deploying

The app is `quiz-servant` in `syd`, giving `https://quiz-servant.fly.dev`.

**The app name appears in three places** and they must agree, or the join slide
will print a URL that goes nowhere: `app` in `fly.toml`, `QUIZ_BASE_URL` in
`fly.toml`, and the image tag in `.github/workflows/deploy.yml`. If
`quiz-servant` turns out to be taken globally, change all three.

First time:

```bash
brew install flyctl
fly auth login
fly apps create quiz-servant

# Not optional: the rootfs does not persist across stop/start.
fly volumes create quiz_data --size 1 --region syd

# Write the token locally FIRST, then push that same value to Fly. Fly secrets
# are write-only: generating one inline loses it forever.
mkdir -p ~/.config/quizctl
openssl rand -hex 24 > ~/.config/quizctl/token
chmod 600 ~/.config/quizctl/token
fly secrets set QUIZ_ADMIN_TOKEN="$(cat ~/.config/quizctl/token)"

fly deploy --remote-only          # ~18 min the first time; minutes after
fly scale count 1                 # NOT optional — see below
fly status                        # must list exactly one machine
```

`--remote-only` builds on Fly's own builder, which is amd64 — never build the
deployment image on an arm Mac.

Then point the CLI at it:

```bash
mkdir -p ~/.config/quizctl
echo "https://quiz-servant.fly.dev" > ~/.config/quizctl/url
fly secrets list                  # to confirm; the value itself is write-only
echo "<the admin token>" > ~/.config/quizctl/token
chmod 600 ~/.config/quizctl/token
```

Subsequent deploys are `fly deploy --remote-only`. The GitHub Actions workflow
is written but **has never run** — there is no remote for this repo yet. Use it
only after it has gone green once, and never for the first deploy.

### Costs

Roughly **$0.45/month**: ~$0.30 compute with auto-stop, since billing is
per-second and a few teaching hours a week is a few cents, plus $0.15 for the
1GB volume. Always-on would be ~$3.65. Volume snapshots are free under the
10GB monthly allowance.

### The two rules that matter

**Exactly one machine, always.** `fly deploy` provisions two by default for HA.
Since state is machine-local, two machines split the room: half the students
answer into a world the projector is not showing, and the tallies are simply
wrong with nothing visibly broken. This bit on the first deploy and is the
failure mode most likely to go unnoticed in a real lecture. After any deploy or
scaling operation:

```bash
fly scale count 1 && fly status    # exactly one machine
```

Worth adding to the pre-lecture ritual, since nothing in the app can detect it
— `quizctl status` talks to whichever machine answers and looks perfectly
healthy either way.

**Never `fly deploy` during a lecture.** A deploy replaces the machine. The
volume and its log survive that, but the machine is gone for a minute or two
mid-replacement, which is not something to do in front of a room.

## Build order

1. ~~`quizctl validate` — YAML → model → static HTML. No server.~~ **done**
2. ~~Local server end to end: student form, submit, results embed.~~ **done** —
   driven so far by `curl` against the JSON admin API. Still worth testing from
   a real phone over the LAN.
3. ~~Presenter page at `/p/<secret>`: open/close/reveal, text moderation, and
   reactivation of a superseded session.~~ **done**
4. ~~`quizctl push` / `session` / `open` / `close` / `reveal` / `status` /
   `pull` via `servant-client`, reusing the `API` type.~~ **done** — server
   location and token come from `QUIZ_URL`/`QUIZ_TOKEN` or files under
   `~/.config/quizctl/`.
5. Fly deploy + GitHub Actions, then a full rehearsal on a second device.
   **← current**

Not yet built, and needed before a real lecture: the QR/join embed carries a
bare `/s` rather than a real hostname (fix alongside deployment, when the
hostname exists), and a real-phone-over-LAN pass on the student flow.

Prove the Docker build locally before wiring CI — debugging a Haskell build
inside CI is miserable.

## Deliberately out of scope

Accounts, multiple presenters, images in questions, timers, leaderboards, word
clouds, editing quizzes in a browser, and any analytics beyond export.
