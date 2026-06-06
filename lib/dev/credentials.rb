# frozen_string_literal: true

require "fileutils"
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

    KEYCHAIN_ACCOUNT = "dev"

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

      creds = YAML.safe_load_file(path)
      creds&.dig(namespace, key)
    end

    # Store a credential to the plain text credentials file.
    #
    # Merges with existing content so other namespaces are preserved.
    # File is created with 0600 permissions (owner read/write only).
    #
    # @param namespace [String]
    # @param key [String]
    # @param value [String]
    # @return [void]
    def store_to_file(namespace, key, value)
      path = credentials_path
      dir = File.dirname(path)
      FileUtils.mkdir_p(dir)

      creds = File.exist?(path) ? (YAML.safe_load_file(path) || {}) : {}
      creds[namespace] ||= {}
      creds[namespace][key] = value

      File.write(path, YAML.dump(creds))
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

      $stdout.print "\nPaste your #{key}: "
      value = $stdin.gets.chomp
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
    # @return [String] e.g. "dev/curseforge/api_key"
    def keychain_service(namespace, key)
      "dev/#{namespace}/#{key}"
    end
  end
end
