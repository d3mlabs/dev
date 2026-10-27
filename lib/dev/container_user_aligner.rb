# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/build_container"
require "dev/container_engine"
require "dev/platform"

module Dev
  # Makes a build container's user the owner of its data root. The
  # container writes its data root — its Ruby, its gems, its toolchain — as
  # whatever user the image runs as; where that user cannot write the mount,
  # nothing inside can install.
  #
  # Two shapes of data root, two rules (one probe either way: the
  # container's ids, the mount's owner, and whether the user can write it).
  #
  # A **named volume** (a Mac, ADR-0008): the gate is behavioural. Docker
  # initialised the volume from the image, owned by the image's user, so
  # the user can write it and nothing happens. It cannot for a volume an
  # older image first mounted without declaring the directory (root-owned,
  # empty): that mount is handed to the container's user. A mount owned by
  # some other non-root uid gives the image user that owner's ids.
  #
  # A **Linux bind mount** (dev#308): the host's own data root, shared
  # between the operator and the runner user through the `dev` group
  # (`<user>:dev 2775`, dev#310). Here the owner's ids are the wrong
  # target — the runner user's container would write the root as the
  # operator, and could not write its own checkout at /project — and
  # writability is the wrong gate: the mount is writable by the image's uid
  # whenever that happens to be the owner's. The container's user is the
  # **host caller** (its uid) in the **root's group** (the mount's gid), so
  # what it writes under /project is the caller's and what it writes under
  # the root is the group's, like the host's own writes. A root-owned mount
  # is adopted as on a volume.
  #
  # Realigning is bin/container-align-user.sh as root: the image user's
  # passwd and group entries take the new ids, and what the old ids held on
  # the container's root filesystem is re-owned (all but the Cellar's keg
  # contents, which Homebrew never writes into), so the next `docker exec`
  # runs as the new ids. Persistent containers keep the change in their
  # writable layer, so the steady state is one probe.
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
    # @param host_os [String] "darwin" / "linux" — a bind mount on Linux, a volume elsewhere
    # @param host_uid [Integer] the host caller's uid, the Linux target
    sig { params(engine: ContainerEngine, host_os: String, host_uid: Integer).void }
    def initialize(engine:, host_os: Platform.os, host_uid: Process.uid)
      @engine = engine
      @host_os = host_os
      @host_uid = host_uid
    end

    # Align the container's user with its data root: the host caller in the
    # root's group on a Linux bind mount, the mount's owner on a volume.
    #
    # @param container [String] a running container's name
    # @return [Symbol] :aligned when the user already had the right ids,
    #   :realigned after it took them, :adopted after a root-owned mount was
    #   handed to the user
    # @raise [ProbeFailedError] when the container cannot be probed
    # @raise [RealignFailedError] when the realign script fails
    sig { params(container: String).returns(Symbol) }
    def align!(container)
      probe = probe(container)
      if probe.owner_uid.zero?
        adopt!(container, probe)
        return :adopted
      end

      uid, gid = target(probe)
      return :aligned if uid.nil? || gid.nil?

      realign!(container, probe, uid, gid)
      :realigned
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

    # The ids the container's user should have, or nil when it has them.
    #
    # @param probe [Probe]
    # @return [Array(Integer, Integer), nil] uid and gid, or nil for aligned
    sig { params(probe: Probe).returns(T.nilable([Integer, Integer])) }
    def target(probe)
      if @host_os == "linux"
        return nil if probe.uid == @host_uid && probe.gid == probe.owner_gid

        [@host_uid, probe.owner_gid]
      else
        return nil if probe.writable

        [probe.owner_uid, probe.owner_gid]
      end
    end

    # Give the image user new ids, as root.
    #
    # @param container [String]
    # @param probe [Probe]
    # @param uid [Integer]
    # @param gid [Integer]
    # @return [void]
    # @raise [RealignFailedError]
    sig { params(container: String, probe: Probe, uid: Integer, gid: Integer).void }
    def realign!(container, probe, uid, gid)
      args = [probe.user, probe.group, probe.uid, probe.gid, uid, gid].map(&:to_s)
      done = @engine.run(["exec", "--user", "root", container, "sh", "-c", SCRIPT.read, "sh", *args])
      raise RealignFailedError.new(container:, uid: uid) unless done
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
