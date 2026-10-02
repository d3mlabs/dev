# typed: strict
# frozen_string_literal: true

require "dev/ini_file"

module Dev
  # The user's `%USERPROFILE%\.wslconfig` — WSL2's VM-wide settings — as an
  # editable value. dev only cares about three keys: `[wsl2] processors` and
  # `memory`, and `[experimental] autoMemoryReclaim` (WSL reads it there and
  # only there — under `[wsl2]` it warns "Unknown key" and ignores it, which
  # is what the first real box had). Everything else in the file is
  # preserved byte for byte (see IniFile). `with` is the one way in.
  class WslConfig
    extend T::Sig

    # A `memory=` value WSL itself would reject (it wants `<n>GB`, `<n>MB`, …).
    class MalformedValueError < RuntimeError; end

    SECTION = "wsl2"
    EXPERIMENTAL_SECTION = "experimental"
    MEMORY_PATTERN = /\A(\d+)\s*(GB|MB|TB)\z/i
    MIB_PER_GIB = 1024

    class << self
      extend T::Sig

      # @param text [String] the file's content ("" for a missing file)
      # @return [WslConfig]
      # @raise [MalformedValueError] when `memory=` is not a size WSL accepts
      sig { params(text: String).returns(WslConfig) }
      def parse(text)
        new(IniFile.parse(text))
      end
    end

    # @param ini [IniFile]
    sig { params(ini: IniFile).void }
    def initialize(ini)
      @ini = ini
      @memory_gib = T.let(parse_memory(ini.value(SECTION, "memory")), T.nilable(Integer))
    end

    # @return [Integer, nil] `[wsl2] processors`
    sig { returns(T.nilable(Integer)) }
    def processors
      @ini.value(SECTION, "processors")&.to_i
    end

    # @return [Integer, nil] `[wsl2] memory`, in whole GiB (rounded up)
    sig { returns(T.nilable(Integer)) }
    attr_reader :memory_gib

    # @return [String, nil] `[experimental] autoMemoryReclaim`
    sig { returns(T.nilable(String)) }
    def auto_memory_reclaim
      @ini.value(EXPERIMENTAL_SECTION, "autoMemoryReclaim")
    end

    # A copy with the given keys set. Nil fields are left as they are.
    #
    # @param processors [Integer, nil]
    # @param memory_gib [Integer, nil]
    # @param auto_memory_reclaim [String, nil]
    # @return [WslConfig]
    sig do
      params(processors: T.nilable(Integer), memory_gib: T.nilable(Integer), auto_memory_reclaim: T.nilable(String))
        .returns(WslConfig)
    end
    def with(processors: nil, memory_gib: nil, auto_memory_reclaim: nil)
      ini = @ini
      ini = ini.set(SECTION, "processors", processors.to_s) if processors
      ini = ini.set(SECTION, "memory", "#{memory_gib}GB") if memory_gib
      ini = ini.set(EXPERIMENTAL_SECTION, "autoMemoryReclaim", auto_memory_reclaim) if auto_memory_reclaim
      self.class.new(ini)
    end

    # @return [String] the file content
    sig { returns(String) }
    def render
      @ini.render
    end

    sig { params(other: Object).returns(T::Boolean) }
    def ==(other)
      other.is_a?(WslConfig) && render == other.render
    end

    private

    # @param value [String, nil] raw `memory=` value
    # @return [Integer, nil] whole GiB, rounded up
    # @raise [MalformedValueError]
    sig { params(value: T.nilable(String)).returns(T.nilable(Integer)) }
    def parse_memory(value)
      return nil if value.nil?

      match = MEMORY_PATTERN.match(value.strip)
      raise MalformedValueError, ".wslconfig has `memory=#{value}`; WSL wants a size like 8GB or 512MB" if match.nil?

      amount = Integer(T.must(match[1]))
      case T.must(match[2]).upcase
      when "GB" then amount
      when "TB" then amount * 1024
      else (amount.to_f / MIB_PER_GIB).ceil
      end
    end
  end
end
