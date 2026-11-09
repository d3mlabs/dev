# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/build_container"
require "dev/ui"
require "dev/container_github_token"
require "dev/deps/dependency"
require "dev/cli/dispatch"
require "dev/environment_image"
require "dev/lifecycle"
require "dev/project_container"
require "dev/cli/transport"
require "fileutils"
require "pathname"
require "shellwords"
require "stringio"
require "support/fake_container_engine"
require "support/fake_gh"
require "tmpdir"

# The sealed dispatch: Native yields for the env and hands it back as
# Run(env); Remote carries the verb over a real snapshot branch (a temp
# bare origin) through a transport whose far side is scripted — the forge
# (FakeGh) for the Actions runner, the engine (FakeContainerEngine) for
# the local container — and never asks for the env: the seam runs on the
# host.
transform!(RSpock::AST::Transformation)
class Dev::Cli::DispatchTest < Minitest::Test
  include SorbetHelper

  RUN = { "databaseId" => 42, "url" => "https://github.com/o/r/actions/runs/42", "status" => "queued", "conclusion" => nil }.freeze
  GREEN = RUN.merge("status" => "completed", "conclusion" => "success").freeze

  test "the native dispatch resolves the env and hands it back as Run(env): the seam runs here, unchanged" do
    Given "a native dispatch and a verb's env"
    env = { build: "cellbound-3d-win64-dev", install: "/var/lib/dev/artifacts/x" }
    invocation = Dev::Lifecycle::VerbInvocation.new(words: ["build", "cellbound-3d-win64-dev"])

    When
    outcome = Dev::Cli::Dispatch::Native.new.dispatch(invocation) { env }

    Then "the outcome is Run over the very env"
    outcome.is_a?(Dev::Cli::Dispatch::Outcome::Run)
    outcome.env.equal?(env)
    outcome == Dev::Cli::Dispatch::Outcome::Run.new(env)
  end

  test "the remote dispatch pushes the snapshot, prints the crossing, runs the verb there over the branch, and is Done without ever resolving the env" do
    Given "a checkout with an origin, the project's copy of the workflow, and a forge that lists and finishes the run"
    workspace = Pathname(Dir.mktmpdir("dispatch-"))
    root, origin = checkout_with_origin(workspace)
    install_workflow(root)
    gh = FakeGh.new(root:)
      .answers(["workflow", "run"], with: "")
      .answers(["run", "list"], with: [RUN])
      .answers(["run", "watch"], with: "")
      .answers(["run", "view"], with: GREEN)
    out = StringIO.new
    ui = Dev::NoUi.new
    remote = Dev::Cli::Dispatch::Remote.new(transport: transport(gh, root:, out:), sync: Dev::Lifecycle::SnapshotSync.new(root:, out: StringIO.new), ui:)
    resolved = false
    heads_at_dispatch = nil
    heads = -> { remote_heads(origin) }
    gh.define_singleton_method(:stream) do |argv|
      heads_at_dispatch = heads.call
      capture(argv)
    end

    When
    outcome = capture_stdout { remote.dispatch(Dev::Lifecycle::VerbInvocation.new(words: ["build", "cellbound-3d-win64-dev"])) { resolved = true } }

    Then "Done, the env never asked for; the workflow was dispatched on the snapshot branch with the verb, the label and no fetch, then located by that branch, watched, and read back"
    outcome == Dev::Cli::Dispatch::Outcome::Done.new
    !resolved
    dispatched = gh.calls.find { |call| call.argv.first(2) == ["workflow", "run"] }.argv
    branch = dispatched.fetch(4)
    branch.start_with?("dev/build/ue-engine-hosted/")
    dispatched == ["workflow", "run", "dev-lifecycle.yml", "--ref", branch, "-f", "verbs=build cellbound-3d-win64-dev", "-f", "runner=ue-engine-hosted", "-f", "fetch=false"]
    gh.calls.map { |call| call.argv.first(2) } == [["workflow", "run"], ["run", "list"], ["run", "watch"], ["run", "view"]]
    gh.calls.fetch(1).argv.include?(branch)
    gh.calls.fetch(2).argv == ["run", "watch", "42"]
    heads_at_dispatch.keys.include?("refs/heads/#{branch}")
    remote_heads(origin).keys == ["refs/heads/main"]
    out.string == "dispatched `dev build cellbound-3d-win64-dev` on ue-engine-hosted: https://github.com/o/r/actions/runs/42\n"

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  test "the crossing line names the transport's destination and the snapshot's short sha" do
    Given
    workspace = Pathname(Dir.mktmpdir("dispatch-"))
    root, _origin = checkout_with_origin(workspace)
    install_workflow(root)
    gh = FakeGh.new(root:)
      .answers(["workflow", "run"], with: "")
      .answers(["run", "list"], with: [RUN])
      .answers(["run", "watch"], with: "")
      .answers(["run", "view"], with: GREEN)
    ui = typed_mock(Dev::Ui)
    remote = Dev::Cli::Dispatch::Remote.new(transport: transport(gh, root:), sync: Dev::Lifecycle::SnapshotSync.new(root:, out: StringIO.new), ui:)
    crossing = nil
    ui.expects(:print_remote_crossing).with { |destination:, snapshot:| crossing = [destination, snapshot] }

    When
    remote.dispatch(Dev::Lifecycle::VerbInvocation.new(words: ["build", "x"])) { flunk("the env was resolved") }

    Then
    crossing.fetch(0) == "on ue-engine-hosted"
    crossing.fetch(1).match?(/\A\h{12}\z/)

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  test "a project without the workflow is refused before anything is pushed, with the copy named" do
    Given
    workspace = Pathname(Dir.mktmpdir("dispatch-"))
    root, origin = checkout_with_origin(workspace)
    gh = FakeGh.new(root:)
    remote = Dev::Cli::Dispatch::Remote.new(transport: transport(gh, root:), sync: Dev::Lifecycle::SnapshotSync.new(root:, out: StringIO.new), ui: typed_mock(Dev::Ui))

    When
    remote.dispatch(Dev::Lifecycle::VerbInvocation.new(words: ["build", "x"])) { nil }

    Then
    error = raises(Dev::Lifecycle::LifecycleWorkflow::WorkflowMissingError)
    error.message.include?("#{root} has no .github/workflows/dev-lifecycle.yml")
    error.message.include?("cp #{Dev::Lifecycle::LifecycleWorkflow::SOURCE} .github/workflows/dev-lifecycle.yml")
    gh.calls.empty?
    remote_heads(origin).keys == ["refs/heads/main"]

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  test "a run that ends red is RemoteVerbFailedError naming the verb, the label, the verdict and the page; the branch is still deleted" do
    Given
    workspace = Pathname(Dir.mktmpdir("dispatch-"))
    root, origin = checkout_with_origin(workspace)
    install_workflow(root)
    gh = FakeGh.new(root:)
      .answers(["workflow", "run"], with: "")
      .answers(["run", "list"], with: [RUN])
      .answers(["run", "watch"], with: "")
      .answers(["run", "view"], with: RUN.merge("status" => "completed", "conclusion" => "failure"))
    remote = Dev::Cli::Dispatch::Remote.new(transport: transport(gh, root:, out: StringIO.new), sync: Dev::Lifecycle::SnapshotSync.new(root:, out: StringIO.new), ui: Dev::NoUi.new)

    When
    capture_stdout { remote.dispatch(Dev::Lifecycle::VerbInvocation.new(words: ["package", "x"])) { nil } }

    Then
    error = raises(Dev::Cli::Transport::ActionsRunner::RemoteVerbFailedError)
    error.message == "`dev package x` on ue-engine-hosted ended with failure: https://github.com/o/r/actions/runs/42"
    remote_heads(origin).keys == ["refs/heads/main"]

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  test "the local container runs the verb by docker exec over the snapshot: the container fetches the branch into its own workspace with gh's auth, resets to the sha, and the branch is deleted after" do
    Given "a checkout with an origin, a persisted image, and an engine recording what runs in the service container"
    workspace = Pathname(Dir.mktmpdir("dispatch-"))
    root, origin = checkout_with_origin(workspace)
    engine = recording_engine
    heads_at_exec = nil
    heads = -> { remote_heads(origin) }
    engine.define_singleton_method(:status) do |args, env: {}, **opts|
      heads_at_exec = heads.call if args.fetch(0) == "exec"
      super(args, env:, **opts)
    end
    ui = typed_mock(Dev::Ui)
    crossing = nil
    ui.expects(:print_remote_crossing).with { |destination:, snapshot:| crossing = [destination, snapshot] }
    remote = Dev::Cli::Dispatch::Remote.new(
      transport: local_container(engine, root:, image: image(persist: true), token: "gho_host"),
      sync: Dev::Lifecycle::SnapshotSync.new(root:, out: StringIO.new), ui:,
    )

    When
    outcome = remote.dispatch(Dev::Lifecycle::VerbInvocation.new(words: ["build", "cellbound-3d-win64-dev"])) { flunk("the env was resolved") }

    Then "Done; the service container was brought up (no checkout mounted), then one exec with GH_TOKEN named, running the workspace program ending in the verb"
    outcome == Dev::Cli::Dispatch::Outcome::Done.new
    crossing.fetch(0) == "in cellbound-3d-linux (container)"
    exec = engine.runs.find { |verb, *_rest| verb == "exec" }
    exec[0, 3] == ["exec", "-e", "GH_TOKEN"]
    exec[4, 2] == ["sh", "-c"]
    engine.run_envs.fetch(engine.runs.index(exec)) == { "GH_TOKEN" => "gho_host" }
    engine.runs.none? { |*run| run.flatten.include?("#{root}:/project") }
    script = exec.last
    branch = heads_at_exec.keys.find { |ref| ref.start_with?("refs/heads/dev/build/container/") }
    !branch.nil?
    script.include?("cd #{Dev::BuildContainer::DATA_ROOT_MOUNT}/workspaces/checkout-#{Dev::BuildContainer.workspace_id(root)}")
    script.include?("git -c credential.helper= -c #{Shellwords.escape("credential.helper=!gh auth git-credential")}")
    script.include?("fetch -q --no-tags https://github.com/o/r.git #{branch}")
    script.include?("git reset -q --hard #{heads_at_exec.fetch(branch)}")
    script.end_with?("exec dev build cellbound-3d-win64-dev\n")
    crossing.fetch(1) == heads_at_exec.fetch(branch)[0, 12]
    remote_heads(origin).keys == ["refs/heads/main"]

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  test "a non-persisted image runs the verb in a one-shot `docker run --rm` of the image, the container's data root mounted and no checkout" do
    Given
    workspace = Pathname(Dir.mktmpdir("dispatch-"))
    root, _origin = checkout_with_origin(workspace)
    engine = recording_engine
    remote = Dev::Cli::Dispatch::Remote.new(
      transport: local_container(engine, root:, image: image(persist: false), token: nil),
      sync: Dev::Lifecycle::SnapshotSync.new(root:, out: StringIO.new), ui: Dev::NoUi.new,
    )

    When
    capture_stdout { remote.dispatch(Dev::Lifecycle::VerbInvocation.new(words: ["build", "x"])) { nil } }

    Then
    run = engine.runs.find { |verb, *_rest| verb == "run" }
    run[0, 2] == ["run", "--rm"]
    run.each_cons(2).include?(["-v", "dev-data-root:/var/lib/dev"])
    run.each_cons(2).none? { |flag, value| flag == "-v" && value.start_with?(root.to_s) }
    run.include?(image(persist: false).ref)
    run.last.end_with?("exec dev build x\n")
    engine.runs.none? { |verb, *_rest| verb == "exec" }

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  test "a verb that exits nonzero inside is ContainerVerbFailedError carrying the status; the branch is still deleted" do
    Given
    workspace = Pathname(Dir.mktmpdir("dispatch-"))
    root, origin = checkout_with_origin(workspace)
    engine = recording_engine(&->(args) { args.fetch(0) == "exec" ? 3 : true })
    remote = Dev::Cli::Dispatch::Remote.new(
      transport: local_container(engine, root:, image: image(persist: true), token: nil),
      sync: Dev::Lifecycle::SnapshotSync.new(root:, out: StringIO.new), ui: Dev::NoUi.new,
    )

    When
    capture_stdout { remote.dispatch(Dev::Lifecycle::VerbInvocation.new(words: ["package", "x"])) { nil } }

    Then
    error = raises(Dev::Cli::Transport::LocalContainer::ContainerVerbFailedError)
    error.message == "`dev package x` in cellbound-3d-linux (container) exited 3"
    error.exit_status == 3
    remote_heads(origin).keys == ["refs/heads/main"]

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  test "`--fetch` copies the artifact out of the container's data root into the host's store through a one-shot container — unless the two are one (Linux)" do
    Given "a data root for this test, and an engine on #{host_os}"
    workspace = Pathname(Dir.mktmpdir("dispatch-"))
    root, _origin = checkout_with_origin(workspace)
    original = ENV["DEV_DATA_ROOT"]
    ENV["DEV_DATA_ROOT"] = (workspace / "data").to_s
    into = workspace / "data" / "artifacts" / "cellbound-3d" / "cellbound-3d-win64-dev"
    engine = recording_engine
    out = StringIO.new
    remote = Dev::Cli::Dispatch::Remote.new(
      transport: local_container(engine, root:, image: image(persist: true), token: nil, host_os:, out:),
      sync: Dev::Lifecycle::SnapshotSync.new(root:, out: StringIO.new), ui: Dev::NoUi.new,
    )
    invocation = Dev::Lifecycle::VerbInvocation.new(
      words: ["package", "cellbound-3d-win64-dev"], fetch: Dev::Lifecycle::ArtifactFetch.new(name: "cellbound-3d-win64-dev", into:),
    )

    When
    capture_stdout { remote.dispatch(invocation) { nil } }

    Then
    copies = engine.runs.select { |verb, *_rest| verb == "cp" }
    copies.size == copies_expected
    copies.all? { |_verb, from, to| from.end_with?(":/var/lib/dev/artifacts/cellbound-3d/cellbound-3d-win64-dev/.") && to == into.to_s }
    copies.all? { |_verb, from, _to| from.start_with?(Dev::BuildContainer.service_container_name(image(persist: true).ref, root) + "-cold-") }
    out.string == "fetched cellbound-3d-win64-dev → #{into}\n"

    Cleanup
    ENV["DEV_DATA_ROOT"] = original
    FileUtils.rm_rf(workspace)

    Where
    host_os  | copies_expected
    "darwin" | 1
    "linux"  | 0
  end

  test "the local container refuses before anything is pushed when the engine does not answer" do
    Given
    workspace = Pathname(Dir.mktmpdir("dispatch-"))
    root, origin = checkout_with_origin(workspace)
    engine = FakeContainerEngine.new(capture_result: "")
    remote = Dev::Cli::Dispatch::Remote.new(
      transport: local_container(engine, root:, image: image(persist: true), token: nil),
      sync: Dev::Lifecycle::SnapshotSync.new(root:, out: StringIO.new), ui: typed_mock(Dev::Ui),
    )

    When
    remote.dispatch(Dev::Lifecycle::VerbInvocation.new(words: ["build", "x"])) { nil }

    Then
    error = raises(Dev::ProjectContainer::EngineUnavailableError)
    error.message.include?("`dev up` brings it up")
    engine.runs.empty?
    remote_heads(origin).keys == ["refs/heads/main"]

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  test "Run outcomes compare by their env; Done outcomes are all equal; the two never equal each other" do
    Given
    run = Dev::Cli::Dispatch::Outcome::Run.new("a")
    same = Dev::Cli::Dispatch::Outcome::Run.new("a")
    other = Dev::Cli::Dispatch::Outcome::Run.new("b")
    done = Dev::Cli::Dispatch::Outcome::Done.new

    Expect
    run == same
    run.eql?(same)
    run.hash == same.hash
    run != other
    run != done
    done == Dev::Cli::Dispatch::Outcome::Done.new
    done.hash == Dev::Cli::Dispatch::Outcome::Done.new.hash
    done != run
    done != "done"
  end

  test "native dispatches are all equal, and no other value" do
    Expect
    Dev::Cli::Dispatch::Native.new == Dev::Cli::Dispatch::Native.new
    Dev::Cli::Dispatch::Native.new.hash == Dev::Cli::Dispatch::Native.new.hash
    Dev::Cli::Dispatch::Native.new != Dev::Cli::Dispatch::Outcome::Done.new
  end

  test "the dispatch, its outcome and the transport are sealed: a variant declared elsewhere is refused" do
    When "including the sealed module outside its declaring file"
    Class.new { include sealed }

    Then
    raises RuntimeError

    Where
    sealed
    Dev::Cli::Dispatch
    Dev::Cli::Dispatch::Outcome
    Dev::Cli::Transport
  end

  test "#{variant} is final: subclassing raises" do
    When
    Class.new(variant)

    Then
    raises RuntimeError

    Where
    variant
    Dev::Cli::Dispatch::Native
    Dev::Cli::Dispatch::Remote
    Dev::Cli::Dispatch::Outcome::Run
    Dev::Cli::Dispatch::Outcome::Done
    Dev::Cli::Transport::ActionsRunner
    Dev::Cli::Transport::LocalContainer
  end

  private

  def transport(gh, root:, out: StringIO.new)
    Dev::Cli::Transport::ActionsRunner.new(
      runner: "ue-engine-hosted",
      runs: Dev::Lifecycle::WorkflowRuns.new(gh:, sleeper: ->(_seconds) { nil }),
      workflow: Dev::Lifecycle::LifecycleWorkflow.new(root:),
      out:,
    )
  end

  # An engine whose daemon answers `docker info` (12 cpus, 24 GiB) and
  # knows no container; every run succeeds unless the handler says.
  def recording_engine(&handler)
    FakeContainerEngine.new(capture_result: ->(args) { args.first == "info" ? "12 #{24 * 1_073_741_824}" : "" }, &handler)
  end

  # The container transport over a recording engine: the client on the
  # given host OS, the repo resolved without gh, the floor passing.
  def local_container(engine, root:, image:, token:, host_os: "darwin", out: StringIO.new)
    containers = Dev::ProjectContainer.new(
      project_root: root,
      client: Dev::BuildContainer.new(engine:, host_os:),
      github_token: Dev::ContainerGithubToken.new(source: -> { token }),
      repo_resolver: -> { "o/r" },
    )
    Dev::Cli::Transport::LocalContainer.new(image:, containers:, out:)
  end

  def image(persist:)
    Dev::EnvironmentImage.from_pin(
      Dev::Deps::Dependency.new(
        name: "cellbound-3d-linux", integration: :image, group: :app, version: "ue5.8-3", hash: "SHA256=#{"a" * 64}",
        metadata: {
          "from" => "ghcr.io/d3mlabs/unreal-engine-build-base", "platform" => "linux/amd64", "platforms" => ["linux/amd64"],
          "registry" => "ghcr.io/d3mlabs", "apt" => [], "persist" => persist,
        },
      ),
    )
  end

  def install_workflow(root)
    Dev::Lifecycle::LifecycleWorkflow.new(root:).path.tap { |path| path.dirname.mkpath }.write(Dev::Lifecycle::LifecycleWorkflow::SOURCE.read)
  end

  def checkout_with_origin(workspace)
    origin = workspace / "origin.git"
    root = workspace / "checkout"
    Dev::Lifecycle::Git.new(root: workspace).capture(["init", "-q", "--bare", origin.to_s])
    root.mkpath
    git = Dev::Lifecycle::Git.new(root:)
    git.capture(["init", "-q", "-b", "main"])
    (root / "a.txt").write("a\n")
    git.capture(["add", "a.txt"])
    git.capture(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "one"])
    git.capture(["remote", "add", "origin", origin.to_s])
    git.capture(["push", "-q", "-u", "origin", "main"])
    [root, origin]
  end

  def remote_heads(origin)
    Dev::Lifecycle::Git.new(root: origin).capture(["for-each-ref", "--format=%(refname) %(objectname)", "refs/heads/"])
      .lines.to_h { |line| line.strip.split(" ", 2) }
  end

  def capture_stdout
    previous = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = previous
  end
end
