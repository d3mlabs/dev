# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/footprint"
require "fileutils"
require "pathname"
require "support/recording_ui"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::FootprintTest < Minitest::Test
  # The agent-link subset, enough to exercise the writer's block mechanics.
  PATHS = [".cursor/rules/org-invariants.mdc", ".agents/skills/dev/", ".cursor/plans/"].freeze

  BLOCK = "#{Dev::Footprint::HEADER}\n.cursor/rules/org-invariants.mdc\n.agents/skills/dev/\n.cursor/plans/\n".freeze

  # The whole footprint, as docs/gitignore.md lists it: activation state
  # first, then the agent links.
  FULL_FOOTPRINT = [
    ".shadowenv.d/",
    ".shadowenv.d-container/",
    ".venv",
    ".venv-container",
    "build/_deps/",
    "lua_modules/",
    *PATHS,
  ].freeze

  def git_repo(dir)
    root = Pathname(dir) / "repo"
    FileUtils.mkdir_p(root)
    system("git", "-C", root.to_s, "init", "-q", exception: true)
    root
  end

  def ensure_footprint(root)
    Dev::Footprint::Gitignore.new(paths: PATHS).apply(root)
  end

  test "MANAGED_PATHS collects each owner's footprint line" do
    Expect "every path dev materializes into a project: the activation state, then the agent links"
    Dev::Footprint::MANAGED_PATHS == FULL_FOOTPRINT
  end

  test "the default writer writes the whole footprint, and git then ignores the venv links as symlinks" do
    Given "a fresh git repo whose .venv is a symlink, as dev links it"
    dir = Dir.mktmpdir("dev-footprint-test-")
    root = git_repo(dir)
    FileUtils.mkdir_p(Pathname(dir) / "store-venv")
    File.symlink((Pathname(dir) / "store-venv").to_s, (root / ".venv").to_s)

    When "ensuring with the default paths"
    added = Dev::Footprint::Gitignore.new.apply(root)

    Then "the whole footprint is added, nothing is left missing, and the symlink is ignored"
    added == FULL_FOOTPRINT
    (root / ".gitignore").read == "#{Dev::Footprint::HEADER}\n#{FULL_FOOTPRINT.join("\n")}\n"
    Dev::Footprint.missing(root, FULL_FOOTPRINT) == []
    Dev::Footprint.ignored?(root, ".venv") == true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure leaves alone a deps path the user's own broader pattern covers" do
    Given "a repo ignoring build/ wholesale and the venv link by name"
    dir = Dir.mktmpdir("dev-footprint-test-")
    root = git_repo(dir)
    (root / ".gitignore").write("build/\n.venv\n")

    When "ensuring the deps paths"
    added = Dev::Footprint::Gitignore.new(paths: [".venv", "build/_deps/", "lua_modules/"]).apply(root)

    Then "only the luarocks tree is added; build/_deps/ and .venv were already git-ignored"
    added == ["lua_modules/"]
    (root / ".gitignore").read == "build/\n.venv\n\n#{Dev::Footprint::HEADER}\nlua_modules/\n"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure adds a missing path inside a block under the legacy header, bringing the header current" do
    Given "a repo whose dev block carries the agent-links header, followed by more user content"
    dir = Dir.mktmpdir("dev-footprint-test-")
    root = git_repo(dir)
    (root / ".gitignore").write("*.log\n\n#{Dev::Footprint::LEGACY_HEADER}\n#{PATHS.join("\n")}\n\n# later\nbuild/\n")

    When "ensuring the venv links"
    added = Dev::Footprint::Gitignore.new(paths: [".venv", ".venv-container"]).apply(root)

    Then "the links join that block, its header reads the current wording, and no second block opens"
    added == [".venv", ".venv-container"]
    (root / ".gitignore").read ==
      "*.log\n\n#{Dev::Footprint::HEADER}\n#{PATHS.join("\n")}\n.venv\n.venv-container\n\n# later\nbuild/\n"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure in a repo without a .gitignore writes the block" do
    Given "a fresh git repo"
    dir = Dir.mktmpdir("dev-footprint-test-")
    root = git_repo(dir)

    When "ensuring"
    added = ensure_footprint(root)

    Then "all three paths are added as dev's block, and git now ignores them"
    added == PATHS
    (root / ".gitignore").read == BLOCK
    Dev::Footprint.missing(root, PATHS) == []

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure appends the block after a user's existing .gitignore content, then is a no-op" do
    Given "a repo with its own .gitignore"
    dir = Dir.mktmpdir("dev-footprint-test-")
    root = git_repo(dir)
    (root / ".gitignore").write("*.log\ntmp/\n")

    When "ensuring twice"
    first = ensure_footprint(root)
    second = ensure_footprint(root)

    Then "the user's lines lead, a blank line separates, the block follows; the second run adds nothing"
    first == PATHS
    second == []
    (root / ".gitignore").read == "*.log\ntmp/\n\n#{BLOCK}"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure leaves alone a path the user already ignores with their own pattern, wherever it sits" do
    Given "a repo ignoring the plans dir under its own comment and .agents wholesale"
    dir = Dir.mktmpdir("dev-footprint-test-")
    root = git_repo(dir)
    (root / ".gitignore").write("# mine\n.cursor/plans\n.agents/\n")

    When "ensuring"
    added = ensure_footprint(root)

    Then "only the invariants link is added, under dev's header; the user's lines are not moved"
    added == [".cursor/rules/org-invariants.mdc"]
    (root / ".gitignore").read == "# mine\n.cursor/plans\n.agents/\n\n#{Dev::Footprint::HEADER}\n.cursor/rules/org-invariants.mdc\n"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure adds a missing path inside an existing dev block rather than opening a second one" do
    Given "a repo whose dev block predates one of the paths, followed by more user content"
    dir = Dir.mktmpdir("dev-footprint-test-")
    root = git_repo(dir)
    (root / ".gitignore").write("*.log\n\n#{Dev::Footprint::HEADER}\n.cursor/rules/org-invariants.mdc\n.cursor/plans/\n\n# later\nbuild/\n")

    When "ensuring"
    added = ensure_footprint(root)

    Then "the skills line joins the block at its end; nothing else moves"
    added == [".agents/skills/dev/"]
    (root / ".gitignore").read ==
      "*.log\n\n#{Dev::Footprint::HEADER}\n.cursor/rules/org-invariants.mdc\n.cursor/plans/\n.agents/skills/dev/\n\n# later\nbuild/\n"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure outside a git repo falls back to a literal line match" do
    Given "a plain directory with a .gitignore naming one of the paths"
    dir = Dir.mktmpdir("dev-footprint-test-")
    root = Pathname(dir) / "plain"
    FileUtils.mkdir_p(root)
    (root / ".gitignore").write(".cursor/plans/\n")

    When "ensuring"
    added = ensure_footprint(root)

    Then "the literally present path is skipped, the others added"
    added == [".cursor/rules/org-invariants.mdc", ".agents/skills/dev/"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "ensure with no git on PATH behaves as outside a repo: literal match, nothing raised" do
    Given "a git repo whose .gitignore names one path, and a PATH with no git on it"
    dir = Dir.mktmpdir("dev-footprint-test-")
    root = git_repo(dir)
    (root / ".gitignore").write(".cursor/plans/\n")
    path_was = ENV.fetch("PATH")
    ENV["PATH"] = File.join(dir, "empty-bin")

    When "ensuring"
    added = ensure_footprint(root)

    Then "git could not be asked, so the literal line counts and the others are added"
    added == [".cursor/rules/org-invariants.mdc", ".agents/skills/dev/"]

    Cleanup
    ENV["PATH"] = path_was
    FileUtils.rm_rf(dir)
  end

  test "missing reports the paths git does not ignore, and nothing outside a git repo" do
    Given "a repo ignoring one path, and a plain dir"
    dir = Dir.mktmpdir("dev-footprint-test-")
    root = git_repo(dir)
    (root / ".gitignore").write(".cursor/plans/\n")
    plain = Pathname(dir) / "plain"
    FileUtils.mkdir_p(plain)

    Expect "the two uncovered paths in the repo; none in the plain dir"
    Dev::Footprint.missing(root, PATHS) == [".cursor/rules/org-invariants.mdc", ".agents/skills/dev/"]
    Dev::Footprint.missing(plain, PATHS) == []

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "warn_missing notes one {{x}} repair line per uncovered path" do
    Given "a repo ignoring nothing"
    dir = Dir.mktmpdir("dev-footprint-test-")
    root = git_repo(dir)
    ui = RecordingUi.new

    When "warning for one path"
    Dev::Footprint.warn_missing(ui, root, [".cursor/plans/"])

    Then
    ui.rows == [[:note, "{{x}} .cursor/plans/ is not gitignored — run `dev learnings init --gitignore`.", 0]]

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
