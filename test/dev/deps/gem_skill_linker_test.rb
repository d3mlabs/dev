# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/gem_skill_linker"
require "open3"
require "tmpdir"
require "fileutils"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::Deps::GemSkillLinkerTest < Minitest::Test
  LOCKFILE = <<~LOCK
    GEM
      remote: https://rubygems.org/
      specs:
        minitest (5.25.0)
        minitest-reporters (1.7.1)
          minitest (>= 5.0)
        rspock (1.2.0)

    PLATFORMS
      arm64-darwin

    DEPENDENCIES
      rspock
  LOCK

  # A project with a generated Gemfile/Gemfile.lock, plus an installed gem
  # tree in the same tmpdir. Returns [project_root, gems_root].
  def build_project(dir)
    project = Pathname(dir) / "repo"
    FileUtils.mkdir_p(project)
    (project / "Gemfile").write("source \"https://rubygems.org\"\n")
    (project / "Gemfile.lock").write(LOCKFILE)
    gems = Pathname(dir) / "gems"
    FileUtils.mkdir_p(gems)
    [project, gems]
  end

  def build_gem(gems_root, dir_name, skills: [])
    root = gems_root / dir_name
    skills.each do |skill|
      FileUtils.mkdir_p(root / "skills" / skill)
      (root / "skills" / skill / "SKILL.md").write("# #{skill}\n")
    end
    FileUtils.mkdir_p(root)
    root
  end

  # `bundle list` must run under the project's shadowenv — same reasoning as
  # BundlerIntegration: the dev process's PATH is the invoking service's,
  # which on headless boxes carries the wrong Ruby — with harness bundler
  # overrides scrubbed from the child env.
  def stub_bundle_list(project, paths)
    env = Dev::Deps::GemSkillLinker::HARNESS_ENV_SCRUB.merge("BUNDLE_GEMFILE" => (project / "Gemfile").to_s)
    Open3.stubs(:capture3)
         .with(env, "shadowenv", "exec", "--", "bundle", "list", "--paths", chdir: project.to_s)
         .returns([paths.map { |p| "#{p}\n" }.join, "", stub(success?: true)])
  end

  # Linker under test. The real Dir.tmpdir contains these tests' own fixture
  # trees, so every linker gets a tmpdir override pointing inside the fixture
  # dir — gems built by build_gem under `gems/` then read as durable, and a
  # test opts into ephemerality by building under `<dir>/tmp`.
  def build_linker(project, dir)
    Dev::Deps::GemSkillLinker.new(project_root: project, tmpdir: Pathname(dir) / "tmp")
  end

  test "links a locked gem's shipped skills as gem-<gem>--<skill>" do
    Given "a locked gem whose tree ships a skill"
    dir = Dir.mktmpdir("dev-gem-skill-test-")
    project, gems = build_project(dir)
    rspock = build_gem(gems, "rspock-1.2.0", skills: ["rspock"])
    minitest = build_gem(gems, "minitest-5.25.0")
    stub_bundle_list(project, [rspock, minitest])
    linker = build_linker(project, dir)

    When "linking"
    linker.link_all

    Then "the skill is linked project-scoped under .agents/skills"
    link = project / ".agents" / "skills" / "gem-rspock--rspock"
    File.symlink?(link)
    File.readlink(link) == (rspock / "skills" / "rspock").to_s

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the longest locked name wins when gem dir basenames share a prefix" do
    Given "minitest and minitest-reporters, the latter shipping a skill"
    dir = Dir.mktmpdir("dev-gem-skill-test-")
    project, gems = build_project(dir)
    reporters = build_gem(gems, "minitest-reporters-1.7.1", skills: ["reporting"])
    stub_bundle_list(project, [reporters])
    linker = build_linker(project, dir)

    When "linking"
    linker.link_all

    Then "the link is named for minitest-reporters, not minitest"
    File.symlink?(project / ".agents" / "skills" / "gem-minitest-reporters--reporting")
    !File.exist?(project / ".agents" / "skills" / "gem-minitest--reporting")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a gem tree absent from the lockfile never links" do
    Given "an installed tree whose name is not locked"
    dir = Dir.mktmpdir("dev-gem-skill-test-")
    project, gems = build_project(dir)
    stray = build_gem(gems, "stray-9.9.9", skills: ["stray"])
    stub_bundle_list(project, [stray])
    linker = build_linker(project, dir)

    When "linking"
    linker.link_all

    Then "no link is created"
    !File.exist?(project / ".agents" / "skills" / "gem-stray--stray")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "prunes gem links whose gem left the lock, leaving foreign entries" do
    Given "a stale gem link, a user symlink, and a user file in the skills dir"
    dir = Dir.mktmpdir("dev-gem-skill-test-")
    project, gems = build_project(dir)
    rspock = build_gem(gems, "rspock-1.2.0", skills: ["rspock"])
    stub_bundle_list(project, [rspock])
    skills_dir = project / ".agents" / "skills"
    FileUtils.mkdir_p(skills_dir)
    departed = build_gem(gems, "departed-1.0.0", skills: ["departed"])
    File.symlink(departed / "skills" / "departed", skills_dir / "gem-departed--departed")
    File.symlink(gems, skills_dir / "my-own-link")
    (skills_dir / "notes.md").write("mine\n")
    linker = build_linker(project, dir)

    When "linking"
    linker.link_all

    Then "only the departed gem link is pruned"
    !File.symlink?(skills_dir / "gem-departed--departed")
    File.symlink?(skills_dir / "gem-rspock--rspock")
    File.symlink?(skills_dir / "my-own-link")
    (skills_dir / "notes.md").file?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "no-ops without a Gemfile (no bundler subprocess)" do
    Given "a project with no Gemfile"
    dir = Dir.mktmpdir("dev-gem-skill-test-")
    project = Pathname(dir) / "repo"
    FileUtils.mkdir_p(project)
    Open3.expects(:capture3).never
    linker = build_linker(project, dir)

    When "linking"
    linker.link_all

    Then "nothing is created"
    !(project / ".agents").exist?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "link_all warns instead of failing the install when the skills dir is unreadable" do
    Given "a project whose skills dir cannot be read for pruning"
    dir = Dir.mktmpdir("dev-gem-skill-test-")
    project, = build_project(dir)
    stub_bundle_list(project, [])
    skills_dir = project / ".agents" / "skills"
    FileUtils.mkdir_p(skills_dir)
    FileUtils.chmod(0o000, skills_dir)
    linker = build_linker(project, dir)
    old_stderr = $stderr
    $stderr = StringIO.new

    When "linking"
    linker.link_all

    Then "the failure is a warning, not an exception"
    $stderr.string.include?("could not refresh gem skill links")

    Cleanup
    $stderr = old_stderr
    FileUtils.chmod(0o755, skills_dir)
    FileUtils.rm_rf(dir)
  end

  # Pins the exact scrub set rather than referencing HARNESS_ENV_SCRUB: a
  # sandboxed session (Cursor sandbox cache, dev#89) leaks these overrides
  # into dev's env, and dropping any of them from the scrub would silently
  # re-open the leak.
  test "bundle list runs with harness bundler and gem overrides explicitly unset" do
    Given "a project"
    dir = Dir.mktmpdir("dev-gem-skill-test-")
    project, = build_project(dir)
    linker = build_linker(project, dir)

    When "linking"
    linker.link_all

    Then "every harness override is nil'd in the child env"
    1 * Open3.capture3(
      {
        "BUNDLE_PATH" => nil,
        "BUNDLE_APP_CONFIG" => nil,
        "BUNDLE_BIN" => nil,
        "GEM_HOME" => nil,
        "GEM_PATH" => nil,
        "RUBYOPT" => nil,
        "RUBYLIB" => nil,
        "BUNDLE_GEMFILE" => (project / "Gemfile").to_s,
      },
      "shadowenv", "exec", "--", "bundle", "list", "--paths", chdir: project.to_s
    ) >> ["", "", stub(success?: true)]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "refuses to link a skill resolved under the temp dir and warns" do
    Given "a locked gem whose tree resolves into the ephemeral temp dir"
    dir = Dir.mktmpdir("dev-gem-skill-test-")
    project, = build_project(dir)
    ephemeral = build_gem(Pathname(dir) / "tmp" / "gems", "rspock-1.2.0", skills: ["rspock"])
    stub_bundle_list(project, [ephemeral])
    linker = build_linker(project, dir)
    old_stderr = $stderr
    $stderr = StringIO.new

    When "linking"
    linker.link_all

    Then "no link is created and the skip is warned"
    !File.exist?(project / ".agents" / "skills" / "gem-rspock--rspock")
    $stderr.string.include?("not linking gem-rspock--rspock")

    Cleanup
    $stderr = old_stderr
    FileUtils.rm_rf(dir)
  end

  test "an ephemeral resolution does not prune the durable link it shadows" do
    Given "a durable link for a gem that now resolves into the temp dir"
    dir = Dir.mktmpdir("dev-gem-skill-test-")
    project, gems = build_project(dir)
    durable = build_gem(gems, "rspock-1.2.0", skills: ["rspock"])
    skills_dir = project / ".agents" / "skills"
    FileUtils.mkdir_p(skills_dir)
    File.symlink(durable / "skills" / "rspock", skills_dir / "gem-rspock--rspock")
    ephemeral = build_gem(Pathname(dir) / "tmp" / "gems", "rspock-1.2.0", skills: ["rspock"])
    stub_bundle_list(project, [ephemeral])
    linker = build_linker(project, dir)
    old_stderr = $stderr
    $stderr = StringIO.new

    When "linking"
    linker.link_all

    Then "the durable link survives, still pointing at its durable target"
    File.symlink?(skills_dir / "gem-rspock--rspock")
    File.readlink(skills_dir / "gem-rspock--rspock") == (durable / "skills" / "rspock").to_s

    Cleanup
    $stderr = old_stderr
    FileUtils.rm_rf(dir)
  end

  test "temp dir containment sees through symlinked temp roots" do
    Given "a tmpdir override that is a symlink to the dir the gem resolves under"
    dir = Dir.mktmpdir("dev-gem-skill-test-")
    project, = build_project(dir)
    real_tmp = Pathname(dir) / "tmp"
    ephemeral = build_gem(real_tmp / "gems", "rspock-1.2.0", skills: ["rspock"])
    tmp_alias = Pathname(dir) / "tmp-alias"
    File.symlink(real_tmp, tmp_alias)
    stub_bundle_list(project, [ephemeral])
    linker = Dev::Deps::GemSkillLinker.new(project_root: project, tmpdir: tmp_alias)
    old_stderr = $stderr
    $stderr = StringIO.new

    When "linking"
    linker.link_all

    Then "the path is recognized as ephemeral and never links"
    !File.exist?(project / ".agents" / "skills" / "gem-rspock--rspock")

    Cleanup
    $stderr = old_stderr
    FileUtils.rm_rf(dir)
  end

  test "a failing bundle list warns instead of failing the install" do
    Given "bundler erroring out"
    dir = Dir.mktmpdir("dev-gem-skill-test-")
    project, = build_project(dir)
    Open3.stubs(:capture3).returns(["", "bundler exploded", stub(success?: false)])
    linker = build_linker(project, dir)
    old_stderr = $stderr
    $stderr = StringIO.new

    When "linking"
    linker.link_all

    Then "the failure is a warning, not an exception"
    $stderr.string.include?("could not list bundled gems")

    Cleanup
    $stderr = old_stderr
    FileUtils.rm_rf(dir)
  end
end
