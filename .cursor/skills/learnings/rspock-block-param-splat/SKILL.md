---
name: rspock-block-param-splat
description: >-
  MUST be used when a block in an rspock `transform!`-ed test class takes a
  single parameter that receives an Array (a fake's handler, a `stubs`
  `with` block, `each`/`map` over argv-shaped records), or when diagnosing
  `undefined method ... for an instance of String` where an Array was
  passed.
---

# One-parameter blocks auto-splat under rspock

rspock rewrites the test class through parse + unparse, and the unparser
re-emits a one-parameter block `{ |args| … }` as `{ |args,| … }` — the
trailing comma makes Ruby splat an Array argument, so `args` is its first
element, not the array. Write the block to say what it expects: destructure
the array (`|verb, *rest|`), take a splat (`|*run|`) or pass a lambda, whose
parameters the unparser leaves alone.

Wrong — the handler receives `["exec", "svc", "sh"]` but `args` is `"exec"`:

    engine = FakeContainerEngine.new { |args| args.first == "exec" ? 3 : true }

Right — destructure, or hand over a lambda:

    engine = FakeContainerEngine.new { |verb, *_rest| verb == "exec" ? 3 : true }
    engine = FakeContainerEngine.new(&->(args) { args.fetch(0) == "exec" ? 3 : true })

The symptom is a `NoMethodError` on a String (or an `Array` arity error)
inside a test that reads correctly, and only inside a `transform!`-ed
class — the same block in a plain Minitest class works. Blocks whose one
parameter receives a non-Array are unaffected, which is why the quirk
hides until a fake starts yielding argv.

learned-from: dev#421 (dispatch_test's recording engine handler, which saw "exec" where it expected the argv).
date: 2026-11-07
