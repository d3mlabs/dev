# frozen_string_literal: true

require "fileutils"

# Shadowenv Unreal Engine provisioning: resolves the UE engine root, generates
# .shadowenv.d/530_unreal.lisp so UE_ROOT, UE_PROJECT, and engine binaries
# are available for IDE code intelligence (CLion, Rider).
#
# Unlike LLVM, Unreal Engine installs vary widely. The engine root must be
# specified explicitly via ue_root parameter or UE_ROOT env var. Common
# detection paths are checked as a fallback.
#
# Skipped on Linux / CI where builds happen inside a container with UE baked in.
module ShadowenvUnreal
  LISP_FILENAME = "530_unreal.lisp"

  # Well-known Unreal Engine locations on macOS, checked in order.
  SEARCH_PATHS = [
    File.join(Dir.home, "UnrealEngine"),
    "/Users/Shared/UnrealEngine",
    "/opt/unreal-engine",
  ].freeze

  module_function

  # Returns the Unreal Engine root directory, or nil if not found.
  # Checks: explicit env var, then well-known paths.
  def detect_ue_root
    from_env = ENV["UE_ROOT"]
    return from_env if from_env && valid_ue_root?(from_env)

    SEARCH_PATHS.each do |path|
      expanded = File.expand_path(path)
      return expanded if valid_ue_root?(expanded)
    end
    nil
  end

  # Returns true when .shadowenv.d/530_unreal.lisp exists and provisions
  # from the given UE root.
  def provisioned?(ue_root, project_root:)
    lisp_path = File.join(project_root.to_s, ".shadowenv.d", LISP_FILENAME)
    return false unless File.exist?(lisp_path)
    content = File.read(lisp_path)
    content.include?(%(provide "unreal")) && content.include?(ue_root)
  end

  # Full provisioning: write .shadowenv.d/530_unreal.lisp, trust shadowenv.
  # Idempotent. Returns true on success, false if UE root is nil.
  #
  # @param project_root [String, Pathname] project root directory
  # @param ue_root      [String, nil]      explicit UE engine root (falls back to detect)
  # @param ue_project   [String, nil]      path to .uproject file (optional)
  def setup!(project_root:, ue_root: nil, ue_project: nil)
    root = ue_root || detect_ue_root
    unless root
      $stderr.puts "dev: Unreal Engine not found. Set UE_ROOT or install to a known location."
      return false
    end

    shadowenv_d = File.join(project_root.to_s, ".shadowenv.d")
    FileUtils.mkdir_p(shadowenv_d)
    lisp_path = File.join(shadowenv_d, LISP_FILENAME)
    File.write(lisp_path, generate_unreal_lisp(root, ue_project:))

    Dir.chdir(project_root.to_s) do
      system("shadowenv", "trust", out: File::NULL, err: File::NULL)
    end

    true
  end

  # Returns true on Linux or when CI env is set -- environments where
  # UE is baked into the build container and shadowenv provisioning is
  # unnecessary.
  def ci_or_linux?
    !!(ENV["CI"].to_s =~ /\A(true|1)\z/i) || RUBY_PLATFORM.to_s.include?("linux")
  end

  # Generate the shadowenv lisp that sets UE_ROOT, UE_PROJECT, and
  # prepends engine binaries to PATH.
  #
  # @param ue_root    [String] Unreal Engine root directory
  # @param ue_project [String, nil] optional path to .uproject file
  # @return [String]
  def generate_unreal_lisp(ue_root, ue_project: nil)
    bin = File.join(ue_root, "Engine", "Binaries", platform_subdir)
    lisp = <<~LISP
      (provide "unreal" "#{ue_root}")

      (env/set "UE_ROOT" "#{ue_root}")
      (env/prepend-to-pathlist "PATH" "#{bin}")
    LISP
    lisp += <<~LISP if ue_project
      (env/set "UE_PROJECT" "#{ue_project}")
    LISP
    lisp
  end

  # --- internal helpers ------------------------------------------------

  # Validates that a directory looks like a UE engine root by checking
  # for Engine/Build/Build.version.
  def valid_ue_root?(path)
    File.directory?(path) && File.exist?(File.join(path, "Engine", "Build", "Build.version"))
  end

  # Returns the platform-specific binaries subdirectory.
  def platform_subdir
    if RUBY_PLATFORM.include?("darwin")
      "Mac"
    elsif RUBY_PLATFORM.include?("linux")
      "Linux"
    else
      "Win64"
    end
  end
end
