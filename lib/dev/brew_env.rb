# typed: strict
# frozen_string_literal: true

require "fileutils"
require "pathname"

module Dev
  # Homebrew's user environment file — `~/.homebrew/brew.env`, or
  # `$XDG_CONFIG_HOME/homebrew/brew.env` — read by every `brew` the user
  # runs, which is how dev tells brew about formulae it must not clean up:
  # a `dev up` keeps the keg the lock names alive through the user's own
  # `brew upgrade` and `brew cleanup` (ADR-0010, dev#289).
  #
  # The list only grows. Two projects on one machine share the file, and
  # releasing a name needs to know no other project's lock still pins it —
  # the cross-project view dev#286 asks for. Until then a stale entry costs
  # one keg of disk, never a broken build.
  class BrewEnv
    extend T::Sig

    # The file exists but dev could not rewrite it.
    class WriteError < StandardError
      extend T::Sig

      # @param path [Pathname] the brew.env dev tried to write
      # @param cause [SystemCallError] what the write said
      sig { params(path: Pathname, cause: SystemCallError).void }
      def initialize(path:, cause:)
        super("could not write #{path} (#{cause.message}) — dev records locked formulae there so brew cleanup keeps their kegs")
      end
    end

    NO_CLEANUP_KEY = "HOMEBREW_NO_CLEANUP_FORMULAE"

    class << self
      extend T::Sig

      # The user-specific brew.env, where brew's own documentation says it
      # is read from.
      #
      # @param env [Hash{String => String}] the environment to resolve against
      # @return [Pathname]
      sig { params(env: T::Hash[String, T.nilable(String)]).returns(Pathname) }
      def user_file(env: ENV.to_h)
        xdg = env["XDG_CONFIG_HOME"]
        return Pathname(xdg) / "homebrew" / "brew.env" if xdg && !xdg.empty?

        Pathname(T.must(env["HOME"])) / ".homebrew" / "brew.env"
      end
    end

    # @param path [Pathname] the brew.env to read and write
    sig { params(path: Pathname).void }
    def initialize(path:)
      @path = path
    end

    # @return [Array<String>] the formulae brew is told never to clean up
    sig { returns(T::Array[String]) }
    def no_cleanup_formulae
      line = lines.find { |candidate| key_line?(candidate) }
      return [] unless line

      value = T.must(line.split("=", 2)[1]).strip.delete_prefix('"').delete_suffix('"')
      value.split(",").map(&:strip).reject(&:empty?)
    end

    # Add formulae to the no-cleanup list, in place, leaving every other
    # line and every name already listed as they were.
    #
    # @param formulae [Array<String>] formula names the lock pins
    # @return [Boolean] true when the file changed
    # @raise [WriteError] if the file cannot be written
    sig { params(formulae: T::Array[String]).returns(T::Boolean) }
    def retain!(formulae)
      current = no_cleanup_formulae
      merged = current | formulae
      return false if merged == current

      key_line = "#{NO_CLEANUP_KEY}=#{merged.join(",")}"
      updated = lines.map { |line| key_line?(line) ? key_line : line }
      updated << key_line unless updated.any? { |line| key_line?(line) }
      write(updated)
      true
    end

    private

    # @return [Array<String>] the file's lines without terminators; empty when absent
    sig { returns(T::Array[String]) }
    def lines
      return [] unless @path.file?

      @path.read.lines.map(&:chomp)
    end

    # @param line [String]
    # @return [Boolean] whether the line sets the no-cleanup key
    sig { params(line: String).returns(T::Boolean) }
    def key_line?(line)
      line.strip.start_with?("#{NO_CLEANUP_KEY}=")
    end

    # @param updated [Array<String>] the lines to write
    # @raise [WriteError]
    sig { params(updated: T::Array[String]).void }
    def write(updated)
      FileUtils.mkdir_p(@path.dirname)
      @path.write(updated.join("\n") + "\n")
    rescue SystemCallError => e
      raise WriteError.new(path: @path, cause: e)
    end
  end
end
