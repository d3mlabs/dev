# typed: strict
# frozen_string_literal: true

require "pathname"
require "sorbet-runtime"
require "dev/provisioning_guard"
require "dev/shadowenv_ruby"

module Dev
  # The ruby-build seam: compiles one Ruby into a given prefix, linking the
  # brew-provided libraries so the required extensions are built rather than
  # silently skipped. The rpath order ShadowenvRuby bakes (the prefix's own
  # lib ahead of brew's) is what keeps the result running as its own version.
  class RubyBuild
    extend T::Sig

    STUB_HINT = "Dev::ContainerRuby.new(builder: <fake>)"

    # Build +version+ into +prefix+.
    #
    # @param version [String] the Ruby version
    # @param prefix [Pathname] the install prefix (created by ruby-build)
    # @return [Boolean] whether ruby-build succeeded
    # @raise [ProvisioningGuard::ForbiddenError] under the harness kill-switch
    sig { params(version: String, prefix: Pathname).returns(T::Boolean) }
    def call(version, prefix)
      ProvisioningGuard.check!("ruby-build #{version}", stub_hint: STUB_HINT)
      env = { "PATH" => ShadowenvRuby.path_with_brew_bin }
      ShadowenvRuby.ensure_ruby_build_deps!(env)
      $stderr.puts "dev: building Ruby #{version} into #{prefix} (one-time)..."
      system(ShadowenvRuby.ruby_build_env(env, version, prefix: prefix.to_s), "ruby-build", version, prefix.to_s) == true
    end
  end
end
