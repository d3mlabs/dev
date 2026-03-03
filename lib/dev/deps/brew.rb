# frozen_string_literal: true

require "open3"

module Dev
  module Deps
    # Installs Homebrew formulae and casks declared in the build group of Dev::Deps::Config.
    module Brew
      VERBOSE = ENV["VERBOSE"].to_s =~ /\A(1|true|yes)\z/i

      def self.current_env
        ci_like = ENV["CI"].to_s =~ /\A(true|1)\z/i
        linux = RUBY_PLATFORM.to_s.include?("linux")
        (ci_like || linux) ? "ci" : "dev"
      end

      # Install all build-group brew deps for the given (or auto-detected) environment.
      def self.install_build_deps(env: nil)
        env = (env || current_env).to_s
        build_group = Config.group("build")
        global_brew = build_group["brew"] || []
        env_brew = (build_group["env"] || {})[env]&.dig("brew") || []
        process_brew_entries(Array(global_brew) + Array(env_brew))
      end

      # --- individual installers ---

      def self.install_tap_formula(name, version, tap: nil)
        tap = (tap || ENV["TAP_NAME"]).to_s.strip
        abort("tap not set (TAP_NAME env or explicit tap required)") if tap.empty?

        version_str = (version || "").to_s.strip
        spec = version_str.empty? ? "#{tap}/#{name}" : "#{tap}/#{name}@#{version_str}"

        if system("brew list #{name} >/dev/null 2>&1")
          step_ok(name)
          return
        end

        if VERBOSE
          system("brew", "install", spec) || abort("brew install #{spec} failed.")
          step_ok(name)
        else
          with_spinner("Installing #{spec}") do
            out, err, status = run_brew_capture("install", spec)
            unless status.success?
              print_brew_failure(out, err)
              raise "brew install #{spec} failed"
            end
          end
        end
      end

      def self.install_brew_spec(spec)
        tool = spec.to_s.split(/\s/).first
        if system("brew list #{tool} >/dev/null 2>&1")
          step_ok(tool)
          return
        end

        if VERBOSE
          system("brew", "install", spec) || abort("brew install #{spec} failed")
          step_ok(tool)
        else
          with_spinner("Installing #{tool}") do
            out, err, status = run_brew_capture("install", spec)
            unless status.success?
              print_brew_failure(out, err)
              raise "brew install #{spec} failed"
            end
          end
        end
      end

      def self.install_cask(cask)
        cask = cask.to_s.strip
        return if cask.empty?

        if system("brew list --cask #{cask} >/dev/null 2>&1")
          step_ok(cask)
          return
        end

        if VERBOSE
          system("brew", "install", "--cask", cask) || abort("brew install --cask #{cask} failed")
          step_ok(cask)
        else
          with_spinner("Installing #{cask}") do
            success = system("brew install --cask #{cask} >/dev/null 2>/dev/null")
            raise "brew install --cask #{cask} failed. Run with VERBOSE=1 to see output." unless success
          end
        end
      end

      # --- entry processing ---

      def self.process_brew_entries(entries)
        (entries || []).each { |entry| process_brew_entry(entry) }
      end

      def self.process_brew_entry(entry)
        if entry.is_a?(Hash)
          entry.each { |name, opts| process_hash_entry(name, opts) }
        else
          process_spec_entry(entry)
        end
      end

      def self.process_hash_entry(name, opts)
        name = name.to_s.strip
        return if name.empty?

        opts = (opts.is_a?(Hash) ? opts : {}).each_with_object({}) { |(k, v), h| h[k.to_s] = v }
        version  = (opts["version"] || opts[:version]).to_s.strip
        tap_name = (opts["tap"]     || opts[:tap]).to_s.strip
        cask     =  opts["cask"]    || opts[:cask]

        if !tap_name.empty?
          install_tap_formula(name, version, tap: tap_name)
        elsif cask
          install_cask(name)
        else
          spec = version.empty? ? name : "#{name}@#{version}"
          install_brew_spec(spec)
        end
      end

      def self.process_spec_entry(spec)
        spec = spec.to_s.strip
        return if spec.empty?
        install_brew_spec(spec)
      end

      # --- UI helpers (CLI::UI optional) ---

      def self.cli_ui_available?
        return @cli_ui_available if defined?(@cli_ui_available)
        @cli_ui_available = begin
          require "cli/ui"
          true
        rescue LoadError
          false
        end
      end

      def self.step_ok(name)
        if cli_ui_available?
          CLI::UI.puts("#{CLI::UI::Glyph::CHECK} #{name}")
        else
          puts "  ok: #{name}"
        end
      end

      def self.step_fail(name)
        if cli_ui_available?
          CLI::UI.puts("#{CLI::UI::Glyph::X} #{name}")
        else
          puts "  FAIL: #{name}"
        end
      end

      def self.with_spinner(title, &block)
        if cli_ui_available?
          CLI::UI::Spinner.spin(title, &block)
        else
          puts "  #{title}..."
          block.call
        end
      end

      def self.sanitize_utf8(str)
        return str if str.nil? || (str.encoding == Encoding::UTF_8 && str.valid_encoding?)
        str.dup.force_encoding(Encoding::UTF_8).encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?")
      end

      def self.run_brew_capture(*args)
        Open3.capture3("brew", *args)
      end

      def self.print_brew_failure(out, err)
        [out, err].each do |s|
          next if s.nil? || sanitize_utf8(s).strip.empty?
          sanitize_utf8(s).each_line { |l| puts "  | #{l.chomp}" }
        end
      end
    end
  end
end
