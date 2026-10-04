# typed: strict
# frozen_string_literal: true

module Dev
  # The version of this dev: the `VERSION` file at dev's root, which the
  # release script bumps and the dev-core formula installs beside `bin`,
  # `src` and `lib`. One reader for both the host (`dev version`, and the
  # version it provisions into its containers) and the dev inside a
  # container (what the host compares against).
  module Version
    extend T::Sig

    # dev's root: a source checkout, or the formula's `libexec/dev`.
    ROOT = T.let(File.expand_path("../..", __dir__), String)

    # Raised when the root carries no VERSION file — a dev-core installed
    # from a formula that predates shipping it.
    class UnknownVersionError < StandardError
      extend T::Sig

      # @param root [String] where VERSION was expected
      sig { params(root: String).void }
      def initialize(root:)
        super("dev: no VERSION file at #{root} — this dev-core predates shipping one; " \
          "run brew upgrade d3mlabs/d3mlabs/dev-core (or your deployment formula) and retry")
      end
    end

    class << self
      extend T::Sig

      # The version string, trimmed.
      #
      # @param root [String] dev's root (injectable for tests)
      # @return [String]
      # @raise [UnknownVersionError] when the root has no VERSION file
      sig { params(root: String).returns(String) }
      def current(root: ROOT)
        path = File.join(root, "VERSION")
        raise UnknownVersionError.new(root:) unless File.file?(path)

        File.read(path).strip
      end
    end
  end
end
