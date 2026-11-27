# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/ui"
require "dev/lifecycle"
require "dev/terminal_owner"
require "pathname"
require "stringio"
require "support/fake_cli_ui_frame"
require "support/fake_cli_ui_spinner"

transform!(RSpock::AST::Transformation)
class Dev::Cli::UiImplTest < Minitest::Test
  include SorbetHelper

  test "#print_header formats and prints the command name" do
    Given
    cli_ui = typed_mock(CLI::UI, class_of: true)

    When "we call print_header"
    Dev::Cli::UiImpl.new(cli_ui:).print_header("./bin/setup.rb")

    Then "cli_ui.fmt is called for bold formatting and cli_ui.puts prints it"
    _ * cli_ui.enable_color = true
    1 * cli_ui.fmt("{{bold:./bin/setup.rb}}")
    1 * cli_ui.puts(anything)
  end

  test "#print_remote_crossing prints the one dim line about leaving for a build host and what it holds of the tree: #{destination}" do
    Given
    cli_ui = typed_mock(CLI::UI, class_of: true)

    When
    Dev::Cli::UiImpl.new(cli_ui:).print_remote_crossing(destination: destination, workspace: "snapshot 0123456789ab")

    Then
    _ * cli_ui.enable_color = true
    1 * cli_ui.fmt("{{gray:→ #{destination}, snapshot 0123456789ab}}")
    1 * cli_ui.puts(anything)

    Where
    destination                   | _
    "on ue-engine-hosted"         | nil
    "in snappy-linux (container)" | nil
  end

  test "#ask_secret is CLI::UI's hidden-input prompt when a terminal is behind stdin, and nil (no question asked) when not" do
    Given "a prompt seam and two stdins"
    cli_ui = typed_mock(CLI::UI, class_of: true)
    prompt = typed_mock(CLI::UI::Prompt, class_of: true)
    tty = StringIO.new
    tty.define_singleton_method(:tty?) { true }
    pipe = StringIO.new

    When "asking at each"
    at_tty = Dev::Cli::UiImpl.new(cli_ui:, prompt:, input: tty).ask_secret("Token")
    at_pipe = Dev::Cli::UiImpl.new(cli_ui:, prompt:, input: pipe).ask_secret("Token")

    Then
    _ * cli_ui.enable_color = true
    _ * prompt.ask_password("Token") >> "ghp_x"
    at_tty == "ghp_x"
    at_pipe.nil?
  end

  # A StdoutRouter double faithful to cli-ui 2.7.0 (and passing for the
  # module at the sig, as typed_mock does): `disable` is one-way — it
  # stops routing but leaves the `write_without_cli_ui` alias behind, so
  # `enabled?` keeps answering true and the next `enable` refuses (dev#523).
  # `routing?` is the truth a test reads.
  class FakeRouter
    attr_reader :log

    def initialize
      @activated = false
      @routing = false
      @log = []
    end

    def is_a?(klass)
      klass == CLI::UI::StdoutRouter.singleton_class || super
    end
    alias kind_of? is_a?

    def enable
      @log << :enable
      return false if @activated

      @activated = true
      @routing = true
    end

    def disable
      @log << :disable
      return false unless @activated

      @routing = false
      true
    end

    def enabled?(_stream = nil)
      @activated
    end

    def routing?
      @routing
    end
  end

  # A CLI::UI that formats nothing and remembers what it printed.
  class RecordingCliUi
    attr_reader :printed

    def initialize
      @printed = []
    end

    def is_a?(klass)
      klass == CLI::UI.singleton_class || super
    end
    alias kind_of? is_a?
    def enable_color=(_value); end

    def fmt(text)
      text
    end

    def puts(text)
      @printed << text
    end
  end

  def ui(frame: FakeCliUiFrame.new, spinner: FakeCliUiSpinner.new, router: FakeRouter.new,
    prompt: CLI::UI::Prompt, input: StringIO.new, cli_ui: RecordingCliUi.new)
    Dev::Cli::UiImpl.new(cli_ui:, frame:, spinner:, router:, prompt:, input:)
  end

  test "#frame is a timed CLI::UI frame around the block, answering what the block answered; the first frame turns the StdoutRouter on and it stays on — cli-ui cannot turn it on twice, and every frame's lines need it (plans#52, dev#523)" do
    Given
    frame = FakeCliUiFrame.new
    router = FakeRouter.new
    ui = ui(frame:, router:)
    seen = []

    When "a verb's three frames in a row, one nested"
    answer = ui.frame("Release: 1.1.0 → 1.2.0") do
      seen << router.routing?
      ui.frame("Cutting v1.2.0") { seen << router.routing? }
      seen << router.routing?
      42
    end
    ui.frame("Publishing v1.2.0") { seen << router.routing? }

    Then "routed in every frame, the last included; never turned off; each frame timed"
    answer == 42
    seen == [true, true, true, true]
    router.log.none?(:disable)
    frame.titles == ["Release: 1.1.0 → 1.2.0", "Cutting v1.2.0", "Publishing v1.2.0"]
    frame.openings.all?(&:timing)
  end

  test "#frame leaves the router on through a raise too: the verb's error report after it is still a frame's line" do
    Given
    frame = FakeCliUiFrame.new
    router = FakeRouter.new

    When
    assert_raises(RuntimeError) { ui(frame:, router:).frame("Cutting v1.2.0") { raise "refused" } }

    Then
    router.routing?
  end

  test "#spin runs the block under a CLI::UI spinner with no debrief; a raise marks it failed and comes back out as itself (dev#514)" do
    Given "a spinner that runs the block, answering as CLI::UI does: true when it returned, false when it raised"
    spinner = FakeCliUiSpinner.new
    ui = ui(spinner:)

    When
    pushed = ui.spin("Pushing main + tag v1.2.0") { :pushed }
    error = assert_raises(RuntimeError) { ui.spin("Creating GitHub release v1.2.0") { raise "HTTP 502" } }

    Then
    pushed == :pushed
    error.message == "HTTP 502"
    spinner.titles == ["Pushing main + tag v1.2.0", "Creating GitHub release v1.2.0"]
    spinner.spins.none?(&:auto_debrief)
  end

  test "#spin turns the StdoutRouter on first: cli-ui runs a spinner's block inside a Capture, which refuses with the router off — silently, the block never running — so a verb whose first word is a spin, not a frame, must not depend on a frame having gone before (plans#52)" do
    Given "a spinner that runs the block, and a router nobody has turned on"
    spinner = FakeCliUiSpinner.new
    router = FakeRouter.new
    ui = ui(spinner:, router:)

    When
    ui.spin("Creating runner group 'ai-flow' at d3mlabs") { :created }

    Then
    router.routing?
  end

  test "#spin whose spinner answers false without the block having raised — the block never ran — raises rather than answering nil as if it had (plans#52)" do
    Given "a spinner that refuses the block"
    spinner = FakeCliUiSpinner.new(refuses_block: true)
    ui = ui(spinner:)

    When
    ui.spin("Creating runner group 'ai-flow' at d3mlabs") { :never }

    Then
    error = raises Dev::Cli::UiImpl::SpinnerRefusedError
    error.message.include?("Creating runner group 'ai-flow' at d3mlabs")
  end

  test "#spin owns the terminal for the block: a child with inherited stdio, a prompt, a frame, a step or another spin under it is refused — #{claimant} (plans#52)" do
    Given
    tty = StringIO.new
    tty.define_singleton_method(:tty?) { true }
    ui = ui(input: tty)

    When
    error = assert_raises(Dev::TerminalOwner::UnderSpinnerError) { ui.spin("Pushing") { under.call(ui) } }

    Then
    error.message.start_with?("#{claimant} would take the terminal under a spinner")
    !Dev::TerminalOwner.spinning?

    Where
    claimant                   | under
    "`sh -c ./bin/package`"    | ->(_) { Dev::Lifecycle::Shell.new.run(["sh", "-c", "./bin/package"], chdir: Pathname(Dir.pwd)) }
    "a prompt"                 | ->(ui) { ui.confirm("Proceed?") }
    "a prompt"                 | ->(ui) { ui.ask_secret("Token") }
    "a prompt"                 | ->(ui) { ui.choose("Which?", ["a", "b"]) }
    "a frame"                  | ->(ui) { ui.frame("Publishing") { :never } }
    "a step"                   | ->(ui) { ui.step("Packaging") { :never } }
    "a spinner"                | ->(ui) { ui.spin("Tagging") { :never } }
  end

  test "#step gives the block the terminal: no spinner, the name before and ✓ after; the router is not touched — a child's fd 1 never was the routed $stdout, and turning it off would lose the bar for good (plans#52, dev#523)" do
    Given
    router = FakeRouter.new
    cli_ui = RecordingCliUi.new
    ui = ui(router:, cli_ui:)
    seen = []
    answer = nil

    When
    ui.frame("Cutting v1.2.0") do
      answer = ui.step("Packaging site") do
        seen << router.routing?
        seen << Dev::TerminalOwner.spinning?
        :packaged
      end
      seen << router.routing?
    end

    Then
    answer == :packaged
    seen == [true, false, true]
    router.log == [:enable]
    cli_ui.printed == ["Packaging site", "{{v}} Packaging site"]
  end

  test "#step that raises prints ✗ and the raise comes back out as itself" do
    Given
    router = FakeRouter.new
    cli_ui = RecordingCliUi.new
    ui = ui(router:, cli_ui:)
    inside = []

    When
    error = assert_raises(RuntimeError) do
      ui.frame("Deploying staging") do
        ui.step("Shipping via run: sh ./stage.sh") { raise "exited 7" }
      ensure
        inside << router.routing?
      end
    end

    Then
    error.message == "exited 7"
    inside == [true]
    cli_ui.printed == ["Shipping via run: sh ./stage.sh", "{{x}} Shipping via run: sh ./stage.sh"]
  end

  test "#confirm asks CLI::UI's yes/no at a terminal, and is nil (nobody to ask) without one (dev#514)" do
    Given
    prompt = typed_mock(CLI::UI::Prompt, class_of: true)
    tty = StringIO.new
    tty.define_singleton_method(:tty?) { true }

    When
    at_tty = ui(prompt:, input: tty).confirm("Proceed?")
    at_pipe = ui(prompt:, input: StringIO.new).confirm("Proceed?")

    Then
    _ * prompt.confirm("Proceed?", default: false) >> false
    at_tty == false
    at_pipe.nil?
  end

  test "#confirm's default is the answer CLI::UI offers first — no unless the caller says yes (dev#533)" do
    Given
    prompt = typed_mock(CLI::UI::Prompt, class_of: true)
    tty = StringIO.new
    tty.define_singleton_method(:tty?) { true }

    When
    stop = ui(prompt:, input: tty).confirm("Stop them too?")
    proceed = ui(prompt:, input: tty).confirm("Proceed?", default: true)

    Then
    1 * prompt.confirm("Stop them too?", default: false) >> true
    1 * prompt.confirm("Proceed?", default: true) >> true
    stop == true
    proceed == true
  end

  test "#choose asks CLI::UI's menu over the options at a terminal, answering the one picked, and is nil (nobody to pick) without one (dev#623)" do
    Given
    prompt = typed_mock(CLI::UI::Prompt, class_of: true)
    tty = StringIO.new
    tty.define_singleton_method(:tty?) { true }

    When
    at_tty = ui(prompt:, input: tty).choose("Which scope?", ["d3mlabs", "~/actions-runner"])
    at_pipe = ui(prompt:, input: StringIO.new).choose("Which scope?", ["d3mlabs", "~/actions-runner"])

    Then
    _ * prompt.ask("Which scope?", options: ["d3mlabs", "~/actions-runner"]) >> "~/actions-runner"
    at_tty == "~/actions-runner"
    at_pipe.nil?
  end

  test "#note prints the text through CLI::UI's formatting (dev#514)" do
    Given
    cli_ui = typed_mock(CLI::UI, class_of: true)

    When
    Dev::Cli::UiImpl.new(cli_ui:).note("{{v}} {{bold:v1.2.0 released!}}")

    Then
    _ * cli_ui.enable_color = true
    1 * cli_ui.fmt("{{v}} {{bold:v1.2.0 released!}}")
    1 * cli_ui.puts(anything)
  end
end
