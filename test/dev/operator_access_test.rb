# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/operator_access"
require "stringio"
require "support/answering_ui"

# The registry as the probe sees it: scopes GitHub refuses the operator's
# login at (403), lifted when a refresh "grants" them.
class ProbedRegistry
  attr_reader :probes

  def initialize(refused: [])
    @refused = refused
    @probes = []
  end

  def grant_all! = @refused.clear

  def group(org:, name:)
    @probes << [:groups, org]
    refuse!(org)
    nil
  end

  def find(scope:, name:)
    @probes << [:runners, scope]
    refuse!(scope)
    nil
  end

  private

  def refuse!(scope)
    return unless @refused.include?(scope)

    raise Dev::RunnerRegistry::QueryError,
      "could not list at #{scope}: gh: You must be an org admin or have the runners and runner groups fine-grained permission. (HTTP 403)"
  end
end

transform!(RSpock::AST::Transformation)
class Dev::OperatorAccessTest < Minitest::Test
  REFRESH = "gh auth refresh -h github.com -s admin:org"

  # The terminal register hands over (Dev::Ui), answering `answer`.
  def answering(answer) = AnsweringUi.new(answer: answer)

  test "an org registration probes the org's runner groups — the capability itself, not the token's scope list — and a login that can read them passes silently" do
    Given
    registry = ProbedRegistry.new
    ui = answering(false)
    access = Dev::OperatorAccess.new(registry: registry, refresher: ->(_scope) { raise "never" })

    When
    access.check!(scope: "d3mlabs", org: true, ui: ui)

    Then
    registry.probes == [[:groups, "d3mlabs"]]
    ui.rows == []
  end

  test "a repo registration probes the repo's runners the same way" do
    Given
    registry = ProbedRegistry.new
    access = Dev::OperatorAccess.new(registry: registry, refresher: ->(_scope) { raise "never" })

    When
    access.check!(scope: "d3mlabs/cellbound-3d", org: false, ui: answering(false))

    Then
    registry.probes == [[:runners, "d3mlabs/cellbound-3d"]]
  end

  test "refused and headless (no terminal to answer at — a no, dev#533): one refusal naming the purpose, GitHub's words and the classic-scope fix — and nothing else happens" do
    Given
    registry = ProbedRegistry.new(refused: ["d3mlabs"])
    ui = AnsweringUi.new(answer: nil)
    refreshed = []
    access = Dev::OperatorAccess.new(registry: registry, refresher: ->(scope) { refreshed << scope })

    When
    access.check!(scope: "d3mlabs", org: true, ui: ui)

    Then "the refusal carries what the login could not do, why register needs it, GitHub's reason, and the fix"
    error = raises Dev::OperatorAccess::RefusedError
    error.message.include?("your gh login cannot read d3mlabs's runner groups")
    error.message.include?("register converges the slots' group there and mints the org's registration tokens")
    error.message.include?("HTTP 403")
    error.message.include?(REFRESH)
    error.message.include?("then re-run")
    # It asked whether to run the refresh (defaulting to no), had no terminal to be answered at, refreshed nothing, probed once.
    ui.questions == [AnsweringUi::Question.new(text: "Run `#{REFRESH}` now?", default: false)]
    refreshed == []
    registry.probes == [[:groups, "d3mlabs"]]
  end

  test "refused at a terminal that says yes: the refresh runs for exactly the missing scope and the probe is repeated; a login that can now read them passes" do
    Given
    registry = ProbedRegistry.new(refused: ["d3mlabs"])
    refreshed = []
    ui = answering(true)
    access = Dev::OperatorAccess.new(registry: registry,
      refresher: ->(scope) {
        refreshed << scope
        registry.grant_all!
        true
      })

    When
    access.check!(scope: "d3mlabs", org: true, ui: ui)

    Then "the refusal was told once, as a note with its glyph, before the question"
    refreshed == ["admin:org"]
    registry.probes == [[:groups, "d3mlabs"], [:groups, "d3mlabs"]]
    ui.rows.length == 1
    ui.rows.first[0] == :note
    ui.rows.first[1].start_with?("{{x}} your gh login cannot read d3mlabs's runner groups")
  end

  test "a refresh that does not help (declined in the browser, wrong account) is the same refusal, after one retry" do
    Given
    registry = ProbedRegistry.new(refused: ["d3mlabs"])
    access = Dev::OperatorAccess.new(registry: registry, refresher: ->(_scope) { true })

    When
    access.check!(scope: "d3mlabs", org: true, ui: answering(true))

    Then
    error = raises Dev::OperatorAccess::RefusedError
    error.message.include?(REFRESH)
    registry.probes.length == 2
  end

  test "the repo-scoped refusal names repo admin and the repo scope" do
    Given
    registry = ProbedRegistry.new(refused: ["d3mlabs/cellbound-3d"])
    access = Dev::OperatorAccess.new(registry: registry, refresher: ->(_scope) { true })

    When
    access.check!(scope: "d3mlabs/cellbound-3d", org: false, ui: answering(false))

    Then
    error = raises Dev::OperatorAccess::RefusedError
    error.message.include?("cannot read d3mlabs/cellbound-3d's runners")
    error.message.include?("repo admin")
    error.message.include?("gh auth refresh -h github.com -s repo")
  end

  test "the default refresher is gh's own refresh for the scope, and its exit status is the answer" do
    Given "gh answering the refresh with #{outcome}"
    Kernel.expects(:system).once.with("gh", "auth", "refresh", "-h", "github.com", "-s", "admin:org").returns(outcome)

    Expect
    Dev::OperatorAccess::DEFAULT_REFRESHER.call("admin:org") == answer

    Where
    outcome | answer
    true    | true
    false   | false
    nil     | false
  end
end
