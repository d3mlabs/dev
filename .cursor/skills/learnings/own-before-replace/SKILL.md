---
name: own-before-replace
description: >-
  MUST be used when dev passes a third-party CLI's takeover flag
  (`--replace`, `--force`, `--clobber`, `--overwrite`) or overwrites a
  remote record for "idempotency", or when a naming scheme is proposed to
  keep two of dev's things from colliding at a remote.
---

# Own before you replace

A takeover flag turns the remote's uniqueness refusal into a silent
overwrite, so it is never idempotency: pass it only after deciding the
thing being replaced is ours — same scope, same host, same role — and
refuse any other collision by naming the holder and the way beside it.
A naming scheme only lowers how often the collision fires; uniqueness of
an identity is a rule's job, checked at the remote before anything changes.

```ruby
# WRONG: every enrollment --replaces; a name another runner holds is
# overwritten and its service keeps running against a dead record
argv + ["--unattended", "--replace"]

# RIGHT: look the name up; replace only our own, refuse the rest
holder = registry.find(scope:, name:)
replace = holder && own_names.include?(name)
raise RegistrationHeldError, "... pass --name to enroll beside it" if holder && !replace
argv << "--replace" if replace
```

The same posture already holds for published artifacts (a store tree or
an image tag is never replaced; first publisher wins) — apply it to any
remote record dev writes under a name it does not solely own.

learned-from: d3mlabs/dev#565 — `dev runner register` always passed
`config.sh --replace`; dev#557 narrowed one collision path by naming
(`<hostname>-<label>`), which only changed how often the steal fired.
date: 2026-11-11
