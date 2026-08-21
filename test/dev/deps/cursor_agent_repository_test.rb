# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/cursor_agent_repository"
require "tmpdir"
require "fileutils"

transform!(RSpock::AST::Transformation)
class Dev::Deps::CursorAgentRepositoryTest < Minitest::Test
  # The served install script's load-bearing lines: the version is baked into
  # the download URL at serve time, which is what makes it pinnable.
  SCRIPT = <<~SCRIPT
    #!/bin/bash
    DOWNLOAD_URL="https://downloads.cursor.com/lab/2026.08.11-e8db854/${OS}/${ARCH}/agent-cli-package.tar.gz"
    FINAL_DIR="$HOME/.local/share/cursor-agent/versions/2026.08.11-e8db854"
  SCRIPT

  # Replays a canned curl result at the network boundary.
  class FixtureCursorAgentRepository < Dev::Deps::CursorAgentRepository
    def initialize(body:, success: true)
      super()
      @body = body
      @success = success
    end

    def fetch_install_script
      [@body, @success]
    end
  end

  def fetch_id
    {
      "name" => "cursor-agent",
      "integration" => "cursor_agent",
      "group" => "baseline",
      "install_dir" => "~/.dev/tools/cursor-agent",
    }
  end

  test "fetch pins the version the served install script bakes into its URL" do
    Given "a repository replaying the served script"
    repository = FixtureCursorAgentRepository.new(body: SCRIPT)

    When "resolving"
    dependency = repository.fetch(fetch_id)

    Then "the baked version is the pin and the install_dir rides the metadata"
    dependency.name == "cursor-agent"
    dependency.integration == :cursor_agent
    dependency.group == :baseline
    dependency.version == "2026.08.11-e8db854"
    dependency.metadata["install_dir"] == "~/.dev/tools/cursor-agent"

    Cleanup
    nil
  end

  test "a failed script fetch raises the fetch error" do
    Given "a repository whose curl fails"
    repository = FixtureCursorAgentRepository.new(body: "", success: false)

    When "resolving"
    repository.fetch(fetch_id)

    Then
    raises Dev::Deps::CursorAgentRepository::InstallScriptFetchError

    Cleanup
    nil
  end

  test "a script without a baked download URL raises the parse error" do
    Given "a repository replaying a script that drifted away from the known shape"
    repository = FixtureCursorAgentRepository.new(body: "#!/bin/bash\necho reshaped\n")

    When "resolving"
    repository.fetch(fetch_id)

    Then
    raises Dev::Deps::CursorAgentRepository::VersionParseError

    Cleanup
    nil
  end

  test "the real curl boundary resolves through whatever curl PATH serves" do
    Given "a fake curl at the front of PATH replaying the served script"
    dir = Dir.mktmpdir("dev-cursor-agent-repo-test-")
    script_file = File.join(dir, "install.sh")
    File.write(script_file, SCRIPT)
    fake_bin = File.join(dir, "bin")
    FileUtils.mkdir_p(fake_bin)
    File.write(File.join(fake_bin, "curl"), "#!/bin/sh\ncat \"#{script_file}\"\n")
    FileUtils.chmod(0o755, File.join(fake_bin, "curl"))
    original_path = ENV.fetch("PATH")
    ENV["PATH"] = "#{fake_bin}:#{original_path}"
    repository = Dev::Deps::CursorAgentRepository.new

    When "resolving through the real boundary"
    dependency = repository.fetch(fetch_id)

    Then "the fake-served script's baked version is the pin"
    dependency.version == "2026.08.11-e8db854"

    Cleanup
    ENV["PATH"] = original_path
    FileUtils.rm_rf(dir)
  end

  test "a host without curl maps to the fetch error, not a crash" do
    Given "a PATH serving no curl at all"
    dir = Dir.mktmpdir("dev-cursor-agent-repo-test-")
    empty_bin = File.join(dir, "bin")
    FileUtils.mkdir_p(empty_bin)
    original_path = ENV.fetch("PATH")
    ENV["PATH"] = empty_bin
    repository = Dev::Deps::CursorAgentRepository.new

    When "resolving through the real boundary"
    repository.fetch(fetch_id)

    Then
    raises Dev::Deps::CursorAgentRepository::InstallScriptFetchError

    Cleanup
    ENV["PATH"] = original_path
    FileUtils.rm_rf(dir)
  end
end
