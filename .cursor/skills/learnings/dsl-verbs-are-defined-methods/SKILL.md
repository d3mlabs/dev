---
name: dsl-verbs-are-defined-methods
description: >-
  MUST be used when adding a verb to an instance_eval DSL (Dev::Deps::DSL,
  GroupDSL, a `register`ed integration verb) or diagnosing a DSL line
  that is silently ignored or raises from inside RubyGems/Kernel.
---

# DSL verbs are defined methods, never method_missing-routed

Every object already answers Kernel's private methods — `gem`, `format`,
`test`, `open`, `select`, `system`, `p`, `load`… — so a DSL verb that
shares one of those names never reaches `method_missing`: with an
implicit receiver, Ruby finds the private Kernel method first and calls
*it*. The DSL line is either silently absorbed (RubyGems' `gem "rake"`
activates a gem and records nothing) or raises from a stranger's stack.
Define each verb as a real method on the DSL class; reserve
`method_missing` for names that are provably not Kernel's.

Wrong — routing the known verb set through method_missing:

    def method_missing(name, *args, **kwargs, &block)
      return super unless VERBS.include?(name)   # :gem never gets here
      dispatch(name, *args, **kwargs, &block)
    end

Right (dev#290) — one defined method per verb, a loop if they share a body:

    VERBS.each do |verb|
      define_method(verb) { |*args, **kwargs, &block| ungrouped(verb, args, kwargs, block) }
    end

Diagnostic signature: a top-level `gem "x"` produces zero declarations
with no error, while `brew "x"` beside it works. The same exposure sits
behind `register :<verb>` — a registered name colliding with a Kernel
method is lost the same way (see the FIX proposed in dev#290's build).

learned-from: dev#290 build pass (DSL#gem moved to method_missing;
Kernel#gem swallowed every top-level gem line until config_test caught it)
date: 2026-10-23
