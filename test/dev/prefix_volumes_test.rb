# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/prefix_volumes"
require "support/fake_container_engine"

transform!(RSpock::AST::Transformation)
class Dev::PrefixVolumesTest < Minitest::Test
  include SorbetHelper

  # `docker volume ls` filtered by name is a substring match; `docker ps -a
  # --filter volume=<name>` names every container mounting it, running or not.
  def engine(volumes:, mounted: {})
    FakeContainerEngine.new(capture_result: lambda { |args|
      case args
      in ["volume", "ls", *] then volumes.map { |v| "#{v}\n" }.join
      in ["ps", "-a", "--filter", /\Avolume=(.*)\z/ => filter, *] then mounted.fetch(filter.delete_prefix("volume="), []).map { |c| "#{c}\n" }.join
      else ""
      end
    })
  end

  def volumes(engine, host_os: "linux", users: %w[jpduchesne runner])
    Dev::PrefixVolumes.new(engine: engine, host_os: host_os, user_exists: ->(name) { users.include?(name) })
  end

  test "on Linux every dev-linuxbrew* volume is listed with the host user its name carries; one naming no host user is stale, the bare legacy name included" do
    Given "an engine after the per-user split: both users' volumes, the legacy one, a renamed user's, and something else named like ours"
    eng = engine(volumes: %w[dev-linuxbrew-runner dev-linuxbrew dev-linuxbrew-jpduchesne dev-linuxbrew-olduser dev-linuxbrew-extra-thing other],
      mounted: { "dev-linuxbrew" => %w[dev-snappy-linux-abc], "dev-linuxbrew-runner" => %w[dev-snappy-linux-def] })

    When
    listed = volumes(eng).list

    Then "sorted by name; user and staleness decoded; mounted_by from the engine"
    listed.map(&:name) == %w[dev-linuxbrew dev-linuxbrew-extra-thing dev-linuxbrew-jpduchesne dev-linuxbrew-olduser dev-linuxbrew-runner]
    listed.map(&:user) == [nil, "extra-thing", "jpduchesne", "olduser", "runner"]
    listed.map(&:stale) == [true, true, false, true, false]
    listed.find { |v| v.name == "dev-linuxbrew" }.mounted_by == %w[dev-snappy-linux-abc]
    listed.find { |v| v.name == "dev-linuxbrew-runner" }.mounted_by == %w[dev-snappy-linux-def]
    listed.find { |v| v.name == "dev-linuxbrew-olduser" }.mounted_by == []
    volumes(eng).stale.map(&:name) == %w[dev-linuxbrew dev-linuxbrew-extra-thing dev-linuxbrew-olduser]
  end

  test "on a Mac the VM's one volume is the bare name and never stale; a suffixed one has no owner there" do
    Given
    eng = engine(volumes: %w[dev-linuxbrew dev-linuxbrew-jp])

    Expect
    volumes(eng, host_os: "darwin").list.map { |v| [v.name, v.stale] } == [["dev-linuxbrew", false], ["dev-linuxbrew-jp", true]]
    volumes(eng, host_os: "darwin").list.fetch(0).describe == "dev-linuxbrew (the VM's)"
  end

  test "describe: the owner for a live volume; the reason and the command for a stale one, naming its containers first when it has any" do
    Given
    eng = engine(volumes: %w[dev-linuxbrew-runner dev-linuxbrew dev-linuxbrew-olduser],
      mounted: { "dev-linuxbrew" => %w[dev-snappy-linux-abc] })
    listed = volumes(eng).list

    Expect
    listed.map(&:describe) == [
      "dev-linuxbrew — stale: no host user; mounted by dev-snappy-linux-abc (dev container up there recreates it, then dev cache gc)",
      "dev-linuxbrew-olduser — stale: no host user olduser (dev cache gc removes it)",
      "dev-linuxbrew-runner (runner)",
    ]
  end

  test "remove! drops one volume and reports whether the engine agreed; an engine that lists nothing yields nothing" do
    Given
    eng = engine(volumes: %w[dev-linuxbrew-olduser])
    refusing = FakeContainerEngine.new(capture_result: "dev-linuxbrew-olduser\n") { |_args| false }

    Expect
    volumes(eng).remove!(volumes(eng).list.fetch(0)) == true
    eng.runs == [["volume", "rm", "dev-linuxbrew-olduser"]]
    volumes(refusing).remove!(volumes(refusing).list.fetch(0)) == false
    volumes(FakeContainerEngine.new).list == []
  end

  test "the default user lookup asks passwd" do
    Expect
    Dev::PrefixVolumes.user_exists?(Etc.getpwuid(Process.uid).name) == true
    Dev::PrefixVolumes.user_exists?("no-such-user-#{Process.pid}") == false
  end
end
