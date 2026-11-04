# typed: false
# frozen_string_literal: true

require "dev/lifecycle"

# The targets the lifecycle tests speak in: cellbound-3d's shape (a client
# over two platforms and two configs, a longer-named sibling, a
# single-platform server) and a gem (no axes at all). Pure builders — every
# call returns fresh values, so tests share no state.
module LifecycleFixtures
  PLATFORM = Dev::Lifecycle::Platform
  CONFIG = Dev::Lifecycle::Config

  # @return [Dev::Lifecycle::Target] `cellbound-3d`: win64 + linux64, dev + release
  def client_target
    Dev::Lifecycle::Target.new(
      name: "cellbound-3d",
      desc: "Client",
      platforms: [PLATFORM::Win64, PLATFORM::Linux64],
      configs: [CONFIG::Development, CONFIG::Release],
    )
  end

  # @return [Dev::Lifecycle::Target] `cellbound-3d-steamworks`: win64 only, release only
  def steamworks_target
    Dev::Lifecycle::Target.new(
      name: "cellbound-3d-steamworks",
      desc: "Client with Steamworks compiled in",
      platforms: [PLATFORM::Win64],
      configs: [CONFIG::Release],
    )
  end

  # @return [Dev::Lifecycle::Target] `cellbound-3d-server`: linux64, dev + release
  def server_target
    Dev::Lifecycle::Target.new(
      name: "cellbound-3d-server",
      desc: "Dedicated server",
      platforms: [PLATFORM::Linux64],
      configs: [CONFIG::Development, CONFIG::Release],
    )
  end

  # @return [Dev::Lifecycle::Target] `rspock`: no axes, its own single build
  def gem_target
    Dev::Lifecycle::Target.new(name: "rspock", desc: "The gem")
  end

  # @return [Array<Dev::Lifecycle::Target>] the four, in that order
  def all_targets
    [client_target, steamworks_target, server_target, gem_target]
  end

  # @param name [String] a fully-qualified build name
  # @return [Dev::Lifecycle::Build]
  def build(name)
    Dev::Lifecycle::Build.parse(name, all_targets)
  end
end
