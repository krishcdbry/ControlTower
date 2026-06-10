# Homebrew formula for Control Tower
# To use: copy to your tap repository (e.g., homebrew-tap/Formula/control-tower.rb)

class ControlTower < Formula
  desc "Unified menu bar app for monitoring AI coding assistant usage"
  homepage "https://github.com/krishcdbry/ControlTower"
  url "https://github.com/krishcdbry/ControlTower/archive/refs/tags/v1.0.0-beta.3.tar.gz"
  sha256 "c074fcd00b74a3b77d2a7d947194bb36cc5658098713b2c0a8c63cb116ff26be"
  license "MIT"
  head "https://github.com/krishcdbry/ControlTower.git", branch: "main"

  depends_on xcode: ["16.0", :build]
  depends_on macos: :sonoma

  def install
    system "swift", "build",
           "--disable-sandbox",
           "-c", "release",
           "-Xswiftc", "-cross-module-optimization"

    # Install CLI tool
    bin.install ".build/release/ct"

    # Build and install the app bundle
    system "./Scripts/compile_and_run.sh", "--build-only" if File.exist?("Scripts/compile_and_run.sh")

    # Install app bundle if it was created
    if File.exist?("ControlTower.app")
      prefix.install "ControlTower.app"
      # Create symlink in /Applications
      ohai "To install the app, run:"
      ohai "  ln -sf #{prefix}/ControlTower.app /Applications/"
    end
  end

  def caveats
    <<~EOS
      Control Tower has been installed!

      CLI tool: The 'ct' command is now available in your PATH.

      Menu bar app: To install the app, run:
        ln -sf #{prefix}/ControlTower.app /Applications/

      Then launch "Control Tower" from Applications or Spotlight.

      Provider setup:
        Claude:  Run 'claude' to authenticate
        Codex:   Run 'codex' to authenticate
        Gemini:  Run 'gemini' to authenticate or set GEMINI_API_KEY
        Copilot: Run 'gh auth login' to authenticate
        Cursor:  Sign in at cursor.com in your browser
    EOS
  end

  test do
    assert_match "Control Tower", shell_output("#{bin}/ct --help")
    assert_match "claude", shell_output("#{bin}/ct list")
  end
end
