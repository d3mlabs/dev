# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps"
require "dev/deps/lockfile"
require "dev/deps/registry"
require "dev/deps/resolver"
require "tmpdir"
require "yaml"

# What an apt declaration becomes in build-deps.lock: the portable identity
# (package, source, architectures, recommends) at the suite address, filtered
# to Linux hosts. The installed version is the host's fact, never the lock's.
transform!(RSpock::AST::Transformation)
class Dev::Deps::AptLockShapeTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("apt-lock-shape-test-")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  test "apt declarations lock as package + source + flags at `version: suite`, host-scoped to linux" do
    Given "WineHQ and a distro package declared for Linux build hosts"
    config = Dev::Deps.define do
      group :build, host: :linux do
        apt "winehq-stable",
          source: {
            key: "https://dl.winehq.org/wine-builds/winehq.key",
            keyring: "/etc/apt/keyrings/winehq-archive.key",
            sources: "https://dl.winehq.org/wine-builds/ubuntu/dists/%{codename}/winehq-%{codename}.sources",
          },
          architectures: [:i386],
          recommends: true
        apt "xvfb"
      end
    end
    root = Pathname(@dir)
    resolver = Dev::Deps::Resolver.new(
      repositories: Dev::Deps::Registry.repositories(project_root: root),
      schemes: Dev::Deps::Registry.schemes,
    )

    When "resolving and locking"
    deps = resolver.resolve(config.declarations)
    Dev::Deps::Lockfile.new(dir: root).lock(deps)
    lock = YAML.safe_load(File.read(File.join(@dir, "build-deps.lock")))

    Then "the lock pins what is portable and says the suite's current build is what installs"
    lock == {
      "apt" => {
        "winehq-stable" => {
          "group" => "build",
          "version" => "suite",
          "source" => {
            "key" => "https://dl.winehq.org/wine-builds/winehq.key",
            "keyring" => "/etc/apt/keyrings/winehq-archive.key",
            "sources" => "https://dl.winehq.org/wine-builds/ubuntu/dists/%{codename}/winehq-%{codename}.sources",
          },
          "architectures" => ["i386"],
          "recommends" => true,
          "host" => "linux",
        },
        "xvfb" => { "group" => "build", "version" => "suite", "host" => "linux" },
      },
    }
    Dev::Deps::Lockfile.new(dir: root).read == deps
  end
end
