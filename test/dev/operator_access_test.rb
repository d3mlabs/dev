# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/operator_access"
require "stringio"

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

class AnsweringConfirmer
  attr_reader :questions

  def initialize(answer)
    @answer = answer
    @questions = []
  end

  def confirm?(question)
    @questions << question
    @answer
  end
end

transform!(RSpock::AST::Transformation)
class Dev::OperatorAccessTest < Minitest::Test
  REFRESH = "gh auth refresh -h github.com -s admin:org"

  test "an org registration probes the org's runner groups — the capability itself, not the token's scope list — and a login that can read them passes silently" do
    Given
    registry = ProbedRegistry.new
    out = StringIO.new
    access = Dev::OperatorAccess.new(registry: registry, confirmer: AnsweringConfirmer.new(false), out: out, refresher: ->(_scope) { raise "never" })

    When
    access.check!(scope: "d3mlabs", org: true)

    Then
    registry.probes == [[:groups, "d3mlabs"]]
    out.string.empty?
  end

  test "a repo registration probes the repo's runners the same way" do
    Given
    registry = ProbedRegistry.new
    access = Dev::OperatorAccess.new(registry: registry, confirmer: AnsweringConfirmer.new(false), out: StringIO.new, refresher: ->(_scope) { raise "never" })

    When
    access.check!(scope: "d3mlabs/cellbound-3d", org: false)

    Then
    registry.probes == [[:runners, "d3mlabs/cellbound-3d"]]
  end

  test "refused and headless (the confirmer says no): one refusal naming the purpose, GitHub's words and the classic-scope fix — and nothing else happens" do
    Given
    registry = ProbedRegistry.new(refused: ["d3mlabs"])
    confirmer = AnsweringConfirmer.new(false)
    refreshed = []
    out = StringIO.new
    access = Dev::OperatorAccess.new(registry: registry, confirmer: confirmer, out: out, refresher: ->(scope) { refreshed << scope })

    When
    access.check!(scope: "d3mlabs", org: true)

    Then "the refusal carries what the login could not do, why register needs it, GitHub's reason, and the fix"
    error = raises Dev::OperatorAccess::RefusedError
    error.message.include?("your gh login cannot read d3mlabs's runner groups")
    error.message.include?("register converges the slots' group there and mints the org's registration tokens")
    error.message.include?("HTTP 403")
    error.message.include?(REFRESH)
    error.message.include?("then re-run")
    # It asked whether to run the refresh, was told no, refreshed nothing, probed once.
    confirmer.questions == ["Run `#{REFRESH}` now?"]
    refreshed == []
    registry.probes == [[:groups, "d3mlabs"]]
  end

  test "refused at a terminal that says yes: the refresh runs for exactly the missing scope and the probe is repeated; a login that can now read them passes" do
    Given
    registry = ProbedRegistry.new(refused: ["d3mlabs"])
    refreshed = []
    out = StringIO.new
    access = Dev::OperatorAccess.new(registry: registry, confirmer: AnsweringConfirmer.new(true), out: out,
      refresher: ->(scope) {
        refreshed << scope
        registry.grant_all!
        true
      })

    When
    access.check!(scope: "d3mlabs", org: true)

    Then
    refreshed == ["admin:org"]
    registry.probes == [[:groups, "d3mlabs"], [:groups, "d3mlabs"]]
    out.string.include?("cannot read d3mlabs's runner groups")
  end

  test "a refresh that does not help (declined in the browser, wrong account) is the same refusal, after one retry" do
    Given
    registry = ProbedRegistry.new(refused: ["d3mlabs"])
    access = Dev::OperatorAccess.new(registry: registry, confirmer: AnsweringConfirmer.new(true), out: StringIO.new, refresher: ->(_scope) { true })

    When
    access.check!(scope: "d3mlabs", org: true)

    Then
    error = raises Dev::OperatorAccess::RefusedError
    error.message.include?(REFRESH)
    registry.probes.length == 2
  end

  test "the repo-scoped refusal names repo admin and the repo scope" do
    Given
    registry = ProbedRegistry.new(refused: ["d3mlabs/cellbound-3d"])
    access = Dev::OperatorAccess.new(registry: registry, confirmer: AnsweringConfirmer.new(false), out: StringIO.new, refresher: ->(_scope) { true })

    When
    access.check!(scope: "d3mlabs/cellbound-3d", org: false)

    Then
    error = raises Dev::OperatorAccess::RefusedError
    error.message.include?("cannot read d3mlabs/cellbound-3d's runners")
    error.message.include?("repo admin")
    error.message.include?("gh auth refresh -h github.com -s repo")
  end
end
