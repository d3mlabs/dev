# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/registry"
require "dev/deps/integration"
require "dev/deps/brew_integration"
require "dev/deps/cmake_integration"
require "dev/deps/xcode_integration"

# A project-local integration, as a `register`ed class would be loaded.
class RegistryTestLocalIntegration < Dev::Deps::Integration; end

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

  test "integration_classes adds a project's registered integrations, given as a #{form}" do
    When "listing with a registration"
    classes = Dev::Deps::Registry.integration_classes(registered: { local: registration })

    Then
    classes[:local] == RegistryTestLocalIntegration

    Where
    form     | registration
    "class"  | RegistryTestLocalIntegration
    "name"   | "RegistryTestLocalIntegration"
  end

  test "integration_classes raises IntegrationClassNotLoadedError for a registered name nothing has loaded" do
    When "registering a constant that does not exist"
    Dev::Deps::Registry.integration_classes(registered: { ghost: "RegistryTestGhostIntegration" })

    Then
    raises Dev::Deps::Registry::IntegrationClassNotLoadedError
  end

  test "integration_classes raises NotAnIntegrationError for a registration that is not an Integration subclass" do
    When "registering #{registration.inspect}"
    Dev::Deps::Registry.integration_classes(registered: { odd: registration })

    Then
    raises Dev::Deps::Registry::NotAnIntegrationError

    Where
    registration
    "String"
    String
    42
  end
end
