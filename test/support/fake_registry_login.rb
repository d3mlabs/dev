# typed: false
# frozen_string_literal: true

require "dev/registry_login"

# A recording RegistryLogin for tests: the registry login is a true boundary
# (gh's token, the daemon's credential store), so tests fake it and check
# which registry was entered, with which scope, around which engine calls.
#
#   login = FakeRegistryLogin.new
#   login.sessions  # => [["ghcr.io", publish: false], ...]
class FakeRegistryLogin < Dev::RegistryLogin
  attr_reader :sessions

  def initialize
    @sessions = []
  end

  def with(registry, publish: false)
    @sessions << [registry, publish]
    yield
  end
end
