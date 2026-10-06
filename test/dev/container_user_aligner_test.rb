# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/container_user_aligner"
require "support/fake_container_engine"

transform!(RSpock::AST::Transformation)
class Dev::ContainerUserAlignerTest < Minitest::Test
  include SorbetHelper

  PROBE = Dev::ContainerUserAligner::PROBE
  SCRIPT = Dev::ContainerUserAligner::SCRIPT

  test "align! does nothing when the container's user can already write the data root" do
    Given "a container whose user owns the mount (same uid as the host, or a mapped mount)"
    engine = FakeContainerEngine.new(capture_result: "1000 1000 builder builder 1000 1000 yes\n")
    aligner = Dev::ContainerUserAligner.new(engine: engine)

    When "aligning"
    result = aligner.align!("dev-x")

    Then "one probe as the container's user, nothing run as root"
    result == :aligned
    engine.captures == [["exec", "dev-x", "sh", "-c", PROBE]]
    engine.runs.empty?
  end

  test "align! leaves a writable mount alone even when the uids differ (a mapped mount)" do
    Given "a Mac-style mount: another owner reported, but writable"
    engine = FakeContainerEngine.new(capture_result: "1000 1000 builder builder 501 20 yes\n")
    aligner = Dev::ContainerUserAligner.new(engine: engine)

    When "aligning"
    result = aligner.align!("dev-x")

    Then
    result == :aligned
    engine.runs.empty?
  end

  test "align! gives the image user the mount owner's uid and gid when it cannot write the mount" do
    Given "a hosted-runner mount: owned by 1001:1001, container user builder 1000:1000, unwritable"
    engine = FakeContainerEngine.new(capture_result: "1000 1000 builder builder 1001 1001 no\n")
    aligner = Dev::ContainerUserAligner.new(engine: engine)

    When "aligning"
    result = aligner.align!("dev-x")

    Then "the realign script runs as root with the user, group, old and new ids"
    result == :realigned
    engine.runs == [["exec", "--user", "root", "dev-x", "sh", "-c", SCRIPT.read, "sh", "builder", "builder", "1000", "1000", "1001", "1001"]]
  end

  test "align! hands a root-owned mount to the container's user instead of remapping the user to root" do
    Given "the engine created the host directory itself, so the mount is root-owned"
    engine = FakeContainerEngine.new(capture_result: "1000 1000 builder builder 0 0 no\n")
    aligner = Dev::ContainerUserAligner.new(engine: engine)

    When "aligning"
    result = aligner.align!("dev-x")

    Then "a chown of the mount, as root; no passwd edit"
    result == :adopted
    engine.runs == [["exec", "--user", "root", "dev-x", "chown", "1000:1000", "/var/lib/dev"]]
  end

  test "align! raises ProbeFailedError when the container cannot be probed: #{description}" do
    Given "a probe that #{description}"
    engine = FakeContainerEngine.new(capture_result: output)
    aligner = Dev::ContainerUserAligner.new(engine: engine)

    When "aligning"
    aligner.align!("dev-x")

    Then
    error = raises Dev::ContainerUserAligner::ProbeFailedError
    error.message.include?("dev-x")

    Where
    description          | output
    "fails"              | ""
    "answers garbage"    | "not what we asked\n"
  end

  test "align! raises RealignFailedError, naming container and uid, when the realign script fails" do
    Given "an unwritable mount and a root exec that fails"
    engine = FakeContainerEngine.new(capture_result: "1000 1000 builder builder 1001 1001 no\n") { |_args| false }
    aligner = Dev::ContainerUserAligner.new(engine: engine)

    When "aligning"
    aligner.align!("dev-x")

    Then
    error = raises Dev::ContainerUserAligner::RealignFailedError
    error.message.include?("dev-x")
    error.message.include?("1001")
  end

  test "the realign script is POSIX sh, edits passwd and group by name and old id, and re-owns by old id across the root filesystem only" do
    Given "the script shipped beside dev's bin"
    script = SCRIPT.read

    Expect "its contract, readable from the text"
    script.start_with?("#!/bin/sh")
    script.include?("/etc/passwd")
    script.include?("/etc/group")
    script.include?("find / -xdev -user")
    script.include?("find / -xdev -group")
    script.include?("chown -h")
    script.include?("chgrp -h")
    SCRIPT.executable?
  end

  test "the realign script parses under sh -n" do
    Expect "a clean syntax check"
    system("sh", "-n", SCRIPT.to_s)
  end
end
