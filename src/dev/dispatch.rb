# typed: strict
# frozen_string_literal: true

module Dev
  # Where a lifecycle verb's seam executes (dev#192, K8): a sealed
  # two-level type — `Native`, the seam runs here; `Remote(transport)`
  # (dev#420), the verb is re-invoked on a host that has the build's
  # environment and the artifact stays with that host. The one decision
  # site is DispatchResolver; the verbs never match on this themselves —
  # they hand a dispatch the env their seam would run against and act on
  # what it leaves them to do, the Outcome: `Run(env)`, run the seam here
  # with that env; `Done`, the dispatch carried the verb out elsewhere and
  # nothing of the stage is left for this process.
  #
  # Neither ADR-0008's *build host* (the (machine, platform) pair owning a
  # data root — the result of dispatching) nor Placement (image or host on
  # this machine — the host rule's input, what the resolver reads).
  #
  # Sealed, like Placement: the executor cases over the outcome and the
  # resolver constructs the dispatch, each with a T.absurd proof. `Env` is
  # the verb's own type — what its `before` resolved from the flags and
  # its seam reads (LifecycleCommand) — so the outcome is generic over it
  # and a dispatch is a generic method: one Native serves every verb.
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
    # @param env [Env] what the verb's seam would run against here
    # @return [Outcome] Run(env) to run the seam in this process; Done when
    #   the dispatch ran the verb elsewhere
    sig do
      abstract.type_parameters(:Env).params(env: T.type_parameter(:Env)).returns(Outcome[T.type_parameter(:Env)])
    end
    def dispatch(env); end

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

        # Compared from the other side: `other` narrows to Run over an
        # erased Env, whose `==` is the env's own; `@env`'s type member
        # is unbounded and offers none.
        sig(:final) { params(other: Object).returns(T::Boolean) }
        def ==(other) = other.is_a?(Run) && other.env == @env

        sig(:final) { params(other: Object).returns(T::Boolean) }
        def eql?(other) = self == other

        sig(:final) { returns(Integer) }
        def hash = [Run, @env].hash
      end

      # Nothing is left for this process: the dispatch ran the verb — seam
      # and after-step alike — on the host it resolved to (dev#420).
      class Done
        extend T::Sig
        extend T::Helpers
        extend T::Generic
        include Outcome
        final!

        Env = type_member

        sig(:final) { params(other: Object).returns(T::Boolean) }
        def ==(other) = other.is_a?(Done)

        sig(:final) { params(other: Object).returns(T::Boolean) }
        def eql?(other) = self == other

        sig(:final) { returns(Integer) }
        def hash = [Done].hash
      end
    end

    # The seam runs here: this machine is the build's environment (the
    # host, or a host provisioned from the image — the box, a hosted
    # runner, the container from inside). Dispatching changes nothing: the
    # env comes back as Run(env) for the seam.
    class Native
      extend T::Sig
      extend T::Helpers
      include Dispatch
      final!

      sig(:final) do
        override.type_parameters(:Env).params(env: T.type_parameter(:Env)).returns(Outcome[T.type_parameter(:Env)])
      end
      def dispatch(env)
        Outcome::Run[T.type_parameter(:Env)].new(env)
      end

      sig(:final) { params(other: Object).returns(T::Boolean) }
      def ==(other) = other.is_a?(Native)

      sig(:final) { params(other: Object).returns(T::Boolean) }
      def eql?(other) = self == other

      sig(:final) { returns(Integer) }
      def hash = [Native].hash
    end
  end
end
