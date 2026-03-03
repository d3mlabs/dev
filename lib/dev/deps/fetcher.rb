# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "tmpdir"
require "uri"

module Dev
  module Deps
    # Fetches runtime dependencies (git repos and URL tarballs) into the build directory.
    module Fetcher
      # Fetch all runtime deps that are missing from disk.
      # Returns an array of [FETCHCONTENT_SOURCE_DIR_<NAME>, path] pairs for cmake.
      def self.fetch_missing(root:, build_dir: "build", verbose: false)
        lock_path = File.join(root, "deps.lock.cmake")
        deps_dir = File.join(root, build_dir, "_deps")
        runtime_deps = Lockfile.parse(lock_path)
        runtime_ref_by_name = Lockfile.runtime_ref_map
        out_of_sync = Lockfile.check_sync!(root: root)

        fetchcontent_source_dirs = []

        runtime_deps.each do |dep|
          name = dep[:name]
          ref_display = runtime_ref_by_name[name] || (dep[:sha] ? dep[:sha][0, 7] : "tarball")
          label = "#{name}@#{ref_display}"
          dep_src = File.join(deps_dir, "#{name}-src")
          populated = populated?(dep_src, dep)
          in_sync = !out_of_sync.include?(name)

          if in_sync
            if populated
              Brew.step_ok(label)
              if dep.key?(:url)
                sha_display = dep[:hash] ? dep[:hash].sub(/\ASHA256=/, "") : "(pending)"
                puts "  url: #{dep[:url]} , sha256: #{sha_display}"
              end
              fetchcontent_source_dirs << ["FETCHCONTENT_SOURCE_DIR_#{name.upcase}", File.expand_path(dep_src)]
            else
              fetch_dep(dep, dep_src, lock_path, verbose: verbose)
              fetchcontent_source_dirs << ["FETCHCONTENT_SOURCE_DIR_#{name.upcase}", File.expand_path(dep_src)]
            end
          else
            Brew.step_fail(label)
            current_content = File.read(lock_path)
            generated = Lockfile.dep_pin(current_content, name)
            if Brew.cli_ui_available?
              CLI::UI.puts(CLI::UI.fmt("{{yellow:lockfile out of sync for #{name}: #{generated}}}"))
            else
              puts "  WARNING: lockfile out of sync for #{name}: #{generated}"
            end
          end
        end

        if out_of_sync.any?
          puts ""
          msg = "Run update-deps and commit deps.lock.cmake."
          if Brew.cli_ui_available?
            CLI::UI.puts(CLI::UI.fmt("{{yellow:#{msg}}}"))
          else
            puts msg
          end
          exit 1
        end

        cleanup_stale(deps_dir, runtime_deps)
        fetchcontent_source_dirs
      end

      def self.fetch_git(repo, sha, dest_dir, quiet: false)
        FileUtils.mkdir_p(File.dirname(dest_dir))
        FileUtils.rm_rf(dest_dir) if File.exist?(dest_dir)
        if quiet
          _out, err, status = Open3.capture3("git", "clone", "--no-checkout", "-q", repo, dest_dir)
          abort("git clone #{repo} failed: #{err}") unless status.success?
          env = { "GIT_TERMINAL_PROMPT" => "0" }
          _out2, err2, status2 = Open3.capture3(env, "git", "-c", "advice.detachedHead=false", "checkout", sha, chdir: dest_dir)
          abort("git checkout #{sha} failed: #{err2}") unless status2.success?
        else
          system("git", "clone", "--no-checkout", repo, dest_dir) || abort("git clone #{repo} failed")
          system("git", "checkout", sha, chdir: dest_dir) || abort("git checkout #{sha} failed")
        end
      end

      # Downloads and extracts a tarball, returns the SHA256 hex digest.
      def self.fetch_tarball(url, dest_dir, quiet: false)
        FileUtils.mkdir_p(File.dirname(dest_dir))
        FileUtils.rm_rf(dest_dir) if File.exist?(dest_dir)
        sha256_hex = nil
        Dir.mktmpdir("dev-deps-dep-") do |tmpdir|
          tarball = File.join(tmpdir, File.basename(URI(url).path))
          curl_args = ["-fSL", "-o", tarball, url]
          curl_args.unshift("-s") if quiet
          _out, err, status = Open3.capture3("curl", *curl_args)
          abort("download #{url} failed: #{err}") unless status.success?
          sha256_hex = Digest::SHA256.file(tarball).hexdigest
          _out, err, status = Open3.capture3("tar", "xzf", tarball, "-C", tmpdir)
          abort("tar extract failed: #{err}") unless status.success?
          inner = Dir.entries(tmpdir).find { |e| e != "." && e != ".." && File.directory?(File.join(tmpdir, e)) }
          abort("tarball had no top-level directory") unless inner
          FileUtils.mv(File.join(tmpdir, inner), dest_dir)
        end
        sha256_hex
      end

      # Sets or updates dep_<name>_hash in the lockfile.
      def self.update_lockfile_hash(lock_path, name, sha256_hex)
        content = File.read(lock_path)
        new_line = "set(dep_#{name}_hash \"SHA256=#{sha256_hex}\")\n"
        if content.include?("dep_#{name}_hash")
          content.sub!(/set\(dep_#{Regexp.escape(name)}_hash\s+"[^"]*"\)\n?/, new_line)
        else
          content.sub!(/(set\(dep_#{Regexp.escape(name)}_url "[^"]*"\)\n)/, "\\1#{new_line}")
        end
        File.write(lock_path, content)
      end

      class << self
        private

        def populated?(dep_src, dep)
          return false unless File.directory?(dep_src)
          File.exist?(File.join(dep_src, ".git")) ||
            File.exist?(File.join(dep_src, "CMakeLists.txt")) ||
            (dep.key?(:url) && !Dir.entries(dep_src).reject { |e| e == "." || e == ".." }.empty?)
        end

        def fetch_dep(dep, dep_src, lock_path, verbose: false)
          name = dep[:name]
          if dep.key?(:url)
            sha_display = dep[:hash] ? dep[:hash].sub(/\ASHA256=/, "") : "(pending)"
            puts "  url: #{dep[:url]} , sha256: #{sha_display}"
            Brew.with_spinner("Fetching #{name}") do
              computed = fetch_tarball(dep[:url], dep_src, quiet: !verbose)
              update_lockfile_hash(lock_path, name, computed) if computed
            end
          else
            Brew.with_spinner("Fetching #{name}") do
              fetch_git(dep[:repo], dep[:sha], dep_src, quiet: !verbose)
            end
          end
        end

        def cleanup_stale(deps_dir, runtime_deps)
          current_dep_names = runtime_deps.map { |d| d[:name].to_s }
          return unless File.directory?(deps_dir)

          Dir.entries(deps_dir).each do |entry|
            next if entry == "." || entry == ".."
            next unless entry.end_with?("-src")
            name = entry.sub(/-src\z/, "")
            next if current_dep_names.include?(name)
            stale_dir = File.join(deps_dir, entry)
            FileUtils.rm_rf(stale_dir) if File.directory?(stale_dir)
          end
        end
      end
    end
  end
end
