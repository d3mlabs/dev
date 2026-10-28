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
    engine = FakeContainerEngine.new(capture_result: "1000 1000 builder builder 1000 1000 yes 1000\n")
    aligner = Dev::ContainerUserAligner.new(engine: engine, host_os: "darwin")

    When "aligning"
    result = aligner.align!("dev-x")

    Then "one probe as the container's user, nothing run as root"
    result == :aligned
    engine.captures == [["exec", "dev-x", "sh", "-c", PROBE]]
    engine.runs.empty?
  end

  test "align! leaves a writable mount alone even when the uids differ (a mapped mount)" do
    Given "a Mac-style mount: another owner reported, but writable"
    engine = FakeContainerEngine.new(capture_result: "1000 1000 builder builder 501 20 yes 1000\n")
    aligner = Dev::ContainerUserAligner.new(engine: engine, host_os: "darwin")

    When "aligning"
    result = aligner.align!("dev-x")

    Then
    result == :aligned
    engine.runs.empty?
  end

  test "align! gives the image user the mount owner's uid and gid when it cannot write the mount" do
    Given "a hosted-runner mount: owned by 1001:1001, container user builder 1000:1000, unwritable"
    engine = FakeContainerEngine.new(capture_result: "1000 1000 builder builder 1001 1001 no 1001\n")
    aligner = Dev::ContainerUserAligner.new(engine: engine, host_os: "darwin")

    When "aligning"
    result = aligner.align!("dev-x")

    Then "the realign script runs as root with the user, group, old and new ids"
    result == :realigned
    engine.runs == [["exec", "--user", "root", "dev-x", "sh", "-c", SCRIPT.read, "sh", "builder", "builder", "1000", "1000", "1001", "1001"]]
  end

  test "align! hands a root-owned mount to the container's user instead of remapping the user to root" do
    Given "the engine created the host directory itself, so the mount is root-owned"
    engine = FakeContainerEngine.new(capture_result: "1000 1000 builder builder 0 0 no 1000\n")
    aligner = Dev::ContainerUserAligner.new(engine: engine, host_os: "darwin")

    When "aligning"
    result = aligner.align!("dev-x")

    Then "a chown of the mount, as root; no passwd edit"
    result == :adopted
    engine.runs == [["exec", "--user", "root", "dev-x", "chown", "1000:1000", "/var/lib/dev"]]
  end

  test "on a Linux bind mount the container's user is the host caller, in the root's group: #{what}" do
    Given "a shared data root (<user>:dev 2775, dev#310) bind-mounted on a Linux host whose caller is uid #{host_uid}"
    engine = FakeContainerEngine.new(capture_result: "#{uid} #{gid} builder builder 1000 1002 #{writable} #{host_uid}\n")
    aligner = Dev::ContainerUserAligner.new(engine: engine, host_os: "linux", host_uid: host_uid)

    When "aligning"
    result = aligner.align!("dev-x")

    Then "the image user takes the caller's uid and the root's gid, whatever the mount's owner — or nothing, when it has them"
    result == expected
    engine.runs == (expected == :aligned ? [] : [["exec", "--user", "root", "dev-x", "sh", "-c", SCRIPT.read, "sh", "builder", "builder", uid.to_s, gid.to_s, host_uid.to_s, "1002"]])

    Where
    what                                                         | host_uid | uid  | gid  | writable | expected
    "the operator owns the root; the image user is its uid"      | 1000     | 1000 | 1000 | "yes"    | :realigned
    "the runner user: writable by the image uid, not the caller" | 1002     | 1000 | 1000 | "yes"    | :realigned
    "a hosted runner at 1001 against an image user at 1000"      | 1001     | 1000 | 1000 | "no"     | :realigned
    "already the caller in the root's group"                     | 1002     | 1002 | 1002 | "yes"    | :aligned
  end

  test "on a Linux bind mount a root-owned data root is still handed to the container's user, not the caller remapped to root" do
    Given "the engine created the host directory itself"
    engine = FakeContainerEngine.new(capture_result: "1000 1000 builder builder 0 0 no 1000\n")
    aligner = Dev::ContainerUserAligner.new(engine: engine, host_os: "linux", host_uid: 1002)

    When "aligning"
    result = aligner.align!("dev-x")

    Then
    result == :adopted
    engine.runs == [["exec", "--user", "root", "dev-x", "chown", "1000:1000", "/var/lib/dev"]]
  end

  # The prefix volume is the host user's own on Linux (BuildContainer.prefix_volume),
  # but docker initialises a fresh one from the image — owned by the image's
  # user, uid 1000 — while the container's user is the caller. Brew's only
  # writer is the prefix's owner, so the volume is handed over with the ids.
  test "a Linuxbrew prefix volume owned by another uid is handed to the container's user once it has its ids: #{what}" do
    Given "a Linux caller at 1002 whose fresh prefix volume still carries the image user's uid"
    engine = FakeContainerEngine.new(capture_result: "#{uid} #{gid} builder builder 1000 1002 yes #{prefix_owner}\n")
    aligner = Dev::ContainerUserAligner.new(engine: engine, host_os: "linux", host_uid: 1002)

    When "aligning"
    result = aligner.align!("dev-x")

    Then "a recursive chown of the prefix mount as root, after any realign; nothing when the owner already matches or the prefix is not there"
    result == expected
    engine.runs == runs.call

    Where
    what                                         | uid  | gid  | prefix_owner | expected         | runs
    "realigned, then the prefix"                 | 1000 | 1000 | 1000         | :realigned       | -> { [["exec", "--user", "root", "dev-x", "sh", "-c", SCRIPT.read, "sh", "builder", "builder", "1000", "1000", "1002", "1002"], ["exec", "--user", "root", "dev-x", "chown", "-R", "1002:1002", "/home/linuxbrew/.linuxbrew"]] }
    "user already aligned, prefix not"           | 1002 | 1002 | 1000         | :prefix_adopted  | -> { [["exec", "--user", "root", "dev-x", "chown", "-R", "1002:1002", "/home/linuxbrew/.linuxbrew"]] }
    "both aligned"                               | 1002 | 1002 | 1002         | :aligned         | -> { [] }
    "no prefix mounted"                          | 1002 | 1002 | "-"          | :aligned         | -> { [] }
  end

  test "handing over the prefix volume raises RealignFailedError when the chown fails" do
    Given
    engine = FakeContainerEngine.new(capture_result: "1002 1002 builder builder 1000 1002 yes 1000\n") { |_args| false }
    aligner = Dev::ContainerUserAligner.new(engine: engine, host_os: "linux", host_uid: 1002)

    When
    aligner.align!("dev-x")

    Then
    error = raises Dev::ContainerUserAligner::RealignFailedError
    error.message.include?("1002")
  end

  test "align! raises ProbeFailedError when the container cannot be probed: #{description}" do
    Given "a probe that #{description}"
    engine = FakeContainerEngine.new(capture_result: output)
    aligner = Dev::ContainerUserAligner.new(engine: engine, host_os: "darwin")

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
    engine = FakeContainerEngine.new(capture_result: "1000 1000 builder builder 1001 1001 no 1001\n") { |_args| false }
    aligner = Dev::ContainerUserAligner.new(engine: engine, host_os: "darwin")

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
    script.include?("find / -xdev")
    script.include?("-user \"$old_uid\" -exec chown -h \"$uid\"")
    script.include?("-group \"$old_gid\" -exec chgrp -h \"$gid\"")
    SCRIPT.executable?
  end

  test "the realign script walks the filesystem once and leaves regular files inside the Cellar at the old ids" do
    Given "the script shipped beside dev's bin"
    script = SCRIPT.read

    Expect "one find, with the Cellar's regular files pruned before either ownership test (overlay copy-up is paid per byte, and poured kegs are never written into)"
    script.scan(/^find /).size == 1
    script.include?("cellar=\"/home/linuxbrew/.linuxbrew/Cellar\"")
    script.include?("\\( -type f -path \"$cellar/*\" -prune \\) -o")
  end

  test "the realign script parses under sh -n" do
    Expect "a clean syntax check"
    system("sh", "-n", SCRIPT.to_s)
  end
end
