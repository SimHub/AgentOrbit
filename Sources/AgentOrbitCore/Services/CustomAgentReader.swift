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

        // 2. LM Studio Bionic (projects/*/.internal/ng-sessions.sqlite)
        if let bionicSessions = readBionicSessions(
            in: resolvedRoot,
            config: config,
            label: label,
            watchedFolders: watchedFolders,
            limit: limit
        ) {
            return bionicSessions
        }

        // 3. Generic JSONL sessions (e.g. Pi, Claude Code, etc.)
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

        // 4. Generic folder activity fallback
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
        let tables = Set(
            SQLiteReader.query(
                databaseURL: dbURL,
                sql: "SELECT name FROM sqlite_master WHERE type='table'"
            ).compactMap { $0["name"]?.stringValue }
        )

        let useV2 = tables.contains("session_v2")
        let tableName = useV2 ? "session_v2" : "session"
        let columns = Set(
            SQLiteReader.query(databaseURL: dbURL, sql: "PRAGMA table_info(\(tableName))")
                .compactMap { $0["name"]?.stringValue }
        )
        guard columns.contains("id"), columns.contains("time_updated") else { return [] }

        var selectFields = ["id", "directory", "title", "model", "agent", "cost", "tokens_input", "tokens_output", "tokens_cache_read", "time_updated"]
            .filter { columns.contains($0) }
        if useV2 {
            for col in ["time_busy", "time_idle", "time_suspended", "idle_outcome"] where columns.contains(col) {
                selectFields.append(col)
            }
        }
        let whereClause = columns.contains("time_archived") ? "WHERE time_archived IS NULL" : ""
        let rows = SQLiteReader.query(
            databaseURL: dbURL,
            sql: """
            SELECT \(selectFields.joined(separator: ", "))
            FROM \(tableName)
            \(whereClause)
            ORDER BY time_updated DESC
            LIMIT \(fetchCount)
            """
        )

        let hasSessionMessage = tables.contains("session_message")
        let hasLegacyMessage = tables.contains("message")
        var results: [AgentSnapshot] = []
        var seenProjects: Set<String> = []

        for (index, row) in rows.enumerated() {
            let sid = row["id"]?.stringValue ?? "\(config.id.uuidString)-\(index)"
            let directory = row["directory"]?.stringValue
            let title = row["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            let parsedModel = parseOpenCodeModel(row["model"]?.stringValue)

            let updatedAt = decodeOpenCodeEpoch(row["time_updated"]?.doubleValue)
            let busyAt = decodeOpenCodeEpoch(row["time_busy"]?.doubleValue)
            let idleAt = decodeOpenCodeEpoch(row["time_idle"]?.doubleValue)
            let suspendedAt = decodeOpenCodeEpoch(row["time_suspended"]?.doubleValue)

            let newestDate = [updatedAt, busyAt, idleAt, suspendedAt].compactMap { $0 }.max()
            let age = newestDate.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude

            let (state, interactionReason) = resolveOpenCodeState(
                dbURL: dbURL,
                sessionID: sid,
                useV2: useV2,
                hasSessionMessage: hasSessionMessage,
                hasLegacyMessage: hasLegacyMessage,
                updatedAt: updatedAt,
                busyAt: busyAt,
                idleAt: idleAt,
                suspendedAt: suspendedAt,
                age: age
            )

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

            let snapshotLastUpdated: Date? = if state == .running, let busyAt, (idleAt == nil || busyAt > idleAt!) {
                max(busyAt, updatedAt ?? busyAt)
            } else {
                newestDate
            }

            results.append(AgentSnapshot(
                kind: .custom,
                sessionID: "\(config.id.uuidString):\(sid)",
                agentLabel: label,
                state: state,
                projectName: PathResolver.projectDisplayName(for: directory, watchedFolders: watchedFolders),
                projectPath: directory,
                gitBranch: PathResolver.gitBranch(for: directory),
                modelName: parsedModel.model,
                reasoningEffort: parsedModel.effort,
                sessionTitle: title,
                usage: usage,
                lastUpdated: snapshotLastUpdated,
                resolvedSourcePath: dbURL.deletingLastPathComponent().path,
                statusMessage: nil,
                interactionReason: interactionReason
            ))

            if results.count >= limit {
                break
            }
        }

        return results
    }

    private static func decodeOpenCodeEpoch(_ rawTime: Double?) -> Date? {
        guard let rawTime, rawTime > 0 else { return nil }
        // OpenCode stores Unix timestamps in milliseconds
        return rawTime > 10_000_000_000
            ? Date(timeIntervalSince1970: rawTime / 1000.0)
            : Date(timeIntervalSince1970: rawTime)
    }

    private static func parseOpenCodeModel(_ raw: String?) -> (model: String, effort: String?) {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return ("—", nil)
        }
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = (json["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !id.isEmpty {
            let variant = (json["variant"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let effort = (variant?.isEmpty == false && variant?.lowercased() != "default") ? variant : nil
            return (id, effort)
        }
        return (trimmed, nil)
    }

    private static func resolveOpenCodeState(
        dbURL: URL,
        sessionID: String,
        useV2: Bool,
        hasSessionMessage: Bool,
        hasLegacyMessage: Bool,
        updatedAt: Date?,
        busyAt: Date?,
        idleAt: Date?,
        suspendedAt: Date?,
        age: TimeInterval
    ) -> (AgentRunState, String?) {
        let escapedSID = sessionID.replacingOccurrences(of: "'", with: "''")

        if useV2 {
            // Check explicit suspension (e.g. awaiting input/resume) after latest idle
            if let suspendedAt, (idleAt == nil || suspendedAt > idleAt!), age < 86_400 {
                return (.needsInput, "Pausiert / Eingabe")
            }

            let isBusy = if let busyAt {
                idleAt == nil || busyAt > idleAt!
            } else {
                false
            }

            if isBusy {
                if hasSessionMessage {
                    let msgRows = SQLiteReader.query(
                        databaseURL: dbURL,
                        sql: "SELECT type, data FROM session_message WHERE session_id = '\(escapedSID)' ORDER BY seq DESC LIMIT 1"
                    )
                    if let latestMsg = msgRows.first,
                       latestMsg["type"]?.stringValue == "assistant",
                       let dataStr = latestMsg["data"]?.stringValue,
                       let data = dataStr.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let content = json["content"] as? [[String: Any]] {
                        let hasQuestionTool = content.contains { item in
                            (item["type"] as? String) == "tool"
                                && ((item["name"] as? String) == "question" || (item["name"] as? String) == "ask_user")
                        }
                        if hasQuestionTool {
                            return (.needsInput, "Rückfrage")
                        }
                    }
                }
                // Guard against stale orphan busy rows older than 6 hours without updates
                if age < 21_600 {
                    return (.running, nil)
                }
            }
            return (.idle, nil)
        }

        // Legacy OpenCode v1 schema fallback: inspect latest message completion + timestamp
        if hasLegacyMessage, age < 600 {
            let msgRows = SQLiteReader.query(
                databaseURL: dbURL,
                sql: "SELECT data FROM message WHERE session_id = '\(escapedSID)' ORDER BY time_updated DESC LIMIT 1"
            )
            if let dataStr = msgRows.first?["data"]?.stringValue,
               let data = dataStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (json["role"] as? String) == "assistant",
               let timeObj = json["time"] as? [String: Any],
               timeObj["completed"] == nil {
                return (.running, nil)
            }
        }

        return (age < 20 ? .running : .idle, nil)
    }

    private static func readBionicSessions(
        in root: URL,
        config: CustomAgentConfig,
        label: String,
        watchedFolders: [WatchedFolderStatus],
        limit: Int
    ) -> [AgentSnapshot]? {
        let fm = FileManager.default
        var projectSources: [(dbURL: URL, projectNameHint: String?)] = []

        let projectsDir = root.appendingPathComponent("projects")
        if PathResolver.existsDirectory(projectsDir),
           let dirs = try? fm.contentsOfDirectory(
               at: projectsDir,
               includingPropertiesForKeys: [.isDirectoryKey],
               options: [.skipsHiddenFiles]
           ) {
            for dir in dirs {
                let dbURL = dir.appendingPathComponent(".internal/ng-sessions.sqlite")
                if fm.fileExists(atPath: dbURL.path) {
                    let hint = parseBionicProjectName(at: dir.appendingPathComponent("project.json"))
                    projectSources.append((dbURL, hint))
                }
            }
        }

        // Also support pointing directly at a Bionic project folder or ng-sessions.sqlite file
        if projectSources.isEmpty {
            let candidates = [
                root.appendingPathComponent(".internal/ng-sessions.sqlite"),
                root.appendingPathComponent("ng-sessions.sqlite"),
                root
            ]
            for candidate in candidates where candidate.lastPathComponent == "ng-sessions.sqlite" && fm.fileExists(atPath: candidate.path) {
                let projectDir = candidate.deletingLastPathComponent().lastPathComponent == ".internal"
                    ? candidate.deletingLastPathComponent().deletingLastPathComponent()
                    : candidate.deletingLastPathComponent()
                let hint = parseBionicProjectName(at: projectDir.appendingPathComponent("project.json"))
                projectSources.append((candidate, hint))
                break
            }
        }

        guard !projectSources.isEmpty else { return nil }

        var allCollected: [AgentSnapshot] = []
        for source in projectSources {
            let dbRows = SQLiteReader.query(
                databaseURL: source.dbURL,
                sql: "PRAGMA table_info(sessions)"
            ).compactMap { $0["name"]?.stringValue }
            guard dbRows.contains("session_id"), dbRows.contains("session_json") else { continue }

            let columns = Set(dbRows)
            let parentFilter = columns.contains("parent_session_id") ? "WHERE parent_session_id IS NULL" : ""
            let orderClause = columns.contains("updated_timestamp") ? "ORDER BY updated_timestamp DESC" : ""
            let sessionRows = SQLiteReader.query(
                databaseURL: source.dbURL,
                sql: """
                SELECT session_id, session_name, committed_head_entry_id, session_json, updated_timestamp
                FROM sessions
                \(parentFilter)
                \(orderClause)
                LIMIT 8
                """
            )

            let walURL = URL(fileURLWithPath: source.dbURL.path + "-wal")
            let dbMtime = [modificationDate(of: source.dbURL), modificationDate(of: walURL)].compactMap { $0 }.max()

            for (idx, row) in sessionRows.enumerated() {
                let sid = row["session_id"]?.stringValue ?? "bionic-\(idx)"
                let sessionName = row["session_name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                let headEntryID = row["committed_head_entry_id"]?.stringValue
                let updatedAt = decodeOpenCodeEpoch(row["updated_timestamp"]?.doubleValue) ?? dbMtime

                guard
                    let jsonText = row["session_json"]?.stringValue,
                    let jsonData = jsonText.data(using: .utf8),
                    let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
                else { continue }

                // Skip internal companion/sub-sessions if marked
                if let subType = json["subSessionType"] as? String, !subType.isEmpty {
                    continue
                }

                let workingDir = (json["sessionParams"] as? [String: Any])?["working_directory"] as? String
                let rawModelID = (json["modelSpecifier"] as? [String: Any])?["indexedModelIdentifier"] as? String
                let modelName = formatBionicModelName(rawModelID)
                let reasoningEffort = ((json["inferenceConfig"] as? [String: Any])?["reasoningLevel"] as? String)
                    .flatMap { $0.isEmpty ? nil : $0 }
                let totalTokens = ((json["contextEstimation"] as? [String: Any])?["total"] as? NSNumber)?.intValue

                let age = updatedAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
                let (state, interactionReason) = resolveBionicState(
                    dbURL: source.dbURL,
                    headEntryID: headEntryID,
                    age: age
                )

                let projectName: String = if let workingDir, !workingDir.isEmpty {
                    PathResolver.projectDisplayName(for: workingDir, watchedFolders: watchedFolders)
                } else if let hint = source.projectNameHint, !hint.isEmpty, hint != "No Project" {
                    hint
                } else {
                    label
                }

                allCollected.append(AgentSnapshot(
                    kind: .custom,
                    sessionID: "\(config.id.uuidString):\(sid)",
                    agentLabel: label,
                    state: state,
                    projectName: projectName,
                    projectPath: workingDir,
                    gitBranch: PathResolver.gitBranch(for: workingDir),
                    modelName: modelName,
                    reasoningEffort: reasoningEffort,
                    sessionTitle: sessionName,
                    usage: UsageMetrics(
                        sessionTotalTokens: totalTokens,
                        contextTokens: totalTokens
                    ),
                    lastUpdated: updatedAt,
                    resolvedSourcePath: source.dbURL.deletingLastPathComponent().path,
                    statusMessage: nil,
                    interactionReason: interactionReason
                ))
            }
        }

        guard !allCollected.isEmpty else {
            return [
                AgentSnapshot(
                    kind: .custom,
                    sessionID: config.id.uuidString,
                    agentLabel: label,
                    state: .idle,
                    projectName: "—",
                    projectPath: nil,
                    gitBranch: nil,
                    modelName: "—",
                    reasoningEffort: nil,
                    sessionTitle: nil,
                    usage: UsageMetrics(),
                    lastUpdated: nil,
                    resolvedSourcePath: root.path,
                    statusMessage: "Noch keine Bionic-Session"
                )
            ]
        }

        // Sort active/waiting first, then newest
        let sorted = allCollected.sorted { lhs, rhs in
            if lhs.state.isActiveOrWaiting != rhs.state.isActiveOrWaiting {
                return lhs.state.isActiveOrWaiting && !rhs.state.isActiveOrWaiting
            }
            return (lhs.lastUpdated ?? .distantPast) > (rhs.lastUpdated ?? .distantPast)
        }

        var results: [AgentSnapshot] = []
        var seenProjects: Set<String> = []
        for snap in sorted {
            let age = snap.lastUpdated.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
            let key = snap.projectPath ?? snap.projectName
            if !snap.state.isActiveOrWaiting && !results.isEmpty {
                if seenProjects.contains(key) || age > 86_400 {
                    continue
                }
            }
            seenProjects.insert(key)
            results.append(snap)
            if results.count >= limit { break }
        }
        return results
    }

    private static func parseBionicProjectName(at url: URL) -> String? {
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let name = json["name"] as? String
        else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func formatBionicModelName(_ raw: String?) -> String {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return "—"
        }
        if let last = trimmed.split(separator: "/").last, !last.isEmpty {
            return String(last)
        }
        return trimmed
    }

    private static func resolveBionicState(
        dbURL: URL,
        headEntryID: String?,
        age: TimeInterval
    ) -> (AgentRunState, String?) {
        guard var currentID = headEntryID, !currentID.isEmpty else {
            return (age < 20 ? .running : .idle, nil)
        }

        var tipEntryJSON: String?
        // Follow any uncommitted child entries appended after committed_head_entry_id (bounded hops)
        for _ in 0..<8 {
            let escaped = currentID.replacingOccurrences(of: "'", with: "''")
            let childRows = SQLiteReader.query(
                databaseURL: dbURL,
                sql: "SELECT id, entry_json FROM chat_entries WHERE previous_id = '\(escaped)' ORDER BY rowid DESC LIMIT 1"
            )
            if let child = childRows.first,
               let nextID = child["id"]?.stringValue,
               nextID != currentID {
                currentID = nextID
                tipEntryJSON = child["entry_json"]?.stringValue
            } else {
                break
            }
        }

        if tipEntryJSON == nil {
            let escaped = currentID.replacingOccurrences(of: "'", with: "''")
            let headRows = SQLiteReader.query(
                databaseURL: dbURL,
                sql: "SELECT entry_json FROM chat_entries WHERE id = '\(escaped)' LIMIT 1"
            )
            tipEntryJSON = headRows.first?["entry_json"]?.stringValue
        }

        guard
            let tipStr = tipEntryJSON,
            let tipData = tipStr.data(using: .utf8),
            let entry = try? JSONSerialization.jsonObject(with: tipData) as? [String: Any],
            let entryType = entry["type"] as? String
        else {
            return (age < 20 ? .running : .idle, nil)
        }

        switch entryType {
        case "elicitationRequest":
            return age < 86_400 ? (.needsInput, "Rückfrage") : (.idle, nil)
        case "forkPoint":
            if (entry["forkPoint"] as? String) == "assistantTurnEnd" {
                return (.idle, nil)
            }
            return age < 21_600 ? (.running, nil) : (.idle, nil)
        case "interrupted", "error":
            return (.idle, nil)
        default:
            // Active entries before assistantTurnEnd (message, stateChange, turnSummary, etc.)
            return age < 21_600 ? (.running, nil) : (.idle, nil)
        }
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
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
