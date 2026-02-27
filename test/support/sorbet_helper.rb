# typed: false
# frozen_string_literal: true

# Mocha mocks that satisfy Sorbet runtime type checks.
#
# Sorbet's runtime sig enforcement uses is_a? to validate parameter types:
#   - T::Types::Simple#valid?  → obj.is_a?(type)
#   - T::Types::ClassOf#valid? → obj.is_a?(type.singleton_class)
#
# A plain mock() fails these checks. typed_mock patches is_a? (and kind_of?)
# on the mock's singleton class so it passes Sorbet validation while remaining
# a normal Mocha mock.
#
# Usage:
#   typed_mock(IO)                         # satisfies sig param typed as IO
#   typed_mock(CLI::UI, class_of: true)    # satisfies sig param typed as T.class_of(CLI::UI)
module SorbetHelper
  def typed_mock(type, class_of: false)
    m = mock
    original_is_a = m.method(:is_a?)

    ancestors = class_of ? [type.singleton_class, Module, Class] : type.ancestors

    m.define_singleton_method(:is_a?) do |klass|
      return true if ancestors.include?(klass)
      original_is_a.call(klass)
    end

    m.define_singleton_method(:kind_of?) { |klass| is_a?(klass) }
    m
  end
end
