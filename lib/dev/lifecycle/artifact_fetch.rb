# typed: strict
# frozen_string_literal: true

require "pathname"
require_relative "../value_equality"

module Dev
  module Lifecycle
    # What `--fetch` asks of a remote dispatch: bring the artifact the
    # remote `package` stamped back into this machine's store. The artifact
    # crosses as a workflow artifact named after the build and lands in the
    # store directory the build has here, so `dev deploy` on this machine
    # reads it as if it had been packaged here. By default nothing comes
    # back.
    class ArtifactFetch < T::Struct
      extend T::Sig
      include Dev::ValueEquality::Derived

      # @return [String] the workflow artifact's name: the build's
      const :name, String
      # @return [Pathname] the store directory the files land in
      const :into, Pathname

      # @return [Array] the members that constitute identity
      sig { override.returns(T::Array[T.anything]) }
      def equality_members
        [name, into]
      end
    end
  end
end
