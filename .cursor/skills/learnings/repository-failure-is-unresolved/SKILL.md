---
name: repository-failure-is-unresolved
description: >-
  MUST be used when writing a Dev::Deps Repository#find, deciding where a
  declaration's shape is validated, or changing how `dev deps update`
  treats a registry it cannot reach.
---

# A Repository#find failure means "unreadable universe", not "bad declaration"

`Resolver#resolve` reads any exception out of `Repository#find` as the
universe not answering and returns it as an `Unresolved` verdict in the
pin's place; only the Resolver's own errors (unknown integration,
disagreeing asks, nothing satisfying) raise. What a missing universe means
is `PinCarryover`'s call: a subset re-lock keeps the lock's pin for a
declaration it would carry anyway, anything else raises the error. So a
check that a declaration is well-formed must run before `find` — at the
DSL boundary — or a subset re-lock will keep a stale pin for a line the
author broke, reporting it as "registry unreachable".

Wrong — the repository is the first to see the malformed source:

    def find(id)
      ref = parse(id.source)   # raises ReferenceError for "ubuntu:22.04"
      ...

Right — the DSL refuses the shape when the line is read; `find` is left
with I/O failures only:

    def image(name, from:, ...)
      raise ImageReferenceError, ... unless OciRepository::REFERENCE.match?(from)

`find` should raise for what it cannot read (token refused, network down,
no such tag) and for nothing it could have known from the declaration.

learned-from: dev#373 (a subset re-lock failing in `OciRepository` for a
floor it was about to carry verbatim; the fix made `find` failures data).
date: 2026-11-01
