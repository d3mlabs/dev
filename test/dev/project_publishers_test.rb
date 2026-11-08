# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/project_publishers"
require "dev/deps/dependency"
require "dev/deps/lockfile"
require "dev/deps/registry"
require "dev/deps/brew_repository"
require "dev/deps/git_repository"
require "support/recording_publisher"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::ProjectPublishersTest < Minitest::Test
  ENTRIES = [
    Dev::Deps::Registry::Entry.new(symbol: :brew, repository: Dev::Deps::BrewRepository, scheme: nil, integration: nil,
      publisher: RecordingPublisher, publisher_needs: %i[project_root]),
    Dev::Deps::Registry::Entry.new(symbol: :ruby, repository: Dev::Deps::BrewRepository, scheme: nil, integration: nil, install_alias: :brew),
    Dev::Deps::Registry::Entry.new(symbol: :steam, repository: Dev::Deps::GitRepository, scheme: nil, integration: nil, publisher: RecordingPublisher),
    Dev::Deps::Registry::Entry.new(symbol: :cmake, repository: Dev::Deps::GitRepository, scheme: nil, integration: nil),
  ].freeze

  def pin(name, integration)
    Dev::Deps::Dependency.new(name:, integration:, group: :app, version: "1.0", hash: nil, metadata: {})
  end

  test "the publishers are the write sides of what deps.lock pins, read once, over the checkout: #{what}" do
    Given "a checkout with that lock"
    root = Pathname(Dir.mktmpdir("project-publishers-"))
    Dev::Deps::Lockfile.new(dir: root).lock(pins.map { |name, integration| pin(name, integration) })
    publishers = Dev::ProjectPublishers.new(root:, entries: ENTRIES)

    When
    contributed = publishers.contributed

    Then
    contributed.keys == channels
    contributed.values.all? { |publisher| publisher.is_a?(RecordingPublisher) }
    contributed.values.map(&:project_root).compact == (channels.include?("brew") ? [root] : [])
    publishers.contributed.equal?(contributed)

    Cleanup
    FileUtils.rm_rf(root)

    Where
    what                          | pins                                              | channels
    "no lock at all"              | []                                                | []
    "a pin reaching no publisher" | [["boost", :cmake]]                               | []
    "a pin through an alias"      | [["ruby", :ruby]]                                 | ["brew"]
    "two pins of one type"        | [["ruby", :ruby], ["brew-thing", :brew]]          | ["brew"]
    "pins of two publishers"      | [["steamworks", :steam], ["ruby", :ruby]]         | ["brew", "steam"]
  end

  test "reach is the table's map of channel to the pins that contribute it, independent of the lock (dev#509)" do
    Given "a checkout with no lock"
    root = Pathname(Dir.mktmpdir("project-publishers-"))

    Expect
    Dev::ProjectPublishers.new(root:, entries: ENTRIES).reach == { "brew" => %i[brew ruby], "steam" => %i[steam] }

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a checkout still carrying the retired build-deps.lock is refused, as every lock read is" do
    Given
    root = Pathname(Dir.mktmpdir("project-publishers-"))
    (root / "build-deps.lock").write("")

    When
    Dev::ProjectPublishers.new(root:, entries: ENTRIES).contributed

    Then
    raises Dev::Deps::Lockfile::RetiredBuildLockError

    Cleanup
    FileUtils.rm_rf(root)
  end
end
