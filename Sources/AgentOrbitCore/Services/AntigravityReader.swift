import Foundation

enum AntigravityReader {
    static func read(
        rawPath: String,
        watchedFolders: [WatchedFolderStatus],
        modelAliases: [String: String],
        contextWindowOverride: Int = 0
    ) -> AgentSnapshot {
        readSessions(
            rawPath: rawPath,
            watchedFolders: watchedFolders,
            modelAliases: modelAliases,
            contextWindowOverride: contextWindowOverride,
            limit: 1
        ).first ?? .placeholder(.antigravity)
    }

    static func readSessions(
        rawPath: String,
        watchedFolders: [WatchedFolderStatus],
        modelAliases: [String: String],
        contextWindowOverride: Int = 0,
        limit: Int = 8
    ) -> [AgentSnapshot] {
        let expanded = PathResolver.expandTilde(rawPath)
        guard !expanded.isEmpty else {
            return [.placeholder(.antigravity, state: .unavailable, message: "Kein .antigravity Pfad konfiguriert")]
        }

        let resolvedRoot = PathResolver.resolveAntigravityRoot(rawPath)
        guard PathResolver.existsDirectory(resolvedRoot) else {
            let state: AgentRunState = resolvedRoot.path.hasPrefix("/Volumes/") ? .offline : .unavailable
            let msg = state == .offline ? "SSD nicht gemountet (\(resolvedRoot.path))" : "Ordner nicht gefunden"
            return [.placeholder(.antigravity, state: state, message: msg)]
        }

        let statePbtxtURL = resolvedRoot.appendingPathComponent("antigravity_state.pbtxt")
        let rawStateModelID = parseSelectedModel(at: statePbtxtURL)
        let statePbtxtMtime = modificationDate(of: statePbtxtURL)

        let dbURL = resolvedRoot.appendingPathComponent("conversation_summaries.db")
        let fetchCount = max(limit * 2, 12)
        let rows = SQLiteReader.query(
            databaseURL: dbURL,
            sql: """
            SELECT conversation_id, title, workspace_uris, status, step_count, not_fully_idle, last_modified_time
            FROM conversation_summaries
            WHERE killed = 0
            ORDER BY last_modified_time DESC
            LIMIT \(fetchCount)
            """
        )

        let firstConvID = rows.first?["conversation_id"]?.stringValue
        let discoveredModels = discoverModelLabels(in: resolvedRoot, preferredConversationID: firstConvID)

        guard !rows.isEmpty else {
            let fallbackDisplay = resolveModelDisplay(
                rawID: rawStateModelID,
                aliases: modelAliases,
                discoveredModels: discoveredModels
            )
            let (modelName, effort) = splitModelAndEffort(fallbackDisplay)
            return [AgentSnapshot(
                kind: .antigravity,
                state: .idle,
                projectName: "—",
                projectPath: nil,
                gitBranch: nil,
                modelName: modelName,
                reasoningEffort: effort,
                sessionTitle: nil,
                usage: UsageMetrics(),
                lastUpdated: nil,
                resolvedSourcePath: resolvedRoot.path,
                statusMessage: "Keine aktive Konversation"
            )]
        }

        var results: [AgentSnapshot] = []
        var seenProjects: Set<String> = []

        for (index, row) in rows.enumerated() {
            let conversationID = row["conversation_id"]?.stringValue
            let sessionID = conversationID ?? "agy-\(index)"
            let workspacePath = parseWorkspacePath(row["workspace_uris"]?.stringValue)
            let statusRaw = row["status"]?.stringValue ?? ""
            let notFullyIdle = (row["not_fully_idle"]?.intValue ?? 0) != 0
            let isRunning = statusRaw.contains("RUNNING") || notFullyIdle
            let state: AgentRunState = isRunning ? .running : .idle
            let modifiedDate = row["last_modified_time"]?.stringValue.flatMap(parseSQLiteDate)
            let age = modifiedDate.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude

            let projectKey = workspacePath ?? sessionID
            // Always keep running conversations and the primary latest conversation;
            // for idle conversations, deduplicate by project and skip stale (> 24h) ones beyond the first.
            if state != .running && !results.isEmpty {
                if seenProjects.contains(projectKey) || age > 86_400 {
                    continue
                }
            }
            seenProjects.insert(projectKey)

            let activeConvModel = conversationID.flatMap { activeConversationModel(in: resolvedRoot, conversationID: $0) }
            let chosenRawModelID: String?
            if let activeConvModel {
                let stateIsNewer = if let statePbtxtMtime, let convMtime = activeConvModel.mtime {
                    statePbtxtMtime.timeIntervalSince(convMtime) > 2
                } else {
                    false
                }
                chosenRawModelID = stateIsNewer ? (rawStateModelID ?? activeConvModel.enumID) : activeConvModel.enumID
            } else {
                chosenRawModelID = rawStateModelID
            }

            let resolvedDisplay = resolveModelDisplay(
                rawID: chosenRawModelID,
                aliases: modelAliases,
                discoveredModels: discoveredModels
            )
            let (modelName, effort) = splitModelAndEffort(resolvedDisplay)

            let title = row["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            let stepCount = row["step_count"]?.intValue

            var usage = UsageMetrics(stepCount: stepCount)
            var transcriptMtime: Date?

            if let conversationID {
                let transcriptURL = resolvedRoot
                    .appendingPathComponent("brain")
                    .appendingPathComponent(conversationID)
                    .appendingPathComponent(".system_generated/logs/transcript.jsonl")

                if FileManager.default.fileExists(atPath: transcriptURL.path) {
                    let transcriptMetrics = parseTranscriptUsage(at: transcriptURL)
                    usage.inputTokens = transcriptMetrics.inputTokens
                    usage.cacheReadTokens = transcriptMetrics.cacheReadTokens
                    usage.outputTokens = transcriptMetrics.outputTokens
                    usage.sessionTotalTokens = transcriptMetrics.totalTokens
                    usage.contextTokens = transcriptMetrics.latestContextTokens
                    if transcriptMetrics.latestContextTokens != nil,
                       let window = estimatedContextWindow(for: modelName, override: contextWindowOverride) {
                        usage.contextWindow = window
                        usage.isContextWindowEstimated = true
                    }
                    transcriptMtime = (try? FileManager.default.attributesOfItem(atPath: transcriptURL.path)[.modificationDate]) as? Date
                }
            }

            let lastUpdated = [modifiedDate, transcriptMtime].compactMap { $0 }.max()
            let projectName = PathResolver.projectDisplayName(for: workspacePath, watchedFolders: watchedFolders)
            let gitBranch = PathResolver.gitBranch(for: workspacePath)

            results.append(AgentSnapshot(
                kind: .antigravity,
                sessionID: sessionID,
                state: state,
                projectName: projectName,
                projectPath: workspacePath,
                gitBranch: gitBranch,
                modelName: modelName,
                reasoningEffort: effort,
                sessionTitle: title,
                usage: usage,
                lastUpdated: lastUpdated,
                resolvedSourcePath: resolvedRoot.path,
                statusMessage: nil
            ))

            if results.count >= limit {
                break
            }
        }

        return results
    }

    static func parseSelectedModel(at pbtxtURL: URL) -> String? {
        guard let content = try? String(contentsOf: pbtxtURL, encoding: .utf8) else { return nil }
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("last_selected_agent_model:") {
                let raw = trimmed.dropFirst("last_selected_agent_model:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return raw.isEmpty ? nil : raw
            }
        }
        return nil
    }

    static func formatModelName(_ rawID: String?, aliases: [String: String]) -> String {
        resolveModelDisplay(rawID: rawID, aliases: aliases, discoveredModels: [:])
    }

    static func resolveModelDisplay(
        rawID: String?,
        aliases: [String: String],
        discoveredModels: [String: String]
    ) -> String {
        guard let rawID, !rawID.isEmpty else { return "—" }

        // 1. User-defined alias takes precedence
        if let custom = aliases[rawID], !custom.isEmpty {
            return custom
        }
        let cleaned = rawID.replacingOccurrences(of: "MODEL_PLACEHOLDER_", with: "")
        if let customShort = aliases[cleaned], !customShort.isEmpty {
            return customShort
        }

        // 2. Auto-discovered display label from conversations/*.db gen_metadata
        if let discovered = discoveredModels[rawID], !discovered.isEmpty {
            return discovered
        }
        if let discoveredShort = discoveredModels[cleaned], !discoveredShort.isEmpty {
            return discoveredShort
        }

        return cleaned
    }

    static func estimatedContextWindow(for modelName: String, override: Int) -> Int? {
        if override < 0 { return nil }
        if override > 0 { return override }
        let lower = modelName.lowercased()
        if lower.contains("claude") {
            return 200_000
        }
        return 1_000_000
    }

    static func splitModelAndEffort(_ display: String) -> (model: String, effort: String?) {
        let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            trimmed.hasSuffix(")"),
            let openIdx = trimmed.lastIndex(of: "("),
            openIdx > trimmed.startIndex
        else {
            return (trimmed, nil)
        }

        let innerStart = trimmed.index(after: openIdx)
        let innerEnd = trimmed.index(before: trimmed.endIndex)
        let effort = String(trimmed[innerStart..<innerEnd]).trimmingCharacters(in: .whitespaces)
        let baseModel = String(trimmed[..<openIdx]).trimmingCharacters(in: .whitespaces)

        guard !baseModel.isEmpty, !effort.isEmpty, effort.count <= 18, !effort.contains(" ") else {
            return (trimmed, nil)
        }
        return (baseModel, effort)
    }

    static func discoverModelLabels(in resolvedRoot: URL, preferredConversationID: String?) -> [String: String] {
        let conversationsDir = resolvedRoot.appendingPathComponent("conversations")
        guard PathResolver.existsDirectory(conversationsDir) else { return [:] }

        var dbURLs: [URL] = []
        if let preferredConversationID, !preferredConversationID.isEmpty {
            let preferredDB = conversationsDir.appendingPathComponent("\(preferredConversationID).db")
            if FileManager.default.fileExists(atPath: preferredDB.path) {
                dbURLs.append(preferredDB)
            }
        }

        if let entries = try? FileManager.default.contentsOfDirectory(
            at: conversationsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            let sorted = entries
                .filter { $0.pathExtension == "db" }
                .sorted { lhs, rhs in
                    let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return lDate > rDate
                }
            for url in sorted.prefix(30) where !dbURLs.contains(url) {
                dbURLs.append(url)
            }
        }

        var mapping: [String: String] = [:]
        for dbURL in dbURLs {
            let rows = SQLiteReader.query(
                databaseURL: dbURL,
                sql: "SELECT data FROM gen_metadata ORDER BY idx DESC LIMIT 3"
            )
            for row in rows {
                guard
                    let blob = row["data"]?.dataValue,
                    let extracted = extractGenMetadataModel(from: blob)
                else { continue }
                if mapping[extracted.enumID] == nil {
                    mapping[extracted.enumID] = extracted.displayName
                }
            }
        }
        return mapping
    }

    private struct ActiveConvModel {
        let enumID: String
        let displayName: String
        let mtime: Date?
    }

    private static func activeConversationModel(in resolvedRoot: URL, conversationID: String) -> ActiveConvModel? {
        let convDB = resolvedRoot
            .appendingPathComponent("conversations")
            .appendingPathComponent("\(conversationID).db")
        guard FileManager.default.fileExists(atPath: convDB.path) else { return nil }

        let walURL = URL(fileURLWithPath: convDB.path + "-wal")
        let mtime = [modificationDate(of: convDB), modificationDate(of: walURL)].compactMap { $0 }.max()

        let rows = SQLiteReader.query(
            databaseURL: convDB,
            sql: "SELECT data FROM gen_metadata ORDER BY idx DESC LIMIT 5"
        )
        for row in rows {
            if let blob = row["data"]?.dataValue,
               let extracted = extractGenMetadataModel(from: blob) {
                return ActiveConvModel(enumID: extracted.enumID, displayName: extracted.displayName, mtime: mtime)
            }
        }
        return nil
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    static func extractGenMetadataModel(from data: Data) -> (enumID: String, displayName: String)? {
        let tail = data.suffix(512)
        guard !tail.isEmpty else { return nil }

        // Extract `model_enum` value: "model_enum" + 0x12 + <len> + <MODEL_...>
        var enumID: String?
        let marker = Data("model_enum".utf8)
        if let range = tail.range(of: marker) {
            let afterKey = range.upperBound
            if afterKey + 2 < tail.endIndex, tail[afterKey] == 0x12 {
                let len = Int(tail[afterKey + 1])
                let strStart = afterKey + 2
                let strEnd = strStart + len
                if len > 0, strEnd <= tail.endIndex,
                   let str = String(data: tail[strStart..<strEnd], encoding: .utf8),
                   str.hasPrefix("MODEL_") {
                    enumID = str
                }
            }
        }

        // Extract protobuf field 21 (0xAA 0x01 + <len> + <DisplayName>) at tail end
        var displayName: String?
        let tag = Data([0xAA, 0x01])
        var searchStart = tail.startIndex
        while let tagRange = tail.range(of: tag, in: searchStart..<tail.endIndex) {
            let lenIdx = tagRange.upperBound
            if lenIdx < tail.endIndex {
                let len = Int(tail[lenIdx])
                let strStart = lenIdx + 1
                let strEnd = strStart + len
                if len >= 3, len <= 80, strEnd == tail.endIndex,
                   let str = String(data: tail[strStart..<strEnd], encoding: .utf8),
                   str.allSatisfy({ !$0.isNewline && $0.isASCII }) {
                    displayName = str
                }
            }
            searchStart = tagRange.upperBound
        }

        guard let enumID, let displayName else { return nil }
        return (enumID, displayName)
    }

    static func parseWorkspacePath(_ rawJSON: String?) -> String? {
        guard
            let rawJSON,
            let data = rawJSON.data(using: .utf8),
            let uris = try? JSONDecoder().decode([String].self, from: data),
            let first = uris.first
        else {
            return nil
        }
        if first.hasPrefix("file://"), let url = URL(string: first) {
            return url.path
        }
        return first
    }

    struct TranscriptUsage: Sendable, Equatable {
        var inputTokens: Int?
        var cacheReadTokens: Int?
        var outputTokens: Int?
        var totalTokens: Int?
        var latestContextTokens: Int?
    }

    static func parseTranscriptUsage(at url: URL) -> TranscriptUsage {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return TranscriptUsage()
        }
        return parseTranscriptJSONL(text: text)
    }

    static func parseTranscriptJSONL(text: String) -> TranscriptUsage {
        var sumInput = 0
        var sumCache = 0
        var sumOutput = 0
        var lastContext = 0
        var sawUsage = false

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("input_tokens") || line.contains("output_tokens") else { continue }
            guard
                let data = line.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let inp = (obj["input_tokens"] as? NSNumber)?.intValue ?? 0
            let cache = (obj["cache_read_tokens"] as? NSNumber)?.intValue ?? 0
            let out = (obj["output_tokens"] as? NSNumber)?.intValue ?? 0
            if inp > 0 || cache > 0 || out > 0 {
                sawUsage = true
                sumInput += inp
                sumCache += cache
                sumOutput += out
                lastContext = inp + cache + out
            }
        }

        guard sawUsage else { return TranscriptUsage() }
        return TranscriptUsage(
            inputTokens: sumInput,
            cacheReadTokens: sumCache,
            outputTokens: sumOutput,
            totalTokens: sumInput + sumCache + sumOutput,
            latestContextTokens: lastContext
        )
    }

    static func parseSQLiteDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatters = [
            "yyyy-MM-dd HH:mm:ss.SSSSSSXXXXX",
            "yyyy-MM-dd HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd HH:mm:ssXXXXX",
            "yyyy-MM-dd HH:mm:ss"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for pattern in formatters {
            formatter.dateFormat = pattern
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return ISO8601DateFormatter().date(from: trimmed)
    }
}
