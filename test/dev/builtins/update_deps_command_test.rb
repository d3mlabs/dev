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
    command = Dev::Builtins::UpdateDepsCommand.new
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update"
    command.call(args: no_args, context: build_context(root))

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
    command = Dev::Builtins::UpdateDepsCommand.new
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update"
    command.call(args: no_args, context: build_context(root))

    Then "the locker received the bundler declarations (asserted on the mock)"
    $stdout.string.include?("lockfiles updated")

    Cleanup
    $stdout = old_stdout
    FileUtils.rm_rf(root)
  end

  test "call installs the locked interpreters through brew before any locker runs, and locks the Gemfile to that Ruby" do
    Given "a manifest declaring a Ruby range and a gem; resolution, the brew install and the locker all observed in order"
    root = Pathname.new(Dir.mktmpdir("update-deps-interpreters-"))
    File.write(root / "dependencies.rb", <<~RUBY)
      require "dev/deps"
      Dev::Deps.define do
        ruby "~> 4.0"
        gem "rake"
      end
    RUBY
    ruby_pin = Dev::Deps::Dependency.new(name: "ruby", integration: :ruby, group: :app, version: "4.0.9", hash: nil,
      metadata: { "tap" => "d3mlabs/d3mlabs", "version_suffix" => "4.0.9" })
    resolver = mock
    resolver.expects(:resolve).with { |*args| args.fetch(0).map(&:integration) == [:ruby] }.returns([ruby_pin])
    resolver.expects(:resolve).with { |*args| args.fetch(0).map(&:integration) == [:ruby, :bundler] }.returns([ruby_pin])
    Dev::Deps::Resolver.expects(:new).returns(resolver)
    order = sequence("install the interpreter, then lock")
    brew = mock
    brew.expects(:install_all).with([ruby_pin]).in_sequence(order)
    Dev::Deps::Registry.expects(:host_integrations).with { |**kwargs| kwargs.fetch(:project_root) == root }
      .returns({ brew: brew, ruby: brew })
    locker = mock
    locker.expects(:lock).in_sequence(order)
    Dev::Deps::Registry.expects(:lockers).with(project_root: root, ruby_version: "4.0.9").returns({ bundler: locker })
    command = Dev::Builtins::UpdateDepsCommand.new
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update"
    command.call(args: no_args, context: build_context(root))

    Then "bundle lock ran under the locked Ruby, whose exact version is the Gemfile's ruby directive (asserted on the mocks)"
    $stdout.string.include?("lockfiles updated")
    Dev::Deps::Lockfile.new(dir: root).read.map { |dep| [dep.integration, dep.name, dep.version] } == [[:ruby, "ruby", "4.0.9"]]

    Cleanup
    $stdout = old_stdout
    FileUtils.rm_rf(root)
  end

  test "call installs nothing before locking when the manifest declares no interpreter" do
    Given "a manifest with a gem and no ruby or python line"
    root = Pathname.new(Dir.mktmpdir("update-deps-no-interpreter-"))
    File.write(root / "dependencies.rb", <<~RUBY)
      require "dev/deps"
      Dev::Deps.define { gem "rake" }
    RUBY
    Dev::Deps::Registry.expects(:host_integrations).never
    locker = mock
    locker.expects(:lock)
    Dev::Deps::Registry.expects(:lockers).with(project_root: root, ruby_version: nil).returns({ bundler: locker })
    Dev::Deps::Resolver.expects(:new).returns(stub(resolve: []))
    command = Dev::Builtins::UpdateDepsCommand.new
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update"
    command.call(args: no_args, context: build_context(root))

    Then "no Ruby is provisioned for a project that declares none (asserted on the mocks)"
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
    command = Dev::Builtins::UpdateDepsCommand.new
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update"
    command.call(args: no_args, context: build_context(root))

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

  test "call re-locks a checkout that still carries build-deps.lock, folding it into deps.lock and removing it" do
    Given "a checkout last locked by a dev that wrote two files"
    root = Pathname.new(Dir.mktmpdir("update-deps-retired-"))
    (root / "deps.lock").write("cmake:\n  boost: { group: app, version: '1.90.0' }\n")
    (root / "build-deps.lock").write("brew:\n  cmake: { group: build, version: '3.31' }\n")
    resolved = [
      Dev::Deps::Dependency.new(name: "boost", integration: :cmake, group: :app, version: "1.90.0", hash: nil,
        metadata: {}),
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build, version: "3.31", hash: nil,
        metadata: {}),
    ]
    Dev::Deps::Resolver.expects(:new).returns(stub(resolve: resolved))
    command = Dev::Builtins::UpdateDepsCommand.new
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update — the command the refusal points at"
    command.call(args: no_args, context: build_context(root))

    Then "one lockfile holds both pins and the retired file is gone"
    !(root / "build-deps.lock").exist?
    Dev::Deps::Lockfile.new(dir: root).read.map(&:name).sort == ["boost", "cmake"]

    Cleanup
    $stdout = old_stdout
    FileUtils.rm_rf(root)
  end

  test "call keeps an unchanged tap's commit from the lock on disk — a re-lock that moves no formula writes the same bytes" do
    Given "a lock written at one core commit, and a resolution of the very same pins at a newer one"
    root = Pathname.new(Dir.mktmpdir("update-deps-carryover-"))
    platforms = { "x86_64_linux" => { "hash" => "SHA256=l", "link" => "https://x/l" } }
    pin = ->(commit) do
      Dev::Deps::Dependency.new(name: "cmake", integration: :brew, group: :build, version: "4.4.4", hash: nil,
        metadata: { "tap_commit" => commit, "format" => "bottle", "platforms" => platforms })
    end
    Dev::Deps::Lockfile.new(dir: root).lock([pin.call("0f1ba9ea")])
    before = (root / "deps.lock").read
    Dev::Deps::Resolver.expects(:new).returns(stub(resolve: [pin.call("7d2877eb")]))
    command = Dev::Builtins::UpdateDepsCommand.new
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update"
    command.call(args: no_args, context: build_context(root))

    Then "deps.lock is byte-identical to what was there"
    (root / "deps.lock").read == before

    Cleanup
    $stdout = old_stdout
    FileUtils.rm_rf(root)
  end

  test "call hands the resolver the needs table: every built-in integration's own manifest, read as a library" do
    Given "an empty manifest, and the resolver construction observed"
    root = Pathname.new(Dir.mktmpdir("update-deps-needs-"))
    received = nil
    Dev::Deps::Resolver.expects(:new).with { |**kwargs| received = kwargs.fetch(:needs) }.returns(stub(resolve: []))
    command = Dev::Builtins::UpdateDepsCommand.new
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update"
    command.call(args: no_args, context: build_context(root))

    Then "xcode's and wwise's needs are in the table, as brew declarations"
    received.fetch(:xcode).map(&:name) == ["xcodes"]
    received.fetch(:wwise).map(&:name) == ["wwise-cli"]
    received.values.flatten.map(&:integration).uniq == [:brew]

    Cleanup
    $stdout = old_stdout
    FileUtils.rm_rf(root)
  end

  test "call does not mistake a previously loaded project's config for this one" do
    Given "a stale config from an earlier load, and a dependencies.rb that never calls Dev::Deps.define"
    Dev::Deps.define { ruby "9.9.9" }
    root = Pathname.new(Dir.mktmpdir("update-deps-stale-"))
    File.write(root / "dependencies.rb", "UPDATE_DEPS_TEST_CONSTANT = 1 unless defined?(UPDATE_DEPS_TEST_CONSTANT)\n")
    command = Dev::Builtins::UpdateDepsCommand.new
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update"
    command.call(args: no_args, context: build_context(root))

    Then "the run resolved an empty config (a leaked ruby pin would try to resolve it)"
    Dev::Deps.last_config.declarations.empty?

    Cleanup
    $stdout = old_stdout
    FileUtils.rm_rf(root)
  end

  private

  def build_context(project_root)
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui),
      project: Dev::ProjectContext.new(name: "TestProject", root: project_root),
    )
  end
end
