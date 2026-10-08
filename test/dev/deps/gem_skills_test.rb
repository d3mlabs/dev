# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/gem_skills"
require "dev/deps/shadowenv_exec"
require "dev/skills"
require "tmpdir"
require "fileutils"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::Deps::GemSkillsTest < Minitest::Test
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

  # `bundle list` runs through the ShadowenvExec seam — the project's
  # provisioned Ruby, dev's own gem env scrubbed — so the channel's bundler
  # boundary is the seam, stubbed to answer with the given gem paths.
  #
  # @return [Dev::Deps::ShadowenvExec] the seam to hand to the channel
  def stub_bundle_list(project, paths)
    shadowenv_exec = Dev::Deps::ShadowenvExec.new(project_root: project)
    shadowenv_exec.stubs(:capture3)
                  .with("bundle", "list", "--paths", env: { "BUNDLE_GEMFILE" => (project / "Gemfile").to_s })
                  .returns([paths.map { |p| "#{p}\n" }.join, "", stub(success?: true)])
    shadowenv_exec
  end

  def build_channel(project, shadowenv_exec)
    Dev::Deps::GemSkills.new(project_root: project, shadowenv_exec: shadowenv_exec)
  end

  # The fixture gem trees live under the real temp dir, so the installer's
  # ephemeral-source guard is pinned inside the fixture dir.
  def build_materializer(dir)
    Dev::Skills::Materializer.new(
      installer_factory: ->(root) { Dev::Skills::Installer.new(skills_dir: root, tmpdir: File.join(dir, "tmp")) },
    )
  end

  test "declares a locked gem's shipped skills as gem-<gem>--<skill>, with the gem and version as provenance" do
    Given "a locked gem whose tree ships a skill, and one that ships none"
    dir = Dir.mktmpdir("dev-gem-skills-test-")
    project, gems = build_project(dir)
    rspock = build_gem(gems, "rspock-1.2.0", skills: ["rspock"])
    minitest = build_gem(gems, "minitest-5.25.0")
    channel = build_channel(project, stub_bundle_list(project, [rspock, minitest]))

    When "listing entries"
    entries = channel.entries

    Then "one entry, named by convention, sourced from the gem's skill dir, carrying its provenance"
    entries.size == 1
    entries[0].link_name == "gem-rspock--rspock"
    entries[0].source == rspock / "skills" / "rspock"
    entries[0].package == "rspock"
    entries[0].version == "1.2.0"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the channel is named gem and lands project-scoped under .agents/skills" do
    Given "a project"
    dir = Dir.mktmpdir("dev-gem-skills-test-")
    project, = build_project(dir)
    channel = build_channel(project, Dev::Deps::ShadowenvExec.new(project_root: project))

    Expect "the conventional name and root"
    channel.name == "gem"
    channel.root == project / ".agents" / "skills"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the longest locked name wins when gem dir basenames share a prefix" do
    Given "minitest and minitest-reporters, the latter shipping a skill"
    dir = Dir.mktmpdir("dev-gem-skills-test-")
    project, gems = build_project(dir)
    reporters = build_gem(gems, "minitest-reporters-1.7.1", skills: ["reporting"])
    channel = build_channel(project, stub_bundle_list(project, [reporters]))

    When "listing entries"
    entries = channel.entries

    Then "the entry is named for minitest-reporters, not minitest, and versioned from the right suffix"
    entries.map(&:link_name) == ["gem-minitest-reporters--reporting"]
    entries[0].package == "minitest-reporters"
    entries[0].version == "1.7.1"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a path gem with a bare root has no version" do
    Given "a locked gem resolving to a bare directory"
    dir = Dir.mktmpdir("dev-gem-skills-test-")
    project, gems = build_project(dir)
    rspock = build_gem(gems, "rspock", skills: ["rspock"])
    channel = build_channel(project, stub_bundle_list(project, [rspock]))

    Expect "the entry has its package but nil version"
    channel.entries.map { |e| [e.package, e.version] } == [["rspock", nil]]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a gem tree absent from the lockfile is never declared" do
    Given "an installed tree whose name is not locked"
    dir = Dir.mktmpdir("dev-gem-skills-test-")
    project, gems = build_project(dir)
    stray = build_gem(gems, "stray-9.9.9", skills: ["stray"])
    channel = build_channel(project, stub_bundle_list(project, [stray]))

    Expect "no entries"
    channel.entries == []

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "owns? only gem- prefixed links" do
    Given "a project"
    dir = Dir.mktmpdir("dev-gem-skills-test-")
    project, = build_project(dir)
    channel = build_channel(project, Dev::Deps::ShadowenvExec.new(project_root: project))

    Expect "the prefix decides"
    channel.owns?(Pathname("/x/gem-rspock--rspock"))
    !channel.owns?(Pathname("/x/my-own-link"))

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "declares nothing without a Gemfile (no bundler subprocess)" do
    Given "a project with no Gemfile"
    dir = Dir.mktmpdir("dev-gem-skills-test-")
    project = Pathname(dir) / "repo"
    FileUtils.mkdir_p(project)
    shadowenv_exec = Dev::Deps::ShadowenvExec.new(project_root: project)
    channel = build_channel(project, shadowenv_exec)

    When "listing entries"
    entries = channel.entries

    Then "nothing is declared and bundler is never consulted"
    entries == []
    0 * shadowenv_exec.capture3(any_parameters)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  # The seam owns the env scrub (dev#89, dev#180 — pinned in its own test);
  # the channel's part is to send `bundle list` through it against the
  # generated Gemfile rather than spawning bundler itself.
  test "bundle list goes through the shadowenv seam against the generated Gemfile" do
    Given "a project"
    dir = Dir.mktmpdir("dev-gem-skills-test-")
    project, = build_project(dir)
    shadowenv_exec = Dev::Deps::ShadowenvExec.new(project_root: project)
    channel = build_channel(project, shadowenv_exec)

    When "listing entries"
    channel.entries

    Then "the seam is asked for the bundle's paths with only the Gemfile pin layered on"
    1 * shadowenv_exec.capture3(
      "bundle", "list", "--paths",
      env: { "BUNDLE_GEMFILE" => (project / "Gemfile").to_s },
    ) >> ["", "", stub(success?: true)]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a failing bundle list warns and declares nothing instead of failing the install" do
    Given "bundler erroring out"
    dir = Dir.mktmpdir("dev-gem-skills-test-")
    project, = build_project(dir)
    shadowenv_exec = Dev::Deps::ShadowenvExec.new(project_root: project)
    shadowenv_exec.stubs(:capture3).returns(["", "bundler exploded", stub(success?: false)])
    channel = build_channel(project, shadowenv_exec)
    old_stderr = $stderr
    $stderr = StringIO.new

    When "listing entries"
    entries = channel.entries

    Then "the failure is a warning, not an exception"
    entries == []
    $stderr.string.include?("could not list bundled gems")

    Cleanup
    $stderr = old_stderr
    FileUtils.rm_rf(dir)
  end

  test "materialized, a locked gem's skill lands under .agents/skills and a departed gem's link is pruned" do
    Given "a stale gem link, a user symlink, and a user file in the project's skills dir"
    dir = Dir.mktmpdir("dev-gem-skills-test-")
    project, gems = build_project(dir)
    rspock = build_gem(gems, "rspock-1.2.0", skills: ["rspock"])
    skills_dir = project / ".agents" / "skills"
    FileUtils.mkdir_p(skills_dir)
    departed = build_gem(gems, "departed-1.0.0", skills: ["departed"])
    File.symlink(departed / "skills" / "departed", skills_dir / "gem-departed--departed")
    File.symlink(gems, skills_dir / "my-own-link")
    (skills_dir / "notes.md").write("mine\n")
    channel = build_channel(project, stub_bundle_list(project, [rspock]))

    When "materializing the channel"
    build_materializer(dir).sync([channel])

    Then "the locked skill is linked, only the departed gem link is pruned"
    File.readlink(skills_dir / "gem-rspock--rspock") == (rspock / "skills" / "rspock").to_s
    !File.symlink?(skills_dir / "gem-departed--departed")
    File.symlink?(skills_dir / "my-own-link")
    (skills_dir / "notes.md").file?

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
