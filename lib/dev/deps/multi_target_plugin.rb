# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "ficsit_target"

module Dev
  module Deps
    # SMR's multi-target plugin zip — the one file a mod version is
    # uploaded as when it is built for several targets
    # (`validateMultiTargetPlugin` in smr-api): every entry under a target
    # directory (`Windows/…`, `WindowsServer/…`, `LinuxServer/…`), each
    # directory holding one target's staged plugin with the same
    # `<ModRef>.uplugin` at its root, and nothing at the zip's own root.
    # SMR splits it back into per-target downloads on its side. Made by
    # MultiTargetPluginMerger from the per-target zips; a value once made.
    class MultiTargetPlugin < T::Struct
      extend T::Sig

      const :archive, Pathname
      const :mod_reference, String
      # In the order the shipments were merged, each once.
      const :targets, T::Array[FicsitTarget]

      # @return [Integer] the zip's size in bytes
      sig { returns(Integer) }
      def size
        archive.size
      end

      sig { returns(String) }
      def to_s
        "#{mod_reference} (#{targets.map(&:serialize).join(", ")})"
      end
    end
  end
end
