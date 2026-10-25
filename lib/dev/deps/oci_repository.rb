# typed: strict
# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "uri"

require_relative "../gh_auth"
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
    # Registry HTTP, not the engine: `dev deps update` resolves a floor with
    # no daemon running and on a host that has none. The credential is the
    # host's gh token (GhAuth) — the floor lives in GHCR under the org, and a
    # consumer may be outside it, so a workflow token cannot be granted; the
    # Bearer challenge is answered with Basic `login:token` at the realm the
    # registry names, which is the distribution-spec dance every registry
    # speaks.
    class OciRepository < Repository
      extend T::Sig

      # The source is not `<registry>/<repository>:<tag>`.
      class ReferenceError < StandardError; end

      # The registry refused the token after the challenge was answered.
      class AccessDeniedError < StandardError; end

      # Any other non-success from the registry.
      class RegistryError < StandardError; end

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

      # `<host>/<repository>:<tag>` — the host has a dot or a port (so a bare
      # Hub name is refused: the floor is never a floating `ubuntu:22.04`),
      # the tag is a tag, never a digest.
      REFERENCE = %r{\A(?<host>[a-z0-9.-]+(?::\d+)?)/(?<repository>[a-z0-9._/-]+):(?<tag>[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})\z}

      # Attestation manifests ride an index under this pseudo-platform.
      UNKNOWN_PLATFORM = "unknown/unknown"

      # One registry response, the shape the HTTP boundary returns.
      class Response < T::Struct
        const :code, Integer
        const :headers, T::Hash[String, String]
        const :body, String
      end

      # A parsed floor reference.
      class Reference < T::Struct
        extend T::Sig

        const :host, String
        const :repository, String
        const :tag, String

        sig { returns(String) }
        def name = "#{host}/#{repository}"

        sig { returns(String) }
        def manifest_url = "https://#{host}/v2/#{repository}/manifests/#{tag}"

        sig { params(digest: String).returns(String) }
        def blob_url(digest) = "https://#{host}/v2/#{repository}/blobs/#{digest}"
      end

      # @param auth [Dev::GhAuth] the token the challenge is answered with
      sig { params(auth: Dev::GhAuth).void }
      def initialize(auth: Dev::GhAuth.new)
        super()
        @auth = auth
      end

      # @param id [PackageId] its source is the floor reference
      # @return [Package] the tag as one version: digest, `from`, `platforms`
      # @raise [ReferenceError, PackageNotFoundError, AccessDeniedError, RegistryError]
      sig { override.params(id: PackageId).returns(Package) }
      def find(id)
        ref = parse(id.source)
        manifest, bearer = fetch_manifest(ref)
        digest = manifest.headers["docker-content-digest"] || "sha256:#{Digest::SHA256.hexdigest(manifest.body)}"

        Package.new(
          id: id,
          versions: [
            PackageVersion.new(
              version: ref.tag,
              digest: "SHA256=#{digest.delete_prefix("sha256:")}",
              metadata: { "from" => ref.name, "platforms" => platforms(ref, manifest, bearer) },
            ),
          ],
        )
      end

      private

      # @param source [String, nil]
      # @return [Reference]
      # @raise [ReferenceError]
      sig { params(source: T.nilable(String)).returns(Reference) }
      def parse(source)
        match = source && REFERENCE.match(source)
        unless match
          raise ReferenceError,
            "#{source.inspect} is not a floor reference — declare `from: \"<registry>/<repository>:<tag>\"` " \
              "(a registry host, a repository, a tag to resolve; dev locks the digest)"
        end

        Reference.new(host: T.must(match[:host]), repository: T.must(match[:repository]), tag: T.must(match[:tag]))
      end

      # The manifest, answering one Bearer challenge on the way.
      #
      # @param ref [Reference]
      # @return [Array(Response, String | nil)] the manifest and the bearer token used, if any
      sig { params(ref: Reference).returns([Response, T.nilable(String)]) }
      def fetch_manifest(ref)
        accept = { "Accept" => MANIFEST_MEDIA_TYPES.join(", ") }
        response = get(ref.manifest_url, headers: accept)
        bearer = T.let(nil, T.nilable(String))
        if response.code == 401 && (challenge = response.headers["www-authenticate"])
          bearer = token_for(challenge)
          response = get(ref.manifest_url, headers: accept.merge("Authorization" => "Bearer #{bearer}"))
        end
        check!(response, ref)
        [response, bearer]
      end

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
      # @param ref [Reference]
      # @param manifest [Response]
      # @param bearer [String, nil] the session's token, reused for the config blob
      # @return [Array<String>] docker platform strings, `os/arch[/variant]`
      sig { params(ref: Reference, manifest: Response, bearer: T.nilable(String)).returns(T::Array[String]) }
      def platforms(ref, manifest, bearer)
        document = JSON.parse(manifest.body)
        if INDEX_MEDIA_TYPES.include?(document["mediaType"]) || document.key?("manifests")
          return Array(document["manifests"]).filter_map { |entry| platform_string(entry["platform"]) }
            .reject { |platform| platform.start_with?(UNKNOWN_PLATFORM) }
        end

        config_digest = document.dig("config", "digest") or raise RegistryError, "manifest names no config: #{ref.manifest_url}"
        headers = bearer ? { "Authorization" => "Bearer #{bearer}" } : {}
        config = get(ref.blob_url(config_digest), headers: headers)
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
      # @param ref [Reference]
      # @raise [PackageNotFoundError, AccessDeniedError, RegistryError]
      sig { params(response: Response, ref: Reference).void }
      def check!(response, ref)
        case response.code
        when 200 then nil
        when 404 then raise PackageNotFoundError, "#{ref.name}:#{ref.tag} — the registry has no such tag"
        when 401, 403 then raise AccessDeniedError, denied_message
        else raise RegistryError, "#{ref.manifest_url} answered HTTP #{response.code}: #{response.body.strip}"
        end
      end

      sig { returns(String) }
      def denied_message
        "the registry refused gh's token — it needs #{Dev::GhAuth::READ_PACKAGES} on the floor's package " \
          "(run: gh auth refresh -s #{Dev::GhAuth::READ_PACKAGES}, and ask for access if the package is not yours)"
      end

      # The HTTP boundary, one GET; redirects followed (blob reads redirect
      # to storage).
      #
      # @param url [String]
      # @param headers [Hash{String => String}]
      # @return [Response]
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
      end
    end
  end
end
