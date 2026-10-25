# typed: strict
# frozen_string_literal: true

require "open3"

module Dev
  # The host's GitHub identity, as the gh CLI holds it — the one credential
  # dev carries to every private GitHub surface: the gh releases the store
  # pulls, and the container registry the environment image lives in
  # (dev#277). A workflow's GITHUB_TOKEN rides the same path through GH_TOKEN,
  # which gh honours; a self-hosted runner's own login is it otherwise. No
  # second secret, no repo-level grant.
  #
  # Reads only: dev never writes gh's credential store. Every gh call is one
  # method, so a test stubs the CLI boundary and nothing else.
  class GhAuth
    extend T::Sig

    # gh holds no login for github.com.
    class NotAuthenticatedError < StandardError; end

    # The token reports its scopes and the one a command needs is missing.
    class MissingScopeError < StandardError; end

    # No gh CLI on PATH.
    class GhMissingError < StandardError; end

    # The scopes a private GHCR package needs: pulling, and pushing.
    READ_PACKAGES = "read:packages"
    WRITE_PACKAGES = "write:packages"

    # The username a registry login sends when the token cannot read /user
    # (a workflow's installation token). GHCR authenticates the token alone
    # and ignores the name.
    ANONYMOUS_LOGIN = "token"

    # The response header a classic OAuth token reports its scopes in.
    # Installation and fine-grained tokens carry no such header.
    SCOPES_HEADER = /^x-oauth-scopes:\s*(.*)$/i

    sig { void }
    def initialize
      @login = T.let(nil, T.nilable(String))
      @scopes = T.let(nil, T.nilable(T::Array[String]))
    end

    # @return [String] the token gh would use for github.com
    # @raise [NotAuthenticatedError] when gh holds none
    # @raise [GhMissingError] when the gh CLI is not installed
    sig { returns(String) }
    def token
      out, _err, ok = run_gh("auth", "token")
      raise NotAuthenticatedError, "gh is not authenticated — run: gh auth login" unless ok

      out.strip
    end

    # @return [String] the authenticated user's handle, or ANONYMOUS_LOGIN
    #   when the token cannot read /user
    sig { returns(String) }
    def login
      @login ||= begin
        out, _err, ok = run_gh("api", "user", "--jq", ".login")
        ok && !out.strip.empty? ? out.strip : ANONYMOUS_LOGIN
      end
    end

    # @return [Array<String>] the token's OAuth scopes; empty when the token
    #   reports none (see SCOPES_HEADER)
    sig { returns(T::Array[String]) }
    def scopes
      @scopes ||= begin
        out, _err, _ok = run_gh("api", "-i", "rate_limit")
        header = out.each_line.find { |line| line.match?(SCOPES_HEADER) }
        header ? T.must(SCOPES_HEADER.match(header))[1].to_s.split(",").map(&:strip).reject(&:empty?) : []
      end
    end

    # @return [Boolean] whether the token reports scopes at all
    sig { returns(T::Boolean) }
    def scopes_reported?
      !scopes.empty?
    end

    # Refuse early, with the fix, when a classic token is known to lack a
    # scope. A token reporting no scopes passes: the registry call that
    # needs the scope is the only test it admits.
    #
    # @param scope [String] READ_PACKAGES or WRITE_PACKAGES
    # @return [void]
    # @raise [MissingScopeError]
    sig { params(scope: String).void }
    def require_scope!(scope)
      return unless scopes_reported?
      return if scopes.include?(scope)

      raise MissingScopeError, "gh's token lacks #{scope} — run: gh auth refresh -s #{scope}"
    end

    private

    # The CLI boundary.
    #
    # @param args [Array<String>] gh's argv
    # @return [Array(String, String, Boolean)] stdout, stderr, success
    # @raise [GhMissingError]
    sig { params(args: String).returns([String, String, T::Boolean]) }
    def run_gh(*args)
      out, err, status = T.unsafe(Open3).capture3("gh", *args)
      [out, err, status.success?]
    rescue Errno::ENOENT
      raise GhMissingError, "gh CLI not found — install it with: brew install gh"
    end
  end
end
