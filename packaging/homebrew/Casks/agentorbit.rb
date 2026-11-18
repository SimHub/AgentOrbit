cask "agentorbit" do
  version "1.3.0"
  sha256 :no_check

  url "https://github.com/SimHub/AgentOrbit/releases/download/v#{version}/AgentOrbit.dmg"
  name "AgentOrbit"
  desc "Lightweight native macOS menu bar & floating desktop HUD for AI coding agents"
  homepage "https://simhub.github.io/AgentOrbit/"

  depends_on macos: ">= :sonoma"

  app "AgentOrbit.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-cr", "#{appdir}/AgentOrbit.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Preferences/dev.agentorbit.AgentOrbit.plist",
  ]

  caveats <<~EOS
    AgentOrbit is ad-hoc signed. If macOS still warns on first launch, run:
      xattr -cr "#{appdir}/AgentOrbit.app"
  EOS
end
