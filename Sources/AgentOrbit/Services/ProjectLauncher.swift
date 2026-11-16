import AgentOrbitCore
import AppKit
import Foundation

@MainActor
enum ProjectLauncher {
    static func open(path: String, agentKind: AgentKind, preferred: PreferredLauncher) {
        let resolvedTarget = resolveTarget(preferred: preferred, agentKind: agentKind)
        open(path: path, with: resolvedTarget)
    }

    static func open(path: String, with target: PreferredLauncher) {
        let expanded = PathResolver.expandTilde(path)
        let projectURL = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()

        if target == .finder {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: projectURL.path)
            return
        }

        if let appURL = applicationURL(for: target) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open([projectURL], withApplicationAt: appURL, configuration: config)
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: projectURL.path)
        }
    }

    static func availableTargets() -> [PreferredLauncher] {
        var targets: [PreferredLauncher] = []
        for candidate in [PreferredLauncher.antigravity, .vscode, .cursor, .terminal] {
            if applicationURL(for: candidate) != nil {
                targets.append(candidate)
            }
        }
        targets.append(.finder)
        return targets
    }

    static func resolveTarget(preferred: PreferredLauncher, agentKind: AgentKind) -> PreferredLauncher {
        if preferred != .auto {
            return preferred
        }
        let order: [PreferredLauncher] = switch agentKind {
        case .antigravity:
            [.antigravity, .cursor, .vscode, .finder]
        case .codex, .custom:
            [.terminal, .vscode, .cursor, .antigravity, .finder]
        }
        for candidate in order {
            if candidate == .finder || applicationURL(for: candidate) != nil {
                return candidate
            }
        }
        return .finder
    }

    private static func applicationURL(for target: PreferredLauncher) -> URL? {
        switch target {
        case .auto, .finder:
            return nil
        case .antigravity:
            return findApp(
                bundleIDs: ["com.google.antigravity", "com.antigravity.ide", "com.todesktop.antigravity"],
                appNames: ["Antigravity.app"]
            )
        case .vscode:
            return findApp(
                bundleIDs: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"],
                appNames: ["Visual Studio Code.app", "Visual Studio Code - Insiders.app"]
            )
        case .cursor:
            return findApp(
                bundleIDs: ["com.todesktop.230313mzl4w4u92"],
                appNames: ["Cursor.app"]
            )
        case .terminal:
            return findApp(
                bundleIDs: [
                    "com.mitchellh.ghostty",
                    "dev.warp.Warp-Stable",
                    "com.googlecode.iterm2",
                    "com.apple.Terminal"
                ],
                appNames: ["Ghostty.app", "Warp.app", "iTerm.app", "Terminal.app"]
            )
        }
    }

    private static func findApp(bundleIDs: [String], appNames: [String]) -> URL? {
        for bundleID in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return url
            }
        }
        let fm = FileManager.default
        let roots = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        ]
        for root in roots {
            for appName in appNames {
                let candidate = URL(fileURLWithPath: root).appendingPathComponent(appName)
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }
}
