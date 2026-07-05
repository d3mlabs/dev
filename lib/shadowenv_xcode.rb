# frozen_string_literal: true

require "fileutils"

# Shadowenv Xcode provisioning: generates .shadowenv.d/520_xcode.lisp so
# DEVELOPER_DIR points at the dev-pinned Xcode (see Dev::Deps::XcodeIntegration)
# inside the project — xcodebuild/xcrun/UBT then ride the pin instead of
# whatever xcode-select or the App Store last touched.
module ShadowenvXcode
  LISP_FILENAME = "520_xcode.lisp"

  module_function

  # Returns true when .shadowenv.d/520_xcode.lisp exists and already
  # provisions the given developer dir.
  def provisioned?(developer_dir, project_root:)
    lisp_path = File.join(project_root.to_s, ".shadowenv.d", LISP_FILENAME)
    return false unless File.exist?(lisp_path)

    File.read(lisp_path).include?(%((env/set "DEVELOPER_DIR" "#{developer_dir}")))
  end

  # Write the lisp and trust shadowenv. Idempotent.
  #
  # @param project_root [String, Pathname] project root directory
  # @param version [String] pinned Xcode version (for the provide record)
  # @param developer_dir [String] .../Xcode-<ver>.app/Contents/Developer
  def setup!(project_root:, version:, developer_dir:)
    shadowenv_d = File.join(project_root.to_s, ".shadowenv.d")
    FileUtils.mkdir_p(shadowenv_d)
    File.write(File.join(shadowenv_d, LISP_FILENAME), generate_xcode_lisp(version, developer_dir))

    Dir.chdir(project_root.to_s) do
      system("shadowenv", "trust", out: File::NULL, err: File::NULL)
    end

    true
  end

  # @param version [String]
  # @param developer_dir [String]
  # @return [String]
  def generate_xcode_lisp(version, developer_dir)
    <<~LISP
      (provide "xcode" "#{version}")

      (env/set "DEVELOPER_DIR" "#{developer_dir}")
    LISP
  end
end
