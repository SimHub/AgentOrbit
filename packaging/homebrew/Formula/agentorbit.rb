class Agentorbit < Formula
  desc "Lightweight, unsigned local AI agent HUD & Glass-HUD Terminal TUI (macOS & Linux)"
  homepage "https://github.com/SimHub/AgentOrbit"
  license "MIT"
  head "https://github.com/SimHub/AgentOrbit.git", branch: "main"

  depends_on "rust" => :build

  def install
    # Build CLI + Glass-HUD Terminal TUI (zero node_modules, zero signing required)
    system "cargo", "build", "--release", "-p", "agentorbit-cli"
    bin.install "target/release/agentorbit"

    # Build native Desktop HUD binary on macOS (or Linux if WebKitGTK is available)
    if OS.mac?
      system "cargo", "build", "--release", "-p", "agentorbit-app"
      bin.install "target/release/agentorbit-app"
    end
  end

  def caveats
    <<~EOS
      Launch the Glass-HUD Terminal TUI:
        agentorbit tui

      Launch the Desktop HUD (macOS):
        agentorbit-app &

      Local builds have no Apple quarantine flag and require no signing.
    EOS
  end

  test do
    assert_match "AgentOrbit", shell_output("#{bin}/agentorbit --help")
  end
end
