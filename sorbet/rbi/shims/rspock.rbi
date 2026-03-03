# typed: true

# RSpock BDD block declarations. These are not real methods -- RSpock's AST
# transformation rewrites them at parse time. Declared here so Sorbet knows
# about them in test files that use transform!(RSpock::AST::Transformation).
class Minitest::Test
  # RSpock BDD blocks can be used with a label (`When "parsing"`) or bare
  # (`When`). Bare uppercase identifiers are parsed by Ruby as constants,
  # so each needs both an optional-arg method and a constant declaration.
  sig { params(label: String).void }
  def Given(label = ""); end
  Given = T.let(nil, NilClass)

  sig { params(label: String).void }
  def When(label = ""); end
  When = T.let(nil, NilClass)

  sig { params(label: String).void }
  def Then(label = ""); end
  Then = T.let(nil, NilClass)

  sig { params(label: String).void }
  def Expect(label = ""); end
  Expect = T.let(nil, NilClass)

  sig { params(label: String).void }
  def Cleanup(label = ""); end
  Cleanup = T.let(nil, NilClass)

  sig { params(label: String).void }
  def Where(label = ""); end
  Where = T.let(nil, NilClass)
end
