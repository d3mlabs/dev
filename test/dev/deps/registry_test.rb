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
    classes[:ruby] == Dev::Deps::BrewIntegration
    classes[:python] == Dev::Deps::BrewIntegration
    classes.values.all? { |klass| klass <= Dev::Deps::Integration }
  end

  test "the interpreters resolve over brew's universe with their own constraint semantics" do
    When "listing the schemes"
    schemes = Dev::Deps::Registry.schemes

    Then "ruby ranges with rubygems requirements over the tap's ruby@ family; python selects a core suffix"
    schemes.fetch(:ruby).is_a?(Dev::Deps::GemScheme)
    schemes.fetch(:python).is_a?(Dev::Deps::BrewScheme)
    Dev::Deps::Registry.repositories(project_root: Pathname("/tmp")).fetch(:ruby).is_a?(Dev::Deps::BrewRepository)
    Dev::Deps::Registry.repositories(project_root: Pathname("/tmp")).fetch(:python).is_a?(Dev::Deps::BrewRepository)
  end

  test "the image entry resolves a floor over the registry and installs nothing: an image is not a store tree" do
    Given
    entry = Dev::Deps::Registry::INTEGRATIONS.find { |candidate| candidate.symbol == :image }

    Expect "OciRepository, no scheme (the tag is the whole ask), no integration, no alias — the container layer reads the pin"
    entry.repository == Dev::Deps::OciRepository
    entry.scheme.nil?
    entry.integration.nil?
    entry.install_alias.nil?
    !entry.host?
    !Dev::Deps::Registry.host_integrations(project_root: Pathname("/tmp"), store: Dev::Deps::LocalStore.new).key?(:image)
  end
end
