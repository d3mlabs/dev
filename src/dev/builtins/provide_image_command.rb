# typed: strict
# frozen_string_literal: true

require "dev/builtin_body"
require "dev/credentials"
require "build_container"

module Dev
  module Builtins
    # The CLI verb for CI image provisioning: resolve the content-addressed
    # image (local → pull → build, see BuildContainer.ensure_image!) and
    # print its tag to stdout (resolution progress goes to stderr, so the
    # tag is capturable). Publishing to the shared registry stays gated on
    # DEV_PUBLISH_IMAGE, same as containerized commands. Exists only when a
    # build container is configured (the composition root gates it).
    class ProvideImageCommand
      extend T::Sig
      include BuiltinBody

      sig { override.returns(String) }
      def desc = "Resolve the build container image (local/pull/build) and print its tag"

      # Hidden: workflow plumbing, not a developer intent command.
      sig { override.returns(T::Boolean) }
      def hidden? = true

      # provide-image consumes the committed lockfiles directly (they are
      # inputs to the image's content hash) and runs on fresh CI checkouts
      # where no installed stamp exists yet.
      sig { override.returns(T::Boolean) }
      def staleness_exempt? = true

      sig { override.params(args: T::Array[String], context: ExecutionContext).void }
      def call(args:, context:)
        cfg = T.must(context.build_container)
        image_tag = BuildContainer.ensure_image!(
          cfg,
          project_root: context.project_root,
          push: false,
          publish: ENV["DEV_PUBLISH_IMAGE"] == "1",
          build_args_provider: -> { Dev::Credentials.resolve_build_args(cfg.build_args) },
          secrets_provider: -> { Dev::Credentials.resolve_build_args(cfg.build_secrets) },
        )
        puts image_tag
      end
    end
  end
end
