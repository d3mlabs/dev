# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/local_store"
require "dev/shadowenv_ruby"
require "fileutils"
require "stringio"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class ShadowenvRubyTest < Minitest::Test
  # --- activate! ---

  test "activate! points the project shadowenv at a keg and this side's gem home in the store, and writes .ruby-version from the locked version" do
    Given "a project root, the locked Ruby's keg and an empty store"
    tmpdir = Dir.mktmpdir("shadowenv-activate-test-")
    keg = Pathname(tmpdir) / "Cellar" / "ruby@4.0.9" / "4.0.9"
    FileUtils.mkdir_p(keg / "bin")
    store_root = File.join(tmpdir, "store")

    When "activating"
    Dev::ShadowenvRuby.activate!(
      keg: keg, version: "4.0.9", project_root: Pathname(tmpdir),
      project_name: "proj", store: Dev::Deps::LocalStore.new(data_root: store_root),
    )

    Then "the gem home exists in the store under the project's key; the lisp names the keg as RUBY_ROOT and the gem home as GEM_HOME; .ruby-version carries the locked version; the shell hook is ensured"
    _ * Dev::ShadowenvRuby.ensure_shadowenv_shell_hook!
    gem_home = Pathname(store_root) / "gems" / "proj" / Dev::ContainerContext.side / "4.0.9"
    gem_home.directory?
    lisp = File.read(File.join(tmpdir, ".shadowenv.d", "510_ruby.lisp"))
    lisp.include?('(provide "ruby" "4.0.9")')
    lisp.include?(%((env/set "RUBY_ROOT" "#{keg}")))
    lisp.include?(%((env/prepend-to-pathlist "PATH" "#{keg / "bin"}")))
    lisp.include?(%((env/set "GEM_HOME" "#{gem_home}")))
    File.read(File.join(tmpdir, ".ruby-version")) == "4.0.9\n"
    Dir.children(tmpdir).sort == [".ruby-version", ".shadowenv.d", "Cellar", "store"]

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "activate! gives two projects on one keg disjoint gem homes (dev#294: bundle clean in one touches nothing of the other)" do
    Given "two project roots locking the same Ruby, one store"
    tmpdir = Dir.mktmpdir("shadowenv-activate-test-")
    keg = Pathname(tmpdir) / "Cellar" / "ruby@4.0.9" / "4.0.9"
    FileUtils.mkdir_p(keg / "bin")
    store = Dev::Deps::LocalStore.new(data_root: File.join(tmpdir, "store"))
    roots = { "alpha" => Pathname(tmpdir) / "alpha", "beta" => Pathname(tmpdir) / "beta" }
    roots.each_value(&:mkpath)

    When "activating both"
    roots.each do |name, root|
      Dev::ShadowenvRuby.activate!(keg: keg, version: "4.0.9", project_root: root, project_name: name, store: store)
    end

    Then "each lisp names its own gem home, neither of which is the keg's gem dir"
    _ * Dev::ShadowenvRuby.ensure_shadowenv_shell_hook!
    gem_homes = roots.transform_values { |root| (root / ".shadowenv.d" / "510_ruby.lisp").read[/\(env\/set "GEM_HOME" "([^"]+)"\)/, 1] }
    gem_homes["alpha"] != gem_homes["beta"]
    gem_homes.values.all? { |home| Pathname(home).directory? }
    gem_homes.values.none? { |home| home.start_with?(keg.to_s) }

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  # --- gem_home_key ---

  test "gem_home_key names the store gem home by project, #{side} side and the keg's full version" do
    When "keying a project's gem home on a keg brew named with a revision"
    key = Dev::ShadowenvRuby.gem_home_key(
      project_name: "cellbound-3d", keg: Pathname("/opt/homebrew/Cellar/ruby@4.0.6/4.0.6_1"), inside: inside,
    )

    Then "the base is the project's under the gems root, the platform the side, the version the keg's"
    key.base == "~/.dev/gems/cellbound-3d"
    key.platform == side
    key.version == "4.0.6_1"

    Where
    side        | inside
    "host"      | false
    "container" | true
  end

  test "gem_home_key reads the side from the inside marker when none is given" do
    Given "a process carrying the inside marker"
    original = ENV[Dev::ContainerContext::MARKER]
    ENV[Dev::ContainerContext::MARKER] = "1"

    When "keying a gem home without naming a side"
    key = Dev::ShadowenvRuby.gem_home_key(project_name: "proj", keg: Pathname("/opt/homebrew/Cellar/ruby@4.0.6/4.0.6"))

    Then "it is the container's"
    key.platform == Dev::ContainerContext::CONTAINER_SIDE

    Cleanup
    original ? ENV[Dev::ContainerContext::MARKER] = original : ENV.delete(Dev::ContainerContext::MARKER)
  end


  # --- gem_api_version ---

  test "gem_api_version returns #{expected} for #{version}" do
    Given "a ruby version string"
    result = Dev::ShadowenvRuby.gem_api_version(version)

    Expect "the correct format is returned"
    result == expected

    Where
    version  | expected
    "4.0.1"  | "4.0.0"
    "3.2.5"  | "3.2.0"
    "2.7.0"  | "2.7.0"
    "3.3.10" | "3.3.0"
    "4"      | "4.0"
  end


  # --- generate_ruby_lisp ---

  # The gem home every lisp test passes: the store path activate! would hand in.
  GEM_HOME = "/var/lib/dev/gems/proj/host/4.0.1"

  test "generate_ruby_lisp contains provide directive with version" do
    When "we generate lisp"
    result = Dev::ShadowenvRuby.generate_ruby_lisp("/opt/ruby/4.0.1", "4.0.1", GEM_HOME)

    Then "the provide directive is present"
    assert_includes result, '(provide "ruby" "4.0.1")'
  end

  test "generate_ruby_lisp sets RUBY_ROOT" do
    When "we generate lisp"
    result = Dev::ShadowenvRuby.generate_ruby_lisp("/opt/ruby/4.0.1", "4.0.1", GEM_HOME)

    Then "RUBY_ROOT is set"
    assert_includes result, '(env/set "RUBY_ROOT" "/opt/ruby/4.0.1")'
  end

  test "generate_ruby_lisp prepends ruby bin to PATH" do
    When "we generate lisp"
    result = Dev::ShadowenvRuby.generate_ruby_lisp("/opt/ruby/4.0.1", "4.0.1", GEM_HOME)

    Then "PATH includes ruby bin"
    assert_includes result, '(env/prepend-to-pathlist "PATH" "/opt/ruby/4.0.1/bin")'
  end

  test "generate_ruby_lisp sets RUBY_VERSION env var" do
    When "we generate lisp"
    result = Dev::ShadowenvRuby.generate_ruby_lisp("/opt/ruby/4.0.1", "4.0.1", GEM_HOME)

    Then "RUBY_VERSION is set"
    assert_includes result, '(env/set "RUBY_VERSION" "4.0.1")'
  end

  test "generate_ruby_lisp makes the project's gem home GEM_HOME, with the keg's gem dir behind it on GEM_PATH and PATH so default gems stay loadable" do
    Given "a keg laid out as brew pours it"
    tmpdir = Dir.mktmpdir("shadowenv-gem-home-test-")
    keg = File.join(tmpdir, "Cellar", "ruby@4.0.1", "4.0.1")
    gem_dir = File.join(keg, "lib", "ruby", "gems", "4.0.0")
    FileUtils.mkdir_p(gem_dir)

    When "we generate lisp"
    result = Dev::ShadowenvRuby.generate_ruby_lisp(keg, "4.0.1", GEM_HOME)

    Then "GEM_ROOT is the keg's gem dir, GEM_HOME the gem home, GEM_PATH the gem home then the keg's, PATH the gem home's bin ahead of the keg's, and nothing derives from HOME"
    result.include?(%((env/set "GEM_ROOT" "#{gem_dir}")))
    result.include?(%((env/set "GEM_HOME" "#{GEM_HOME}")))
    result.index(%((env/prepend-to-pathlist "GEM_PATH" "#{gem_dir}"))) < result.index(%((env/prepend-to-pathlist "GEM_PATH" "#{GEM_HOME}")))
    result.index(%((env/prepend-to-pathlist "PATH" "#{gem_dir}/bin"))) < result.index(%((env/prepend-to-pathlist "PATH" "#{GEM_HOME}/bin")))
    !result.include?('(env/get "HOME")')

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  # --- ensure_shadowenv_shell_hook! ---

  test "ensure_shadowenv_shell_hook! off a tty writes nothing (ai-flow#116: an agent run has no shell to hook)" do
    Given "a zsh shell with no .zshrc, headless"
    tmpdir = Dir.mktmpdir("shadowenv-hook-test-")
    original_shell = ENV["SHELL"]
    original_home = ENV["HOME"]
    ENV["SHELL"] = "/bin/zsh"
    ENV["HOME"] = tmpdir

    When "we ensure the shell hook"
    Dev::ShadowenvRuby.ensure_shadowenv_shell_hook!(interactive: false)

    Then "no RC file appears"
    Dir.children(tmpdir).empty?

    Cleanup
    ENV["SHELL"] = original_shell
    ENV["HOME"] = original_home
    FileUtils.rm_rf(tmpdir)
  end

  test "ensure_shadowenv_shell_hook! adds hook to zshrc when not present" do
    Given "a zsh shell with no .zshrc"
    tmpdir = Dir.mktmpdir("shadowenv-hook-test-")
    original_shell = ENV["SHELL"]
    original_home = ENV["HOME"]
    ENV["SHELL"] = "/bin/zsh"
    ENV["HOME"] = tmpdir

    When "we ensure the shell hook"
    Dev::ShadowenvRuby.ensure_shadowenv_shell_hook!(interactive: true)

    Then "the hook is added to .zshrc"
    zshrc = File.read(File.join(tmpdir, ".zshrc"))
    assert_includes zshrc, 'eval "$(shadowenv init zsh)"'

    Cleanup
    ENV["SHELL"] = original_shell
    ENV["HOME"] = original_home
    FileUtils.rm_rf(tmpdir)
  end

  test "ensure_shadowenv_shell_hook! leaves a hand-installed hook alone" do
    Given "a zsh shell with existing shadowenv hook in .zshrc"
    tmpdir = Dir.mktmpdir("shadowenv-hook-test-")
    original_shell = ENV["SHELL"]
    original_home = ENV["HOME"]
    ENV["SHELL"] = "/bin/zsh"
    ENV["HOME"] = tmpdir
    File.write(File.join(tmpdir, ".zshrc"), 'eval "$(shadowenv init zsh)"')
    before = File.read(File.join(tmpdir, ".zshrc"))

    When "we ensure the shell hook"
    Dev::ShadowenvRuby.ensure_shadowenv_shell_hook!(interactive: true)

    Then "the RC is untouched"
    File.read(File.join(tmpdir, ".zshrc")) == before

    Cleanup
    ENV["SHELL"] = original_shell
    ENV["HOME"] = original_home
    FileUtils.rm_rf(tmpdir)
  end

  test "ensure_shadowenv_shell_hook! recognizes an RC written before the shared installer" do
    Given "a zsh .zshrc carrying the historical dev marker"
    tmpdir = Dir.mktmpdir("shadowenv-hook-test-")
    original_shell = ENV["SHELL"]
    original_home = ENV["HOME"]
    ENV["SHELL"] = "/bin/zsh"
    ENV["HOME"] = tmpdir
    File.write(File.join(tmpdir, ".zshrc"), "\n# Shadowenv (added by dev)\neval \"$(shadowenv init zsh)\"\n")
    before = File.read(File.join(tmpdir, ".zshrc"))

    When "we ensure the shell hook"
    Dev::ShadowenvRuby.ensure_shadowenv_shell_hook!(interactive: true)

    Then "the old install is recognized, not re-appended"
    File.read(File.join(tmpdir, ".zshrc")) == before

    Cleanup
    ENV["SHELL"] = original_shell
    ENV["HOME"] = original_home
    FileUtils.rm_rf(tmpdir)
  end

  test "ensure_shadowenv_shell_hook! adds hook to bash_profile for bash" do
    Given "a bash shell with no .bash_profile"
    tmpdir = Dir.mktmpdir("shadowenv-hook-test-")
    original_shell = ENV["SHELL"]
    original_home = ENV["HOME"]
    ENV["SHELL"] = "/bin/bash"
    ENV["HOME"] = tmpdir

    When "we ensure the shell hook"
    Dev::ShadowenvRuby.ensure_shadowenv_shell_hook!(interactive: true)

    Then "the hook is added to .bash_profile"
    bash_profile = File.read(File.join(tmpdir, ".bash_profile"))
    assert_includes bash_profile, 'eval "$(shadowenv init bash)"'

    Cleanup
    ENV["SHELL"] = original_shell
    ENV["HOME"] = original_home
    FileUtils.rm_rf(tmpdir)
  end

  test "ensure_shadowenv_shell_hook! warns when the RC file cannot be written instead of raising" do
    Given "a zsh shell whose home directory is not writable"
    tmpdir = Dir.mktmpdir("shadowenv-hook-test-")
    original_shell = ENV["SHELL"]
    original_home = ENV["HOME"]
    ENV["SHELL"] = "/bin/zsh"
    ENV["HOME"] = tmpdir
    FileUtils.chmod(0o500, tmpdir)

    When "we ensure the shell hook"
    stderr = capture_stderr { Dev::ShadowenvRuby.ensure_shadowenv_shell_hook!(interactive: true) }

    Then "the failure is a warning"
    stderr.include?("Could not add shadowenv hook")

    Cleanup
    ENV["SHELL"] = original_shell
    ENV["HOME"] = original_home
    FileUtils.chmod(0o700, tmpdir)
    FileUtils.rm_rf(tmpdir)
  end

  test "ensure_shadowenv_shell_hook! warns on an unsupported shell instead of raising: the Ruby activation goes on" do
    Given "a plain sh user"
    tmpdir = Dir.mktmpdir("shadowenv-hook-test-")
    original_shell = ENV["SHELL"]
    original_home = ENV["HOME"]
    ENV["SHELL"] = "/bin/sh"
    ENV["HOME"] = tmpdir

    When "we ensure the shell hook"
    stderr = capture_stderr { Dev::ShadowenvRuby.ensure_shadowenv_shell_hook!(interactive: true) }

    Then "the refusal is a warning naming the supported set, and nothing is written"
    stderr.include?("Could not add shadowenv hook")
    stderr.include?("zsh, bash, fish")
    Dir.children(tmpdir).empty?

    Cleanup
    ENV["SHELL"] = original_shell
    ENV["HOME"] = original_home
    FileUtils.rm_rf(tmpdir)
  end

  private

  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end
end
