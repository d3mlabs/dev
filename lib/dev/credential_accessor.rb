# typed: strict
# frozen_string_literal: true

require "stringio"

module Dev
  # Read accessor over the Credentials provider, surfaced as `dev cred get`.
  #
  # Mirrors Dev::Deps::Accessor (`dev deps path`): it exposes an internal
  # resolution detail — here the ENV → keychain → file → prompt fallback chain —
  # to shell consumers (e.g. stage.sh) so they never reimplement credential
  # lookup or hardcode a storage backend. A non-interactive miss raises the
  # provider's MissingCredentialError, whose message points at `gh secret set`.
  #
  # Credentials is injected (defaulting to the real provider) so tests can
  # exercise dispatch without loading io/console.
  class CredentialAccessor
    extend T::Sig

    class UsageError < StandardError; end

    USAGE = "usage: dev cred get <namespace> <key>"

    # @param credentials [#resolve] credential provider (default: Dev::Credentials)
    sig { params(credentials: T.untyped).void }
    def initialize(credentials: nil)
      @credentials = T.let(credentials || Dev::Credentials, T.untyped)
    end

    # Dispatch a `dev cred …` invocation and print the resolved value.
    #
    # @param args [Array<String>] argv after the "cred" command
    # @param out  [IO, StringIO] output stream
    # @raise [UsageError] on an unrecognized invocation
    sig { params(args: T::Array[String], out: T.any(IO, StringIO)).void }
    def run(args, out: $stdout)
      subcommand, *rest = args
      case subcommand
      when "get" then out.puts(get(*T.unsafe(rest)))
      else raise UsageError, USAGE
      end
    end

    private

    # @param namespace [String]
    # @param key [String]
    # @return [String] resolved credential value
    # @raise [UsageError] for a missing namespace/key
    sig { params(namespace: T.nilable(String), key: T.nilable(String)).returns(String) }
    def get(namespace = nil, key = nil)
      raise UsageError, USAGE unless namespace && key

      @credentials.resolve(
        namespace: namespace,
        key: key,
        env_var: default_env_var(namespace, key),
        prompt_label: "#{namespace} #{key}",
      )
    end

    # Conventional ENV override name for a credential, so `NAMESPACE_KEY=…`
    # overrides the stored value (matching how build_args use the arg name).
    #
    # @param namespace [String]
    # @param key [String]
    # @return [String]
    sig { params(namespace: String, key: String).returns(String) }
    def default_env_var(namespace, key)
      "#{namespace}_#{key}".upcase.gsub(/[^A-Z0-9]+/, "_")
    end
  end
end
