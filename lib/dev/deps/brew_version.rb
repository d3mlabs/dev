# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module Dev
  module Deps
    # A Homebrew version, ordered by Homebrew's own rules. Formulae write
    # versions of every shape — `3.11.4_1` (a bottle revision), `2024-01-15`,
    # `1.0r3`, `1.0.0-beta`, `2.1p2` — and Homebrew compares them as token
    # sequences: `.`, `-` and `_` separate, digits are numbers, and letters
    # are either a release marker with a fixed place in the order (alpha <
    # beta < pre < rc < the release itself < patch < post) or a plain word,
    # which sits above the release (`1.0r3` is a revision of 1.0, not a
    # prerelease). A missing position reads as the release: `1.0` is
    # `1.0.0`, below `1.0_1` and above `1.0-rc1`.
    #
    # Gem::Version is too loose here — it reads every letter as a
    # prerelease, so `1.0r3` would fall below `1.0` — which is why brew's
    # ordering is its own type.
    class BrewVersion
      extend T::Sig
      include Comparable

      # The string has no token Homebrew can read (it does not start with a digit).
      class InvalidVersionError < StandardError; end

      # One position of a version: a kind, which fixes its place against
      # every other kind, and a value compared within the kind.
      class Token
        extend T::Sig
        include Comparable

        # @return [Symbol] :alpha, :beta, :pre, :rc, :release, :word, :patch, :post or :number
        sig { returns(Symbol) }
        attr_reader :kind

        # @return [Integer, String] the number, the word, or the marker's revision
        sig { returns(T.any(Integer, String)) }
        attr_reader :value

        # @param kind [Symbol]
        # @param value [Integer, String]
        sig { params(kind: Symbol, value: T.any(Integer, String)).void }
        def initialize(kind:, value:)
          @kind = kind
          @value = value
          freeze
        end

        # Kinds in ascending order; `:release` is the empty position a
        # shorter version reads at, `:number` is above every word so that
        # `1.0.1` is above `1.0p1`.
        RANK = T.let(%i[alpha beta pre rc release word patch post number].freeze, T::Array[Symbol])

        # @param other [Token]
        # @return [Integer]
        sig { params(other: Token).returns(Integer) }
        def <=>(other)
          return within_kind(other) if kind == other.kind
          return 0 if release_equivalent?(other) || other.release_equivalent?(self)

          rank <=> other.rank
        end

        class << self
          extend T::Sig

          # @return [Token] the empty position
          sig { returns(Token) }
          def release
            new(kind: :release, value: 0)
          end
        end

        protected

        # @return [Integer] the kind's place in RANK
        sig { returns(Integer) }
        def rank
          T.must(RANK.index(kind))
        end

        # A zero number reads as the release itself (`1.0` is `1.0.0`).
        #
        # @param other [Token]
        # @return [Boolean]
        sig { params(other: Token).returns(T::Boolean) }
        def release_equivalent?(other)
          kind == :release && other.kind == :number && other.value == 0
        end

        private

        # Two tokens of one kind compare by value: numbers and marker
        # revisions numerically, words as text.
        #
        # @param other [Token] a token of this kind
        # @return [Integer]
        sig { params(other: Token).returns(Integer) }
        def within_kind(other)
          mine, theirs = value, other.value
          return mine <=> theirs if mine.is_a?(Integer) && theirs.is_a?(Integer)

          T.must(mine.to_s <=> theirs.to_s)
        end
      end

      # Markers Homebrew gives a fixed place, with the revision they may
      # carry; the one-letter spellings only with a revision (`a1`, `p2`).
      MARKER_PATTERN = /\A(?:(alpha|beta|pre|rc|post)(\d*)|([abp])(\d+))\z/i
      # Marker spelling → kind (`a` is alpha, `b` beta, `p` patch).
      MARKERS = T.let(
        {
          "alpha" => :alpha, "a" => :alpha,
          "beta" => :beta, "b" => :beta,
          "pre" => :pre,
          "rc" => :rc,
          "p" => :patch,
          "post" => :post,
        }.freeze,
        T::Hash[String, Symbol],
      )
      # Homebrew's scan: a marker with its revision, a number, or a word —
      # separators (`.`, `-`, `_`) fall between matches.
      SCAN_PATTERN = /alpha\d*|beta\d*|pre\d*|rc\d*|post\d*|a\d+|b\d+|p\d+|\d+|[a-z]+/i

      # @return [String] the version as brew wrote it
      sig { returns(String) }
      attr_reader :to_s

      # @return [Array<Token>]
      sig { returns(T::Array[Token]) }
      attr_reader :tokens

      # @param version [String] as brew writes it
      # @raise [InvalidVersionError] unless the version starts with a digit
      sig { params(version: String).void }
      def initialize(version)
        raise InvalidVersionError, "not a version brew's ordering can read: #{version.inspect}" unless version.match?(/\A\d/)

        @to_s = version
        words = T.cast(version.scan(SCAN_PATTERN), T::Array[String])
        @tokens = T.let(words.map { |word| token(word) }.freeze, T::Array[Token])
        freeze
      end

      # @param other [BrewVersion]
      # @return [Integer]
      sig { params(other: BrewVersion).returns(Integer) }
      def <=>(other)
        width = [tokens.size, other.tokens.size].max
        width.times do |index|
          comparison = token_at(index) <=> other.token_at(index)
          return comparison unless comparison.zero?
        end
        0
      end

      protected

      # @param index [Integer]
      # @return [Token] the token there, or the release past the end
      sig { params(index: Integer).returns(Token) }
      def token_at(index)
        tokens.fetch(index) { Token.release }
      end

      private

      # @param word [String] one scanned token
      # @return [Token]
      sig { params(word: String).returns(Token) }
      def token(word)
        return Token.new(kind: :number, value: word.to_i) if word.match?(/\A\d+\z/)

        marker = MARKER_PATTERN.match(word)
        return Token.new(kind: :word, value: word.downcase) unless marker

        Token.new(kind: MARKERS.fetch(T.must(marker[1] || marker[3]).downcase), value: (marker[2] || marker[4]).to_i)
      end
    end
  end
end
