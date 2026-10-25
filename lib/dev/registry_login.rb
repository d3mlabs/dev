# typed: strict
# frozen_string_literal: true

require "dev/container_engine"
require "dev/gh_auth"

module Dev
  # The engine's login to a container registry, performed by dev around the
  # one operation that needs it (dev#277): `docker login` fed the host's gh
  # token on stdin, the block, `docker logout` — whatever the block did.
  #
  # Scoped to the operation, so the token rests nowhere: not in
  # `~/.docker/config.json`, not in the disk a hosted runner's checkpoint
  # captures. The consequence is stated plainly: dev's logout also removes a
  # login the user made by hand to that registry — which was the stopgap
  # this replaces (a `docker login` at a box's bring-up, a workflow's login
  # step). The scope a classic token needs is checked first (GhAuth), so a
  # refusal names the `gh auth refresh` to run instead of surfacing as a
  # failed pull.
  class RegistryLogin
    extend T::Sig

    # `docker login` returned nonzero.
    class LoginFailedError < StandardError; end

    # @param engine [Dev::ContainerEngine] the engine whose daemon pulls and pushes
    # @param auth [Dev::GhAuth] the credential
    sig { params(engine: Dev::ContainerEngine, auth: Dev::GhAuth).void }
    def initialize(engine:, auth: Dev::GhAuth.new)
      @engine = engine
      @auth = auth
    end

    # Run the block logged in to the registry.
    #
    # @param registry [String] the registry host (`ghcr.io`)
    # @param publish [Boolean] whether the block pushes (write scope) or only pulls
    # @return [Object] the block's value
    # @raise [GhAuth::MissingScopeError, LoginFailedError]
    sig do
      type_parameters(:R)
        .params(registry: String, publish: T::Boolean, blk: T.proc.returns(T.type_parameter(:R)))
        .returns(T.type_parameter(:R))
    end
    def with(registry, publish: false, &blk)
      @auth.require_scope!(publish ? GhAuth::WRITE_PACKAGES : GhAuth::READ_PACKAGES)
      login!(registry)
      begin
        blk.call
      ensure
        @engine.run(["logout", registry], out: File::NULL, err: File::NULL)
      end
    end

    private

    # @param registry [String]
    # @raise [LoginFailedError]
    sig { params(registry: String).void }
    def login!(registry)
      reader, writer = IO.pipe
      writer.write(@auth.token)
      writer.close
      ok = @engine.run(["login", registry, "-u", @auth.login, "--password-stdin"], in: reader, out: File::NULL)
      reader.close
      return if ok

      raise LoginFailedError,
        "docker login #{registry} failed with gh's token — the token needs #{GhAuth::READ_PACKAGES} on the " \
          "registry's packages (gh auth refresh -s #{GhAuth::READ_PACKAGES}), and the daemon must reach #{registry}"
    end
  end
end
