# typed: strict
# frozen_string_literal: true

require_relative "range_scheme"

module Dev
  module Deps
    # PEP 440 ordering (:pip): dev's requirement evaluated over Python
    # package versions with pip's comparison rules. `~>` reads as PEP 440's
    # `~=` (`~> 2.0.3` is `>= 2.0.3, < 2.1`), `=` as `==`.
    #
    # Version grammar: [epoch!]release[{a|b|rc}N][.postN][.devN]; local
    # version labels ("+cpu") are accepted and ignored for ordering.
    # Deliberately NOT full PEP 440 on the requirement side: wildcard
    # equality (`==2.0.*`), arbitrary equality (`===`), post-release
    # exclusion nuances of `>V`, and environment markers are not in dev's
    # language — a pip-native specifier belongs to a future dev-owned pip
    # solve (docs/deps-architecture.md).
    class Pep440Scheme < RangeScheme
      extend T::Sig

      # The version string is not a PEP 440 version.
      class InvalidVersionError < VersionScheme::InvalidVersionError; end

      VERSION_PATTERN = /
        \A
        (?:(\d+)!)?                # epoch
        (\d+(?:\.\d+)*)            # release segments
        (?:[._-]?(a|b|rc|alpha|beta|c|pre|preview)[._-]?(\d*))?  # prerelease
        (?:[._-]?post[._-]?(\d*))? # post release
        (?:[._-]?dev[._-]?(\d*))?  # dev release
        (?:\+[0-9a-z.]+)?          # local version label (ignored)
        \z
      /xi

      # Prerelease phase ranks; canonical spellings and PEP 440 aliases.
      PHASE_RANKS = T.let(
        { "a" => 0, "alpha" => 0, "b" => 1, "beta" => 1, "c" => 2, "pre" => 2, "preview" => 2, "rc" => 2 }.freeze,
        T::Hash[String, Integer],
      )

      protected

      # PEP 440 comparison key, mirroring pip's _cmpkey: [epoch, release
      # (trailing zeros stripped), pre-key, post-key, dev-key]. A dev release
      # with no prerelease sorts below any prerelease of the same release.
      #
      # @param coordinate [String]
      # @return [Array]
      # @raise [InvalidVersionError] if the version does not parse
      sig { override.params(coordinate: String).returns(T::Array[T.untyped]) }
      def comparison_key(coordinate)
        match = VERSION_PATTERN.match(coordinate)
        raise InvalidVersionError, "not a PEP 440 version: #{coordinate.inspect}" unless match

        epoch = match[1].to_i
        release = T.must(match[2]).split(".").map(&:to_i)
        release.pop while release.size > 1 && release.last.to_i.zero?

        phase, phase_number, post, dev = match[3], match[4], match[5], match[6]
        pre_key = if phase
          [PHASE_RANKS.fetch(phase.downcase), phase_number.to_i]
        elsif post.nil? && dev
          [-1] # dev-only releases sort below every prerelease
        else
          [3]
        end
        post_key = post ? [0, post.to_i] : [-1]
        dev_key = dev ? [0, dev.to_i] : [1]

        [epoch, release, pre_key, post_key, dev_key]
      end
    end
  end
end
