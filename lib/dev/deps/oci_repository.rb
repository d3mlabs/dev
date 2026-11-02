# typed: strict
# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "openssl"
require "uri"

require_relative "../gh_auth"
require_relative "floor_reference"
require_relative "package"
require_relative "package_id"
require_relative "package_version"
require_relative "repository"

module Dev
  module Deps
    # The floor of an `image` block (dev#277): a tagged image in a container
    # registry, resolved to the digest the registry serves for the tag.
    #
    # The url model, because a tag names one artifact: the source is the
    # whole address (`ghcr.io/d3mlabs/unreal-engine-build-base:ue5.8-3`),
    # find returns the tag as the single version, and its digest — the
    # registry's `Docker-Content-Digest` for the manifest — is what the pull
    # by digest verifies. Platforms are facts beside it: the index's entries,
    # or the lone manifest's config `os/architecture`.
    #
    # Two types, one per side of the registry (dev#395): the source is read
    # as a FloorReference — the author's ask, whose grammar that type owns —
    # and the registry's answer is gathered as a ResolvedFloor before it is
    # mapped onto Package/PackageVersion as the last step. The pin's
    # metadata is the serialization boundary: the string shape survives
    # only there.
    #
    # Registry HTTP, not the engine: `dev deps update` resolves a floor with
    # no daemon running and on a host that has none. The credential is the
    # host's gh token (GhAuth) — the floor lives in GHCR under the org, and a
    # consumer may be outside it, so a workflow token cannot be granted; the
    # Bearer challenge is answered with Basic `login:token` at the realm the
    # registry names, which is the distribution-spec dance every registry
    # speaks.
    class OciRepository < Repository
      extend T::Sig

      # The registry refused the token after the challenge was answered.
      class AccessDeniedError < UnreadableUniverseError; end

      # Any other non-success from the registry, or no answer at all (a
      # registry that is down or unreachable).
      class RegistryError < UnreadableUniverseError; end

      # What the registry says a floor is made of: one manifest or an index.
      MANIFEST_MEDIA_TYPES = T.let(
        [
          "application/vnd.oci.image.index.v1+json",
          "application/vnd.docker.distribution.manifest.list.v2+json",
          "application/vnd.oci.image.manifest.v1+json",
          "application/vnd.docker.distribution.manifest.v2+json",
        ].freeze,
        T::Array[String],
      )

      INDEX_MEDIA_TYPES = T.let(
        [
          "application/vnd.oci.image.index.v1+json",
          "application/vnd.docker.distribution.manifest.list.v2+json",
        ].freeze,
        T::Array[String],
      )

      # Attestation manifests ride an index under this pseudo-platform.
      UNKNOWN_PLATFORM = "unknown/unknown"

      # One registry response, the shape the HTTP boundary returns.
      class Response < T::Struct
        const :code, Integer
        const :headers, T::Hash[String, String]
        const :body, String
      end

      # The registry's answer for a floor: the reference it was asked for,
      # the manifest digest it serves for the tag (as the registry spells
      # it, `sha256:<hex>`), and the platforms the floor publishes.
      class ResolvedFloor < T::Struct
        const :reference, FloorReference
        const :digest, String
        const :platforms, T::Array[String]
      end

      # @param auth [Dev::GhAuth] the token the challenge is answered with
      sig { params(auth: Dev::GhAuth).void }
      def initialize(auth: Dev::GhAuth.new)
        super()
        @auth = auth
      end

      # @param id [PackageId] its source is the floor reference
      # @return [Package] the tag as one version: digest, `from`, `platforms`
      # @raise [FloorReference::ReferenceError] if the source is not a floor
      #   reference — the declaration being wrong, never the registry's silence
      # @raise [PackageNotFoundError, AccessDeniedError, RegistryError] the
      #   universe could not be read
      sig { override.params(id: PackageId).returns(Package) }
      def find(id)
        floor = fetch_floor(FloorReference.parse(id.source))
        Package.new(id: id, versions: [version_of(floor)])
      end

      private

      # Ask the registry what the floor is: its manifest digest and the
      # platforms it publishes.
      #
      # @param ref [FloorReference]
      # @return [ResolvedFloor]
      # @raise [PackageNotFoundError, AccessDeniedError, RegistryError]
      sig { params(ref: FloorReference).returns(ResolvedFloor) }
      def fetch_floor(ref)
        manifest, bearer = fetch_manifest(ref)
        digest = manifest.headers["docker-content-digest"] || "sha256:#{Digest::SHA256.hexdigest(manifest.body)}"
        ResolvedFloor.new(reference: ref, digest: digest, platforms: platforms(ref, manifest, bearer))
      end

      # The floor as the one version of its package: the tag is the version,
      # the manifest digest its integrity hash in dev's spelling, and the
      # reference less its tag is `from` — the metadata hash is where the
      # reference becomes a string again, for the lock to serialize and
      # PinCarryover to read back.
      #
      # @param floor [ResolvedFloor]
      # @return [PackageVersion]
      sig { params(floor: ResolvedFloor).returns(PackageVersion) }
      def version_of(floor)
        PackageVersion.new(
          version: floor.reference.tag,
          digest: "SHA256=#{floor.digest.delete_prefix("sha256:")}",
          metadata: { "from" => floor.reference.name, "platforms" => floor.platforms },
        )
      end

      # The manifest, answering one Bearer challenge on the way.
      #
      # @param ref [FloorReference]
      # @return [Array(Response, String | nil)] the manifest and the bearer token used, if any
      sig { params(ref: FloorReference).returns([Response, T.nilable(String)]) }
      def fetch_manifest(ref)
        accept = { "Accept" => MANIFEST_MEDIA_TYPES.join(", ") }
        response = get(manifest_url(ref), headers: accept)
        bearer = T.let(nil, T.nilable(String))
        if response.code == 401 && (challenge = response.headers["www-authenticate"])
          bearer = token_for(challenge)
          response = get(manifest_url(ref), headers: accept.merge("Authorization" => "Bearer #{bearer}"))
        end
        check!(response, ref)
        [response, bearer]
      end

      # Where the registry serves the floor's manifest: a registry concern,
      # derived from the reference and kept here.
      #
      # @param ref [FloorReference]
      # @return [String]
      sig { params(ref: FloorReference).returns(String) }
      def manifest_url(ref) = "https://#{ref.host}/v2/#{ref.repository}/manifests/#{ref.tag}"

      # Where the registry serves one of the floor's blobs.
      #
      # @param ref [FloorReference]
      # @param digest [String] the blob's digest, as the manifest names it
      # @return [String]
      sig { params(ref: FloorReference, digest: String).returns(String) }
      def blob_url(ref, digest) = "https://#{ref.host}/v2/#{ref.repository}/blobs/#{digest}"

      # Trade gh's token for the registry's bearer token at the realm the
      # challenge names, for the scope it names.
      #
      # @param challenge [String] the WWW-Authenticate header
      # @return [String] the bearer token
      sig { params(challenge: String).returns(String) }
      def token_for(challenge)
        params = T.let({}, T::Hash[String, String])
        challenge.scan(/(\w+)="([^"]*)"/) { |key, value| params[key] = value }
        realm = params["realm"]
        raise RegistryError, "registry challenge names no realm: #{challenge}" if realm.nil?

        query = URI.encode_www_form(params.slice("scope", "service").sort)
        basic = ["#{@auth.login}:#{@auth.token}"].pack("m0")
        response = get("#{realm}?#{query}", headers: { "Authorization" => "Basic #{basic}" })
        raise AccessDeniedError, denied_message unless response.code == 200

        JSON.parse(response.body).fetch("token") { raise RegistryError, "token endpoint returned no token: #{realm}" }
      end

      # The platforms the floor publishes: an index lists them; a lone
      # manifest's config names its one.
      #
      # @param ref [FloorReference]
      # @param manifest [Response]
      # @param bearer [String, nil] the session's token, reused for the config blob
      # @return [Array<String>] docker platform strings, `os/arch[/variant]`
      sig { params(ref: FloorReference, manifest: Response, bearer: T.nilable(String)).returns(T::Array[String]) }
      def platforms(ref, manifest, bearer)
        document = JSON.parse(manifest.body)
        if INDEX_MEDIA_TYPES.include?(document["mediaType"]) || document.key?("manifests")
          return Array(document["manifests"]).filter_map { |entry| platform_string(entry["platform"]) }
            .reject { |platform| platform.start_with?(UNKNOWN_PLATFORM) }
        end

        config_digest = document.dig("config", "digest") or raise RegistryError, "manifest names no config: #{manifest_url(ref)}"
        headers = bearer ? { "Authorization" => "Bearer #{bearer}" } : {}
        config = get(blob_url(ref, config_digest), headers: headers)
        check!(config, ref)
        [T.must(platform_string(JSON.parse(config.body)))]
      end

      # @param platform [Hash, nil] `{ "os", "architecture", "variant"? }`
      # @return [String, nil]
      sig { params(platform: T.nilable(T::Hash[String, T.untyped])).returns(T.nilable(String)) }
      def platform_string(platform)
        return nil unless platform && platform["os"] && platform["architecture"]

        [platform["os"], platform["architecture"], platform["variant"]].compact.join("/")
      end

      # @param response [Response]
      # @param ref [FloorReference]
      # @raise [PackageNotFoundError, AccessDeniedError, RegistryError]
      sig { params(response: Response, ref: FloorReference).void }
      def check!(response, ref)
        case response.code
        when 200 then nil
        when 404 then raise PackageNotFoundError, "#{ref} — the registry has no such tag"
        when 401, 403 then raise AccessDeniedError, denied_message
        else raise RegistryError, "#{manifest_url(ref)} answered HTTP #{response.code}: #{response.body.strip}"
        end
      end

      sig { returns(String) }
      def denied_message
        "the registry refused gh's token — it needs #{Dev::GhAuth::READ_PACKAGES} on the floor's package " \
          "(run: gh auth refresh -s #{Dev::GhAuth::READ_PACKAGES}, and ask for access if the package is not yours)"
      end

      # The HTTP boundary, one GET; redirects followed (blob reads redirect
      # to storage). A registry that does not answer at all is a
      # RegistryError like one that answers badly: either way the universe
      # could not be read.
      #
      # @param url [String]
      # @param headers [Hash{String => String}]
      # @return [Response]
      # @raise [RegistryError] if the transport fails before any answer
      sig { params(url: String, headers: T::Hash[String, String]).returns(Response) }
      def get(url, headers:)
        uri = URI(url)
        response = Net::HTTP.start(T.must(uri.host), uri.port, use_ssl: uri.scheme == "https") do |http|
          http.request(Net::HTTP::Get.new(uri, headers))
        end
        if response.is_a?(Net::HTTPRedirection) && (location = response["location"])
          return get(location, headers: headers.reject { |key, _| key == "Authorization" })
        end

        Response.new(
          code: response.code.to_i,
          headers: response.each_header.to_h { |key, value| [key.downcase, value] },
          body: response.body.to_s,
        )
      rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, EOFError => e
        raise RegistryError, "#{url} did not answer: #{e.message}"
      end
    end
  end
end
