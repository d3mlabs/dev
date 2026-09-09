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
      current = begin
        out = `bundle --version 2>&1`.strip
        m = out.match(/Bundler version (\d+\.\d+\.\d+)/)
        m ? Gem::Version.new(T.must(m[1])) : nil
      end
      return true if current && requirement.satisfied_by?(current)

      puts "Ensuring bundler #{BUNDLER_VERSION}..."
      _out, err, status = Open3.capture3("gem", "install", "bundler", "--no-document")
      unless status.success?
        raise BundlerInstallError, "Failed to install bundler: #{err}"
      end
      Gem.clear_paths
      true
    end
  end
end
