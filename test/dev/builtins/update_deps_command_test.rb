# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/builtins/update_deps_command"
require "fileutils"
require "pathname"
require "stringio"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Builtins::UpdateDepsCommandTest < Minitest::Test
  include SorbetHelper

  test "traits: staleness-exempt (it IS the remediation), never stamps" do
    Given "the builtin"
    command = Dev::Builtins::UpdateDepsCommand.new

    Expect "the declarative traits"
    command.staleness_exempt? == true
    command.stamps? == false
    !command.hidden?
    command.desc.include?("lockfiles")
  end

  test "call resolves an empty manifest and reports the update" do
    Given "a project root with no dependencies.rb"
    root = Pathname.new(Dir.mktmpdir("update-deps-empty-"))
    Dev::ShadowenvRuby.stubs(:converge!)
    command = Dev::Builtins::UpdateDepsCommand.new
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update"
    command.call(args: [], context: build_context(root))

    Then "the run completes and points at dev up"
    $stdout.string.include?("lockfiles updated")

    Cleanup
    $stdout = old_stdout
    FileUtils.rm_rf(root)
  end

  test "call locks each integration's declarations before resolving" do
    Given "a manifest with a gem declaration, and a locker wired for :bundler"
    root = Pathname.new(Dir.mktmpdir("update-deps-lock-"))
    File.write(root / "dependencies.rb", <<~RUBY)
      require "dev/deps"
      Dev::Deps.define { gem "rake" }
    RUBY
    locker = mock
    locker.expects(:lock).with { |*args| args.fetch(0).map(&:name) == ["rake"] }
    Dev::Deps::Registry.expects(:lockers).returns({ bundler: locker })
    Dev::Deps::Resolver.expects(:new).returns(stub(resolve: []))
    Dev::ShadowenvRuby.stubs(:converge!)
    command = Dev::Builtins::UpdateDepsCommand.new
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update"
    command.call(args: [], context: build_context(root))

    Then "the locker received the bundler declarations (asserted on the mock)"
    $stdout.string.include?("lockfiles updated")

    Cleanup
    $stdout = old_stdout
    FileUtils.rm_rf(root)
  end

  test "call provisions the project's Ruby before any locker runs" do
    Given "a manifest with a gem declaration; provisioning and locking both observed in order"
    root = Pathname.new(Dir.mktmpdir("update-deps-provision-"))
    File.write(root / "dependencies.rb", <<~RUBY)
      require "dev/deps"
      Dev::Deps.define { gem "rake" }
    RUBY
    order = sequence("provision then lock")
    Dev::ShadowenvRuby.expects(:converge!).with(ruby_version: "4.0.1", project_root: root).once.in_sequence(order)
    locker = mock
    locker.expects(:lock).in_sequence(order)
    Dev::Deps::Registry.expects(:lockers).returns({ bundler: locker })
    Dev::Deps::Resolver.expects(:new).returns(stub(resolve: []))
    command = Dev::Builtins::UpdateDepsCommand.new
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update"
    command.call(args: [], context: build_context(root))

    Then "a fresh checkout has a .shadowenv.d before bundle lock is wrapped in it (asserted on the mocks)"
    $stdout.string.include?("lockfiles updated")

    Cleanup
    $stdout = old_stdout
    FileUtils.rm_rf(root)
  end

  test "call warns for each build-group formula the image build would compile from source" do
    Given "a resolution with a bottled build formula, a source-only build formula, a source-only app formula, " \
      "and a source-only build formula gated to Macs"
    root = Pathname.new(Dir.mktmpdir("update-deps-preflight-"))
    resolved = [
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build, version: "4.4.3", hash: nil,
        metadata: { "format" => "bottle" }),
      Dev::Deps::Dependency.new(name: "wwise-cli", integration: :brew, group: :build, version: "1.0.0", hash: nil,
        metadata: { "tap" => "d3mlabs/d3mlabs", "format" => "source" }),
      Dev::Deps::Dependency.new(name: "jq", integration: :brew, group: :app, version: "1.7", hash: nil,
        metadata: { "format" => "source" }),
      Dev::Deps::Dependency.new(name: "xcodes", integration: :brew, group: :build, version: "1.6.2", hash: nil,
        metadata: { "tap" => "xcodesorg/made", "host" => "darwin", "format" => "source" }),
    ]
    Dev::Deps::Resolver.expects(:new).returns(stub(resolve: resolved))
    Dev::ShadowenvRuby.stubs(:converge!)
    command = Dev::Builtins::UpdateDepsCommand.new
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update"
    command.call(args: [], context: build_context(root))

    Then "only the source formula the image build installs is named — format matters there, and the Mac-only one never reaches the image"
    $stdout.string.include?("wwise-cli has no x86_64_linux bottle")
    !$stdout.string.include?("cmake has no")
    !$stdout.string.include?("jq has no")
    !$stdout.string.include?("xcodes has no")
    $stdout.string.include?("lockfiles updated")

    Cleanup
    $stdout = old_stdout
    FileUtils.rm_rf(root)
  end

  test "call does not mistake a previously loaded project's config for this one" do
    Given "a stale config from an earlier load, and a dependencies.rb that never calls Dev::Deps.define"
    Dev::Deps.define { ruby "9.9.9" }
    root = Pathname.new(Dir.mktmpdir("update-deps-stale-"))
    File.write(root / "dependencies.rb", "UPDATE_DEPS_TEST_CONSTANT = 1 unless defined?(UPDATE_DEPS_TEST_CONSTANT)\n")
    Dev::ShadowenvRuby.stubs(:converge!)
    command = Dev::Builtins::UpdateDepsCommand.new
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update"
    command.call(args: [], context: build_context(root))

    Then "the run resolved an empty config (a leaked ruby pin would try to resolve it)"
    Dev::Deps.last_config.ruby_version_requirement.nil?

    Cleanup
    $stdout = old_stdout
    FileUtils.rm_rf(root)
  end

  private

  def build_context(project_root)
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui),
      project: Dev::ProjectContext.new(name: "TestProject", root: project_root, ruby_version: "4.0.1"),
    )
  end
end
