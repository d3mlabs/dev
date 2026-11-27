# typed: strict
# frozen_string_literal: true

require "fileutils"
require "pathname"
require_relative "project_shadowenv"

module Dev
  # The one writer of a project's activation lisps.
  #
  # The project is bind-mounted into the build container, and an
  # activation names one build host's prefixes (`/opt/homebrew` against
  # Linuxbrew's), so each side of the container has a shadowenv of its own
  # (ProjectShadowenv): the host's at the project root, the container's
  # nested under `.shadowenv.d-container/`. A writer on either side writes
  # to this side's directory; neither side ever sees the other's lisps.
  #
  # Writers decide the content; this module only places it, skips a write
  # that would change nothing, and trusts the directory after a change.
  module ShadowenvFile
    extend T::Sig

    module_function

    # Write an activation lisp, when it differs from what the project
    # already has, then trust shadowenv.
    #
    # @param project_root [String, Pathname] project root (the shadowenv is this side's under it)
    # @param filename [String] the lisp's file name, e.g. "510_ruby.lisp"
    # @param body [String] the lisp source
    # @return [Boolean] true when the file was (re)written, false when already current
    sig { params(project_root: T.any(String, Pathname), filename: String, body: String).returns(T::Boolean) }
    def write!(project_root:, filename:, body:)
      shadowenv = ProjectShadowenv.new(project_root)
      lisp_path = shadowenv.dir / filename
      return false if lisp_path.file? && lisp_path.read == body

      FileUtils.mkdir_p(shadowenv.dir)
      lisp_path.write(body)
      Kernel.system("shadowenv", "trust", chdir: shadowenv.search_root.to_s, out: File::NULL, err: File::NULL)
      true
    end
  end
end
