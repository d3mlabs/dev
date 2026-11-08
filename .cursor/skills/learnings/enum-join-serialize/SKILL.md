---
name: enum-join-serialize
description: >-
  MUST be used when interpolating or joining a T::Enum (or an array of
  them) into a string, or when rubocop's Style/MapJoin asks to drop a
  map(&:to_s) before join.
---

# T::Enum refuses implicit conversion; spell it `serialize`

`T::Enum#to_str` raises (`Implicit conversion of Enum to string is not
allowed. Call #serialize instead.`), and `Array#join` tries `to_str`
before `to_s`, so `targets.join(", ")` over an enum array fails at
runtime. The obvious fix, `targets.map(&:to_s).join(", ")`, is flagged
by `Style/MapJoin` as redundant — and its autocorrect reintroduces the
crash, which no type check catches (`join` accepts `T.untyped`).

Wrong — passes sorbet, fails the first time it runs:

    def to_s = "#{mod_reference} (#{targets.join(", ")})"

Also wrong — runs, but rubocop autocorrects it back to the crash:

    def to_s = "#{mod_reference} (#{targets.map(&:to_s).join(", ")})"

Right — the enum's own word for its string form, which the cop leaves
alone and which reads as what it is:

    def to_s = "#{mod_reference} (#{targets.map(&:serialize).join(", ")})"

A single enum in an interpolation (`"#{target}"`) is fine: interpolation
calls `to_s`, which T::Enum defines as `serialize`. The trap is only the
join, and only because the lint fix and the runtime fix disagree.

learned-from: dev#427 build pass (MultiTargetPlugin#to_s raised
NoMethodError in the merger test, then Style/MapJoin flagged the fix)
date: 2026-11-08
