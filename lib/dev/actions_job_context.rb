# typed: strict
# frozen_string_literal: true

module Dev
  # Whether this dev process runs inside a GitHub Actions job — the
  # generic lifecycle workflow's, or any other. One fact with one reader:
  # a lifecycle verb that would leave the machine from inside a job is a
  # job dispatching a job. The verb got there because a runner
  # was told to run it; a runner that then finds itself not to be the
  # build's environment is misprovisioned, and the answer is to say so,
  # not to re-dispatch — once onto itself, or forever between two.
  #
  # Read from GitHub's own marker, `GITHUB_ACTIONS=true`, which every job
  # carries on every runner kind; declared by the runner, never inferred
  # from a hostname or a user.
  module ActionsJobContext
    extend T::Sig

    MARKER = "GITHUB_ACTIONS"

    class << self
      extend T::Sig

      # Whether the given environment carries the job marker.
      #
      # @param env [Hash{String => String}] the environment to read, the
      #   process's own by default
      # @return [Boolean]
      sig { params(env: T::Hash[String, String]).returns(T::Boolean) }
      def inside?(env = ENV.to_h)
        env[MARKER] == "true"
      end
    end
  end
end
