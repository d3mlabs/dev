# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/data_root_migration"
require "fileutils"
require "support/recording_ui"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::DataRootMigrationTest < Minitest::Test
  def setup
    @from = Dir.mktmpdir("home-dev")
    @to = Dir.mktmpdir("machine-root")
    @ui = RecordingUi.new
  end

  def teardown
    FileUtils.rm_rf([@from, @to])
    super
  end

  test "artifact trees move as a rename, each its own spin; per-user state stays" do
    Given
    FileUtils.mkdir_p(File.join(@from, "engines", "ue5"))
    FileUtils.mkdir_p(File.join(@from, "cache"))
    FileUtils.mkdir_p(File.join(@from, "state"))

    When
    migration.run!

    Then
    File.directory?(File.join(@to, "engines", "ue5"))
    File.directory?(File.join(@to, "cache"))
    !File.exist?(File.join(@from, "engines"))
    File.directory?(File.join(@from, "state"))
    !File.exist?(File.join(@to, "state"))
    @ui.rows == [[:spin, "Migrating ~/.dev/cache to #{File.join(@to, "cache")}", 0], [:spin, "Migrating ~/.dev/engines to #{File.join(@to, "engines")}", 0]]
  end

  test "an entry the destination already holds is skipped, the home copy left where it is" do
    Given
    FileUtils.mkdir_p(File.join(@from, "engines", "stale"))
    FileUtils.mkdir_p(File.join(@to, "engines", "current"))

    When
    migration.run!

    Then
    File.directory?(File.join(@to, "engines", "current"))
    !File.exist?(File.join(@to, "engines", "stale"))
    File.directory?(File.join(@from, "engines", "stale"))
    @ui.rows == [[:note, "Skipping ~/.dev/engines (already present in #{@to})", 0]]
  end

  test "no per-user root, nothing to do" do
    Given
    FileUtils.rm_rf(@from)

    When
    migration.run!

    Then
    Dir.empty?(@to)
    @ui.rows == []
  end

  private

  def migration
    Dev::DataRootMigration.new(from: @from, to: @to, ui: @ui)
  end
end
