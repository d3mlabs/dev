# Shell functions standing in for the three executables
# bin/container-provision-dev.sh calls: brew, git and dev. A test prepends
# this text to the script's own and runs the pair as one `sh -c` program, the
# way Dev::ContainerDevProvisioner hands the script to `docker exec`.
# Functions shadow PATH lookup, which a shim directory cannot: the script
# prepends Linuxbrew's bin to PATH, and a runner with a real Linuxbrew would
# win.
#
# Reads from the environment:
#   DEV_TEST_TAP_DIR     what `brew --repo` answers; with no .git in it the
#                        script trusts and taps, so every brew call runs
#   DEV_TEST_BREW_CALLS  a file brew appends each call to, followed by the
#                        trust-store dir's mode as `ls -ld` prints it, so a
#                        test can see the mode at the first brew call
#
# The whole file is a provision of dev-core 0.2.98: git's history holds one
# commit whose formula ships v0.2.98, no dev-core is installed yet, and the
# installed dev reports 0.2.98.
brew() {
  echo "$* $(ls -ld "$HOME/.homebrew" | cut -c1-10)" >> "$DEV_TEST_BREW_CALLS"
  case "$1" in
    --repo) echo "$DEV_TEST_TAP_DIR" ;;
    list) return 1 ;;
    *) : ;;
  esac
}

# Called as: git -c safe.directory='*' -C <tap_dir> <subcommand> ...
git() {
  case "$5" in
    log) echo "0123456789abcdef0123456789abcdef01234567" ;;
    show) echo 'url "https://github.com/d3mlabs/dev/archive/refs/tags/v0.2.98.tar.gz"' ;;
    *) : ;;
  esac
}

dev() {
  echo "0.2.98"
}
