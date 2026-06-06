# frozen_string_literal: true

require "fileutils"
require "io/console"
require "open3"
require "yaml"

module Dev
  # Generic credential provider — resolves credentials via a fallback chain:
  # ENV var → macOS Keychain → plain text file → interactive prompt.
  #
  # Storage backend is macOS Keychain when available, plain text fallback
  # (~/.config/dev/credentials.yml with 0600 permissions) on Linux.
  module Credentials
    class MissingCredentialError < StandardError; end

    KEYCHAIN_ACCOUNT = "d3mlabs/dev"

    module_function

    # Resolve a credential value through the fallback chain.
    #
    # @param namespace [String] credential namespace, e.g. "curseforge"
    # @param key [String] credential key within namespace, e.g. "api_key"
    # @param env_var [String] environment variable name, e.g. "CF_API_KEY"
    # @param prompt_label [String] human-readable description for the interactive prompt
    # @param create_url [String] URL where the user creates the credential
    # @return [String] the credential value
    # @raise [MissingCredentialError] if non-interactive and no credential found
    def resolve(namespace:, key:, env_var:, prompt_label:, create_url:)
      ENV[env_var] ||
        load(namespace, key) ||
        prompt_and_store(namespace, key, env_var, prompt_label, create_url)
    end

    # Load a credential from the platform-appropriate backend.
    #
    # Tries macOS Keychain first (when available), then the plain text file.
    #
    # @param namespace [String]
    # @param key [String]
    # @return [String, nil] the credential value, or nil if not found
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
    def keychain_available?
      RUBY_PLATFORM.include?("darwin")
    end

    # Load a credential from the macOS Keychain.
    #
    # @param namespace [String]
    # @param key [String]
    # @return [String, nil] the credential value, or nil if not found
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

    # Interactive prompt for credential onboarding.
    #
    # Displays instructions, optionally opens the browser, and prompts
    # the user to paste the credential. Stores it via the appropriate backend.
    #
    # @param namespace [String]
    # @param key [String]
    # @param env_var [String]
    # @param prompt_label [String]
    # @param create_url [String]
    # @return [String] the credential value
    # @raise [MissingCredentialError] if non-interactive or empty input
    def prompt_and_store(namespace, key, env_var, prompt_label, create_url)
      unless $stdin.tty?
        raise MissingCredentialError,
          "#{prompt_label} required.\n" \
          "Create one at: #{create_url}\n" \
          "Then set: gh secret set #{env_var}"
      end

      $stdout.puts "\n#{prompt_label} required."
      $stdout.puts "Create one (free) at: #{create_url}\n\n"
      $stdout.print "Open in browser? (Y/n): "
      answer = $stdin.gets.chomp
      Kernel.system("open", create_url) unless answer.downcase == "n"

      # Security: suppress echo so the credential isn't visible on screen.
      $stdout.print "\nPaste your #{key}: "
      value = $stdin.noecho { $stdin.gets.chomp }
      $stdout.puts
      raise MissingCredentialError, "No #{key} provided" if value.empty?

      store(namespace, key, value)
      $stdout.puts "Credential stored.\n\n"
      value
    end

    # Path to the plain text credentials file.
    #
    # Respects XDG_CONFIG_HOME (defaults to ~/.config).
    #
    # @return [String]
    def credentials_path
      config_home = ENV.fetch("XDG_CONFIG_HOME", File.join(Dir.home, ".config"))
      File.join(config_home, "dev", "credentials.yml")
    end

    # Build the Keychain service name for a credential.
    #
    # @param namespace [String]
    # @param key [String]
    # @return [String] e.g. "curseforge/api_key"
    def keychain_service(namespace, key)
      "#{namespace}/#{key}"
    end
  end
end
