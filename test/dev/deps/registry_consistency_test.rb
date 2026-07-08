# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/registry"
require "dev/deps/dsl"

# Anti-drift guard for the integration Registry (lib/dev/deps/registry.rb).
#
# Integration wiring used to live in two hand-maintained hashes that nothing kept
# in sync with the classes that existed — which is how LuaRocks shipped resolved
# but never installed. These tests fail the build the instant a repository or
# integration class, or a declaration DSL verb, is added without a registry entry.
transform!(RSpock::AST::Transformation)
class Dev::Deps::RegistryConsistencyTest < Minitest::Test
  DEPS_DIR = File.expand_path("../../../../lib/dev/deps", __dir__)

  # Repositories deliberately not owned by a single integration symbol.
  REPOSITORY_ALLOWLIST = {
    "url_repository.rb" =>
      "UrlRepository is a cmake fetch backend chosen per-dep, not its own integration type",
  }.freeze

  # Integrations deliberately not host-wired (none today).
  INTEGRATION_ALLOWLIST = {}.freeze

  # Every GroupDSL verb that creates a declaration, mapped to its integration
  # symbol. Adding a new declaration verb must add a Registry entry too.
  DECLARATION_INTEGRATIONS = %i[bundler brew cmake luarocks ficsit gh steam pip].freeze

  def source_file(klass)
    File.realpath(Object.const_source_location(klass.name).first)
  end

  def deps_files(suffix)
    Dir[File.join(DEPS_DIR, "*#{suffix}.rb")].map { |path| File.basename(path) }
  end

  test "every repository class is wired into the registry or allowlisted" do
    Given "the repository files on disk and the registry's referenced repositories"
    referenced = Dev::Deps::Registry::INTEGRATIONS.map(&:repository).uniq.map { |k| source_file(k) }

    When "checking each *_repository.rb file"
    unwired = deps_files("_repository").reject do |basename|
      REPOSITORY_ALLOWLIST.key?(basename) ||
        referenced.include?(File.realpath(File.join(DEPS_DIR, basename)))
    end

    Then "none are left unwired"
    assert_empty unwired, "repository classes missing from Registry::INTEGRATIONS: #{unwired.join(", ")}"
  end

  test "every integration class is wired into the registry or allowlisted" do
    Given "the integration files on disk and the registry's referenced integrations"
    referenced = Dev::Deps::Registry::INTEGRATIONS.map(&:integration).compact.uniq.map { |k| source_file(k) }

    When "checking each *_integration.rb file"
    unwired = deps_files("_integration").reject do |basename|
      INTEGRATION_ALLOWLIST.key?(basename) ||
        referenced.include?(File.realpath(File.join(DEPS_DIR, basename)))
    end

    Then "none are left unwired"
    assert_empty unwired, "integration classes missing from Registry::INTEGRATIONS: #{unwired.join(", ")}"
  end

  test "every declaration DSL verb has a registry entry" do
    Given "the integration symbols the registry knows"
    known = Dev::Deps::Registry::INTEGRATIONS.map(&:symbol)

    When "comparing against the DSL declaration verbs"
    missing = DECLARATION_INTEGRATIONS - known

    Then "every declaration verb resolves to a registry entry"
    assert_empty missing, "declaration integrations missing from the registry: #{missing.join(", ")}"
  end

  test "every host-scoped entry has both a repository and an integration" do
    Given "the host-scoped registry entries"
    host_entries = Dev::Deps::Registry::INTEGRATIONS.select(&:host?)

    When "inspecting their repository and integration"
    incomplete = host_entries.reject { |entry| entry.repository && entry.integration }

    Then "all host entries are fully wired"
    assert_empty incomplete, "host entries missing a repository or integration: #{incomplete.map(&:symbol).join(", ")}"
  end

  test "the registry actually wires luarocks and brew for host install" do
    Given "the registry host symbols"
    host_symbols = Dev::Deps::Registry::INTEGRATIONS.select(&:host?).map(&:symbol)

    When "checking the previously-dormant integrations"
    luarocks_wired = host_symbols.include?(:luarocks)
    brew_wired = host_symbols.include?(:brew)
    bundler_wired = host_symbols.include?(:bundler)

    Then "luarocks, brew, and bundler all install on the host"
    luarocks_wired
    brew_wired
    bundler_wired
  end
end
