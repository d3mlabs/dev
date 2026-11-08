# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/registry"
require "dev/deps/integration"
require "dev/deps/brew_integration"
require "dev/deps/bundler_repository"
require "dev/deps/cmake_integration"
require "dev/deps/ghcr_publisher"
require "dev/deps/rubygems_publisher"
require "dev/deps/xcode_integration"
require "support/recording_publisher"
require "pathname"

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
    !Dev::Deps::Registry.host_integrations(project_root: Pathname("/tmp"), project_name: "proj", store: Dev::Deps::LocalStore.new).key?(:image)
  end

  test "an entry publishes exactly when it names a publisher class, and the channel it contributes is its own name (dev#422)" do
    Given
    silent = Dev::Deps::Registry::Entry.new(symbol: :cmake, repository: Dev::Deps::GitRepository, scheme: nil, integration: nil)
    steam = Dev::Deps::Registry::Entry.new(symbol: :steam, repository: Dev::Deps::GitRepository, scheme: nil, integration: nil, publisher: RecordingPublisher)

    Expect
    !silent.publishes?
    silent.publisher.nil?
    silent.publisher_needs == []
    steam.publishes?
    steam.publisher == RecordingPublisher
    steam.channel_name == "steam"
  end

  test "an entry's channel is the destination's name when that differs from the type's, and only a publishing entry may name one" do
    Given
    gems = Dev::Deps::Registry::Entry.new(symbol: :bundler, repository: Dev::Deps::BundlerRepository, scheme: nil, integration: nil,
      publisher: RecordingPublisher, channel: "rubygems")

    When "a silent entry names a channel"
    Dev::Deps::Registry::Entry.new(symbol: :cmake, repository: Dev::Deps::GitRepository, scheme: nil, integration: nil, channel: "nowhere")

    Then
    raises Dev::Deps::Registry::ChannelWithoutPublisherError
    gems.channel == "rubygems"
    gems.channel_name == "rubygems"
  end

  test "the built-in write sides (dev#428): gems push to rubygems, an image to ghcr, each reached by its own pin and no other" do
    Given
    gems = Dev::Deps::Registry::INTEGRATIONS.find { |entry| entry.symbol == :bundler }
    image = Dev::Deps::Registry::INTEGRATIONS.find { |entry| entry.symbol == :image }

    Expect "the two entries publish under the store's name; the rest are silent"
    gems.publisher == Dev::Deps::RubygemsPublisher
    gems.publisher_needs == %i[project_root]
    gems.channel_name == "rubygems"
    image.publisher == Dev::Deps::GhcrPublisher
    image.publisher_needs == []
    image.channel_name == "ghcr"
    Dev::Deps::Registry::INTEGRATIONS.select(&:publishes?).map(&:symbol) == %i[bundler image]
    Dev::Deps::Registry::INTEGRATIONS.filter_map(&:channel).uniq.size == Dev::Deps::Registry::INTEGRATIONS.count(&:publishes?)
  end

  test "publishers over the built-in table: #{pinned.inspect} contributes #{channels.inspect}" do
    When
    publishers = Dev::Deps::Registry.publishers(project_root: Pathname("/project"), pinned:)

    Then
    publishers.keys == channels
    publishers.values.map(&:class) == classes

    Where
    pinned             | channels              | classes
    [:bundler]         | ["rubygems"]          | [Dev::Deps::RubygemsPublisher]
    [:image]           | ["ghcr"]              | [Dev::Deps::GhcrPublisher]
    [:bundler, :image] | ["rubygems", "ghcr"]  | [Dev::Deps::RubygemsPublisher, Dev::Deps::GhcrPublisher]
    [:ruby]            | []                    | []
    [:gh, :steam]      | []                    | []
    []                 | []                    | []
  end

  test "publishers builds one instance per publishing entry the lock reaches, directly or through an alias, with the kwargs it asks for" do
    Given "a table where brew publishes and ruby installs through it; steam publishes but is not pinned; cmake is pinned but silent"
    entries = [
      Dev::Deps::Registry::Entry.new(symbol: :brew, repository: Dev::Deps::BrewRepository, scheme: nil, integration: nil,
        publisher: RecordingPublisher, publisher_needs: %i[project_root]),
      Dev::Deps::Registry::Entry.new(symbol: :ruby, repository: Dev::Deps::BrewRepository, scheme: nil, integration: nil, install_alias: :brew),
      Dev::Deps::Registry::Entry.new(symbol: :steam, repository: Dev::Deps::GitRepository, scheme: nil, integration: nil, publisher: RecordingPublisher),
      Dev::Deps::Registry::Entry.new(symbol: :cmake, repository: Dev::Deps::GitRepository, scheme: nil, integration: nil),
    ]

    When
    publishers = Dev::Deps::Registry.publishers(project_root: Pathname("/project"), pinned: pinned, entries:)

    Then
    publishers.keys == channels
    publishers.values.all? { |publisher| publisher.is_a?(RecordingPublisher) }
    publishers.values.map(&:project_root).compact == (channels.include?("brew") ? [Pathname("/project")] : [])

    Where
    pinned           | channels
    [:brew]          | ["brew"]
    [:ruby]          | ["brew"]
    [:ruby, :steam]  | ["brew", "steam"]
    [:cmake]         | []
    []               | []
  end
end
