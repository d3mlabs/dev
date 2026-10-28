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
  # The Linuxbrew prefix mount comes with the ids. It is a volume docker
  # initialised from the image — owned by the image's user — and on Linux
  # the host user's own (BuildContainer.prefix_volume, dev#337: a brew
  # prefix has one owner, its only writer). Once the container's user has
  # its final ids, a prefix owned by any other uid is handed to it: a
  # recursive chown as root, cheap on a volume's real filesystem (no
  # overlay copy-up), idempotent after.
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

    # What the container's user reports about itself and the mounts, in one
    # exec: uid, gid, user name, group name, the data root mount's owner uid
    # and gid, whether the user can write it, and the Linuxbrew prefix
    # mount's owner uid (`-` when there is no prefix).
    PROBE = T.let(
      "printf '%s %s %s %s %s %s %s\\n' \"$(id -u)\" \"$(id -g)\" \"$(id -un)\" \"$(id -gn)\" " \
      "\"$(stat -c '%u %g' #{BuildContainer::DATA_ROOT_MOUNT})\" " \
      "\"$([ -w #{BuildContainer::DATA_ROOT_MOUNT} ] && echo yes || echo no)\" " \
      "\"$(stat -c '%u' #{BuildContainer::LINUXBREW_MOUNT} 2>/dev/null || echo -)\"".freeze,
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
      const :prefix_owner_uid, T.nilable(Integer)
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
    #   handed to the user, :prefix_adopted when only the Linuxbrew prefix
    #   volume changed hands
    # @raise [ProbeFailedError] when the container cannot be probed
    # @raise [RealignFailedError] when the realign script or a chown fails
    sig { params(container: String).returns(Symbol) }
    def align!(container)
      probe = probe(container)
      if probe.owner_uid.zero?
        adopt!(container, probe)
        own_prefix!(container, probe, probe.uid, probe.gid)
        return :adopted
      end

      uid, gid = target(probe)
      if uid.nil? || gid.nil?
        return own_prefix!(container, probe, probe.uid, probe.gid) ? :prefix_adopted : :aligned
      end

      realign!(container, probe, uid, gid)
      own_prefix!(container, probe, uid, gid)
      :realigned
    end

    private

    # @param container [String]
    # @return [Probe]
    # @raise [ProbeFailedError] on no or unparseable output
    sig { params(container: String).returns(Probe) }
    def probe(container)
      fields = @engine.capture(["exec", container, "sh", "-c", PROBE]).split
      raise ProbeFailedError.new(container:) unless fields.length == 8 && fields.values_at(0, 1, 4, 5).all? { |f| f.match?(/\A\d+\z/) }

      prefix_owner = T.must(fields[7])
      Probe.new(
        uid: Integer(T.must(fields[0])), gid: Integer(T.must(fields[1])),
        user: T.must(fields[2]), group: T.must(fields[3]),
        owner_uid: Integer(T.must(fields[4])), owner_gid: Integer(T.must(fields[5])),
        writable: fields[6] == "yes",
        prefix_owner_uid: prefix_owner.match?(/\A\d+\z/) ? Integer(prefix_owner) : nil,
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

    # Hand the Linuxbrew prefix mount to the container's user when another
    # uid owns it, as root.
    #
    # @param container [String]
    # @param probe [Probe]
    # @param uid [Integer] the user's final uid
    # @param gid [Integer] the user's final gid
    # @return [Boolean] whether the prefix changed hands
    # @raise [RealignFailedError]
    sig { params(container: String, probe: Probe, uid: Integer, gid: Integer).returns(T::Boolean) }
    def own_prefix!(container, probe, uid, gid)
      owner = probe.prefix_owner_uid
      return false if owner.nil? || owner == uid

      done = @engine.run(["exec", "--user", "root", container, "chown", "-R", "#{uid}:#{gid}", BuildContainer::LINUXBREW_MOUNT])
      raise RealignFailedError.new(container:, uid: uid) unless done

      true
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
