# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/ruby_build"
require "pathname"

transform!(RSpock::AST::Transformation)
class RubyBuildTest < Minitest::Test
  test "call refuses to run ruby-build under the harness kill-switch (#208)" do
    Given "an armed guard and a build that would otherwise run"
    build = Dev::RubyBuild.new

    When "a build is requested"
    build.call("4.0.6", Pathname("/var/lib/dev/ruby/linux-x86_64/4.0.6"))

    Then "the seam refuses before touching the system"
    error = raises Dev::ProvisioningGuard::ForbiddenError
    error.message.include?("refusing to ruby-build 4.0.6")
    0 * build.system
  end

  test "call installs the brew build libraries, then runs ruby-build into the prefix with the prefix-rpathed env" do
    Given "the guard lifted and the ShadowenvRuby seams answering"
    guard = allow_provisioning
    build = Dev::RubyBuild.new
    Dev::ShadowenvRuby.stubs(:path_with_brew_bin).returns("/home/linuxbrew/.linuxbrew/bin:/usr/bin")
    Dev::ShadowenvRuby.stubs(:ruby_build_env)
      .with({"PATH" => "/home/linuxbrew/.linuxbrew/bin:/usr/bin"}, "4.0.6", prefix: "/var/lib/dev/ruby/linux-x86_64/4.0.6")
      .returns({"PATH" => "/home/linuxbrew/.linuxbrew/bin:/usr/bin", "LDFLAGS" => "-Wl,-rpath,/var/lib/dev/ruby/linux-x86_64/4.0.6/lib"})

    When "a build is requested"
    result = build.call("4.0.6", Pathname("/var/lib/dev/ruby/linux-x86_64/4.0.6"))

    Then "deps are ensured first, then ruby-build runs with that env and its result is returned"
    1 * Dev::ShadowenvRuby.ensure_ruby_build_deps!({"PATH" => "/home/linuxbrew/.linuxbrew/bin:/usr/bin"})
    1 * build.system(
      {"PATH" => "/home/linuxbrew/.linuxbrew/bin:/usr/bin", "LDFLAGS" => "-Wl,-rpath,/var/lib/dev/ruby/linux-x86_64/4.0.6/lib"},
      "ruby-build", "4.0.6", "/var/lib/dev/ruby/linux-x86_64/4.0.6",
    ) >> true
    result == true

    Cleanup
    restore_provisioning_guard(guard)
  end
end
