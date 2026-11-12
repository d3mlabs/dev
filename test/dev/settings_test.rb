# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/settings"
require "tmpdir"
require "fileutils"

transform!(RSpock::AST::Transformation)
class Dev::SettingsTest < Minitest::Test
  # Build Settings with hermetic layer paths: both files live in the temp
  # dir, so the machine's real user/system config never leaks into a test.
  def build_settings(dir)
    Dev::Settings.new(
      config_path: File.join(dir, "user", "config.yml"),
      system_config_path: File.join(dir, "system", "config.yml"),
    )
  end

  def write_user(dir, content)
    path = File.join(dir, "user", "config.yml")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def write_system(dir, content)
    path = File.join(dir, "system", "config.yml")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  test "plans_repo reads from the user config file" do
    Given "a user config file declaring the org plans repo"
    dir = Dir.mktmpdir("dev-settings-test-")
    write_user(dir, "plans_repo: d3mlabs/plans\n")
    settings = build_settings(dir)

    Expect
    settings.plans_repo == "d3mlabs/plans"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "DEV_PLANS_REPO overrides the config file" do
    Given "a config file and an ENV override"
    dir = Dir.mktmpdir("dev-settings-test-")
    write_user(dir, "plans_repo: d3mlabs/plans\n")
    ENV["DEV_PLANS_REPO"] = "acme/plans"
    settings = build_settings(dir)

    Expect
    settings.plans_repo == "acme/plans"

    Cleanup
    ENV.delete("DEV_PLANS_REPO")
    FileUtils.rm_rf(dir)
  end

  test "an unset plans_repo raises with instructions" do
    Given "no config file in either layer"
    dir = Dir.mktmpdir("dev-settings-test-")
    settings = build_settings(dir)

    When "reading the plans repo"
    settings.plans_repo

    Then
    raises Dev::Settings::MissingSettingError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a key falls through to the system config file" do
    Given "only the system layer (an org deployment's file) declares the key"
    dir = Dir.mktmpdir("dev-settings-test-")
    write_system(dir, "plans_repo: d3mlabs/plans\n")
    settings = build_settings(dir)

    Expect
    settings.plans_repo == "d3mlabs/plans"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the user file wins over the system file per key, gitconfig-style" do
    Given "both layers set plans_repo, and only the system layer sets knowledge_repo"
    dir = Dir.mktmpdir("dev-settings-test-")
    write_system(dir, "plans_repo: d3mlabs/plans\nknowledge_repo: d3mlabs/knowledge\n")
    write_user(dir, "plans_repo: personal/plans\n")
    saved_env = ENV.delete("DEV_KNOWLEDGE_REPO")
    settings = build_settings(dir)

    Expect "the user's plans_repo wins while the system knowledge_repo still applies"
    settings.plans_repo == "personal/plans"
    settings.knowledge_repo == "d3mlabs/knowledge"

    Cleanup
    ENV["DEV_KNOWLEDGE_REPO"] = saved_env if saved_env
    FileUtils.rm_rf(dir)
  end

  test "knowledge_repo reads from the config file" do
    Given "a config file declaring the org knowledge repo"
    dir = Dir.mktmpdir("dev-settings-test-")
    write_user(dir, "knowledge_repo: d3mlabs/knowledge\n")
    saved_env = ENV.delete("DEV_KNOWLEDGE_REPO")
    settings = build_settings(dir)

    Expect
    settings.knowledge_repo == "d3mlabs/knowledge"

    Cleanup
    ENV["DEV_KNOWLEDGE_REPO"] = saved_env if saved_env
    FileUtils.rm_rf(dir)
  end

  test "DEV_KNOWLEDGE_REPO overrides the config file" do
    Given "a config file and an ENV override"
    dir = Dir.mktmpdir("dev-settings-test-")
    write_user(dir, "knowledge_repo: d3mlabs/knowledge\n")
    saved_env = ENV["DEV_KNOWLEDGE_REPO"]
    ENV["DEV_KNOWLEDGE_REPO"] = "acme/knowledge"
    settings = build_settings(dir)

    Expect
    settings.knowledge_repo == "acme/knowledge"

    Cleanup
    saved_env ? ENV["DEV_KNOWLEDGE_REPO"] = saved_env : ENV.delete("DEV_KNOWLEDGE_REPO")
    FileUtils.rm_rf(dir)
  end

  test "an unset knowledge_repo is nil — no org sync is a supported state" do
    Given "no config file"
    dir = Dir.mktmpdir("dev-settings-test-")
    saved_env = ENV.delete("DEV_KNOWLEDGE_REPO")
    settings = build_settings(dir)

    Expect
    settings.knowledge_repo.nil?

    Cleanup
    ENV["DEV_KNOWLEDGE_REPO"] = saved_env if saved_env
    FileUtils.rm_rf(dir)
  end

  test "deployment_formula reads from the system config file (the deployment names itself)" do
    Given "a system config declaring the deployment's own formula"
    dir = Dir.mktmpdir("dev-settings-test-")
    write_system(dir, "deployment_formula: d3mlabs/d3mlabs/dev\n")
    saved_env = ENV.delete("DEV_DEPLOYMENT_FORMULA")
    settings = build_settings(dir)

    Expect
    settings.deployment_formula == "d3mlabs/d3mlabs/dev"

    Cleanup
    ENV["DEV_DEPLOYMENT_FORMULA"] = saved_env if saved_env
    FileUtils.rm_rf(dir)
  end

  test "DEV_DEPLOYMENT_FORMULA overrides the config files" do
    Given "a system config and an ENV override"
    dir = Dir.mktmpdir("dev-settings-test-")
    write_system(dir, "deployment_formula: d3mlabs/d3mlabs/dev\n")
    saved_env = ENV["DEV_DEPLOYMENT_FORMULA"]
    ENV["DEV_DEPLOYMENT_FORMULA"] = "acme/tap/dev"
    settings = build_settings(dir)

    Expect
    settings.deployment_formula == "acme/tap/dev"

    Cleanup
    saved_env ? ENV["DEV_DEPLOYMENT_FORMULA"] = saved_env : ENV.delete("DEV_DEPLOYMENT_FORMULA")
    FileUtils.rm_rf(dir)
  end

  test "an unset deployment_formula is nil — no deployment to self-update is a supported state" do
    Given "no config file"
    dir = Dir.mktmpdir("dev-settings-test-")
    saved_env = ENV.delete("DEV_DEPLOYMENT_FORMULA")
    settings = build_settings(dir)

    Expect
    settings.deployment_formula.nil?

    Cleanup
    ENV["DEV_DEPLOYMENT_FORMULA"] = saved_env if saved_env
    FileUtils.rm_rf(dir)
  end

  test "an empty user value counts as unset per layer — the system value shows through for getter and lookup alike" do
    Given "a user file with an empty plans_repo over a system file with a real one"
    dir = Dir.mktmpdir("dev-settings-test-")
    write_user(dir, 'plans_repo: ""' + "\n")
    write_system(dir, "plans_repo: d3mlabs/plans\n")
    settings = build_settings(dir)

    Expect "the getter and the dev config view agree on the resolved value"
    settings.plans_repo == "d3mlabs/plans"
    settings.lookup("plans_repo") == ["d3mlabs/plans", :system]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "container_engine reads the per-user engine record" do
    Given "a user config naming the invoking user's container engine"
    dir = Dir.mktmpdir("dev-settings-test-")
    write_user(dir, "container_engine: colima\n")
    saved_env = ENV.delete("DEV_CONTAINER_ENGINE")
    settings = build_settings(dir)

    Expect
    settings.container_engine == "colima"

    Cleanup
    ENV["DEV_CONTAINER_ENGINE"] = saved_env if saved_env
    FileUtils.rm_rf(dir)
  end

  test "an unset container_engine is nil — the bare-docker default is a supported state" do
    Given "no config file"
    dir = Dir.mktmpdir("dev-settings-test-")
    saved_env = ENV.delete("DEV_CONTAINER_ENGINE")
    settings = build_settings(dir)

    Expect
    settings.container_engine.nil?

    Cleanup
    ENV["DEV_CONTAINER_ENGINE"] = saved_env if saved_env
    FileUtils.rm_rf(dir)
  end

  test "lifecycle_runner is the standing runner label, set by `dev config set lifecycle.runner`, overridden by DEV_LIFECYCLE_RUNNER" do
    Given "a user config written through set, then an ENV override"
    dir = Dir.mktmpdir("dev-settings-test-")
    saved_env = ENV.delete("DEV_LIFECYCLE_RUNNER")
    settings = build_settings(dir)
    settings.set(Dev::Settings::LIFECYCLE_RUNNER_KEY, "ue-engine-hosted")
    from_file = settings.lifecycle_runner
    ENV["DEV_LIFECYCLE_RUNNER"] = "win64-pool"
    from_env = build_settings(dir).lifecycle_runner

    Expect
    Dev::Settings::LIFECYCLE_RUNNER_KEY == "lifecycle.runner"
    from_file == "ue-engine-hosted"
    from_env == "win64-pool"

    Cleanup
    saved_env ? ENV["DEV_LIFECYCLE_RUNNER"] = saved_env : ENV.delete("DEV_LIFECYCLE_RUNNER")
    FileUtils.rm_rf(dir)
  end

  test "an unset lifecycle_runner is nil — the enrolled runner, or a refusal, decides the remote dispatch" do
    Given "no config file"
    dir = Dir.mktmpdir("dev-settings-test-")
    saved_env = ENV.delete("DEV_LIFECYCLE_RUNNER")
    settings = build_settings(dir)

    Expect
    settings.lifecycle_runner.nil?

    Cleanup
    ENV["DEV_LIFECYCLE_RUNNER"] = saved_env if saved_env
    FileUtils.rm_rf(dir)
  end

  test "engine_resources defaults to enforce and reads the layers like every other key" do
    Given "an engine_resources value in one layer"
    dir = Dir.mktmpdir("dev-settings-test-")
    saved_env = ENV.delete("DEV_ENGINE_RESOURCES")
    write_user(dir, user) if user
    ENV["DEV_ENGINE_RESOURCES"] = env if env
    settings = build_settings(dir)

    Expect
    settings.engine_resources == expected

    Cleanup
    ENV.delete("DEV_ENGINE_RESOURCES")
    ENV["DEV_ENGINE_RESOURCES"] = saved_env if saved_env
    FileUtils.rm_rf(dir)

    Where
    user                        | env    | expected
    nil                         | nil    | "enforce"
    "engine_resources: warn\n"  | nil    | "warn"
    "engine_resources: warn\n"  | "enforce" | "enforce"
    nil                         | "warn" | "warn"
  end

  test "an engine_resources value outside enforce/warn is a typed error naming the layer it came from" do
    Given "a misspelt user value"
    dir = Dir.mktmpdir("dev-settings-test-")
    saved_env = ENV.delete("DEV_ENGINE_RESOURCES")
    write_user(dir, "engine_resources: ignore\n")
    settings = build_settings(dir)

    When "reading it"
    settings.engine_resources

    Then
    error = raises Dev::Settings::InvalidSettingError
    error.message.include?("`ignore`")
    error.message.include?("from user")
    error.message.include?("enforce, warn")

    Cleanup
    ENV["DEV_ENGINE_RESOURCES"] = saved_env if saved_env
    FileUtils.rm_rf(dir)
  end

  test "system_config_path is exposed for the host converge to find the deployment payload" do
    Given "hermetic settings"
    dir = Dir.mktmpdir("dev-settings-test-")
    settings = build_settings(dir)

    Expect
    settings.system_config_path == File.join(dir, "system", "config.yml")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "default_org reads from the user config file" do
    Given "a user config declaring the default GitHub org"
    dir = Dir.mktmpdir("dev-settings-test-")
    write_user(dir, "default_org: d3mlabs\n")
    saved_env = ENV.delete("DEV_DEFAULT_ORG")
    settings = build_settings(dir)

    Expect
    settings.default_org == "d3mlabs"

    Cleanup
    ENV["DEV_DEFAULT_ORG"] = saved_env if saved_env
    FileUtils.rm_rf(dir)
  end

  test "DEV_DEFAULT_ORG overrides the config files" do
    Given "a user config and an ENV override"
    dir = Dir.mktmpdir("dev-settings-test-")
    write_user(dir, "default_org: d3mlabs\n")
    saved_env = ENV["DEV_DEFAULT_ORG"]
    ENV["DEV_DEFAULT_ORG"] = "acme"
    settings = build_settings(dir)

    Expect
    settings.default_org == "acme"

    Cleanup
    saved_env ? ENV["DEV_DEFAULT_ORG"] = saved_env : ENV.delete("DEV_DEFAULT_ORG")
    FileUtils.rm_rf(dir)
  end

  test "an unset default_org is nil — explicit <org>/<repo> targets are a supported state" do
    Given "no config file"
    dir = Dir.mktmpdir("dev-settings-test-")
    saved_env = ENV.delete("DEV_DEFAULT_ORG")
    settings = build_settings(dir)

    Expect
    settings.default_org.nil?

    Cleanup
    ENV["DEV_DEFAULT_ORG"] = saved_env if saved_env
    FileUtils.rm_rf(dir)
  end

  # A brew prefix in a tmp dir: `<prefix>/bin/brew` executable, as a real
  # install leaves it.
  def brew_prefix_in(dir, *segments)
    File.join(dir, *segments).tap do |prefix|
      FileUtils.mkdir_p(File.join(prefix, "bin"))
      File.write(File.join(prefix, "bin", "brew"), "")
      FileUtils.chmod(0o755, File.join(prefix, "bin", "brew"))
    end
  end

  # dev#568: the box's shape — a job without a login shell exports no
  # HOMEBREW_PREFIX, and /usr/local (present on this test host as on every
  # Linux one) is not where brew is. Installed dev runs from a keg, and the
  # keg names its prefix — ahead of any brew the host also has.
  test "with HOMEBREW_PREFIX unset the brew prefix is the one whose Cellar holds dev's keg — by keg path or opt link — ahead of a standard prefix with brew" do
    Given "a Linuxbrew-shaped prefix holding dev's keg and its opt link, another prefix with a brew, and no HOMEBREW_PREFIX"
    dir = Dir.mktmpdir("dev-settings-test-")
    prefix = File.join(dir, "home", "linuxbrew", ".linuxbrew")
    keg = File.join(prefix, "Cellar", "dev-core", "0.8.9")
    other = brew_prefix_in(dir, "usr", "local")
    FileUtils.mkdir_p([File.join(keg, "libexec", "dev", "lib"), File.join(prefix, "opt")])
    File.symlink(File.join("..", "Cellar", "dev-core", "0.8.9"), File.join(prefix, "opt", "dev-core"))
    saved = ENV.delete("HOMEBREW_PREFIX")

    Expect "the prefix dev is installed under, by either path"
    Dev::Settings.brew_prefix(root: File.join(keg, "libexec", "dev"), standard_prefixes: [other]) == File.realpath(prefix)
    Dev::Settings.brew_prefix(root: File.join(prefix, "opt", "dev-core", "libexec", "dev"), standard_prefixes: [other]) == File.realpath(prefix)

    Cleanup
    ENV["HOMEBREW_PREFIX"] = saved if saved
    FileUtils.rm_rf(dir)
  end

  # A source checkout runs from no keg, but the machine's brew is still where
  # the org's system layer lives: a developer in a non-login shell (tmux, a
  # remote editor) must see the same `knowledge_repo` and `deployment_formula`
  # a login shell does. The old probe took the first standard prefix that
  # *existed* — `/usr/local` on every Linux host; the fact that places brew
  # is `<prefix>/bin/brew`.
  test "a source checkout resolves the standard prefix holding bin/brew — not one merely present — and nil when none does" do
    Given "a checkout, a present-but-brewless /usr/local, a /opt/homebrew with brew, and no HOMEBREW_PREFIX"
    dir = Dir.mktmpdir("dev-settings-test-")
    checkout = File.join(dir, "src", "dev")
    brewless = File.join(dir, "usr", "local")
    homebrew = brew_prefix_in(dir, "opt", "homebrew")
    FileUtils.mkdir_p([checkout, brewless])
    saved = ENV.delete("HOMEBREW_PREFIX")

    Expect "the prefix with brew, skipping the brewless one that sorts first; nil with only brewless prefixes"
    Dev::Settings.brew_prefix(root: checkout, standard_prefixes: [brewless, homebrew]) == homebrew
    Dev::Settings.brew_prefix(root: checkout, standard_prefixes: [brewless, File.join(dir, "missing")]).nil?

    Cleanup
    ENV["HOMEBREW_PREFIX"] = saved if saved
    FileUtils.rm_rf(dir)
  end

  test "the standard prefixes are brew's supported install locations: Apple Silicon, Intel mac, Linuxbrew" do
    Expect
    Dev::Settings::STANDARD_BREW_PREFIXES == ["/opt/homebrew", "/usr/local", "/home/linuxbrew/.linuxbrew"]
  end

  test "HOMEBREW_PREFIX overrides the keg-derived prefix and names the system layer under it; an empty one counts as unset" do
    Given "a keg root under one prefix and HOMEBREW_PREFIX naming another; then an empty HOMEBREW_PREFIX"
    dir = Dir.mktmpdir("dev-settings-test-")
    keg_root = File.join(dir, "Cellar", "dev-core", "0.8.9", "libexec", "dev")
    named = File.join(dir, "named")
    FileUtils.mkdir_p([keg_root, named])
    saved = ENV["HOMEBREW_PREFIX"]
    ENV["HOMEBREW_PREFIX"] = named
    overridden = Dev::Settings.brew_prefix(root: keg_root)
    system_path = Dev::Settings.new(config_path: File.join(dir, "u.yml")).system_config_path
    ENV["HOMEBREW_PREFIX"] = ""
    derived = Dev::Settings.brew_prefix(root: keg_root)

    Expect "the named prefix, the system layer under it, and the keg's prefix once the override is empty"
    overridden == named
    system_path == File.join(named, "etc", "dev", "config.yml")
    derived == File.realpath(dir)

    Cleanup
    saved ? ENV["HOMEBREW_PREFIX"] = saved : ENV.delete("HOMEBREW_PREFIX")
    FileUtils.rm_rf(dir)
  end
end
