# Two stages, so the ~15 minute dependency build is cached independently of
# application code. The dependency layer is keyed only on the three files
# copied below; because hpack globs modules, package.yaml changes when
# dependencies change, not when a module is added.
#
# GHC 9.10.3 in the base image matches lts-24.12 exactly, so --system-ghc
# avoids downloading a second toolchain.
FROM haskell:9.10.3-bookworm AS build
WORKDIR /src

COPY stack.yaml stack.yaml.lock package.yaml ./
RUN stack build --system-ghc --no-install-ghc --only-dependencies

COPY . .
RUN stack install --system-ghc --no-install-ghc --local-bin-path /out

FROM debian:bookworm-slim
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       libgmp10 \
       zlib1g \
       ca-certificates \
       netbase \
  && rm -rf /var/lib/apt/lists/*

COPY --from=build /out/ /usr/local/bin/

# GHC takes its default encoding from the locale, so an image with no LANG
# gets ASCII and dies on the first em dash. Quiz.Encoding.forceUtf8 pins UTF-8
# in-process regardless; this is the second layer of defence, and keeps any
# subprocess or library that reads the locale behaving sanely too.
ENV LANG=C.UTF-8

# Responses are appended here as JSONL. In production /data MUST be a mounted
# volume: a Fly machine's rootfs does not survive stop/start, so without one an
# auto-stop silently discards the lecture. See fly.toml's [[mounts]].
ENV QUIZ_LOG=/data/responses.jsonl
RUN mkdir -p /data

EXPOSE 8080
CMD ["quiz-servant"]
