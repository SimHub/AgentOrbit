import Foundation

public struct DiscoveredAgentsResult: Sendable, Equatable {
    public let hasCodex: Bool
    public let codexPath: String
    public let hasAntigravity: Bool
    public let antigravityPath: String
    public let customAgents: [CustomAgentConfig]

    public init(
        hasCodex: Bool,
        codexPath: String,
        hasAntigravity: Bool,
        antigravityPath: String,
        customAgents: [CustomAgentConfig]
    ) {
        self.hasCodex = hasCodex
        self.codexPath = codexPath
        self.hasAntigravity = hasAntigravity
        self.antigravityPath = antigravityPath
        self.customAgents = customAgents
    }
}

public enum AgentDiscovery {
    public static func discover(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> DiscoveredAgentsResult {
        let fm = FileManager.default
        let codexURL = homeDirectory.appendingPathComponent(".codex")
        let resolvedCodex = codexURL.resolvingSymlinksInPath()
        let hasCodex = PathResolver.existsDirectory(resolvedCodex)

        let agyPrimary = homeDirectory.appendingPathComponent(".gemini/antigravity")
        let agyFallback = homeDirectory.appendingPathComponent(".antigravity")
        let hasPrimaryAgy = PathResolver.existsDirectory(agyPrimary.resolvingSymlinksInPath())
        let hasFallbackAgy = PathResolver.existsDirectory(agyFallback.resolvingSymlinksInPath())
        let hasAgy = hasPrimaryAgy || hasFallbackAgy
        let chosenAgyPath = (!hasPrimaryAgy && hasFallbackAgy) ? agyFallback.path : agyPrimary.path

        var custom: [CustomAgentConfig] = []

        // OpenCode (only if opencode.db exists)
        let openCodeDir = homeDirectory.appendingPathComponent(".local/share/opencode")
        if fm.fileExists(atPath: openCodeDir.appendingPathComponent("opencode.db").path) {
            custom.append(CustomAgentConfig(name: "OpenCode", path: openCodeDir.path, isEnabled: true))
        }

        // Pi agent
        let piDir = homeDirectory.appendingPathComponent(".pi/agent")
        if PathResolver.existsDirectory(piDir.resolvingSymlinksInPath()) {
            custom.append(CustomAgentConfig(name: "Pi", path: piDir.path, isEnabled: true))
        }

        // Claude Code (only if projects/ or sessions/ exists, not just empty ~/.claude)
        let claudeDir = homeDirectory.appendingPathComponent(".claude")
        if PathResolver.existsDirectory(claudeDir.appendingPathComponent("projects")) ||
            PathResolver.existsDirectory(claudeDir.appendingPathComponent("sessions")) {
            custom.append(CustomAgentConfig(name: "Claude", path: claudeDir.path, isEnabled: true))
        }

        return DiscoveredAgentsResult(
            hasCodex: hasCodex,
            codexPath: codexURL.path,
            hasAntigravity: hasAgy,
            antigravityPath: chosenAgyPath,
            customAgents: custom
        )
    }
}
