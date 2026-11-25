# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/deps/selection_rule"
require "dev/deps/series_head"
require "dev/deps/package_version"
require "dev/deps/requirement"
require "dev/deps/tag_scheme"
require "dev/lifecycle/series"

transform!(RSpock::AST::Transformation)
class Dev::Deps::SelectionRuleTest < Minitest::Test
  def head(major, version)
    Dev::Deps::SeriesHead.new(series: Dev::Lifecycle::Series.new(major), version:)
  end

  def version(string)
    Dev::Deps::PackageVersion.new(version: string, source: string)
  end

  def rule_for(requirement, heads:, candidates:, scheme: Dev::Deps::TagScheme.new)
    Dev::Deps::SelectionRule.for(
      requirement: Dev::Deps::Requirement.parse(requirement),
      scheme:,
      heads:,
      candidates: candidates.map(&:version),
    )
  end

  test "the rule for #{requirement.inspect} against a universe with heads is #{said}" do
    Given "tags 1.3.0, 1.4.0, 2.0.0 with v1 rolled back to 1.3.0 and v2 at 2.0.0; the candidates are the tags the requirement admits"
    heads = [head(1, "1.3.0"), head(2, "2.0.0")]
    parsed = Dev::Deps::Requirement.parse(requirement)
    candidates = %w[1.3.0 1.4.0 2.0.0].map { |v| version(v) }.select { |v| Dev::Deps::TagScheme.new.satisfies?(v, parsed) }
    expected = head_major ? Dev::Deps::SelectionRule::Head.new(head: head(head_major, picked)) : Dev::Deps::SelectionRule::Greatest.new(beside: heads)

    When
    rule = rule_for(requirement, heads:, candidates:)

    Then "a series-shaped ask takes the newest covered head; anything finer takes the greatest, beside the heads it passed over"
    rule == expected
    rule.pick(candidates, Dev::Deps::TagScheme.new).version == picked
    rule.to_s == said

    Where
    requirement   | head_major | picked  | said
    "^1"          | 1          | "1.3.0" | "series head v1 → 1.3.0"
    ">= 1, < 2"   | 1          | "1.3.0" | "series head v1 → 1.3.0"
    ">= 1"        | 2          | "2.0.0" | "series head v2 → 2.0.0"
    ">= 1.4"      | nil        | "2.0.0" | "greatest satisfying"
    ">= 1.4, < 2" | nil        | "1.4.0" | "greatest satisfying"
  end

  test "a head that is not a candidate does not apply, and the rule says it passed that head over" do
    Given "v1 pointing at a pre-release ^1 does not admit"
    heads = [head(1, "1.0.0-rc.1")]
    candidates = [version("1.0.0"), version("1.1.0")]

    When
    rule = rule_for("^1", heads:, candidates:)

    Then
    rule == Dev::Deps::SelectionRule::Greatest.new(beside: heads)
    rule.pick(candidates, Dev::Deps::TagScheme.new).version == "1.1.0"
  end

  test "the rule accounts for itself only where another rule could have applied" do
    Given "a universe with heads, and a derived one with none"
    beside_heads = Dev::Deps::SelectionRule::Greatest.new(beside: [head(1, "1.3.0")])
    alone = Dev::Deps::SelectionRule::Greatest.new(beside: [])
    at_head = Dev::Deps::SelectionRule::Head.new(head: head(1, "1.3.0"))

    Expect "greatest beside a head is worth saying; greatest as the only rule is not; a head always is"
    beside_heads.explanation == "greatest satisfying"
    alone.explanation.nil?
    at_head.explanation == "series head v1 → 1.3.0"
  end

  test "a scheme-less channel, or a universe with no heads, resolves by the greatest with nothing to say" do
    Given "versions in the order the universe listed them"
    candidates = [version("b"), version("a")]

    When "no scheme orders them"
    rule = Dev::Deps::SelectionRule.for(requirement: Dev::Deps::Requirement.parse(""), scheme: nil, heads: [], candidates: %w[b a])

    Then "the last listed is the greatest, as the Resolver always read a scheme-less universe"
    rule == Dev::Deps::SelectionRule::Greatest.new(beside: [])
    rule.pick(candidates, nil).version == "a"
    rule.explanation.nil?
  end

  test "rules compare by the rule and its facts" do
    Expect
    assert_value_semantics Dev::Deps::SelectionRule::Head.new(head: head(1, "1.3.0")),
      equal_to: Dev::Deps::SelectionRule::Head.new(head: head(1, "1.3.0")),
      unequal_to: [Dev::Deps::SelectionRule::Head.new(head: head(1, "1.4.0")), Dev::Deps::SelectionRule::Greatest.new(beside: [])]
    assert_value_semantics Dev::Deps::SelectionRule::Greatest.new(beside: [head(1, "1.3.0")]),
      equal_to: Dev::Deps::SelectionRule::Greatest.new(beside: [head(1, "1.3.0")]),
      unequal_to: [Dev::Deps::SelectionRule::Greatest.new(beside: [])]
  end

  test "a series head names the pointer and what it points at" do
    Expect
    head(1, "v1.3.0").to_s == "v1 → v1.3.0"
    assert_value_semantics head(1, "v1.3.0"), equal_to: head(1, "v1.3.0"), unequal_to: [head(2, "v1.3.0"), head(1, "v1.4.0")]
  end
end
