# typed: strict
# frozen_string_literal: true

require "pathname"
require "uri"
require_relative "../value_equality"

module Dev
  module Deps
    # One formula file in a Homebrew tap (`Formula/<name>.rb`), read and
    # rewritten for the one thing a release changes in it: its **stable
    # spec** — Homebrew's name for the default `url` and `sha256` pair the
    # formula builds from. Everything else in the file (the dependency
    # edges, the resources with their own `url`/`sha256` pairs, the
    # install block) is the formula author's and is left byte for byte.
    #
    # The stable spec is located by shape, not by what the url says: the
    # first `url "…"` line of the file and the `sha256 "…"` that follows
    # it before any other `url` — which is where Homebrew's style puts
    # it, and which keeps a vendored resource's `sha256` out of reach. A
    # release that moves a formula from one url scheme to another (a
    # source tarball to a release asset) is the same rewrite as a version
    # bump; the earlier `bin/release.rb` anchored on the old url's shape
    # and could only bump in place.
    #
    # Files are read and written as UTF-8 explicitly: a formula may carry
    # non-ASCII bytes (an em dash in a comment), and under a non-UTF-8
    # locale Ruby's default external encoding would make the rewrite fail
    # on them.
    class FormulaFile
      extend T::Sig

      # The file carries no `url`/`sha256` pair where a stable spec should be.
      class NoStableSpecError < RuntimeError; end

      # The stable spec of a formula: what it downloads and what the
      # download must hash to.
      class StableSpec < T::Struct
        extend T::Sig
        include Dev::ValueEquality::Derived

        const :url, URI::Generic
        const :sha256, String

        # @return [Array] the members that constitute identity
        sig { override.returns(T::Array[T.anything]) }
        def equality_members
          [url, sha256]
        end

        sig { returns(String) }
        def to_s
          "#{url} (#{sha256})"
        end
      end

      EXTENSION = ".rb"
      URL_LINE = /\A(?<lead>\s*url\s+")(?<url>[^"]+)(?<tail>".*)\z/
      SHA256_LINE = /\A(?<lead>\s*sha256\s+")(?<sha256>[0-9a-f]+)(?<tail>".*)\z/
      # `depends_on "name"` / `depends_on "tap/name" => :build`: the name
      # is the quoted word, tap-qualified or not.
      DEPENDS_ON_LINE = /\A\s*depends_on\s+"(?<name>[^"]+)"/

      # @return [Pathname]
      sig { returns(Pathname) }
      attr_reader :path

      # @param path [Pathname] the formula file
      sig { params(path: Pathname).void }
      def initialize(path:)
        @path = path
      end

      # The formula's name: the file's, without the extension.
      #
      # @return [String]
      sig { returns(String) }
      def name
        @path.basename(EXTENSION).to_s
      end

      # The formulas this one depends on, as brew resolves a `depends_on`:
      # the formula's own name, the tap prefix dropped — in file order,
      # `on_macos` and other blocks included. What the publisher reads to
      # name only the roots in its upgrade line (dev#531).
      #
      # @return [Array<String>]
      sig { returns(T::Array[String]) }
      def dependencies
        read_lines.filter_map { |line| DEPENDS_ON_LINE.match(line)&.[](:name)&.split("/")&.last }
      end

      # The stable spec as the file carries it now.
      #
      # @return [StableSpec]
      # @raise [NoStableSpecError]
      sig { returns(StableSpec) }
      def stable_spec
        lines = read_lines
        url_index, sha256_index = locate(lines)
        url = T.must(URL_LINE.match(T.must(lines[url_index])))[:url].to_s
        sha256 = T.must(SHA256_LINE.match(T.must(lines[sha256_index])))[:sha256].to_s
        StableSpec.new(url: URI.parse(url), sha256:)
      end

      # Rewrite the stable spec in place, the two lines' own indentation
      # and the rest of the file kept.
      #
      # @param spec [StableSpec]
      # @return [void]
      # @raise [NoStableSpecError]
      sig { params(spec: StableSpec).void }
      def write_stable_spec(spec)
        text = @path.read(encoding: "UTF-8")
        lines = text.lines(chomp: true)
        url_index, sha256_index = locate(lines)
        lines[url_index] = T.must(lines[url_index]).sub(URL_LINE) { "#{$~[:lead]}#{spec.url}#{$~[:tail]}" }
        lines[sha256_index] = T.must(lines[sha256_index]).sub(SHA256_LINE) { "#{$~[:lead]}#{spec.sha256}#{$~[:tail]}" }
        @path.write(lines.join("\n") + (text.end_with?("\n") ? "\n" : ""), encoding: "UTF-8")
      end

      private

      # @return [Array<String>] the file's lines, without their endings
      sig { returns(T::Array[String]) }
      def read_lines
        @path.read(encoding: "UTF-8").lines(chomp: true)
      end

      # The indices of the stable spec's two lines: the first `url`, and
      # the first `sha256` after it with no other `url` between.
      #
      # @param lines [Array<String>] without their endings
      # @return [Array(Integer, Integer)]
      # @raise [NoStableSpecError]
      sig { params(lines: T::Array[String]).returns([Integer, Integer]) }
      def locate(lines)
        url_index = lines.index { |line| URL_LINE.match?(line) }
        raise NoStableSpecError, "#{@path}: no `url \"…\"` line — the formula has no stable spec to point at a release" if url_index.nil?

        after = T.must(lines[(url_index + 1)..])
        offset = after.index { |line| SHA256_LINE.match?(line) || URL_LINE.match?(line) }
        if offset.nil? || !SHA256_LINE.match?(T.must(after[offset]))
          raise NoStableSpecError, "#{@path}: the `url` on line #{url_index + 1} has no `sha256 \"…\"` after it"
        end

        [url_index, url_index + 1 + offset]
      end
    end
  end
end
