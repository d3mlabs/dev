# frozen_string_literal: true

require "dev/plan/header"
require "dev/plan/frontmatter"

module Dev
  module Plan
    # The three on-disk layers of a plan file: ai-flow sync header, optional
    # Cursor YAML frontmatter, and the markdown body. Sync compares and ships
    # the markdown body only; the header and frontmatter stay local.
    class Content
      # @return [Dev::Plan::Header, nil]
      attr_reader :header

      # @return [String, nil] raw frontmatter block including `---` fences
      attr_reader :frontmatter

      # @return [String] markdown body (canonical plan prose)
      attr_reader :body

      # Parse a plan file into its layers. Canonical on-disk order is header,
      # then optional frontmatter, then body. When frontmatter sits above the
      # ai-flow header (Cursor's plan tool writes that layout, with a blank
      # line after the closing fence), both are still recognized; {#render}
      # rewrites canonical order.
      #
      # @param content [String]
      # @return [Content]
      def self.parse(content)
        header, remainder = Header.split(without_leading_blank_lines(content))
        if header
          frontmatter, body = Frontmatter.split(remainder)
          return new(header: header, frontmatter: frontmatter, body: body)
        end

        # Frontmatter may sit above a misplaced ai-flow header.
        frontmatter, after_frontmatter = Frontmatter.split(content)
        if frontmatter
          header, body = Header.split(without_leading_blank_lines(after_frontmatter))
          # No header: keep the body byte-exact (the stripped copy was only
          # for detection).
          return new(header: header, frontmatter: frontmatter, body: header ? body : after_frontmatter)
        end

        new(header: nil, frontmatter: nil, body: content)
      end

      # The Header pattern is anchored at the start of its input, so blank
      # lines ahead of the comment (Cursor writes one after its frontmatter
      # fence) are skipped before detection — and only for detection.
      #
      # @param content [String]
      # @return [String]
      def self.without_leading_blank_lines(content)
        content.sub(/\A(?:[ \t]*\n)+/, "")
      end

      # @param header [Dev::Plan::Header, nil]
      # @param frontmatter [String, nil]
      # @param body [String]
      def initialize(header:, frontmatter:, body:)
        @header = header
        @frontmatter = frontmatter
        @body = body
      end

      # Serialize in canonical order: ai-flow header, optional frontmatter,
      # markdown body.
      #
      # @return [String]
      def render
        "#{header&.render}#{frontmatter}#{body}"
      end

      # @param header [Dev::Plan::Header, nil]
      # @return [Content]
      def with_header(header)
        self.class.new(header: header, frontmatter: frontmatter, body: body)
      end

      # @param body [String]
      # @return [Content]
      def with_body(body)
        self.class.new(header: header, frontmatter: frontmatter, body: body)
      end

      # @param synced_at [String]
      # @return [Content]
      def with_synced_at(synced_at)
        with_header(header.with_synced_at(synced_at))
      end
    end
  end
end
