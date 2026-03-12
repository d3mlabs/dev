# frozen_string_literal: true

require "fileutils"

# Shadowenv LLVM provisioning: resolves the Homebrew LLVM prefix, generates
# .shadowenv.d/520_llvm.lisp so clang, clang-format, clang-tidy, and lld are
# available in PATH, and CC/CXX point to the Homebrew compiler.
#
# Skipped on Linux / CI where Linuxbrew tools are already in PATH.
module ShadowenvLlvm
  LISP_FILENAME = "520_llvm.lisp"
  FORMULA_NAMES = ["llvm@22", "llvm"].freeze

  module_function

  # Returns the Homebrew prefix for the LLVM formula, or nil if not installed.
  def detect_llvm_prefix
    FORMULA_NAMES.each do |name|
      prefix = brew_prefix_for(name)
      return prefix if prefix
    end
    nil
  end

  # Returns true when .shadowenv.d/520_llvm.lisp exists and provisions from
  # the given prefix. This is the fast-path check run before every dev command.
  def provisioned?(llvm_prefix, project_root:)
    lisp_path = File.join(project_root.to_s, ".shadowenv.d", LISP_FILENAME)
    return false unless File.exist?(lisp_path)
    content = File.read(lisp_path)
    content.include?(%(provide "llvm")) && content.include?(llvm_prefix)
  end

  # Full provisioning: write .shadowenv.d/520_llvm.lisp, trust shadowenv.
  # Idempotent. Returns true on success, false if LLVM prefix is nil.
  def setup!(project_root:, llvm_prefix: nil)
    prefix = llvm_prefix || detect_llvm_prefix
    unless prefix
      $stderr.puts "dev: LLVM not found via Homebrew. Run: brew install llvm"
      return false
    end

    shadowenv_d = File.join(project_root.to_s, ".shadowenv.d")
    FileUtils.mkdir_p(shadowenv_d)
    lisp_path = File.join(shadowenv_d, LISP_FILENAME)
    File.write(lisp_path, generate_llvm_lisp(prefix))

    Dir.chdir(project_root.to_s) do
      system("shadowenv", "trust", out: File::NULL, err: File::NULL)
    end

    true
  end

  # Returns true on Linux or when CI env is set -- environments where
  # Linuxbrew puts LLVM tools in PATH and shadowenv provisioning is
  # unnecessary.
  def ci_or_linux?
    !!(ENV["CI"].to_s =~ /\A(true|1)\z/i) || RUBY_PLATFORM.to_s.include?("linux")
  end

  # Generate the shadowenv lisp that puts LLVM in PATH and sets CC/CXX.
  def generate_llvm_lisp(llvm_prefix)
    bin = File.join(llvm_prefix, "bin")
    lib_cxx = File.join(llvm_prefix, "lib", "c++")
    <<~LISP
      (provide "llvm" "#{llvm_prefix}")

      (env/prepend-to-pathlist "PATH" "#{bin}")
      (env/set "CC" "#{File.join(bin, "clang")}")
      (env/set "CXX" "#{File.join(bin, "clang++")}")
      (env/set "LDFLAGS" "-L#{lib_cxx} -Wl,-rpath,#{lib_cxx}")
    LISP
  end

  # --- internal helpers ------------------------------------------------

  def brew_prefix_for(formula)
    return nil unless system("command -v brew >/dev/null 2>&1")
    out = IO.popen(["brew", "--prefix", formula], err: File::NULL, &:read)
    prefix = out&.strip
    (prefix && !prefix.empty? && File.directory?(prefix)) ? prefix : nil
  end
end
