# typed: strict
# frozen_string_literal: true

require "fileutils"
require "pathname"

module Dev
  # Shadowenv LLVM provisioning: resolves the Homebrew LLVM prefix, generates
  # .shadowenv.d/520_llvm.lisp so clang, clang-format, clang-tidy, and lld are
  # available in PATH, and CC/CXX point to the Homebrew compiler.
  #
  # Skipped on Linux / CI where Linuxbrew tools are already in PATH.
  module ShadowenvLlvm
    extend T::Sig
    include Kernel

    LISP_FILENAME = "520_llvm.lisp"
    FORMULA_NAMES = ["llvm@22", "llvm"].freeze

    module_function

    # Returns the Homebrew prefix for the LLVM formula, or nil if not installed.
    sig { returns(T.nilable(String)) }
    def detect_llvm_prefix
      FORMULA_NAMES.each do |name|
        prefix = brew_prefix_for(name)
        return prefix if prefix
      end
      nil
    end

    # Returns true when .shadowenv.d/520_llvm.lisp exists and provisions from
    # the given prefix. This is the fast-path check run before every dev command.
    sig { params(llvm_prefix: String, project_root: T.any(String, Pathname)).returns(T::Boolean) }
    def provisioned?(llvm_prefix, project_root:)
      lisp_path = File.join(project_root.to_s, ".shadowenv.d", LISP_FILENAME)
      return false unless File.exist?(lisp_path)
      content = File.read(lisp_path)
      content.include?(%(provide "llvm")) && content.include?(llvm_prefix)
    end

    # Full provisioning: write .shadowenv.d/520_llvm.lisp, trust shadowenv.
    # Idempotent. Returns true on success, false if LLVM prefix is nil.
    sig { params(project_root: T.any(String, Pathname), llvm_prefix: T.nilable(String)).returns(T::Boolean) }
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
    sig { returns(T::Boolean) }
    def ci_or_linux?
      !!(ENV["CI"].to_s =~ /\A(true|1)\z/i) || RUBY_PLATFORM.to_s.include?("linux")
    end

    # Generate the shadowenv lisp that puts LLVM in PATH and sets CC/CXX.
    sig { params(llvm_prefix: String).returns(String) }
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

    # Returns true if the project's build-deps.lock references LLVM.
    # Supports both YAML format (top-level "llvm:" key) and the legacy
    # plain-text format ("brew llvm").
    sig { params(project_root: T.any(String, Pathname)).returns(T::Boolean) }
    def project_needs_llvm?(project_root)
      lockfile = Pathname(project_root) / "build-deps.lock"
      return false unless lockfile.exist?

      content = lockfile.read
      content.match?(/^llvm:\s*$/) || content.match?(/^brew llvm\b/)
    end

    # --- internal helpers ------------------------------------------------

    sig { params(formula: String).returns(T.nilable(String)) }
    def brew_prefix_for(formula)
      return nil unless system("command -v brew >/dev/null 2>&1")
      out = IO.popen(["brew", "--prefix", formula], err: File::NULL, &:read)
      prefix = out&.strip
      (prefix && !prefix.empty? && File.directory?(prefix)) ? prefix : nil
    end
  end
end
