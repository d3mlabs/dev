# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/tap_pinner"
require "fileutils"
require "open3"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::TapPinnerTest < Minitest::Test
  # A git repository standing in for a tap's remote, with two commits.
  #
  # @param dir [Pathname]
  # @return [Array<String>] the two commit SHAs, oldest first
  def self.seed_remote(dir)
    dir.mkpath
    git = ->(*args) { Open3.capture3("git", "-C", dir.to_s, *args).fetch(0).strip }
    git.call("init", "-q")
    git.call("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "one")
    first = git.call("rev-parse", "HEAD")
    git.call("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "two")
    [first, git.call("rev-parse", "HEAD")]
  end

  def head_of(dir)
    Open3.capture3("git", "-C", dir.to_s, "rev-parse", "HEAD").fetch(0).strip
  end

  test "pin! creates the tap at brew's layout and checks out the commit, fetching only that commit" do
    Given "a remote with two commits and no tap checked out yet"
    tmp = Pathname(Dir.mktmpdir("dev-tap-pinner-"))
    first, second = self.class.seed_remote(tmp / "remote")
    pinner = Dev::Deps::TapPinner.new(taps_root: tmp / "Taps", remote_urls: { "someorg/sometap" => (tmp / "remote").to_s })

    When "pinning the older commit"
    pinner.pin!("someorg/sometap", first)

    Then "the tap sits where brew looks for it, at that commit, as a single-commit clone"
    tap_dir = tmp / "Taps" / "someorg" / "homebrew-sometap"
    head_of(tap_dir) == first
    head_of(tap_dir) != second
    Open3.capture3("git", "-C", tap_dir.to_s, "rev-list", "--count", "HEAD").fetch(0).strip == "1"

    Cleanup
    FileUtils.rm_rf(tmp)
  end

  test "pin! moves an existing tap to the commit" do
    Given "a tap already pinned at one commit"
    tmp = Pathname(Dir.mktmpdir("dev-tap-pinner-"))
    first, second = self.class.seed_remote(tmp / "remote")
    pinner = Dev::Deps::TapPinner.new(taps_root: tmp / "Taps", remote_urls: { "someorg/sometap" => (tmp / "remote").to_s })
    pinner.pin!("someorg/sometap", first)

    When "pinning the other commit"
    pinner.pin!("someorg/sometap", second)

    Then
    head_of(tmp / "Taps" / "someorg" / "homebrew-sometap") == second

    Cleanup
    FileUtils.rm_rf(tmp)
  end

  test "pin! raises PinError naming the tap and commit when the remote has no such commit" do
    Given "a remote and a commit it does not have"
    tmp = Pathname(Dir.mktmpdir("dev-tap-pinner-"))
    self.class.seed_remote(tmp / "remote")
    pinner = Dev::Deps::TapPinner.new(taps_root: tmp / "Taps", remote_urls: { "someorg/sometap" => (tmp / "remote").to_s })

    When "pinning"
    pinner.pin!("someorg/sometap", "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")

    Then
    error = raises Dev::Deps::TapPinner::PinError
    error.message.include?("someorg/sometap")
    error.message.include?("deadbeef")

    Cleanup
    FileUtils.rm_rf(tmp)
  end

  test "remote_url defaults to the tap's GitHub repository" do
    Given "a pinner with no explicit URLs"
    pinner = Dev::Deps::TapPinner.new(taps_root: Pathname("/nonexistent"))

    Expect "brew's naming convention: github.com/<user>/homebrew-<repo>"
    pinner.remote_url("homebrew/core") == "https://github.com/homebrew/homebrew-core"
    pinner.remote_url("d3mlabs/d3mlabs") == "https://github.com/d3mlabs/homebrew-d3mlabs"
  end
end
