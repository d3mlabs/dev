# frozen_string_literal: true

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
    class UsageError < StandardError; end

    USAGE = "usage: dev cred get <namespace> <key>"

    # @param credentials [#resolve] credential provider (default: Dev::Credentials)
    def initialize(credentials: nil)
      @credentials = credentials || Dev::Credentials
    end

    # Dispatch a `dev cred …` invocation and print the resolved value.
    #
    # @param args [Array<String>] argv after the "cred" command
    # @param out  [IO] output stream
    # @raise [UsageError] on an unrecognized invocation
    def run(args, out: $stdout)
      subcommand, *rest = args
      case subcommand
      when "get" then out.puts(get(*rest))
      else raise UsageError, USAGE
      end
    end

    private

    # @param namespace [String]
    # @param key [String]
    # @return [String] resolved credential value
    # @raise [UsageError] for a missing namespace/key
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
    def default_env_var(namespace, key)
      "#{namespace}_#{key}".upcase.gsub(/[^A-Z0-9]+/, "_")
    end
  end
end
