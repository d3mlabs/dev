# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/project_shadowenv"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::ProjectShadowenvTest < Minitest::Test
  ROOT = Pathname("/work/proj")

  test "on the host, shadowenv searches from the project root and finds the conventional .shadowenv.d" do
    Given
    shadowenv = Dev::ProjectShadowenv.new(ROOT, inside: false)

    Expect
    shadowenv.search_root == ROOT
    shadowenv.dir == ROOT / ".shadowenv.d"
  end

  test "inside the build container, shadowenv searches from .shadowenv.d-container and finds the .shadowenv.d nested there — nothing is mounted over the host's" do
    Given
    shadowenv = Dev::ProjectShadowenv.new(ROOT, inside: true)

    Expect
    shadowenv.search_root == ROOT / ".shadowenv.d-container"
    shadowenv.dir == ROOT / ".shadowenv.d-container" / ".shadowenv.d"
  end

  test "the side defaults to this dev's, read from the container marker: #{what}" do
    When
    shadowenv = Dev::ProjectShadowenv.new(ROOT.to_s)

    Then
    1 * Dev::ContainerContext.inside? >> inside
    shadowenv.search_root == expected

    Where
    what          | inside | expected
    "on the host" | false  | ROOT
    "inside"      | true   | ROOT / ".shadowenv.d-container"
  end

  test "both directories are the footprint an adopter ignores, as directory patterns" do
    Expect
    Dev::ProjectShadowenv::GITIGNORE_FOOTPRINT == [".shadowenv.d/", ".shadowenv.d-container/"]
  end
end
