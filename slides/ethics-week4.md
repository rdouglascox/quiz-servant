---
quiz: ethics-week4
title: "Week 4 — Rights and constraints"
feedback: after_close
header-includes: |
  <meta name="quiz-base" content="https://quiz-servant.fly.dev">
  <meta name="quiz-slug" content="ethics-week4">
---

# Joining

Students go to the address below. The code changes every session; this page
does not.

::: {.quiz question=join}
Waiting…
:::

# The transplant surgeon

A surgeon has five patients who will each die without a different organ. A
healthy sixth person walks in for a check-up. Their organs are compatible with
all five.

> Almost nobody says the surgeon should operate. Almost everybody says you
> should pull the trolley lever. The arithmetic is the same in both.

```quiz
key: transplant
type: choice
prompt: "Should the surgeon operate?"
options:
  - { key: operate, text: "Yes — five lives outweigh one" }
  - { key: refrain, text: "No" }
  - { key: unsure,  text: "I don't know" }
```

# What might explain the difference

If the arithmetic is identical, the difference has to lie somewhere other than
the outcome.

```quiz
key: what-explains
type: multi
prompt: "Which of these could explain the difference?"
select: 1..3
options:
  - { key: using,     text: "The surgeon uses the sixth person as a means" }
  - { key: rights,    text: "The sixth person has a right not to be killed" }
  - { key: institution, text: "Trust in medicine would collapse" }
  - { key: nothing,   text: "Nothing — our intuitions are simply inconsistent" }
```

# Naming it

```quiz
key: name-the-principle
type: text
prompt: "In a sentence, what principle separates the two cases?"
max_length: 200
```

# Where that leaves you

```quiz
key: still-consequentialist
type: grid
prompt: "After all that, how far do you accept each of these?"
range: 1..5
labels:
  1: "Reject"
  5: "Accept"
items:
  - { key: outcomes, text: "Only outcomes ultimately matter" }
  - { key: sideconstraints, text: "Some acts are off-limits whatever the outcome" }
  - { key: intuitions, text: "Our case intuitions are evidence about ethics" }
```

Run the same grid again in week 10 and the movement is the interesting part.
