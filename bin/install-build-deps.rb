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

ENV_NAME = "ci"

# Host OS of the container being built, for host-gated brew entries. Docker
# builds are Linux; the constant spares a RUBY_PLATFORM sniff that could never
# say anything else here.
HOST = :linux

config.taps.each do |tap|
  puts ">>> Registering tap: #{tap.name}"
  system("brew", "tap", tap.name) || abort("brew tap #{tap.name} failed")
end

def install_brew_declaration(decl)
  tap = decl.constraint["tap"]
  version = decl.constraint["version"]

  if decl.constraint["cask"]
    puts ">>> Installing cask: #{decl.name}"
    system("brew", "install", "--cask", decl.name) || abort("brew install --cask #{decl.name} failed")
  else
    spec = if tap
      version_suffix = version ? "@#{version}" : ""
      "#{tap}/#{decl.name}#{version_suffix}"
    elsif version
      "#{decl.name}@#{version}"
    else
      decl.name
    end
    puts ">>> Installing: #{spec}"
    system("brew", "install", spec) || abort("brew install #{spec} failed")
  end

  if decl.post_install
    puts ">>> Running post_install for #{decl.name}"
    decl.post_install.call(decl.name, decl.constraint)
  end
end

# The build image materializes the :build group's brew declarations for this
# env — the same declarations the resolver/lockfile pipeline reads; env/host
# filtering mirrors DependencyInstaller (nil means "everywhere").
build_brews = config.declarations.select do |decl|
  decl.integration == :brew &&
    decl.group == :build &&
    (decl.env.nil? || decl.env == ENV_NAME)
end

hosted, skipped = build_brews.partition { |decl| decl.host.nil? || decl.host == HOST }
skipped.each { |decl| puts ">>> Skipping #{decl.name} (host: #{decl.host})" }
hosted.each { |decl| install_brew_declaration(decl) }

puts ">>> All build dependencies installed"
