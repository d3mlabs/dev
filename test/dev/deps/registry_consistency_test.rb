# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/registry"
require "dev/deps/dsl"
require "dev/deps/local_store"
require "tmpdir"

# Anti-drift guard for the integration Registry (lib/dev/deps/registry.rb).
#
# Integration wiring used to live in two hand-maintained hashes that nothing kept
# in sync with the classes that existed — which is how LuaRocks shipped resolved
# but never installed. These tests fail the build the instant a repository or
# integration class, or a declaration DSL verb, is added without a registry entry.
transform!(RSpock::AST::Transformation)
class Dev::Deps::RegistryConsistencyTest < Minitest::Test
  DEPS_DIR = File.expand_path("../../../../lib/dev/deps", __dir__)

  # Repositories deliberately not owned by a single integration symbol (none today).
  REPOSITORY_ALLOWLIST = {}.freeze

  # Integrations deliberately not host-wired (none today).
  INTEGRATION_ALLOWLIST = {}.freeze

  # Schemes deliberately not owned by a single integration symbol.
  SCHEME_ALLOWLIST = {
    "version_scheme.rb" => "VersionScheme is the abstract base every scheme subclasses",
  }.freeze

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

  test "every version scheme class is wired into the registry or allowlisted" do
    Given "the scheme files on disk and the registry's referenced schemes"
    referenced = Dev::Deps::Registry::INTEGRATIONS.filter_map(&:scheme).uniq.map { |k| source_file(k) }

    When "checking each *_scheme.rb file"
    unwired = deps_files("_scheme").reject do |basename|
      SCHEME_ALLOWLIST.key?(basename) ||
        referenced.include?(File.realpath(File.join(DEPS_DIR, basename)))
    end

    Then "none are left unwired"
    assert_empty unwired, "scheme classes missing from Registry::INTEGRATIONS: #{unwired.join(", ")}"
  end

  test "install_alias entries share their target's integration instance" do
    Given "a scratch project root"
    dir = Dir.mktmpdir("registry-alias-test-")

    When "building host integrations from the registry"
    integrations = Dev::Deps::Registry.host_integrations(
      project_root: Pathname(dir),
      store: Dev::Deps::LocalStore.new(data_root: dir),
    )

    Then ":url deps install through :cmake's instance, so deps.cmake stays whole"
    integrations.fetch(:cmake).equal?(integrations.fetch(:url))

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "pin_taps reaches the brew integration on either side and is off unless asked: #{side}, #{pin_taps}" do
    Given "a scratch project root"
    dir = Dir.mktmpdir("registry-pin-test-")

    When "building the side's integrations"
    integrations = Dev::Deps::Registry.public_send(
      side, project_root: Pathname(dir), store: Dev::Deps::LocalStore.new(data_root: dir), pin_taps: pin_taps,
    )

    Then
    integrations.fetch(:brew).pin_taps? == pin_taps

    Cleanup
    FileUtils.rm_rf(dir)

    Where
    side                      | pin_taps
    :host_integrations        | false
    :host_integrations        | true
    :container_integrations   | false
    :container_integrations   | true
  end

  test "container_integrations carries only the container-scoped types, and skips an alias whose target is host-only" do
    Given "a scratch project root"
    dir = Dir.mktmpdir("registry-container-test-")

    When "building container integrations from the registry"
    integrations = Dev::Deps::Registry.container_integrations(
      project_root: Pathname(dir),
      store: Dev::Deps::LocalStore.new(data_root: dir),
    )

    Then "bundler and brew install inside the container; cmake (and so url) do not"
    integrations.key?(:bundler)
    integrations.key?(:brew)
    integrations.key?(:cask)
    !integrations.key?(:cmake)
    !integrations.key?(:url)
    !integrations.key?(:pip)
    !integrations.key?(:luarocks)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "container? is the mirror of host?: BOTH is on both sides, HOST and CONTAINER on one, and never without an integration" do
    Given "entries of each scope"
    both = Dev::Deps::Registry::INTEGRATIONS.find { |entry| entry.symbol == :brew }
    host_only = Dev::Deps::Registry::INTEGRATIONS.find { |entry| entry.symbol == :cmake }
    no_integration = Dev::Deps::Registry::INTEGRATIONS.find { |entry| entry.symbol == :url }

    Expect "each answers for its side"
    both.host? && both.container?
    host_only.host? && !host_only.container?
    !no_integration.host? && !no_integration.container?
  end

  test "every locker class is wired into the registry" do
    Given "the locker files on disk and the registry's referenced lockers"
    referenced = Dev::Deps::Registry::INTEGRATIONS.filter_map(&:locker).uniq.map { |k| source_file(k) }

    When "checking each *_locker.rb file"
    unwired = deps_files("_locker").reject do |basename|
      referenced.include?(File.realpath(File.join(DEPS_DIR, basename)))
    end

    Then "none are left unwired"
    assert_empty unwired, "locker classes missing from Registry::INTEGRATIONS: #{unwired.join(", ")}"
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
