# typed: strict
# frozen_string_literal: true

require "etc"
require "json"

module Dev
  # This machine's runner enrollments, inspected — never recorded
  # (plans#26): the actions-runner install dirs under $HOME (suffixless or
  # `-<label>`-suffixed, see DIR_GLOBS) are the only local state, and each
  # configured dir's .runner file (written by config.sh) names the
  # enrollment's scope and runner name. Labels are
  # deliberately NOT here — GitHub is their single home; Dev::RunnerRegistry
  # reads them. Offline by construction, so register and status can find
  # this host's enrollments without the network.
  #
  # On a Linux host the enrollments live under the runner user's home, not
  # the operator's (dev#310); `also_under` widens the scan to it. Each
  # enrollment knows its owner — the user whose dir it is, which is the
  # user its service runs as — so register can tell an enrollment running
  # as the wrong identity.
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

      # Whether svc.sh has installed this enrollment's service: its
      # `.service` marker (the unit name) exists in the dir. The unit is
      # named from scope and runner name, not from the dir — so two dirs
      # enrolled for one scope under one name contend for one unit, and
      # which dir owns it is this fact.
      const :service_installed, T::Boolean

      # The dir as a human types it: `~`-relative when under home, else
      # absolute. What unregister completes and register's remedy prints.
      const :display_dir, String

      # The user whose dir this is — the one its service runs as.
      const :owner, String
    end

    # The dir names a runner install may have under home: the suffixless
    # name a hand-run `config.sh` leaves (GitHub's own instructions) and
    # the `-<label>` suffix register derives. Both are enrollments when
    # configured.
    DIR_GLOBS = T.let(["actions-runner", "actions-runner-*"].freeze, T::Array[String])

    # @param home [String] the home dir to scan (injectable for tests); the
    #   one display dirs are relative to
    # @param homes [Array<String>] every home to scan (home included)
    sig { params(home: String, homes: T::Array[String]).void }
    def initialize(home: Dir.home, homes: [home])
      @home = home
      @homes = homes
    end

    # The same discovery, also scanning another user's home.
    #
    # @param home [String] the other home
    # @return [RunnerDiscovery]
    sig { params(home: String).returns(RunnerDiscovery) }
    def also_under(home)
      RunnerDiscovery.new(home: @home, homes: (@homes + [home]).uniq)
    end

    # Every configured enrollment on this host, in dir order per home.
    # Unconfigured dirs (downloaded but never registered, or garbage) are
    # silently skipped — they are not enrollments.
    #
    # @return [Array<Enrollment>]
    sig { returns(T::Array[Enrollment]) }
    def enrollments
      @homes.flat_map do |home|
        dirs = DIR_GLOBS.flat_map { |pattern| Dir.glob(File.join(home, pattern)) }
        dirs.sort.filter_map { |dir| self.class.read(dir, home: @home) }
      end
    end

    # Every local enrollment serving a scope, in dir order. More than one
    # is the broken state `config.sh --replace` leaves behind (the newest
    # dir holds the registration, an older one the service unit); the
    # callers that can act on plurality — unregister's resolution,
    # register's detection — read this, not for_scope.
    #
    # @param scope [String] "owner/repo" or "owner"
    # @return [Array<Enrollment>]
    sig { params(scope: String).returns(T::Array[Enrollment]) }
    def enrollments_for(scope)
      enrollments.select { |enrollment| enrollment.scope == scope }
    end

    # The one enrollment serving a scope, when exactly one does. The
    # lookup spans every runner dir because dir names drift from labels
    # over a box's life (e.g. an org enrollment living in a repo-named dir
    # from its pre-org history) — matching on the .runner record is what
    # makes re-registration self-healing instead of a duplicate
    # enrollment. nil when none serves the scope and also when several do:
    # plurality is not for this lookup to resolve by picking a winner (the
    # amend path would amend one and leave the other), so callers settle
    # it through enrollments_for first.
    #
    # @param scope [String] "owner/repo" or "owner"
    # @return [Enrollment, nil]
    sig { params(scope: String).returns(T.nilable(Enrollment)) }
    def for_scope(scope)
      matches = enrollments_for(scope)
      matches.length == 1 ? matches.fetch(0) : nil
    end

    class << self
      extend T::Sig

      # Parse a runner dir's .runner record. config.sh writes the file with
      # a UTF-8 BOM, so read with "bom|utf-8" or JSON.parse chokes on the
      # first byte. nil when absent or unreadable — an unconfigured dir.
      #
      # @param dir [String] a runner install dir
      # @param home [String] the home the display dir is relative to
      # @return [Enrollment, nil]
      sig { params(dir: String, home: String).returns(T.nilable(Enrollment)) }
      def read(dir, home: Dir.home)
        raw = File.read(File.join(dir, ".runner"), encoding: "bom|utf-8")
        record = JSON.parse(raw)
        url = record["gitHubUrl"].to_s
        scope = url.sub(%r{\Ahttps://github\.com/}, "").chomp("/")
        name = record["agentName"].to_s
        return nil if scope.empty? || scope == url || name.empty?

        Enrollment.new(
          dir: dir,
          scope: scope,
          name: name,
          service_installed: File.exist?(File.join(dir, ".service")),
          display_dir: display_dir(dir, home),
          owner: owner(dir),
        )
      rescue JSON::ParserError, Errno::ENOENT
        nil
      end

      # The dir's owner by name; the uid when it has no passwd entry.
      #
      # @param dir [String]
      # @return [String]
      sig { params(dir: String).returns(String) }
      def owner(dir)
        uid = File.stat(dir).uid
        Etc.getpwuid(uid)&.name || uid.to_s
      end

      private

      # `~/<rest>` for a dir under home, the dir itself otherwise.
      #
      # @param dir [String]
      # @param home [String]
      # @return [String]
      sig { params(dir: String, home: String).returns(String) }
      def display_dir(dir, home)
        prefix = "#{home.chomp("/")}/"
        dir.start_with?(prefix) ? "~/#{dir.delete_prefix(prefix)}" : dir
      end
    end
  end
end
