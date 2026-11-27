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
require "stringio"
require "support/fake_container_engine"
require "support/fake_gh"
require "tmpdir"

# The sealed dispatch: Native yields for the env and hands it back as
# Run(env); Remote runs the one caller shape over the seam — refuse,
# deliver the checkout as a workspace, print the crossing, run — through
# a transport whose far side is scripted (the forge, FakeGh, for the
# Actions runner; the engine, FakeContainerEngine, for the local
# container) and whose delivery is real: a snapshot branch on a temp
# bare origin for the runner, the checkout mounted for the container. It
# never asks for the env: the seam runs on the host.
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
    remote = Dev::Cli::Dispatch::Remote.new(transport: transport(gh, root:, out:), root:, ui:)
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

  test "the crossing line names the transport's destination and the workspace it delivered: the snapshot's short sha" do
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
    remote = Dev::Cli::Dispatch::Remote.new(transport: transport(gh, root:), root:, ui:)

    When
    remote.dispatch(Dev::Lifecycle::VerbInvocation.new(words: ["build", "x"])) { flunk("the env was resolved") }

    Then
    1 * ui.print_remote_crossing(destination: "on ue-engine-hosted", workspace: regexp_matches(/\Asnapshot \h{12}\z/))

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  test "a project without the workflow is refused before anything is pushed, with the copy named" do
    Given
    workspace = Pathname(Dir.mktmpdir("dispatch-"))
    root, origin = checkout_with_origin(workspace)
    gh = FakeGh.new(root:)
    remote = Dev::Cli::Dispatch::Remote.new(transport: transport(gh, root:), root:, ui: typed_mock(Dev::Ui))

    When
    remote.dispatch(Dev::Lifecycle::VerbInvocation.new(words: ["build", "x"])) { nil }

    Then
    error = raises(Dev::Lifecycle::LifecycleWorkflow::WorkflowMissingError)
    error.message.include?("#{root} has no .github/workflows/dev-lifecycle.yml")
    error.message.include?("cp #{Dev::Lifecycle::LifecycleWorkflow.new(root:).source} .github/workflows/dev-lifecycle.yml")
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
    remote = Dev::Cli::Dispatch::Remote.new(transport: transport(gh, root:, out: StringIO.new), root:, ui: Dev::NoUi.new)

    When
    capture_stdout { remote.dispatch(Dev::Lifecycle::VerbInvocation.new(words: ["package", "x"])) { nil } }

    Then
    error = raises(Dev::Cli::Transport::ActionsRunner::RemoteVerbFailedError)
    error.message == "`dev package x` on ue-engine-hosted ended with failure: https://github.com/o/r/actions/runs/42"
    remote_heads(origin).keys == ["refs/heads/main"]

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  test "the local container runs the verb by docker exec in the mounted checkout: the service container mounts the tree at its own path, nothing is pushed, and the origin never changes" do
    Given "a checkout with an origin, a persisted image, and an engine recording what runs in the service container"
    workspace = Pathname(Dir.mktmpdir("dispatch-"))
    root, origin = checkout_with_origin(workspace)
    checkout = Dev::BuildContainer.workspace_path(root)
    heads_before = remote_heads(origin)
    # No service container exists yet: `container inspect` fails, so the
    # dispatch creates one — the run whose mounts are under test.
    engine = recording_engine { |args| args[0, 2] != ["container", "inspect"] }
    ui = typed_mock(Dev::Ui)
    remote = Dev::Cli::Dispatch::Remote.new(
      transport: local_container(engine, root:, image: image(persist: true), token: "gho_host"),
      root:, ui:,
    )

    When
    outcome = remote.dispatch(Dev::Lifecycle::VerbInvocation.new(words: ["build", "cellbound-3d-win64-dev"])) { flunk("the env was resolved") }

    Then "Done; the service container was created with the checkout mounted once, then one exec in the checkout with GH_TOKEN named, the verb its argv; the origin as it was"
    outcome == Dev::Cli::Dispatch::Outcome::Done.new
    1 * ui.print_remote_crossing(destination: "in cellbound-3d-linux (container)", workspace: "the checkout, mounted")
    created = engine.runs.find { |verb, flag, *_rest| verb == "run" && flag == "-d" }
    created.each_cons(2).include?(["-v", "#{checkout}:#{checkout}"])
    created.each_cons(2).count { |flag, mount| flag == "-v" && mount.start_with?(checkout.to_s) } == 1
    exec = engine.runs.find { |verb, *_rest| verb == "exec" }
    exec == ["exec", "-e", "GH_TOKEN", "-w", checkout, Dev::BuildContainer.service_container_name(image(persist: true).ref, root), "dev", "build", "cellbound-3d-win64-dev"]
    engine.run_envs.fetch(engine.runs.index(exec)) == { "GH_TOKEN" => "gho_host" }
    remote_heads(origin) == heads_before
    Dev::Lifecycle::Git.new(root:).capture(["status", "--porcelain"]).strip.empty?

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  test "a non-persisted image runs the verb in a one-shot `docker run --rm` of the image, the container's data root and the checkout mounted, the checkout the workdir" do
    Given
    workspace = Pathname(Dir.mktmpdir("dispatch-"))
    root, _origin = checkout_with_origin(workspace)
    checkout = Dev::BuildContainer.workspace_path(root)
    engine = recording_engine
    remote = Dev::Cli::Dispatch::Remote.new(
      transport: local_container(engine, root:, image: image(persist: false), token: nil),
      root:, ui: Dev::NoUi.new,
    )

    When
    capture_stdout { remote.dispatch(Dev::Lifecycle::VerbInvocation.new(words: ["build", "x"])) { nil } }

    Then
    run = engine.runs.find { |verb, *_rest| verb == "run" }
    run[0, 2] == ["run", "--rm"]
    run.each_cons(2).include?(["-v", "dev-data-root:/var/lib/dev"])
    run.each_cons(2).include?(["-v", "#{checkout}:#{checkout}"])
    run.each_cons(2).include?(["-w", checkout])
    run.include?(image(persist: false).ref)
    run.last(3) == ["dev", "build", "x"]
    engine.runs.none? { |verb, *_rest| verb == "exec" }

    Cleanup
    FileUtils.rm_rf(workspace)
  end

  test "a verb that exits nonzero inside is ContainerVerbFailedError carrying the status" do
    Given
    workspace = Pathname(Dir.mktmpdir("dispatch-"))
    root, _origin = checkout_with_origin(workspace)
    engine = recording_engine(&->(args) { args.fetch(0) == "exec" ? 3 : true })
    remote = Dev::Cli::Dispatch::Remote.new(
      transport: local_container(engine, root:, image: image(persist: true), token: nil),
      root:, ui: Dev::NoUi.new,
    )

    When
    capture_stdout { remote.dispatch(Dev::Lifecycle::VerbInvocation.new(words: ["package", "x"])) { nil } }

    Then
    error = raises(Dev::Cli::Transport::LocalContainer::ContainerVerbFailedError)
    error.message == "`dev package x` in cellbound-3d-linux (container) exited 3"
    error.exit_status == 3

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
      root:, ui: Dev::NoUi.new,
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

  test "the local container refuses before anything runs when the engine does not answer" do
    Given
    workspace = Pathname(Dir.mktmpdir("dispatch-"))
    root, _origin = checkout_with_origin(workspace)
    engine = FakeContainerEngine.new(capture_result: "")
    remote = Dev::Cli::Dispatch::Remote.new(
      transport: local_container(engine, root:, image: image(persist: true), token: nil),
      root:, ui: typed_mock(Dev::Ui),
    )

    When
    remote.dispatch(Dev::Lifecycle::VerbInvocation.new(words: ["build", "x"])) { nil }

    Then
    error = raises(Dev::ProjectContainer::EngineUnavailableError)
    error.message.include?("`dev up` brings it up")
    engine.runs.empty?

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

  # The sync step over a real checkout, its failed-delete report kept
  # off the terminal.
  def quiet_sync_for
    ->(root) { Dev::Lifecycle::SnapshotSync.new(root:, out: StringIO.new) }
  end

  # The runner transport outside an Actions job, whatever the suite's own
  # environment says.
  def transport(gh, root:, out: StringIO.new)
    Dev::Cli::Transport::ActionsRunner.new(
      runner: "ue-engine-hosted",
      runs: Dev::Lifecycle::WorkflowRuns.new(gh:, sleeper: ->(_seconds) { nil }),
      workflow: Dev::Lifecycle::LifecycleWorkflow.new(root:),
      sync_for: quiet_sync_for,
      inside_job: false,
      out:,
    )
  end

  # An engine whose daemon answers `docker info` (12 cpus, 24 GiB) and
  # knows no container; every run succeeds unless the handler says.
  def recording_engine(&handler)
    FakeContainerEngine.new(capture_result: ->(args) { args.first == "info" ? "12 #{24 * 1_073_741_824}" : "" }, &handler)
  end

  # The container transport over a recording engine: the client on the
  # given host OS, the floor passing.
  def local_container(engine, root:, image:, token:, host_os: "darwin", out: StringIO.new)
    containers = Dev::ProjectContainer.new(
      project_root: root,
      client: Dev::BuildContainer.new(engine:, host_os:),
      github_token: Dev::ContainerGithubToken.new(source: -> { token }),
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
    workflow = Dev::Lifecycle::LifecycleWorkflow.new(root:)
    workflow.path.tap { |path| path.dirname.mkpath }.write(workflow.source.read)
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
