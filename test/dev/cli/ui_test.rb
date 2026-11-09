# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/ui"
require "dev/lifecycle"
require "dev/terminal_owner"
require "pathname"
require "stringio"

transform!(RSpock::AST::Transformation)
class Dev::Cli::UiImplTest < Minitest::Test
  include SorbetHelper

  def setup
    @cli_ui = typed_mock(CLI::UI, class_of: true)
    @cli_ui.stubs(:enable_color=)
    @ui = Dev::Cli::UiImpl.new(cli_ui: @cli_ui)
  end

  test "#print_header formats and prints the command name" do
    When "we call print_header"
    @ui.print_header("./bin/setup.rb")

    Then "cli_ui.fmt is called for bold formatting and cli_ui.puts prints it"
    1 * @cli_ui.fmt("{{bold:./bin/setup.rb}}")
    1 * @cli_ui.puts(anything)
  end

  test "#print_remote_crossing prints the one dim line about leaving for a build host at a snapshot: #{destination}" do
    When
    @ui.print_remote_crossing(destination: destination, snapshot: "0123456789ab")

    Then
    1 * @cli_ui.fmt("{{gray:→ #{destination}, snapshot 0123456789ab}}")
    1 * @cli_ui.puts(anything)

    Where
    destination                   | _
    "on ue-engine-hosted"         | nil
    "in snappy-linux (container)" | nil
  end

  test "#ask_secret is CLI::UI's hidden-input prompt when a terminal is behind stdin, and nil (no question asked) when not" do
    Given "a prompt seam and two stdins"
    prompt = typed_mock(CLI::UI::Prompt, class_of: true)
    prompt.stubs(:ask_password).with("Token").returns("ghp_x")
    tty = StringIO.new
    tty.define_singleton_method(:tty?) { true }
    pipe = StringIO.new

    Expect
    Dev::Cli::UiImpl.new(cli_ui: @cli_ui, prompt: prompt, input: tty).ask_secret("Token") == "ghp_x"
    Dev::Cli::UiImpl.new(cli_ui: @cli_ui, prompt: prompt, input: pipe).ask_secret("Token").nil?
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

    def is_a?(klass) = klass == CLI::UI::StdoutRouter.singleton_class || super
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

    def enabled?(_stream = nil) = @activated
    def routing? = @routing
  end

  # A CLI::UI that formats nothing and remembers what it printed.
  class RecordingCliUi
    attr_reader :printed

    def initialize = @printed = []
    def is_a?(klass) = klass == CLI::UI.singleton_class || super
    alias kind_of? is_a?
    def enable_color=(_value); end
    def fmt(text) = text
    def puts(text) = @printed << text
  end

  def ui(frame: typed_mock(CLI::UI::Frame, class_of: true), spinner: typed_mock(CLI::UI::Spinner, class_of: true), router: FakeRouter.new,
    prompt: CLI::UI::Prompt, input: StringIO.new, cli_ui: @cli_ui)
    Dev::Cli::UiImpl.new(cli_ui:, frame:, spinner:, router:, prompt:, input:)
  end

  test "#frame is a timed CLI::UI frame around the block, answering what the block answered; the first frame turns the StdoutRouter on and it stays on — cli-ui cannot turn it on twice, and every frame's lines need it (plans#52, dev#523)" do
    Given
    frame = typed_mock(CLI::UI::Frame, class_of: true)
    frame.stubs(:open).with("Release: 1.1.0 → 1.2.0", timing: true).yields.returns(42)
    frame.stubs(:open).with("Cutting v1.2.0", timing: true).yields.returns(7)
    frame.stubs(:open).with("Publishing v1.2.0", timing: true).yields.returns(9)
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

    Then "routed in every frame, the last included; never turned off"
    answer == 42
    seen == [true, true, true, true]
    router.log.none?(:disable)
  end

  test "#frame leaves the router on through a raise too: the verb's error report after it is still a frame's line" do
    Given
    frame = typed_mock(CLI::UI::Frame, class_of: true)
    frame.stubs(:open).yields
    router = FakeRouter.new

    When
    assert_raises(RuntimeError) { ui(frame:, router:).frame("Cutting v1.2.0") { raise "refused" } }

    Then
    router.routing?
  end

  test "#spin runs the block under a CLI::UI spinner with no debrief; a raise marks it failed and comes back out as itself (dev#514)" do
    Given "a spinner that runs the block, answering as CLI::UI does: true when it returned, false when it raised"
    spinner = typed_mock(CLI::UI::Spinner, class_of: true)
    spinner.stubs(:spin).with("Pushing main + tag v1.2.0", auto_debrief: false).returns(true).yields
    spinner.stubs(:spin).with("Creating GitHub release v1.2.0", auto_debrief: false).yields.returns(false)
    ui = ui(spinner:)

    When
    pushed = ui.spin("Pushing main + tag v1.2.0") { :pushed }
    error = assert_raises(RuntimeError) { ui.spin("Creating GitHub release v1.2.0") { raise "HTTP 502" } }

    Then
    pushed == :pushed
    error.message == "HTTP 502"
  end

  test "#spin owns the terminal for the block: a child with inherited stdio, a prompt, a frame, a step or another spin under it is refused — #{claimant} (plans#52)" do
    Given
    spinner = typed_mock(CLI::UI::Spinner, class_of: true)
    spinner.stubs(:spin).yields.returns(false)
    frame = typed_mock(CLI::UI::Frame, class_of: true)
    frame.stubs(:open).yields
    tty = StringIO.new
    tty.define_singleton_method(:tty?) { true }
    ui = ui(spinner:, frame:, input: tty)

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
    "a frame"                  | ->(ui) { ui.frame("Publishing") { :never } }
    "a step"                   | ->(ui) { ui.step("Packaging") { :never } }
    "a spinner"                | ->(ui) { ui.spin("Tagging") { :never } }
  end

  test "#step gives the block the terminal: no spinner, the name before and ✓ after; the router is not touched — a child's fd 1 never was the routed $stdout, and turning it off would lose the bar for good (plans#52, dev#523)" do
    Given
    router = FakeRouter.new
    frame = typed_mock(CLI::UI::Frame, class_of: true)
    frame.stubs(:open).yields
    cli_ui = RecordingCliUi.new
    ui = ui(frame:, router:, cli_ui:)
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
    frame = typed_mock(CLI::UI::Frame, class_of: true)
    frame.stubs(:open).yields
    cli_ui = RecordingCliUi.new
    ui = ui(frame:, router:, cli_ui:)
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
    prompt.stubs(:confirm).with("Proceed?", default: false).returns(false)
    tty = StringIO.new
    tty.define_singleton_method(:tty?) { true }

    Expect
    ui(prompt:, input: tty).confirm("Proceed?") == false
    ui(prompt:, input: StringIO.new).confirm("Proceed?").nil?
  end

  test "#confirm's default is the answer CLI::UI offers first — no unless the caller says yes (dev#533)" do
    Given
    prompt = typed_mock(CLI::UI::Prompt, class_of: true)
    prompt.expects(:confirm).with("Stop them too?", default: false).returns(true)
    prompt.expects(:confirm).with("Proceed?", default: true).returns(true)
    tty = StringIO.new
    tty.define_singleton_method(:tty?) { true }

    Expect
    ui(prompt:, input: tty).confirm("Stop them too?") == true
    ui(prompt:, input: tty).confirm("Proceed?", default: true) == true
  end

  test "#note prints the text through CLI::UI's formatting (dev#514)" do
    When
    @ui.note("{{v}} {{bold:v1.2.0 released!}}")

    Then
    1 * @cli_ui.fmt("{{v}} {{bold:v1.2.0 released!}}")
    1 * @cli_ui.puts(anything)
  end
