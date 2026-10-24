# typed: strict
# frozen_string_literal: true

require "fileutils"
require "pathname"
require "dev/container_context"

module Dev
  # The one writer of a project's activation lisps, aware of which side of
  # the build container this dev is on.
  #
  # `.shadowenv.d/` lives in the project, and the project is bind-mounted
  # into the build container: one directory serves two build hosts whose
  # prefixes differ (`/opt/homebrew` against Linuxbrew's). An activation
  # written inside the container therefore goes to a `_container` sibling
  # of the host's file, wrapped in a `when-let` on the inside marker
  # (ContainerContext) so it is inert on the host, and shadowenv's lexical
  # load order (`510_ruby.lisp` before `510_ruby_container.lisp`) lets it
  # override the host's values inside. Neither side ever rewrites the
  # other's file, so one checkout serves both.
  #
  # Writers decide the content; this module only places it, skips a write
  # that would change nothing, and trusts the directory after a change.
  module ShadowenvFile
    extend T::Sig

    module_function

    # Write an activation lisp for this side, when it differs from what the
    # project already has, then trust shadowenv.
    #
    # @param project_root [String, Pathname] project root (`.shadowenv.d` lives there)
    # @param filename [String] the host-side file, e.g. "510_ruby.lisp"
    # @param body [String] the lisp source
    # @param inside [Boolean] whether this dev runs inside the build container
    # @return [Boolean] true when the file was (re)written, false when already current
    sig do
      params(
        project_root: T.any(String, Pathname),
        filename: String,
        body: String,
        inside: T::Boolean,
      ).returns(T::Boolean)
    end
    def write!(project_root:, filename:, body:, inside: ContainerContext.inside?)
      content = inside ? container_body(body) : body
      target = inside ? container_filename(filename) : filename
      shadowenv_d = Pathname.new(project_root) / ".shadowenv.d"
      lisp_path = shadowenv_d / target
      return false if lisp_path.file? && lisp_path.read == content

      FileUtils.mkdir_p(shadowenv_d)
      lisp_path.write(content)
      Dir.chdir(project_root.to_s) do
        Kernel.system("shadowenv", "trust", out: File::NULL, err: File::NULL)
      end
      true
    end

    # The container-side sibling of a host-side file.
    #
    # @param filename [String] e.g. "510_ruby.lisp"
    # @return [String] e.g. "510_ruby_container.lisp"
    sig { params(filename: String).returns(String) }
    def container_filename(filename)
      filename.sub(/\.lisp\z/, "_container.lisp")
    end

    # The body gated on the inside marker: inert wherever the marker is unset.
    #
    # @param body [String] the lisp source
    # @return [String]
    sig { params(body: String).returns(String) }
    def container_body(body)
      "(when-let ((inside (env/get \"#{ContainerContext::MARKER}\")))\n#{body})\n"
    end
  end
end
