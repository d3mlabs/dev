---
name: sig-retrofit-runtime-semantics
description: >-
  MUST be used when adding Sorbet sigs to existing Ruby methods: sig-wrapped
  methods behave differently at runtime (void sentinel, validated params,
  private-call receivers), so retrofitting is not behavior-neutral.
---

# Retrofitting sigs changes runtime behavior, not just static checking

sorbet-runtime wraps every sig'd method, so adding sigs to working code can
break it three ways: `.void` replaces the method's return value with a VOID
sentinel (callers or tests asserting `.nil?` fail); params are validated on
every call (duck-typed test fakes and StringIO-for-IO injections raise
TypeError — type such seams `T.untyped` / `T.any(IO, StringIO)`); and
`T.unsafe(self).some_method(...)` is an explicit-receiver call, which raises
NoMethodError when the target (e.g. `Kernel#system`) is private. For
runtime-sized splats keep the call receiverless and unsafe-cast the argv.

Wrong:

```ruby
success = T.unsafe(self).system(env, *build_command(spec), chdir: dir)
# => NoMethodError: private method 'system' called for an instance of …
```

Right:

```ruby
argv = [env, *build_command(spec)]
success = system(*T.unsafe(argv), chdir: dir)
```

learned-from: the typed-sigil enforcement pass (dev#139) — four test
failures after lib/ went strict: two private-receiver T.unsafe(self) calls,
a `.nil?` assertion on a newly-void install_all, and a String passed where
the sig'd base contract validates a Hash.
date: 2026-08-28
