# typed: strict
# frozen_string_literal: true

require "dev/ini_file"

module Dev
  # The distro's `/etc/wsl.conf` — WSL2's per-distro boot settings — as an
  # editable value, the way WslConfig is the VM-wide `.wslconfig`. dev cares
  # about one key: `[boot] systemd`, which every systemd unit in the distro
  # (dockerd, the runner services) exists only under. Everything else in the
  # file is preserved byte for byte (see IniFile). The file is read by WSL at
  # distro start, so a change here is in effect only after `wsl --shutdown`.
  class WslConf
    extend T::Sig

    PATH = "/etc/wsl.conf"
    BOOT_SECTION = "boot"
    SYSTEMD_KEY = "systemd"

    class << self
      extend T::Sig

      # @param text [String] the file's content ("" for a missing file)
      # @return [WslConf]
      sig { params(text: String).returns(WslConf) }
      def parse(text)
        new(IniFile.parse(text))
      end

      # The distro's own file, empty when it does not exist yet.
      #
      # @param path [String] where the distro keeps it (PATH; injectable for tests)
      # @return [WslConf]
      sig { params(path: String).returns(WslConf) }
      def read(path: PATH)
        parse(File.exist?(path) ? File.read(path) : "")
      end
    end

    # @param ini [IniFile]
    sig { params(ini: IniFile).void }
    def initialize(ini)
      @ini = ini
    end

    # Whether `[boot] systemd=true` is set — spelled as WSL reads it,
    # case-insensitively.
    #
    # @return [Boolean]
    sig { returns(T::Boolean) }
    def systemd_enabled?
      @ini.value(BOOT_SECTION, SYSTEMD_KEY).to_s.casecmp?("true")
    end

    # A copy with systemd enabled.
    #
    # @return [WslConf]
    sig { returns(WslConf) }
    def with_systemd_enabled
      self.class.new(@ini.set(BOOT_SECTION, SYSTEMD_KEY, "true"))
    end

    # @return [String] the file content
    sig { returns(String) }
    def render
      @ini.render
    end

    sig { params(other: Object).returns(T::Boolean) }
    def ==(other)
      other.is_a?(WslConf) && render == other.render
    end
  end
end
