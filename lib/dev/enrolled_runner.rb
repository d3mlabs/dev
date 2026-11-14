# typed: strict
# frozen_string_literal: true

require_relative "value_equality"

module Dev
  # A repo's enrolled runner: what bare `dev runner register`
  # makes, and what the lifecycle verbs' remote dispatch targets from a
  # machine that is not a build's environment. Both halves of its identity
  # derive from the one repo, "owner/repo" as GitHub spells it — the
  # **scope** is the repo itself (a repo-scoped enrollment is that repo's
  # object, and the workflows targeting it live there), the **label** is
  # the repo's name, lowercased: GitHub matches labels case-insensitively
  # but stores them as created, and one spelling keeps register's amend
  # compare exact; dashes stay, since labels allow them and the name is
  # the identity. dev.yml `name:` is the package identity, may differ,
  # and never enters here.
  #
  # Declared nowhere (enrollment state is inspected, never
  # recorded). Register derives it to enroll; EnrolledRunnerLookup
  # derives it to ask GitHub whether one is available; the two agree
  # because this is the one derivation.
  class EnrolledRunner < T::Struct
    extend T::Sig
    include Dev::ValueEquality::Derived

    # The repo is not "owner/repo". Refused here rather than enrolled or
    # looked up under a scope dev would read as an org (a bare name is
    # the org shape to every runner endpoint).
    class MalformedRepoError < ArgumentError; end

    # @return [String] "owner/repo" — the enrollment's scope, as GitHub spells it
    const :scope, String

    # @return [String] the custom label the enrollment carries: the repo's name, lowercased
    const :label, String

    class << self
      extend T::Sig

      # The enrolled runner of a repo.
      #
      # @param repo [String] "owner/repo", as `gh repo view` spells it
      # @return [EnrolledRunner]
      # @raise [MalformedRepoError] when the repo is not an owner and a name
      sig { params(repo: String).returns(EnrolledRunner) }
      def for(repo)
        owner, name, extra = repo.split("/", 3)
        if owner.nil? || owner.empty? || name.nil? || name.empty? || extra
          raise MalformedRepoError, "#{repo.inspect} is not an owner/repo (e.g. d3mlabs/cellbound-3d)"
        end

        new(scope: repo, label: name.downcase)
      end
    end

    # @return [Array] the members that constitute identity
    sig { override.returns(T::Array[T.anything]) }
    def equality_members
      [scope, label]
    end
  end
end
