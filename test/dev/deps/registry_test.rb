# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/registry"
require "dev/deps/integration"
require "dev/deps/brew_integration"
require "dev/deps/cmake_integration"
require "dev/deps/xcode_integration"

transform!(RSpock::AST::Transformation)
class Dev::Deps::RegistryTest < Minitest::Test
  test "integration_classes maps every installing symbol to its class, aliases included" do
    When "listing the built-in classes"
    classes = Dev::Deps::Registry.integration_classes

    Then "installing types map to their class; an aliased type maps to its target's"
    classes[:brew] == Dev::Deps::BrewIntegration
    classes[:xcode] == Dev::Deps::XcodeIntegration
    classes[:url] == Dev::Deps::CmakeIntegration
    classes.values.all? { |klass| klass <= Dev::Deps::Integration }
  end
end
