# typed: false
# frozen_string_literal: true

require "test_helper"
require "shadowenv_ruby"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class ShadowenvRubyTest < Minitest::Test
  # --- resolve_ruby_version ---

  test "resolve_ruby_version returns explicit version when provided" do
    Given "an explicit version above the minimum"
    ruby_version = "4.0.1"

    When "we resolve with an explicit version"
    result = ShadowenvRuby.resolve_ruby_version(ruby_version)

    Then "the explicit version is returned and homebrew version is ignored"
    _ * ShadowenvRuby.detect_homebrew_ruby_version >> "3.2.0"
    result == ruby_version
  end

  test "resolve_ruby_version falls back to Homebrew when explicit is nil" do
    Given "no explicit version"
    ruby_version = nil

    When "we resolve with nil"
    result = ShadowenvRuby.resolve_ruby_version(nil)

    Then "the Homebrew version is returned"
    _ * ShadowenvRuby.detect_homebrew_ruby_version >> "3.3.0"
    result == "3.3.0"
  end

  test "resolve_ruby_version aborts when no version is available" do
    Given "no explicit version"
    ruby_version = nil

    When "we resolve the ruby version"
    ShadowenvRuby.resolve_ruby_version(ruby_version)

    Then "it aborts"
    _ * ShadowenvRuby.detect_homebrew_ruby_version >> nil
    1 * Kernel.abort("dev: No Ruby declared in dependencies.rb and Homebrew Ruby not found. Run: brew install ruby")
  end

  test "resolve_ruby_version aborts when version is below minimum" do
    Given "a version below the minimum"
    ruby_version = "2.6.0"

    When "we resolve the ruby version"
    ShadowenvRuby.resolve_ruby_version(ruby_version)

    Then "it aborts for version below 2.7.0"
    1 * Kernel.abort("dev: Resolved Ruby 2.6.0 is below dev's minimum (>= 2.7.0). Pin a newer version in dependencies.rb or run: brew upgrade ruby")
  end

  # --- provisioned? ---

  test "provisioned? returns true when lisp file matches version" do
    Given "a project root with matching 510_ruby.lisp"
    ruby_version = "4.0.1"
    tmpdir = Dir.mktmpdir("shadowenv-test-")
    shadowenv_d = File.join(tmpdir, ".shadowenv.d")
    FileUtils.mkdir_p(shadowenv_d)
    File.write(
      File.join(shadowenv_d, "510_ruby.lisp"),
      ShadowenvRuby.generate_ruby_lisp("/opt/ruby/4.0.1", ruby_version)
    )

    Expect ".provisioned? returns true when lisp file matches version"
    ShadowenvRuby.provisioned?(ruby_version, project_root: tmpdir) == true

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "provisioned? returns false when lisp file has different version" do
    Given "a project root with 510_ruby.lisp for a different version"
    tmpdir = Dir.mktmpdir("shadowenv-test-")
    shadowenv_d = File.join(tmpdir, ".shadowenv.d")
    FileUtils.mkdir_p(shadowenv_d)
    File.write(
      File.join(shadowenv_d, "510_ruby.lisp"),
      ShadowenvRuby.generate_ruby_lisp("/opt/ruby/3.2.0", "3.2.0")
    )

    Expect ".provisioned? returns false when lisp file has different version"
    ShadowenvRuby.provisioned?("4.0.1", project_root: tmpdir) == false

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "provisioned? returns false when .shadowenv.d does not exist" do
    Given "a project root without .shadowenv.d"
    tmpdir = Dir.mktmpdir("shadowenv-test-")

    Expect ".provisioned? returns false when .shadowenv.d does not exist"
    result = ShadowenvRuby.provisioned?("4.0.1", project_root: tmpdir) == false

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  # --- gem_api_version ---

  test "gem_api_version returns #{expected} for #{version}" do
    Given "a ruby version string"
    result = ShadowenvRuby.gem_api_version(version)

    Expect "the correct format is returned"
    result == expected

    Where
    version  | expected
    "4.0.1"  | "4.0.0"
    "3.2.5"  | "3.2.0"
    "2.7.0"  | "2.7.0"
    "3.3.10" | "3.3.0"
  end

  # --- generate_ruby_lisp ---

  test "generate_ruby_lisp contains provide directive with version" do
    When "we generate lisp"
    result = ShadowenvRuby.generate_ruby_lisp("/opt/ruby/4.0.1", "4.0.1")

    Then "the provide directive is present"
    assert_includes result, '(provide "ruby" "4.0.1")'
  end

  test "generate_ruby_lisp sets RUBY_ROOT" do
    When "we generate lisp"
    result = ShadowenvRuby.generate_ruby_lisp("/opt/ruby/4.0.1", "4.0.1")

    Then "RUBY_ROOT is set"
    assert_includes result, '(env/set "RUBY_ROOT" "/opt/ruby/4.0.1")'
  end

  test "generate_ruby_lisp prepends ruby bin to PATH" do
    When "we generate lisp"
    result = ShadowenvRuby.generate_ruby_lisp("/opt/ruby/4.0.1", "4.0.1")

    Then "PATH includes ruby bin"
    assert_includes result, '(env/prepend-to-pathlist "PATH" "/opt/ruby/4.0.1/bin")'
  end

  test "generate_ruby_lisp sets RUBY_VERSION env var" do
    When "we generate lisp"
    result = ShadowenvRuby.generate_ruby_lisp("/opt/ruby/4.0.1", "4.0.1")

    Then "RUBY_VERSION is set"
    assert_includes result, '(env/set "RUBY_VERSION" "4.0.1")'
  end

  # --- ensure_shadowenv_shell_hook! ---

  test "ensure_shadowenv_shell_hook! adds hook to zshrc when not present" do
    Given "a zsh shell with no .zshrc"
    tmpdir = Dir.mktmpdir("shadowenv-hook-test-")
    original_shell = ENV["SHELL"]
    original_home = ENV["HOME"]
    ENV["SHELL"] = "/bin/zsh"
    ENV["HOME"] = tmpdir

    When "we ensure the shell hook"
    result = ShadowenvRuby.ensure_shadowenv_shell_hook!

    Then "the hook is added to .zshrc"
    result == :added
    zshrc = File.read(File.join(tmpdir, ".zshrc"))
    assert_includes zshrc, 'eval "$(shadowenv init zsh)"'

    Cleanup
    ENV["SHELL"] = original_shell
    ENV["HOME"] = original_home
    FileUtils.rm_rf(tmpdir)
  end

  test "ensure_shadowenv_shell_hook! returns :already_present when hook exists" do
    Given "a zsh shell with existing shadowenv hook in .zshrc"
    tmpdir = Dir.mktmpdir("shadowenv-hook-test-")
    original_shell = ENV["SHELL"]
    original_home = ENV["HOME"]
    ENV["SHELL"] = "/bin/zsh"
    ENV["HOME"] = tmpdir
    File.write(File.join(tmpdir, ".zshrc"), 'eval "$(shadowenv init zsh)"')

    When "we ensure the shell hook"
    result = ShadowenvRuby.ensure_shadowenv_shell_hook!

    Then "it reports already present"
    result == :already_present

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
    result = ShadowenvRuby.ensure_shadowenv_shell_hook!

    Then "the old install is recognized, not re-appended"
    result == :already_present
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
    result = ShadowenvRuby.ensure_shadowenv_shell_hook!

    Then "the hook is added to .bash_profile"
    result == :added
    bash_profile = File.read(File.join(tmpdir, ".bash_profile"))
    assert_includes bash_profile, 'eval "$(shadowenv init bash)"'

    Cleanup
    ENV["SHELL"] = original_shell
    ENV["HOME"] = original_home
    FileUtils.rm_rf(tmpdir)
  end

  # --- missing_extensions / extensions_ok? ---

  test "missing_extensions reports every required extension when the ruby binary is absent" do
    Given "a ruby_root with no bin/ruby"
    tmpdir = Dir.mktmpdir("shadowenv-ext-test-")

    Expect "all required extensions are reported missing"
    ShadowenvRuby.missing_extensions(tmpdir) == ShadowenvRuby::REQUIRED_EXTENSIONS

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "missing_extensions is empty for a healthy ruby" do
    Given "a ruby_root whose bin/ruby is the (healthy) test runner ruby"
    tmpdir = Dir.mktmpdir("shadowenv-ext-test-")
    bin = File.join(tmpdir, "bin")
    FileUtils.mkdir_p(bin)
    FileUtils.ln_s(RbConfig.ruby, File.join(bin, "ruby"))

    Expect "nothing is missing — the running ruby has zlib/openssl/psych"
    ShadowenvRuby.missing_extensions(tmpdir).empty? == true

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  test "missing_extensions reports all when bin/ruby cannot load extensions" do
    Given "a ruby_root whose bin/ruby always fails to require"
    tmpdir = Dir.mktmpdir("shadowenv-ext-test-")
    bin = File.join(tmpdir, "bin")
    FileUtils.mkdir_p(bin)
    fake_ruby = File.join(bin, "ruby")
    File.write(fake_ruby, "#!/bin/sh\nexit 1\n")
    FileUtils.chmod(0o755, fake_ruby)

    Expect "every required extension is reported missing"
    ShadowenvRuby.missing_extensions(tmpdir) == ShadowenvRuby::REQUIRED_EXTENSIONS

    Cleanup
    FileUtils.rm_rf(tmpdir)
  end

  # --- ruby_build_env ---

  test "ruby_build_env returns the env unchanged when Homebrew is absent" do
    Given "a base install env and no Homebrew"
    base_env = { "PATH" => "/usr/bin" }

    When "we build the ruby-build env"
    result = ShadowenvRuby.ruby_build_env(base_env)

    Then "the env is returned unchanged"
    _ * ShadowenvRuby.homebrew_prefix >> nil
    result == base_env
  end

  test "ruby_build_env points ruby-build at the brew libraries when Homebrew is present" do
    Given "a base install env and a Homebrew prefix"
    tmp_prefix = Dir.mktmpdir("brew-prefix-")
    base_env = { "PATH" => "/usr/bin" }

    When "we build the ruby-build env"
    result = ShadowenvRuby.ruby_build_env(base_env)

    Then "configure opts and compiler/pkg-config flags point at brew"
    _ * ShadowenvRuby.homebrew_prefix >> tmp_prefix
    _ * ShadowenvRuby.brew_prefix_for(anything) >> "/brew/opt/zlib"
    assert_includes result["RUBY_CONFIGURE_OPTS"], "--with-zlib-dir=/brew/opt/zlib"
    assert_includes result["CPPFLAGS"], "-I#{File.join(tmp_prefix, "include")}"
    assert_includes result["LDFLAGS"], "-L#{File.join(tmp_prefix, "lib")}"
    assert_includes result["LDFLAGS"], "-Wl,-rpath,#{File.join(tmp_prefix, "lib")}"
    assert_includes result["PKG_CONFIG_PATH"], File.join(tmp_prefix, "lib", "pkgconfig")

    Cleanup
    FileUtils.rm_rf(tmp_prefix)
  end
end
