# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/self_contained_tree"
require "support/recording_toolchain_exec"
require "support/tool_tree_fixtures"
require "fileutils"
require "open3"
require "pathname"
require "rbconfig"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::SelfContainedTreeTest < Minitest::Test
  include ToolTreeFixtures

  # @param tree [Pathname]
  # @return [Dev::Deps::SelfContainedTree::GemBundle] the tree's Ruby part
  def gem_bundle(tree)
    Dev::Deps::SelfContainedTree.new(root: tree).gem_bundle
  end

  # --- the tree: what ships decides, by content ------------------------------

  test "a tree carrying dependencies.rb and deps.lock is self-contained; one without either is a plain asset" do
    Given "three trees"
    root = Pathname(Dir.mktmpdir("dev-self-contained-"))
    shipped = tool_tree(root / "tree")
    manifest_only = root / "manifest-only"
    manifest_only.mkpath
    (manifest_only / "dependencies.rb").write("")
    bare = root / "bare"
    bare.mkpath

    Expect
    Dev::Deps::SelfContainedTree.carried_by?(shipped)
    !Dev::Deps::SelfContainedTree.carried_by?(manifest_only)
    !Dev::Deps::SelfContainedTree.carried_by?(bare)

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "pins is what the tree's own lock pins" do
    Given
    root = Pathname(Dir.mktmpdir("dev-self-contained-"))
    tree = Dev::Deps::SelfContainedTree.new(root: tool_tree(root / "tree"))

    Expect
    tree.pins.map { |pin| [pin.integration, pin.version] } == [[:ruby, "4.0.6"]]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "executables read the tree's exe/: #{description}" do
    Given
    root = Pathname(Dir.mktmpdir("dev-self-contained-"))
    tree = tool_tree(root / "tree", exes:)
    # A directory under exe/ is not an executable.
    (tree / "exe/man").mkpath if exes.any?

    Expect
    Dev::Deps::SelfContainedTree.new(root: tree).executables.map { |exe| exe.basename.to_s } == exes.sort

    Cleanup
    FileUtils.rm_rf(root)

    Where
    description             | exes
    "one exe"               | ["ai-flow"]
    "two exes, sorted"      | ["zeta", "alpha"]
    "no executables at all" | []
  end

  test "a complete tree has no gaps; a plain asset — neither manifest nor lock — has none either, there being nothing to converge" do
    Given "a complete tree, and a bare one with only a binary"
    root = Pathname(Dir.mktmpdir("dev-self-contained-"))
    complete = tool_tree(root / "tree")
    plain = root / "plain"
    plain.mkpath
    (plain / "game.exe").write("exe")

    Expect
    Dev::Deps::SelfContainedTree.new(root: complete).gaps == []
    Dev::Deps::SelfContainedTree.new(root: plain).gaps == []

    Cleanup
    FileUtils.rm_rf(root)
  end

  NO_LOCK = "ships dependencies.rb without deps.lock — a self-contained tree carries its lock beside its manifest"
  NO_MANIFEST = "ships deps.lock without dependencies.rb — a self-contained tree carries its lock beside its manifest"
  NO_RUBY = "pins no ruby in deps.lock — its executables and gems run under the Ruby its lock pins"
  NO_EXE = "has no exe/ — a self-contained tree's executables are its exe/, one bin/ launcher is written per entry"
  COLLISION = "carries bin/ai-flow beside exe/ai-flow — a self-contained tree's own bin/ may not carry the name of one of its exe/"

  # The tree reshaped after tool_tree laid it: a file removed, a bin/ of its own.
  def reshape(tree, remove: nil, own_bin: nil)
    (tree / remove).file? ? (tree / remove).delete : (tree / remove).rmdir if remove
    return unless own_bin

    (tree / "bin").mkpath
    (tree / "bin" / own_bin).write("#!/bin/sh\necho mine\n")
  end

  test "gaps names what the install would refuse, as the install words it: #{description}" do
    Given
    root = Pathname(Dir.mktmpdir("dev-self-contained-"))
    tree = tool_tree(root / "tree", lock:, exes:, gemfile:)
    reshape(tree, remove:, own_bin:)

    Expect
    Dev::Deps::SelfContainedTree.new(root: tree).gaps == expected

    Cleanup
    FileUtils.rm_rf(root)

    Where
    description                      | lock         | exes                   | gemfile | remove            | own_bin   | expected
    "the manifest without the lock"  | RUBY_LOCK    | ["ai-flow"]            | true    | "deps.lock"       | nil       | [NO_LOCK]
    "the lock without the manifest"  | RUBY_LOCK    | ["ai-flow"]            | true    | "dependencies.rb" | nil       | [NO_MANIFEST]
    "a Gemfile and no ruby pin"      | FORMULA_LOCK | ["ai-flow"]            | true    | nil               | nil       | [NO_RUBY]
    "no exe/ at all"                 | RUBY_LOCK    | []                     | true    | "exe"             | nil       | [NO_EXE]
    "an empty exe/"                  | RUBY_LOCK    | []                     | true    | nil               | nil       | [NO_EXE]
    "a bin/ name an exe/ would take" | RUBY_LOCK    | ["ai-flow", "ai-gate"] | false   | nil               | "ai-flow" | [COLLISION]
    "every gap at once, in order"    | FORMULA_LOCK | ["ai-flow"]            | true    | nil               | "ai-flow" | [NO_RUBY, COLLISION]
  end

  test "write_launchers! writes an executable bin/<name> per exe/<name>, each the block's script for it" do
    Given
    root = Pathname(Dir.mktmpdir("dev-self-contained-"))
    tree = tool_tree(root / "tree", exes: ["ai-flow", "ai-gate"])

    When
    Dev::Deps::SelfContainedTree.new(root: tree).write_launchers! { |exe| "#!/bin/sh\necho #{exe.basename}\n" }

    Then
    (tree / "bin").children.map { |launcher| launcher.basename.to_s }.sort == ["ai-flow", "ai-gate"]
    (tree / "bin/ai-flow").executable?
    (tree / "bin/ai-flow").read == "#!/bin/sh\necho ai-flow\n"
    (tree / "bin/ai-gate").read == "#!/bin/sh\necho ai-gate\n"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "write_launchers! writes nothing for a tree with no exe/ and raises nothing" do
    Given
    root = Pathname(Dir.mktmpdir("dev-self-contained-"))
    tree = tool_tree(root / "tree", exes: [])

    When
    Dev::Deps::SelfContainedTree.new(root: tree).write_launchers! { |_exe| "#!/bin/sh\n" }

    Then
    !(tree / "bin").exist?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a tree whose own bin/ already carries an exe's name is refused before any launcher is written" do
    Given "a tree with bin/ai-flow of its own and exe/ai-flow, exe/ai-gate"
    root = Pathname(Dir.mktmpdir("dev-self-contained-"))
    tree = tool_tree(root / "tree", exes: ["ai-flow", "ai-gate"])
    (tree / "bin").mkpath
    (tree / "bin/ai-flow").write("#!/bin/sh\necho mine\n")

    When
    Dev::Deps::SelfContainedTree.new(root: tree).write_launchers! { |_exe| "#!/bin/sh\n" }

    Then
    error = raises(Dev::Deps::SelfContainedTree::LauncherCollisionError)
    error.message.include?((tree / "bin/ai-flow").to_s)
    (tree / "bin/ai-flow").read == "#!/bin/sh\necho mine\n"
    !(tree / "bin/ai-gate").exist?

    Cleanup
    FileUtils.rm_rf(root)
  end

  # --- the Ruby part: the gem integration's steps, in bundler's words --------

  test "pinned_ruby is the lock's ruby pin, as brew installs it" do
    Given
    root = Pathname(Dir.mktmpdir("dev-self-contained-"))
    bundle = gem_bundle(tool_tree(root / "tree"))

    When
    pin = bundle.pinned_ruby

    Then
    [pin.integration, pin.version, pin.metadata["version_suffix"], pin.metadata["tap"]] == [:ruby, "4.0.6", "4.0.6", "d3mlabs/d3mlabs"]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a lock pinning no ruby is refused by name: nothing to run the executables under" do
    Given "a tree whose lock pins only a formula"
    root = Pathname(Dir.mktmpdir("dev-self-contained-"))
    tree = tool_tree(root / "tree", lock: FORMULA_LOCK)

    When
    gem_bundle(tree).pinned_ruby

    Then
    error = raises(Dev::Deps::SelfContainedTree::GemBundle::NoRubyPinError)
    error.message.include?((tree / "deps.lock").to_s)

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "ruby_pinned? reads the lock without raising, and gaps is the pin's clause or none: #{description}" do
    Given
    root = Pathname(Dir.mktmpdir("dev-self-contained-"))
    bundle = gem_bundle(tool_tree(root / "tree", lock:))

    Expect
    bundle.ruby_pinned? == pinned
    bundle.gaps == gaps

    Cleanup
    FileUtils.rm_rf(root)

    Where
    description      | lock         | pinned | gaps
    "a ruby pin"     | RUBY_LOCK    | true   | []
    "a formula only" | FORMULA_LOCK | false  | [NO_RUBY]
  end

  test "gems? and vendored? read the tree: #{description}" do
    Given
    root = Pathname(Dir.mktmpdir("dev-self-contained-"))
    tree = tool_tree(root / "tree", gemfile:)
    (tree / "vendor/bundle").mkpath if vendored

    Expect
    bundle = gem_bundle(tree)
    bundle.gems? == gemfile
    bundle.vendored? == vendored

    Cleanup
    FileUtils.rm_rf(root)

    Where
    description                 | gemfile | vendored
    "gems, not yet vendored"    | true    | false
    "gems vendored at release"  | true    | true
    "ruby only"                 | false   | false
  end

  test "vendor! runs a frozen bundle install into the tree's vendor/bundle under the toolchain, through the seam" do
    Given "a tree with gems and a recording toolchain"
    root = Pathname(Dir.mktmpdir("dev-self-contained-"))
    tree = tool_tree(root / "tree")
    exec = RecordingToolchainExec.new

    When
    gem_bundle(tree).vendor!(exec:, cache: root / "tool-caches/bundler")

    Then "one bundle install, on the tree's own Gemfile, into its own path, frozen, runtime groups only, sharing nothing, caching in the store"
    exec.calls == [[
      ["bundle", "install"],
      {
        "BUNDLE_GEMFILE" => "#{tree}/Gemfile",
        "BUNDLE_PATH" => "#{tree}/vendor/bundle",
        "BUNDLE_FROZEN" => "true",
        "BUNDLE_WITHOUT" => "development:test",
        "BUNDLE_DISABLE_SHARED_GEMS" => "true",
        "BUNDLE_GLOBAL_GEM_CACHE" => "true",
        "BUNDLE_USER_CACHE" => "#{root}/tool-caches/bundler",
      },
    ]]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "vendor! without a cache leaves bundler its own" do
    Given
    root = Pathname(Dir.mktmpdir("dev-self-contained-"))
    tree = tool_tree(root / "tree")
    exec = RecordingToolchainExec.new

    When
    gem_bundle(tree).vendor!(exec:)

    Then
    exec.calls.size == 1
    exec.calls[0][1].keys == %w[BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_FROZEN BUNDLE_WITHOUT BUNDLE_DISABLE_SHARED_GEMS]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "vendor! on a tree without a Gemfile has no gems to install and runs nothing" do
    Given
    root = Pathname(Dir.mktmpdir("dev-self-contained-"))
    tree = tool_tree(root / "tree", gemfile: false)
    exec = RecordingToolchainExec.new

    When
    gem_bundle(tree).vendor!(exec:)

    Then
    exec.calls.empty?

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a failed bundle install is a VendorError carrying bundler's words" do
    Given
    root = Pathname(Dir.mktmpdir("dev-self-contained-"))
    tree = tool_tree(root / "tree")

    When
    gem_bundle(tree).vendor!(exec: RecordingToolchainExec.new(fail: true))

    Then
    error = raises(Dev::Deps::SelfContainedTree::GemBundle::VendorError)
    error.message.include?("vendor/bundle")
    error.message.include?("could not find compatible versions")

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "binstub! writes a launcher per exe/<name>: bin/dev's sh half — unset the harness activation, exec the pinned Ruby on the exe" do
    Given "a tree with gems and two executables"
    root = Pathname(Dir.mktmpdir("dev-self-contained-"))
    tree = tool_tree(root / "tree", exes: ["ai-flow", "ai-gate"])
    ruby = Pathname("/opt/homebrew/Cellar/ruby@4.0.6/4.0.6/bin/ruby")

    When
    gem_bundle(tree).binstub!(ruby:)

    Then
    (tree / "bin").children.map { |launcher| launcher.basename.to_s }.sort == ["ai-flow", "ai-gate"]
    (tree / "bin/ai-flow").executable?
    (tree / "bin/ai-flow").read == <<~SH
      #!/bin/sh
      # Generated by dev: ai-flow under this tree's own Ruby. The executable selects the tree's gems itself.
      tree="$(cd "$(dirname "$0")/.." && pwd -P)"
      unset RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLE_LOCKFILE BUNDLE_PATH BUNDLE_APP_CONFIG BUNDLE_BIN BUNDLE_BIN_PATH BUNDLER_VERSION BUNDLER_SETUP
      exec /opt/homebrew/Cellar/ruby@4.0.6/4.0.6/bin/ruby "$tree/exe/ai-flow" "$@"
    SH

    Cleanup
    FileUtils.rm_rf(root)
  end

  # The binstub neither exports nor sets up bundler: with gems or without,
  # it is the same script. Finding the gems is the executable's, in-process.
  test "a Ruby-only tree's binstub is byte-for-byte the binstub of a tree with gems" do
    Given "two trees, one with a Gemfile and one without"
    root = Pathname(Dir.mktmpdir("dev-self-contained-"))
    with_gems = tool_tree(root / "gems")
    ruby_only = tool_tree(root / "ruby-only", gemfile: false)
    ruby = Pathname("/opt/homebrew/Cellar/ruby@4.0.6/4.0.6/bin/ruby")

    When
    gem_bundle(with_gems).binstub!(ruby:)
    gem_bundle(ruby_only).binstub!(ruby:)

    Then
    (with_gems / "bin/ai-flow").read == (ruby_only / "bin/ai-flow").read

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "binstub! keeps the tree's rule: its own bin/ carrying an exe's name is a collision" do
    Given
    root = Pathname(Dir.mktmpdir("dev-self-contained-"))
    tree = tool_tree(root / "tree")
    (tree / "bin").mkpath
    (tree / "bin/ai-flow").write("#!/bin/sh\necho mine\n")

    When
    gem_bundle(tree).binstub!(ruby: Pathname("/usr/bin/ruby"))

    Then
    raises(Dev::Deps::SelfContainedTree::LauncherCollisionError)
    (tree / "bin/ai-flow").read == "#!/bin/sh\necho mine\n"

    Cleanup
    FileUtils.rm_rf(root)
  end

  # The gem a vendored tree's executable finds at the documented path. A
  # frozen `bundle install` with BUNDLE_PATH=vendor/bundle lays each gem as
  # `vendor/bundle/ruby/<ruby_version>/{specifications,gems}/<name>-<v>`;
  # this is that layout by hand, for this test's Ruby.
  #
  # @param tree [Pathname]
  # @param name [String]
  # @param body [String] the gem's entry file
  # @return [void]
  def plant_vendored_gem(tree, name, body)
    gem_home = tree / Dev::Deps::SelfContainedTree::GemBundle::VENDOR_DIR / "ruby" / RbConfig::CONFIG["ruby_version"]
    full_name = "#{name}-1.0.0"
    (gem_home / "specifications").mkpath
    (gem_home / "gems" / full_name / "lib").mkpath
    (gem_home / "gems" / full_name / "lib" / "#{name}.rb").write(body)
    spec = Gem::Specification.new do |s|
      s.name = name
      s.version = "1.0.0"
      s.summary = "planted"
      s.authors = ["self_contained_tree_test"]
      s.require_paths = ["lib"]
    end
    (gem_home / "specifications" / "#{full_name}.gemspec").write(spec.to_ruby)
  end

  # An executable written to the self-contained tree's contract: it selects
  # the tree's vendored gems and the Ruby's own, in-process, by position —
  # and reports what it loaded and what env reached it.
  CONTRACT_EXE = <<~RUBY
    #!/usr/bin/env ruby
    tree = File.expand_path("..", __dir__)
    tree_gems = File.join(tree, "vendor/bundle/ruby", RbConfig::CONFIG["ruby_version"])
    ruby_own_gems = File.join(RbConfig::CONFIG["rubylibprefix"], "gems", RbConfig::CONFIG["ruby_version"])
    Gem.use_paths(tree_gems, [tree_gems, ruby_own_gems])
    require "tree_probe"
    puts TREE_PROBE
    puts ENV.fetch("GEM_HOME", "(unset)")
    puts ENV.fetch("BUNDLE_GEMFILE", "(unset)")
  RUBY

  # The whole contract, end to end under a hostile caller: the binstub's
  # unset is why the Ruby boots at all (a RUBYOPT=-rbundler/setup on a
  # Gemfile that is not there would kill it first), the in-process
  # selection is why the gem is found with GEM_HOME pointing nowhere, and
  # GEM_HOME still reaching the executable is what the tool's children
  # inherit — the caller's gem env, untouched.
  test "through the binstub, an executable written to the contract loads the tree's vendored gem; the harness activation is gone and the caller's gem env is passed through" do
    Given "a tree with a planted gem at the documented path and a contract-following exe, binstubbed with this test's Ruby"
    root = Pathname(Dir.mktmpdir("dev-self-contained-"))
    tree = tool_tree(root / "tree")
    plant_vendored_gem(tree, "tree_probe", %(TREE_PROBE = "probe loaded from the tree"\n))
    (tree / "exe/ai-flow").write(CONTRACT_EXE)
    gem_bundle(tree).binstub!(ruby: Pathname(RbConfig.ruby))
    hostile = {
      "RUBYOPT" => "-rbundler/setup",
      "BUNDLE_GEMFILE" => (root / "nowhere/Gemfile").to_s,
      "GEM_HOME" => (root / "callers-gems").to_s,
      "GEM_PATH" => (root / "callers-gems").to_s,
    }

    When "running the binstub under that env"
    out, err, status = Open3.capture3(hostile, (tree / "bin/ai-flow").to_s)

    Then
    [status.success?, err] == [true, ""]
    out.lines(chomp: true) == ["probe loaded from the tree", (root / "callers-gems").to_s, "(unset)"]

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "a binstub runs: the executable sees its arguments under the given Ruby, from wherever the tree sits" do
    Given "a Ruby-only tree binstubbed with this test's Ruby, then moved — as a staging tree is published"
    root = Pathname(Dir.mktmpdir("dev-self-contained-"))
    tree = tool_tree(root / "tree", gemfile: false)
    gem_bundle(tree).binstub!(ruby: Pathname(RbConfig.ruby))
    published = root / "published"
    FileUtils.mv(tree, published)

    When "running the binstub by its new path"
    out, err, status = Open3.capture3((published / "bin/ai-flow").to_s, "dispatch", "--dry")

    Then
    [status.success?, err] == [true, ""]
    out == "ai-flow says dispatch --dry\n"

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "the binstub's harness scrub is bin/dev's own list — the one source, checked against the locked bundler there" do
    Given "bin/dev's unset line, continuation joined"
    bin_dev = File.read(File.expand_path("../../../bin/dev", __dir__))
    shim_keys = bin_dev[/^unset ((?:\\\n|[^\n])*)/, 1].gsub("\\\n", " ").split

    Expect
    Dev::Deps::SelfContainedTree::GemBundle::HARNESS_ACTIVATION_KEYS == shim_keys
  end
end
