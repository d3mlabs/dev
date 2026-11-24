# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "acceptance"
require_relative "build"
require_relative "packager"
require_relative "packed_archive"
require_relative "../value_equality"

module Dev
  module Lifecycle
    # The built-in `none` packager: the target is built and never shipped,
    # so it is invisible to `package`, `release` and `deploy`. Asking it to
    # package anyway is a programming error, reported as one.
    class NonePackager
      extend T::Sig
      include Packager
      include Dev::ValueEquality::Derived

      # `package` reached a target that declares `packager: none`.
      class NeverPackagedError < RuntimeError; end

      # @param build [Build]
      # @param stage [Pathname]
      # @param archive [Pathname]
      # @param acceptance [Acceptance]
      # @return [PackedArchive] never
      # @raise [NeverPackagedError] always
      sig { override.params(build: Build, stage: Pathname, archive: Pathname, acceptance: Acceptance).returns(PackedArchive) }
      def package(build, stage, archive, acceptance: Acceptance.unconditional)
        _ = [stage, archive, acceptance]
        raise NeverPackagedError, "target '#{build.target}' declares `packager: none` — it is built, never packaged"
      end

      # The declaration as `dev help` renders it.
      sig { returns(String) }
      def to_s
        "none"
      end

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        []
      end
    end
  end
end
