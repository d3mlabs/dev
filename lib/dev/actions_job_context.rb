# typed: strict
# frozen_string_literal: true

module Dev
  # Whether this dev process runs inside a GitHub Actions job — the
  # generic lifecycle workflow's, or any other. One fact, read where the
  # job changes what dev does: the Actions transport refuses to carry a
  # verb out of a job (Cli::Transport::ActionsRunner — a job dispatching
  # a job would hide a misprovisioned runner behind a loop).
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
