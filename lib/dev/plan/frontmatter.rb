# frozen_string_literal: true

require "yaml"

module Dev
  module Plan
    # Cursor plan YAML frontmatter (`---` … `---`) — local editor state
    # (picker label, overview, todos). Peeled before any GitHub sync so the
    # issue body stays markdown-only.
    class Frontmatter
      FENCE_LINE = /\A---\n?\z/

      class << self
        # Peel a Cursor-like YAML frontmatter block from the start of +content+.
        # Only a leading `---` … `---` fence whose interior is a YAML mapping is
        # removed; ordinary markdown horizontal rules deeper in the body, or a
        # leading `---` that is not a mapping, are left alone.
        #
        # @param content [String]
        # @return [Array(String | nil, String)] frontmatter block (including
        #   fences and a trailing newline after the closing fence) or nil, and
        #   the remainder
        def split(content)
          lines = content.lines
          return [nil, content] if lines.empty? || !fence?(lines.fetch(0))

          close_index = (1...lines.length).find { |index| fence?(lines.fetch(index)) }
          return [nil, content] unless close_index

          yaml_text = lines[1...close_index].join
          return [nil, content] unless mapping?(yaml_text)

          frontmatter = lines[0..close_index].join
          frontmatter = "#{frontmatter}\n" unless frontmatter.end_with?("\n")
          body = lines[(close_index + 1)..].join
          [frontmatter, body]
        end

        private

        # @param line [String]
        # @return [Boolean]
        def fence?(line)
          line.match?(FENCE_LINE)
        end

        # @param yaml_text [String] interior between fences
        # @return [Boolean] true when the interior parses as a YAML mapping
        def mapping?(yaml_text)
          parsed = YAML.safe_load(yaml_text)
          parsed.is_a?(Hash)
        rescue Psych::SyntaxError, Psych::DisallowedClass
          false
        end
      end
    end
  end
end
