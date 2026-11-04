# typed: strict
# frozen_string_literal: true

module Dev
  module Lifecycle
    # A size in bytes as dev.yml and the CLI spell one — `2GiB`, `500MiB`,
    # `1024` — for the archive's `split:` (dev#192, K1). Binary units only
    # (`KiB`, `MiB`, `GiB`, `TiB`), because the one limit this exists to
    # stay under, GitHub's 2 GiB per release asset, is binary.
    class ByteSize < T::Struct
      extend T::Sig

      # A string that is not an integer followed by one of the units.
      class InvalidByteSizeError < ArgumentError; end

      UNITS = T.let(
        { "B" => 1, "KiB" => 1024, "MiB" => 1024**2, "GiB" => 1024**3, "TiB" => 1024**4 }.freeze,
        T::Hash[String, Integer],
      )
      PATTERN = /\A(\d+)\s*(#{UNITS.keys.join("|")})?\z/

      const :bytes, Integer

      class << self
        extend T::Sig

        # @param text [String] e.g. "2GiB"; a bare integer is bytes
        # @return [ByteSize]
        # @raise [InvalidByteSizeError]
        sig { params(text: String).returns(ByteSize) }
        def parse(text)
          match = PATTERN.match(text.strip)
          unless match && Integer(T.must(match[1])).positive?
            raise InvalidByteSizeError,
              "#{text.inspect} is not a size: a positive integer with one of #{UNITS.keys.join(", ")} (2GiB, 500MiB)"
          end

          new(bytes: Integer(T.must(match[1])) * UNITS.fetch(match[2] || "B"))
        end
      end

      # The largest unit that divides the size exactly, so `2GiB` reads
      # back as written.
      #
      # @return [String]
      sig { returns(String) }
      def to_s
        unit, factor = T.must(UNITS.reverse_each.find { |_unit, factor| (bytes % factor).zero? })
        "#{bytes / factor}#{unit == "B" ? "" : unit}"
      end

      sig { params(other: Object).returns(T::Boolean) }
      def ==(other) = other.is_a?(ByteSize) && bytes == other.bytes

      sig { params(other: Object).returns(T::Boolean) }
      def eql?(other) = self == other

      sig { returns(Integer) }
      def hash = [ByteSize, bytes].hash
    end
  end
end
