# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/cursor_agent_integration"
require "dev/deps/cursor_agent_repository"
require "dev/deps/dependency"
require "dev/deps/cache"
require "tmpdir"
require "fileutils"

transform!(RSpock::AST::Transformation)
class Dev::Deps::CursorAgentIntegrationTest < Minitest::Test
  # Stubs the download boundary: records the URL and plants a real package
  # tarball (one top-level dir, like the served artifact) at the destination.
  class FixtureCursorAgentIntegration < Dev::Deps::CursorAgentIntegration
    attr_reader :downloaded_urls

    def initialize(tarball:, **kwargs)
      super(**kwargs)
      @tarball = tarball
      @downloaded_urls = []
    end

    def download_package(url, archive_path)
      @downloaded_urls << url
      FileUtils.cp(@tarball, archive_path)
    end
  end

  # A real tar.gz shaped like the served package: a single top-level dir
  # wrapping the cursor-agent binary (the install strips it, like the
  # official script's --strip-components=1).
  def build_package_tarball(dir)
    payload = File.join(dir, "package", "dist-package")
    FileUtils.mkdir_p(payload)
    File.write(File.join(payload, "cursor-agent"), "#!/bin/sh\necho agent\n")
    tarball = File.join(dir, "agent-cli-package.tar.gz")
    system("tar", "-czf", tarball, "-C", File.join(dir, "package"), "dist-package") || raise("tar failed")
    tarball
  end

  def build_dependency(install_dir)
    Dev::Deps::Dependency.new(
      name: "cursor-agent", integration: :cursor_agent, group: :baseline,
      version: "2026.08.11-e8db854", hash: nil,
      metadata: { "install_dir" => install_dir },
    )
  end

  def build_integration(dir, tarball)
    FixtureCursorAgentIntegration.new(
      tarball: tarball,
      repository: Dev::Deps::CursorAgentRepository.new,
      cache: Dev::Deps::Cache.new(cache_dir: File.join(dir, "cache")),
    )
  end

  test "install materializes the version-keyed dir with marker and current pointer" do
    Given "a locked dep and a fixture package"
    dir = Dir.mktmpdir("dev-cursor-agent-test-")
    install_dir = File.join(dir, "tools", "cursor-agent")
    integration = build_integration(dir, build_package_tarball(dir))

    When "installing"
    integration.install_all([build_dependency(install_dir)])

    Then "the binary landed versioned, marker stamped, current pointing at it"
    File.exist?(File.join(install_dir, "2026.08.11-e8db854", "cursor-agent"))
    File.read(File.join(install_dir, "2026.08.11-e8db854", ".dev-cursor-agent")).strip == "2026.08.11-e8db854"
    File.readlink(File.join(install_dir, "current")) == "2026.08.11-e8db854"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the download URL carries the locked version and this host's os/arch" do
    Given "a locked dep"
    dir = Dir.mktmpdir("dev-cursor-agent-test-")
    integration = build_integration(dir, build_package_tarball(dir))

    When "installing"
    integration.install_all([build_dependency(File.join(dir, "tools"))])
    url = integration.downloaded_urls.fetch(0)

    Then "the URL is the served scheme, pinned to the lock"
    url.start_with?("https://downloads.cursor.com/lab/2026.08.11-e8db854/")
    url.end_with?("/agent-cli-package.tar.gz")
    %w[darwin linux].any? { |os| url.include?("/#{os}/") }
    %w[arm64 x64].any? { |arch| url.include?("/#{arch}/") }

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a published version is skipped without re-downloading" do
    Given "an already-installed version"
    dir = Dir.mktmpdir("dev-cursor-agent-test-")
    install_dir = File.join(dir, "tools", "cursor-agent")
    tarball = build_package_tarball(dir)
    build_integration(dir, tarball).install_all([build_dependency(install_dir)])
    integration = build_integration(dir, tarball)

    When "installing again"
    integration.install_all([build_dependency(install_dir)])

    Then "idempotent: no second download"
    integration.downloaded_urls.empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a concurrently published version is left intact and still pointed at" do
    Given "a version dir another job already published mid-download (content, no readable marker yet)"
    dir = Dir.mktmpdir("dev-cursor-agent-test-")
    install_dir = File.join(dir, "tools", "cursor-agent")
    occupied = File.join(install_dir, "2026.08.11-e8db854")
    FileUtils.mkdir_p(occupied)
    File.write(File.join(occupied, "cursor-agent"), "the concurrent winner's binary\n")
    integration = build_integration(dir, build_package_tarball(dir))

    When "installing into the occupied slot"
    integration.install_all([build_dependency(install_dir)])

    Then "first writer wins — the existing dir survives and current points at it"
    File.read(File.join(occupied, "cursor-agent")) == "the concurrent winner's binary\n"
    File.readlink(File.join(install_dir, "current")) == "2026.08.11-e8db854"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  # The real curl boundary, exercised through a fake curl on PATH — the same
  # argv the integration passes, no network.
  def with_fake_curl(dir, script_body)
    fake_bin = File.join(dir, "bin")
    FileUtils.mkdir_p(fake_bin)
    File.write(File.join(fake_bin, "curl"), script_body)
    FileUtils.chmod(0o755, File.join(fake_bin, "curl"))
    original_path = ENV.fetch("PATH")
    ENV["PATH"] = "#{fake_bin}:#{original_path}"
    original_path
  end

  test "the real download boundary installs through whatever curl PATH serves" do
    Given "a fake curl that writes the fixture package to curl's -o destination"
    dir = Dir.mktmpdir("dev-cursor-agent-test-")
    install_dir = File.join(dir, "tools", "cursor-agent")
    tarball = build_package_tarball(dir)
    original_path = with_fake_curl(dir, <<~SH)
      #!/bin/sh
      while [ $# -gt 1 ]; do
        if [ "$1" = "-o" ]; then cp "#{tarball}" "$2"; exit 0; fi
        shift
      done
      exit 1
    SH
    integration = Dev::Deps::CursorAgentIntegration.new(
      repository: Dev::Deps::CursorAgentRepository.new,
      cache: Dev::Deps::Cache.new(cache_dir: File.join(dir, "cache")),
    )

    When "installing through the real download path"
    integration.install_all([build_dependency(install_dir)])

    Then "the binary landed exactly as with the stubbed boundary"
    File.exist?(File.join(install_dir, "2026.08.11-e8db854", "cursor-agent"))

    Cleanup
    ENV["PATH"] = original_path
    FileUtils.rm_rf(dir)
  end

  test "a failed download raises DownloadError" do
    Given "a curl that always fails"
    dir = Dir.mktmpdir("dev-cursor-agent-test-")
    original_path = with_fake_curl(dir, "#!/bin/sh\nexit 22\n")
    integration = Dev::Deps::CursorAgentIntegration.new(
      repository: Dev::Deps::CursorAgentRepository.new,
      cache: Dev::Deps::Cache.new(cache_dir: File.join(dir, "cache")),
    )

    When "installing"
    integration.install_all([build_dependency(File.join(dir, "tools", "cursor-agent"))])

    Then
    raises Dev::Deps::CursorAgentIntegration::DownloadError

    Cleanup
    ENV["PATH"] = original_path
    FileUtils.rm_rf(dir)
  end

  test "a corrupt package raises ExtractionError" do
    Given "a curl that serves bytes tar cannot read"
    dir = Dir.mktmpdir("dev-cursor-agent-test-")
    original_path = with_fake_curl(dir, <<~SH)
      #!/bin/sh
      while [ $# -gt 1 ]; do
        if [ "$1" = "-o" ]; then echo "not a tarball" > "$2"; exit 0; fi
        shift
      done
      exit 1
    SH
    integration = Dev::Deps::CursorAgentIntegration.new(
      repository: Dev::Deps::CursorAgentRepository.new,
      cache: Dev::Deps::Cache.new(cache_dir: File.join(dir, "cache")),
    )

    When "installing"
    integration.install_all([build_dependency(File.join(dir, "tools", "cursor-agent"))])

    Then
    raises Dev::Deps::CursorAgentIntegration::ExtractionError

    Cleanup
    ENV["PATH"] = original_path
    FileUtils.rm_rf(dir)
  end
end
