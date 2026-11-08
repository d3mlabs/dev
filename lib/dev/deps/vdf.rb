# typed: strict
# frozen_string_literal: true

module Dev
  module Deps
    # Valve's KeyValues text format ("VDF"), as the Steam content builder
    # reads its build scripts: one root key over a block, every key and
    # scalar double-quoted, blocks in braces, one entry per line, tabs for
    # depth. Writing only — SteamCmd reads the one VDF dev consumes
    # (`app_info_print`) with a targeted scan, and the two never meet.
    #
    # Scalars are strings (a number is quoted like any other), nested
    # hashes are blocks. Quotes and backslashes inside a value are escaped
    # as `\"` and `\\`; a Windows content root therefore round-trips.
    module Vdf
      extend T::Sig

      Value = T.type_alias { T.any(String, Integer, T::Hash[String, T.untyped]) }

      class << self
        extend T::Sig

        # Serialize one root key and its block.
        #
        # @param root [String] the root key (`AppBuild`, `DepotBuild`)
        # @param block [Hash{String => String, Integer, Hash}] the entries, in order
        # @return [String] the document, newline-terminated
        sig { params(root: String, block: T::Hash[String, Value]).returns(String) }
        def dump(root, block)
          "#{quote(root)}\n#{dump_block(block, 0)}"
        end

        private

        # @param block [Hash]
        # @param depth [Integer] the block's indentation level
        # @return [String] the braces and the entries, newline-terminated
        sig { params(block: T::Hash[String, Value], depth: Integer).returns(String) }
        def dump_block(block, depth)
          indent = "\t" * depth
          inner = "\t" * (depth + 1)
          lines = block.map do |key, value|
            if value.is_a?(Hash)
              "#{inner}#{quote(key)}\n#{dump_block(value, depth + 1)}"
            else
              "#{inner}#{quote(key)}\t#{quote(value.to_s)}\n"
            end
          end
          "#{indent}{\n#{lines.join}#{indent}}\n"
        end

        # @param text [String]
        # @return [String] the text double-quoted, quotes and backslashes escaped
        sig { params(text: String).returns(String) }
        def quote(text)
          "\"#{text.gsub("\\", "\\\\\\\\").gsub("\"", "\\\"")}\""
        end
      end
    end
  end
end
