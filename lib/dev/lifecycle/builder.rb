# typed: strict
# frozen_string_literal: true

require "etc"
require "fileutils"
require "pathname"
# Build appears in a signature only; as for Packager, requiring build.rb
# here would close a load cycle through Target. `dev/lifecycle` loads both.

module Dev
  module Lifecycle
    # The port between dev and the project's build tool: given a build, make
    # its stage — the runnable, laid-out output — in the directory dev
    # hands it. The builder never knows the archive format; that is the
    # Packager's.
    #
    # The stage is fresh before any implementation runs: `build` empties
    # the directory and recreates it, then asks the implementation to fill
    # it. One rule, in dev, so no script has to clear a previous build's
    # files itself; a toolchain's incremental state lives in its own build
    # directory, never in the stage, so nothing is lost. A previous stage
    # that cannot be emptied is an error naming what blocks, never a tree
    # the implementation fills on top of.
    #
    # The stage lives in the store, which on a host with a runner is one
    # tree two users write through the `dev` group. dev's own writes are
    # group-writable (SharedUmask); what the implementation's tool writes
    # follows the tool — `cp -a` keeps its source's modes, a toolchain its
    # umask — and only the owner can change a mode. So `build` ends by
    # opening what this user wrote to the group, as the writer, before the
    # next build by the other user has to empty it.
    #
    # ScriptBuilder is the target's `builder:` script, reading the build from
    # `DEV_*`; CheckoutBuilder is the identity element a target with no
    # `builder:` gets — the checkout's tracked files. An integration builder
    # owns the toolchain mapping and declares the target options it accepts
    # through `target_options_schema`.
    module Builder
      extend T::Sig
      extend T::Helpers
      # Every includer is an Object; this gives `build`'s own steps the
      # Kernel protocol (raise, format) under srb.
      include Kernel
      abstract!

      # The previous build's tree could not be removed — in a shared store,
      # another user wrote it without the group's write bit.
      class StageNotEmptiedError < RuntimeError; end

      # What a directory in the shared store carries beyond its owner's
      # bits: group read, write and search, and setgid so new entries
      # stay in the group.
      SHARED_DIRECTORY_BITS = 0o2070

      # What a file in the shared store carries beyond its owner's bits:
      # group read and write.
      SHARED_FILE_BITS = 0o060

      # Make the build's stage: emptied, filled, then opened to the group.
      #
      # @param build [Build] what to build
      # @param stage [Pathname] the directory the stage goes into; emptied
      #   and recreated here, then what the Packager reads next
      # @return [void]
      # @raise [StageNotEmptiedError] the previous stage is still there
      sig(:final) { params(build: Build, stage: Pathname).void }
      def build(build, stage)
        empty(stage)
        stage.mkpath
        fill(build, stage)
        share(stage)
      end

      # Fill the fresh stage with the build's output.
      #
      # @param build [Build] what to build
      # @param stage [Pathname] exists and is empty
      # @return [void]
      sig { abstract.params(build: Build, stage: Pathname).void }
      def fill(build, stage); end

      # The keys a target may carry for this builder, namespaced under its
      # name in dev.yml; validated by the builder, never defined by dev.
      # Empty for a script, which takes its parameters from the env.
      #
      # @return [Array<String>]
      sig { abstract.returns(T::Array[String]) }
      def target_options_schema; end

      # What `build-id.json` records as `builder`: `script` for the script
      # form, `checkout` for the identity builder, an integration's name
      # for its own.
      #
      # @return [String]
      sig { abstract.returns(String) }
      def name; end

      # What `build-id.json` records as `builder_version`: an engine tag for
      # an integration that has one, nil for a script.
      #
      # @return [String, nil]
      sig { abstract.returns(T.nilable(String)) }
      def version; end

      # What the verb tells the operator after this builder ran: each line
      # names something the declaration relies on that the next release
      # drops, and what to change. Nothing, for most builders.
      #
      # @return [Array<String>]
      sig { overridable.returns(T::Array[String]) }
      def deprecations
        []
      end

      private

      # Remove the previous build's tree, loudly: `rm_rf` would swallow a
      # permission error and leave the implementation to fill on top of it.
      #
      # @param stage [Pathname]
      # @return [void]
      # @raise [StageNotEmptiedError]
      sig { params(stage: Pathname).void }
      def empty(stage)
        FileUtils.rm_r(stage) if stage.exist?
      rescue SystemCallError => error
        raise StageNotEmptiedError, "cannot empty the stage #{stage}: #{removal_failure(stage, error)}"
      end

      # Why the removal failed, for the operator: the first directory this
      # user cannot write — the stage's parent, the stage, or one beneath
      # it — with its owner and mode; the system's own message when no
      # directory's write bit explains it.
      #
      # @param stage [Pathname]
      # @param error [SystemCallError] what the removal raised
      # @return [String]
      sig { params(stage: Pathname, error: SystemCallError).returns(String) }
      def removal_failure(stage, error)
        blocking = unwritable_directories(stage).first
        return error.message unless blocking

        stat = blocking.lstat
        "#{blocking} is owned by #{user_name(stat.uid)} (mode #{format("%o", stat.mode & 0o7777)}) and not writable " \
          "by #{user_name(Process.euid)} — a shared store needs group-writable stages"
      end

      # Removing an entry needs the write bit on its directory: the stage's
      # parent for the stage itself, each directory of the tree for what it
      # holds. Symlinks are not descended.
      #
      # @param stage [Pathname]
      # @return [Array<Pathname>] those this user cannot write, outermost first
      sig { params(stage: Pathname).returns(T::Array[Pathname]) }
      def unwritable_directories(stage)
        directories = T.let([stage.dirname], T::Array[Pathname])
        stage.find { |path| directories << path if path.lstat.directory? }
        directories.reject { |directory| directory.lstat.writable? }
      end

      # Open what this user wrote to the store's group: dirs `g+rwxs`,
      # files `g+rw`, the shape LinuxDataRootProvisioner gives the root. An
      # entry another user owns (a builder's root-run container) is left:
      # this user cannot change it, and the next `empty` names it. A
      # symlink has no mode of its own, and a dangling one has no target
      # to change.
      #
      # @param stage [Pathname]
      # @return [void]
      sig { params(stage: Pathname).void }
      def share(stage)
        stage.find do |path|
          stat = path.lstat
          next if stat.symlink? || stat.uid != Process.euid

          path.chmod(stat.mode & 0o7777 | (stat.directory? ? SHARED_DIRECTORY_BITS : SHARED_FILE_BITS))
        end
      end

      # @param uid [Integer]
      # @return [String] the account's name, or the uid when the host has no entry for it
      sig { params(uid: Integer).returns(String) }
      def user_name(uid)
        Etc.getpwuid(uid)&.name || uid.to_s
      end
    end
  end
end
