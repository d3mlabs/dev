# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module Dev
  module Plan
    extend T::Sig

    module_function

    # Normalize a markdown plan body for the issue: LF, single trailing
    # newline. Callers pass the markdown body only — not Cursor YAML
    # frontmatter or the ai-flow sync header.
    #
    # @param plan_body [String]
    # @return [String]
    sig { params(plan_body: String).returns(String) }
    def to_issue_body(plan_body)
      "#{plan_body.rstrip}\n"
    end

    # Normalize an issue body to a local markdown plan body. Issue bodies use
    # CRLF when edited via the GitHub web UI, so normalize to LF — the local
    # file and merge base always use LF. The result is markdown only (GitHub
    # never stores Cursor frontmatter).
    #
    # @param issue_body [String, nil]
    # @return [String]
    sig { params(issue_body: T.nilable(String)).returns(String) }
    def from_issue_body(issue_body)
      "#{(issue_body || "").gsub("\r\n", "\n").rstrip}\n"
    end

    # The ai-flow sync header: an HTML comment at the top of a linked plan file
    # (invisible in both GitHub and Cursor plan rendering) carrying the issue
    # cross-reference and the remote `updated_at` recorded at last sync.
    class Header
      extend T::Sig

      PATTERN = /\A<!-- ai-flow\nissue: (?<owner_repo>[^#\s]+)#(?<number>\d+)\nsynced_at: (?<synced_at>\S+)\n-->\n/

      # @return [String] "owner/repo"
      sig { returns(String) }
      attr_reader :owner_repo

      # @return [Integer] issue number
      sig { returns(Integer) }
      attr_reader :number

      # @return [String] remote `updated_at` recorded at last sync (ISO 8601)
      sig { returns(String) }
      attr_reader :synced_at

      # @param owner_repo [String] "owner/repo"
      # @param number [Integer]
      # @param synced_at [String]
      sig { params(owner_repo: String, number: Integer, synced_at: String).void }
      def initialize(owner_repo:, number:, synced_at:)
        @owner_repo = owner_repo
        @number = number
        @synced_at = synced_at
      end

      class << self
        extend T::Sig

        # Split a plan file's content into its header and body.
        #
        # @param content [String]
        # @return [Array(Header | nil, String)] header (nil when unlinked) and body
        sig { params(content: String).returns([T.nilable(Header), String]) }
        def split(content)
          match = PATTERN.match(content)
          return [nil, content] unless match

          header = new(
            owner_repo: T.must(match[:owner_repo]),
            number: Integer(T.must(match[:number])),
            synced_at: T.must(match[:synced_at]),
          )
          [header, match.post_match]
        end
      end

      # @return [String] "owner/repo#number"
      sig { returns(String) }
      def issue_ref
        "#{owner_repo}##{number}"
      end

      # @param synced_at [String] new sync timestamp
      # @return [Header]
      sig { params(synced_at: String).returns(Header) }
      def with_synced_at(synced_at)
        self.class.new(owner_repo: owner_repo, number: number, synced_at: synced_at)
      end

      # @return [String] the serialized header block (trailing newline included)
      sig { returns(String) }
      def render
        "<!-- ai-flow\nissue: #{issue_ref}\nsynced_at: #{synced_at}\n-->\n"
      end
    end
  end
end
