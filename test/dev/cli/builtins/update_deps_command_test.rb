# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/environment_image"
require "dev/cli/builtins/update_deps_command"
require "dev/deps/gh_repository"
require "dev/deps/oci_repository"
require "dev/deps/package"
require "dev/deps/package_id"
require "dev/deps/package_version"
require "dev/deps/repository"
require "dev/http_client"
require "support/recording_ui"
require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "stringio"
require "tmpdir"

# The command is given the registry (what dev's integrations contribute for
# a project) and a factory for the resolver over that universe; a test
# scripts the universe through the registry double and the resolution
# through the resolver double, and reads the lock the command writes.
transform!(RSpock::AST::Transformation)
class Dev::Cli::Builtins::UpdateDepsCommandTest < Minitest::Test
  include SorbetHelper

  test "traits: staleness-exempt (it IS the remediation), never stamps" do
    Given "the builtin"
    command = Dev::Cli::Builtins::UpdateDepsCommand.new

    Expect "the declarative traits"
    command.staleness_exempt? == true
    command.stamps? == false
    !command.hidden?
    command.desc.include?("lockfiles")
  end

  test "call resolves an empty manifest and reports the update" do
    Given "a project root with no dependencies.rb"
    root = Pathname.new(Dir.mktmpdir("update-deps-empty-"))
    command = Dev::Cli::Builtins::UpdateDepsCommand.new
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
    resolver = mock
    command = Dev::Cli::Builtins::UpdateDepsCommand.new(resolver_factory: ->(*_universe) { resolver })
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update"
    command.call(args: no_args, context: build_context(root))

    Then "the lock's image entry carries the digest this dev computes"
    _ * resolver.resolve(anything) >> [image_pin]
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
    registry = catalog
    resolver = mock
    command = Dev::Cli::Builtins::UpdateDepsCommand.new(registry:, resolver_factory: ->(*_universe) { resolver })
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update"
    command.call(args: no_args, context: build_context(root))

    Then "the locker received the bundler declarations"
    _ * registry.repositories(project_root: root) >> {}
    1 * registry.lockers(project_root: root, ruby_version: nil) >> { bundler: locker }
    1 * locker.lock(declarations_of { gem "rake" }, unlock: Dev::Deps::UnlockSet.all)
    _ * resolver.resolve(anything) >> []
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
        ruby "~4.0"
        gem "rake"
      end
    RUBY
    manifest = declarations_of do
      ruby "~4.0"
      gem "rake"
    end
    ruby_pin = Dev::Deps::Dependency.new(name: "ruby", integration: :ruby, group: :app, version: "4.0.9", hash: nil,
      metadata: { "tap" => "d3mlabs/d3mlabs", "version_suffix" => "4.0.9" })
    resolver = mock
    brew_repo = typed_mock(Dev::Deps::BrewRepository)
    brew = mock
    locker = mock
    ui = RecordingUi.new
    registry = catalog
    command = Dev::Cli::Builtins::UpdateDepsCommand.new(registry:, resolver_factory: ->(*_universe) { resolver })
    old_stdout = $stdout
    $stdout = StringIO.new
    # call order: the locker runs bundle lock under the Ruby the install just activated, so install-then-lock is the contract
    order = sequence("install the interpreter, then lock")
    brew.expects(:install_all).with([ruby_pin]).in_sequence(order)
    locker.expects(:lock).in_sequence(order)

    When "running dev deps update"
    command.call(args: no_args, context: build_context(root, ui: ui))

    Then "bundle lock ran under the locked Ruby, whose exact version is the Gemfile's ruby directive; the install spoke in its own frame"
    _ * registry.repositories(project_root: root) >> { ruby: brew_repo }
    1 * brew_repo.refresh_index!
    1 * resolver.resolve(manifest.select { |decl| decl.integration == :ruby }) >> [ruby_pin]
    1 * resolver.resolve(manifest) >> [ruby_pin]
    1 * registry.host_integrations(project_root: root, project_name: "TestProject", store: instance_of(Dev::Deps::LocalStore), ui: ui) >>
      { brew: brew, ruby: brew }
    1 * registry.lockers(project_root: root, ruby_version: "4.0.9") >> { bundler: locker }
    $stdout.string.include?("lockfiles updated")
    Dev::Deps::Lockfile.new(dir: root).read.map { |dep| [dep.integration, dep.name, dep.version] } == [[:ruby, "ruby", "4.0.9"]]
    ui.rows == [[:frame, "ruby: 1 pin", 0]]

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
    locker = mock
    registry = catalog
    resolver = mock
    command = Dev::Cli::Builtins::UpdateDepsCommand.new(registry:, resolver_factory: ->(*_universe) { resolver })
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update"
    command.call(args: no_args, context: build_context(root))

    Then "no Ruby is provisioned for a project that declares none"
    _ * registry.repositories(project_root: root) >> {}
    0 * registry.host_integrations(anything)
    1 * registry.lockers(project_root: root, ruby_version: nil) >> { bundler: locker }
    1 * locker.lock(anything, unlock: anything)
    _ * resolver.resolve(anything) >> []
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
    resolver = mock
    command = Dev::Cli::Builtins::UpdateDepsCommand.new(resolver_factory: ->(*_universe) { resolver })
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update"
    command.call(args: no_args, context: build_context(root))

    Then "only the source formula the image build installs is named — format matters there, and the Mac-only one never reaches the image"
    _ * resolver.resolve(anything) >> resolved
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
    resolver = mock
    command = Dev::Cli::Builtins::UpdateDepsCommand.new(resolver_factory: ->(*_universe) { resolver })
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update — the command the refusal points at"
    command.call(args: no_args, context: build_context(root))

    Then "one lockfile holds both pins and the retired file is gone"
    _ * resolver.resolve(anything) >> resolved
    !(root / "build-deps.lock").exist?
    Dev::Deps::Lockfile.new(dir: root).read.map(&:name).sort == ["boost", "cmake"]

    Cleanup
    $stdout = old_stdout
    FileUtils.rm_rf(root)
  end

  test "call moves every pin to the newest its declaration admits, across channels, after refreshing brew's index" do
    Given "a lock behind brew's index and behind the pip index, for a formula and an open-range pip package"
    root = Pathname.new(Dir.mktmpdir("update-deps-bare-"))
    File.write(root / "dependencies.rb", <<~RUBY)
      require "dev/deps"
      Dev::Deps.define do
        brew "cmake"
        pip "kimimaro", ">=5"
      end
    RUBY
    Dev::Deps::Lockfile.new(dir: root).lock([brew_pin("cmake", "4.4.4", commit: "0f1ba9ea"), pip_pin("kimimaro", "5.8.5")])
    today = [brew_pin("cmake", "4.4.5", commit: "7d2877eb"), pip_pin("kimimaro", "5.9.0")]
    resolver = mock
    brew_repo = typed_mock(Dev::Deps::BrewRepository)
    registry = catalog
    command = Dev::Cli::Builtins::UpdateDepsCommand.new(registry:, resolver_factory: ->(*_universe) { resolver })
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update"
    command.call(args: no_args, context: build_context(root))

    Then "brew update ran once; the lock is today's, every move named, nothing kept"
    _ * registry.repositories(project_root: root) >> { brew: brew_repo }
    1 * brew_repo.refresh_index!
    _ * registry.lockers(project_root: root, ruby_version: nil) >> {}
    _ * resolver.resolve(anything) >> today
    pins = Dev::Deps::Lockfile.new(dir: root).read.to_h { |dep| [dep.name, [dep.version, dep.source]] }
    pins == { "cmake" => ["4.4.5", "homebrew/core@7d2877eb"], "kimimaro" => ["5.9.0", "kimimaro==5.9.0"] }
    $stdout.string.include?("dev: moved cmake 4.4.4 → 4.4.5\n")
    $stdout.string.include?("dev: moved kimimaro 5.8.5 → 5.9.0\n")
    !$stdout.string.include?("dev: kept")

    Cleanup
    $stdout = old_stdout
    FileUtils.rm_rf(root)
  end

  test "call refreshes brew's index only for a bare update of a manifest brew answers for: #{description}" do
    Given "a manifest #{description}"
    root = Pathname.new(Dir.mktmpdir("update-deps-refresh-"))
    File.write(root / "dependencies.rb", <<~RUBY)
      require "dev/deps"
      Dev::Deps.define { #{declaration} }
    RUBY
    resolver = mock
    brew_repo = typed_mock(Dev::Deps::BrewRepository)
    registry = catalog
    command = Dev::Cli::Builtins::UpdateDepsCommand.new(registry:, resolver_factory: ->(*_universe) { resolver })
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update #{words.join(" ")}"
    command.call(args: parsed_args(command, words), context: build_context(root))

    Then "brew update ran as often as the row says"
    _ * registry.repositories(project_root: root) >> { brew: brew_repo, python: brew_repo }
    refreshes * brew_repo.refresh_index!
    _ * registry.lockers(project_root: root, ruby_version: nil) >> {}
    _ * resolver.resolve(anything) >> []
    $stdout.string.include?("lockfiles updated")

    Cleanup
    $stdout = old_stdout
    FileUtils.rm_rf(root)

    Where
    description                          | declaration        | words      | refreshes
    "with a formula, updated bare"       | 'brew "cmake"'     | []         | 1
    "with an interpreter, updated bare"  | 'python "3.12"'    | []         | 1
    "with a formula, one name updated"   | 'brew "cmake"'     | ["cmake"]  | 0
    "with only a gem, updated bare"      | 'gem "rake"'       | []         | 0
  end

  test "call warns and resolves against the index brew has when brew update fails" do
    Given "a formula declared, and a brew update that cannot run"
    root = Pathname.new(Dir.mktmpdir("update-deps-refresh-failed-"))
    File.write(root / "dependencies.rb", <<~RUBY)
      require "dev/deps"
      Dev::Deps.define { brew "cmake" }
    RUBY
    resolver = mock
    brew_repo = typed_mock(Dev::Deps::BrewRepository)
    registry = catalog
    command = Dev::Cli::Builtins::UpdateDepsCommand.new(registry:, resolver_factory: ->(*_universe) { resolver })
    old_stdout = $stdout
    old_stderr = $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new

    When "running dev deps update"
    command.call(args: no_args, context: build_context(root))

    Then "the lock is written from the index at hand, and stderr says the refresh did not happen"
    _ * registry.repositories(project_root: root) >> { brew: brew_repo }
    1 * brew_repo.refresh_index! >> raises(Dev::Deps::BrewRepository::IndexRefreshError.new(stderr: "fatal: unable to access github.com"))
    _ * registry.lockers(project_root: root, ruby_version: nil) >> {}
    _ * resolver.resolve(anything) >> [brew_pin("cmake", "4.4.5", commit: "7d2877eb")]
    Dev::Deps::Lockfile.new(dir: root).read.map(&:version) == ["4.4.5"]
    $stderr.string.include?("dev: warning: brew update failed (fatal: unable to access github.com) — resolving against the index brew has")
    $stdout.string.include?("lockfiles updated")

    Cleanup
    $stdout = old_stdout
    $stderr = old_stderr
    FileUtils.rm_rf(root)
  end

  test "call <name> moves the named declaration and keeps every other pin the lock can keep, across channels" do
    Given "a lock with two formulae and a pip package, all newer today, and one formula named"
    root = Pathname.new(Dir.mktmpdir("update-deps-named-"))
    File.write(root / "dependencies.rb", <<~RUBY)
      require "dev/deps"
      Dev::Deps.define do
        brew "cmake"
        brew "jq"
        pip "kimimaro", ">=5"
      end
    RUBY
    Dev::Deps::Lockfile.new(dir: root).lock([brew_pin("cmake", "4.4.4", commit: "0f1ba9ea"), brew_pin("jq", "1.7", commit: "0f1ba9ea"), pip_pin("kimimaro", "5.8.5")])
    today = [brew_pin("cmake", "4.4.5", commit: "7d2877eb"), brew_pin("jq", "1.8", commit: "7d2877eb"), pip_pin("kimimaro", "5.9.0")]
    resolver = mock
    command = Dev::Cli::Builtins::UpdateDepsCommand.new(resolver_factory: ->(*_universe) { resolver })
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update jq"
    command.call(args: parsed_args(command, ["jq"]), context: build_context(root))

    Then "jq moved to today's pin with today's commit; cmake and kimimaro are the lock's, tap_commit included"
    _ * resolver.resolve(anything) >> today
    pins = Dev::Deps::Lockfile.new(dir: root).read.to_h { |dep| [dep.name, [dep.version, dep.metadata["tap_commit"]]] }
    pins == { "cmake" => ["4.4.4", "0f1ba9ea"], "jq" => ["1.8", "7d2877eb"], "kimimaro" => ["5.8.5", nil] }
    $stdout.string.include?("dev: moved jq 1.7 → 1.8 (named)")
    !$stdout.string.include?("cmake")
    !$stdout.string.include?("kimimaro")
    $stdout.string.include?("dev: lockfiles updated — now run dev up to install.")

    Cleanup
    $stdout = old_stdout
    FileUtils.rm_rf(root)
  end

  test "call <name> re-resolves an unchanged pin the lock records no source for, saying why, and the lock gains one" do
    Given "a lock written before pins carried a source: a pip pin without one, beside the formula named"
    root = Pathname.new(Dir.mktmpdir("update-deps-sourceless-"))
    File.write(root / "dependencies.rb", <<~RUBY)
      require "dev/deps"
      Dev::Deps.define do
        brew "cmake"
        pip "kimimaro", ">=5"
      end
    RUBY
    unsourced = Dev::Deps::Dependency.new(name: "kimimaro", integration: :pip, group: :app, version: "5.8.5", hash: nil, metadata: {})
    Dev::Deps::Lockfile.new(dir: root).lock([brew_pin("cmake", "4.4.4", commit: "0f1ba9ea"), unsourced])
    resolver = mock
    command = Dev::Cli::Builtins::UpdateDepsCommand.new(resolver_factory: ->(*_universe) { resolver })
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update cmake"
    command.call(args: parsed_args(command, ["cmake"]), context: build_context(root))

    Then "kimimaro is today's with a source from now on, and the move names the cause"
    _ * resolver.resolve(anything) >> [brew_pin("cmake", "4.4.5", commit: "7d2877eb"), pip_pin("kimimaro", "5.9.0")]
    pins = Dev::Deps::Lockfile.new(dir: root).read.to_h { |dep| [dep.name, [dep.version, dep.source]] }
    pins == { "cmake" => ["4.4.5", "homebrew/core@7d2877eb"], "kimimaro" => ["5.9.0", "kimimaro==5.9.0"] }
    $stdout.string.include?("dev: moved cmake 4.4.4 → 4.4.5 (named)")
    $stdout.string.include?("dev: moved kimimaro 5.8.5 → 5.9.0 (the lock records no source for 5.8.5, so it cannot be kept)")
    !$stdout.string.include?("dev: kept")

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
        brew "cmake"
        gem "rake"
        gem "ffi"
      end
    RUBY
    gems = declarations_of do
      brew "cmake"
      gem "rake"
      gem "ffi"
    end.select { |decl| decl.integration == :bundler }
    gem_pin = ->(name, version) do
      Dev::Deps::Dependency.new(name:, integration: :bundler, group: :app, version:, hash: nil, source: version, metadata: {})
    end
    Dev::Deps::Lockfile.new(dir: root).lock([brew_pin("cmake", "4.4.4"), gem_pin.call("rake", "13.2.1"), gem_pin.call("ffi", "1.16.3")])
    locker = mock
    today = [brew_pin("cmake", "4.4.5"), gem_pin.call("rake", "13.3.0"), gem_pin.call("ffi", "1.17.0")]
    resolver = mock
    registry = catalog
    command = Dev::Cli::Builtins::UpdateDepsCommand.new(registry:, resolver_factory: ->(*_universe) { resolver })
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update rake"
    command.call(args: parsed_args(command, ["rake"]), context: build_context(root))

    Then "the locker was told to float rake; rake is today's, the others are the lock's"
    _ * registry.repositories(project_root: root) >> {}
    1 * registry.lockers(project_root: root, ruby_version: nil) >> { bundler: locker }
    1 * locker.lock(gems, unlock: Dev::Deps::UnlockSet.new(names: ["rake"]))
    _ * resolver.resolve(anything) >> today
    pins = Dev::Deps::Lockfile.new(dir: root).read.to_h { |dep| [dep.name, dep.version] }
    pins == { "cmake" => "4.4.4", "rake" => "13.3.0", "ffi" => "1.16.3" }

    Cleanup
    $stdout = old_stdout
    FileUtils.rm_rf(root)
  end

  test "call leaves a brew pin's lock line alone when a bare update finds it unmoved (ADR-0005)" do
    Given "a lock whose formula brew still serves at the same version, from a newer index"
    root = Pathname.new(Dir.mktmpdir("update-deps-unmoved-"))
    File.write(root / "dependencies.rb", <<~RUBY)
      require "dev/deps"
      Dev::Deps.define { brew "cmake" }
    RUBY
    Dev::Deps::Lockfile.new(dir: root).lock([brew_pin("cmake", "4.4.4", commit: "0f1ba9ea")], manifest_digest: Digest::SHA256.file((root / "dependencies.rb").to_s).hexdigest)
    before = (root / "deps.lock").read
    resolver = mock
    brew_repo = typed_mock(Dev::Deps::BrewRepository)
    registry = catalog
    command = Dev::Cli::Builtins::UpdateDepsCommand.new(registry:, resolver_factory: ->(*_universe) { resolver })
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update"
    command.call(args: no_args, context: build_context(root))

    Then "deps.lock is byte-identical: the lock's commit stands for a pin that did not move"
    _ * registry.repositories(project_root: root) >> { brew: brew_repo }
    1 * brew_repo.refresh_index!
    _ * registry.lockers(project_root: root, ruby_version: nil) >> {}
    _ * resolver.resolve(anything) >> [brew_pin("cmake", "4.4.4", commit: "7d2877eb")]
    (root / "deps.lock").read == before
    !$stdout.string.include?("dev: moved")

    Cleanup
    $stdout = old_stdout
    FileUtils.rm_rf(root)
  end

  test "call resolves a series-shaped gh requirement through the series head and says which rule chose each pin" do
    Given "a gh repo with tags 1.3.0 and 1.4.0 and v1 → 1.3.0 (the rollback), a lock on 1.4.0, and a lower-bounded sibling declaration"
    root = Pathname.new(Dir.mktmpdir("update-deps-series-head-"))
    File.write(root / "dependencies.rb", <<~RUBY)
      require "dev/deps"
      Dev::Deps.define do
        gh "ai-flow", "^1", github: "d3mlabs/ai-flow", assets: "*.zip"
        gh "ai-flow-newest", ">= 1.4", github: "d3mlabs/ai-flow", assets: "*.zip"
      end
    RUBY
    Dev::Deps::Lockfile.new(dir: root).lock([gh_pin("ai-flow", "1.4.0", "b" * 40)])
    registry = catalog
    command = Dev::Cli::Builtins::UpdateDepsCommand.new(registry:)
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update"
    command.call(args: no_args, context: build_context(root))

    Then "^1 follows v1 back to 1.3.0 at its commit; >= 1.4 is the greatest tag; the report says which rule chose each"
    _ * registry.repositories(project_root: root) >> { gh: Dev::Deps::GhRepository.new }
    _ * Open3.capture3("gh", "api", "repos/d3mlabs/ai-flow/releases?per_page=100&page=1") >> [AI_FLOW_RELEASES, "", exit_status(0)]
    _ * Open3.capture3("gh", "api", "repos/d3mlabs/ai-flow/tags?per_page=100&page=1") >> [AI_FLOW_TAGS, "", exit_status(0)]
    _ * registry.lockers(project_root: root, ruby_version: nil) >> {}
    pins = Dev::Deps::Lockfile.new(dir: root).read.to_h { |dep| [dep.name, [dep.version, dep.source]] }
    pins == { "ai-flow" => ["1.3.0", "a" * 40], "ai-flow-newest" => ["1.4.0", "b" * 40] }
    $stdout.string.include?("dev: moved ai-flow 1.4.0 → 1.3.0 (series head v1 → 1.3.0)\n")
    $stdout.string.include?("dev: added ai-flow-newest 1.4.0 (greatest satisfying)\n")

    Cleanup
    $stdout = old_stdout
    FileUtils.rm_rf(root)
  end

  test "call <name> whose pin is already what its rule chooses says so, and says the lock is current" do
    Given "a lock on 1.3.0, which is where v1 points"
    root = Pathname.new(Dir.mktmpdir("update-deps-unchanged-"))
    File.write(root / "dependencies.rb", <<~RUBY)
      require "dev/deps"
      Dev::Deps.define do
        gh "ai-flow", "^1", github: "d3mlabs/ai-flow", assets: "*.zip"
      end
    RUBY
    locked = Dev::Deps::Dependency.new(name: "ai-flow", integration: :gh, group: :app, version: "1.3.0", hash: nil, source: "a" * 40,
      metadata: { "repo" => "d3mlabs/ai-flow", "commit" => "a" * 40,
                  "assets" => [{ "name" => "ai-flow-1.3.0.zip", "size" => 1, "sha256" => "a3" }], "asset_pattern" => "*.zip" })
    Dev::Deps::Lockfile.new(dir: root).lock([locked], manifest_digest: Digest::SHA256.file((root / "dependencies.rb").to_s).hexdigest)
    before = (root / "deps.lock").read
    registry = catalog
    command = Dev::Cli::Builtins::UpdateDepsCommand.new(registry:)
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update ai-flow"
    command.call(args: parsed_args(command, ["ai-flow"]), context: build_context(root))

    Then "the named pin is reported unchanged with the rule that confirmed it; the lock is byte-identical and said to be current"
    _ * registry.repositories(project_root: root) >> { gh: Dev::Deps::GhRepository.new }
    _ * Open3.capture3("gh", "api", "repos/d3mlabs/ai-flow/releases?per_page=100&page=1") >> [AI_FLOW_RELEASES, "", exit_status(0)]
    _ * Open3.capture3("gh", "api", "repos/d3mlabs/ai-flow/tags?per_page=100&page=1") >> [AI_FLOW_TAGS, "", exit_status(0)]
    _ * registry.lockers(project_root: root, ruby_version: nil) >> {}
    (root / "deps.lock").read == before
    $stdout.string.include?("dev: ai-flow 1.3.0 unchanged (series head v1 → 1.3.0)\n")
    $stdout.string.include?("dev: deps.lock is current.\n")
    !$stdout.string.include?("lockfiles updated")
    !$stdout.string.include?("dev: kept")

    Cleanup
    $stdout = old_stdout
    FileUtils.rm_rf(root)
  end

  test "call <name> finishes on a host that can reach only the named declaration's registry, keeping the floor it would carry anyway" do
    Given "dev#373: a lock with an image floor and a pip pin, a token GHCR refuses, and a pip index that answers"
    root = Pathname.new(Dir.mktmpdir("update-deps-floor-denied-"))
    write_floor_manifest(root)
    Dev::Deps::Lockfile.new(dir: root).lock(Dev::EnvironmentImage.stamp([floor_pin, pip_pin("clang-format", "17.0.6")]))
    floor_before = (root / "deps.lock").read[/image:.*?(?=\npip:)/m]
    ghcr = typed_mock(Dev::HttpClient)
    pip_index = typed_mock(Dev::Deps::Repository)
    registry = catalog
    command = Dev::Cli::Builtins::UpdateDepsCommand.new(registry:)
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update clang-format"
    command.call(args: parsed_args(command, ["clang-format"]), context: build_context(root))

    Then "the floor's lock section is byte-identical, clang-format moved, and the output says what the registry refused"
    _ * registry.repositories(project_root: root) >> { image: denied_oci_repository(ghcr), pip: pip_index }
    _ * ghcr.get(anything, headers: anything) >> Dev::HttpClient::Response.new(code: 403, headers: {}, body: "denied")
    _ * pip_index.find(responds_with(:name, "clang-format")) >> clang_format_package("18.1.8")
    _ * registry.lockers(project_root: root, ruby_version: nil) >> {}
    (root / "deps.lock").read[/image:.*?(?=\npip:)/m] == floor_before
    Dev::Deps::Lockfile.new(dir: root).read.to_h { |dep| [dep.name, dep.version] } == { "cellbound-3d-linux" => "ue5.8-3", "clang-format" => "18.1.8" }
    $stdout.string.include?("dev: kept (registry unreachable): cellbound-3d-linux ue5.8-3 — the registry refused gh's token")
    $stdout.string.include?("lockfiles updated")

    Cleanup
    $stdout = old_stdout
    FileUtils.rm_rf(root)
  end

  test "call bare still needs every registry: the floor's refusal propagates" do
    Given "the same lock and the same refused token"
    root = Pathname.new(Dir.mktmpdir("update-deps-floor-denied-all-"))
    write_floor_manifest(root)
    Dev::Deps::Lockfile.new(dir: root).lock(Dev::EnvironmentImage.stamp([floor_pin, pip_pin("clang-format", "17.0.6")]))
    before = (root / "deps.lock").read
    ghcr = typed_mock(Dev::HttpClient)
    pip_index = typed_mock(Dev::Deps::Repository)
    registry = catalog
    command = Dev::Cli::Builtins::UpdateDepsCommand.new(registry:)

    When "running dev deps update"
    command.call(args: no_args, context: build_context(root))

    Then "the registry's own error, naming the scope to add; the lock is untouched"
    _ * registry.repositories(project_root: root) >> { image: denied_oci_repository(ghcr), pip: pip_index }
    _ * ghcr.get(anything, headers: anything) >> Dev::HttpClient::Response.new(code: 403, headers: {}, body: "denied")
    _ * pip_index.find(responds_with(:name, "clang-format")) >> clang_format_package("18.1.8")
    _ * registry.lockers(project_root: root, ruby_version: nil) >> {}
    error = raises Dev::Deps::OciRepository::AccessDeniedError
    error.message.include?("read:packages")
    (root / "deps.lock").read == before

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "call refuses a name the manifest does not declare, listing the names it does" do
    Given "a manifest declaring cmake and rake"
    root = Pathname.new(Dir.mktmpdir("update-deps-unknown-"))
    File.write(root / "dependencies.rb", <<~RUBY)
      require "dev/deps"
      Dev::Deps.define do
        brew "cmake"
        gem "rake"
      end
    RUBY
    resolver_factory = typed_mock(Proc)
    command = Dev::Cli::Builtins::UpdateDepsCommand.new(resolver_factory:)

    When "running dev deps update jq"
    command.call(args: parsed_args(command, ["jq"]), context: build_context(root))

    Then "the error names the unknown name and the manifest's; no resolver was built and no lock was written"
    0 * resolver_factory.call(anything, anything, anything)
    error = raises Dev::Cli::Builtins::UpdateDepsCommand::UnknownDeclarationError
    error.message.include?("declares no jq")
    error.message.include?("cmake, rake")
    !(root / "deps.lock").exist?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "call refuses --all as a flag it does not know: the bare verb is the full re-lock" do
    Given "the builtin's vocabulary"
    command = Dev::Cli::Builtins::UpdateDepsCommand.new

    When "parsing dev deps update --all"
    parsed_args(command, ["--all"])

    Then
    error = raises Dev::Cli::FlagVocabulary::UnknownFlagError
    error.message.include?("unknown flag '--all'")
    command.flags.empty?
  end

  test "call <name> installs the kept Ruby, not today's, so bundle lock runs under the version the lock keeps" do
    Given "a lock pinning ruby 4.0.6 within a ~4.0 range, a brew that resolves the range to 4.0.9 today, and the gem named"
    root = Pathname.new(Dir.mktmpdir("update-deps-kept-ruby-"))
    File.write(root / "dependencies.rb", <<~RUBY)
      require "dev/deps"
      Dev::Deps.define do
        ruby "~4.0"
        gem "rake"
      end
    RUBY
    ruby_pin = ->(version, commit) do
      Dev::Deps::Dependency.new(name: "ruby", integration: :ruby, group: :app, version:, hash: nil, source: "d3mlabs/d3mlabs@#{commit}",
        metadata: { "tap" => "d3mlabs/d3mlabs", "tap_commit" => commit, "version_suffix" => version, "format" => "bottle",
                    "platforms" => { "arm64_sequoia" => { "hash" => "SHA256=m", "link" => "https://x/m" } } })
    end
    Dev::Deps::Lockfile.new(dir: root).lock([ruby_pin.call("4.0.6", "0f1ba9ea")])
    resolver = mock
    brew = mock
    locker = mock
    registry = catalog
    command = Dev::Cli::Builtins::UpdateDepsCommand.new(registry:, resolver_factory: ->(*_universe) { resolver })
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update rake"
    command.call(args: parsed_args(command, ["rake"]), context: build_context(root))

    Then "the lock still pins 4.0.6; the install and the locker saw that version, not today's"
    _ * registry.repositories(project_root: root) >> {}
    _ * resolver.resolve(anything) >> [ruby_pin.call("4.0.9", "7d2877eb")]
    1 * registry.host_integrations(project_root: root, project_name: "TestProject", store: instance_of(Dev::Deps::LocalStore), ui: anything) >>
      { brew: brew, ruby: brew }
    1 * brew.install_all([ruby_pin.call("4.0.6", "0f1ba9ea")])
    1 * registry.lockers(project_root: root, ruby_version: "4.0.6") >> { bundler: locker }
    1 * locker.lock(anything, unlock: anything)
    Dev::Deps::Lockfile.new(dir: root).read.map(&:version) == ["4.0.6"]

    Cleanup
    $stdout = old_stdout
    FileUtils.rm_rf(root)
  end

  test "call hands the resolver the needs table: every built-in integration's own manifest, read as a library" do
    Given "an empty manifest, and the resolver construction observed"
    root = Pathname.new(Dir.mktmpdir("update-deps-needs-"))
    received = nil
    resolver = mock
    command = Dev::Cli::Builtins::UpdateDepsCommand.new(resolver_factory: lambda { |_repositories, _schemes, needs|
      received = needs
      resolver
    })
    old_stdout = $stdout
    $stdout = StringIO.new

    When "running dev deps update"
    command.call(args: no_args, context: build_context(root))

    Then "xcode's and wwise's needs are in the table, as brew declarations"
    _ * resolver.resolve(anything) >> []
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
    command = Dev::Cli::Builtins::UpdateDepsCommand.new
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

  FLOOR = "ghcr.io/d3mlabs/unreal-engine-build-base:ue5.8-3"

  # d3mlabs/ai-flow as `gh api` lists it: releases 1.3.0 and 1.4.0, and
  # the series tag v1 at 1.3.0's commit — a deploy rolled back below the
  # greatest tag.
  AI_FLOW_RELEASES = JSON.generate([
    { "tag_name" => "1.4.0", "draft" => false, "assets" => [{ "name" => "ai-flow-1.4.0.zip", "size" => 1, "digest" => "sha256:b4" }] },
    { "tag_name" => "1.3.0", "draft" => false, "assets" => [{ "name" => "ai-flow-1.3.0.zip", "size" => 1, "digest" => "sha256:a3" }] },
  ])
  AI_FLOW_TAGS = JSON.generate([
    { "name" => "v1", "commit" => { "sha" => "a" * 40 } },
    { "name" => "1.4.0", "commit" => { "sha" => "b" * 40 } },
    { "name" => "1.3.0", "commit" => { "sha" => "a" * 40 } },
  ])

  # The registry role: what dev's integrations contribute for a project.
  # Its static tables — the schemes and the integration classes the needs
  # table is read from — are the real ones; what a test cares about
  # (repositories, lockers, host integrations) it states as interactions.
  def catalog
    registry = typed_mock(Dev::Deps::Registry, class_of: true)
    registry.define_singleton_method(:schemes) { Dev::Deps::Registry.schemes }
    registry.define_singleton_method(:integration_classes) { Dev::Deps::Registry.integration_classes }
    registry
  end

  # The declarations a manifest body produces, equal by value to what the
  # command reads from the project's dependencies.rb.
  def declarations_of(&manifest)
    Dev::Deps.define(&manifest).declarations
  end

  # cellbound-3d's shape at dev#373: an image floor and the pip tool being added.
  def write_floor_manifest(root)
    File.write(root / "dependencies.rb", <<~RUBY)
      require "dev/deps"
      Dev::Deps.define do
        image "cellbound-3d-linux", from: "#{FLOOR}" do
          platform "linux/amd64"
        end
        pip "clang-format", "18.1.8"
      end
    RUBY
  end

  # The floor's pin as the lock on disk carries it.
  def floor_pin
    Dev::Deps::Dependency.new(
      name: "cellbound-3d-linux", integration: :image, group: :app, version: "ue5.8-3", hash: "SHA256=#{"a" * 64}",
      metadata: { "from" => "ghcr.io/d3mlabs/unreal-engine-build-base", "platform" => "linux/amd64",
                  "platforms" => ["linux/amd64"], "registry" => "ghcr.io/d3mlabs", "apt" => [] },
    )
  end

  # A pip pin as PipRepository resolves it: its source is the exact requirement.
  def pip_pin(name, version)
    Dev::Deps::Dependency.new(name:, integration: :pip, group: :app, version:, hash: nil, source: "#{name}==#{version}", metadata: {})
  end

  # A real OciRepository over the given HTTP client, with a gh token to offer.
  def denied_oci_repository(http)
    auth = typed_mock(Dev::GhAuth)
    auth.define_singleton_method(:token) { "t" }
    auth.define_singleton_method(:login) { "u" }
    Dev::Deps::OciRepository.new(auth:, http:)
  end

  # A gh pin as the Resolver mints it: its source is the tag's commit.
  def gh_pin(name, version, sha)
    Dev::Deps::Dependency.new(name:, integration: :gh, group: :app, version:, hash: nil, source: sha,
      metadata: { "repo" => "d3mlabs/ai-flow", "commit" => sha, "asset_pattern" => "*.zip" })
  end

  # clang-format on a pip index, at one version.
  def clang_format_package(version)
    Dev::Deps::Package.new(
      id: Dev::Deps::PackageId.new(integration: :pip, name: "clang-format", source: nil),
      versions: [Dev::Deps::PackageVersion.new(version:)],
    )
  end

  # A bottled core-tap formula pin as BrewRepository resolves it: its source
  # is the tap at the commit.
  def brew_pin(name, version, commit: "0f1ba9ea", group: :app)
    Dev::Deps::Dependency.new(name:, integration: :brew, group:, version:, hash: nil, source: "homebrew/core@#{commit}",
      metadata: { "tap_commit" => commit, "format" => "bottle",
                  "platforms" => { "x86_64_linux" => { "hash" => "SHA256=l", "link" => "https://x/l" } } })
  end

  def build_context(project_root, ui: RecordingUi.new)
    Dev::Cli::ExecutionContext.new(
      ui: ui,
      project: Dev::Cli::ProjectContext.new(name: "TestProject", root: project_root),
    )
  end
end
