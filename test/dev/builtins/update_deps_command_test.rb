# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/environment_image"
require "dev/builtins/update_deps_command"
require "digest"
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

  test "call stamps every image pin with its content digest before writing the lock" do
    Given "a resolver answering one image pin without a digest"
    root = Pathname.new(Dir.mktmpdir("update-deps-image-"))
    image_pin = Dev::Deps::Dependency.new(
      name: "snappy-linux", integration: :image, group: :app, version: "ue5.8-3", hash: "SHA256=#{"a" * 64}",
      metadata: { "from" => "ghcr.io/d3mlabs/floor", "platform" => "linux/amd64", "platforms" => ["linux/amd64"],
                  "registry" => "ghcr.io/d3mlabs", "apt" => ["dos2unix"] },
    )
    Dev::Deps::Resolver.expects(:new).returns(stub(resolve: [image_pin]))
    command = Dev::Builtins::UpdateDepsCommand.new
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update"
    command.call(args: no_args, context: build_context(root))

    Then "the lock's image entry carries the digest this dev computes"
    locked = Dev::Deps::Lockfile.new(dir: root).read.find { |dep| dep.integration == :image }
    locked.metadata["digest"] == Dev::EnvironmentImage.from_pin(image_pin).digest

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

  test "call keeps the brew section byte-identical when no brew declaration changed, however far brew's index moved" do
    Given "cellbound-3d#319: a lock from an older Mac, and a newer Mac whose brew resolves every formula to a newer version"
    root = Pathname.new(Dir.mktmpdir("update-deps-carryover-"))
    File.write(root / "dependencies.rb", <<~RUBY)
      require "dev/deps"
      Dev::Deps.define do
        brew "cmake", group: :build
        brew "python@3.12", group: :build
      end
    RUBY
    locked = [brew_pin("cmake", "4.4.4", commit: "0f1ba9ea"), brew_pin("python@3.12", "3.12.11", commit: "0f1ba9ea")]
    Dev::Deps::Lockfile.new(dir: root).lock(locked, manifest_digest: Digest::SHA256.file((root / "dependencies.rb").to_s).hexdigest)
    before = (root / "deps.lock").read
    today = [brew_pin("cmake", "4.4.5", commit: "7d2877eb"), brew_pin("python@3.12", "3.12.12", commit: "7d2877eb")]
    Dev::Deps::Resolver.expects(:new).returns(stub(resolve: today))
    command = Dev::Builtins::UpdateDepsCommand.new
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update"
    command.call(args: no_args, context: build_context(root))

    Then "deps.lock is byte-identical to what was there, and the output says what was kept"
    (root / "deps.lock").read == before
    $stdout.string.include?("dev: kept 2 pins from deps.lock: cmake, python@3.12")
    !$stdout.string.include?("dev: moved")

    Cleanup
    $stdout = old_stdout
    FileUtils.rm_rf(root)
  end

  test "call floats only the named declaration and reports the move with its reason" do
    Given "a lock with two formulae, both newer in brew today, and one of them named"
    root = Pathname.new(Dir.mktmpdir("update-deps-named-"))
    File.write(root / "dependencies.rb", <<~RUBY)
      require "dev/deps"
      Dev::Deps.define do
        brew "cmake", group: :build
        brew "jq", group: :build
      end
    RUBY
    Dev::Deps::Lockfile.new(dir: root).lock([brew_pin("cmake", "4.4.4", commit: "0f1ba9ea"), brew_pin("jq", "1.7", commit: "0f1ba9ea")])
    today = [brew_pin("cmake", "4.4.5", commit: "7d2877eb"), brew_pin("jq", "1.8", commit: "7d2877eb")]
    Dev::Deps::Resolver.expects(:new).returns(stub(resolve: today))
    command = Dev::Builtins::UpdateDepsCommand.new
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update jq"
    command.call(args: parsed_args(command, ["jq"]), context: build_context(root))

    Then "jq moved to today's pin with today's commit; cmake is the lock's, tap_commit included"
    pins = Dev::Deps::Lockfile.new(dir: root).read.to_h { |dep| [dep.name, [dep.version, dep.metadata["tap_commit"]]] }
    pins == { "cmake" => ["4.4.4", "0f1ba9ea"], "jq" => ["1.8", "7d2877eb"] }
    $stdout.string.include?("dev: moved jq 1.7 → 1.8 (named)")
    $stdout.string.include?("dev: kept 1 pin from deps.lock: cmake")

    Cleanup
    $stdout = old_stdout
    FileUtils.rm_rf(root)
  end

  test "call floats a named gem through bundler and carries the other gems verbatim from the lock" do
    Given "a manifest with two gems and a formula, a lock for all three, and a locker wired for :bundler"
    root = Pathname.new(Dir.mktmpdir("update-deps-named-gem-"))
    File.write(root / "dependencies.rb", <<~RUBY)
      require "dev/deps"
      Dev::Deps.define do
        brew "cmake", group: :build
        gem "rake"
        gem "ffi"
      end
    RUBY
    gem_pin = ->(name, version) do
      Dev::Deps::Dependency.new(name:, integration: :bundler, group: :app, version:, hash: nil, metadata: {})
    end
    Dev::Deps::Lockfile.new(dir: root).lock([brew_pin("cmake", "4.4.4"), gem_pin.call("rake", "13.2.1"), gem_pin.call("ffi", "1.16.3")])
    locker = mock
    locker.expects(:lock).with do |declarations, unlock:|
      declarations.map(&:name) == ["rake", "ffi"] && unlock == Dev::Deps::UnlockSet.new(names: ["rake"])
    end
    Dev::Deps::Registry.expects(:lockers).returns({ bundler: locker })
    today = [brew_pin("cmake", "4.4.5"), gem_pin.call("rake", "13.3.0"), gem_pin.call("ffi", "1.17.0")]
    Dev::Deps::Resolver.expects(:new).returns(stub(resolve: today))
    command = Dev::Builtins::UpdateDepsCommand.new
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update rake"
    command.call(args: parsed_args(command, ["rake"]), context: build_context(root))

    Then "the locker was told to float rake (asserted on the mock); rake is today's, the others are the lock's"
    pins = Dev::Deps::Lockfile.new(dir: root).read.to_h { |dep| [dep.name, dep.version] }
    pins == { "cmake" => "4.4.4", "rake" => "13.3.0", "ffi" => "1.16.3" }

    Cleanup
    $stdout = old_stdout
    FileUtils.rm_rf(root)
  end

  test "call --all takes brew's current versions and says which pins moved" do
    Given "a lock behind brew's index"
    root = Pathname.new(Dir.mktmpdir("update-deps-all-"))
    File.write(root / "dependencies.rb", <<~RUBY)
      require "dev/deps"
      Dev::Deps.define { brew "cmake", group: :build }
    RUBY
    Dev::Deps::Lockfile.new(dir: root).lock([brew_pin("cmake", "4.4.4", commit: "0f1ba9ea")])
    Dev::Deps::Resolver.expects(:new).returns(stub(resolve: [brew_pin("cmake", "4.4.5", commit: "7d2877eb")]))
    command = Dev::Builtins::UpdateDepsCommand.new
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update --all"
    command.call(args: parsed_args(command, ["--all"]), context: build_context(root))

    Then "the lock is today's resolution and the move is reported"
    Dev::Deps::Lockfile.new(dir: root).read.map { |dep| [dep.version, dep.metadata["tap_commit"]] } == [["4.4.5", "7d2877eb"]]
    $stdout.string.include?("dev: moved cmake 4.4.4 → 4.4.5 (--all)")
    !$stdout.string.include?("dev: kept")

    Cleanup
    $stdout = old_stdout
    FileUtils.rm_rf(root)
  end

  test "call refuses a name the manifest does not declare, listing the names it does" do
    Given "a manifest declaring cmake and rake"
    root = Pathname.new(Dir.mktmpdir("update-deps-unknown-"))
    File.write(root / "dependencies.rb", <<~RUBY)
      require "dev/deps"
      Dev::Deps.define do
        brew "cmake", group: :build
        gem "rake"
      end
    RUBY
    Dev::Deps::Resolver.expects(:new).never
    command = Dev::Builtins::UpdateDepsCommand.new

    When "running dev deps update jq"
    error = assert_raises(Dev::Builtins::UpdateDepsCommand::UnknownDeclarationError) do
      command.call(args: parsed_args(command, ["jq"]), context: build_context(root))
    end

    Then "the error names the unknown name and the manifest's, and no lock was written"
    error.message.include?("declares no jq")
    error.message.include?("cmake, rake")
    !(root / "deps.lock").exist?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "call refuses --all together with names" do
    Given "a manifest declaring cmake"
    root = Pathname.new(Dir.mktmpdir("update-deps-all-names-"))
    File.write(root / "dependencies.rb", <<~RUBY)
      require "dev/deps"
      Dev::Deps.define { brew "cmake", group: :build }
    RUBY
    Dev::Deps::Resolver.expects(:new).never
    command = Dev::Builtins::UpdateDepsCommand.new

    When "running dev deps update cmake --all"
    error = assert_raises(Dev::Builtins::UpdateDepsCommand::AllWithNamesError) do
      command.call(args: parsed_args(command, ["cmake", "--all"]), context: build_context(root))
    end

    Then "the refusal says the two shapes exclude each other"
    error.message.include?("not both")

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "call installs the kept Ruby, not today's, so bundle lock runs under the version the lock keeps" do
    Given "a lock pinning ruby 4.0.6 within a ~> 4.0 range, and a brew that resolves the range to 4.0.9 today"
    root = Pathname.new(Dir.mktmpdir("update-deps-kept-ruby-"))
    File.write(root / "dependencies.rb", <<~RUBY)
      require "dev/deps"
      Dev::Deps.define do
        ruby "~> 4.0"
        gem "rake"
      end
    RUBY
    ruby_pin = ->(version, commit) do
      Dev::Deps::Dependency.new(name: "ruby", integration: :ruby, group: :app, version:, hash: nil,
        metadata: { "tap" => "d3mlabs/d3mlabs", "tap_commit" => commit, "version_suffix" => version, "format" => "bottle",
                    "platforms" => { "arm64_sequoia" => { "hash" => "SHA256=m", "link" => "https://x/m" } } })
    end
    Dev::Deps::Lockfile.new(dir: root).lock([ruby_pin.call("4.0.6", "0f1ba9ea")])
    Dev::Deps::Resolver.expects(:new).returns(stub(resolve: [ruby_pin.call("4.0.9", "7d2877eb")]))
    brew = mock
    brew.expects(:install_all).with { |*args| args.fetch(0).map(&:version) == ["4.0.6"] }
    Dev::Deps::Registry.expects(:host_integrations).returns({ brew: brew, ruby: brew })
    locker = mock
    locker.expects(:lock)
    Dev::Deps::Registry.expects(:lockers).with(project_root: root, ruby_version: "4.0.6").returns({ bundler: locker })
    command = Dev::Builtins::UpdateDepsCommand.new
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update"
    command.call(args: no_args, context: build_context(root))

    Then "the lock still pins 4.0.6 (install and locker asserted on the mocks)"
    Dev::Deps::Lockfile.new(dir: root).read.map(&:version) == ["4.0.6"]

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

  # A bottled core-tap formula pin as BrewRepository resolves it.
  def brew_pin(name, version, commit: "0f1ba9ea", group: :build)
    Dev::Deps::Dependency.new(name:, integration: :brew, group:, version:, hash: nil,
      metadata: { "tap_commit" => commit, "format" => "bottle",
                  "platforms" => { "x86_64_linux" => { "hash" => "SHA256=l", "link" => "https://x/l" } } })
  end

  def build_context(project_root)
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui),
      project: Dev::ProjectContext.new(name: "TestProject", root: project_root),
    )
  end
end
