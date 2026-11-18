# typed: strict
# frozen_string_literal: true

require "fileutils"
require "pathname"

module Dev
  # The one writer of a project's activation lisps.
  #
  # `.shadowenv.d/` lives in the project, and the project is bind-mounted
  # into the build container — but not that directory: an activation names
  # one build host's prefixes (`/opt/homebrew` against Linuxbrew's), so
  # each side of the container has a shadowenv directory of its own, and
  # the container's is mounted over the host's at the one path shadowenv
  # reads (BuildContainer::CONTAINER_SHADOWENV_DIR). A writer on either
  # side therefore writes `.shadowenv.d/<file>` and reaches its own side's
  # directory; neither side ever sees the other's lisps.
  #
  # Writers decide the content; this module only places it, skips a write
  # that would change nothing, and trusts the directory after a change.
  module ShadowenvFile
    extend T::Sig

    module_function

    # Write an activation lisp, when it differs from what the project
    # already has, then trust shadowenv.
    #
    # @param project_root [String, Pathname] project root (`.shadowenv.d` lives there)
    # @param filename [String] the lisp's file name, e.g. "510_ruby.lisp"
    # @param body [String] the lisp source
    # @return [Boolean] true when the file was (re)written, false when already current
    sig { params(project_root: T.any(String, Pathname), filename: String, body: String).returns(T::Boolean) }
    def write!(project_root:, filename:, body:)
      shadowenv_d = Pathname.new(project_root) / ".shadowenv.d"
      lisp_path = shadowenv_d / filename
      return false if lisp_path.file? && lisp_path.read == body

      FileUtils.mkdir_p(shadowenv_d)
      lisp_path.write(body)
      Dir.chdir(project_root.to_s) do
        Kernel.system("shadowenv", "trust", out: File::NULL, err: File::NULL)
      end
      true
    end
  end
end
