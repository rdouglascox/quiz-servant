# Lecture decks, in three flavours.
#
#   make slides     live quiz panels, polling the server        (what you teach from)
#   make offline    the questions printed on the slides         (when the network dies)
#   make noquiz     no quiz panels at all                       (handing slides out)
#   make all-decks  all three
#
# Each output is a single self-contained HTML file — the minpressive template
# inlines its own CSS and runtime, --include-after-body inlines the quiz embed,
# and --embed-resources folds in any images. Nothing is left to upload beside it.
#
# Override the template path if minpressive lives elsewhere:
#
#   make slides MINPRESSIVE=/path/to/minpressive_basic.html
#
MINPRESSIVE ?= ../minpressive/minpressive_basic.html

# `offline` needs the questions. A deck that writes them into ```quiz fences
# already has them, and needs nothing further. A deck that only places panels
# by reference — ::: {.quiz question=key} — needs the quiz file passed, and
# picks up slides/<name>.yaml beside the deck if it exists. Override for a
# one-off:
#
#   make offline QUIZ=examples/ethics-week3.yaml
#
QUIZ ?=

SOURCES := $(wildcard slides/*.md)
DECKS   := $(patsubst %.md,%.html,$(SOURCES))
OFFLINE := $(patsubst %.md,%.offline.html,$(SOURCES))
NOQUIZ  := $(patsubst %.md,%.noquiz.html,$(SOURCES))

.PHONY: slides offline noquiz all-decks clean-slides
slides: $(DECKS)
offline: $(OFFLINE)
noquiz: $(NOQUIZ)
all-decks: slides offline noquiz

# Note that slides/foo.offline.html matches both `slides/%.html` (stem
# "foo.offline") and `slides/%.offline.html` (stem "foo"). make picks the
# shorter stem, so the variant rules win without needing to be disambiguated.

define check_template
@test -f "$(MINPRESSIVE)" || \
  { echo "template not found: $(MINPRESSIVE) — set MINPRESSIVE=..."; exit 1; }
endef

slides/%.html: slides/%.md tools/quiz-embed.html tools/quiz-filter.lua
	$(check_template)
	pandoc $< \
	  --lua-filter=tools/quiz-filter.lua \
	  --template=$(MINPRESSIVE) \
	  --include-after-body=tools/quiz-embed.html \
	  --embed-resources --standalone \
	  -o $@
	@echo "built $@ — upload this one file"

# Build this whenever the quiz changes, not when you need it: the point is
# that it already exists on the morning the network does not.
slides/%.offline.html: slides/%.md tools/quiz-offline.lua
	$(check_template)
	@quiz="$(or $(QUIZ),slides/$*.yaml)"; \
	if [ -f "$$quiz" ]; then meta="--metadata-file=$$quiz"; else meta=""; fi; \
	pandoc $< $$meta \
	  --lua-filter=tools/quiz-offline.lua \
	  --template=$(MINPRESSIVE) \
	  --embed-resources --standalone \
	  -o $@
	@echo "built $@ — questions printed; no server needed"

slides/%.noquiz.html: slides/%.md tools/quiz-strip.lua
	$(check_template)
	pandoc $< \
	  --lua-filter=tools/quiz-strip.lua \
	  --template=$(MINPRESSIVE) \
	  --embed-resources --standalone \
	  -o $@
	@echo "built $@ — quiz panels removed"

clean-slides:
	rm -f $(DECKS) $(OFFLINE) $(NOQUIZ)
