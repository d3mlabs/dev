# typed: strict
# frozen_string_literal: true

require_relative "archive"
require_relative "../value_equality"

module Dev
  module Lifecycle
    # What a target declares for its Packager port: a `package:` script
    # line, or one of the built-ins by name: `archive` (the default; `{
    # archive: { format: tar, split: 2GiB } }` for its tar form), `as-is`,
    # `none`.
    #
    # A declaration, not the port: Ports turns it into a Packager for this
    # checkout. Sealed, so the composition matches exhaustively.
    module PackagerSpec
      extend T::Sig
      extend T::Helpers
      include Kernel
      abstract!
      sealed!

      # The names a `packager:` line may carry.
      BUILTIN_NAMES = T.let(["archive", "as-is", "none"].freeze, T::Array[String])

      # The declaration as `dev help` renders it.
      sig { abstract.returns(String) }
      def to_s; end

      # `package: <command>` — a shell command run at the project root with
      # the build, the install and the archive path in its env (ScriptEnv).
      class Script < T::Struct
        extend T::Sig
        include PackagerSpec
        include Dev::ValueEquality::Derived

        const :command, String

        sig { override.returns(String) }
        def to_s
          command
        end

        # @return [Array] the members that constitute identity
        sig { override.returns(T::Array[T.anything]) }
        def equality_members
          [command]
        end
      end

      # `packager: archive` (or omitted) in one of dev's own forms
      # (Lifecycle::Archive::Form): the zip, or the tar — whole or split.
      class Archive < T::Struct
        extend T::Sig
        include PackagerSpec
        include Dev::ValueEquality::Derived

        const :form, Lifecycle::Archive::Form, factory: -> { Lifecycle::Archive::Form::Zip.new }

        sig { override.returns(String) }
        def to_s
          "archive#{form}"
        end

        # @return [Array] the members that constitute identity
        sig { override.returns(T::Array[T.anything]) }
        def equality_members
          [form]
        end
      end

      # `packager: as-is` — the install already is the archive.
      class AsIs < T::Struct
        extend T::Sig
        include PackagerSpec
        include Dev::ValueEquality::Derived

        sig { override.returns(String) }
        def to_s
          "as-is"
        end

        # @return [Array] the members that constitute identity
        sig { override.returns(T::Array[T.anything]) }
        def equality_members
          []
        end
      end

      # `packager: none` — built, never shipped.
      class None < T::Struct
        extend T::Sig
        include PackagerSpec
        include Dev::ValueEquality::Derived

        sig { override.returns(String) }
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
end
