# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/clone"
require "fileutils"
require "pathname"
require "tmpdir"

# An executor stand-in over the gh CLI boundary, recording argv and answering
# a scripted exit status — the one true boundary this module has.
class RecordingCloneExecutor
  attr_reader :argvs

  def initialize(success: true)
    @success = success
    @argvs = []
  end

  def system(*argv)
    @argvs << argv
    @success
  end
end unless defined?(RecordingCloneExecutor)

transform!(RSpock::AST::Transformation)
class Dev::Clone::GhClonerTest < Minitest::Test
  test "clones through gh into the destination, creating parent directories" do
    Given "a destination whose host/org levels don't exist yet"
    root = Dir.mktmpdir("gh-cloner-")
    destination = Pathname(root) / "github.com" / "acme" / "widget"
    executor = RecordingCloneExecutor.new
    cloner = Dev::Clone::GhCloner.new(executor: executor)

    When "we clone"
    cloner.clone("acme/widget", destination)

    Then "gh repo clone ran with the full name and path, and the parents exist"
    executor.argvs == [["gh", "repo", "clone", "acme/widget", destination.to_s]]
    File.directory?(destination.dirname)

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a failing gh clone raises CloneFailedError" do
    Given "an executor whose gh invocation fails"
    root = Dir.mktmpdir("gh-cloner-")
    destination = Pathname(root) / "github.com" / "acme" / "widget"
    cloner = Dev::Clone::GhCloner.new(executor: RecordingCloneExecutor.new(success: false))

    When "we clone"
    cloner.clone("acme/widget", destination)

    Then
    raises Dev::Clone::GhCloner::CloneFailedError

    Cleanup
    FileUtils.rm_rf(root)
  end
end
