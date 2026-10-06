# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/build_container"
require "dev/container_engine"

module Dev
  # Makes a build container's user the host's user: the uid and gid that own
  # the mounted data root. Dependencies install where they are consumed
  # (ADR-0002), so the container writes the host's data root — its Ruby, its
  # gems, the shared download caches — as whatever user the image runs as.
  # Where that user cannot write the mount (a hosted runner at uid 1001
  # against an image user at 1000), nothing inside can install.
  #
  # Behavioural gate, not a platform guess: the container is asked whether
  # its user can write the data root. It can (gamebox, where the uids match;
  # Macs, where the virtiofs mount is writable regardless) — nothing
  # happens. It cannot — bin/container-align-user.sh, as root, gives the
  # image user the mount owner's ids and re-owns every file the old ids held
  # on the container's root filesystem, so the next `docker exec` runs as the
  # host's user and every bind mount is writable from both sides. A
  # root-owned mount (the engine created the host directory) is handed to
  # the container's user instead: nothing runs as root for lack of a better
  # idea. Persistent containers keep the change in their writable layer, so
  # the steady state is one probe.
  class ContainerUserAligner
    extend T::Sig

    # The realign script, shipped beside dev's bin so a formula install
    # carries it; its text travels to the container as the `sh -c` argument.
    SCRIPT = T.let(Pathname.new(File.expand_path("../../bin/container-align-user.sh", __dir__)), Pathname)

    # What the container's user reports about itself and the mount, in one
    # exec: uid, gid, user name, group name, the mount's owner uid and gid,
    # and whether the user can write the mount.
    PROBE = T.let(
      "printf '%s %s %s %s %s %s\\n' \"$(id -u)\" \"$(id -g)\" \"$(id -un)\" \"$(id -gn)\" " \
      "\"$(stat -c '%u %g' #{BuildContainer::DATA_ROOT_MOUNT})\" " \
      "\"$([ -w #{BuildContainer::DATA_ROOT_MOUNT} ] && echo yes || echo no)\"".freeze,
      String,
    )

    # The container did not answer the probe.
    class ProbeFailedError < StandardError
      extend T::Sig

      # @param container [String] the container name
      sig { params(container: String).void }
      def initialize(container:)
        super("dev: could not read #{container}'s user and data root ownership — is the container running?")
      end
    end

    # The realign script exited nonzero.
    class RealignFailedError < StandardError
      extend T::Sig

      # @param container [String] the container name
      # @param uid [Integer] the uid the container's user was being given
      sig { params(container: String, uid: Integer).void }
      def initialize(container:, uid:)
        super("dev: giving #{container}'s user uid #{uid} failed — see the output above")
      end
    end

    # What the probe reports.
    class Probe < T::Struct
      const :uid, Integer
      const :gid, Integer
      const :user, String
      const :group, String
      const :owner_uid, Integer
      const :owner_gid, Integer
      const :writable, T::Boolean
    end

    # @param engine [Dev::ContainerEngine] the engine the container runs on
    sig { params(engine: ContainerEngine).void }
    def initialize(engine:)
      @engine = engine
    end

    # Align the container's user with the mounted data root's owner.
    #
    # @param container [String] a running container's name
    # @return [Symbol] :aligned when the user could already write the mount,
    #   :realigned after the user took the owner's ids, :adopted after a
    #   root-owned mount was handed to the user
    # @raise [ProbeFailedError] when the container cannot be probed
    # @raise [RealignFailedError] when the realign script fails
    sig { params(container: String).returns(Symbol) }
    def align!(container)
      probe = probe(container)
      return :aligned if probe.writable

      if probe.owner_uid.zero?
        adopt!(container, probe)
        :adopted
      else
        realign!(container, probe)
        :realigned
      end
    end

    private

    # @param container [String]
    # @return [Probe]
    # @raise [ProbeFailedError] on no or unparseable output
    sig { params(container: String).returns(Probe) }
    def probe(container)
      fields = @engine.capture(["exec", container, "sh", "-c", PROBE]).split
      raise ProbeFailedError.new(container:) unless fields.length == 7 && fields.values_at(0, 1, 4, 5).all? { |f| f.match?(/\A\d+\z/) }

      Probe.new(
        uid: Integer(T.must(fields[0])), gid: Integer(T.must(fields[1])),
        user: T.must(fields[2]), group: T.must(fields[3]),
        owner_uid: Integer(T.must(fields[4])), owner_gid: Integer(T.must(fields[5])),
        writable: fields[6] == "yes",
      )
    end

    # Give the image user the mount owner's ids, as root.
    #
    # @param container [String]
    # @param probe [Probe]
    # @return [void]
    # @raise [RealignFailedError]
    sig { params(container: String, probe: Probe).void }
    def realign!(container, probe)
      args = [probe.user, probe.group, probe.uid, probe.gid, probe.owner_uid, probe.owner_gid].map(&:to_s)
      done = @engine.run(["exec", "--user", "root", container, "sh", "-c", SCRIPT.read, "sh", *args])
      raise RealignFailedError.new(container:, uid: probe.owner_uid) unless done
    end

    # Hand a root-owned mount to the container's user, as root.
    #
    # @param container [String]
    # @param probe [Probe]
    # @return [void]
    # @raise [RealignFailedError]
    sig { params(container: String, probe: Probe).void }
    def adopt!(container, probe)
      done = @engine.run(["exec", "--user", "root", container, "chown", "#{probe.uid}:#{probe.gid}", BuildContainer::DATA_ROOT_MOUNT])
      raise RealignFailedError.new(container:, uid: probe.uid) unless done
    end
  end
end
