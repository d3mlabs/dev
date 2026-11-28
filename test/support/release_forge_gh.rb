# typed: false
# frozen_string_literal: true

require "json"
require "pathname"
require "support/fake_gh"

# A FakeGh that keeps a release's assets the way the forge does, for the
# verbs that write one and read it back in the same run (`package
# --attach`, `release`): `release upload` stores each file's bytes under
# the tag, `release view <tag> --json assets` lists what is attached, and
# `release download` serves it (FakeGh's `serves`). Everything else —
# `release view` for the page, `create`, `edit`, `api` — stays scripted,
# so a test still says whether the release exists and what the forge
# answers; an upload a test scripted a refusal for (`refuses(["release",
# "upload"], …)`) is refused rather than kept, so a frozen release can be
# staged. Every call is recorded as FakeGh records it.
class ReleaseForgeGh < FakeGh
  UPLOAD = ["release", "upload"].freeze
  VIEW = ["release", "view"].freeze
  ASSETS_FIELDS = ["--json", "assets"].freeze

  def initialize(root: Pathname("/nonexistent/checkout"))
    super
    @attached = Hash.new { |hash, tag| hash[tag] = {} }
  end

  # What a tag's release carries, as uploaded: asset name → bytes.
  #
  # @param tag [String] the tag's name (`v1.2.0`)
  # @return [Hash{String => String}]
  def attached(tag)
    @attached[tag]
  end

  def capture(argv, stdin: nil)
    return upload(argv, stdin:) if argv.first(UPLOAD.size) == UPLOAD && !scripted?(argv)
    return list(argv, stdin:) if argv.first(VIEW.size) == VIEW && argv[3..4] == ASSETS_FIELDS

    super
  end

  private

  # Whether a test registered an answer or refusal for this argv.
  def scripted?(argv)
    @answers.any? { |prefix, _out, _err| argv.first(prefix.size) == prefix }
  end

  # `gh release upload <tag> <file>… --clobber`: keep each file's bytes
  # under its name, replacing an earlier upload of the same name.
  def upload(argv, stdin:)
    calls << Call.new(argv:, stdin:)
    tag = argv.fetch(2)
    argv[3..].reject { |word| word.start_with?("--") }.each do |file|
      bytes = File.binread(file)
      @attached[tag][File.basename(file)] = bytes
      serves(tag, File.basename(file) => bytes)
    end
    ""
  end

  # `gh release view <tag> --json assets --jq .assets`: the attached
  # assets, name and a download url each, as gh lists them.
  def list(argv, stdin:)
    calls << Call.new(argv:, stdin:)
    tag = argv.fetch(2)
    JSON.generate(@attached[tag].keys.map { |name| { "name" => name, "url" => "https://github.com/o/r/releases/download/#{tag}/#{name}" } })
  end
end
