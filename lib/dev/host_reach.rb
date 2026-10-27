# typed: strict
# frozen_string_literal: true

require "dev/deps/dependency"
require "dev/runner_setup"
require "dev/runner_user"

module Dev
  # Whether the host identity can read what a repo's jobs fetch — checked,
  # not remembered (dev#310). A job on a Linux host fetches its private
  # dependencies with the runner user's gh login (the machine user): the
  # lock's `gh` pins (`gh api repos/<repo>/tarball`, `gh release download`)
  # and the image floor it pulls (`ghcr.io/<owner>/<name>`, through
  # RegistryLogin with that same token). A grant the machine user lacks is
  # a red run an hour in; here it is a message from `dev runner register`
  # (which refuses to enroll) and a line in `dev runner status`.
  #
  # Each target is probed as the runner user: `gh api repos/<repo>` for a
  # repo; for a package, the org path then the user path (the owner's kind
  # is not in the lock). A 404 is "cannot read" and comes back with the
  # grant: the collaborator PUT for a repo, the access-settings page for a
  # package (there is no API for package grants; a package also inherits
  # its source repo's access, which is the usual way).
  class HostReach
    extend T::Sig

    # The host identity cannot read one or more targets; the message lists
    # each with its grant.
    class UnreachableError < RuntimeError; end

    # One thing the jobs fetch: a repo (`owner/repo`) or a package
    # (`ghcr.io/owner/name`).
    class Target < T::Struct
      extend T::Sig

      const :kind, Symbol # :repo or :package
      const :owner, String
      const :name, String
      const :registry, T.nilable(String) # the package's registry host

      sig { returns(String) }
      def to_s
        kind == :repo ? "#{owner}/#{name}" : "package #{registry}/#{owner}/#{name}"
      end

      # The API paths that answer whether the identity can read this.
      #
      # @return [Array<String>] tried in order; any 200 is reachable
      sig { returns(T::Array[String]) }
      def probe_paths
        if kind == :repo
          ["repos/#{owner}/#{name}"]
        else
          ["orgs/#{owner}/packages/container/#{name}", "users/#{owner}/packages/container/#{name}"]
        end
      end

      # The grant that would make this readable by `login`.
      #
      # @param login [String] the host identity's GitHub login
      # @param owner_kind [Symbol] :org or :user — which settings page a package has
      # @return [String]
      sig { params(login: String, owner_kind: Symbol).returns(String) }
      def grant(login, owner_kind: :org)
        if kind == :repo
          "gh api -X PUT repos/#{owner}/#{name}/collaborators/#{login} -f permission=pull"
        else
          segment = owner_kind == :user ? "users" : "orgs"
          "grant #{login} read on https://github.com/#{segment}/#{owner}/packages/container/#{name}/settings " \
            "(or on the repo that publishes it: a package inherits its source repo's access)"
        end
      end
    end

    # What a check found about one unreachable target.
    class Verdict < T::Struct
      const :target, Target
      const :grant, String
    end

    class << self
      extend T::Sig

      # The targets a lock's pins imply, in pin order.
      #
      # @param pins [Array<Dev::Deps::Dependency>]
      # @return [Array<Target>]
      sig { params(pins: T::Array[Deps::Dependency]).returns(T::Array[Target]) }
      def targets(pins)
        pins.filter_map do |pin|
          case pin.integration
          when :gh
            owner, name = pin.metadata.fetch("repo").to_s.split("/", 2)
            Target.new(kind: :repo, owner: owner.to_s, name: name.to_s)
          when :image
            registry, owner, name = pin.metadata.fetch("from").to_s.split("/", 3)
            Target.new(kind: :package, owner: owner.to_s, name: name.to_s, registry: registry.to_s)
          end
        end
      end
    end

    # @param identity [Dev::RunnerUser] the host identity to probe as
    # @param executor [#capture] CLI boundary (RunnerSetup::Executor's shape)
    sig { params(identity: RunnerUser, executor: T.untyped).void }
    def initialize(identity:, executor: RunnerSetup::Executor.new)
      @identity = identity
      @exec = executor
    end

    # The targets the identity cannot read, each with its grant.
    #
    # @param pins [Array<Dev::Deps::Dependency>]
    # @return [Array<Verdict>]
    sig { params(pins: T::Array[Deps::Dependency]).returns(T::Array[Verdict]) }
    def check(pins)
      targets = self.class.targets(pins)
      return [] if targets.empty?

      unreachable = targets.reject { |target| target.probe_paths.any? { |path| reachable?(path) } }
      return [] if unreachable.empty?

      login = login_name
      unreachable.map do |target|
        Verdict.new(target: target, grant: target.grant(login, owner_kind: owner_kind(target.owner)))
      end
    end

    # Refuse when anything is unreachable.
    #
    # @param pins [Array<Dev::Deps::Dependency>]
    # @return [void]
    # @raise [UnreachableError]
    sig { params(pins: T::Array[Deps::Dependency]).void }
    def check!(pins)
      verdicts = check(pins)
      return if verdicts.empty?

      lines = verdicts.map { |verdict| "  #{verdict.target} — #{verdict.grant}" }
      raise UnreachableError,
        "#{@identity.name} (#{login_name}) cannot read what this repo's jobs fetch:\n#{lines.join("\n")}\n" \
        "then re-run dev runner register."
    end

    private

    # @param path [String] a gh api path
    # @return [Boolean]
    sig { params(path: String).returns(T::Boolean) }
    def reachable?(path)
      _out, _err, ok = @exec.capture(*@identity.sudo_argv("gh", "api", path))
      ok ? true : false
    end

    # @return [String] the identity's GitHub login
    sig { returns(String) }
    def login_name
      @login_name ||= T.let(nil, T.nilable(String))
      @login_name ||= begin
        out, _err, ok = @exec.capture(*@identity.sudo_argv("gh", "api", "user", "--jq", ".login"))
        ok && !out.strip.empty? ? out.strip : @identity.name
      end
    end

    # @param owner [String]
    # @return [Symbol] :org or :user
    sig { params(owner: String).returns(Symbol) }
    def owner_kind(owner)
      out, _err, ok = @exec.capture(*@identity.sudo_argv("gh", "api", "users/#{owner}", "--jq", ".type"))
      ok && out.strip == "User" ? :user : :org
    end
  end
end
