---
name: nested-test-fakes
description: >-
  MUST be used when a test needs a fake or stub class (e.g. a
  Dev::BuiltinCommand fake): nest it inside the test class it serves,
  never at file top level.
---

# Test fakes nest inside their test class

A fake class belongs inside the test class that uses it: the constant is
namespaced (`Dev::FooTest::FakeBuiltin`), so cross-file collisions are
impossible and the `unless defined?` guard plus unique name prefixes
(`ServiceFakeBuiltin`, `DispatchFakeBuiltin`, …) become dead weight.
Nesting inside an rspock `transform!`-ed class is safe — the
transformation only rewrites `test "..." do` blocks (plain nested classes
merely gain a harmless `extend RSpock::Declarative`).

Wrong — top-level fake with prefix and guard:

    class ServiceFakeBuiltin < Dev::BuiltinCommand
      def desc = "a builtin"
      def call(args:, context:); end
    end unless defined?(ServiceFakeBuiltin)

    transform!(RSpock::AST::Transformation)
    class Dev::CommandServiceTest < Minitest::Test

Right — nested, short name, no guard:

    transform!(RSpock::AST::Transformation)
    class Dev::CommandServiceTest < Minitest::Test
      class FakeBuiltin < Dev::BuiltinCommand
        def desc = "a builtin"
        def call(args:, context:); end
      end

learned-from: dev#122 review (threads on builtin_executor_test.rb and
overridden_executor_test.rb: "move the fake to be inside the test class")
date: 2026-08-18
