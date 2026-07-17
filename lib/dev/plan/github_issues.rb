# frozen_string_literal: true

require "json"

module Dev
  module Plan
    # GitHub Issues API access for plan sync, via the authenticated `gh` CLI
    # (the same boundary the rest of dev uses — no extra token management).
    # JSON payloads go through `--input -` so bodies never hit argv.
    class GithubIssues
      class Error < RuntimeError; end

      Issue = Struct.new(:number, :title, :body, :updated_at, :html_url, keyword_init: true)

      # @param executor [Dev::Plan::Executor] CLI boundary (injectable for tests)
      def initialize(executor: Executor.new)
        @executor = executor
      end

      # @param owner_repo [String] "owner/repo"
      # @param number [Integer]
      # @return [Issue]
      # @raise [Error] when the issue can't be fetched
      def get(owner_repo, number)
        out = gh_api("repos/#{owner_repo}/issues/#{number}")
        parse_issue(out)
      end

      # @param owner_repo [String] "owner/repo"
      # @param title [String]
      # @param body [String]
      # @return [Issue] the created issue
      # @raise [Error] when creation fails
      def create(owner_repo, title:, body:)
        payload = JSON.generate({ title: title, body: body })
        out = gh_api("repos/#{owner_repo}/issues", method: "POST", input: payload)
        parse_issue(out)
      end

      # PATCH the issue body (and optionally title). Returns the updated issue,
      # whose `updated_at` is what the caller records as the new sync point.
      #
      # @param owner_repo [String] "owner/repo"
      # @param number [Integer]
      # @param body [String]
      # @param title [String, nil] new title, or nil to leave unchanged
      # @return [Issue]
      # @raise [Error] when the update fails
      def update(owner_repo, number, body:, title: nil)
        fields = { body: body }
        fields[:title] = title if title
        out = gh_api("repos/#{owner_repo}/issues/#{number}", method: "PATCH", input: JSON.generate(fields))
        parse_issue(out)
      end

      private

      # @param path [String] API path
      # @param method [String, nil] HTTP method (nil = GET)
      # @param input [String, nil] JSON payload piped to stdin
      # @return [String] response body
      # @raise [Error] on any gh failure, with an actionable message
      def gh_api(path, method: nil, input: nil)
        argv = ["gh", "api"]
        argv += ["-X", method] if method
        argv += ["--input", "-"] if input
        argv << path
        out, err, ok = @executor.capture(*argv, stdin: input)
        return out if ok

        raise Error, "gh CLI not found — install it with: brew install gh" if err.include?("No such file")
        raise Error, "gh is not authenticated — run: gh auth login" if err.include?("gh auth login")

        raise Error, "gh api #{path} failed: #{err.strip}"
      end

      # @param json [String]
      # @return [Issue]
      def parse_issue(json)
        data = JSON.parse(json)
        Issue.new(
          number: data.fetch("number"),
          title: data.fetch("title"),
          body: data["body"] || "",
          updated_at: data.fetch("updated_at"),
          html_url: data.fetch("html_url"),
        )
      rescue JSON::ParserError, KeyError => e
        raise Error, "unexpected gh api response: #{e.message}"
      end
    end
  end
end
