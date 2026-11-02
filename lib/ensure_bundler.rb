# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require "open3"

# Ensures the bundler version declared in dependencies.rb is installed.
# Used by the bin/ scripts (setup, test, tc, rbi), which all activate gems
# before requiring this file — via `require "bundler/setup"` or, for rbi.rb,
# plain RubyGems against the default gem home the bundle installs into.
#
# Uses Open3.capture3 for gem install so output doesn't leak through
# the terminal when running inside a CLI::UI spinner.
module EnsureBundler
  class BundlerInstallError < StandardError; end

  # `bundle --version` prints "Bundler version X.Y.Z" through Bundler 3 and a
  # bare "X.Y.Z" from Bundler 4 on. Anchored to a whole line so version-like
  # fragments elsewhere in the output (gem paths in a warning or backtrace)
  # are never mistaken for the bundler version.
  VERSION_LINE = /^(?:Bundler version )?(\d+\.\d+\.\d+)$/

  class << self
    extend T::Sig

    # Ensure the installed bundler satisfies dependencies.rb's BUNDLER_VERSION,
    # installing it when absent or too old.
    #
    # @param dev_root [String] dev repo root (where dependencies.rb lives)
    # @return [Boolean] true (raises on failure)
    # @raise [BundlerInstallError] when gem install fails
    sig { params(dev_root: String).returns(T::Boolean) }
    def ensure!(dev_root)
      load File.join(dev_root, "dependencies.rb") unless defined?(BUNDLER_VERSION)

      requirement = Gem::Requirement.new(BUNDLER_VERSION)
      current = installed_version
      return true if current && requirement.satisfied_by?(current)

      puts "Ensuring bundler #{BUNDLER_VERSION}..."
      _out, err, status = Open3.capture3("gem", "install", "bundler", "--no-document")
      unless status.success?
        raise BundlerInstallError, "Failed to install bundler: #{err}"
      end
      Gem.clear_paths
      true
    end

    private

    # The version of the bundler that `bundle` on PATH runs.
    #
    # Not an error path: no bundler is a legitimate state the caller resolves
    # by installing one, so it reads as nil rather than raising.
    #
    # @return [Gem::Version, nil] nil when `bundle` is absent, fails, or
    #   prints nothing recognizable as a version
    sig { returns(T.nilable(Gem::Version)) }
    def installed_version
      out, status = Open3.capture2e("bundle", "--version")
      return nil unless status.success?

      match = out.match(VERSION_LINE)
      match && Gem::Version.new(T.must(match[1]))
    rescue Errno::ENOENT
      nil
    end
  end
end
