# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/cli/build_selector"
require "dev/cli/flag_vocabulary"
require "dev/cli/command"
require "dev/lifecycle"
require "support/lifecycle_fixtures"

transform!(RSpock::AST::Transformation)
class Dev::Cli::BuildSelectorTest < Minitest::Test
  include LifecycleFixtures

  # A node declaring exactly the selector's flags, so the words parse the
  # way a verb's argv does.
  class SelectingVerb < Dev::Cli::LifecycleCommand
    Env = type_member { { fixed: String } }

    def desc
      "selects"
    end

    def flags
      Dev::Cli::BuildSelector::FLAGS
    end

    def before(args:, context:)
      Dev::Cli::Dispatch::Outcome::Done.new
    end

    def seam(env, context:); end

    def after(env, context:); end
  end

  def select(*words)
    Dev::Cli::BuildSelector.new(targets: all_targets).select(parsed_args(SelectingVerb.new, words))
  end

  test "#{words.inspect} selects #{expected}" do
    Expect
    select(*words).name == expected

    Where
    words                                                    | expected
    # bare: the first declared target, its first platform and config
    []                                                       | "cellbound-3d-win64-dev"
    # a pattern fills its omitted axes with the target's defaults
    ["cellbound-3d"]                                         | "cellbound-3d-win64-dev"
    ["cellbound-3d-linux64"]                                 | "cellbound-3d-linux64-dev"
    ["cellbound-3d-release"]                                 | "cellbound-3d-win64-release"
    ["cellbound-3d-linux64-release"]                         | "cellbound-3d-linux64-release"
    ["cellbound-3d-steamworks"]                              | "cellbound-3d-steamworks-win64-release"
    ["rspock"]                                               | "rspock"
    # the long form
    ["--target", "cellbound-3d-server"]                      | "cellbound-3d-server-linux64-dev"
    ["--target", "cellbound-3d", "--config", "release"]      | "cellbound-3d-win64-release"
    ["--target", "cellbound-3d", "--platform", "linux64"]    | "cellbound-3d-linux64-dev"
    # flags refine a positional's omitted axes, and the first target's
    ["cellbound-3d", "--config", "release"]                  | "cellbound-3d-win64-release"
    ["cellbound-3d-linux64", "--config", "release"]          | "cellbound-3d-linux64-release"
    ["--platform", "linux64", "--config", "release"]         | "cellbound-3d-linux64-release"
  end

  test "the flags are consumed into the build: nothing of them is a positional" do
    Given
    args = parsed_args(SelectingVerb.new, ["--target", "rspock"])

    Expect
    args.positionals == []
    Dev::Cli::BuildSelector.new(targets: all_targets).select(args) == build("rspock")
    Dev::Cli::BuildSelector.new(targets: all_targets).targets == all_targets
  end

  test "#{words.inspect} is refused with #{error}: #{why}" do
    When
    select(*words)

    Then
    raised = raises(error)
    raised.message.include?(message)

    Where
    words                                           | error                                                  | message                                    | why
    ["cellbound-3d", "rspock"]                      | Dev::Cli::BuildSelector::TooManyBuildsError            | "one build at a time"                      | "two positionals"
    ["cellbound-3d", "--target", "rspock"]          | Dev::Cli::BuildSelector::ConflictingSelectionError     | "named twice: 'cellbound-3d' and --target" | "a positional beside --target"
    ["cellbound-3d-win64", "--platform", "linux64"] | Dev::Cli::BuildSelector::ConflictingSelectionError     | "platform is named twice: 'win64'"         | "the platform in the name and as a flag"
    ["cellbound-3d-release", "--config", "dev"]     | Dev::Cli::BuildSelector::ConflictingSelectionError     | "config is named twice: 'release'"         | "the config in the name and as a flag"
    ["opencell"]                                    | Dev::Lifecycle::BuildPattern::UnknownTargetError       | "names no declared target"                 | "no such target"
    ["--target", "opencell"]                        | Dev::Lifecycle::BuildPattern::UnknownTargetError       | "names no declared target"                 | "no such target, long form"
    ["cellbound-3d-macos"]                          | Dev::Lifecycle::BuildPattern::UnsupportedPlatformError | "does not declare platform 'macos'"        | "a platform the target lacks, in the name"
    ["cellbound-3d", "--platform", "macos"]         | Dev::Lifecycle::Build::PlatformMismatchError           | "does not declare platform 'macos'"        | "a platform the target lacks, as a flag"
    ["rspock", "--platform", "win64"]               | Dev::Lifecycle::Build::PlatformMismatchError           | "declares no platforms"                    | "a platform on a platform-less target"
    ["cellbound-3d", "--config", "debug"]           | Dev::Lifecycle::Build::ConfigMismatchError             | "does not declare config 'debug'"          | "a config the target lacks, as a flag"
    ["cellbound-3d", "--platform", "amiga"]         | Dev::Lifecycle::UnknownPlatformError                   | "unknown platform \"amiga\""               | "an id outside the set"
    ["cellbound-3d", "--config", "shipping"]        | Dev::Lifecycle::UnknownConfigError                     | "unknown config \"shipping\""              | "a config id outside the set"
  end
end
