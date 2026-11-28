# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "support/lifecycle_fixtures"
require "etc"
require "fileutils"
require "pathname"
require "tmpdir"

# The port's own rule, over real directories: the stage is emptied loudly
# and what the implementation wrote is opened to the store's group.
transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::BuilderTest < Minitest::Test
  include LifecycleFixtures

  # A builder whose tool leaves owner-only modes behind, as `cp -a` from a
  # `755` source or a `022` umask does, plus a dangling symlink a fetched
  # tree may carry.
  class OwnerOnlyBuilder
    include Dev::Lifecycle::Builder

    def fill(build, stage)
      _ = build
      (stage / "bin").mkpath
      (stage / "bin").chmod(0o755)
      (stage / "bin/tool").write("tool")
      (stage / "bin/tool").chmod(0o644)
      File.symlink("missing", (stage / "dangling").to_s)
    end

    def target_options_schema
      []
    end

    def name
      "owner-only"
    end

    def version
      nil
    end
  end

  def mode(path)
    format("%o", path.lstat.mode & 0o7777)
  end

  test "the stage is emptied and remade before fill, and what the builder wrote is opened to the group: dirs g+rwxs, files g+rw, symlinks left" do
    Given "a stage holding a previous build's file"
    root = Pathname(Dir.mktmpdir("builder-"))
    stage = root / "store/rspock/stage"
    stage.mkpath
    (stage / "stale.txt").write("from before")

    When
    OwnerOnlyBuilder.new.build(build("rspock"), stage)

    Then "the previous file is gone and every entry this user wrote is group-writable, dirs setgid"
    !(stage / "stale.txt").exist?
    mode(stage) == "2775"
    mode(stage / "bin") == "2775"
    mode(stage / "bin/tool") == "664"
    (stage / "dangling").symlink?
    (stage / "bin/tool").read == "tool"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a previous stage this user cannot remove fails loudly, naming the directory, its owner and mode, and the user (dev#745)" do
    Given "a stage whose subtree carries no write bit for this user, as another user's 755 tree does"
    skip "root removes anything, so no directory can block it" if Process.uid.zero?
    root = Pathname(Dir.mktmpdir("builder-"))
    stage = root / "store/rspock/stage"
    (stage / "held").mkpath
    (stage / "held/file.txt").write("another user's")
    (stage / "held").chmod(0o555)
    user = Etc.getpwuid(Process.euid).name

    When
    OwnerOnlyBuilder.new.build(build("rspock"), stage)

    Then "the builder never ran: the error names what blocks and the tree is as it was"
    error = raises Dev::Lifecycle::Builder::StageNotEmptiedError
    error.message == "cannot empty the stage #{stage}: #{stage / "held"} is owned by #{user} (mode 555) and not " \
      "writable by #{user} — a shared store needs group-writable stages"
    (stage / "held/file.txt").exist?
    !(stage / "bin").exist?

    Cleanup
    (stage / "held").chmod(0o755) if stage&.join("held")&.exist?
    FileUtils.rm_rf(root)
  end

  test "a removal no directory's write bit explains is still the typed error, carrying the system's message" do
    Given "a stage with a directory this user can write but not read"
    skip "root reads anything, so no directory can block it" if Process.uid.zero?
    root = Pathname(Dir.mktmpdir("builder-"))
    stage = root / "store/rspock/stage"
    (stage / "opaque").mkpath
    (stage / "opaque/file.txt").write("unlisted")
    (stage / "opaque").chmod(0o300)

    When
    OwnerOnlyBuilder.new.build(build("rspock"), stage)

    Then "the unlisted file keeps the directory, and the message is the system's"
    error = raises Dev::Lifecycle::Builder::StageNotEmptiedError
    error.message.start_with?("cannot empty the stage #{stage}: Directory not empty")
    error.message.include?((stage / "opaque").to_s)

    Cleanup
    (stage / "opaque").chmod(0o755) if stage&.join("opaque")&.exist?
    FileUtils.rm_rf(root)
  end
end
