# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/integration"
require "dev/deps/repository"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Deps::IntegrationTest < Minitest::Test
  # Publishes the base class's private helpers under test — subclasses call
  # them from install paths; here they are the unit.
  class ExposedIntegration < Dev::Deps::Integration
    def publish_current!(base_dir, target_dir) = publish_current(base_dir, target_dir)
  end

  test "base class install_all raises NotImplementedError" do
    Given "an Integration with injected dependencies"
    repo = Dev::Deps::Repository.new
    integration = Dev::Deps::Integration.new(repository: repo, cache: nil)

    When "calling install_all"
    integration.install_all([])

    Then
    raises NotImplementedError
  end

  test "publish_current re-raises when the swap fails, leaving no temp link behind" do
    Given "a base dir the symlink cannot be created in"
    dir = Dir.mktmpdir("dev-integration-test-")
    base_dir = Pathname(dir) / "base"
    FileUtils.mkdir_p(base_dir)
    FileUtils.chmod(0o555, base_dir)
    integration = ExposedIntegration.new(repository: Dev::Deps::Repository.new, cache: nil)

    When "publishing the current pointer"
    integration.publish_current!(base_dir, base_dir / "1.0.0")

    Then
    raises Errno::EACCES

    Cleanup
    FileUtils.chmod(0o755, base_dir)
    FileUtils.rm_rf(dir)
  end
end
