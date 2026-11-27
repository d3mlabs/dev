# typed: false
# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

# The `d3mlabs/dev/up` action's shell, run against a fake `brew` on PATH.
# The steps are inline bash, so the test reads them out of action.yml and
# runs them as the job would.
transform!(RSpock::AST::Transformation)
class UpActionTest < Minitest::Test
  ACTION = File.expand_path("../../up/action.yml", __dir__)

  # A `brew` that records each call to %<calls>s and refuses the first
  # %<refusals>d of each subcommand the way brew refuses a concurrent one —
  # outright, not by waiting on its lock — then succeeds.
  FAKE_BREW = <<~'SH'
    #!/bin/sh
    echo "$*" >> "%<calls>s"
    count=$(grep -c "^$1" "%<calls>s")
    if [ "$count" -le %<refusals>d ]; then
      case "$1" in
        update) echo "Error: Another \`brew update\` process is already running." >&2 ;;
        upgrade) echo "Error: A \`brew upgrade\` process has already locked dev." >&2 ;;
      esac
      exit 1
    fi
    echo "ok $1"
  SH

  # The named step's `run:` script.
  def step_script(name)
    steps = YAML.safe_load(File.read(ACTION)).fetch("runs").fetch("steps")
    steps.find { |step| step["name"] == name }.fetch("run")
  end

  # FAKE_BREW installed on a bin directory under dir; returns that directory.
  def fake_brew(dir, refusals:)
    bin = File.join(dir, "bin")
    FileUtils.mkdir_p(bin)
    File.write(File.join(dir, "calls"), "")
    File.write(File.join(bin, "brew"), format(FAKE_BREW, calls: File.join(dir, "calls"), refusals: refusals))
    File.chmod(0o755, File.join(bin, "brew"))
    bin
  end

  test "Upgrade dev waits its turn when another slot's brew holds the lock, then runs update and upgrade once each more" do
    Given "a brew that refuses the first update and the first upgrade as a concurrent one"
    dir = Dir.mktmpdir("dev-up-action-")
    bin = fake_brew(dir, refusals: 1)

    When
    out, err, status = Open3.capture3({ "PATH" => "#{bin}:#{ENV.fetch("PATH")}", "BREW_WAIT_SECONDS" => "0" }, "bash", "-e", "-o", "pipefail", "-c", step_script("Upgrade dev"))

    Then "the step succeeds, having retried each command exactly once"
    status.success?
    File.read(File.join(dir, "calls")).lines(chomp: true) == ["update", "update", "upgrade d3mlabs/d3mlabs/dev", "upgrade d3mlabs/d3mlabs/dev"]
    out.include?("ok update") && out.include?("ok upgrade")
    err.empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "Upgrade dev gives up on a lock nobody releases, with brew's words" do
    Given "a brew that refuses every call as a concurrent one"
    dir = Dir.mktmpdir("dev-up-action-")
    bin = fake_brew(dir, refusals: 1000)

    When
    _out, err, status = Open3.capture3({ "PATH" => "#{bin}:#{ENV.fetch("PATH")}", "BREW_WAIT_SECONDS" => "0" }, "bash", "-e", "-o", "pipefail", "-c", step_script("Upgrade dev"))

    Then "it stops at the retry budget, never reaching upgrade"
    !status.success?
    err.include?("Another `brew update` process is already running")
    File.read(File.join(dir, "calls")).lines.count == 24

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "Upgrade dev fails on any other brew error, with brew's words" do
    Given "a brew whose update fails for a reason that is not a lock"
    dir = Dir.mktmpdir("dev-up-action-")
    bin = File.join(dir, "bin")
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, "brew"), "#!/bin/sh\necho 'fatal: unable to access github.com' >&2\nexit 1\n")
    File.chmod(0o755, File.join(bin, "brew"))

    When
    _out, err, status = Open3.capture3({ "PATH" => "#{bin}:#{ENV.fetch("PATH")}", "BREW_WAIT_SECONDS" => "0" }, "bash", "-e", "-o", "pipefail", "-c", step_script("Upgrade dev"))

    Then
    !status.success?
    err.include?("fatal: unable to access github.com")

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
