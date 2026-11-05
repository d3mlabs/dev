# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/dispatch"

transform!(RSpock::AST::Transformation)
class Dev::DispatchTest < Minitest::Test
  test "the native dispatch hands the env back as Run(env): the seam runs here, unchanged" do
    Given "a native dispatch and a verb's env"
    env = { build: "cellbound-3d-win64-dev", install: "/var/lib/dev/artifacts/x" }

    When
    outcome = Dev::Dispatch::Native.new.dispatch(env)

    Then "the outcome is Run over the very env"
    outcome.is_a?(Dev::Dispatch::Outcome::Run)
    outcome.env.equal?(env)
    outcome == Dev::Dispatch::Outcome::Run.new(env)
  end

  test "Run outcomes compare by their env; Done outcomes are all equal; the two never equal each other" do
    Given
    run = Dev::Dispatch::Outcome::Run.new("a")
    same = Dev::Dispatch::Outcome::Run.new("a")
    other = Dev::Dispatch::Outcome::Run.new("b")
    done = Dev::Dispatch::Outcome::Done.new

    Expect
    run == same
    run.eql?(same)
    run.hash == same.hash
    run != other
    run != done
    done == Dev::Dispatch::Outcome::Done.new
    done.hash == Dev::Dispatch::Outcome::Done.new.hash
    done != run
    done != "done"
  end

  test "native dispatches are all equal, and no other value" do
    Expect
    Dev::Dispatch::Native.new == Dev::Dispatch::Native.new
    Dev::Dispatch::Native.new.hash == Dev::Dispatch::Native.new.hash
    Dev::Dispatch::Native.new != Dev::Dispatch::Outcome::Done.new
  end

  test "the dispatch and its outcome are sealed: a variant declared elsewhere is refused" do
    When "including the sealed module outside its declaring file"
    Class.new { include Dev::Dispatch }

    Then
    raises RuntimeError
  end

  test "the outcome is sealed too" do
    When
    Class.new { include Dev::Dispatch::Outcome }

    Then
    raises RuntimeError
  end

  test "#{variant} is final: subclassing raises" do
    When
    Class.new(variant)

    Then
    raises RuntimeError

    Where
    variant
    Dev::Dispatch::Native
    Dev::Dispatch::Outcome::Run
    Dev::Dispatch::Outcome::Done
  end
end
