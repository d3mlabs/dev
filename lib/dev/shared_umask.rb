# typed: strict
# frozen_string_literal: true

require "dev/platform"

module Dev
  # On Linux, dev writes group-shared: the process umask is `002` from the
  # first line of `bin/dev`, inherited by everything dev spawns.
  #
  # The Linux data root is one tree written by two OS users — the operator
  # and the runner user — through the `dev` group (`<user>:dev 2775`,
  # LinuxDataRootProvisioner, dev#310). Setgid keeps every new entry in the
  # group; whether the entry is group-*writable* is the creating process's
  # umask, and only that: a POSIX default ACL cannot help, since a new
  # entry's group permissions are the ACL intersected with the mode the
  # process requested. The writers of the data root are dev and its
  # children — the host's `dev up`, the container's `dev up` behind the
  # bind mount (ContainerUserAligner puts it in the group), the gem and
  # engine installs they spawn — so the one place the rule has to hold is
  # the dev process itself. Ubuntu's login default is already `002`; a
  # systemd service's is `022`, and the runner service is a dev process
  # one `exec` down.
  #
  # Not on a Mac: its data root has one owner (ADR-0008), the agent user's
  # shared dirs carry their own umask rule (AgentBootstrap's sudoers), and
  # the login's umask is the user's business.
  module SharedUmask
    extend T::Sig

    # Group-writable, world-readable.
    UMASK = 0o002

    class << self
      extend T::Sig

      # Set the process umask for a Linux host; leave it elsewhere.
      #
      # @param host_os [String] "darwin" / "linux" / "windows"
      # @return [Integer] the umask before the call
      sig { params(host_os: String).returns(Integer) }
      def apply!(host_os: Platform.os)
        return File.umask unless host_os == "linux"

        File.umask(UMASK)
      end
    end
  end
end
