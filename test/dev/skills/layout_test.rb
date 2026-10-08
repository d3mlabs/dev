# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/skills/layout"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::Skills::LayoutTest < Minitest::Test
  test "SHIPPED_SKILLS_DIR points at dev's packaged skills" do
    Expect "the shipped ai-flow skill resolves under it"
    (Dev::Skills::Layout::SHIPPED_SKILLS_DIR / "ai-flow" / "SKILL.md").file?
  end

  test "the user-global root is ~/.cursor/skills" do
    Expect "the root under the given home"
    Dev::Skills::Layout.user_global_root(home: "/home/u") == Pathname("/home/u/.cursor/skills")
  end

  test "the project root is <project>/.agents/skills" do
    Expect "the agent-neutral project dir"
    Dev::Skills::Layout.project_root("/src/repo") == Pathname("/src/repo/.agents/skills")
  end
end
