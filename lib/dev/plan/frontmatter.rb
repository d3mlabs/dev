# typed: strict
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
        extend T::Sig

        # Peel a Cursor-like YAML frontmatter block from the start of +content+.
        # Only a leading `---` … `---` fence whose interior is a YAML mapping is
        # removed; ordinary markdown horizontal rules deeper in the body, or a
        # leading `---` that is not a mapping, are left alone.
        #
        # @param content [String]
        # @return [Array(String | nil, String)] frontmatter block (including
        #   fences and a trailing newline after the closing fence) or nil, and
        #   the remainder
        sig { params(content: String).returns([T.nilable(String), String]) }
        def split(content)
          lines = content.lines
          return [nil, content] if lines.empty? || !fence?(lines.fetch(0))

          close_index = (1...lines.length).find { |index| fence?(lines.fetch(index)) }
          return [nil, content] unless close_index

          yaml_text = T.must(lines[1...close_index]).join
          return [nil, content] unless mapping?(yaml_text)

          frontmatter = T.must(lines[0..close_index]).join
          frontmatter = "#{frontmatter}\n" unless frontmatter.end_with?("\n")
          body = T.must(lines[(close_index + 1)..]).join
          [frontmatter, body]
        end

        # True when the block carries no content — every value in its mapping
        # is nil, false, an empty string, or an empty collection. Cursor writes
        # such a block (`name: ""`, `todos: []`, …) for an unfilled draft.
        #
        # @param frontmatter [String] a block produced by {.split}, fences included
        # @return [Boolean]
        sig { params(frontmatter: String).returns(T::Boolean) }
        def empty?(frontmatter)
          interior = T.must(frontmatter.lines[1..-2]).join
          YAML.safe_load(interior).values.all? { |value| blank_value?(value) }
        end

        private

        # @param value [Object] a value from the frontmatter's YAML mapping
        # @return [Boolean]
        sig { params(value: T.untyped).returns(T::Boolean) }
        def blank_value?(value)
          return true if value.nil? || value == false

          value.respond_to?(:empty?) && value.empty?
        end

        # @param line [String]
        # @return [Boolean]
        sig { params(line: String).returns(T::Boolean) }
        def fence?(line)
          line.match?(FENCE_LINE)
        end

        # @param yaml_text [String] interior between fences
        # @return [Boolean] true when the interior parses as a YAML mapping
        sig { params(yaml_text: String).returns(T::Boolean) }
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
