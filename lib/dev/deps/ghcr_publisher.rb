# typed: strict
# frozen_string_literal: true

require "pathname"
require "dev/container_engine"
require "dev/lifecycle/build_id"
require "dev/lifecycle/channel"
require "dev/lifecycle/publisher"
require "dev/lifecycle/receipt"
require "dev/lifecycle/shipment"
require "dev/lifecycle/track"
require "dev/registry_login"
require_relative "oci_repository"

module Dev
  module Deps
    # The write side of the image entry (dev#192 K5, dev#428): each shipped
    # archive — a `docker save` tarball of one tagged image — is loaded
    # into the engine, tagged for the track and pushed to GHCR, the
    # registry the project's own environment image is pulled from
    # (ADR-0010: a store is publishable exactly when the project depends on
    # it). Every project whose lock pins an `image` gets the `deploy ghcr`
    # channel with no dev.yml line; its first consumers are the org's image
    # repos, whose targets are the images they build.
    #
    # The archive decides the **repository** (the `ghcr.io/<org>/<name>`
    # its image was saved under — the builder's business, dev#434) and the
    # track decides the **tag**: a release's archive is pushed as its
    # version (`ghcr.io/d3mlabs/unreal-engine-build-base:ue5.8-3`, what
    # consumers pin), a working artifact as `testing-<build id>`, a tag no
    # floor ever names (BuildId's `+` is not in docker's tag grammar, so it
    # is spelled `-`). Every archive is loaded and checked before the first
    # push, so a tarball that is not an image, carries no tag, or names
    # another registry refuses the whole deploy with nothing uploaded. The
    # archives are read-only input: the engine's image store is the
    # publisher's own, and nothing lands in the scratch. Credentials are
    # the registry login's (RegistryLogin: gh's token, or the one
    # DEV_REGISTRY_TOKEN names, with the write scope), held for the pushes
    # only.
    #
    # The engine and the login are resolved on first use, not at
    # construction: the Registry builds every contributed publisher at
    # load for every command (Dev::ProjectPublishers), and the operator's
    # engine record is read — and failed on — only when a deploy pushes.
    class GhcrPublisher
      extend T::Sig
      include Lifecycle::Publisher

      # `docker load` failed, or printed nothing it loaded.
      class LoadFailedError < RuntimeError; end

      # The archive's image carries no repository tag (`docker save` of an
      # image id): nothing says where it goes.
      class UntaggedImageError < RuntimeError; end

      # The archive's image is tagged under a registry other than GHCR.
      class ForeignRegistryError < RuntimeError; end

      # The archive loads images of more than one repository.
      class AmbiguousImageError < RuntimeError; end

      # A release's version is not a docker tag.
      class InvalidTagError < RuntimeError; end

      # Asked to ship on the live track from the store — the verb derives
      # the track from the source, so this is a dev wiring bug.
      class LiveTrackWithoutReleaseError < RuntimeError; end

      # `docker tag` returned nonzero.
      class TagFailedError < RuntimeError; end

      # `docker push` returned nonzero.
      class PushFailedError < RuntimeError; end

      REGISTRY = "ghcr.io"
      TESTING_TAG_PREFIX = "testing-"
      # Docker's tag grammar, as OciRepository::REFERENCE spells it for a floor.
      TAG = /\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}\z/
      # What `docker load` prints for each tagged image it loaded.
      LOADED_IMAGE = /^Loaded image: (?<ref>\S+)$/

      # One image as the archive loaded it and as the track names it.
      class Upload < T::Struct
        const :loaded, String
        const :target, String
      end

      class << self
        extend T::Sig

        # The tag a working artifact is pushed under: the build id, made a
        # docker tag — `+` and anything else outside the grammar spelled
        # `-` — behind a prefix no release version carries.
        #
        # @param build_id [Lifecycle::BuildId]
        # @return [String]
        sig { params(build_id: Lifecycle::BuildId).returns(String) }
        def testing_tag(build_id)
          "#{TESTING_TAG_PREFIX}#{build_id.to_s.gsub(/[^A-Za-z0-9_.-]/, "-")}"
        end
      end

      # @param engine [ContainerEngine, nil] the engine that loads and pushes (default: the operator's, resolved on first use)
      # @param login [RegistryLogin, nil] the registry session around the pushes (default: over the engine)
      sig { params(engine: T.nilable(ContainerEngine), login: T.nilable(RegistryLogin)).void }
      def initialize(engine: nil, login: nil)
        @engine = engine
        @login = login
      end

      # Load every archive, then push each image under its track's tag in
      # one registry session.
      #
      # @param shipments [Array<Lifecycle::Shipment>] each archive a `docker save` tarball
      # @param channel [Lifecycle::Channel] for the messages
      # @param track [Lifecycle::Track] live tags by the release version, testing by the build id
      # @param scratch [Pathname] unused: the engine's image store is the scratch
      # @return [Lifecycle::Receipt] the references pushed
      # @raise [LoadFailedError, UntaggedImageError, ForeignRegistryError, AmbiguousImageError]
      # @raise [InvalidTagError, LiveTrackWithoutReleaseError]
      # @raise [TagFailedError, PushFailedError] at the first image the engine refuses
      # @raise [GhAuth::MissingScopeError, RegistryLogin::LoginFailedError]
      sig do
        override.params(
          shipments: T::Array[Lifecycle::Shipment], channel: Lifecycle::Channel, track: Lifecycle::Track, scratch: Pathname,
        ).returns(Lifecycle::Receipt)
      end
      def publish(shipments, channel:, track:, scratch:)
        _ = scratch
        uploads = shipments.map { |shipment| upload_for(shipment, channel:, track:) }
        login.with(REGISTRY, publish: true) { uploads.each { |upload| push(upload) } }
        Lifecycle::Receipt.new(summary: "pushed #{uploads.map(&:target).join(", ")}")
      end

      # The declaration as `dev help` renders it.
      sig { returns(String) }
      def to_s = "docker push"

      private

      # @return [ContainerEngine]
      sig { returns(ContainerEngine) }
      def engine
        @engine ||= ContainerEngine.resolve
      end

      # @return [RegistryLogin]
      sig { returns(RegistryLogin) }
      def login
        @login ||= RegistryLogin.new(engine:)
      end

      # Load one archive and name its push.
      #
      # @param shipment [Lifecycle::Shipment]
      # @param channel [Lifecycle::Channel]
      # @param track [Lifecycle::Track]
      # @return [Upload]
      sig { params(shipment: Lifecycle::Shipment, channel: Lifecycle::Channel, track: Lifecycle::Track).returns(Upload) }
      def upload_for(shipment, channel:, track:)
        references = load(shipment, channel)
        repository = the_one_repository(references, shipment, channel)
        Upload.new(loaded: T.must(references.first).to_s, target: "#{repository}:#{tag_for(shipment, track)}")
      end

      # `docker load` the archive and parse what it reports loaded.
      #
      # @param shipment [Lifecycle::Shipment]
      # @param channel [Lifecycle::Channel]
      # @return [Array<OciRepository::Reference>] the tagged images, in the engine's order
      # @raise [LoadFailedError, UntaggedImageError, ForeignRegistryError]
      sig { params(shipment: Lifecycle::Shipment, channel: Lifecycle::Channel).returns(T::Array[OciRepository::Reference]) }
      def load(shipment, channel)
        output = engine.capture(["load", "--input", shipment.archive.to_s])
        if output.empty?
          raise LoadFailedError,
            "channel '#{channel}': docker load #{shipment.archive.basename} (#{shipment}) failed — the archive must be a " \
              "`docker save` tarball"
        end

        refs = output.scan(LOADED_IMAGE).flatten.map(&:to_s)
        if refs.empty?
          raise UntaggedImageError,
            "channel '#{channel}': #{shipment.archive.basename} (#{shipment}) loaded an image with no repository tag — " \
              "`docker save` a tagged image (#{REGISTRY}/<org>/<name>:<tag>)"
        end

        refs.map { |ref| reference(ref, shipment, channel) }
      end

      # @param ref [String] a `Loaded image:` reference
      # @param shipment [Lifecycle::Shipment]
      # @param channel [Lifecycle::Channel]
      # @return [OciRepository::Reference]
      # @raise [ForeignRegistryError]
      sig { params(ref: String, shipment: Lifecycle::Shipment, channel: Lifecycle::Channel).returns(OciRepository::Reference) }
      def reference(ref, shipment, channel)
        match = OciRepository::REFERENCE.match(ref)
        if match.nil? || match[:host] != REGISTRY
          raise ForeignRegistryError,
            "channel '#{channel}': #{shipment.archive.basename} (#{shipment}) is tagged #{ref}, not under #{REGISTRY} — " \
              "`docker save` the image under its #{REGISTRY}/<org>/<name> tag"
        end

        OciRepository::Reference.new(host: T.must(match[:host]), repository: T.must(match[:repository]), tag: T.must(match[:tag]))
      end

      # @param references [Array<OciRepository::Reference>] non-empty
      # @param shipment [Lifecycle::Shipment]
      # @param channel [Lifecycle::Channel]
      # @return [String] `ghcr.io/<org>/<name>`
      # @raise [AmbiguousImageError]
      sig do
        params(references: T::Array[OciRepository::Reference], shipment: Lifecycle::Shipment, channel: Lifecycle::Channel)
          .returns(String)
      end
      def the_one_repository(references, shipment, channel)
        names = references.map(&:name).uniq
        return names.fetch(0) if names.size == 1

        raise AmbiguousImageError,
          "channel '#{channel}': #{shipment.archive.basename} (#{shipment}) loads images of #{names.size} repositories " \
            "(#{names.join(", ")}) — `docker save` one image"
      end

      # @param shipment [Lifecycle::Shipment]
      # @param track [Lifecycle::Track]
      # @return [String] the tag the track names
      # @raise [InvalidTagError, LiveTrackWithoutReleaseError]
      sig { params(shipment: Lifecycle::Shipment, track: Lifecycle::Track).returns(String) }
      def tag_for(shipment, track)
        return self.class.testing_tag(shipment.build_id) unless track.live?

        provenance = shipment.provenance
        unless provenance.is_a?(Lifecycle::Provenance::Release)
          raise LiveTrackWithoutReleaseError, "#{shipment} was shipped on the live track from the store (dev wiring bug)"
        end

        version = provenance.tag.version
        raise InvalidTagError, "release version #{version.inspect} is not a docker tag (#{TAG.source})" unless TAG.match?(version)

        version
      end

      # @param upload [Upload]
      # @raise [TagFailedError, PushFailedError]
      sig { params(upload: Upload).void }
      def push(upload)
        raise TagFailedError, "docker tag #{upload.loaded} #{upload.target} failed" unless engine.run(["tag", upload.loaded, upload.target])
        raise PushFailedError, "docker push #{upload.target} failed" unless engine.run(["push", upload.target])
      end
    end
  end
end
