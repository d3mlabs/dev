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
  
  # Cleanup and Where can be used bare (`Cleanup`) or with a label
  # (`Cleanup "reason"`). Bare uppercase identifiers are parsed by Ruby as
  # constants, so both a constant and an optional-arg method are needed.
  sig { params(label: String).void }
  def Cleanup(label = ""); end
  Cleanup = T.let(nil, NilClass)

  sig { params(label: String).void }
  def Where(label = ""); end
  Where = T.let(nil, NilClass)
end
