# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/global_catalog"
require "open3"
require "tmpdir"

# bin/dev opens with an `unset` of the caller's bundler-activation env
# (dev#94): a harness running under `bundle exec` leaks RUBYOPT/BUNDLE_*
# into every child, and the Ruby interpreter acts on RUBYOPT before the
# script's first line — so the defense lives in the sh layer, and only
# spawning the real shim can exercise it. Scrub tests, one property each:
#
# 1. dev still boots when the caller's env is hostile (the bug's symptom).
# 2. The shim hands Ruby an env with every scrub key removed (the fix,
#    key by key).
# 3. The scrub list keeps up with bundler: whatever the locked bundler
#    exports must be on it (the drift over time).
#
# The shim is also the one place the full argv routing (global dispatch,
# then Runner) is wired together, so its end-to-end routing behavior —
# help outside a project — is exercised here too.
transform!(RSpock::AST::Transformation)
class Dev::BinDevTest < Minitest::Test
  DEV_ROOT = File.expand_path("../..", __dir__)
  BIN_DEV = File.join(DEV_ROOT, "bin", "dev")

  # The scrub list, parsed from the shim's `unset` line (joining its
  # backslash continuations). The sh script is the single source of truth
  # — the scrub must run before any Ruby exists, so the list cannot live
  # in a Ruby constant; tests alias it by parsing rather than keeping a
  # copy that could drift.
  SHIM_UNSET_KEYS = File.read(BIN_DEV)[/^unset ((?:\\\n|[^\n])*)/, 1].gsub("\\\n", " ").split.freeze

  # These tests spawn the real `bin/dev`, which builds every builtin on
  # its platform defaults and inherits this process's env: the host-probe
  # kill-switch is lifted so the child reads its host, as a user's would.
  # What is asserted here (boot, usage, exit codes) is the same on every
  # host.
  def setup
    super
    @host_probes = allow_host_probes
  end

  def teardown
    restore_host_probe_guard(@host_probes)
    super
  end

  test "a hostile bundler env cannot stop dev from booting" do
    Given "a directory with no dev.yml, and the env a bundle-exec harness leaks (ai-flow#44)"
    dir = Dir.mktmpdir("dev-bin-test-")
    hostile = {
      "RUBYOPT" => "-rbundler/setup",
      "BUNDLE_GEMFILE" => "/nonexistent/harness/Gemfile",
    }

    # A project command with no global/no-project fallback: `up` outside a
    # project converges the host layer (a real host mutation via brew), so
    # it can never be spawned from tests.
    When "running a project command (bare dev renders the global usage instead) there"
    _out, err, status = Open3.capture3(hostile, "sh", BIN_DEV, "test", chdir: dir)

    Then "dev reached its own no-dev.yml refusal — not a crash inside the caller's bundler"
    !status.success?
    err.include?("no dev.yml found")
    !err.include?("bundler")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  # The formula vendors dev's runtime gems into libexec and installs the
  # tree as libexec/dev/{bin,lib}. The Ruby half finds them by
  # position (libexec/specifications beside its root), never by env — so
  # the env dev was started in, hostile or not, neither helps nor hurts,
  # and nothing is exported for children to inherit.
  test "installed under a brew-style libexec, dev resolves its vendored gems in-process — the env has no say" do
    Given "a libexec holding the two vendored gems and dev's tree, and a gem env pointing at nothing"
    dir = Dir.mktmpdir("dev-bin-test-")
    libexec = build_libexec(dir)
    no_gems = File.join(dir, "no-gems")
    FileUtils.mkdir_p(no_gems)

    When "running the installed shim for the version"
    out, err, status = Open3.capture3(no_gems_env(no_gems), "sh", File.join(libexec, "dev", "bin", "dev"), "--version", chdir: dir)

    Then "dev booted on its vendored gems and answered"
    status.success?
    out.strip == File.read(File.join(DEV_ROOT, "VERSION")).strip
    err.empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  # Selecting the vendored gems must not hide the Ruby's own: since Ruby
  # 4, reline (and readline on top of it) are *bundled* gems — installed
  # in the Ruby's gem dir, not resolvable from its default-gem specs the
  # way json or open3 are. CLI::UI::Prompt requires them, and UiImpl loads
  # it on every tty or CI run. A Gem.path of exactly [libexec] shipped in
  # 0.6.6 and broke every interactive `dev` — the vendored dir goes in
  # front of the caller's gem path, never instead of it.
  test "installed under a libexec, a CI run outside a project still reaches the Ruby's bundled gems through CLI::UI" do
    Given "a libexec holding the vendored gems and dev's tree, the caller's ordinary gem env, and CI set so the real UI loads"
    dir = Dir.mktmpdir("dev-bin-test-")
    libexec = build_libexec(dir)
    env = { "CI" => "1", "PATH" => "#{File.dirname(RbConfig.ruby)}:#{ENV.fetch("PATH")}" }

    When "running the installed shim bare, from a directory that is not a project"
    out, err, status = Open3.capture3(env, "sh", File.join(libexec, "dev", "bin", "dev"), chdir: dir)

    Then "the UI came up (reline found beside the Ruby) and dev answered as it does outside a project"
    status.success?
    out.include?("outside a project")
    !err.include?("LoadError")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  # The Ruby's default gem path is wider than the Ruby: RubyGems puts the
  # user's ~/.gem/ruby/X.Y.0 first, and a brew Ruby adds the prefix-wide
  # dir shared by every brew Ruby. Both are written by other interpreters
  # and can hold a native extension linked against another libruby at the
  # same version as this Ruby's own — which is what reline's io-console
  # dependency resolved to on the Mac runner. An installed dev's gem path
  # is its vendored gems plus the running Ruby's own dir, nothing from the
  # environment, so such a user dir is never consulted.
  test "installed under a libexec, a CI run never consults the user's gem dir — an io-console planted there, newer than the Ruby's, is not loaded" do
    Given "a libexec with the vendored gems, no GEM_HOME/GEM_PATH, and a HOME whose user gem dir holds an io-console that raises on load"
    dir = Dir.mktmpdir("dev-bin-test-")
    libexec = build_libexec(dir)
    home = File.join(dir, "home")
    plant_poisoned_user_gem(home, "io-console")
    env = {
      "CI" => "1", "HOME" => home, "GEM_HOME" => nil, "GEM_PATH" => nil,
      "PATH" => "#{File.dirname(RbConfig.ruby)}:#{ENV.fetch("PATH")}",
    }

    When "running the installed shim bare, from a directory that is not a project"
    out, err, status = Open3.capture3(env, "sh", File.join(libexec, "dev", "bin", "dev"), chdir: dir)

    Then "the UI came up on the Ruby's own io-console and dev answered"
    status.success?
    out.include?("outside a project")
    !err.include?(POISONED_GEM_MESSAGE)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "from a source checkout, with nothing vendored beside it, the shell's gem env governs as before" do
    Given "the repo's own shim, and a gem env pointing at nothing"
    dir = Dir.mktmpdir("dev-bin-test-")
    no_gems = File.join(dir, "no-gems")
    FileUtils.mkdir_p(no_gems)

    When "running the source shim"
    _out, err, status = Open3.capture3(no_gems_env(no_gems), "sh", BIN_DEV, "--version", chdir: dir)

    Then "it is the env's gems dev looks for — and finds none"
    !status.success?
    err.include?("sorbet-runtime")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "bare dev and dev --help outside a project print the projectless usage and exit 0" do
    Given "a directory with no dev.yml anywhere above it"
    dir = Dir.mktmpdir("dev-bin-test-")

    When "running bin/dev bare and with --help there"
    bare_out, _bare_err, bare_status = Open3.capture3("sh", BIN_DEV, chdir: dir)
    help_out, _help_err, help_status = Open3.capture3("sh", BIN_DEV, "--help", chdir: dir)

    Then "both succeed with the projectless listing (global commands included) and the project hint"
    bare_status.success?
    help_status.success?
    bare_out.include?("Commands available outside a project")
    bare_out.include?("Run dev inside a project that defines a dev.yml to see its commands.")
    Dev::Cli::GlobalCatalog.new.commands.keys.all? { |name| bare_out.include?(name) }
    help_out == bare_out

    Cleanup
    FileUtils.rm_rf(dir)
  end

  # The bug behind #217: `dev plan new --help` created an issue titled
  # "help". The flag is global dispatch's to decline and the Runner's to
  # answer, and only the shim wires the two together.
  test "dev plan new --help outside a project prints plan new's usage and exits 0, creating nothing" do
    Given "a directory with no dev.yml anywhere above it, and a gh stub that records being run"
    dir = Dir.mktmpdir("dev-bin-test-")
    env = { "PATH" => "#{write_stub_gh(dir)}:#{ENV.fetch("PATH")}" }

    When "asking a global leaf for help, with a title in the way"
    out, _err, status = Open3.capture3(env, "sh", BIN_DEV, "plan", "new", "Carve system", "--help", chdir: dir)

    Then "the leaf's usage, and gh was never reached"
    status.success?
    out.include?("Usage: dev plan new <title>")
    out.include?("Create a templated issue")
    !File.exist?(gh_marker(dir))

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "dev plan new --hlep outside a project is a usage error: exit 2 with the usage on stderr" do
    Given "a directory with no dev.yml anywhere above it, and a gh stub that records being run"
    dir = Dir.mktmpdir("dev-bin-test-")
    env = { "PATH" => "#{write_stub_gh(dir)}:#{ENV.fetch("PATH")}" }

    When "typo'ing the help flag"
    out, err, status = Open3.capture3(env, "sh", BIN_DEV, "plan", "new", "--hlep", chdir: dir)

    Then "the flag is refused before the verb runs"
    status.exitstatus == 2
    err.include?("dev: unknown flag '--hlep' for 'dev plan new'")
    err.include?("Usage: dev plan new <title>")
    out.empty?
    !File.exist?(gh_marker(dir))

    Cleanup
    FileUtils.rm_rf(dir)
  end

  # --- inside dev's own checkout, dev is the checkout (dev#689) ------------
  #
  # The installed dev predates every grammar change the checkout makes to
  # its own dev.yml, so once the checkout's lock is installed the installed
  # shim hands every verb to the checkout's bin/dev, under the checkout's
  # shadowenv; until then (`dev up` is what installs it) it runs itself.
  # The sh half is the only place the rule can live — it must run before
  # any Ruby of the installed dev reads the dev.yml — so these tests spawn
  # the real shim over a synthetic checkout, with a shadowenv stub that
  # records what it was asked to run and then runs it: the handoff and the
  # probe are the shim's; the activation they ride on is shadowenv's own.

  test "inside dev's own checkout with its lock installed, the installed shim hands off to the checkout's bin/dev under the checkout's shadowenv — from any directory within" do
    Given "a checkout that is dev (name: dev, bin/dev, lib/dev.rb) with a lock bundle check satisfies, and a shadowenv stub"
    dir = Dir.mktmpdir("dev-bin-test-")
    checkout = build_dev_checkout(dir, lock_installed: true)
    env = { "PATH" => "#{write_stub_shadowenv(dir)}:#{File.dirname(RbConfig.ruby)}:#{ENV.fetch("PATH")}" }

    When "running the repo's shim, standing in for the installed one, from a subdirectory of the checkout"
    out, err, status = Open3.capture3(env, "sh", BIN_DEV, "--version", chdir: File.join(checkout, "lib"))

    Then "the checkout's bin/dev answered with the argv unchanged, reached through `shadowenv exec --dir <checkout>` after the probe"
    status.success?
    out == "checkout-dev --version\n"
    err.empty?
    shadowenv_calls(dir) == [
      "exec -- bundle check --dry-run",
      "exec --dir #{checkout} -- #{checkout}/bin/dev --version",
    ]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "inside dev's own checkout with its lock not yet installed, the installed shim runs itself: that is what `dev up` is for" do
    Given "a checkout that is dev whose lock names a gem not installed anywhere"
    dir = Dir.mktmpdir("dev-bin-test-")
    checkout = build_dev_checkout(dir, lock_installed: false)
    env = { "PATH" => "#{write_stub_shadowenv(dir)}:#{File.dirname(RbConfig.ruby)}:#{ENV.fetch("PATH")}" }

    When "running the repo's shim there"
    out, _err, status = Open3.capture3(env, "sh", BIN_DEV, "--version", chdir: checkout)

    Then "the probe failed and the installed dev answered for itself"
    status.success?
    out.strip == File.read(File.join(DEV_ROOT, "VERSION")).strip
    shadowenv_calls(dir) == ["exec -- bundle check --dry-run"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the checkout's own bin/dev never hands off to itself" do
    Given "a checkout that is dev, provisioned, whose bin/dev is the real shim over the repo's lib and VERSION"
    dir = Dir.mktmpdir("dev-bin-test-")
    checkout = build_dev_checkout(dir, lock_installed: true, shim: :real)
    env = { "PATH" => "#{write_stub_shadowenv(dir)}:#{File.dirname(RbConfig.ruby)}:#{ENV.fetch("PATH")}" }

    When "running the checkout's own shim"
    out, _err, status = Open3.capture3(env, "sh", File.join(checkout, "bin", "dev"), "--version", chdir: checkout)

    Then "it answered itself — no probe, no exec: the rule is for the installed dev"
    status.success?
    out.strip == File.read(File.join(DEV_ROOT, "VERSION")).strip
    shadowenv_calls(dir) == []

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a project that is not dev's checkout never hands off: #{missing}" do
    Given "a provisioned checkout that is dev in all but one of the three facts"
    dir = Dir.mktmpdir("dev-bin-test-")
    checkout = build_dev_checkout(dir, lock_installed: true)
    unmake.call(checkout)
    env = { "PATH" => "#{write_stub_shadowenv(dir)}:#{File.dirname(RbConfig.ruby)}:#{ENV.fetch("PATH")}" }

    When "running the repo's shim there"
    out, _err, status = Open3.capture3(env, "sh", BIN_DEV, "--version", chdir: checkout)

    Then "the installed dev answered for itself without probing"
    status.success?
    out.strip == File.read(File.join(DEV_ROOT, "VERSION")).strip
    shadowenv_calls(dir) == []

    Cleanup
    FileUtils.rm_rf(dir)

    Where
    missing                         | unmake
    "dev.yml names another project" | ->(root) { File.write(File.join(root, "dev.yml"), "name: devtools\n") }
    "no bin/dev"                    | ->(root) { File.delete(File.join(root, "bin", "dev")) }
    "no lib/dev.rb"                 | ->(root) { File.delete(File.join(root, "lib", "dev.rb")) }
  end

  test "the shim removes every scrub key from the env it hands to ruby" do
    Given "every scrub key planted hostile, and a stub ruby that prints the env it receives"
    dir = Dir.mktmpdir("dev-bin-test-")
    hostile = SHIM_UNSET_KEYS.to_h { |key| [key, "/hostile/#{key}"] }
    env = hostile.merge("PATH" => "#{write_stub_ruby(dir)}:#{ENV.fetch("PATH")}")

    When "running the shim"
    out, _err, status = Open3.capture3(env, "sh", BIN_DEV, chdir: dir)

    Then "no scrub key survives into the ruby process"
    status.success?
    (env_names(out) & SHIM_UNSET_KEYS).empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  # The scrub list is a denylist of what `bundle exec` exports, and that
  # set grows across bundler versions — a new exported key would silently
  # re-open the leak. The live truth comes from the locked bundler itself:
  # a child launched under `bundle exec` reports every key its activation
  # exported (its ENV vs its Bundler.original_env). The launch is
  # constructed here — the parent's own activation keys are removed first
  # — because the suite's inherited env is whatever shell started it (an
  # agent harness, an IDE) and proves nothing about the locked bundler.
  # Subset direction only: keys the shim lists but this activation didn't
  # export (config-dependent ones like BUNDLE_PATH) are free no-ops, so
  # exact equality would only add flake.
  test "the scrub list covers every key the locked bundler exports" do
    Given "a child activated by the repo's bundle exec, from a base env with no prior activation"
    # nil values unset the keys; BUNDLE_GEMFILE especially must be absent,
    # or bundle exec's BUNDLER_ORIG_* record hides it from the diff.
    fresh_env = ENV.keys.grep(/\A(?:BUNDLE_|BUNDLER_|RUBYOPT\z|RUBYLIB\z)/).to_h { |key| [key, nil] }
    report_exported = 'puts((ENV.keys | Bundler.original_env.keys)' \
      ".select { |key| ENV[key] != Bundler.original_env[key] })"
    out, _err, status = Open3.capture3(fresh_env, "bundle", "exec", "ruby", "-e", report_exported, chdir: DEV_ROOT)
    # In scope: bundler/ruby activation keys. Out of scope: BUNDLER_ORIG_*
    # (bundler's inert restore records) and GEM_* (legitimate user config,
    # per dev#94).
    exported = out.split("\n").grep(/\A(?:BUNDLE_|BUNDLER_(?!ORIG_)|RUBYOPT\z|RUBYLIB\z)/)

    Expect "a fresh activation that exported the Gemfile pin, fully covered by the scrub list"
    status.success?
    exported.include?("BUNDLE_GEMFILE")
    (exported - SHIM_UNSET_KEYS).empty?
  end

  # A PATH-front stub standing in for ruby: the shim's version probe
  # (`ruby -e ...`) passes, and the real launch (`ruby -x bin/dev`) prints
  # the received env instead of running dev — so the assertion sees the
  # exact hand-off env without dev's Ruby machinery (or provisioning)
  # getting involved. Returns the bin dir to prepend to PATH.
  def write_stub_ruby(dir)
    stub_bin = File.join(dir, "bin")
    FileUtils.mkdir_p(stub_bin)
    File.write(File.join(stub_bin, "ruby"), <<~SH)
      #!/bin/sh
      case "$1" in
        -e) exit 0 ;;
        *) env ;;
      esac
    SH
    FileUtils.chmod(0o755, File.join(stub_bin, "ruby"))
    stub_bin
  end

  # A checkout the shim's rule recognises as dev itself: `dev.yml` saying
  # `name: dev`, `bin/dev`, `lib/dev.rb` — and the state the probe reads, a
  # `.shadowenv.d` and a Gemfile with its lock. Installed means the lock
  # names nothing (`bundle check` is satisfied by any Ruby, offline); not
  # installed means it names a gem no machine has, which `bundle check`
  # refuses from the lock alone, offline. The checkout's `bin/dev` is a
  # stub that prints its name and argv — the handoff's proof — or, for the
  # loop test, a copy of the real shim over the repo's lib and VERSION.
  # Returns the checkout's path.
  def build_dev_checkout(dir, lock_installed:, shim: :stub)
    checkout = File.join(dir, "checkout")
    FileUtils.mkdir_p([File.join(checkout, "bin"), File.join(checkout, "lib"), File.join(checkout, ".shadowenv.d")])
    File.write(File.join(checkout, "dev.yml"), "name: dev\ncommands:\n  test:\n    run: ./bin/test.rb\n")
    File.write(File.join(checkout, "Gemfile"), lock_installed ? "source \"https://rubygems.org\"\n" : <<~GEMFILE)
      source "https://rubygems.org"
      gem "dev-bin-test-missing-gem"
    GEMFILE
    File.write(File.join(checkout, "Gemfile.lock"), lock_installed ? <<~INSTALLED : <<~MISSING)
      GEM
        remote: https://rubygems.org/
        specs:

      PLATFORMS
        ruby

      DEPENDENCIES
    INSTALLED
      GEM
        remote: https://rubygems.org/
        specs:
          dev-bin-test-missing-gem (99.0.0)

      PLATFORMS
        ruby

      DEPENDENCIES
        dev-bin-test-missing-gem
    MISSING
    case shim
    when :stub
      File.write(File.join(checkout, "lib", "dev.rb"), "")
      File.write(File.join(checkout, "bin", "dev"), "#!/bin/sh\necho \"checkout-dev $*\"\n")
      FileUtils.chmod(0o755, File.join(checkout, "bin", "dev"))
    when :real
      FileUtils.cp(BIN_DEV, File.join(checkout, "bin", "dev"))
      FileUtils.rm_rf(File.join(checkout, "lib"))
      %w[lib VERSION].each { |entry| File.symlink(File.join(DEV_ROOT, entry), File.join(checkout, entry)) }
    end
    checkout
  end

  # A PATH-front stub standing in for shadowenv: records every invocation
  # (its argv, one line each) and runs the command after `--` as given,
  # applying no environment — the shim's rule is what is under test, not
  # the activation it rides on. Returns the bin dir to prepend to PATH.
  def write_stub_shadowenv(dir)
    stub_bin = File.join(dir, "stub-bin")
    FileUtils.mkdir_p(stub_bin)
    File.write(File.join(stub_bin, "shadowenv"), <<~SH)
      #!/bin/sh
      printf '%s\\n' "$*" >> "#{shadowenv_log(dir)}"
      while [ $# -gt 0 ]; do
        case "$1" in
          --) shift; break ;;
          *) shift ;;
        esac
      done
      exec "$@"
    SH
    FileUtils.chmod(0o755, File.join(stub_bin, "shadowenv"))
    stub_bin
  end

  # Where the shadowenv stub records its invocations.
  def shadowenv_log(dir)
    File.join(dir, "shadowenv-calls")
  end

  # The shadowenv stub's recorded invocations, in order; none when it never ran.
  def shadowenv_calls(dir)
    File.exist?(shadowenv_log(dir)) ? File.read(shadowenv_log(dir)).lines.map(&:chomp) : []
  end

  # A PATH-front stub standing in for gh: were the help flag ever to fall
  # through to the verb, the issue creation would hit this stub — which
  # leaves a marker and fails — instead of reaching GitHub. Prepending
  # (rather than removing gh's directory from PATH) keeps `sh` and friends
  # reachable where gh shares their directory, as on Linux CI runners.
  # Returns the bin dir to prepend to PATH.
  def write_stub_gh(dir)
    stub_bin = File.join(dir, "bin")
    FileUtils.mkdir_p(stub_bin)
    File.write(File.join(stub_bin, "gh"), <<~SH)
      #!/bin/sh
      : > "#{gh_marker(dir)}"
      exit 1
    SH
    FileUtils.chmod(0o755, File.join(stub_bin, "gh"))
    stub_bin
  end

  # Where the gh stub records that it ran.
  def gh_marker(dir)
    File.join(dir, "gh-was-run")
  end

  # The formula's layout in miniature: libexec/{specifications,gems} holding
  # the two runtime gems the formula vendors (linked from wherever this
  # suite's Ruby has them — RubyGems follows links), and libexec/dev with a
  # copy of the shim (a copy, as brew installs: realpath must resolve
  # inside the layout) beside links to the repo's lib and VERSION.
  # Returns the libexec path.
  def build_libexec(dir)
    libexec = File.join(dir, "libexec")
    FileUtils.mkdir_p([File.join(libexec, "specifications"), File.join(libexec, "gems"), File.join(libexec, "dev", "bin")])
    %w[sorbet-runtime cli-ui].each do |name|
      spec = Gem::Specification.find_by_name(name)
      File.symlink(spec.spec_file, File.join(libexec, "specifications", File.basename(spec.spec_file)))
      File.symlink(spec.gem_dir, File.join(libexec, "gems", File.basename(spec.gem_dir)))
    end
    FileUtils.cp(BIN_DEV, File.join(libexec, "dev", "bin", "dev"))
    %w[lib VERSION].each { |entry| File.symlink(File.join(DEV_ROOT, entry), File.join(libexec, "dev", entry)) }
    libexec
  end

  POISONED_GEM_MESSAGE = "poisoned gem loaded from the user gem dir"
  POISONED_GEM_VERSION = "0.99.0"

  # A gem in the user gem dir under `home` (~/.gem/ruby/X.Y.0, what
  # RubyGems puts first on a Ruby's default path) whose entry file raises.
  # Its version is above any the Ruby ships and inside reline's `~> 0.5`
  # on io-console, so RubyGems must pick it over the Ruby's own copy
  # wherever that dir is on the path — loading it is the proof the dir was
  # consulted.
  def plant_poisoned_user_gem(home, name)
    gem_dir = File.join(home, ".gem", "ruby", RbConfig::CONFIG["ruby_version"])
    full_name = "#{name}-#{POISONED_GEM_VERSION}"
    lib = File.join(gem_dir, "gems", full_name, "lib", *name.split("-")[0..-2])
    FileUtils.mkdir_p([File.join(gem_dir, "specifications"), lib])
    File.write(File.join(lib, "#{name.split("-").last}.rb"), "raise LoadError, #{POISONED_GEM_MESSAGE.inspect}\n")
    spec = Gem::Specification.new do |s|
      s.name = name
      s.version = POISONED_GEM_VERSION
      s.summary = "poisoned"
      s.authors = ["bin_dev_test"]
      s.require_paths = ["lib"]
    end
    File.write(File.join(gem_dir, "specifications", "#{full_name}.gemspec"), spec.to_ruby)
  end

  # A gem env that resolves nothing, with the suite's own Ruby first on
  # PATH so the shim's probe picks it deterministically. The suite runs
  # under bundler; the shim's sh layer strips that activation itself, which
  # is why these tests go through `sh`, not `ruby -x`. The Ui tier is
  # pinned plain: a terminal's (or CI's) tier loads CLI::UI::Prompt, whose
  # reline is the Ruby's bundled gem, reached through Gem.path — not a
  # vendored gem, and not what this env is about.
  def no_gems_env(no_gems)
    {
      "GEM_HOME" => no_gems, "GEM_PATH" => no_gems, "PATH" => "#{File.dirname(RbConfig.ruby)}:#{ENV.fetch("PATH")}",
      "CI" => nil, "CLICOLOR_FORCE" => nil,
    }
  end

  # Variable names from `env` output — whole names, because the suite's
  # own BUNDLER_ORIG_* records contain scrub keys as substrings.
  def env_names(env_output)
    env_output.lines.map { |line| line.split("=", 2).first }
  end
end
