---
name: data-define-nested-constants
description: >-
  MUST be used when a Data.define value class needs nested constants — a
  typed error, a default, a pattern — or when a NameError reports such a
  constant missing on the value class.
---

# Data.define blocks don't nest constants; Sorbet rejects the class form

Constants (including `class Foo < RuntimeError`) declared inside a
`Data.define do … end` block use Ruby's *lexical* scoping, so they land
on the enclosing module, not the value class — `Value::Error` then
raises NameError while `EnclosingModule::Error` silently exists. The
escape hatch `class Value < Data.define(...)` nests correctly but fails
Sorbet's srb tc ("Superclasses must only contain constant literals",
error 4002) even in typed: false files. A value class that needs nested
constants (this repo's typed-errors rule nests errors in the raising
class) is written as a plain class with attr_readers; keep `Data.define`
only for constant-free values like `Dev::Cd::Repo`.

Wrong — the error lands on Dev::Clone, not RepoSpec:

    RepoSpec = Data.define(:org, :name) do
      class MalformedRepoError < RuntimeError; end   # Dev::Clone::…!
    end

Right (dev#101):

    class RepoSpec
      class MalformedRepoError < RuntimeError; end
      attr_reader :org, :name
      # parse factory + initialize(org:, name:)
    end

learned-from: dev#101 build pass (RepoSpec's typed error raised
NameError under test; the `< Data.define` fix then failed srb tc)
date: 2026-08-15
