# typed: strict
# frozen_string_literal: true

module Dev
  module Deps
    # A name outside FicsitTarget's set, at a boundary (a directory under a
    # plugin's `Content/Paks/`). Beside the enum rather than inside it: a
    # T::Enum body may hold only its own values.
    class UnknownFicsitTargetError < ArgumentError; end

    # SMR's targets — the three things a mod version is built for
    # (`validation.AllowedTargets` in smr-api): the `targetName` of a
    # published version, the `platforms:` keys of a ficsit pin, and the
    # directories a multi-target plugin zip is laid out in (`Windows/`,
    # `WindowsServer/`, `LinuxServer/`). They are Unreal's cooked-platform
    # names, because Alpakit stages each target's plugin under
    # `Content/Paks/<cook platform>/` and names its zip
    # `<ModRef>-<cook platform>.zip` — which is how a per-target archive
    # says what target it is (AlpakitPlugin).
    class FicsitTarget < T::Enum
      extend T::Sig

      enums do
        Windows = new("Windows")
        WindowsServer = new("WindowsServer")
        LinuxServer = new("LinuxServer")
      end

      class << self
        extend T::Sig

        # The target a name spells — the deserialization every boundary
        # goes through.
        #
        # @param name [String]
        # @return [FicsitTarget]
        # @raise [UnknownFicsitTargetError]
        sig { params(name: String).returns(FicsitTarget) }
        def parse(name)
          try_deserialize(name) ||
            raise(UnknownFicsitTargetError, "unknown ficsit target #{name.inspect} (expected #{values.map(&:serialize).join(", ")})")
        end
      end

      # The name, as SMR and Alpakit spell it.
      #
      # @return [String]
      sig { returns(String) }
      def to_s
        serialize
      end
    end
  end
end
