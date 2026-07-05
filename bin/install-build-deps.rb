#!/usr/bin/env ruby
# frozen_string_literal: true

# Installs :build group Homebrew dependencies from a dependencies.rb file.
# Called by docker-install-build-deps.sh inside Docker builds.
#
# Usage: ruby install-build-deps.rb [deps_dir]
#   deps_dir: directory containing dependencies.rb (default: /app)
#
# env is declared, not detected: this script only ever runs inside a docker
# build (see header), where no CI variable exists — it IS the ci install
# path by construction. This declaration is what let detect_env drop its
# Linux-implies-CI clause (a Linux workstation is dev, not ci).

require "dev/deps"

deps_dir = ARGV[0] || "/app"
deps_file = File.join(deps_dir, "dependencies.rb")
abort "dependencies.rb not found at #{deps_file}" unless File.exist?(deps_file)

load(deps_file)
config = Dev::Deps.last_config
abort "No config found — dependencies.rb must call Dev::Deps.define" unless config

env = "ci"
build_group = config.group("build")

config.taps.each do |tap|
  puts ">>> Registering tap: #{tap.name}"
  system("brew", "tap", tap.name) || abort("brew tap #{tap.name} failed")
end

# Collect brew entries: global + matching env scope.
brew_entries = Array(build_group["brew"])
env_section = build_group.dig("env", env)
brew_entries += Array(env_section["brew"]) if env_section

# Host OS of the container being built, for host-gated brew entries. Docker
# builds are Linux; the constant spares a RUBY_PLATFORM sniff that could never
# say anything else here.
HOST = "linux"

def install_brew_entry(entry)
  case entry
  when String
    puts ">>> Installing: #{entry}"
    system("brew", "install", entry) || abort("brew install #{entry} failed")
  when Hash
    entry.each do |name, opts|
      # Host-gated entries (e.g. brew "xcodes", host: :darwin) skip
      # non-matching hosts — mirrors DependencyInstaller#filter_by_host.
      host = opts["host"]
      if host && host.to_s != HOST
        puts ">>> Skipping #{name} (host: #{host})"
        next
      end

      post_install = opts.delete("post_install")
      tap = opts["tap"]
      version = opts["version"]
      cask = opts["cask"]

      if cask
        puts ">>> Installing cask: #{name}"
        system("brew", "install", "--cask", name) || abort("brew install --cask #{name} failed")
      else
        spec = if tap
          version_suffix = version ? "@#{version}" : ""
          "#{tap}/#{name}#{version_suffix}"
        elsif version
          "#{name}@#{version}"
        else
          name
        end
        puts ">>> Installing: #{spec}"
        system("brew", "install", spec) || abort("brew install #{spec} failed")
      end

      if post_install
        puts ">>> Running post_install for #{name}"
        post_install.call(name, opts)
      end
    end
  end
end

brew_entries.each { |entry| install_brew_entry(entry) }

puts ">>> All build dependencies installed"
