# frozen_string_literal: true

module Dev
  module Plan
    module_function

    # Render a plan body as an issue body: verbatim content, normalized to a
    # single trailing newline.
    #
    # @param plan_body [String]
    # @return [String]
    def to_issue_body(plan_body)
      "#{plan_body.rstrip}\n"
    end

    # Extract the plan body from an issue body. Issue bodies use CRLF line
    # endings when edited via the GitHub web UI, so normalize to LF — the
    # local file and merge base always use LF.
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

      # Split a plan file's content into its header and body.
      #
      # @param content [String]
      # @return [Array(Header | nil, String)] header (nil when unlinked) and body
      def self.split(content)
        match = PATTERN.match(content)
        return [nil, content] unless match

        header = new(
          owner_repo: match[:owner_repo],
          number: Integer(match[:number]),
          synced_at: match[:synced_at],
        )
        [header, match.post_match]
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
