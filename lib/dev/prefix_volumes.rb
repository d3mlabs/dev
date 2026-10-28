# typed: strict
# frozen_string_literal: true

require "etc"
require "dev/build_container"
require "dev/container_engine"
require "dev/platform"

module Dev
  # The engine's Linuxbrew prefix volumes and whose they are. A prefix
  # volume is per host user on Linux (`dev-linuxbrew-<user>`,
  # BuildContainer.prefix_volume) and the VM's one on a Mac; one whose name
  # carries no host user — a renamed or removed user, or Linux's bare
  # `dev-linuxbrew` from before the split — is stale: nothing will mount it
  # again. `dev engine status` reports the list; `dev cache gc` removes the
  # stale ones no container still mounts.
  class PrefixVolumes
    extend T::Sig

    UserExists = T.type_alias { T.proc.params(name: String).returns(T::Boolean) }

    # One volume, decoded.
    class Volume < T::Struct
      extend T::Sig

      const :name, String
      const :user, T.nilable(String)
      const :stale, T::Boolean
      const :mounted_by, T::Array[String]

      # One line for a human: the owner for a live volume; for a stale one
      # the reason and the command that reclaims it — after the containers
      # still mounting it have been recreated, when there are any.
      #
      # @return [String]
      sig { returns(String) }
      def describe
        return "#{name} (#{user || "the VM's"})" unless stale

        reason = user ? "no host user #{user}" : "no host user"
        return "#{name} — stale: #{reason} (dev cache gc removes it)" if mounted_by.empty?

        "#{name} — stale: #{reason}; mounted by #{mounted_by.join(", ")} (dev container up there recreates it, then dev cache gc)"
      end
    end

    class << self
      extend T::Sig

      # Whether the host has a user by that name.
      #
      # @param name [String]
      # @return [Boolean]
      sig { params(name: String).returns(T::Boolean) }
      def user_exists?(name)
        !Etc.getpwnam(name).nil?
      rescue ArgumentError
        false
      end
    end

    # @param engine [Dev::ContainerEngine] the engine whose volumes these are
    # @param host_os [String] "darwin" / "linux" — which naming rule applies
    # @param user_exists [Proc] passwd lookup (injectable for tests)
    sig { params(engine: ContainerEngine, host_os: String, user_exists: UserExists).void }
    def initialize(engine:, host_os: Platform.os, user_exists: ->(name) { PrefixVolumes.user_exists?(name) })
      @engine = engine
      @host_os = host_os
      @user_exists = user_exists
    end

    # Every `dev-linuxbrew*` volume on the engine, by name.
    #
    # @return [Array<Volume>]
    sig { returns(T::Array[Volume]) }
    def list
      names = @engine.capture(["volume", "ls", "--format", "{{.Name}}", "--filter", "name=#{BuildContainer::LINUXBREW_VOLUME}"])
        .each_line.map(&:strip).select { |name| name.start_with?(BuildContainer::LINUXBREW_VOLUME) }.sort
      names.map { |name| decode(name) }
    end

    # The volumes nothing will mount again.
    #
    # @return [Array<Volume>]
    sig { returns(T::Array[Volume]) }
    def stale = list.select(&:stale)

    # Drop one volume.
    #
    # @param volume [Volume]
    # @return [Boolean] whether the engine removed it
    sig { params(volume: Volume).returns(T::Boolean) }
    def remove!(volume)
      @engine.run(["volume", "rm", volume.name], out: File::NULL)
    end

    private

    # @param name [String]
    # @return [Volume]
    sig { params(name: String).returns(Volume) }
    def decode(name)
      user = name == BuildContainer::LINUXBREW_VOLUME ? nil : name.delete_prefix("#{BuildContainer::LINUXBREW_VOLUME}-")
      stale =
        if @host_os == "linux"
          user.nil? || !@user_exists.call(user)
        else
          !user.nil?
        end
      mounted_by = @engine.capture(["ps", "-a", "--filter", "volume=#{name}", "--format", "{{.Names}}"]).each_line.map(&:strip).reject(&:empty?)
      Volume.new(name: name, user: user, stale: stale, mounted_by: mounted_by)
    end
  end
end
