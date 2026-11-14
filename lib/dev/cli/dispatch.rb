# typed: strict
# frozen_string_literal: true

require "dev/lifecycle"
require "dev/ui"
require_relative "transport"
require_relative "../value_equality"

module Dev
  module Cli
    # Where a lifecycle verb's seam executes: a sealed
    # two-level type — `Native`, the seam runs here; `Remote(transport)`,
    # the verb is re-invoked on a host that has the build's environment
    # and the artifact stays with that host. The one decision site is
    # DispatchResolver; the verbs never match on this themselves — they
    # hand a dispatch the invocation a remote host would run in their
    # place, and how to resolve the env their seam would run against here,
    # and act on what it leaves them to do, the Outcome: `Run(env)`, run the
    # seam here with that env; `Done`, the dispatch carried the verb out
    # elsewhere and nothing of the stage is left for this process. The env
    # is resolved only for a seam that runs here: what it reads — the
    # tree's state, the store's artifacts — is this machine's, and a verb
    # that leaves reads the host's instead (`deploy` selects from the
    # host's store).
    #
    # Neither a *build host* (the (machine, platform) pair owning a
    # data root — the result of dispatching) nor Placement (image or host on
    # this machine — the host rule's input, what the resolver reads).
    #
    # Sealed, like Placement: the executor cases over the outcome and the
    # resolver constructs the dispatch, each with a T.absurd proof. `Env` is
    # the verb's own type — what its `before` resolved from the flags and
    # its seam reads (LifecycleCommand) — so the outcome is generic over it
    # and a dispatch is a generic method: one Native, one Remote serve every
    # verb.
    module Dispatch
      extend T::Sig
      extend T::Helpers
      # Every includer is an Object; this tells Sorbet the Object protocol
      # exists on a value typed as the interface.
      include Kernel
      abstract!
      sealed!

      # Carry the verb's stage to where it executes.
      #
      # @param invocation [Lifecycle::VerbInvocation] the verb as a remote
      #   host would run it in this process's place
      # @yieldreturn [Env] what the verb's seam runs against here; called
      #   only when the seam does
      # @return [Outcome] Run(env) to run the seam in this process; Done when
      #   the dispatch ran the verb elsewhere
      sig do
        abstract.type_parameters(:Env)
          .params(invocation: Lifecycle::VerbInvocation, blk: T.proc.returns(T.type_parameter(:Env)))
          .returns(Outcome[T.type_parameter(:Env)])
      end
      def dispatch(invocation, &blk); end

      # What a dispatch leaves the stage to do in this process.
      module Outcome
        extend T::Sig
        extend T::Helpers
        extend T::Generic
        include Kernel
        abstract!
        sealed!

        # The verb's env type (see Dispatch).
        Env = type_member

        # Run the seam here, with the env the dispatch hands back — the
        # native case, where it is the env `before` resolved, unchanged.
        class Run
          extend T::Sig
          extend T::Helpers
          include Dev::ValueEquality::Derived
          extend T::Generic
          include Outcome
          final!

          Env = type_member

          # @return [Env] what the seam runs against
          sig(:final) { returns(Env) }
          attr_reader :env

          # @param env [Env]
          sig(:final) { params(env: Env).void }
          def initialize(env)
            @env = env
          end

          # @return [Array] the members that constitute identity
          sig(:final) { override.returns(T::Array[T.anything]) }
          def equality_members
            [@env]
          end
        end

        # Nothing is left for this process: the dispatch ran the verb — seam
        # and after-step alike — on the host it resolved to.
        class Done
          extend T::Sig
          extend T::Helpers
          include Dev::ValueEquality::Derived
          extend T::Generic
          include Outcome
          final!

          Env = type_member

          # @return [Array] the members that constitute identity
          sig(:final) { override.returns(T::Array[T.anything]) }
          def equality_members
            []
          end
        end
      end

      # The seam runs here: this machine is the build's environment (the
      # host, or a host provisioned from the image — the box, a hosted
      # runner, the container from inside). Dispatching changes nothing: the
      # env the verb resolves comes back as Run(env) for the seam.
      class Native
        extend T::Sig
        extend T::Helpers
        include Dispatch
        final!
        include Dev::ValueEquality::Derived

        sig(:final) do
          override.type_parameters(:Env)
            .params(invocation: Lifecycle::VerbInvocation, blk: T.proc.returns(T.type_parameter(:Env)))
            .returns(Outcome[T.type_parameter(:Env)])
        end
        def dispatch(invocation, &blk)
          _ = invocation
          Outcome::Run[T.type_parameter(:Env)].new(yield)
        end

        # @return [Array] the members that constitute identity
        sig(:final) { override.returns(T::Array[T.anything]) }
        def equality_members
          []
        end
      end

      # The verb runs on a host that has the build's environment, reached
      # through a Transport: the working tree crosses as
      # a snapshot branch for the dispatch's duration (Lifecycle::SnapshotSync
      # — refused first if a project workflow would run on the push), one
      # dim line says where the verb went and from which commit, the
      # transport runs the invocation there and returns with its verdict,
      # and the artifact stays in that host's data root unless the
      # invocation asked for it back. Nothing of the stage is left here:
      # the outcome is Done, and the env is never resolved — the seam it
      # would feed runs on the host, over the host's tree and store.
      class Remote
        extend T::Sig
        extend T::Helpers
        include Dispatch
        final!

        sig(:final) { returns(Transport) }
        attr_reader :transport

        # @param transport [Transport] how the host is reached
        # @param sync [Lifecycle::SnapshotSync] the sync step over the project's checkout
        # @param ui [Ui] where the crossing line prints
        sig(:final) { params(transport: Transport, sync: Lifecycle::SnapshotSync, ui: Ui).void }
        def initialize(transport:, sync:, ui:)
          @transport = transport
          @sync = sync
          @ui = ui
        end

        # @raise [Lifecycle::WorkflowTriggers::UnfilteredPushTriggerError] and
        #   the sync step's other refusals, before anything is pushed
        # @raise [Transport::ActionsRunner::RemoteVerbFailedError],
        #   [Transport::LocalContainer::ContainerVerbFailedError] and the
        #   transport's other errors, after the run
        sig(:final) do
          override.type_parameters(:Env)
            .params(invocation: Lifecycle::VerbInvocation, blk: T.proc.returns(T.type_parameter(:Env)))
            .returns(Outcome[T.type_parameter(:Env)])
        end
        def dispatch(invocation, &blk)
          _ = blk
          @transport.assert_ready!
          @sync.sync(runner: @transport.runner) do |snapshot|
            @ui.print_remote_crossing(destination: @transport.destination, snapshot: snapshot.short_sha)
            @transport.run(invocation, snapshot:)
          end
          Outcome::Done[T.type_parameter(:Env)].new
        end
      end
    end
  end
end
