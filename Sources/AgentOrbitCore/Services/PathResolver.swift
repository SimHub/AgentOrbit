import Foundation

public enum PathResolver {
    public static func expandTilde(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return (trimmed as NSString).expandingTildeInPath
    }

    static func resolve(_ rawPath: String) -> URL {
        let expanded = expandTilde(rawPath)
        let url = URL(fileURLWithPath: expanded)
        return url.resolvingSymlinksInPath()
    }

    static func existsDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func resolveCodexRoot(_ rawPath: String) -> URL {
        let resolved = resolve(rawPath)
        let fm = FileManager.default
        if fm.fileExists(atPath: resolved.appendingPathComponent("state_5.sqlite").path) ||
            fm.fileExists(atPath: resolved.appendingPathComponent("config.toml").path) {
            return resolved
        }
        let nested = resolved.appendingPathComponent(".codex").resolvingSymlinksInPath()
        if existsDirectory(nested) {
            return nested
        }
        return resolved
    }

    static func resolveAntigravityRoot(_ rawPath: String) -> URL {
        let resolved = resolve(rawPath)
        let fm = FileManager.default

        let directMarkers = ["conversation_summaries.db", "antigravity_state.pbtxt"]
        if directMarkers.contains(where: { fm.fileExists(atPath: resolved.appendingPathComponent($0).path) }) {
            return resolved
        }

        let subAntigravity = resolved.appendingPathComponent("antigravity").resolvingSymlinksInPath()
        if directMarkers.contains(where: { fm.fileExists(atPath: subAntigravity.appendingPathComponent($0).path) }) {
            return subAntigravity
        }

        let subGeminiAntigravity = resolved.appendingPathComponent(".gemini/antigravity").resolvingSymlinksInPath()
        if directMarkers.contains(where: { fm.fileExists(atPath: subGeminiAntigravity.appendingPathComponent($0).path) }) {
            return subGeminiAntigravity
        }

        // If user entered ~/.antigravity (IDE folder), check default ~/.gemini/antigravity sibling
        if resolved.lastPathComponent == ".antigravity" {
            let homeGemini = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".gemini/antigravity")
                .resolvingSymlinksInPath()
            if directMarkers.contains(where: { fm.fileExists(atPath: homeGemini.appendingPathComponent($0).path) }) {
                return homeGemini
            }
        }

        return resolved
    }

    static func gitBranch(for directoryPath: String?) -> String? {
        guard let directoryPath, !directoryPath.isEmpty else { return nil }
        var current = URL(fileURLWithPath: directoryPath).resolvingSymlinksInPath()
        let fm = FileManager.default

        for _ in 0..<8 {
            let dotGit = current.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                let headURL: URL
                if isDir.boolValue {
                    headURL = dotGit.appendingPathComponent("HEAD")
                } else if let content = try? String(contentsOf: dotGit, encoding: .utf8),
                          let line = content.split(separator: "\n").first,
                          line.hasPrefix("gitdir:") {
                    let rawGitDir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    let gitDirURL = rawGitDir.hasPrefix("/")
                        ? URL(fileURLWithPath: rawGitDir)
                        : current.appendingPathComponent(rawGitDir)
                    headURL = gitDirURL.appendingPathComponent("HEAD")
                } else {
                    return nil
                }

                if let head = try? String(contentsOf: headURL, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines) {
                    if head.hasPrefix("ref: refs/heads/") {
                        return String(head.dropFirst("ref: refs/heads/".count))
                    }
                    if head.hasPrefix("ref: ") {
                        return URL(fileURLWithPath: String(head.dropFirst(5))).lastPathComponent
                    }
                    return String(head.prefix(7))
                }
                return nil
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }

    static func inspectWatchedFolder(_ configuredPath: String) -> WatchedFolderStatus {
        let resolved = resolve(configuredPath)
        let online = existsDirectory(resolved)
        let fm = FileManager.default
        let hasCodex = online && fm.fileExists(atPath: resolved.appendingPathComponent(".codex").path)
        let hasAntigravity = online && (
            fm.fileExists(atPath: resolved.appendingPathComponent(".antigravity").path) ||
            fm.fileExists(atPath: resolved.appendingPathComponent(".agent").path)
        )
        let branch = online ? gitBranch(for: resolved.path) : nil
        return WatchedFolderStatus(
            configuredPath: configuredPath,
            resolvedPath: resolved.path,
            displayName: resolved.lastPathComponent.isEmpty ? configuredPath : resolved.lastPathComponent,
            isOnline: online,
            gitBranch: branch,
            hasCodexConfig: hasCodex,
            hasAntigravityConfig: hasAntigravity
        )
    }

    static func projectDisplayName(for path: String?, watchedFolders: [WatchedFolderStatus]) -> String {
        guard let path, !path.isEmpty else { return "—" }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        for folder in watchedFolders where folder.isOnline {
            if resolved == folder.resolvedPath || resolved.hasPrefix(folder.resolvedPath + "/") {
                if resolved == folder.resolvedPath {
                    return folder.displayName
                }
                let relative = String(resolved.dropFirst(folder.resolvedPath.count + 1))
                let firstSegment = relative.split(separator: "/").first.map(String.init)
                return firstSegment.map { "\(folder.displayName)/\($0)" } ?? folder.displayName
            }
        }
        let name = URL(fileURLWithPath: resolved).lastPathComponent
        return name.isEmpty ? resolved : name
    }
}
