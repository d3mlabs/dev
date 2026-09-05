---
name: sorbet-splat-unsafe
description: >-
  MUST be used when a sig'd method forwards a runtime-built argv to a
  splatting call (system, Open3.capture3, another rest-args method) or when
  reviewing a T.unsafe/T.let/T.cast around a splat.
---

# Runtime-sized splats: design them away, don't annotate them

Sorbet rejects `f(*array)` whenever the array's size isn't statically known
(error 7019) — regardless of declared element type, so `T.let`/`T.cast`
never help, and it bites any target with fixed positional params
(`Kernel#system` and `Open3.capture3` both take an env-or-command first
param). Restructure so no call site splats: give your own helpers an
`argv: T::Array[String]` parameter instead of rest args, and keep the one
unavoidable `T.unsafe` at the stdlib boundary, commented with error 7019.

Wrong:

```ruby
argv = ["docker", "inspect", "--format", fmt, *ids]
sources = capture(*T.unsafe(argv)) # every caller escapes
```

Right:

```ruby
sources = capture(["docker", "inspect", "--format", fmt, *ids])

sig { params(argv: T::Array[String]).returns(String) }
def capture(argv)
  # T.unsafe: fixed first param can't match a runtime-sized splat (7019).
  out, _err, status = Open3.capture3(*T.unsafe(argv))
```

learned-from: dev#140 review — three threads asked "why T.unsafe / why not
T.let?" about splat escapes; capture(argv) removed all but the boundary one.
date: 2026-09-04
