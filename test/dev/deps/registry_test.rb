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
require "dev/deps/brew_publisher"
require "dev/deps/tap"
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

  test "ficsit publishes through its own repository class; a lock pinning a mod gets `deploy ficsit` (dev#427)" do
    Given
    ficsit = Dev::Deps::Registry::INTEGRATIONS.find { |entry| entry.symbol == :ficsit }

    Expect "the write side is the read side's class, built with no kwargs"
    ficsit.publisher == Dev::Deps::FicsitRepository
    ficsit.publisher_needs == []
    ficsit.channel_name == "ficsit"
    publishers = Dev::Deps::Registry.publishers(project_root: Pathname("/tmp"), pinned: [:ficsit])
    publishers.keys == ["ficsit"]
    publishers.fetch("ficsit").is_a?(Dev::Deps::FicsitRepository)
  end

  test "the built-in store publishers are steam's repository and egs's own class (dev#426)" do
    Given
    by_symbol = Dev::Deps::Registry::INTEGRATIONS.to_h { |entry| [entry.symbol, entry] }

    Expect
    by_symbol[:steam].publisher == Dev::Deps::SteamRepository
    by_symbol[:steam].publisher_needs == []
    by_symbol[:egs].publisher == Dev::Deps::EgsPublisher
    by_symbol[:egs].publisher_needs == %i[project_root]
    by_symbol[:egs].repository == Dev::Deps::UrlRepository
    by_symbol[:egs].integration == Dev::Deps::EgsIntegration
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

  test "the built-in write sides (dev#428, #429): gems push to rubygems, an image to ghcr, formulae to the tap, each reached by its own pin and no other" do
    Given
    gems = Dev::Deps::Registry::INTEGRATIONS.find { |entry| entry.symbol == :bundler }
    image = Dev::Deps::Registry::INTEGRATIONS.find { |entry| entry.symbol == :image }

    Expect "the two entries publish under the store's name; with steam, egs and ficsit (dev#426, #427), the rest are silent"
    gems.publisher == Dev::Deps::RubygemsPublisher
    gems.publisher_needs == %i[project_root]
    gems.channel_name == "rubygems"
    image.publisher == Dev::Deps::GhcrPublisher
    image.publisher_needs == []
    image.channel_name == "ghcr"
    brew = Dev::Deps::Registry::INTEGRATIONS.find { |entry| entry.symbol == :brew }
    brew.publisher == Dev::Deps::BrewPublisher
    brew.publisher_needs == %i[project_root taps]
    brew.channel_name == "brew"
    Dev::Deps::Registry::INTEGRATIONS.select(&:publishes?).map(&:symbol) == %i[bundler brew ficsit steam egs image]
    Dev::Deps::Registry::INTEGRATIONS.select(&:publishes?).map(&:channel_name).uniq.size == Dev::Deps::Registry::INTEGRATIONS.count(&:publishes?)
  end

  test "publishers over the built-in table: #{pinned.inspect} contributes #{channels.inspect}" do
    When
    publishers = Dev::Deps::Registry.publishers(project_root: Pathname("/project"), pinned:, taps: [Dev::Deps::Tap.new(name: "d3mlabs/d3mlabs")])

    Then
    publishers.keys == channels
    publishers.values.map(&:class) == classes

    Where
    pinned             | channels              | classes
    [:bundler]         | ["rubygems"]          | [Dev::Deps::RubygemsPublisher]
    [:image]           | ["ghcr"]              | [Dev::Deps::GhcrPublisher]
    [:bundler, :image] | ["rubygems", "ghcr"]  | [Dev::Deps::RubygemsPublisher, Dev::Deps::GhcrPublisher]
    [:ficsit]          | ["ficsit"]            | [Dev::Deps::FicsitRepository]
    [:steam]           | ["steam"]             | [Dev::Deps::SteamRepository]
    [:egs]             | ["egs"]               | [Dev::Deps::EgsPublisher]
    [:steam, :egs]     | ["steam", "egs"]      | [Dev::Deps::SteamRepository, Dev::Deps::EgsPublisher]
    [:ruby]            | ["brew"]              | [Dev::Deps::BrewPublisher]
    [:brew]            | ["brew"]              | [Dev::Deps::BrewPublisher]
    [:cmake, :url]     | []                    | []
    []                 | []                    | []
  end

  test "brew (dev#429): a lock reaching it, directly or through ruby, gets the tap publisher; a lock reaching none of the three gets nothing" do
    Given
    taps = [Dev::Deps::Tap.new(name: "d3mlabs/d3mlabs")]

    When
    publishers = Dev::Deps::Registry.publishers(project_root: Pathname("/tmp"), pinned: [:ruby], taps:)

    Then
    publishers.keys == ["brew"]
    publishers["brew"].is_a?(Dev::Deps::BrewPublisher)
    Dev::Deps::Registry.publishers(project_root: Pathname("/tmp"), pinned: [:cmake, :git], taps:) == {}
  end

  test "publisher_reach maps each channel a table can ship to onto the types whose pin reaches it, directly or through an alias (dev#509)" do
    Given "the same table: brew publishes and ruby installs through it; steam publishes; cmake is silent"
    entries = [
      Dev::Deps::Registry::Entry.new(symbol: :brew, repository: Dev::Deps::BrewRepository, scheme: nil, integration: nil,
        publisher: RecordingPublisher, publisher_needs: %i[project_root]),
      Dev::Deps::Registry::Entry.new(symbol: :ruby, repository: Dev::Deps::BrewRepository, scheme: nil, integration: nil, install_alias: :brew),
      Dev::Deps::Registry::Entry.new(symbol: :steam, repository: Dev::Deps::GitRepository, scheme: nil, integration: nil, publisher: RecordingPublisher),
      Dev::Deps::Registry::Entry.new(symbol: :cmake, repository: Dev::Deps::GitRepository, scheme: nil, integration: nil),
    ]

    Expect
    Dev::Deps::Registry.publisher_reach(entries:) == { "brew" => %i[brew ruby], "steam" => %i[steam] }
    Dev::Deps::Registry.publisher_reach == { "rubygems" => %i[bundler], "brew" => %i[brew ruby python], "ficsit" => %i[ficsit], "steam" => %i[steam], "egs" => %i[egs], "ghcr" => %i[image] }
  end

  test "publishers builds one instance per publishing entry the lock reaches, directly or through an alias, with the kwargs it asks for" do
    Given "a table where brew publishes and ruby installs through it; steam publishes but is not pinned; cmake is pinned but silent"
    taps = [Dev::Deps::Tap.new(name: "d3mlabs/d3mlabs")]
    entries = [
      Dev::Deps::Registry::Entry.new(symbol: :brew, repository: Dev::Deps::BrewRepository, scheme: nil, integration: nil,
        publisher: RecordingPublisher, publisher_needs: %i[project_root taps]),
      Dev::Deps::Registry::Entry.new(symbol: :ruby, repository: Dev::Deps::BrewRepository, scheme: nil, integration: nil, install_alias: :brew),
      Dev::Deps::Registry::Entry.new(symbol: :steam, repository: Dev::Deps::GitRepository, scheme: nil, integration: nil, publisher: RecordingPublisher),
      Dev::Deps::Registry::Entry.new(symbol: :cmake, repository: Dev::Deps::GitRepository, scheme: nil, integration: nil),
    ]

    When
    publishers = Dev::Deps::Registry.publishers(project_root: Pathname("/project"), pinned: pinned, taps:, entries:)

    Then
    publishers.keys == channels
    publishers.values.all? { |publisher| publisher.is_a?(RecordingPublisher) }
    publishers.values.map(&:project_root).compact == (channels.include?("brew") ? [Pathname("/project")] : [])
    publishers.values.map(&:taps).compact == (channels.include?("brew") ? [taps] : [])

    Where
    pinned           | channels
    [:brew]          | ["brew"]
    [:ruby]          | ["brew"]
    [:ruby, :steam]  | ["brew", "steam"]
    [:cmake]         | []
    []               | []
  end
end
