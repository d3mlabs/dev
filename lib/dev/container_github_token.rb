# typed: strict
# frozen_string_literal: true

require "open3"
require "sorbet-runtime"

module Dev
  # The host's gh token, carried into a container as GH_TOKEN. The container
  # is a build host that fetches private releases for itself (ADR-0008) and
  # a command run inside may call `gh` (a publisher's `gh release create`);
  # both need the auth the host already holds, and neither should hold a
  # copy of it: the token goes to the exec's `-e` and nowhere else — never
  # printed, never in an error message, never in the store.
  #
  # One rule for every exec dev makes: a GH_TOKEN the image's run_env names
  # wins; otherwise the host's, when gh is logged in; otherwise nothing.
  # Whose token the host holds is the host's business (dev#310).
  class ContainerGithubToken
    extend T::Sig

    # The env var gh reads its token from, inside.
    GH_TOKEN = "GH_TOKEN"

    # The host's gh token, or nil when gh is not logged in or not installed.
    #
    # @return [String, nil]
    HOST = T.let(
      lambda do
        stdout, _stderr, status = Open3.capture3("gh", "auth", "token")
        status.success? ? stdout.strip : nil
      rescue Errno::ENOENT
        nil
      end,
      T.proc.returns(T.nilable(String)),
    )

    # @param source [Proc] answers the host's gh token (nil or empty when
    #   there is none); injected so tests never shell out to gh
    sig { params(source: T.proc.returns(T.nilable(String))).void }
    def initialize(source: HOST)
      @source = source
    end

    # The env with the host's gh token added under GH_TOKEN, unless the env
    # already names one or the host has none.
    #
    # @param env [Hash{String => String}] the resolved run_env
    # @return [Hash{String => String}]
    sig { params(env: T::Hash[String, String]).returns(T::Hash[String, String]) }
    def merge_into(env)
      return env if env.key?(GH_TOKEN)

      token = @source.call
      return env if token.nil? || token.empty?

      env.merge(GH_TOKEN => token)
    end
  end
end
