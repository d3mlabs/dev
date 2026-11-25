# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "../data_root"
require_relative "../environment_image"
require_relative "../lifecycle/platform"
require_relative "build_patch_tool"
require_relative "declaration"
require_relative "formula_spec"
require_relative "requirement"
require_relative "scope"
require_relative "scoped_declaration"
require_relative "steam_branch"

module Dev
  module Deps
    # Top-level DSL evaluated inside Dev::Deps.define { ... }.
    #
    # Every declaration verb GroupDSL offers works here too, ungrouped. An
    # ungrouped declaration lands in the default group for the project's
    # own lock and is what the manifest exports when read as a library (an
    # integration's dependencies.rb): top-level lines are the public
    # interface, grouped ones are private. `env` is not offered ungrouped,
    # since env never propagates to a consumer.
    class DSL
      extend T::Sig

      # An `image` block named `host` (EnvironmentImage::HOST): the word is
      # dev.yml's `environment: host`, so an image of that name could never
      # be named as an environment.
      class ReservedImageNameError < StandardError; end

      # Group an ungrouped declaration lands in. Bundler's default (unscoped)
      # group, mirroring a hand-written Gemfile's top section.
      DEFAULT_GROUP = :app

      # The GroupDSL verbs available ungrouped (every declaration verb; env
      # excluded — see the class comment). Registered integration verbs join
      # them dynamically. `apt` is here only to refuse at the top level with
      # the same message it refuses with in a group (see GroupDSL#apt).
      UNGROUPED_VERBS = T.let(
        %i[apt brew cmake custom egs ficsit gem gh luarocks pip steam wwise xcode].freeze,
        T::Array[Symbol],
      )

      # @return [Hash{String => Hash}] declared taps by name
      sig { returns(T::Hash[String, T::Hash[String, T.untyped]]) }
      attr_reader :taps

      # @return [Array<ScopedDeclaration>] all declared dependencies, grouped
      #   and ungrouped, in declaration order
      sig { returns(T::Array[ScopedDeclaration]) }
      attr_reader :declarations

      # @return [Array<ScopedDeclaration>] the ungrouped declarations — what
      #   this manifest exports when read as a library
      sig { returns(T::Array[ScopedDeclaration]) }
      attr_reader :exports

      # @return [String, nil] declared Lua version
      sig { returns(T.nilable(String)) }
      attr_reader :lua_version_value

      # @return [Hash{Symbol => Class, String}] custom integration registrations
      sig { returns(T::Hash[Symbol, T.untyped]) }
      attr_reader :registered_integrations

      # @return [Array<Symbol>] dynamically registered integration method names
      sig { returns(T::Array[Symbol]) }
      attr_reader :registered_methods

      sig { void }
      def initialize
        @taps = T.let({}, T::Hash[String, T::Hash[String, T.untyped]])
        @declarations = T.let([], T::Array[ScopedDeclaration])
        @exports = T.let([], T::Array[ScopedDeclaration])
        @lua_version_value = T.let(nil, T.nilable(String))
        @registered_integrations = T.let({}, T::Hash[Symbol, T.untyped])
        @registered_methods = T.let([], T::Array[Symbol])
      end

      # The tap publishing one immutable `ruby@X.Y.Z` formula per Ruby patch,
      # the universe `ruby` resolves over.
      RUBY_TAP = "d3mlabs/d3mlabs"

      # Declare the project's Ruby: a dependency like any other, minted as a
      # :ruby declaration the Resolver ranges over the tap's `ruby@X.Y.Z`
      # family with rubygems ordering (GemScheme), locked to one exact
      # patch, and installed through brew as a keg-only bottle that dev
      # activates in the project shadowenv. The locked version is also the
      # generated Gemfile's `ruby` directive.
      #
      # `"4.0.5"` pins that patch; `"~4.0"` takes the highest 4.0.x the tap
      # has at `dev deps update` (a patch upgrade is a re-lock); a bare minor
      # `"4.0"` means any patch of it, as `python "3.12"` does.
      #
      # @param version [String, Symbol] a requirement, exact or ranged
      # @return [void]
      # @raise [Requirement::ParseError] if the argument is not a requirement
      sig { params(version: T.any(String, Symbol)).void }
      def ruby(version)
        requirement = ruby_requirement(version.to_s.strip)
        @taps[RUBY_TAP] ||= { "name" => RUBY_TAP, "url" => nil }
        @declarations << ScopedDeclaration.new(
          declaration: Declaration.new(name: "ruby", integration: :ruby, requirement: requirement, source: RUBY_TAP),
          scope: Scope.new(group: DEFAULT_GROUP),
        )
      end

      # Declare the Lua version for LuaRocks integration.
      #
      # @param version [String, Symbol] Lua version (e.g. "5.1")
      # @return [void]
      sig { params(version: T.any(String, Symbol)).void }
      def lua_version(version)
        @lua_version_value = version.to_s.strip
      end

      # Declare the project's Python: a :python declaration ranging over
      # homebrew/core's `python@<minor>` family — the minor is a formula
      # family suffix, `"3.12"` meaning `~3.12` exactly as `brew "llvm",
      # version: "18"` means `~18` — locked and installed through brew
      # like any formula; dev builds the project's venv on the locked keg
      # in the store (one per side of the build container, linked as
      # `.venv` on the host and `.venv-container` inside), and pip deps
      # (declared with `pip` inside a group) install into that venv.
      #
      # @param version [String, Symbol] Python minor version (e.g. "3.12")
      # @return [void]
      # @raise [FormulaSpec::InvalidSpecError] if the minor is not dotted digits
      sig { params(version: T.any(String, Symbol)).void }
      def python(version)
        spec = FormulaSpec.parse("python@#{version.to_s.strip}")
        @declarations << ScopedDeclaration.new(
          declaration: Declaration.new(name: spec.name, integration: :python, requirement: spec.requirement),
          scope: Scope.new(group: DEFAULT_GROUP),
        )
      end

      # Declare a Homebrew tap.
      #
      # @param name [String, Symbol] tap identifier (e.g. "d3mlabs/d3mlabs")
      # @param url [String, nil] tap URL; file:// means a local tap
      # @return [void]
      sig { params(name: T.any(String, Symbol), url: T.untyped).void }
      def tap(name, url: nil)
        name_str = name.to_s
        @taps[name_str] = {
          "name" => name_str,
          "url"  => url && url.to_s,
        }
      end

      # Register a custom integration: maps the name to an Integration class
      # and creates a DSL method so it can be used inside group blocks.
      #
      # @param name [Symbol, String] integration identifier (e.g. :wow_curseforge)
      # @param klass [Class, String] Integration subclass or its name
      # @return [void]
      sig { params(name: T.any(Symbol, String), klass: T.untyped).void }
      def register(name, klass)
        sym = name.to_sym
        @registered_integrations[sym] = klass
        @registered_methods << sym
      end

      # Declare a dependency group, optionally pinned to a platform and/or host OS.
      #
      # @param name [String, Symbol] group name (e.g. :app, :test, :integration)
      # @param platform [String, nil] platform the group's deps target (e.g. "LinuxServer").
      #   Stamped onto every declaration in the group so the resolver can union platforms
      #   across groups for multi-arch integrations. nil lets each integration pick its default.
      # @param host [Symbol, nil] host OS the group's deps install on (:darwin / :linux).
      #   Sugar that stamps every member declaration, exactly as platform: does; install
      #   filters against the detected host OS (the lockfile stays universal — all hosts'
      #   deps are resolved and locked, filtering happens at install, never at resolve).
      # @return [void]
      sig do
        params(
          name: T.any(String, Symbol),
          platform: T.nilable(String),
          host: T.nilable(Symbol),
          block: T.nilable(T.proc.bind(GroupDSL).void),
        ).void
      end
      def group(name, platform: nil, host: nil, &block)
        group_name = name.to_s
        group_dsl = GroupDSL.new(group: group_name.to_sym, platform:, host:, registered_methods: @registered_methods)
        group_dsl.instance_eval(&block) if block
        @declarations.concat(group_dsl.declarations)
      end

      # Declare an environment image: the floor it derives from (a
      # dependency, resolved to a digest at `dev deps update`) and, in the
      # block, the project's OS layer as `apt` lines. dev builds the image
      # from the lock and publishes it; a host runs inside it unless it was
      # provisioned from it.
      #
      # Top level only, and never an export: the environment is the
      # project's, not a group's. Several blocks declare several images;
      # commands name them.
      #
      # @param name [String, Symbol] the image's name in the registry
      # @param from [String] the floor, `<registry>/<repository>:<tag>`
      # @param registry [String, nil] where the image publishes; defaults to
      #   the floor's registry prefix — beside what it derives from
      # @return [void]
      sig do
        params(
          name: T.any(String, Symbol),
          from: String,
          registry: T.nilable(String),
          block: T.nilable(T.proc.bind(ImageDSL).void),
        ).void
      end
      def image(name, from:, registry: nil, &block)
        name_str = name.to_s
        raise GroupDSL::EmptyNameError, "image name cannot be empty" if name_str.empty?
        if name_str == EnvironmentImage::HOST
          raise ReservedImageNameError,
            "`#{EnvironmentImage::HOST}` cannot name an image: it is dev.yml's `environment: #{EnvironmentImage::HOST}`, " \
              "the command placement that is no image"
        end

        image_dsl = ImageDSL.new
        image_dsl.instance_eval(&block) if block
        @declarations << ScopedDeclaration.new(
          declaration: Declaration.new(name: name_str, integration: :image, source: from),
          scope: Scope.new(group: DEFAULT_GROUP),
          materialization: {
            "platform" => image_dsl.platform_value,
            "apt" => image_dsl.packages,
          }.merge(image_dsl.capability).merge(
            "registry" => registry || ImageDSL.registry_of(from),
          ).merge(image_dsl.container_shape),
        )
      end

      # The ungrouped declaration verbs, defined rather than caught by
      # method_missing: `gem` is also Kernel#gem (RubyGems), which an implicit
      # receiver would reach first.
      UNGROUPED_VERBS.each do |verb|
        # T.unsafe: inside define_method the receiver is the instance, which
        # Sorbet types as the class here.
        define_method(verb) { |*args, **kwargs, &block| T.unsafe(self).send(:ungrouped, verb, args, kwargs, block) }
      end

      private

      # Run a GroupDSL verb in the default group and record the result as
      # both a declaration and an export. A fresh GroupDSL per call keeps
      # declaration order exactly as written across grouped and ungrouped
      # lines — the resolver's first-wins scoping reads it.
      #
      # @param verb [Symbol] the GroupDSL verb
      # @param args [Array] positional arguments, as the verb was called
      # @param kwargs [Hash{Symbol => Object}] keyword arguments, as the verb was called
      # @param block [Proc, nil] the verb's block, if any
      # @return [void]
      sig { params(verb: Symbol, args: T::Array[T.untyped], kwargs: T::Hash[Symbol, T.untyped], block: T.nilable(Proc)).void }
      def ungrouped(verb, args, kwargs, block)
        group_dsl = GroupDSL.new(group: DEFAULT_GROUP, registered_methods: @registered_methods)
        T.unsafe(group_dsl).public_send(verb, *args, **kwargs, &block)
        @declarations.concat(group_dsl.declarations)
        @exports.concat(group_dsl.declarations)
      end

      # The requirement a `ruby` argument means: a bare minor ("4.0") is any
      # patch of it (`~4.0`); anything else — an exact patch, an explicit
      # requirement — is taken as written.
      #
      # @param version [String] the argument, stripped
      # @return [Requirement]
      # @raise [Requirement::ParseError] if the argument is not a requirement
      sig { params(version: String).returns(Requirement) }
      def ruby_requirement(version)
        Requirement.parse(version.match?(/\A\d+\.\d+\z/) ? "#{Requirement::TILDE}#{version}" : version)
      end
    end

    # DSL inside an `image` block: what the environment image is made of
    # beyond its floor, what it can build, and how its container is shaped.
    # `platform` and `apt` make the image, since exactly that much can be
    # locked and compared. `target_platforms` states the build platforms
    # the image's toolchain emits, locked with the image and checked
    # against each target's `environment:` at load. `persist`, `volume` and
    # `run_env` shape the container the image runs as. None of the last
    # four enters the image or its digest.
    class ImageDSL
      extend T::Sig

      # A store verb (gh, brew, gem, …) inside an image block. Store trees
      # are not baked into images; refused rather than ignored so the author
      # knows the line did nothing.
      class StoreVerbInImageError < StandardError; end

      # An `apt` argument that is not a Debian package name — including
      # `name=version`: a distro package cannot be pinned, the image is the
      # pin.
      class InvalidPackageNameError < StandardError; end

      # A `target_platforms` argument outside dev's platform ids.
      class UnknownTargetPlatformError < StandardError; end

      # Debian policy §5.6.1: lower-case alphanumerics, `+ - .`, at least
      # two characters, starting alphanumeric.
      PACKAGE_NAME = /\A[a-z0-9][a-z0-9+.-]+\z/

      # The verbs that declare store content, each refused here by name.
      STORE_VERBS = T.let(
        %i[brew cmake custom ficsit gem gh luarocks pip steam wwise xcode].freeze,
        T::Array[Symbol],
      )

      # @return [String, nil] the docker platform the block named
      sig { returns(T.nilable(String)) }
      attr_reader :platform_value

      # @return [Array<String>] the apt packages, sorted and unique
      sig { returns(T::Array[String]) }
      def packages
        @packages.sort.uniq
      end

      # What the image can build, as lock metadata: `target_platforms`, the
      # ids in the platform set's own order and unique, only when the block
      # declared any. An image that declares nothing produces no build
      # platform, and no cross-platform build may name it.
      #
      # @return [Hash{String => Array<String>}] `target_platforms`, only when declared
      sig { returns(T::Hash[String, T::Array[String]]) }
      def capability
        return {} if @target_platforms.empty?

        declared = Lifecycle::Platform.values.select { |platform| @target_platforms.include?(platform) }
        { "target_platforms" => declared.map(&:serialize) }
      end

      # The container's shape as lock metadata: only what the block said —
      # a block that said nothing adds nothing, so a lock without these
      # keys reads as it did before they existed.
      #
      # @return [Hash{String => Object}] `persist`, `volumes`, `run_env`, each only when declared
      sig { returns(T::Hash[String, T.untyped]) }
      def container_shape
        shape = {}
        shape["persist"] = true if @persist
        shape["volumes"] = @volumes.dup unless @volumes.empty?
        shape["run_env"] = @run_env.dup unless @run_env.empty?
        shape
      end

      sig { void }
      def initialize
        @platform_value = T.let(nil, T.nilable(String))
        @packages = T.let([], T::Array[String])
        @target_platforms = T.let([], T::Array[Lifecycle::Platform])
        @persist = T.let(false, T::Boolean)
        @volumes = T.let([], T::Array[String])
        @run_env = T.let({}, T::Hash[String, String])
      end

      # Name the image's platform (`os/arch[/variant]`). Required only when
      # the floor is multi-arch; inferred from the floor otherwise.
      #
      # @param docker_platform [String]
      # @return [void]
      sig { params(docker_platform: String).void }
      def platform(docker_platform)
        @platform_value = docker_platform
      end

      # Add distro packages to the image's OS layer.
      #
      # @param names [Array<String>] Debian package names, no versions
      # @return [void]
      # @raise [InvalidPackageNameError]
      sig { params(names: String).void }
      def apt(*names)
        names.each do |name|
          unless PACKAGE_NAME.match?(name)
            raise InvalidPackageNameError,
              "#{name.inspect} is not a package name — `apt` takes Debian package names, never versions: " \
                "a distro package cannot be pinned, the image is the pin"
          end
        end
        @packages.concat(names)
      end

      # Declare the build platforms this image's toolchain emits, the
      # capability a target's `environment:` is checked against for each of
      # its builds. dev's platform ids, as symbols (`target_platforms :win64,
      # :linux64`). Repeatable.
      #
      # @param ids [Array<Symbol, String>] platform ids
      # @return [void]
      # @raise [UnknownTargetPlatformError]
      sig { params(ids: T.any(Symbol, String)).void }
      def target_platforms(*ids)
        @target_platforms.concat(ids.map { |id| parse_target_platform(id.to_s) })
      end

      # Run this image's commands in one long-lived container (a `docker
      # exec` each) instead of a fresh `--rm` one: the writable layer keeps
      # an incremental build's state between commands.
      #
      # @param enabled [Boolean]
      # @return [void]
      sig { params(enabled: T::Boolean).void }
      def persist(enabled)
        @persist = enabled
      end

      # Mount into this image's container, exactly as written (`docker run
      # -v`). Repeatable.
      #
      # @param spec [String] `host:container[:opts]`
      # @return [void]
      sig { params(spec: String).void }
      def volume(spec)
        @volumes << spec
      end

      # Environment a command in this image's container receives (`docker
      # run -e`), each value a Dev::Credentials "namespace/key" reference
      # resolved when the command runs. Repeatable; later keys add.
      #
      # @param mapping [Hash{String => String}] env var name → credential reference
      # @return [void]
      sig { params(mapping: T::Hash[String, String]).void }
      def run_env(mapping)
        @run_env.merge!(mapping)
      end

      STORE_VERBS.each do |verb|
        define_method(verb) do |*_args, **_kwargs, &_block|
          raise StoreVerbInImageError,
            "`#{verb}` inside an image block declares store content baked into the image — " \
              "which dev does not build. Declare it outside the block; " \
              "the container's own `dev up` installs it."
        end
      end

      class << self
        extend T::Sig

        # The registry prefix of a floor reference: everything before the
        # last path segment. `ghcr.io/d3mlabs/unreal-engine-build-base:ue5.8-3`
        # → `ghcr.io/d3mlabs`.
        #
        # @param from [String]
        # @return [String]
        sig { params(from: String).returns(String) }
        def registry_of(from)
          segments = from.split("/")
          segments.take(segments.size - 1).join("/")
        end
      end

      private

      # @param id [String] one `target_platforms` argument
      # @return [Lifecycle::Platform]
      # @raise [UnknownTargetPlatformError] listing the set
      sig { params(id: String).returns(Lifecycle::Platform) }
      def parse_target_platform(id)
        Lifecycle::Platform.parse(id)
      rescue Lifecycle::UnknownPlatformError => e
        raise UnknownTargetPlatformError, "`target_platforms` takes dev's platform ids: #{e.message}"
      end
    end

    # What a `brew` line asks, read once for the group and env forms of the
    # verb. The arguments sort into the declaration's fields: the formula
    # spec's name is the package, `tap:` is the source coordinate, `cask:`
    # routes to the :cask integration (a separate universe), and the
    # requirement is whichever one form was given — the positional
    # (`brew "llvm", "~18"`), `version:` (brew's family suffix, `"18"`
    # meaning `~18`), or the spec's own `@` (`brew "llvm@18"`), the three
    # spellings of one ask. What remains rides as options.
    class BrewAsk
      extend T::Sig

      # The requirement was said in more than one of its three spellings.
      class TwoRequirementsError < StandardError; end

      # @return [Declaration] the ask as a declaration
      sig { returns(Declaration) }
      attr_reader :declaration

      # @param declaration [Declaration]
      sig { params(declaration: Declaration).void }
      def initialize(declaration:)
        @declaration = declaration
      end

      class << self
        extend T::Sig

        # @param name [String] formula spec (`llvm`, `llvm@18`) or cask name
        # @param requirement [String, nil] the positional requirement
        # @param opts [Hash{Symbol => Object}] the keyword options
        # @return [BrewAsk]
        # @raise [TwoRequirementsError] if more than one spelling is given
        # @raise [FormulaSpec::InvalidSpecError] if the spec's suffix is not dotted digits
        # @raise [Requirement::ParseError] if the positional is not a requirement
        sig { params(name: String, requirement: T.nilable(String), opts: T::Hash[Symbol, T.untyped]).returns(BrewAsk) }
        def parse(name, requirement, opts)
          options = opts.dup
          cask = options.delete(:cask)
          tap = options.delete(:tap)
          suffix = options.delete(:version)
          # A versioned cask is its own name in Homebrew (`temurin@21`), so
          # a cask's `@` is not read as a family suffix.
          spec = cask ? FormulaSpec.new(name: name) : FormulaSpec.parse(name)

          spellings = {
            "a positional requirement" => requirement && Requirement.parse(requirement),
            "version:" => suffix && FormulaSpec.parse("#{spec.name}@#{suffix}").requirement,
            "the @ suffix" => spec.versioned? ? spec.requirement : nil,
          }.compact
          if spellings.size > 1
            raise TwoRequirementsError,
              "brew #{name.inspect}: the requirement is given as #{spellings.keys.join(" and ")} — " \
                "say it once (`brew \"#{spec.name}\", \"#{spellings.values.first}\"`)"
          end

          new(
            declaration: Declaration.new(
              name: spec.name,
              integration: cask ? :cask : :brew,
              requirement: spellings.values.first || Requirement::Any.new,
              options: options.transform_keys(&:to_s),
              source: tap&.to_s,
            ),
          )
        end
      end
    end

    # DSL for per-environment entries (inside group :build for env-specific brew).
    class EnvDSL
      extend T::Sig

      class EmptyNameError < StandardError; end

      # @return [Array<ScopedDeclaration>] declarations made inside this env block
      sig { returns(T::Array[ScopedDeclaration]) }
      attr_reader :declarations

      # @param group [Symbol] enclosing group, stamped onto declarations
      # @param platform [String, nil] enclosing group's platform
      # @param host [Symbol, nil] enclosing group's host OS
      # @param env [String, nil] environment name ("ci" / "dev"), stamped onto declarations
      sig do
        params(
          group: Symbol,
          platform: T.nilable(String),
          host: T.nilable(Symbol),
          env: T.nilable(String),
        ).void
      end
      def initialize(group: :app, platform: nil, host: nil, env: nil)
        @declarations = T.let([], T::Array[ScopedDeclaration])
        @group = group
        @platform = platform
        @host = host
        @env = env
      end

      # Declare a Homebrew formula/cask scoped to this environment. The
      # arguments read as GroupDSL#brew's (BrewAsk).
      #
      # @param name [String, Symbol] formula spec (`llvm`, `llvm@18`) or cask name
      # @param requirement [String, nil] a requirement over the family's versions
      # @param opts [Hash] options (tap:, version:, cask:)
      # @return [void]
      # @raise [EmptyNameError] if the name is empty
      # @raise [BrewAsk::TwoRequirementsError] if the requirement is said twice
      sig { params(name: T.any(String, Symbol), requirement: T.nilable(String), opts: T.untyped).void }
      def brew(name, requirement = nil, **opts)
        raise EmptyNameError, "brew dependency name cannot be empty" if name.to_s.empty?

        ask = BrewAsk.parse(name.to_s, requirement, opts)
        @declarations << ScopedDeclaration.new(
          declaration: ask.declaration,
          scope: Scope.new(group: @group, host: @host, env: @env),
          platform: @platform,
        )
      end
    end

    # DSL for group-scoped deps: declarations (app/test), brew + nested env (build).
    class GroupDSL
      extend T::Sig

      class EmptyNameError < StandardError; end

      # A commit pin (cmake commit:, gh sha:) that is not a full 40-char SHA.
      # Conflict rejection compares revisions textually, so only the
      # canonical spelling keeps equality trustworthy.
      class InvalidRevisionError < StandardError; end

      # A git-backed dep with nothing to select or address: a cmake dep with
      # no requirement, tag:, branch:, or commit:, a gh dep with no
      # requirement, tag: or sha:. An unconstrained enumeration would pin an
      # arbitrary ref, so the ask must say what it wants.
      class MissingRefError < StandardError; end

      # A verb's requirement given in two spellings at once — the positional
      # and the keyword that is its sugar (`tag:`, `buildid:`, `version:`).
      class TwoRequirementsError < StandardError; end

      # `assets:` on a gh dep pinned at a sha:. Release assets hang off a
      # release, and a commit publishes none — the only thing GitHub serves
      # for a bare commit is its source, so a sha: pin materializes with
      # build: alone.
      class AssetsAtCommitError < StandardError; end

      # `install_dir:` on a tree dep (gh, steam, wwise). The store places a
      # tree from its identity, so the manifest does not say where. Refused
      # rather than ignored, because a project still saying it has a tree at
      # the old path to move.
      class InstallDirRemovedError < StandardError; end

      # `apt` outside an `image` block. A distro package is not a dependency
      # dev can lock; the image its packages produce is, so the lines live in
      # the block that produces it.
      class AptOutsideImageError < StandardError; end

      # The canonical git address: a full 40-char lowercase hex SHA.
      FULL_SHA = /\A[0-9a-f]{40}\z/

      # The artifact target a ficsit mod materializes when no group platform
      # says otherwise: the Windows game build, which every mod publishes.
      FICSIT_DEFAULT_TARGET = "Windows"

      # What a wwise declaration downloads unless told otherwise: the SDK
      # package alone (Authoring is the Wwise application bundle, which the
      # downloader cannot extract and a build never needs), for the Windows
      # toolchains, Linux, and the platform-independent files (see #wwise).
      WWISE_DEFAULT_PACKAGES = T.let(["SDK"].freeze, T::Array[String])
      WWISE_DEFAULT_DEPLOYMENT_PLATFORMS = T.let(["Windows_vc160", "Windows_vc170", "Linux", ""].freeze, T::Array[String])

      # @return [Array<ScopedDeclaration>] declarations made inside this group
      sig { returns(T::Array[ScopedDeclaration]) }
      attr_reader :declarations

      # @param group [Symbol] group name (e.g. :app, :test, :build)
      # @param platform [String, nil] platform stamped onto every declaration in this group
      # @param host [Symbol, nil] host OS stamped onto every declaration in this group
      # @param registered_methods [Array<Symbol>] dynamically registered integration methods
      sig do
        params(
          group: Symbol,
          platform: T.nilable(String),
          host: T.nilable(Symbol),
          registered_methods: T::Array[Symbol],
        ).void
      end
      def initialize(group:, platform: nil, host: nil, registered_methods: [])
        @group = group
        @platform = platform
        @host = host
        @declarations = T.let([], T::Array[ScopedDeclaration])
        @registered_methods = registered_methods
      end

      # Declare a CMake dependency. Expands github: shorthand if present.
      #
      # Two universes behind one verb, split by the source's shape:
      #   - repo:/github: — a git universe under :cmake. The requirement
      #     selects over the remote's enumerated refs: `tag:` and `branch:`
      #     are an exact ref by name, the positional a range over the refs
      #     that are versions (`"~1.3"`); commit: is a revision — an
      #     address into the continuous space, full 40-char SHA only.
      #   - url: — an artifact universe under :url. The URL is the entire
      #     address, so nothing selects: a tag: here is a display label
      #     riding materialization, not a requirement.
      #
      # cmake_targets:/cmake_namespace: are install instructions (they shape
      # the generated deps.targets.cmake), so they ride materialization for
      # both universes.
      #
      # @param name [String, Symbol] dependency name
      # @param requirement [String, nil] a requirement over the remote's version tags
      # @param spec [Hash] options (tag:, branch:, commit:, repo:, url:, github:,
      #   cmake_targets:, cmake_namespace:, etc.)
      # @return [void]
      # @raise [InvalidRevisionError] if commit: is not a full 40-char SHA
      # @raise [MissingRefError] if a git-backed dep names no ref at all
      # @raise [TwoRequirementsError] if the requirement is given twice
      sig { params(name: T.any(String, Symbol), requirement: T.nilable(String), spec: T.untyped).void }
      def cmake(name, requirement = nil, **spec)
        spec = expand_github(name.to_s, spec)
        url = spec.delete(:url)&.to_s
        repo = spec.delete(:repo)&.to_s
        revision = spec.delete(:commit)&.to_s

        materialization = {}
        %i[cmake_targets cmake_namespace].each do |key|
          value = spec.delete(key)
          materialization[key.to_s] = value if value
        end

        if url
          label = spec.delete(:tag)
          materialization["version_label"] = label.to_s if label
          return add_declaration(name, :url, spec, requirement: Requirement.parse(requirement), source: url,
            materialization: materialization)
        end

        validate_full_sha!("cmake", name.to_s, :commit, revision)
        ref = spec.delete(:tag) || spec.delete(:branch)
        named = ref.nil? ? nil : Requirement::Exact.new(version: ref.to_s)
        asked = one_requirement("cmake", name.to_s, requirement, "tag:/branch:", named)
        if revision.nil? && asked.any?
          raise MissingRefError,
            "cmake #{name} names no requirement, tag:, branch:, or commit: — an unconstrained git universe " \
              "would pin an arbitrary ref"
        end

        add_declaration(name, :cmake, spec, requirement: asked, source: repo, revision: revision, materialization: materialization)
      end

      # Declare a Ruby gem scoped to this group (group name -> bundler group).
      #
      # @param name [String, Symbol] gem name
      # @param requirement [String, nil] requirement (e.g. "^1.17")
      # @param spec [Hash] additional bundler options (e.g. require:, git:)
      # @return [void]
      # @raise [Requirement::ParseError] if the requirement does not parse
      sig { params(name: T.any(String, Symbol), requirement: T.nilable(String), spec: T.untyped).void }
      def gem(name, requirement = nil, **spec)
        add_declaration(name, :bundler, spec, requirement: Requirement.parse(requirement))
      end

      # Declare a LuaRocks dependency with an optional requirement.
      #
      # @param name [String, Symbol] rock name
      # @param requirement [String, nil] requirement (e.g. ">= 3.5")
      # @param spec [Hash] additional options
      # @return [void]
      # @raise [Requirement::ParseError] if the requirement does not parse
      sig { params(name: T.any(String, Symbol), requirement: T.nilable(String), spec: T.untyped).void }
      def luarocks(name, requirement = nil, **spec)
        add_declaration(name, :luarocks, spec, requirement: Requirement.parse(requirement))
      end

      # Declare a pip package installed into the project venv (see `python`).
      # The transitive tree is resolved by pip at install time, so only the
      # top-level packages you depend on need declaring — mirroring luarocks.
      #
      # @param name [String, Symbol] distribution name (e.g. "totalsegmentator")
      # @param requirement [String, nil] requirement (e.g. ">=2.0", "2.0.5"; `~2.0.3` reads as PEP 440's `~=2.0.3`)
      # @param spec [Hash] additional options (e.g. host:)
      # @return [void]
      # @raise [Requirement::ParseError] if the requirement does not parse
      sig { params(name: T.any(String, Symbol), requirement: T.nilable(String), spec: T.untyped).void }
      def pip(name, requirement = nil, **spec)
        add_declaration(name, :pip, spec, requirement: Requirement.parse(requirement))
      end

      # Declare a Satisfactory mod dependency from ficsit.app.
      #
      # The requirement is the positional or `version:`, the keyword SMR's
      # own pages write a mod's constraint under — the same semver range
      # syntax, so the keyword is the positional under ficsit.app's name.
      #
      # target: is an install instruction — which of the mod's artifacts to
      # fetch when no group platform says otherwise — so it rides the
      # declaration's materialization, defaulting to the Windows game build
      # (the target every ficsit mod publishes for players).
      #
      # @param mod_reference [String, Symbol] mod reference (e.g. "SML", "AreaActions")
      # @param requirement [String, nil] requirement (e.g. "^3.12", ">=1.0")
      # @param version [String, nil] the same requirement, as SMR writes it (e.g. "^3.12.0")
      # @param spec [Hash] additional options (target:, etc.)
      # @return [void]
      # @raise [TwoRequirementsError] if both the positional and version: are given
      # @raise [Requirement::ParseError] if either is not a requirement
      sig do
        params(
          mod_reference: T.any(String, Symbol),
          requirement: T.nilable(String),
          version: T.nilable(String),
          spec: T.untyped,
        ).void
      end
      def ficsit(mod_reference, requirement = nil, version: nil, **spec)
        asked = one_requirement("ficsit", mod_reference.to_s, requirement, "version:", version && Requirement.parse(version))
        target = spec.delete(:target) || FICSIT_DEFAULT_TARGET
        add_declaration(mod_reference, :ficsit, spec, requirement: asked, materialization: { "target" => target.to_s })
      end

      # Declare a GitHub dependency, materialized one of two ways:
      #   - assets:  download prebuilt release asset(s) matching a glob (e.g. the CSS
      #              engine tarball). Prebuilt path.
      #   - build:   fetch the tag's source archive and build it (e.g. stock UE, which
      #              Epic ships as source only). Pass a project-relative script path or
      #              an inline shell string; :none extracts source with no build step
      #              (header-only). dev runs it with $DEV_SOURCE_DIR / $DEV_INSTALL_DIR /
      #              $DEV_VERSION and publishes $DEV_INSTALL_DIR as the tag's tree.
      # Exactly one of assets:/build: must be given (the verb names the FETCH backend;
      # assets/build names how it's MATERIALIZED).
      #
      # Two ways to say which version, exactly one of them:
      #   - a requirement over the repo's enumerated releases+tags universe
      #     (TagScheme): `tag:` names one tag exactly, as spelled; the
      #     positional ranges over the tags that are versions (`">= 5.6"`,
      #     a leading `v` read past).
      #   - sha:  a revision — an address into the continuous space between
      #           tags, full 40-char commit SHA only. No release exists for a
      #           bare commit, so a sha: pin materializes with build: alone.
      #
      # The first argument is the declaration name. With github:/repo: it is the name and
      # the slug comes from that option; otherwise it is the "owner/repo" slug and the
      # name is its basename (e.g. gh "EpicGames/UnrealEngine" -> name "UnrealEngine").
      #
      # @param name_or_slug [String, Symbol] dependency name, or "owner/repo" slug
      # @param requirement [String, nil] a requirement over the repo's version tags
      # @param tag [String, nil] exact tag (e.g. "5.6.1-release") — no floating "latest"
      # @param sha [String, nil] full 40-char commit SHA to pin instead of a tag
      # @param github [String, nil] "owner/repo" slug (shorthand; makes the first arg the name)
      # @param repo [String, nil] alias for github:
      # @param assets [String, nil] glob selecting prebuilt release assets
      # @param build [String, Symbol, nil] build-from-source recipe (script path / shell / :none)
      # @param spec [Hash] additional options
      # @return [void]
      # @raise [MissingRefError] if no requirement, tag: or sha: is given
      # @raise [TwoRequirementsError] if both the positional and tag: are given
      # @raise [InvalidRevisionError] if sha: is not a full 40-char SHA
      # @raise [AssetsAtCommitError] if assets: is combined with sha:
      sig do
        params(
          name_or_slug: T.any(String, Symbol),
          requirement: T.nilable(String),
          tag: T.nilable(String),
          sha: T.nilable(String),
          github: T.nilable(String),
          repo: T.nilable(String),
          assets: T.nilable(String),
          build: T.nilable(T.any(String, Symbol)),
          spec: T.untyped,
        ).void
      end
      def gh(name_or_slug, requirement = nil, tag: nil, sha: nil, github: nil, repo: nil, assets: nil, build: nil, **spec)
        slug = (github || repo || name_or_slug).to_s
        name = (github || repo) ? name_or_slug.to_s : T.must(slug.split("/").last)
        reject_install_dir!("gh", name, spec, place: "gh/#{slug}")

        unless [assets, build].compact.size == 1
          raise ArgumentError,
            "gh #{name.inspect}: provide exactly one of assets: (prebuilt release asset) " \
            "or build: (build from source)"
        end
        asked = one_requirement("gh", name, requirement, "tag:", tag && Requirement::Exact.new(version: tag))
        if asked.any? && sha.nil?
          raise MissingRefError,
            "gh #{name.inspect} names no requirement, tag: or sha: — a gh pin never floats to the latest release"
        end
        validate_full_sha!("gh", name, :sha, sha)
        if sha && assets
          raise AssetsAtCommitError,
            "gh #{name.inspect}: assets: selects release assets, and a commit publishes no release — " \
              "a sha: pin materializes from source (build:)"
        end

        # Sorted into fields: the slug is the source coordinate, the tag is
        # the requirement (or the sha the revision — Declaration refuses
        # both), and how to materialize (which assets to fetch or how to
        # build) is install instruction — the repository never sees any of
        # it. Where it lands is the store's: ~/.dev/gh/<slug>/<tag-or-sha>.
        materialization = {}
        materialization["asset_pattern"] = assets if assets
        materialization["build"] = build.to_s if build
        add_declaration(name, :gh, spec, requirement: asked, source: slug, revision: sha, materialization: materialization)
      end

      # Declare a Steam application dependency (e.g. the Satisfactory Dedicated
      # Server), provisioned via SteamCMD into the store (~/.dev/steam/<app>/<buildid>).
      #
      # The depot platform comes from the consuming group's platform:, so this
      # method takes no platform of its own. Pass buildid: (or the positional
      # `"= <buildid>"`) to assert an exact build; otherwise the resolver
      # floats to the branch's current build. A range is nothing Steam can
      # answer (SteamScheme) until a build history exists (dev#631).
      #
      # @param name [String, Symbol] dependency name (e.g. "SatisfactoryServer")
      # @param requirement [String, nil] an exact buildid, as a requirement
      # @param app [Integer, String] Steam app id (e.g. 1690800)
      # @param branch [String] Steam branch (default "public")
      # @param buildid [Integer, String, nil] the exact build asserted
      # @param spec [Hash] additional options
      # @return [void]
      # @raise [TwoRequirementsError] if both the positional and buildid: are given
      sig do
        params(
          name: T.any(String, Symbol),
          requirement: T.nilable(String),
          app: T.any(Integer, String),
          branch: String,
          buildid: T.nilable(T.any(Integer, String)),
          spec: T.untyped,
        ).void
      end
      def steam(name, requirement = nil, app:, branch: SteamBranch::DEFAULT_BRANCH, buildid: nil, **spec)
        reject_install_dir!("steam", name.to_s, spec, place: "steam/#{app}")
        # Sorted into fields: the app id and branch are the source coordinate
        # (which branch's universe — SteamBranch), the buildid is the
        # requirement, and the group's platform (which depot build SteamCMD
        # provisions — an install instruction, not a version fact) is
        # materialization.
        asked = one_requirement("steam", name.to_s, requirement, "buildid:", buildid && Requirement::Exact.new(version: buildid.to_s))
        materialization = {}
        materialization["platform"] = @platform if @platform
        add_declaration(name, :steam, spec, requirement: asked, source: SteamBranch.new(app: app.to_s, branch: branch).to_s,
          materialization: materialization)
      end

      # Declare the Epic Games Store's BuildPatchTool, provisioned from the
      # zip Epic serves into the store (~/.dev/egs/<name>/<digest>). Pinning
      # it gives the project its `deploy egs` channel.
      #
      # The universe is url-shaped: the zip is the whole address, hashed on
      # first use at `dev deps update` and verified at install, so the
      # declaration takes no version. A project behind a mirror names it
      # with url:.
      #
      # @param name [String, Symbol] dependency name (BuildPatchTool::NAME by convention)
      # @param url [String] where the zip is served from
      # @param spec [Hash] host: to scope the pin to one host
      # @return [void]
      sig { params(name: T.any(String, Symbol), url: String, spec: T.untyped).void }
      def egs(name = BuildPatchTool::NAME, url: BuildPatchTool::DOWNLOAD_URL, **spec)
        reject_install_dir!("egs", name.to_s, spec, place: "egs/#{name}")
        add_declaration(name, :egs, spec, source: url)
      end

      # Declare a dependency using any registered integration by name.
      #
      # @param name [String, Symbol] dependency name
      # @param requirement [String, nil] a requirement, in dev's language
      # @param integration [Symbol, String] integration identifier (e.g. :wow_curseforge)
      # @param spec [Hash] additional options, the integration's own
      # @return [void]
      # @raise [Requirement::ParseError] if the requirement does not parse
      sig do
        params(
          name: T.any(String, Symbol),
          requirement: T.nilable(String),
          integration: T.any(Symbol, String),
          spec: T.untyped,
        ).void
      end
      def custom(name, requirement = nil, integration:, **spec)
        add_declaration(name, integration.to_sym, spec, requirement: Requirement.parse(requirement))
      end

      # Pin the Xcode toolchain — a first-class dep like ruby, but riding the
      # normal resolver -> lockfile -> install pipeline. The integration is
      # inherently darwin-scoped (Xcode only exists on macOS; a no-op on other
      # hosts), so the declaration is safe without explicit host gating. dev
      # installs the pin to /Applications/Xcode-<version>.app via the xcodes
      # CLI — the xcode integration's own need, locked into the project with
      # provenance and installed first — and publishes DEVELOPER_DIR via
      # shadowenv.
      #
      # @param version [String, Symbol] exact Xcode version (e.g. "26.1.1")
      # @param spec [Hash] additional options
      # @return [void]
      # @raise [ArgumentError] if the version is blank — Apple publishes no
      #   registry to select from, so the exact version is the whole ask
      sig { params(version: T.any(String, Symbol), spec: T.untyped).void }
      def xcode(version, **spec)
        revision = version.to_s.strip
        raise ArgumentError, "xcode requires an exact version (e.g. xcode \"26.1.1\")" if revision.empty?

        # The exact version is an address, not a requirement: there is no
        # universe to select over, so it rides the declaration's revision and
        # XcodeRepository#at lifts it as the identity.
        add_declaration("xcode", :xcode, spec, revision: revision)
      end

      # Declare the Wwise SDK together with its Unreal Engine integration
      # package, downloaded by wwise-cli into the store (~/.dev/wwise/<sdk>)
      # laid out as wwise-cli's own cache. wwise-cli is the wwise
      # integration's own need, locked into the project with provenance and
      # installed first. The Audiokinetic login comes from Dev::Credentials
      # (WWISE_EMAIL / WWISE_PASSWORD).
      #
      # Audiokinetic publishes no version list without a login, so like xcode
      # the SDK version is an address: it rides the declaration's revision.
      # The integration package is versioned separately by Audiokinetic but
      # consumed only alongside the SDK, so it is an install instruction —
      # "also cache integration V for UE 5.6" — riding materialization with
      # the package and deployment-platform selection.
      #
      # The empty ("") deployment platform in the default is required, not
      # cosmetic: wwise-cli keeps a file only when its value for each filter
      # group is allowed, and the platform-independent SDK files (the base
      # headers) carry an empty DeploymentPlatforms value.
      #
      # @param name [String, Symbol] dependency name (e.g. "Wwise")
      # @param sdk [String] exact SDK version (e.g. "2023.1.14.8770")
      # @param integration [String] exact Unreal integration version (e.g. "2023.1.14.3555")
      # @param ue [String] Unreal Engine version the integration package targets, "<major>.<minor>"
      # @param packages [Array<String>] Wwise packages to download (default: the SDK alone)
      # @param deployment_platforms [Array<String>] SDK platform variants to download
      # @param spec [Hash] additional options
      # @return [void]
      # @raise [ArgumentError] if sdk, integration or ue is blank — there is
      #   no registry to select from, so each exact value is the whole ask
      sig do
        params(
          name: T.any(String, Symbol),
          sdk: String,
          integration: String,
          ue: String,
          packages: T::Array[String],
          deployment_platforms: T::Array[String],
          spec: T.untyped,
        ).void
      end
      def wwise(name, sdk:, integration:, ue:, packages: WWISE_DEFAULT_PACKAGES,
        deployment_platforms: WWISE_DEFAULT_DEPLOYMENT_PLATFORMS, **spec)
        reject_install_dir!("wwise", name.to_s, spec, place: "wwise")
        { sdk:, integration:, ue: }.each do |field, value|
          next unless value.strip.empty?

          raise ArgumentError, "wwise #{name.inspect}: #{field}: requires an exact value (e.g. #{field}: \"2023.1.14.8770\")"
        end

        # "integration_version", not "integration": the lockfile owns the
        # latter as the section key and strips it from a pin's metadata.
        materialization = {
          "integration_version" => integration,
          "ue" => ue,
          "packages" => packages,
          "deployment_platforms" => deployment_platforms,
        }
        add_declaration(name, :wwise, spec, revision: sdk.strip, materialization: materialization)
      end

      # Declare a Homebrew formula/cask.
      #
      # The declaration rides the resolver -> lockfile -> install pipeline —
      # the one install path, on the host (`dev deps install`) and in the
      # container image (bin/docker-install-build-deps.sh runs the same
      # command from the lock). BrewIntegration skips already-installed
      # formulae, so the install is idempotent.
      #
      # The arguments are read by BrewAsk: `tap:` is the source coordinate,
      # `cask:` routes to the :cask integration (a separate universe —
      # Homebrew publishes no versions or bottle digests for casks), and
      # the requirement over the family's real versions is the positional
      # (`brew "llvm", "~18"`), `version:` (`"18"`, the family suffix) or
      # the spec's own `@` (`brew "llvm@18"`) — one of them.
      #
      # @param name [String, Symbol] formula spec (`llvm`, `llvm@18`) or cask name
      # @param requirement [String, nil] a requirement over the family's versions
      # @param opts [Hash] options (tap:, version:, cask:, host:)
      # @return [void]
      # @raise [EmptyNameError] if the name is empty
      # @raise [BrewAsk::TwoRequirementsError] if the requirement is said twice
      sig { params(name: T.any(String, Symbol), requirement: T.nilable(String), opts: T.untyped).void }
      def brew(name, requirement = nil, **opts)
        raise EmptyNameError, "brew dependency name cannot be empty" if name.to_s.empty?

        post_install = opts.delete(:post_install)
        host = opts.delete(:host) || @host
        ask = BrewAsk.parse(name.to_s, requirement, opts)
        @declarations << ScopedDeclaration.new(
          declaration: ask.declaration,
          scope: Scope.new(group: @group, host:),
          platform: @platform,
          post_install:,
        )
      end

      # Refuse `apt` here: packages are image content, not pins.
      #
      # @param names [Array<String>] what the author tried to declare
      # @raise [AptOutsideImageError] always
      sig { params(names: String).void }
      def apt(*names)
        raise AptOutsideImageError,
          "`apt #{names.map(&:inspect).join(", ")}` outside an image block — a distro package cannot be " \
            "locked; the image its packages produce can. Declare it inside `image \"<name>\", from: <floor> do … end`."
      end

      # Scope member declarations to an environment ("ci" / "dev"). The env
      # name is a first-class declaration field (like host), landing in the
      # lockfile's env section so `dev deps install` filters it to the matching
      # environment — never smuggled through the declaration's options.
      #
      # @param name [String, Symbol] environment name
      # @return [void]
      sig { params(name: T.any(String, Symbol), block: T.nilable(T.proc.bind(EnvDSL).void)).void }
      def env(name, &block)
        env_name = name.to_s
        env_dsl = EnvDSL.new(group: @group, platform: @platform, host: @host, env: env_name)
        env_dsl.instance_eval(&block) if block
        @declarations.concat(env_dsl.declarations)
      end

      # Dispatch dynamically registered integration methods (e.g. wow_curseforge).
      # Falls back to super for unknown methods.
      #
      # @param method_name [Symbol] called method name
      # @param args [Array] positional arguments (first is the dependency name)
      # @param kwargs [Hash] keyword arguments passed to custom()
      # @return [Object]
      sig { params(method_name: Symbol, args: T.untyped, kwargs: T.untyped, block: T.untyped).returns(T.untyped) }
      def method_missing(method_name, *args, **kwargs, &block)
        if @registered_methods.include?(method_name.to_sym)
          T.unsafe(self).custom(*args, integration: method_name, **kwargs)
        else
          super
        end
      end

      # @param method_name [Symbol] queried method name
      # @param include_private [Boolean]
      # @return [Boolean]
      sig { params(method_name: T.any(Symbol, String), include_private: T::Boolean).returns(T::Boolean) }
      def respond_to_missing?(method_name, include_private = false)
        @registered_methods.include?(method_name.to_sym) || super
      end

      private

      # Refuse `install_dir:` on a tree verb, telling the author where the
      # store places the tree and how to move one already on disk. Mutates
      # spec: the key is removed so a caller that rescues sees a clean spec.
      #
      # @param verb [String] the DSL verb ("gh", "steam", "wwise")
      # @param name [String] the declaration name
      # @param spec [Hash] the verb's remaining options
      # @param place [String] the identity path under ~/.dev the store uses
      # @return [void]
      # @raise [InstallDirRemovedError] if spec carries :install_dir
      sig { params(verb: String, name: String, spec: T::Hash[Symbol, T.untyped], place: String).void }
      def reject_install_dir!(verb, name, spec, place:)
        return unless spec.key?(:install_dir)

        old = spec.delete(:install_dir)
        new_base = "#{Dev::DataRoot::HOME_ROOT}/#{place}/"
        raise InstallDirRemovedError, <<~MSG.strip
          #{verb} #{name.inspect}: install_dir: is gone — the store places trees by identity, \
          under #{new_base}<version>. Remove the option and re-lock. \
          A tree already installed moves with: mv #{old}/<version> #{new_base} \
          (or let `dev up` fetch it again).
        MSG
      end

      # Refuse a commit pin that is not spelled canonically. A nil revision
      # is no pin at all and passes; the verbs decide separately whether
      # one was required.
      #
      # @param verb [String] the DSL verb ("cmake", "gh")
      # @param name [String] the declaration name
      # @param option [Symbol] the option carrying the pin (:commit, :sha)
      # @param revision [String, nil] the pin as written
      # @return [void]
      # @raise [InvalidRevisionError] if the revision is not a full 40-char SHA
      sig { params(verb: String, name: String, option: Symbol, revision: T.nilable(String)).void }
      def validate_full_sha!(verb, name, option, revision)
        return if revision.nil? || revision.match?(FULL_SHA)

        raise InvalidRevisionError,
          "#{verb} #{name} pins #{option}: #{revision.inspect} — a commit is a full 40-char SHA " \
            "(tags select with tag:)"
      end

      # The one requirement a verb was given, out of its two spellings: the
      # positional in dev's language, or the keyword that is the verb's
      # sugar for it (`tag:` an Exact, ficsit's `version:` the positional
      # under SMR's name).
      #
      # @param verb [String] the DSL verb, for the message
      # @param name [String] the declaration name
      # @param positional [String, nil] the positional expression
      # @param keyword [String] the sugar keyword's name, for the message
      # @param sugar [Requirement, nil] what the keyword meant, when given
      # @return [Requirement] Any when neither was given
      # @raise [TwoRequirementsError] if both were given
      # @raise [Requirement::ParseError] if the positional does not parse
      sig do
        params(
          verb: String,
          name: String,
          positional: T.nilable(String),
          keyword: String,
          sugar: T.nilable(Requirement),
        ).returns(Requirement)
      end
      def one_requirement(verb, name, positional, keyword, sugar)
        if positional && sugar
          raise TwoRequirementsError,
            "#{verb} #{name.inspect}: the requirement is given both as #{positional.inspect} and as #{keyword} — say it once"
        end

        sugar || Requirement.parse(positional)
      end

      # Create a ScopedDeclaration and store it.
      #
      # host: is peeled off the spec into the Scope — a per-declaration
      # override of the group's host (e.g. `gh ..., host: :darwin` outside a
      # host-gated group). It never reaches the declaration, which describes
      # what the dep is, not where it installs. What remains of the spec is
      # the declaration's options, in the integration's vocabulary.
      #
      # @param name [String, Symbol] dependency name
      # @param integration [Symbol] integration type
      # @param spec [Hash] the verb's remaining options (symbol keys → stringified)
      # @param requirement [Requirement] what is asked of the package's versions
      # @param source [String, nil] source coordinate for the Declaration
      # @param revision [String, nil] addressable revision for the Declaration
      # @param materialization [Hash{String => Object}] install instructions
      # @return [void]
      sig do
        params(
          name: T.any(String, Symbol),
          integration: Symbol,
          spec: T::Hash[Symbol, T.untyped],
          requirement: Requirement,
          source: T.nilable(String),
          revision: T.nilable(String),
          materialization: T::Hash[String, T.untyped],
        ).void
      end
      def add_declaration(name, integration, spec, requirement: Requirement::Any.new, source: nil, revision: nil,
        materialization: {})
        name_str = name.to_s
        raise EmptyNameError, "dependency name cannot be empty" if name_str.empty?

        post_install = spec.delete(:post_install)
        host = spec.delete(:host) || @host
        spec = expand_github(name_str, spec) if spec.key?(:github)
        options = stringify_keys(spec)

        @declarations << ScopedDeclaration.new(
          declaration: Declaration.new(name: name_str, integration:, requirement:, options:, source:, revision:),
          scope: Scope.new(group: @group, host:),
          platform: @platform,
          post_install:,
          materialization: materialization,
        )
      end

      # Expand github: shorthand to a full repo: URL.
      #
      # "org/repo" → "https://github.com/org/repo"
      # "org"      → "https://github.com/org/<dep_name>"
      #
      # @param name [String] dependency name (used as repo name for org-only shorthand)
      # @param spec [Hash] spec hash; github: key is consumed and replaced with repo:
      # @return [Hash] spec with github: replaced by repo:
      sig { params(name: String, spec: T::Hash[Symbol, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
      def expand_github(name, spec)
        github = spec.delete(:github)
        return spec unless github

        repo_url = if github.include?("/")
          "https://github.com/#{github}"
        else
          "https://github.com/#{github}/#{name}"
        end
        spec.merge(repo: repo_url)
      end

      # @param hash [Hash] symbol-keyed options
      # @return [Hash] the same options with string keys
      sig { params(hash: T::Hash[T.untyped, T.untyped]).returns(T::Hash[String, T.untyped]) }
      def stringify_keys(hash)
        hash.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
      end
    end
  end
end
