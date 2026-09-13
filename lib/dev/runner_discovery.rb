# typed: strict
# frozen_string_literal: true

require "json"

module Dev
  # This machine's runner enrollments, inspected — never recorded
  # (plans#26): the actions-runner install dirs under $HOME are the only
  # local state, and each configured dir's .runner file (written by
  # config.sh) names the enrollment's scope and runner name. Labels are
  # deliberately NOT here — GitHub is their single home; Dev::RunnerRegistry
  # reads them. Offline by construction, so register and status can find
  # this host's enrollments without the network.
  class RunnerDiscovery
    extend T::Sig

    # One local enrollment: where it lives and what its .runner records.
    class Enrollment < T::Struct
      # Absolute install dir. Its name is history (register defaults it from
      # the first label at enrollment time) — never identity; the .runner
      # record inside is what binds it to a scope.
      const :dir, String

      # "owner/repo" (repo scope) or "owner" (org scope).
      const :scope, String

      # The runner's GitHub-side name (.runner agentName).
      const :name, String
    end

    # @param home [String] the home dir to scan (injectable for tests)
    sig { params(home: String).void }
    def initialize(home: Dir.home)
      @home = home
    end

    # Every configured enrollment on this host, in dir order. Unconfigured
    # dirs (downloaded but never registered, or garbage) are silently
    # skipped — they are not enrollments.
    #
    # @return [Array<Enrollment>]
    sig { returns(T::Array[Enrollment]) }
    def enrollments
      Dir.glob(File.join(@home, "actions-runner-*")).sort.filter_map { |dir| self.class.read(dir) }
    end

    # The enrollment serving a scope, when one exists. The lookup spans
    # every runner dir because dir names drift from labels over a box's
    # life (e.g. an org enrollment living in a repo-named dir from its
    # pre-org history) — matching on the .runner record is what makes
    # re-registration self-healing instead of a duplicate enrollment.
    #
    # @param scope [String] "owner/repo" or "owner"
    # @return [Enrollment, nil]
    sig { params(scope: String).returns(T.nilable(Enrollment)) }
    def for_scope(scope)
      enrollments.find { |enrollment| enrollment.scope == scope }
    end

    class << self
      extend T::Sig

      # Parse a runner dir's .runner record. config.sh writes the file with
      # a UTF-8 BOM, so read with "bom|utf-8" or JSON.parse chokes on the
      # first byte. nil when absent or unreadable — an unconfigured dir.
      #
      # @param dir [String] a runner install dir
      # @return [Enrollment, nil]
      sig { params(dir: String).returns(T.nilable(Enrollment)) }
      def read(dir)
        raw = File.read(File.join(dir, ".runner"), encoding: "bom|utf-8")
        record = JSON.parse(raw)
        url = record["gitHubUrl"].to_s
        scope = url.sub(%r{\Ahttps://github\.com/}, "").chomp("/")
        name = record["agentName"].to_s
        return nil if scope.empty? || scope == url || name.empty?

        Enrollment.new(dir: dir, scope: scope, name: name)
      rescue JSON::ParserError, Errno::ENOENT
        nil
      end
    end
  end
end
