# typed: strict
# frozen_string_literal: true

require "dev/gh_auth"

module Dev
  # The credential dev logs the engine in to a container registry with. By
  # default it is the host's gh login (GhAuth, dev#277): one identity for the
  # private releases and the registry alike. A host whose gh identity the
  # registry will not take states another in DEV_REGISTRY_TOKEN — a hosted
  # job runs `dev up` under a GitHub App token for the private releases, and
  # GHCR refuses App installation tokens outright, while it accepts the job's
  # own GITHUB_TOKEN (dev#351). dev does not guess which token a job holds
  # for what; the job says so, the way it already says GH_TOKEN.
  #
  # An explicit token is tried as given: the login name is the anonymous one
  # (the registry authenticates the token alone) and no scope is checked —
  # `gh auth refresh` is not the fix for a token that did not come from gh,
  # and the registry's answer is the only test it admits, as for any token
  # that reports no scopes. The token goes to the login's stdin and nowhere
  # else.
  class RegistryCredential
    extend T::Sig

    # The environment variable naming the registry token, when it is not gh's.
    ENV_VAR = "DEV_REGISTRY_TOKEN"

    # @param auth [Dev::GhAuth] the host's gh identity, the default credential
    # @param env [Hash{String => String}] the process environment (injected
    #   so tests set and unset the variable without touching ENV)
    sig { params(auth: Dev::GhAuth, env: T::Hash[String, String]).void }
    def initialize(auth: Dev::GhAuth.new, env: ENV.to_h)
      @auth = auth
      value = env[ENV_VAR]
      @explicit = T.let(value.nil? || value.empty? ? nil : value, T.nilable(String))
    end

    # @return [Boolean] whether DEV_REGISTRY_TOKEN names the token
    sig { returns(T::Boolean) }
    def explicit?
      !@explicit.nil?
    end

    # @return [String] the token to log in with
    # @raise [GhAuth::NotAuthenticatedError, GhAuth::GhMissingError] from gh,
    #   when the token is gh's
    sig { returns(String) }
    def token
      @explicit || @auth.token
    end

    # @return [String] the login name the registry is sent
    sig { returns(String) }
    def login
      @explicit ? GhAuth::ANONYMOUS_LOGIN : @auth.login
    end

    # Refuse early when gh's classic token is known to lack a scope; an
    # explicit token is not checked (see the class comment).
    #
    # @param scope [String] GhAuth::READ_PACKAGES or GhAuth::WRITE_PACKAGES
    # @return [void]
    # @raise [GhAuth::MissingScopeError]
    sig { params(scope: String).void }
    def require_scope!(scope)
      return if @explicit

      @auth.require_scope!(scope)
    end
  end
end
