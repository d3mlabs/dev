# typed: strict
# frozen_string_literal: true

module Dev
  # The user's `%USERPROFILE%\.wslconfig` — WSL2's VM-wide settings — as an
  # editable value. dev only cares about three `[wsl2]` keys (`processors`,
  # `memory`, `autoMemoryReclaim`), and this file is the user's: every other
  # line, the section-name and key-name spelling, and the line endings are
  # preserved byte for byte. `with` is the one way in; it rewrites a key in
  # place when present and appends it to the section (creating the section)
  # when not.
  class WslConfig
    extend T::Sig

    # A `memory=` value WSL itself would reject (it wants `<n>GB`, `<n>MB`, …).
    class MalformedValueError < RuntimeError; end

    SECTION = "wsl2"
    SECTION_PATTERN = /\A\s*\[\s*([^\]]+?)\s*\]\s*\z/
    KEY_PATTERN = /\A(\s*)([A-Za-z][A-Za-z0-9]*)(\s*=\s*)(.*?)(\s*)\z/
    MEMORY_PATTERN = /\A(\d+)\s*(GB|MB|TB)\z/i
    MIB_PER_GIB = 1024

    # Keys dev writes, in the order they are appended when missing.
    KEYS = T.let(%w[processors memory autoMemoryReclaim].freeze, T::Array[String])

    class << self
      extend T::Sig

      # @param text [String] the file's content ("" for a missing file)
      # @return [WslConfig]
      # @raise [MalformedValueError] when `memory=` is not a size WSL accepts
      sig { params(text: String).returns(WslConfig) }
      def parse(text)
        new(text.lines)
      end
    end

    # @param lines [Array<String>] the file's lines, line endings included
    sig { params(lines: T::Array[String]).void }
    def initialize(lines)
      @lines = lines
      @memory_gib = T.let(parse_memory(value_of("memory")), T.nilable(Integer))
    end

    # @return [Integer, nil] `[wsl2] processors`
    sig { returns(T.nilable(Integer)) }
    def processors
      value = value_of("processors")
      value&.to_i
    end

    # @return [Integer, nil] `[wsl2] memory`, in whole GiB (rounded up)
    sig { returns(T.nilable(Integer)) }
    attr_reader :memory_gib

    # @return [String, nil] `[wsl2] autoMemoryReclaim`
    sig { returns(T.nilable(String)) }
    def auto_memory_reclaim
      value_of("autoMemoryReclaim")
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
      values = {
        "processors" => processors&.to_s,
        "memory" => memory_gib && "#{memory_gib}GB",
        "autoMemoryReclaim" => auto_memory_reclaim,
      }
      lines = @lines.dup
      KEYS.each do |key|
        value = values.fetch(key)
        next if value.nil?

        set(lines, key, value)
      end
      self.class.new(lines)
    end

    # @return [String] the file content
    sig { returns(String) }
    def render
      @lines.join
    end

    sig { params(other: Object).returns(T::Boolean) }
    def ==(other)
      other.is_a?(WslConfig) && render == other.render
    end

    private

    # The trimmed value of +key+ inside `[wsl2]`, or nil.
    #
    # @param key [String]
    # @return [String, nil]
    sig { params(key: String).returns(T.nilable(String)) }
    def value_of(key)
      range = section_range(@lines)
      return nil if range.nil?

      T.must(@lines[range]).each do |line|
        match = KEY_PATTERN.match(line.chomp)
        return match[4] if match && T.must(match[2]).casecmp?(key)
      end
      nil
    end

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

    # Rewrite +key+ in place inside `[wsl2]`, or append it to the section
    # (creating the section at the end of the file when absent).
    #
    # @param lines [Array<String>] mutated
    # @param key [String]
    # @param value [String]
    # @return [void]
    sig { params(lines: T::Array[String], key: String, value: String).void }
    def set(lines, key, value)
      eol = line_ending(lines)
      range = section_range(lines)
      if range.nil?
        terminate_last_line(lines, eol)
        lines << eol unless lines.empty?
        lines << "[#{SECTION}]#{eol}"
        lines << "#{key}=#{value}#{eol}"
        return
      end

      range.each do |index|
        match = KEY_PATTERN.match(T.must(lines[index]).chomp)
        next unless match && T.must(match[2]).casecmp?(key)

        lines[index] = "#{match[1]}#{match[2]}#{match[3]}#{value}#{match[5]}#{eol}"
        return
      end

      # Append after the section's last non-blank line (the header itself for
      # an empty section) so a blank separator before the next section stays.
      insert_at = range.end - 1
      insert_at -= 1 while insert_at >= range.begin && T.must(lines[insert_at]).strip.empty?
      terminate_last_line(lines, eol) if insert_at == lines.size - 1
      lines.insert(insert_at + 1, "#{key}=#{value}#{eol}")
    end

    # Indexes of the `[wsl2]` section's body lines (header excluded, up to the
    # next header or EOF), or nil when there is no such section.
    #
    # @param lines [Array<String>]
    # @return [Range, nil]
    sig { params(lines: T::Array[String]).returns(T.nilable(T::Range[Integer])) }
    def section_range(lines)
      start = lines.index { |line| (m = SECTION_PATTERN.match(line.chomp)) && T.must(m[1]).casecmp?(SECTION) }
      return nil if start.nil?

      body = (start + 1)...lines.size
      finish = body.find { |i| SECTION_PATTERN.match?(T.must(lines[i]).chomp) } || lines.size
      (start + 1)...finish
    end

    # @param lines [Array<String>]
    # @return [String] "\r\n" when the file uses it, else "\n"
    sig { params(lines: T::Array[String]).returns(String) }
    def line_ending(lines)
      lines.any? { |line| line.end_with?("\r\n") } ? "\r\n" : "\n"
    end

    # Give the last line its line ending so an append starts on a new line.
    #
    # @param lines [Array<String>] mutated
    # @param eol [String]
    # @return [void]
    sig { params(lines: T::Array[String], eol: String).void }
    def terminate_last_line(lines, eol)
      last = lines.last
      lines[-1] = "#{last}#{eol}" if last && !last.end_with?("\n")
    end
  end
end
