# frozen_string_literal: true

module Dev
  module Plan
    module_function

    # Normalize a markdown plan body for the issue: LF, single trailing
    # newline. Callers pass the markdown body only — not Cursor YAML
    # frontmatter or the ai-flow sync header.
    #
    # @param plan_body [String]
    # @return [String]
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
    def from_issue_body(issue_body)
      "#{(issue_body || "").gsub("\r\n", "\n").rstrip}\n"
    end

    # The ai-flow sync header: an HTML comment at the top of a linked plan file
    # (invisible in both GitHub and Cursor plan rendering) carrying the issue
    # cross-reference and the remote `updated_at` recorded at last sync.
    class Header
      PATTERN = /\A<!-- ai-flow\nissue: (?<owner_repo>[^#\s]+)#(?<number>\d+)\nsynced_at: (?<synced_at>\S+)\n-->\n/

      # @return [String] "owner/repo"
      attr_reader :owner_repo

      # @return [Integer] issue number
      attr_reader :number

      # @return [String] remote `updated_at` recorded at last sync (ISO 8601)
      attr_reader :synced_at

      # @param owner_repo [String] "owner/repo"
      # @param number [Integer]
      # @param synced_at [String]
      def initialize(owner_repo:, number:, synced_at:)
        @owner_repo = owner_repo
        @number = number
        @synced_at = synced_at
      end

      class << self
        # Split a plan file's content into its header and body.
        #
        # @param content [String]
        # @return [Array(Header | nil, String)] header (nil when unlinked) and body
        def split(content)
          match = PATTERN.match(content)
          return [nil, content] unless match

          header = new(
            owner_repo: match[:owner_repo],
            number: Integer(match[:number]),
            synced_at: match[:synced_at],
          )
          [header, match.post_match]
        end
      end

      # @return [String] "owner/repo#number"
      def issue_ref
        "#{owner_repo}##{number}"
      end

      # @param synced_at [String] new sync timestamp
      # @return [Header]
      def with_synced_at(synced_at)
        self.class.new(owner_repo: owner_repo, number: number, synced_at: synced_at)
      end

      # @return [String] the serialized header block (trailing newline included)
      def render
        "<!-- ai-flow\nissue: #{issue_ref}\nsynced_at: #{synced_at}\n-->\n"
      end
    end
  end
end
