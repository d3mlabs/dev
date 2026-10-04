# typed: strict
# frozen_string_literal: true

require "fileutils"
require "pathname"
require "securerandom"
require "sorbet-runtime"
require "dev/data_root"

module Dev
  # A throwaway data root for one cold run (`dev up --no-cache`): an empty
  # sibling of the warm root, made the process's data root for the block's
  # duration through the one override DataRoot already honours
  # (`DEV_DATA_ROOT`), then removed. Everything that resolves the data root
  # at call time — the artifact store, the container's data-root mount —
  # lands in it, so a run inside the block starts from nothing and leaves
  # nothing behind; the warm root is never touched. A sibling, not a tmpdir,
  # so it is mountable wherever the warm root is.
  module ColdRoot
    extend T::Sig

    ENV_VAR = "DEV_DATA_ROOT"

    class << self
      extend T::Sig

      # Run +blk+ with a fresh data root beside +warm_root+.
      #
      # @param warm_root [String] the data root to stand beside (defaults to the resolved one)
      # @yieldparam root [Pathname] the throwaway data root, created
      # @return [void]
      sig { params(warm_root: String, blk: T.proc.params(root: Pathname).void).void }
      def with(warm_root: DataRoot.path, &blk)
        root = Pathname("#{warm_root}-cold-#{SecureRandom.hex(4)}")
        previous = ENV.fetch(ENV_VAR, nil)
        root.mkpath
        ENV[ENV_VAR] = root.to_s
        begin
          blk.call(root)
        ensure
          if previous.nil?
            ENV.delete(ENV_VAR)
          else
            ENV[ENV_VAR] = previous
          end
          FileUtils.rm_rf(root)
        end
      end
    end
  end
end
