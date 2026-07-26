# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/knowledge/invariants_renderer"
require "pathname"
require "tmpdir"
require "fileutils"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::Knowledge::InvariantsRendererTest < Minitest::Test
  INDEX = <<~INDEX
    # Org learnings index

    Preamble prose.

    ## Invariants (always-on)

    - [design/single-responsibility] One reason to change per unit.
      → skills/single-responsibility/

    ## Knowledge (on-demand)

    - [ruby/typed-errors] Named error classes. → skills/typed-errors/
  INDEX

  def build_env(dir)
    index = Pathname(dir) / "index.md"
    index.write(INDEX)
    rules = Pathname(dir) / "repo" / ".cursor" / "rules" / "org-invariants.mdc"
    [index, rules]
  end

  test "renders the invariants section as an always-on generated rule" do
    Given "a cached index and a project without the rule"
    dir = Dir.mktmpdir("dev-invariants-test-")
    index, rules = build_env(dir)
    renderer = Dev::Knowledge::InvariantsRenderer.new

    When "rendering"
    renderer.render(index_file: index, rules_file: rules, repo: "d3mlabs/knowledge")

    Then "the rule is always-on, marked generated, and carries only the invariant lines"
    content = rules.read
    content.include?("alwaysApply: true")
    content.include?(Dev::Knowledge::InvariantsRenderer::GENERATED_MARKER)
    content.include?("d3mlabs/knowledge")
    content.include?("[design/single-responsibility]")
    !content.include?("[ruby/typed-errors]")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "an unchanged render never rewrites the file" do
    Given "an already-rendered rule, backdated to detect writes"
    dir = Dir.mktmpdir("dev-invariants-test-")
    index, rules = build_env(dir)
    renderer = Dev::Knowledge::InvariantsRenderer.new
    renderer.render(index_file: index, rules_file: rules, repo: "d3mlabs/knowledge")
    old = Time.now - 3600
    File.utime(old, old, rules)

    When "rendering the same content again"
    renderer.render(index_file: index, rules_file: rules, repo: "d3mlabs/knowledge")

    Then "the file was not touched"
    (File.mtime(rules) - old).abs < 5

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a user-owned file in the rule's place survives, with a warning" do
    Given "a hand-written file at the render target"
    dir = Dir.mktmpdir("dev-invariants-test-")
    index, rules = build_env(dir)
    FileUtils.mkdir_p(rules.dirname)
    rules.write("my own rule\n")
    renderer = Dev::Knowledge::InvariantsRenderer.new
    old_stderr = $stderr
    $stderr = StringIO.new

    When "rendering"
    renderer.render(index_file: index, rules_file: rules, repo: "d3mlabs/knowledge")

    Then "the file is untouched and the collision reported"
    rules.read == "my own rule\n"
    $stderr.string.include?("not dev-generated")

    Cleanup
    $stderr = old_stderr
    FileUtils.rm_rf(dir)
  end

  test "a vanished index retracts a previously generated rule" do
    Given "a rendered rule whose index disappears"
    dir = Dir.mktmpdir("dev-invariants-test-")
    index, rules = build_env(dir)
    renderer = Dev::Knowledge::InvariantsRenderer.new
    renderer.render(index_file: index, rules_file: rules, repo: "d3mlabs/knowledge")
    index.delete

    When "rendering"
    renderer.render(index_file: index, rules_file: rules, repo: "d3mlabs/knowledge")

    Then "the generated rule is gone"
    !rules.exist?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "an index without an invariants section retracts the rule" do
    Given "a rendered rule, then an index that dropped the section"
    dir = Dir.mktmpdir("dev-invariants-test-")
    index, rules = build_env(dir)
    renderer = Dev::Knowledge::InvariantsRenderer.new
    renderer.render(index_file: index, rules_file: rules, repo: "d3mlabs/knowledge")
    index.write("# Org learnings index\n\n## Knowledge (on-demand)\n\n- a line\n")

    When "rendering"
    renderer.render(index_file: index, rules_file: rules, repo: "d3mlabs/knowledge")

    Then "the generated rule is gone"
    !rules.exist?

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
