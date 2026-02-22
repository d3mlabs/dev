# typed: true

# RSpock BDD block declarations. These are not real methods -- RSpock's AST
# transformation rewrites them at parse time. Declared here so Sorbet knows
# about them in test files that use transform!(RSpock::AST::Transformation).
class Minitest::Test
  sig { params(label: String).void }
  def Given(label); end

  sig { params(label: String).void }
  def When(label); end

  sig { params(label: String).void }
  def Then(label); end

  sig { params(label: String).void }
  def Expect(label); end

  sig { params(label: String).void }
  def Cleanup(label); end

  # Where is used bare (no parens/args), so Ruby parses it as a constant, not a method call.
  Where = T.let(nil, NilClass)
end
