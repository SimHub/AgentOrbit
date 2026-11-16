import Foundation

enum CustomAgentReader {
    static func readSessions(
        config: CustomAgentConfig,
        watchedFolders: [WatchedFolderStatus],
        limit: Int = 6
    ) -> [AgentSnapshot] {
        guard config.isEnabled else { return [] }

        let expanded = PathResolver.expandTilde(config.path)
        let label = config.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Custom" : config.name
        guard !expanded.isEmpty else {
            return [.placeholder(.custom, sessionID: config.id.uuidString, agentLabel: label, state: .unavailable, message: "Kein Pfad konfiguriert")]
        }

        let resolvedRoot = PathResolver.resolve(config.path)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolvedRoot.path, isDirectory: &isDir) else {
            let state: AgentRunState = resolvedRoot.path.hasPrefix("/Volumes/") ? .offline : .unavailable
            let msg = state == .offline ? "SSD nicht gemountet (\(resolvedRoot.path))" : "Ordner nicht gefunden"
            return [.placeholder(.custom, sessionID: config.id.uuidString, agentLabel: label, state: state, message: msg)]
        }

        // 1. OpenCode SQLite (opencode.db)
        let openCodeDB = isDir.boolValue
            ? resolvedRoot.appendingPathComponent("opencode.db")
            : resolvedRoot
        if openCodeDB.lastPathComponent == "opencode.db", fm.fileExists(atPath: openCodeDB.path) {
            let sessions = readOpenCodeDB(
                at: openCodeDB,
                config: config,
                label: label,
                watchedFolders: watchedFolders,
                limit: limit
            )
            if !sessions.isEmpty {
                return sessions
            }
        }

        // 2. Generic JSONL sessions (e.g. Pi, Claude Code, etc.)
        if isDir.boolValue {
            let jsonlSessions = readRecentJSONLSessions(
                in: resolvedRoot,
                config: config,
                label: label,
                watchedFolders: watchedFolders,
                limit: limit
            )
            if !jsonlSessions.isEmpty {
                return jsonlSessions
            }
        }

