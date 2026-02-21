# typed: true

# DO NOT EDIT MANUALLY
# This file was pulled from a central RBI files repository.
# Please run `bin/tapioca annotations` to update it.

module Mocha::API
  sig { params(arguments: T.untyped).returns(Mocha::Mock) }
  def mock(*arguments); end

  sig { params(arguments: T.untyped).returns(T.untyped) }
  def stub(*arguments); end
end

module Mocha::ClassMethods
  sig { returns(Mocha::Mock) }
  def any_instance; end
end

class Mocha::Expectation
  # `with` annotation removed: its **kwargs conflicts with the generated RBI (error 4010).
  # The generated definition in mocha@*.rbi still provides the method, just without a sig.

  sig { params(values: T.untyped).returns(Mocha::Expectation) }
  def returns(*values); end
end

module Mocha::ObjectMethods
  sig { params(expected_methods_vs_return_values: T.untyped).returns(Mocha::Expectation) }
  def expects(expected_methods_vs_return_values); end

  sig { params(stubbed_methods_vs_return_values: T.untyped).returns(Mocha::Expectation) }
  def stubs(stubbed_methods_vs_return_values); end
end
