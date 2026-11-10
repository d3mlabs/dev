# typed: strict
# frozen_string_literal: true

require_relative "archive"

module Dev
  module Lifecycle
    # What a target declares for its Packager port (dev#192, K1): a
    # `package:` script line, or one of dev's built-ins by name —
    # `archive` (the default, needing no line; `{ archive: { format: tar,
    # split: 2GiB } }` for its tar form), `as-is`, `none`. The integration
    # form (`packager: rubygem`) lands with dev#433 as a further variant.
    #
    # A declaration, not the port: Ports turns it into a Packager for this
    # checkout (the built-ins are their own ports; a script needs the
    # project root). Sealed, so the composition matches exhaustively.
    module PackagerSpec
      extend T::Sig
      extend T::Helpers
      include Kernel
      abstract!
      sealed!

      # The names a `packager:` line may carry today.
      BUILTIN_NAMES = T.let(["archive", "as-is", "none"].freeze, T::Array[String])

      # The declaration as `dev help` renders it.
      sig { abstract.returns(String) }
      def to_s; end

      # `package: <command>` — a shell command run at the project root with
      # the build, the install and the archive path in its env (ScriptEnv).
      class Script < T::Struct
        extend T::Sig
        include PackagerSpec

        const :command, String

        sig { override.returns(String) }
        def to_s
          command
        end

        sig { params(other: Object).returns(T::Boolean) }
        def ==(other)
          other.is_a?(Script) && command == other.command
        end

        sig { params(other: Object).returns(T::Boolean) }
        def eql?(other)
          self == other
        end

        sig { returns(Integer) }
        def hash
          [Script, command].hash
        end
      end

      # `packager: archive` (or omitted) in one of dev's own forms
      # (Lifecycle::Archive::Form): the zip, or the tar — whole or split.
      class Archive < T::Struct
        extend T::Sig
        include PackagerSpec

        const :form, Lifecycle::Archive::Form, factory: -> { Lifecycle::Archive::Form::Zip.new }

        sig { override.returns(String) }
        def to_s
          "archive#{form}"
        end

        sig { params(other: Object).returns(T::Boolean) }
        def ==(other)
          other.is_a?(Archive) && form == other.form
        end

        sig { params(other: Object).returns(T::Boolean) }
        def eql?(other)
          self == other
        end

        sig { returns(Integer) }
        def hash
          [Archive, form].hash
        end
      end

      # `packager: as-is` — the install already is the archive.
      class AsIs < T::Struct
        extend T::Sig
        include PackagerSpec

        sig { override.returns(String) }
        def to_s
          "as-is"
        end

        sig { params(other: Object).returns(T::Boolean) }
        def ==(other)
          other.is_a?(AsIs)
        end

        sig { params(other: Object).returns(T::Boolean) }
        def eql?(other)
          self == other
        end

        sig { returns(Integer) }
        def hash
          [AsIs].hash
        end
      end

      # `packager: none` — built, never shipped.
      class None < T::Struct
        extend T::Sig
        include PackagerSpec

        sig { override.returns(String) }
        def to_s
          "none"
        end

        sig { params(other: Object).returns(T::Boolean) }
        def ==(other)
          other.is_a?(None)
        end

        sig { params(other: Object).returns(T::Boolean) }
        def eql?(other)
          self == other
        end

        sig { returns(Integer) }
        def hash
          [None].hash
        end
      end
    end
  end
end
