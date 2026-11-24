# typed: false
# frozen_string_literal: true

require "test_helper"
require "yaml"
require "dev/cli/runner_role_parser"

transform!(RSpock::AST::Transformation)
class Dev::Cli::RunnerRoleParserTest < Minitest::Test
  # --- declarations ------------------------------------------------------------

  test "labels alone declare a repo's own role" do
    When
    entries = build_parser.parse_all(yaml("ue-farm:\n  labels: [ue, gpu]"))

    Then
    entries == { "ue-farm" => Dev::RunnerRole::Declaration.new(name: "ue-farm", labels: %w[ue gpu]) }
  end

  test "a declaration carries its group (a bare name), its workflows and its job identity" do
    When
    entries = build_parser.parse_all(yaml(<<~YAML))
      agent:
        labels: [ai-ask, ai-edit]
        group: ai-flow
        workflows: [.github/workflows/ai-commands.yml, .github/workflows/origin-firing.yml]
        job_identity: ai-agent
    YAML

    Then
    entries == {
      "agent" => Dev::RunnerRole::Declaration.new(
        name: "agent",
        labels: %w[ai-ask ai-edit],
        group: "ai-flow",
        visibility: "selected",
        workflows: %w[.github/workflows/ai-commands.yml .github/workflows/origin-firing.yml],
        job_identity: "ai-agent",
      ),
    }
  end

  test "a group as a mapping carries its visibility" do
    When
    declaration = build_parser.parse_all(yaml(<<~YAML)).fetch("orchestrator")
      orchestrator:
        labels: [ai-orchestrator]
        group: { name: ai-orchestrator, visibility: all }
        workflows: [.github/workflows/ai-commands.yml]
    YAML

    Then
    declaration.group == "ai-orchestrator"
    declaration.visibility == "all"
    declaration.workflows == [".github/workflows/ai-commands.yml"]
    declaration.job_identity.nil?
  end

  test "an absent or non-mapping block is no roles" do
    Expect
    build_parser.parse_all(nil) == {}
    build_parser.parse_all([]) == {}
    build_parser.parse_all("agent") == {}
  end

  # --- references ----------------------------------------------------------------

  test "from: alone references another project's declaration of the same name" do
    When
    entries = build_parser.parse_all(yaml("agent:\n  from: d3mlabs/ai-flow"))

    Then
    entries == { "agent" => Dev::RunnerRole::Reference.new(name: "agent", declaring_repo: "d3mlabs/ai-flow") }
  end

  test "a block mixes declarations and references, each in its own shape" do
    When
    entries = build_parser.parse_all(yaml(<<~YAML))
      agent:
        from: d3mlabs/ai-flow
      ue-farm:
        labels: [ue, gpu]
    YAML

    Then
    entries.keys == %w[agent ue-farm]
    entries.fetch("agent").is_a?(Dev::RunnerRole::Reference)
    entries.fetch("ue-farm").is_a?(Dev::RunnerRole::Declaration)
  end

  test "from: beside #{other} is refused naming the key — a reference borrows its shape as declared" do
    When
    build_parser.parse_all(yaml("agent:\n  from: d3mlabs/ai-flow\n  #{body}"))

    Then
    error = raises Dev::Cli::RunnerRoleParser::RunnerRoleError
    error.message.include?("`agent` references another project's declaration (`from:`) and also declares `#{other}`")
    error.message.include?("drop `from:` to declare the role here, or `#{other}` to reference it")

    Where
    other          | body
    "labels"       | "labels: [ai-ask]"
    "group"        | "group: ai-flow"
    "job_identity" | "job_identity: ai-agent"
    "workflows"    | "workflows: [.github/workflows/x.yml]"
  end

  test "from: beside two other keys names both" do
    When
    build_parser.parse_all(yaml("agent:\n  from: d3mlabs/ai-flow\n  labels: [a]\n  group: g"))

    Then
    error = raises Dev::Cli::RunnerRoleParser::RunnerRoleError
    error.message.include?("also declares `labels`, `group`")
  end

  test "from: that is #{fault} is refused" do
    When
    build_parser.parse_all(yaml("agent:\n  from: #{value}"))

    Then
    error = raises Dev::Cli::RunnerRoleParser::RunnerRoleError
    error.message.include?("`agent`")
    error.message.include?(fragment)

    Where
    fault                  | value                      | fragment
    "empty"                | "''"                       | "needs `from:` as the declaring project's owner/repo"
    "not a string"         | "[d3mlabs, ai-flow]"       | "needs `from:` as the declaring project's owner/repo"
    "a bare name"          | "ai-flow"                  | "is not an owner/repo"
    "a URL"                | "https://github.com/a/b"   | "is not an owner/repo"
  end

  # --- refusals shared by every shape ------------------------------------------

  test "a declaration that is #{fault} is refused" do
    When
    build_parser.parse_all(yaml(body))

    Then
    error = raises Dev::Cli::RunnerRoleParser::RunnerRoleError
    error.message.include?(name)
    error.message.include?(fragment)

    Where
    fault                                   | name         | fragment                        | body
    "the builtin's name"                    | "build-host" | "is builtin"                    | "build-host:\n  labels: [x]"
    "without labels"                        | "farm"       | "needs a `labels:` list"        | "farm: {}"
    "with labels not a list"                | "farm"       | "needs a `labels:` list"        | "farm:\n  labels: ue"
    "not a mapping"                         | "farm"       | "needs a mapping"               | "farm: ue"
    "a group without workflows"             | "farm"       | "pins no `workflows:`"          | "farm:\n  labels: [ue]\n  group: ue-hosted"
    "workflows without a group"             | "farm"       | "names no `group:`"             | "farm:\n  labels: [ue]\n  workflows: [.github/workflows/x.yml]"
    "a group that is neither name nor map"  | "farm"       | "neither a name nor"            | "farm:\n  labels: [ue]\n  group: [x]\n  workflows: [.github/workflows/x.yml]"
    "a group with an unknown visibility"    | "farm"       | "one of selected | all"         | "farm:\n  labels: [ue]\n  group: { name: g, visibility: public }\n  workflows: [.github/workflows/x.yml]"
    "workflows not a list"                  | "farm"       | "needs `workflows:` as a list"  | "farm:\n  labels: [ue]\n  group: g\n  workflows: .github/workflows/x.yml"
    "a workflow outside .github/workflows"  | "farm"       | "under .github/workflows/"      | "farm:\n  labels: [ue]\n  group: g\n  workflows: [ci/x.yml]"
    "a job identity not a user name"        | "farm"       | "not a user name"               | "farm:\n  labels: [ue]\n  job_identity: [a]"
  end

  private

  def build_parser
    Dev::Cli::RunnerRoleParser.new
  end

  # The `runner_roles:` block as YAML hands it to the parser.
  def yaml(text)
    YAML.safe_load(text)
  end
end