end

transform!(RSpock::AST::Transformation)
class Dev::Cli::NoUiTest < Minitest::Test
  test "#print_header writes command name to stdout" do
    Given "a NoUi instance"
    ui = Dev::Cli::NoUi.new

    Expect "print_header writes the command name to stdout"
    assert_output("./bin/setup.rb\n") { ui.print_header("./bin/setup.rb") }
  end

  test "#print_remote_crossing writes the crossing line plain to stdout" do
    Given
    ui = Dev::Cli::NoUi.new

    Expect
    Dev::Cli::Ui::CROSSING_PREFIX == "→ "
    assert_output("→ on ue-engine-hosted, snapshot 0123456789ab\n") do
      ui.print_remote_crossing(destination: "on ue-engine-hosted", snapshot: "0123456789ab")
    end
  end

  test "#ask_secret never asks: nil, nothing written" do
    Given
    ui = Dev::Cli::NoUi.new

    Expect
    assert_output("") { assert_nil(ui.ask_secret("Token")) }
  end

  test "#frame, #spin, #step and #note are plain lines on the given stream, no escape codes: the title, ✓ per spin that returned, a step's name before and ✓ after, the text with its markup stripped (dev#514)" do
    Given
    out = StringIO.new
    ui = Dev::Cli::NoUi.new(out:)

    When
    answer = ui.frame("Releasing v1.2.0") do
      ui.note("{{bold:Base:}} main @ 6c8f60e")
      ui.spin("Pushing main + tag v1.2.0") { :pushed }
      ui.step("Packaging site") { out.puts("packaged site") }
      :done
    end
    ui.note("{{v}} {{bold:v1.2.0 released!}}")

    Then
    answer == :done
    out.string == "Releasing v1.2.0\nBase: main @ 6c8f60e\n✓ Pushing main + tag v1.2.0\nPackaging site\npackaged site\n✓ Packaging site\n✓ v1.2.0 released!\n"
    !out.string.include?("\e[")
  end

  test "#spin and #step that raise write ✗ and the raise comes back out as itself; #confirm is nil — nobody to ask (dev#514)" do
    Given
    out = StringIO.new
    ui = Dev::Cli::NoUi.new(out:)

    When
    spun = assert_raises(RuntimeError) { ui.spin("Creating GitHub release v1.2.0") { raise "HTTP 502" } }
    stepped = assert_raises(RuntimeError) { ui.step("Shipping via run: sh ./stage.sh") { raise "exited 7" } }

    Then
    spun.message == "HTTP 502"
    stepped.message == "exited 7"
    out.string == "✗ Creating GitHub release v1.2.0\nShipping via run: sh ./stage.sh\n✗ Shipping via run: sh ./stage.sh\n"
    ui.confirm("Proceed?").nil?
  end

  test "the plain tier keeps the spinner's rule too: a child with inherited stdio under #spin is refused — so a test catches the misuse the terminal would (plans#52)" do
    Given
    ui = Dev::Cli::NoUi.new(out: StringIO.new)

    When
    error = assert_raises(Dev::TerminalOwner::UnderSpinnerError) do
      ui.spin("Packaging site") { Dev::Lifecycle::Shell.new.run(["true"], chdir: Pathname(Dir.pwd)) }
    end

    Then
    error.message.start_with?("`true` would take the terminal under a spinner")
    !Dev::TerminalOwner.spinning?
  end
end
