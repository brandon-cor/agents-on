class AgentsOn < Formula
  desc "Install and manage the Agents On menu bar sleep toggle"
  homepage "https://github.com/brandon-cor/agents-on"
  url "https://github.com/brandon-cor/agents-on/releases/download/v0.5.0/Agents-On-macOS.zip",
      using: :nounzip
  sha256 "b21b88eb9fdaa6f5d5dd003b4a3631aab4b67444db27428a27b9e79dd3d85a58"
  license "MIT"

  depends_on macos: :sonoma

  resource "installer" do
    url "https://raw.githubusercontent.com/brandon-cor/agents-on/99601cdd9d803faf73efa3823cc76bc0fe7db28f/install.sh"
    sha256 "3a33b8cf5d4172b6101f9341636a0352bb1f61e7f876803ea3d7fc62eec67b43"
  end

  def install
    # Preserve the verified release archive for the upstream installer's offline mode.
    libexec.install "Agents-On-macOS.zip"
    (libexec/"SHA256SUMS").write <<~EOS
      b21b88eb9fdaa6f5d5dd003b4a3631aab4b67444db27428a27b9e79dd3d85a58  Agents-On-macOS.zip
    EOS
    resource("installer").stage do
      libexec.install "install.sh"
    end

    # Setup is explicit: Homebrew installation never prompts for root or changes sleep.
    bin.mkpath
    (bin/"agents-on").write <<~SH
      #!/bin/bash
      set -euo pipefail

      usage() {
        cat <<'USAGE'
      Agents On for macOS
      Usage: agents-on install | verify | on | off | status | show | doctor | uninstall

      install    Set up the menu bar app and password-free toggles (one-time Mac password).
      verify     Verify the downloaded app without installing or changing sleep settings.
      on/off     Keep this Mac awake, or restore normal sleep.
      status     Show the current state.
      show       Show the menu bar indicator.
      doctor     Check the installed app.
      uninstall  Remove the app and restore normal sleep.
      USAGE
      }

      if [[ $# -ne 1 ]]; then
        usage >&2
        exit 2
      fi
      case "$1" in
        --help|-h|help) usage ;;
        --version) echo "#{version}" ;;
        install) exec /bin/bash "#{libexec}/install.sh" --archive-dir "#{libexec}" ;;
        verify) exec /bin/bash "#{libexec}/install.sh" --check-only --archive-dir "#{libexec}" ;;
        on|off|status|show|doctor)
          if [[ ! -x "$HOME/.local/bin/agents" ]]; then
            echo 'Finish setup first: agents-on install' >&2
            exit 1
          fi
          exec "$HOME/.local/bin/agents" "$1"
          ;;
        uninstall)
          script="$HOME/Library/Application Support/Agents On/uninstall.sh"
          if [[ ! -f "$script" ]]; then
            echo 'Agents On is not set up for this account.' >&2
            exit 1
          fi
          exec /bin/bash "$script"
          ;;
        *) usage >&2; exit 2 ;;
      esac
    SH
    (bin/"agents-on").chmod 0755
  end

  def caveats
    <<~EOS
      Finish setup and start the menu bar app:
        agents-on install

      Setup asks once for your Mac password to allow the two sleep toggles.
      The app is installed in ~/Applications and starts when you sign in.
      Run `agents-on install` again after upgrading this formula.

      To remove the app and restore normal sleep, run `agents-on uninstall`
      before `brew uninstall agents-on`.
    EOS
  end

  test do
    assert_match "Agents On for macOS", shell_output("#{bin}/agents-on --help")
    assert_equal version.to_s, shell_output("#{bin}/agents-on --version").strip
    assert_match "No installation or sleep settings changed", shell_output("#{bin}/agents-on verify")
  end
end
