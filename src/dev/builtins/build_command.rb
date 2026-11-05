# typed: strict
# frozen_string_literal: true

require "pathname"
require "stringio"
require "dev/build_dispatcher"
require "dev/build_listing"
require "dev/build_selector"
require "dev/command"
require "dev/dispatch"
require "dev/lifecycle"

module Dev
  module Builtins
    # `dev build [BUILD] [--target T] [--platform P] [--config C]`: make one
    # build's install through its target's builder (dev#192, K1, K4). The
    # verb exists iff the project declares `targets:`, and acts on one
    # build: the positional (a name or a pattern, an omitted axis taking
    # the target's first), its long form in flags, or — bare — the first
    # declared target's default build, which is why a project lists its
    # fast-loop target first.
    #
    # The stage: `before` consumes the argv into the build (BuildSelector),
    # resolves where it runs (BuildDispatcher — the target's `environment:`
    # under the host rule) and hands the env to that dispatch; the seam is
    # the builder, writing the install into the store's directory for the
    # build (`DEV_INSTALL`); `after` reports it. A target with no `build:`
    # has nothing to compile — the verb says so and does nothing, so
    # `package` can run alone over it.
    class BuildCommand < LifecycleCommand
      extend T::Sig

      # What `before` resolves and the seam and `after` read.
      class BuildEnv < T::Struct
        const :build, Lifecycle::Build
        const :install, Pathname
        # nil: the target declares nothing to compile
        const :builder, T.nilable(Lifecycle::Builder)
      end

      Env = type_member { { fixed: BuildEnv } }

      # @param selector [BuildSelector] argv → the build
      # @param dispatcher [BuildDispatcher] the build → where it runs
      # @param listing [BuildListing] what the usage and completion list
      # @param ports [Lifecycle::Ports] the targets' builders
      # @param store [Lifecycle::Store] where the install goes
      # @param out [IO, StringIO]
      sig do
        params(
          selector: BuildSelector,
          dispatcher: BuildDispatcher,
          listing: BuildListing,
          ports: Lifecycle::Ports,
          store: Lifecycle::Store,
          out: T.any(IO, StringIO),
        ).void
      end
      def initialize(selector:, dispatcher:, listing:, ports:, store:, out: $stdout)
        super()
        @selector = selector
        @dispatcher = dispatcher
        @listing = listing
        @ports = ports
        @store = store
        @out = out
      end

      sig { override.returns(String) }
      def desc
        "Build a target's install (build [BUILD] | --target T [--platform P] [--config C])\n" \
          "BUILD is `<target>[-<platform>[-<config>]]`; an omitted axis takes the target's first. " \
          "Bare `dev build` is `#{default_build}`."
      end

      sig { override.returns(T::Array[Cli::Flag]) }
      def flags = BuildSelector::FLAGS

      sig { override.returns(T.nilable(Listing)) }
      def listing = @listing.listing

      sig { override.params(words: T::Array[String]).returns(T::Array[String]) }
      def completions(words)
        _ = words
        @listing.completions
      end

      sig { override.params(args: Cli::ParsedArgs, context: ExecutionContext).returns(Dispatch::Outcome[BuildEnv]) }
      def before(args:, context:)
        _ = context
        build = @selector.select(args)
        env = BuildEnv.new(build:, install: @store.install_dir(build), builder: @ports.builder_for(build.target))
        @dispatcher.dispatch_for(build).dispatch(env)
      end

      sig { override.params(env: BuildEnv, context: ExecutionContext).void }
      def seam(env, context:)
        _ = context
        env.builder&.build(env.build, env.install)
      end

      sig { override.params(env: BuildEnv, context: ExecutionContext).void }
      def after(env, context:)
        _ = context
        if env.builder
          @out.puts "built #{env.build} → #{env.install}"
        else
          @out.puts "#{env.build}: nothing to build (target '#{env.build.target}' declares no `build:`)"
        end
      end

      private

      # @return [String] what bare `dev build` means
      sig { returns(String) }
      def default_build = T.must(@selector.targets.first).default_build.name
    end
  end
end
