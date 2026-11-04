# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/lifecycle"
require "support/lifecycle_fixtures"
require "pathname"

transform!(RSpock::AST::Transformation)
class Dev::Lifecycle::NonePackagerTest < Minitest::Test
  include LifecycleFixtures

  test "a none target is never packaged: reaching its packager is an error naming the target" do
    When
    Dev::Lifecycle::NonePackager.new.package(build("cellbound-3d-win64-dev"), Pathname("/install"), Pathname("/store/x"))

    Then
    error = raises(Dev::Lifecycle::NonePackager::NeverPackagedError)
    error.message.include?("target 'cellbound-3d' declares `packager: none`")
  end

  test "none is a value and renders as its name" do
    Expect
    Dev::Lifecycle::NonePackager.new == Dev::Lifecycle::NonePackager.new
    Dev::Lifecycle::NonePackager.new.hash == Dev::Lifecycle::NonePackager.new.hash
    Dev::Lifecycle::NonePackager.new.to_s == "none"
    Dev::Lifecycle::NonePackager.new != Dev::Lifecycle::AsIsPackager.new
  end
end
