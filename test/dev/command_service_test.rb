# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/command_service"
require "dev/command"
require "pathname"

# Builtin fake whose traits drive the service's guard/stamp decisions and
# whose call records the dispatch.
class ServiceFakeBuiltin < Dev::BuiltinCommand
  attr_reader :calls

  def initialize(staleness_exempt: false, stamps: false)
    @staleness_exempt = staleness_exempt
    @stamps = stamps
    @calls = []
  end

  def desc = "a builtin"

  def staleness_exempt? = @staleness_exempt

  def stamps? = @stamps

  def call(args:, context:)
    @calls << [args, context]
  end
end unless defined?(ServiceFakeBuiltin)

transform!(RSpock::AST::Transformation)
class Dev::CommandServiceTest < Minitest::Test
  include SorbetHelper

  def build_service(builtins:, dependency_service:, executor: Dev::CommandExecutor.new)
    Dev::CommandService.new(
      repository: Dev::CommandRepository.new(builtins: builtins, project_commands: {}),
      executor: executor,
      dependency_service: dependency_service,
    )
  end

  def fake_context
    Dev::ExecutionContext.new(
      ui: typed_mock(Dev::Cli::Ui),
      ruby_version: "4.0.1",
      project_root: Pathname.new("/tmp/service-test"),
    )
  end

  def fake_dependency_service
    dependency_service = typed_mock(Dev::DependencyService)
    dependency_service.stubs(:guard!)
    dependency_service.stubs(:lock!)
    dependency_service
  end

  test "execute fetches the command, dispatches it, and passes args and context through" do
    Given "a service over one builtin"
    builtin = ServiceFakeBuiltin.new(staleness_exempt: true)
    service = build_service(builtins: { "deps" => builtin }, dependency_service: fake_dependency_service)
    context = fake_context

    When "executing the command"
    service.execute("deps", args: ["path", "xcode"], context: context)

    Then "the builtin ran once with the args and context"
    builtin.calls == [[["path", "xcode"], context]]
  end

  test "execute raises CommandNotFoundError (the repository's own) for an unknown name" do
    Given "a service over an empty repository"
    service = build_service(builtins: {}, dependency_service: fake_dependency_service)

    When "executing an unknown command"
    service.execute("nonexistent", args: [], context: fake_context)

    Then "the error bubbles under its native namespace"
    raises Dev::CommandRepository::CommandNotFoundError
  end

  test "execute guards staleness before a non-exempt command" do
    Given "a non-exempt builtin and an expecting dependency service"
    dependency_service = typed_mock(Dev::DependencyService)
    dependency_service.expects(:guard!).once
    service = build_service(
      builtins: { "build" => ServiceFakeBuiltin.new(staleness_exempt: false) },
      dependency_service: dependency_service,
    )

    When "executing"
    service.execute("build", args: [], context: fake_context)

    Then "the expectation on the guard holds"
    true
  end

  test "execute skips the guard for a staleness-exempt command" do
    Given "an exempt builtin (it IS the remediation) and a strict dependency service"
    dependency_service = typed_mock(Dev::DependencyService)
    dependency_service.expects(:guard!).never
    dependency_service.stubs(:lock!)
    service = build_service(
      builtins: { "update-deps" => ServiceFakeBuiltin.new(staleness_exempt: true) },
      dependency_service: dependency_service,
    )

    When "executing"
    service.execute("update-deps", args: [], context: fake_context)

    Then "the guard was never consulted"
    true
  end

  test "execute records the installed stamp after a stamping command succeeds" do
    Given "a stamping builtin and an expecting dependency service"
    dependency_service = typed_mock(Dev::DependencyService)
    dependency_service.stubs(:guard!)
    dependency_service.expects(:lock!).once
    service = build_service(
      builtins: { "install-deps" => ServiceFakeBuiltin.new(staleness_exempt: true, stamps: true) },
      dependency_service: dependency_service,
    )

    When "executing"
    service.execute("install-deps", args: [], context: fake_context)

    Then "the stamp was recorded"
    true
  end

  test "execute never stamps for a non-stamping command" do
    Given "a plain builtin and a strict dependency service"
    dependency_service = typed_mock(Dev::DependencyService)
    dependency_service.stubs(:guard!)
    dependency_service.expects(:lock!).never
    service = build_service(
      builtins: { "deps" => ServiceFakeBuiltin.new },
      dependency_service: dependency_service,
    )

    When "executing"
    service.execute("deps", args: [], context: fake_context)

    Then "no stamp was recorded"
    true
  end

  test "a failed execution skips the stamp" do
    Given "a stamping command whose executor raises the child's failure"
    dependency_service = typed_mock(Dev::DependencyService)
    dependency_service.stubs(:guard!)
    dependency_service.expects(:lock!).never
    executor = typed_mock(Dev::CommandExecutor)
    executor.stubs(:execute).raises(Dev::CommandRunner::CommandFailedError.new(exit_status: 7))
    service = build_service(
      builtins: { "up" => ServiceFakeBuiltin.new(staleness_exempt: true, stamps: true) },
      dependency_service: dependency_service,
      executor: executor,
    )

    When "executing"
    service.execute("up", args: [], context: fake_context)

    Then "the failure bubbled and the stamp was skipped"
    raises Dev::CommandRunner::CommandFailedError
  end

  test "visible_commands serves the repository's usage view" do
    Given "a service over one visible builtin"
    builtin = ServiceFakeBuiltin.new
    service = build_service(builtins: { "deps" => builtin }, dependency_service: fake_dependency_service)

    Expect "the usage view flows through the service (the onion rule)"
    service.visible_commands == { "deps" => builtin }
  end
end
