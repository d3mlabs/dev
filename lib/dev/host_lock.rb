# typed: strict
# frozen_string_literal: true

require "fileutils"

require "dev/data_root"

module Dev
  # A host-wide mutex on a resource every identity on the box shares — the
  # brew prefix first: two runner slots, or a human
  # and the agent user, discovering the same missing keg at once must take
  # turns, because brew's own per-formula lock makes the loser *fail*, not
  # wait. Blocking: the second holder waits for the first, then re-asks its
  # question (the keg is usually there by then).
  #
  # flock(2) is the mechanism — the kernel releases it when the holder dies,
  # so there is no stale-lock ritual, and FD_CLOEXEC keeps spawned children
  # (brew itself) from inheriting it. The lockfile lives under the data
  # root, the one place the agent bootstrap already shares between the
  # identities (DataRoot::SHARED_ROOT, group-owned); it is opened read-only,
  # which flock accepts, so an identity that can read it can lock it even
  # when another created it. Re-entrant per instance: a write taken under a
  # converge taken under the same lock is one hold.
  class HostLock
    extend T::Sig

    # Where the data root keeps its locks.
    LOCKS_DIR = "locks"

    # @param name [String] the resource ("brew") — one lockfile per name
    # @param root [String] the data root the lockfile lives under
    sig { params(name: String, root: String).void }
    def initialize(name:, root: DataRoot.path)
      @name = name
      @root = root
      @depth = T.let(0, Integer)
    end

    # @return [String] the lockfile
    sig { returns(String) }
    def path
      File.join(@root, LOCKS_DIR, "#{@name}.lock")
    end

    # Run the block holding the lock, waiting for any other holder first.
    #
    # @yieldreturn the block's value
    # @return [Object] the block's value
    sig do
      type_parameters(:Result)
        .params(blk: T.proc.returns(T.type_parameter(:Result)))
        .returns(T.type_parameter(:Result))
    end
    def synchronize(&blk)
      return yield if @depth.positive?

      ensure_dir!
      File.open(path, File::RDONLY | File::CREAT, 0o664) do |file|
        file.flock(File::LOCK_EX)
        @depth += 1
        begin
          yield
        ensure
          @depth -= 1
        end
      end
    end

    private

    # The locks directory, open to the shared group so whichever identity
    # comes first does not fence the other out; a directory another user
    # already made (EPERM on chmod) is theirs to have opened.
    #
    # @return [void]
    sig { void }
    def ensure_dir!
      dir = File.dirname(path)
      FileUtils.mkdir_p(dir)
      FileUtils.chmod(0o2775, dir)
    rescue Errno::EPERM
      nil
    end
  end
end
