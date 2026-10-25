# typed: strict
# frozen_string_literal: true

require "dev/environment_image"

module Dev
  # What this machine was provisioned from: the `/etc/dev/environment`
  # marker the image build writes (EnvironmentImage#dockerfile), read back.
  # A host baked from a project's image carries it, a container dev made
  # carries its image's, a bare machine carries none.
  #
  # The host rule (dev#308, ADR-0007 amended) is one comparison over it:
  # a host runs an image's commands natively when it was provisioned from
  # that image — same name, same digest as the lock's pin — and inside the
  # image otherwise. The digest is the generated Dockerfile's, so the
  # floor, the platform and the apt set are all inside the comparison; a
  # Mac fails it by construction, and so does a host built from last
  # week's recipe (drift).
  class HostEnvironment
    extend T::Sig

    # Where the marker lives, host or container (one constant, the image's).
    MARKER_PATH = EnvironmentImage::MARKER_PATH

    # The marker's two lines, each `key=value`.
    LINE = /\A(?<key>name|digest)=(?<value>\S+)\z/

    # @param path [String] the marker file (injectable for tests)
    sig { params(path: String).void }
    def initialize(path: MARKER_PATH)
      @path = path
      @fields = T.let(nil, T.nilable(T::Hash[String, String]))
    end

    # @return [String, nil] the image's name, nil without a well-formed marker
    sig { returns(T.nilable(String)) }
    def name = fields["name"]

    # @return [String, nil] the image's digest (64 hex), nil without a well-formed marker
    sig { returns(T.nilable(String)) }
    def digest = fields["digest"]

    # Whether this machine was provisioned from +image+ as the lock pins it.
    #
    # @param image [Dev::EnvironmentImage]
    # @return [Boolean]
    sig { params(image: EnvironmentImage).returns(T::Boolean) }
    def provisioned_from?(image)
      name == image.name && digest == image.digest
    end

    # The identity in a log line: `name@<12 hex>`, or what is missing.
    #
    # @return [String]
    sig { returns(String) }
    def describe
      return "no image (no #{@path})" if name.nil?

      "#{name}@#{T.must(digest)[0, EnvironmentImage::SHORT_DIGEST_LENGTH]}"
    end

    private

    # The marker parsed, once; empty unless both lines are present and the
    # digest is 64 hex — anything less is no marker.
    #
    # @return [Hash{String => String}]
    sig { returns(T::Hash[String, String]) }
    def fields
      @fields ||= parse
    end

    sig { returns(T::Hash[String, String]) }
    def parse
      return {} unless File.file?(@path)

      parsed = T.let({}, T::Hash[String, String])
      File.readlines(@path, chomp: true).each do |line|
        match = LINE.match(line)
        parsed[T.must(match[:key])] = T.must(match[:value]) if match
      end
      return {} unless parsed.key?("name") && parsed["digest"].to_s.match?(/\A[0-9a-f]{64}\z/)

      parsed
    end
  end
end
