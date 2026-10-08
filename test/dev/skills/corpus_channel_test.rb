# typed: false
# frozen_string_literal: true

require "test_helper"
require "dev/skills"
require "fileutils"
require "pathname"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class Dev::Skills::CorpusChannelTest < Minitest::Test
  def build_skill(dir, *path_parts)
    source = Pathname(dir).join(*path_parts)
    FileUtils.mkdir_p(source)
    File.write(source / "SKILL.md", "# skill\n")
    source
  end

  test "entries are the corpus's skill dirs under their own names, non-skills skipped, sorted" do
    Given "a corpus with two skills and one non-skill dir"
    dir = Dir.mktmpdir("dev-corpus-channel-test-")
    typed = build_skill(dir, "corpus", "typed-errors")
    capture = build_skill(dir, "corpus", "capture-learning")
    FileUtils.mkdir_p(File.join(dir, "corpus", "not-a-skill"))
    channel = Dev::Skills::CorpusChannel.new(name: "c", root: File.join(dir, "root"), corpus_root: File.join(dir, "corpus"))

    When "listing entries"
    entries = channel.entries

    Then "each skill dir is an entry named after itself, with no provenance"
    entries.map(&:link_name) == ["capture-learning", "typed-errors"]
    entries.map(&:source) == [capture, typed]
    entries.all? { |e| e.package.nil? && e.version.nil? }

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "entries are empty when the corpus does not exist" do
    Given "a channel over a missing corpus"
    dir = Dir.mktmpdir("dev-corpus-channel-test-")
    channel = Dev::Skills::CorpusChannel.new(name: "c", root: File.join(dir, "root"), corpus_root: File.join(dir, "nope"))

    Expect "no entries"
    channel.entries == []

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "OwnSkills is the shipped set, landing user-globally" do
    Given "the default own-skills channel"
    channel = Dev::Skills::OwnSkills.new

    Expect "it is named dev, user-global, reads from the shipped dir, and declares the shipped ai-flow skill"
    channel.name == "dev"
    !channel.project_scoped?
    channel.root == Dev::Skills::Layout.user_global_root
    channel.corpus_root == Dev::Skills::Layout::SHIPPED_SKILLS_DIR
    channel.entries.map(&:link_name).include?("ai-flow")
  end
end