        // 3. Generic folder activity fallback
        let mtime = newestModificationDate(in: resolvedRoot, maxDepth: 2)
        let isLive = mtime.map { Date().timeIntervalSince($0) < 20 } ?? false
        return [
            AgentSnapshot(
                kind: .custom,
                sessionID: config.id.uuidString,
                agentLabel: label,
                state: isLive ? .running : .idle,
                projectName: label,
                projectPath: resolvedRoot.path,
                gitBranch: PathResolver.gitBranch(for: resolvedRoot.path),
                modelName: "—",
                reasoningEffort: nil,
                sessionTitle: nil,
                usage: UsageMetrics(),
                lastUpdated: mtime,
                resolvedSourcePath: resolvedRoot.path,
                statusMessage: mtime == nil ? "Noch keine Aktivität" : nil
            )
        ]
    }

    private static func readOpenCodeDB(
        at dbURL: URL,
        config: CustomAgentConfig,
        label: String,
        watchedFolders: [WatchedFolderStatus],
        limit: Int
    ) -> [AgentSnapshot] {
        let fetchCount = max(limit * 2, 12)
        let rows = SQLiteReader.query(
            databaseURL: dbURL,
            sql: """
            SELECT id, directory, title, model, agent, cost, tokens_input, tokens_output, tokens_cache_read, time_updated
            FROM session
            WHERE time_archived IS NULL
            ORDER BY time_updated DESC
            LIMIT \(fetchCount)
            """
        )

        var results: [AgentSnapshot] = []
        var seenProjects: Set<String> = []

        for (index, row) in rows.enumerated() {
            let sid = row["id"]?.stringValue ?? "\(config.id.uuidString)-\(index)"
            let directory = row["directory"]?.stringValue
            let title = row["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            let model = row["model"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "—"
            let rawTime = row["time_updated"]?.doubleValue
            let updatedAt = rawTime.map { val in
                // OpenCode stores Unix timestamps in milliseconds
                val > 10_000_000_000 ? Date(timeIntervalSince1970: val / 1000.0) : Date(timeIntervalSince1970: val)
            }
            let age = updatedAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
            let state: AgentRunState = age < 20 ? .running : .idle

            let projectKey = directory ?? sid
            if !state.isActiveOrWaiting && !results.isEmpty {
                if seenProjects.contains(projectKey) || age > 86_400 {
                    continue
                }
            }
            seenProjects.insert(projectKey)

            let inp = row["tokens_input"]?.intValue
            let out = row["tokens_output"]?.intValue
            let cache = row["tokens_cache_read"]?.intValue
            let costVal = row["cost"]?.doubleValue
            let total = [inp, out, cache].compactMap { $0 }.reduce(0, +)

            let usage = UsageMetrics(
                sessionTotalTokens: total > 0 ? total : nil,
                inputTokens: inp,
                cacheReadTokens: cache,
                outputTokens: out,
                recordedCostUSD: (costVal ?? 0) > 0 ? costVal : nil
            )

            results.append(AgentSnapshot(
                kind: .custom,
                sessionID: "\(config.id.uuidString):\(sid)",
                agentLabel: label,
                state: state,
                projectName: PathResolver.projectDisplayName(for: directory, watchedFolders: watchedFolders),
                projectPath: directory,
                gitBranch: PathResolver.gitBranch(for: directory),
                modelName: model,
                reasoningEffort: nil,
                sessionTitle: title,
                usage: usage,
                lastUpdated: updatedAt,
                resolvedSourcePath: dbURL.deletingLastPathComponent().path,
                statusMessage: nil
            ))

            if results.count >= limit {
                break
            }
        }

        return results
    }

    private static func readRecentJSONLSessions(
        in root: URL,
        config: CustomAgentConfig,
        label: String,
        watchedFolders: [WatchedFolderStatus],
        limit: Int
    ) -> [AgentSnapshot] {
        let fm = FileManager.default
        let searchRoots = [
            root.appendingPathComponent("sessions"),
            root.appendingPathComponent("projects"),
            root
        ]

        var jsonlFiles: [(url: URL, mtime: Date)] = []
        for base in searchRoots where PathResolver.existsDirectory(base) {
            guard let enumerator = fm.enumerator(
                at: base,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            var scanned = 0
            while let fileURL = enumerator.nextObject() as? URL {
                scanned += 1
                if scanned > 300 { break }
                guard fileURL.pathExtension.lowercased() == "jsonl" else { continue }
                let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true, let mtime = values?.contentModificationDate else { continue }
                jsonlFiles.append((fileURL, mtime))
            }
            if !jsonlFiles.isEmpty { break }
        }

        guard !jsonlFiles.isEmpty else { return [] }
        jsonlFiles.sort { $0.mtime > $1.mtime }

        var results: [AgentSnapshot] = []
        var seenProjects: Set<String> = []

        for item in jsonlFiles.prefix(limit * 2) {
            let age = Date().timeIntervalSince(item.mtime)
            let state: AgentRunState = age < 20 ? .running : .idle
            let parsed = parseGenericJSONLTail(at: item.url)
            let cwd = parsed.cwd
            let projectKey = cwd ?? item.url.deletingPathExtension().lastPathComponent

            if !state.isActiveOrWaiting && !results.isEmpty {
                if seenProjects.contains(projectKey) || age > 86_400 {
                    continue
                }
            }
            seenProjects.insert(projectKey)

            results.append(AgentSnapshot(
                kind: .custom,
                sessionID: "\(config.id.uuidString):\(item.url.lastPathComponent)",
                agentLabel: label,
                state: state,
                projectName: cwd.map { PathResolver.projectDisplayName(for: $0, watchedFolders: watchedFolders) } ?? item.url.deletingPathExtension().lastPathComponent,
                projectPath: cwd,
                gitBranch: PathResolver.gitBranch(for: cwd),
                modelName: parsed.model ?? "—",
                reasoningEffort: nil,
                sessionTitle: nil,
                usage: UsageMetrics(sessionTotalTokens: parsed.totalTokens),
                lastUpdated: item.mtime,
                resolvedSourcePath: root.path,
                statusMessage: nil
            ))

            if results.count >= limit { break }
        }

        return results
    }

    private static func parseGenericJSONLTail(at url: URL) -> (cwd: String?, model: String?, totalTokens: Int?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, nil, nil) }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        let tailBytes: UInt64 = 32_768
        let offset = fileSize > tailBytes ? fileSize - tailBytes : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else {
            return (nil, nil, nil)
        }

        var cwd: String?
        var model: String?
        var totalTokens: Int?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let lineData = rawLine.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            if cwd == nil {
                cwd = (json["cwd"] as? String) ?? (json["project"] as? String)
            }
            if model == nil {
                model = json["model"] as? String
            }
            if totalTokens == nil, let usage = json["usage"] as? [String: Any] {
                totalTokens = usage["total_tokens"] as? Int
            }
            if cwd != nil, model != nil, totalTokens != nil { break }
        }
        return (cwd, model, totalTokens)
    }

    private static func newestModificationDate(in root: URL, maxDepth: Int) -> Date? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (try? fm.attributesOfItem(atPath: root.path)[.modificationDate]) as? Date
        }
        var latest = (try? fm.attributesOfItem(atPath: root.path)[.modificationDate]) as? Date
        for item in items.prefix(40) {
            if let mtime = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                if latest == nil || mtime > latest! {
                    latest = mtime
                }
            }
        }
        return latest
    }
}
