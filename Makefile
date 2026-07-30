# Lecture decks.
#
#   make slides
#
# Each slides/*.md becomes a single self-contained slides/*.html — the
# minpressive template inlines its own CSS and runtime, --include-after-body
# inlines the quiz embed, and --embed-resources folds in any images. Nothing is
# left to upload alongside it.
#
# Override the template path if minpressive lives elsewhere:
#
#   make slides MINPRESSIVE=/path/to/minpressive_basic.html
#
MINPRESSIVE ?= ../minpressive/minpressive_basic.html

DECKS := $(patsubst %.md,%.html,$(wildcard slides/*.md))

.PHONY: slides clean-slides
slides: $(DECKS)

slides/%.html: slides/%.md tools/quiz-embed.html tools/quiz-filter.lua
	@test -f "$(MINPRESSIVE)" || \
	  { echo "template not found: $(MINPRESSIVE) — set MINPRESSIVE=..."; exit 1; }
	pandoc $< \
	  --lua-filter=tools/quiz-filter.lua \
	  --template=$(MINPRESSIVE) \
	  --include-after-body=tools/quiz-embed.html \
	  --embed-resources --standalone \
	  -o $@
	@echo "built $@ — upload this one file"

clean-slides:
	rm -f $(DECKS)
