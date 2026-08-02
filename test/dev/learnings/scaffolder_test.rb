# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/learnings"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Learnings::ScaffolderTest < Minitest::Test
  test "scaffold_repo writes the empty always-on index at the canonical path" do
    Given "a repo with no learnings index"
    dir = Dir.mktmpdir("dev-learnings-scaffolder-test-")

    When "scaffolding the repo tier"
    Dev::Learnings::Scaffolder.new.scaffold_repo(dir)

    Then "the index carries the repo-tier template, front matter included"
    index = Dev::Learnings::Layout.repo_index_file(dir)
    index.file?
    index.read == Dev::Learnings::Layout::REPO_INDEX_SCAFFOLD
    index.read.include?("alwaysApply: true")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "scaffold_repo refuses an existing index with a typed error" do
    Given "a repo whose index is already committed"
    dir = Dir.mktmpdir("dev-learnings-scaffolder-test-")
    index = Dev::Learnings::Layout.repo_index_file(dir)
    FileUtils.mkdir_p(index.dirname)
    index.write("# hand-curated\n")

    When "scaffolding the repo tier again"
    Dev::Learnings::Scaffolder.new.scaffold_repo(dir)

    Then
    raises Dev::Learnings::Scaffolder::IndexAlreadyExistsError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "scaffold_org writes the knowledge-repo layout: the index plus a commitable skills corpus" do
    Given "an empty knowledge repo checkout"
    dir = Dir.mktmpdir("dev-learnings-scaffolder-test-")

    When "scaffolding the org tier"
    Dev::Learnings::Scaffolder.new.scaffold_org(dir)

    Then "index.md carries the org template and skills/ exists with its gitkeep"
    index = Dev::Learnings::Layout.org_index_file(dir)
    index.file?
    index.read == Dev::Learnings::Layout::ORG_INDEX_SCAFFOLD
    skills_dir = Dev::Learnings::Layout.org_skills_dir(dir)
    skills_dir.directory?
    (skills_dir / Dev::Learnings::Scaffolder::GITKEEP_FILENAME).file?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "scaffold_org refuses an existing index with a typed error" do
    Given "a knowledge repo checkout that already carries an index"
    dir = Dir.mktmpdir("dev-learnings-scaffolder-test-")
    Dev::Learnings::Layout.org_index_file(dir).write("# curated org index\n")

    When "scaffolding the org tier again"
    Dev::Learnings::Scaffolder.new.scaffold_org(dir)

    Then
    raises Dev::Learnings::Scaffolder::IndexAlreadyExistsError

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a scaffolded org index is already parseable by the invariants renderer" do
    Given "a freshly scaffolded knowledge repo checkout"
    dir = Dir.mktmpdir("dev-learnings-scaffolder-test-")
    Dev::Learnings::Scaffolder.new.scaffold_org(dir)

    When "extracting the Tier-0 prompt block from the scaffolded index"
    block = Dev::Learnings::InvariantsRenderer.new.prompt_block(Dev::Learnings::Layout.org_index_file(dir))

    Then "the fixed invariants section is recognized (empty of entries, but present)"
    !block.nil?

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
