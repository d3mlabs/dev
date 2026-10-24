# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/shadowenv_file"

module Dev
  # Shadowenv PATH activation: writes a `.shadowenv.d/<file>.lisp` that
  # prepends a set of directories to PATH inside the project, so a project
  # runs exactly the tools its lock names — the locked brew keg rather than
  # whichever keg brew linked, a published gh tree's `bin/` without a
  # hand-sourced script (ADR-0010, dev#289).
  #
  # Integrations decide *which* directories; this module only renders the
  # file and hands it to ShadowenvFile, which places it for the side this
  # dev is on. The provide record carries the activated set so a reader of
  # the file can tell what it stands for, and so the file is rewritten
  # exactly when the set changes.
  module ShadowenvPath
    extend T::Sig

    module_function

    # Write the activation when it differs from what the project already
    # has, then trust shadowenv. An empty `paths` still writes the provide,
    # so a set that shrank to nothing clears its stale prepends. Inside the
    # build container the file is the `_container` sibling (ShadowenvFile).
    #
    # @param project_root [String, Pathname] project root (`.shadowenv.d` lives there)
    # @param filename [String] the lisp file, e.g. "515_brew.lisp"
    # @param provide [Array(String, String)] the provide record: integration name, activated set
    # @param paths [Array<String>] absolute directories to prepend, in order
    # @return [Boolean] true when the file was (re)written, false when already current
    sig do
      params(
        project_root: T.any(String, Pathname),
        filename: String,
        provide: [String, String],
        paths: T::Array[String],
      ).returns(T::Boolean)
    end
    def setup!(project_root:, filename:, provide:, paths:)
      ShadowenvFile.write!(project_root:, filename:, body: generate_path_lisp(provide:, paths:))
    end

    # @param provide [Array(String, String)] integration name, activated set
    # @param paths [Array<String>] absolute directories to prepend, in order
    # @return [String] lisp source
    sig { params(provide: [String, String], paths: T::Array[String]).returns(String) }
    def generate_path_lisp(provide:, paths:)
      name, set = provide
      prepends = paths.map { |path| %((env/prepend-to-pathlist "PATH" "#{path}")) }
      [%((provide "#{name}" "#{set}")), *prepends].join("\n") + "\n"
    end
  end
end
