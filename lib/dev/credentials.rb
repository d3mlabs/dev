# typed: strict
# frozen_string_literal: true

require "fileutils"
require "open3"
require "yaml"
require "dev/ui"

module Dev
  # Generic credential provider — resolves credentials via a fallback chain:
  # ENV var → macOS Keychain → plain text file → interactive prompt.
  #
  # Storage backend is macOS Keychain when available, plain text fallback
  # (~/.config/dev/credentials.yml with 0600 permissions) on Linux.
  #
  # The prompt is the caller's Ui's (plans#52): the one question and the
  # one hidden paste go through `Ui#confirm` and `Ui#ask_secret`, so
  # whether there is a terminal to ask at is the tier's decision, made
  # once, never re-asked of `$stdin` here. A nil answer is the headless
  # path: the miss is refused with the CI remediation.
  module Credentials
    extend T::Sig

    class MissingCredentialError < StandardError; end

    KEYCHAIN_ACCOUNT = "d3mlabs/dev"

    module_function

    # Resolve a credential value through the fallback chain.
    #
    # @param namespace [String] credential namespace, e.g. "curseforge"
    # @param key [String] credential key within namespace, e.g. "api_key"
    # @param env_var [String] environment variable name, e.g. "CF_API_KEY"
    # @param prompt_label [String] human-readable description for the interactive prompt
    # @param ui [Ui] the terminal the onboarding prompt asks at, if any
    # @param create_url [String, nil] URL where the user creates the credential
    #   (omitted from prompts when nil)
    # @return [String] the credential value
    # @raise [MissingCredentialError] if non-interactive and no credential found
    sig do
      params(
        namespace: String,
        key: String,
        env_var: String,
        prompt_label: String,
        ui: Ui,
        create_url: T.nilable(String),
      ).returns(String)
    end
    def resolve(namespace:, key:, env_var:, prompt_label:, ui:, create_url: nil)
      ENV[env_var] ||
        load(namespace, key) ||
        prompt_and_store(namespace, key, env_var, prompt_label, create_url, ui:)
    end

    # Resolve runtime env vars an `image` block declares (`run_env`)
    # for injection into the container.
    #
    # Best-effort and non-interactive by design: an entry is injected only
    # when its value is already available (ENV override, then stored
    # credential), and silently skipped otherwise. run_env applies to every
    # containerized command, so a missing runtime secret must not block or
    # prompt commands that don't need it. The provisioning command that
    # *does* need it is responsible for making the value available (e.g.
    # exporting it before invoking the command).
    #
    # @param run_env [Hash{String => String}] var name => credential reference
    # @return [Hash{String => String}] var name => resolved value, resolvable entries only
    sig { params(run_env: T::Hash[String, String]).returns(T::Hash[String, String]) }
    def resolve_run_env(run_env)
      run_env.each_with_object({}) do |(name, credential_ref), resolved|
        namespace, key = credential_ref.split("/", 2)
        value = ENV[name] || load(T.must(namespace), T.must(key))
        resolved[name] = value if value
      end
    end

    # Load a credential from the platform-appropriate backend.
    #
    # Tries macOS Keychain first (when available), then the plain text file.
    #
    # @param namespace [String]
    # @param key [String]
    # @return [String, nil] the credential value, or nil if not found
    sig { params(namespace: String, key: String).returns(T.nilable(String)) }
    def load(namespace, key)
      value = load_from_keychain(namespace, key) if keychain_available?
      value || load_from_file(namespace, key)
    end

    # Store a credential to the platform-appropriate backend.
    #
    # Uses macOS Keychain when available, plain text file otherwise.
    #
    # @param namespace [String]
    # @param key [String]
    # @param value [String]
    # @return [void]
    sig { params(namespace: String, key: String, value: String).void }
    def store(namespace, key, value)
      if keychain_available?
        store_to_keychain(namespace, key, value)
      else
        store_to_file(namespace, key, value)
      end
    end

    # Whether the macOS Keychain is available.
    #
    # @return [Boolean]
    sig { returns(T::Boolean) }
    def keychain_available?
      RUBY_PLATFORM.include?("darwin")
    end

    # Load a credential from the macOS Keychain.
    #
    # @param namespace [String]
    # @param key [String]
    # @return [String, nil] the credential value, or nil if not found
    sig { params(namespace: String, key: String).returns(T.nilable(String)) }
    def load_from_keychain(namespace, key)
      service = keychain_service(namespace, key)
      stdout, _stderr, status = Open3.capture3(
        "security", "find-generic-password",
        "-a", KEYCHAIN_ACCOUNT,
        "-s", service,
        "-w",
      )
      status.success? ? stdout.chomp : nil
    end

    # Store a credential to the macOS Keychain.
    #
    # Uses -U flag to update if the entry already exists.
    # Note: -w passes the value as a CLI argument, briefly visible in `ps`.
    # This is the only interface `security add-generic-password` offers;
    # a native Keychain API binding would eliminate this exposure.
    #
    # @param namespace [String]
    # @param key [String]
    # @param value [String]
    # @return [void]
    sig { params(namespace: String, key: String, value: String).void }
    def store_to_keychain(namespace, key, value)
      service = keychain_service(namespace, key)
      Kernel.system(
        "security", "add-generic-password",
        "-U",
        "-a", KEYCHAIN_ACCOUNT,
        "-s", service,
        "-w", value,
        out: File::NULL, err: File::NULL,
      )
    end

    # Load a credential from the plain text credentials file.
    #
    # @param namespace [String]
    # @param key [String]
    # @return [String, nil] the credential value, or nil if not found
    sig { params(namespace: String, key: String).returns(T.nilable(String)) }
    def load_from_file(namespace, key)
      path = credentials_path
      return nil unless File.exist?(path)

      # Security: safe_load only allows basic types — no arbitrary
      # object instantiation from tampered YAML.
      creds = YAML.safe_load_file(path)
      creds&.dig(namespace, key)
    end

    # Store a credential to the plain text credentials file.
    #
    # Merges with existing content so other namespaces are preserved.
    # Uses flock(LOCK_EX) to prevent concurrent writes from clobbering
    # each other, and ensures 0600 permissions even if the file was
    # created externally with a wider umask.
    #
    # @param namespace [String]
    # @param key [String]
    # @param value [String]
    # @return [void]
    sig { params(namespace: String, key: String, value: String).void }
    def store_to_file(namespace, key, value)
      path = credentials_path
      dir = File.dirname(path)

      # Security: mkdir_p only sets mode on creation; chmod corrects
      # pre-existing directories that may have a wider umask (e.g. 0755).
      FileUtils.mkdir_p(dir, mode: 0o700)
      File.chmod(0o700, dir)

      # Security: RDWR|CREAT with explicit 0o600 creates the file with
      # restrictive permissions from the start (no TOCTOU window).
      # flock(LOCK_EX) prevents concurrent writes from clobbering each other.
      File.open(path, File::RDWR | File::CREAT, 0o600) do |f|
        f.flock(File::LOCK_EX)

        existing = f.read
        creds = existing.empty? ? {} : (YAML.safe_load(existing) || {})
        creds[namespace] ||= {}
        creds[namespace][key] = value

        f.rewind
        f.truncate(0)
        f.write(YAML.dump(creds))
      end

      # Security: corrects permissions on files created externally with
      # a wider umask. File.open's mode only applies on creation.
      File.chmod(0o600, path)
    end

    # Interactive prompt for credential onboarding: offers to open the
    # page the credential is made on (when one is known), asks for the
    # value with input hidden, and stores it via the appropriate backend.
    #
    # Both questions go through the Ui, so a terminal-less run never
    # blocks: the offer's nil is read as no, and the paste's nil is the
    # headless miss — refused with where to make the credential and the
    # `gh secret set` that supplies it to a job.
    #
    # @param namespace [String]
    # @param key [String]
    # @param env_var [String]
    # @param prompt_label [String]
    # @param create_url [String, nil]
    # @param ui [Ui]
    # @return [String] the credential value
    # @raise [MissingCredentialError] if non-interactive or empty input
    sig do
      params(
        namespace: String,
        key: String,
        env_var: String,
        prompt_label: String,
        create_url: T.nilable(String),
        ui: Ui,
      ).returns(String)
    end
    def prompt_and_store(namespace, key, env_var, prompt_label, create_url, ui:)
      offer_create_url(prompt_label, create_url, ui:) if create_url

      value = ui.ask_secret("Paste your #{prompt_label}")
      Kernel.raise MissingCredentialError, headless_hint(prompt_label, env_var, create_url) if value.nil?
      Kernel.raise MissingCredentialError, "No #{key} provided" if value.empty?

      store(namespace, key, value)
      ui.note("{{v}} #{prompt_label} stored")
      value
    end

    # Offer to open the page the credential is created on. Yes is the
    # answer Enter gives, as it was before the seam: opening a browser tab
    # is the one thing here dev would do unasked (contrast dev#533's
    # default of no for everything irreversible). nil — no terminal — is
    # read as no; the paste that follows refuses with the hint.
    #
    # @param prompt_label [String]
    # @param create_url [String]
    # @param ui [Ui]
    # @return [void]
    sig { params(prompt_label: String, create_url: String, ui: Ui).void }
    def offer_create_url(prompt_label, create_url, ui:)
      return unless ui.confirm("#{prompt_label} required — create one (free) at #{create_url}. Open it in the browser?", default: true)

      Kernel.system("open", create_url)
    end

    # What a run with no terminal to ask at is told instead of a prompt.
    #
    # @param prompt_label [String]
    # @param env_var [String]
    # @param create_url [String, nil]
    # @return [String]
    sig { params(prompt_label: String, env_var: String, create_url: T.nilable(String)).returns(String) }
    def headless_hint(prompt_label, env_var, create_url)
      message = "#{prompt_label} required.\n"
      message += "Create one at: #{create_url}\n" if create_url
      message + "Then set: gh secret set #{env_var}"
    end

    # Path to the plain text credentials file.
    #
    # Respects XDG_CONFIG_HOME (defaults to ~/.config).
    #
    # @return [String]
    sig { returns(String) }
    def credentials_path
      config_home = ENV.fetch("XDG_CONFIG_HOME", File.join(Dir.home, ".config"))
      File.join(config_home, "dev", "credentials.yml")
    end

    # Build the Keychain service name for a credential.
    #
    # @param namespace [String]
    # @param key [String]
    # @return [String] e.g. "curseforge/api_key"
    sig { params(namespace: String, key: String).returns(String) }
    def keychain_service(namespace, key)
      "#{namespace}/#{key}"
    end
  end
end
