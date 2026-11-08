---
name: rspock-block-arg-splat
description: >-
  MUST be used when a brace or do-block with a single parameter receives an
  Array inside an rspock `transform!`-ed test file — a callback, a fake's
  handler, a `map` over rows — or when such a block mysteriously sees only
  the array's first element.
---

# A single-param block is re-emitted as `|a,|` in transformed test files

In a `transform!(RSpock::AST::Transformation)` file, `{ |args| … }` is
parsed by ast_transform's builder as a plain `(arg :args)` and re-emitted
by unparser as `{ |args,| … }` — the trailing comma makes the block
destructure, so a handler called with `["tag", "a", "b"]` sees `"tag"`.
Hand such a callback a **lambda** (`->(x) { … }` with `&`) or a
`&method(:name)`: both keep lambda arity semantics through the transform.

Wrong — a fake engine's handler that compares whole argv:

    FakeContainerEngine.new { |args| args != refuse }   # args == "tag"

Right:

    refuses = ->(docker_args) { docker_args != refuse }
    FakeContainerEngine.new(&refuses)

Root cause: `ASTTransform::KwargsBuilder` opts into `emit_kwargs` only;
unparser 0.9's `emit_block_arguments` assumes the modern `emit_procarg0`
flag and writes `,` after a lone `:arg`. The fix lives in
d3mlabs/ast-transform (set the builder's `emit_procarg0`), not in any
adopting repo — until it lands, the lambda is the rule. Helper methods
defined inside the test class are transformed too, so the rule covers
them, not only `Given`/`When` bodies.

learned-from: dev#428 build pass (GhcrPublisher tests: the fake engine's
block handler never refused; `tmp/ast_transform/…` showed `|args,|`)
date: 2026-11-08
