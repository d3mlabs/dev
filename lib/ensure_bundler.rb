# frozen_string_literal: true

# Shared logic to ensure bundler version from dependencies.rb is installed.
# Used by bin/setup.rb (dev up) and bin/test.rb.

def ensure_bundler!(dev_root)
  load File.join(dev_root, "dependencies.rb") unless defined?(BUNDLER_VERSION)

  requirement = Gem::Requirement.new(BUNDLER_VERSION)
  current = begin
    out = `bundle --version 2>&1`.strip
    m = out.match(/Bundler version (\d+\.\d+\.\d+)/)
    m ? Gem::Version.new(m[1]) : nil
  end
  return true if current && requirement.satisfied_by?(current)

  puts "  Ensuring bundler #{BUNDLER_VERSION}..."
  unless system("gem", "install", "bundler", "--no-document")
    puts "  ⚠️  Failed to install bundler. Run: gem install bundler (or add --user-install if no write to system gems)"
    return false
  end
  Gem.clear_paths
  true
end
