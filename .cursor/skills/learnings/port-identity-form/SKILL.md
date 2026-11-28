---
name: port-identity-form
description: MUST be used when adding a lifecycle port or a stage a target may leave undeclared (a builder, packager, publisher, a `files:` selection), or when a verb is about to grow a `nil` branch for "the target declares nothing here".
---

# A port's undeclared case is its identity form, never nil

A stage that a target may leave undeclared gets an identity implementation
— the form that hands its input through unchanged (`CheckoutBuilder` for no
`build:`, `as-is` for package) — and the verbs see one port type with no
nil branch. A precondition of the stage (the stage is fresh) is the port's
own rule, stated once in dev, never each script's.

Why: a nil port does not stay nil. Every verb grows an `if builder` arm,
`build-id.json` grows a sentinel (`"none"`), and every adopter whose tree
is "the checkout, selected" re-derives the identity in a script — three
repos carried `find "$DEV_INSTALL" -delete; cp -R … "$DEV_INSTALL"/` because
dev left both "what no `build:` means" and "is the stage fresh" unspecified.

```ruby
# WRONG: the absent declaration is nil, and callers branch on it
sig { params(target: Target).returns(T.nilable(Builder)) }
def builder_for(target) = target.builder ? ScriptBuilder.new(...) : nil
env.builder&.build(build, stage)            # in every verb
builder: env.builder&.name || "none"        # a sentinel in the stamp

# RIGHT: the absent declaration is the identity; the precondition is the port's
sig { params(target: Target).returns(Builder) }
def builder_for(target) = target.builder ? ScriptBuilder.new(...) : @checkout_builder
sig(:final) { params(build: Build, stage: Pathname).void }
def build(build, stage) = (empty(stage); stage.mkpath; fill(build, stage); share(stage))
```

Before adding a nilable port or a "declares nothing" skip, name the
identity element and ask what every implementation would otherwise have
to re-derive about the stage; that is the port's rule.

learned-from: dev#674 (plans#76 "selection is packaging; the stage has an identity builder") — `ScriptBuilder#build` did `mkpath` and nothing else, `Ports#builder_for` returned nil, and dev-core, dev and ai-flow each shipped the same clear-and-copy script.
date: 2026-11-23
