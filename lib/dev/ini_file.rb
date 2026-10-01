# typed: strict
# frozen_string_literal: true

module Dev
  # A minimal INI editor for the files WSL reads (`.wslconfig`, `/etc/wsl.conf`):
  # `[section]` headers and `key=value` lines. Reads are case-insensitive on
  # section and key names, as WSL's are. Writes rewrite a key in place when
  # present and append it to its section (creating the section at the end of
  # the file) when not — and touch nothing else: other lines, spelling, and
  # the file's line endings survive byte for byte. The file is the user's.
  class IniFile
    extend T::Sig

    SECTION_PATTERN = /\A\s*\[\s*([^\]]+?)\s*\]\s*\z/
    KEY_PATTERN = /\A(\s*)([A-Za-z][A-Za-z0-9]*)(\s*=\s*)(.*?)(\s*)\z/

    class << self
      extend T::Sig

      # @param text [String] the file's content ("" for a missing file)
      # @return [IniFile]
      sig { params(text: String).returns(IniFile) }
      def parse(text)
        new(text.lines)
      end
    end

    # @param lines [Array<String>] the file's lines, line endings included
    sig { params(lines: T::Array[String]).void }
    def initialize(lines)
      @lines = lines
    end

    # The trimmed value of +key+ inside +section+, or nil.
    #
    # @param section [String]
    # @param key [String]
    # @return [String, nil]
    sig { params(section: String, key: String).returns(T.nilable(String)) }
    def value(section, key)
      range = section_range(@lines, section)
      return nil if range.nil?

      T.must(@lines[range]).each do |line|
        match = KEY_PATTERN.match(line.chomp)
        return match[4] if match && T.must(match[2]).casecmp?(key)
      end
      nil
    end

    # A copy with +key+ set to +value+ inside +section+.
    #
    # @param section [String]
    # @param key [String]
    # @param value [String]
    # @return [IniFile]
    sig { params(section: String, key: String, value: String).returns(IniFile) }
    def set(section, key, value)
      lines = @lines.dup
      eol = line_ending(lines)
      range = section_range(lines, section)
      if range.nil?
        terminate_last_line(lines, eol)
        lines << eol unless lines.empty?
        lines << "[#{section}]#{eol}"
        lines << "#{key}=#{value}#{eol}"
        return self.class.new(lines)
      end

      range.each do |index|
        match = KEY_PATTERN.match(T.must(lines[index]).chomp)
        next unless match && T.must(match[2]).casecmp?(key)

        lines[index] = "#{match[1]}#{match[2]}#{match[3]}#{value}#{match[5]}#{eol}"
        return self.class.new(lines)
      end

      # Append after the section's last non-blank line (the header itself for
      # an empty section) so a blank separator before the next section stays.
      insert_at = range.end - 1
      insert_at -= 1 while insert_at >= range.begin && T.must(lines[insert_at]).strip.empty?
      terminate_last_line(lines, eol) if insert_at == lines.size - 1
      lines.insert(insert_at + 1, "#{key}=#{value}#{eol}")
      self.class.new(lines)
    end

    # @return [String] the file content
    sig { returns(String) }
    def render
      @lines.join
    end

    sig { params(other: Object).returns(T::Boolean) }
    def ==(other)
      other.is_a?(IniFile) && render == other.render
    end

    private

    # Indexes of +section+'s body lines (header excluded, up to the next
    # header or EOF), or nil when there is no such section.
    #
    # @param lines [Array<String>]
    # @param section [String]
    # @return [Range, nil]
    sig { params(lines: T::Array[String], section: String).returns(T.nilable(T::Range[Integer])) }
    def section_range(lines, section)
      start = lines.index { |line| (m = SECTION_PATTERN.match(line.chomp)) && T.must(m[1]).casecmp?(section) }
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
