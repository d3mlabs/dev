# typed: strict
# frozen_string_literal: true

require "fileutils"
require "pathname"
require "dev/project_shadowenv"

module Dev
  # Shadowenv Xcode provisioning: generates .shadowenv.d/520_xcode.lisp so
  # DEVELOPER_DIR points at the dev-pinned Xcode (see Dev::Deps::XcodeIntegration)
  # inside the project — xcodebuild/xcrun/UBT then ride the pin instead of
  # whatever xcode-select or the App Store last touched.
  module ShadowenvXcode
    extend T::Sig
    include Kernel

    LISP_FILENAME = "520_xcode.lisp"

    module_function

    # Returns true when .shadowenv.d/520_xcode.lisp exists and already
    # provisions the given developer dir.
    sig { params(developer_dir: String, project_root: T.any(String, Pathname)).returns(T::Boolean) }
    def provisioned?(developer_dir, project_root:)
      lisp_path = ProjectShadowenv.new(project_root).dir / LISP_FILENAME
      return false unless File.exist?(lisp_path)

      File.read(lisp_path).include?(%((env/set "DEVELOPER_DIR" "#{developer_dir}")))
    end

    # Write the lisp and trust shadowenv. Idempotent.
    #
    # @param project_root [String, Pathname] project root directory
    # @param version [String] pinned Xcode version (for the provide record)
    # @param developer_dir [String] .../Xcode-<ver>.app/Contents/Developer
    sig do
      params(
        project_root: T.any(String, Pathname),
        version: String,
        developer_dir: String,
      ).returns(T::Boolean)
    end
    def setup!(project_root:, version:, developer_dir:)
      shadowenv = ProjectShadowenv.new(project_root)
      shadowenv_d = shadowenv.dir
      FileUtils.mkdir_p(shadowenv_d)
      File.write(File.join(shadowenv_d, LISP_FILENAME), generate_xcode_lisp(version, developer_dir))

      system("shadowenv", "trust", chdir: shadowenv.search_root.to_s, out: File::NULL, err: File::NULL)

      true
    end

    # @param version [String]
    # @param developer_dir [String]
    # @return [String]
    sig { params(version: String, developer_dir: String).returns(String) }
    def generate_xcode_lisp(version, developer_dir)
      <<~LISP
        (provide "xcode" "#{version}")

        (env/set "DEVELOPER_DIR" "#{developer_dir}")
      LISP
    end
  end
end
