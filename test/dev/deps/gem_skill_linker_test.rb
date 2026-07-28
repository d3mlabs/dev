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
  # which on headless boxes carries the wrong Ruby.
  def stub_bundle_list(project, paths)
    Open3.stubs(:capture3)
         .with({ "BUNDLE_GEMFILE" => (project / "Gemfile").to_s },
           "shadowenv", "exec", "--", "bundle", "list", "--paths", chdir: project.to_s)
         .returns([paths.map { |p| "#{p}\n" }.join, "", stub(success?: true)])
  end

  test "links a locked gem's shipped skills as gem-<gem>--<skill>" do
    Given "a locked gem whose tree ships a skill"
    dir = Dir.mktmpdir("dev-gem-skill-test-")
    project, gems = build_project(dir)
    rspock = build_gem(gems, "rspock-1.2.0", skills: ["rspock"])
    minitest = build_gem(gems, "minitest-5.25.0")
    stub_bundle_list(project, [rspock, minitest])
    linker = Dev::Deps::GemSkillLinker.new(project_root: project)

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
    linker = Dev::Deps::GemSkillLinker.new(project_root: project)

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
    linker = Dev::Deps::GemSkillLinker.new(project_root: project)

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
    linker = Dev::Deps::GemSkillLinker.new(project_root: project)

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
    linker = Dev::Deps::GemSkillLinker.new(project_root: project)

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
    linker = Dev::Deps::GemSkillLinker.new(project_root: project)
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

  test "a failing bundle list warns instead of failing the install" do
    Given "bundler erroring out"
    dir = Dir.mktmpdir("dev-gem-skill-test-")
    project, = build_project(dir)
    Open3.stubs(:capture3).returns(["", "bundler exploded", stub(success?: false)])
    linker = Dev::Deps::GemSkillLinker.new(project_root: project)
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
