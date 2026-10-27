# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/shared_umask"

transform!(RSpock::AST::Transformation)
class Dev::SharedUmaskTest < Minitest::Test
  def setup
    @before = File.umask
  end

  def teardown
    File.umask(@before)
    super
  end

  test "on Linux dev's process writes group-shared: umask 002, whatever the login's was" do
    Given "a login umask of 022"
    File.umask(0o022)

    When
    previous = Dev::SharedUmask.apply!(host_os: "linux")

    Then
    File.umask == 0o002
    previous == 0o022
  end

  test "elsewhere the process umask is left as the login set it" do
    Given
    File.umask(0o022)

    When
    previous = Dev::SharedUmask.apply!(host_os: "darwin")

    Then
    File.umask == 0o022
    previous == 0o022
  end

  test "the shared umask is 002" do
    Expect
    Dev::SharedUmask::UMASK == 0o002
  end
end
