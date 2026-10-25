# typed: strict
# frozen_string_literal: true

require "pathname"
require "sorbet-runtime"
require_relative "platform"
require_relative "deps/config"
require_relative "deps/cli_ui"
require_relative "deps/lockfile"
require_relative "deps/fetcher"
require_relative "deps/installer"

module Dev
  module Deps
    # A manifest was promised at a path where no file exists.
    class ManifestNotFoundError < StandardError; end

    # A manifest file ran to completion without ever calling Dev::Deps.define,
    # so it defined nothing to read.
    class UndefinedManifestError < StandardError; end

    @last_config = T.let(nil, T.nilable(Config))

    class << self
      extend T::Sig

      # Evaluate a dependencies.rb DSL block into a Config and remember it.
      #
      # @param block [Proc] DSL block evaluated in DSL context
      # @return [Config]
      sig { params(block: T.nilable(T.proc.bind(DSL).void)).returns(Config) }
      def define(&block)
        @last_config = Config.define(&block)
      end

      # The most recently defined config (from the last call to .define).
      # Useful for retrieving the config after loading a dependencies.rb file.
      #
      # @return [Config, nil]
      sig { returns(T.nilable(Config)) }
      attr_reader :last_config

      # Clears the last defined config. Call before loading a dependencies.rb:
      # a file that never calls .define (e.g. dev's own bootstrap-constants
      # dependencies.rb) would otherwise leave a previously loaded project's
      # config visible as if it were its own.
      #
      # @return [void]
      sig { void }
      def reset!
        @last_config = nil
      end

      # Evaluate a dependencies.rb file into the Config it defines, leaving
      # last_config exactly as it was: a manifest read as a library — an
      # integration's own dependencies.rb — must never masquerade as the
      # project's.
      #
      # @param path [Pathname] the manifest file
      # @return [Config] what the file defined
      # @raise [ManifestNotFoundError] if no file exists at path
      # @raise [UndefinedManifestError] if the file never calls .define
      sig { params(path: Pathname).returns(Config) }
      def evaluate(path)
        previous = @last_config
        raise ManifestNotFoundError, "no manifest at #{path}" unless path.file?

        @last_config = nil
        Kernel.load(path.to_s)
        # Through the reader, not the ivar: the file's define call is what
        # set it, which flow typing of the assignment above cannot see.
        defined = last_config
        raise UndefinedManifestError, "#{path} never calls Dev::Deps.define" if defined.nil?

        defined
      ensure
        @last_config = previous
      end

      # Detect the current environment (ci vs dev) from the CI variable alone.
      #
      # Deliberately NOT platform-based: a Linux workstation is "dev" and a Mac
      # CI runner is "ci". The one caller that needed the old Linux-implies-CI
      # clause (bin/docker-install-build-deps.sh, which runs inside docker
      # builds where no CI variable exists) sets CI=true explicitly instead of
      # relying on detection — fix by declaration, not detection.
      #
      # @return [String] "ci" or "dev"
      sig { returns(String) }
      def detect_env
        ENV["CI"].to_s =~ /\A(true|1)\z/i ? "ci" : "dev"
      end

      # Detect the host OS for host-gated dependency filtering (the `host:`
      # declaration axis). Matches the symbols the DSL accepts (:darwin, :linux).
      #
      # @return [String] "darwin", "linux", or "windows"
      sig { returns(String) }
      def detect_host
        Dev::Platform.os
      end
    end
  end
end
