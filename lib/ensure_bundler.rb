# frozen_string_literal: true

require "open3"

# Shared logic to ensure bundler version from dependencies.rb is installed.
# Used by bin/setup.rb (dev up) and bin/test.rb.
#
# Uses Open3.capture3 for gem install so output doesn't leak through
# the terminal when running inside a CLI::UI spinner.

class BundlerInstallError < StandardError; end

def ensure_bundler!(dev_root)
  load File.join(dev_root, "dependencies.rb") unless defined?(BUNDLER_VERSION)

  requirement = Gem::Requirement.new(BUNDLER_VERSION)
  current = begin
    out = `bundle --version 2>&1`.strip
    m = out.match(/Bundler version (\d+\.\d+\.\d+)/)
    m ? Gem::Version.new(m[1]) : nil
  end
  return true if current && requirement.satisfied_by?(current)

  puts "Ensuring bundler #{BUNDLER_VERSION}..."
  out, err, status = Open3.capture3("gem", "install", "bundler", "--no-document")
  unless status.success?
    raise BundlerInstallError, "Failed to install bundler: #{err}"
  end
  Gem.clear_paths
  true
end
