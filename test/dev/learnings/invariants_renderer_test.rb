# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/learnings/invariants_renderer"
require "pathname"
require "tmpdir"
require "fileutils"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::Learnings::InvariantsRendererTest < Minitest::Test
  INDEX = <<~INDEX
    # Org learnings index

    Preamble prose.

    ## Invariants (always-on)

    - [design/single-responsibility] One reason to change per unit.
      → skills/single-responsibility/

    ## Knowledge (on-demand)

    - [ruby/typed-errors] Named error classes. → skills/typed-errors/
  INDEX

  # A cached index, the machine-side render target beside it, and a project's
  # rules-file link target.
  def build_env(dir)
    index = Pathname(dir) / "index.md"
    index.write(INDEX)
    rendered = Pathname(dir) / "org-invariants.mdc"
    rules = Pathname(dir) / "repo" / ".cursor" / "rules" / "org-invariants.mdc"
    [index, rendered, rules]
  end

  test "renders the invariants section as an always-on generated rule beside the cache" do
    Given "a cached index and no render yet"
    dir = Dir.mktmpdir("dev-invariants-test-")
    index, rendered, = build_env(dir)
    renderer = Dev::Learnings::InvariantsRenderer.new

    When "rendering"
    renderer.render(index_file: index, rendered_file: rendered, repo: "d3mlabs/knowledge")

    Then "the rule is always-on, marked generated, and carries only the invariant lines"
    content = rendered.read
    content.include?("alwaysApply: true")
    content.include?(Dev::Learnings::InvariantsRenderer::GENERATED_MARKER)
    content.include?("d3mlabs/knowledge")
    content.include?("[design/single-responsibility]")
    !content.include?("[ruby/typed-errors]")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "an unchanged render never rewrites the file" do
    Given "an already-rendered rule, backdated to detect writes"
    dir = Dir.mktmpdir("dev-invariants-test-")
    index, rendered, = build_env(dir)
    renderer = Dev::Learnings::InvariantsRenderer.new
    renderer.render(index_file: index, rendered_file: rendered, repo: "d3mlabs/knowledge")
    old = Time.now - 3600
    File.utime(old, old, rendered)

    When "rendering the same content again"
    renderer.render(index_file: index, rendered_file: rendered, repo: "d3mlabs/knowledge")

    Then "the file was not touched"
    (File.mtime(rendered) - old).abs < 5

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a vanished index (or one without an invariants section) retracts the render" do
    Given "a rendered rule whose index loses its section"
    dir = Dir.mktmpdir("dev-invariants-test-")
    index, rendered, = build_env(dir)
    renderer = Dev::Learnings::InvariantsRenderer.new
    renderer.render(index_file: index, rendered_file: rendered, repo: "d3mlabs/knowledge")
    index.write("# Org learnings index\n\n## Knowledge (on-demand)\n\n- a line\n")

    When "rendering"
    renderer.render(index_file: index, rendered_file: rendered, repo: "d3mlabs/knowledge")

    Then "the render is gone"
    !rendered.exist?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "prompt_block is the invariants section plus the skill-pointer note" do
    Given "a cached index"
    dir = Dir.mktmpdir("dev-invariants-test-")
    index, = build_env(dir)
    renderer = Dev::Learnings::InvariantsRenderer.new

    When "extracting the Tier-0 prompt block"
    block = renderer.prompt_block(index)

    Then "the block carries the invariant lines and the pointer note, nothing else"
    block.include?("[design/single-responsibility]")
    block.include?(Dev::Learnings::InvariantsRenderer::SKILL_POINTER_NOTE)
    !block.include?("[ruby/typed-errors]")
    !block.include?("alwaysApply")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "prompt_block is nil without an index or an invariants section" do
    Given "an index that lost its invariants section"
    dir = Dir.mktmpdir("dev-invariants-test-")
    index, = build_env(dir)
    index.write("# Org learnings index\n\n## Knowledge (on-demand)\n\n- a line\n")
    renderer = Dev::Learnings::InvariantsRenderer.new

    Expect
    renderer.prompt_block(index).nil?
    renderer.prompt_block(Pathname(dir) / "missing.md").nil?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "link points the project rules file at the render as a symlink" do
    Given "a machine-side render and a project without the link"
    dir = Dir.mktmpdir("dev-invariants-test-")
    index, rendered, rules = build_env(dir)
    renderer = Dev::Learnings::InvariantsRenderer.new
    renderer.render(index_file: index, rendered_file: rendered, repo: "d3mlabs/knowledge")

    When "linking"
    renderer.link(rendered_file: rendered, rules_file: rules)

    Then "the project carries a symlink resolving to the render"
    rules.symlink?
    rules.readlink == rendered
    rules.read.include?("[design/single-responsibility]")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "link replaces a legacy per-project generated file with the symlink" do
    Given "a project still carrying an old-style generated regular file"
    dir = Dir.mktmpdir("dev-invariants-test-")
    index, rendered, rules = build_env(dir)
    renderer = Dev::Learnings::InvariantsRenderer.new
    renderer.render(index_file: index, rendered_file: rendered, repo: "d3mlabs/knowledge")
    FileUtils.mkdir_p(rules.dirname)
    rules.write("#{Dev::Learnings::InvariantsRenderer::LEGACY_GENERATED_MARKER} changes land upstream -->\nold render\n")

    When "linking"
    renderer.link(rendered_file: rendered, rules_file: rules)

    Then "the file became the symlink"
    rules.symlink?
    rules.readlink == rendered

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a user-owned file in the link's place survives, with a warning" do
    Given "a hand-written file at the link target"
    dir = Dir.mktmpdir("dev-invariants-test-")
    index, rendered, rules = build_env(dir)
    renderer = Dev::Learnings::InvariantsRenderer.new
    renderer.render(index_file: index, rendered_file: rendered, repo: "d3mlabs/knowledge")
    FileUtils.mkdir_p(rules.dirname)
    rules.write("my own rule\n")
    old_stderr = $stderr
    $stderr = StringIO.new

    When "linking"
    renderer.link(rendered_file: rendered, rules_file: rules)

    Then "the file is untouched and the collision reported"
    rules.read == "my own rule\n"
    !rules.symlink?
    $stderr.string.include?("not dev-generated")

    Cleanup
    $stderr = old_stderr
    FileUtils.rm_rf(dir)
  end

  test "a retracted render removes the project link" do
    Given "a linked project whose render is retracted"
    dir = Dir.mktmpdir("dev-invariants-test-")
    index, rendered, rules = build_env(dir)
    renderer = Dev::Learnings::InvariantsRenderer.new
    renderer.render(index_file: index, rendered_file: rendered, repo: "d3mlabs/knowledge")
    renderer.link(rendered_file: rendered, rules_file: rules)
    index.delete
    renderer.render(index_file: index, rendered_file: rendered, repo: "d3mlabs/knowledge")

    When "linking against the retracted render"
    renderer.link(rendered_file: rendered, rules_file: rules)

    Then "the project link is gone"
    !rules.symlink?
    !rules.exist?

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
