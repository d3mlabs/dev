# typed: strict
# frozen_string_literal: true

module Dev
  # A project's `Gemfile.lock`, read for the one thing two of dev's layers
  # care about: the lines bundler writes about the project's **own gem** —
  # the gem under `PATH` / `remote: .`, whose version mirrors `VERSION`
  # when the gemspec reads it. Bundler records that version twice: the
  # spec line (`    dev (0.8.0)`, four spaces in under `specs:`, its
  # dependencies six) and, since bundler 2.6, a `CHECKSUMS` entry
  # (`  dev (0.8.0)`, two spaces in, no digest for a path gem).
  #
  # `Lifecycle::ProjectVersion` moves both lines on a release bump, so the
  # lock is never left half-moved for the next `bundle` to rewrite
  # (dev#521). `Deps::Staleness` digests the lock **without** them: a path
  # gem is pointed at, never installed from the lock, so its version is a
  # label and not an ingredient — counting it made every release bump nag
  # "run dev up" for nothing (dev#527). Only `remote: .` is the own gem; a
  # sibling path gem (`remote: ../x`) is any other gem here.
  class GemfileLock
    extend T::Sig

    FILE_NAME = "Gemfile.lock"

    # The lock has no gem under `PATH` / `remote: .`: nothing of the
    # project's to move.
    class NoOwnGemError < RuntimeError; end

    # The own gem's spec line, in bundler's layout. `lead` runs to the
    # opening paren, `gem` is the name inside it, `version` the value.
    OWN_SPEC = /^(?<lead>PATH\n  remote: \.\n  specs:\n(?:    .+\n)*?    (?<gem>\S+) \()(?<version>[^)]+)\)$/

    # @param text [String] the lock's contents
    sig { params(text: String).void }
    def initialize(text)
      @text = text
      @spec = T.let(OWN_SPEC.match(text), T.nilable(MatchData))
    end

    # @return [String, nil] the own gem's name; nil when the lock has none
    sig { returns(T.nilable(String)) }
    def own_gem
      @spec&.[](:gem)
    end

    # @return [String, nil] the own gem's version; nil when the lock has none
    sig { returns(T.nilable(String)) }
    def own_version
      @spec&.[](:version)
    end

    # The lock with the own gem at +version+: its spec line and, when the
    # lock has one, its `CHECKSUMS` entry — nothing else.
    #
    # @param version [String]
    # @return [String]
    # @raise [NoOwnGemError]
    sig { params(version: String).returns(String) }
    def with_own_version(version)
      raise NoOwnGemError, "#{FILE_NAME} has no gem under PATH / remote: . to move" unless @spec

      rewrite_own_lines { version }
    end

    # The lock as an install reads it: the own gem's version lines blanked,
    # so two locks differing only there read the same. A lock with no own
    # gem is itself.
    #
    # @return [String]
    sig { returns(String) }
    def without_own_version
      return @text unless @spec

      rewrite_own_lines { "" }
    end

    private

    # @yieldreturn [String] what replaces the own gem's version
    # @return [String]
    sig { params(block: T.proc.returns(String)).returns(String) }
    def rewrite_own_lines(&block)
      spec = T.must(@spec)
      gem = T.must(spec[:gem])
      current = T.must(spec[:version])
      text = @text.sub(OWN_SPEC) { "#{Regexp.last_match(:lead)}#{block.call})" }
      text.sub(checksum_entry(gem, current)) { "#{Regexp.last_match(:lead)}#{block.call})" }
    end

    # The own gem's `CHECKSUMS` entry at a version (bundler ≥ 2.6); absent
    # from an older bundler's lock, where the substitution is a no-op.
    #
    # @param gem [String]
    # @param version [String]
    # @return [Regexp] with a `lead` group running to the opening paren
    sig { params(gem: String, version: String).returns(Regexp) }
    def checksum_entry(gem, version)
      /^(?<lead>CHECKSUMS\n(?:  .+\n)*?  #{Regexp.escape(gem)} \()#{Regexp.escape(version)}\)$/
    end
  end
end
