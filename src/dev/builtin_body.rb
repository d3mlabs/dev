# typed: strict
# frozen_string_literal: true

require_relative "execution_context"

module Dev
  # The behavior contract of a builtin dev command: a Ruby body plus the
  # trait readings BuiltinCommand delegates to. Implementations live under
  # src/dev/builtins/ (one class per builtin, collaborators
  # constructor-injected); the composition root wraps each body in
  # BuiltinCommand, the sealed hierarchy's final leaf.
  #
  # This would be an `interface!`, but Sorbet interfaces forbid default
  # implementations and the traits deliberately default (most builtins are
  # visible, guarded, and non-stamping) — hence `abstract!` with
  # overridable trait defaults mirroring Command's.
  module BuiltinBody
    extend T::Sig
    extend T::Helpers
    abstract!

    sig { abstract.returns(String) }
    def desc; end

    # Whether this builtin is callable but omitted from `dev`/`dev --help`
    # usage (see Command#hidden?). Visible by default.
    sig { overridable.returns(T::Boolean) }
    def hidden? = false

    # Whether the staleness guard skips this builtin (see
    # Command#staleness_exempt?). Guarded by default.
    sig { overridable.returns(T::Boolean) }
    def staleness_exempt? = false

    # Whether a fully-successful run records the installed stamp (see
    # Command#stamps?). Non-stamping by default.
    sig { overridable.returns(T::Boolean) }
    def stamps? = false

    sig { abstract.params(args: T::Array[String], context: ExecutionContext).void }
    def call(args:, context:); end
  end
end
