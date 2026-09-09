# typed: strict
# frozen_string_literal: true

require "dev/plan/header"
require "dev/plan/frontmatter"

module Dev
  module Plan
    # The three on-disk layers of a plan file: ai-flow sync header, optional
    # Cursor YAML frontmatter, and the markdown body. Sync compares and ships
    # the markdown body only; the header and frontmatter stay local.
    class Content
      extend T::Sig

      # @return [Dev::Plan::Header, nil]
      sig { returns(T.nilable(Header)) }
      attr_reader :header

      # @return [String, nil] raw frontmatter block including `---` fences
      sig { returns(T.nilable(String)) }
      attr_reader :frontmatter

      # @return [String] markdown body (canonical plan prose)
      sig { returns(String) }
      attr_reader :body

      class << self
        extend T::Sig

        # Parse a plan file into its layers. Canonical on-disk order is header,
        # then optional frontmatter, then body. When frontmatter sits above the
        # ai-flow header (Cursor's plan tool writes that layout, with a blank
        # line after the closing fence), both are still recognized; {#render}
        # rewrites canonical order. Stacked frontmatter blocks — an empty one
        # Cursor wrote above the real one — are collapsed to the block that
        # carries content.
        #
        # @param content [String]
        # @return [Content]
        sig { params(content: String).returns(Content) }
        def parse(content)
          header, remainder = Header.split(without_leading_blank_lines(content))
          if header
            frontmatter, body = split_stacked_frontmatter(remainder)
            return new(header: header, frontmatter: frontmatter, body: body)
          end

          # Frontmatter may sit above a misplaced ai-flow header.
          frontmatter, after_frontmatter = split_stacked_frontmatter(content)
          if frontmatter
            header, body = Header.split(without_leading_blank_lines(after_frontmatter))
            # No header: keep the body byte-exact (the stripped copy was only
            # for detection).
            return new(header: header, frontmatter: frontmatter, body: header ? body : after_frontmatter)
          end

          new(header: nil, frontmatter: nil, body: content)
        end

        private

        # Peel the leading frontmatter, collapsing stacked blocks: while the
        # peeled block is empty and another block follows (blank lines between
        # them tolerated), drop it in favor of the next one. Peeling stops at
        # the first block that carries content, so a body that merely starts
        # with something frontmatter-shaped is never consumed. A solitary empty
        # block (a fresh Cursor draft) is kept as-is.
        #
        # @param content [String]
        # @return [Array(String | nil, String)] the surviving frontmatter block
        #   (or nil) and the remainder
        sig { params(content: String).returns([T.nilable(String), String]) }
        def split_stacked_frontmatter(content)
          frontmatter, remainder = Frontmatter.split(content)
          return [nil, content] if frontmatter.nil?

          while Frontmatter.empty?(frontmatter)
            next_frontmatter, next_remainder = Frontmatter.split(without_leading_blank_lines(remainder))
            break if next_frontmatter.nil?

            frontmatter = next_frontmatter
            remainder = next_remainder
          end
          [frontmatter, remainder]
        end

        # The Header pattern is anchored at the start of its input, so blank
        # lines ahead of the comment (Cursor writes one after its frontmatter
        # fence) are skipped before detection — and only for detection.
        #
        # @param content [String]
        # @return [String]
        sig { params(content: String).returns(String) }
        def without_leading_blank_lines(content)
          content.sub(/\A(?:[ \t]*\n)+/, "")
        end
      end

      # @param header [Dev::Plan::Header, nil]
      # @param frontmatter [String, nil]
      # @param body [String]
      sig { params(header: T.nilable(Header), frontmatter: T.nilable(String), body: String).void }
      def initialize(header:, frontmatter:, body:)
        @header = header
        @frontmatter = frontmatter
        @body = body
      end

      # Serialize in canonical order: ai-flow header, optional frontmatter,
      # markdown body.
      #
      # @return [String]
      sig { returns(String) }
      def render
        "#{header&.render}#{frontmatter}#{body}"
      end

      # @param header [Dev::Plan::Header, nil]
      # @return [Content]
      sig { params(header: T.nilable(Header)).returns(Content) }
      def with_header(header)
        self.class.new(header: header, frontmatter: frontmatter, body: body)
      end

      # @param body [String]
      # @return [Content]
      sig { params(body: String).returns(Content) }
      def with_body(body)
        self.class.new(header: header, frontmatter: frontmatter, body: body)
      end

      # @param synced_at [String]
      # @return [Content]
      sig { params(synced_at: String).returns(Content) }
      def with_synced_at(synced_at)
        with_header(T.must(header).with_synced_at(synced_at))
      end
    end
  end
end
