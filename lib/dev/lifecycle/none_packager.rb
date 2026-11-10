# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "build"
require_relative "packager"
require_relative "packed_archive"

module Dev
  module Lifecycle
    # The built-in `none` packager (dev#192, K1): the target is built and
    # never shipped — the Editor `dev test` runs, a library the clients
    # link — so it is invisible to `package`, `release` and `deploy`
    # (Target#packageable?). Asking it to package anyway is a programming
    # error, reported as one.
    class NonePackager
      extend T::Sig
      include Packager

      # `package` reached a target that declares `packager: none`.
      class NeverPackagedError < RuntimeError; end

      # @param build [Build]
      # @param install [Pathname]
      # @param archive [Pathname]
      # @return [PackedArchive] never
      # @raise [NeverPackagedError] always
      sig { override.params(build: Build, install: Pathname, archive: Pathname).returns(PackedArchive) }
      def package(build, install, archive)
        _ = [install, archive]
        raise NeverPackagedError, "target '#{build.target}' declares `packager: none` — it is built, never packaged"
      end

      # The declaration as `dev help` renders it.
      sig { returns(String) }
      def to_s
        "none"
      end

      sig { params(other: Object).returns(T::Boolean) }
      def ==(other)
        other.is_a?(NonePackager)
      end

      sig { params(other: Object).returns(T::Boolean) }
      def eql?(other)
        self == other
      end

      sig { returns(Integer) }
      def hash
        [NonePackager].hash
      end
    end
  end
end
