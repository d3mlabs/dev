---
name: unresolved-carries-any-failure
description: >-
  MUST be used when consuming a Resolver::Unresolved verdict, adding a
  path that keeps a lock pin without today's resolution, or widening
  what the Resolver tolerates from a repository.
---

# An Unresolved is not a verdict on the declaration — so judge it yourself

`Dev::Deps::Resolver#choose` wraps `repository.find` in `rescue
StandardError`: an `Unresolved` carries a refused token, a dead network,
*and* a declaration the repository could not even parse
(`OciRepository::ReferenceError` on `from: "ghcr.io/typo"`). A consumer
that keeps prior state on an Unresolved therefore inherits none of the
validity the resolved path proves, and must make whatever judgment the
declaration and the kept pin still allow — else a broken edit is kept
under the old pin with the parse error reported as the outage.

Wrong — carry the lock's pin whenever the re-lock would not have floated it:

    def decide_unresolved(unresolved, prior, floats:, unlock:)
      raise unresolved.error unless unlock.subset? && prior && !floats
      Decision.new(pin: prior, unreachable: unresolved.error)

Right (dev#393) — carry only when the pin was resolved from the source
the declaration names; a pin records what it can (`from` + tag for an
image, `tap` for brew), and a declaration that no longer matches raises
the repository's own error like every other shape:

    carried = unlock.subset? && prior && !floats &&
      resolved_from?(prior, unresolved.declaration.source)
    raise unresolved.error unless carried

General shape: a tolerated failure must not widen what the happy path
accepts. When a fallback skips the check the success path performed by
construction, re-apply that check from the inputs the fallback still has.

learned-from: dev#393 review (subset re-lock kept an edited image floor's
old digest, reporting a ReferenceError as "registry unreachable")
date: 2026-11-01
