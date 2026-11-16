import Foundation

enum CodexReader {
    struct ConfigDefaults: Sendable, Equatable {
        var model: String?
        var reasoningEffort: String?
    }

    struct SessionTailMetrics: Sendable, Equatable {
        var usage: UsageMetrics
        var lastEventDate: Date?
        var hasOpenTurn: Bool = false
        var pendingUserInputTool: String? = nil
        var pendingApprovalTool: String? = nil
    }

    static func read(rawPath: String, watchedFolders: [WatchedFolderStatus]) -> AgentSnapshot {
        readSessions(rawPath: rawPath, watchedFolders: watchedFolders, limit: 1).first
            ?? .placeholder(.codex)
    }

    static func readSessions(
        rawPath: String,
        watchedFolders: [WatchedFolderStatus],
        limit: Int = 8
    ) -> [AgentSnapshot] {
        let expanded = PathResolver.expandTilde(rawPath)
        guard !expanded.isEmpty else {
            return [.placeholder(.codex, state: .unavailable, message: "Kein .codex Pfad konfiguriert")]
        }

        let resolvedRoot = PathResolver.resolveCodexRoot(rawPath)
        guard PathResolver.existsDirectory(resolvedRoot) else {
            let state: AgentRunState = resolvedRoot.path.hasPrefix("/Volumes/") ? .offline : .unavailable
            let msg = state == .offline ? "SSD nicht gemountet (\(resolvedRoot.path))" : "Ordner nicht gefunden"
            return [.placeholder(.codex, state: state, message: msg)]
        }

        let configDefaults = parseConfigToml(at: resolvedRoot.appendingPathComponent("config.toml"))
        let dbURL = resolvedRoot.appendingPathComponent("state_5.sqlite")
        let fetchCount = max(limit * 2, 12)
        let threadColumns = SQLiteReader.query(databaseURL: dbURL, sql: "PRAGMA table_info(threads)")
            .compactMap { $0["name"]?.stringValue }
        let approvalSelect = threadColumns.contains("approval_mode") ? ", approval_mode" : ""
        let rows = SQLiteReader.query(
            databaseURL: dbURL,
            sql: """
            SELECT id, cwd, model, reasoning_effort, tokens_used, git_branch, updated_at, title, rollout_path\(approvalSelect)
            FROM threads
            WHERE archived = 0
            ORDER BY updated_at DESC
            LIMIT \(fetchCount)
            """
        )

        guard !rows.isEmpty else {
            return [AgentSnapshot(
                kind: .codex,
                state: .idle,
                projectName: "—",
                projectPath: nil,
                gitBranch: nil,
                modelName: configDefaults.model ?? "—",
                reasoningEffort: configDefaults.reasoningEffort,
                sessionTitle: nil,
                usage: UsageMetrics(),
                lastUpdated: nil,
                resolvedSourcePath: resolvedRoot.path,
                statusMessage: "Noch keine Session"
            )]
        }

        let hasActiveWriterLock = hasRecentLock(in: resolvedRoot.appendingPathComponent("thread-writer-locks"))
        var results: [AgentSnapshot] = []
        var seenProjects: Set<String> = []

        for (index, row) in rows.enumerated() {
            let threadID = nonEmpty(row["id"]?.stringValue) ?? "codex-\(index)"
            let cwd = row["cwd"]?.stringValue
            let model = nonEmpty(row["model"]?.stringValue) ?? configDefaults.model ?? "—"
            let effort = nonEmpty(row["reasoning_effort"]?.stringValue) ?? configDefaults.reasoningEffort
            let dbTokens = row["tokens_used"]?.intValue
            let dbBranch = nonEmpty(row["git_branch"]?.stringValue)
            let title = nonEmpty(row["title"]?.stringValue)
            let updatedEpoch = row["updated_at"]?.doubleValue
            let updatedAt = updatedEpoch.map { Date(timeIntervalSince1970: $0) }
            let rolloutPath = nonEmpty(row["rollout_path"]?.stringValue)

            let resolvedRollout = resolveRolloutURL(rolloutPath: rolloutPath, codexRoot: resolvedRoot)
            var tailMetrics = resolvedRollout.map { parseSessionTail(at: $0) }
                ?? SessionTailMetrics(usage: UsageMetrics(), lastEventDate: nil)

            if tailMetrics.usage.sessionTotalTokens == nil, let dbTokens {
                tailMetrics.usage.sessionTotalTokens = dbTokens
            }

            let rolloutMtime = resolvedRollout.flatMap {
                (try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate]) as? Date
            }
            let newestTimestamp = [updatedAt, tailMetrics.lastEventDate, rolloutMtime].compactMap { $0 }.max()

            let age = newestTimestamp.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
            let isVeryRecent = age < 20
            let approvalMode = nonEmpty(row["approval_mode"]?.stringValue)?.lowercased()
            let approvalAllowed = (approvalMode != "never")

            let state: AgentRunState
            let interactionReason: String?
            if tailMetrics.pendingUserInputTool != nil, age < 86_400 {
                state = .needsInput
                interactionReason = "Rückfrage"
            } else if tailMetrics.hasOpenTurn,
                      let pendingTool = tailMetrics.pendingApprovalTool,
                      approvalAllowed,
                      age >= 10,
                      age < 7_200 {
                state = .needsInput
                interactionReason = (pendingTool == "apply_patch") ? "Patch-Freigabe" : "Freigabe nötig"
            } else if (hasActiveWriterLock && isVeryRecent) || age < 8 || (tailMetrics.hasOpenTurn && age < 25) {
                state = .running
                interactionReason = nil
            } else {
                state = .idle
                interactionReason = nil
            }

            let projectKey = cwd ?? threadID
            // Always keep active/waiting sessions and the primary latest session;
            // for idle sessions, show at most one per project and skip stale (> 24h) sessions beyond the first.
            if !state.isActiveOrWaiting && !results.isEmpty {
                if seenProjects.contains(projectKey) || age > 86_400 {
                    continue
                }
            }
            seenProjects.insert(projectKey)

            let liveBranch = PathResolver.gitBranch(for: cwd) ?? dbBranch
            let projectName = PathResolver.projectDisplayName(for: cwd, watchedFolders: watchedFolders)

            results.append(AgentSnapshot(
                kind: .codex,
                sessionID: threadID,
                state: state,
                projectName: projectName,
                projectPath: cwd,
                gitBranch: liveBranch,
                modelName: model,
                reasoningEffort: effort,
                sessionTitle: title,
                usage: tailMetrics.usage,
                lastUpdated: newestTimestamp,
                resolvedSourcePath: resolvedRoot.path,
                statusMessage: nil,
                interactionReason: interactionReason
            ))

            if results.count >= limit {
                break
            }
        }

        return results
    }

    static func parseConfigToml(at url: URL) -> ConfigDefaults {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ConfigDefaults()
        }
        var defaults = ConfigDefaults()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("[") { break } // Stop at first TOML section table
            if let eqIndex = line.firstIndex(of: "=") {
                let key = line[..<eqIndex].trimmingCharacters(in: .whitespaces)
                var val = line[line.index(after: eqIndex)...].trimmingCharacters(in: .whitespaces)
                if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 {
                    val = String(val.dropFirst().dropLast())
                }
                if key == "model" {
                    defaults.model = val
                } else if key == "model_reasoning_effort" {
                    defaults.reasoningEffort = val
                }
            }
        }
        return defaults
    }

    static func parseSessionTail(at url: URL, tailBytes: Int = 96_000) -> SessionTailMetrics {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return SessionTailMetrics(usage: UsageMetrics(), lastEventDate: nil)
        }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        let offset = fileSize > UInt64(tailBytes) ? fileSize - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        return parseSessionJSONL(data: data, droppedLeadingPartialLine: offset > 0)
    }

    static func parseSessionJSONL(data: Data, droppedLeadingPartialLine: Bool = false) -> SessionTailMetrics {
        guard let text = String(data: data, encoding: .utf8) else {
            return SessionTailMetrics(usage: UsageMetrics(), lastEventDate: nil)
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if droppedLeadingPartialLine, !lines.isEmpty {
            lines.removeFirst()
        }

        var usage = UsageMetrics()
        var lastDate: Date?
        var hasOpenTurn = false
        var pendingCalls: [String: String] = [:]
        var pendingOrder: [String] = []

        for rawLine in lines {
            guard
                let lineData = rawLine.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            if let ts = json["timestamp"] as? String, let parsed = parseISO8601(ts) {
                lastDate = parsed
            }

            let topType = json["type"] as? String
            guard let payload = json["payload"] as? [String: Any] else { continue }
            let payloadType = payload["type"] as? String

            if topType == "event_msg" {
                switch payloadType {
                case "task_started":
                    hasOpenTurn = true
                    pendingCalls.removeAll()
                    pendingOrder.removeAll()
                case "task_complete", "turn_aborted":
                    hasOpenTurn = false
                    pendingCalls.removeAll()
                    pendingOrder.removeAll()
                case "token_count":
                    if let info = payload["info"] as? [String: Any] {
                        if let total = info["total_token_usage"] as? [String: Any] {
                            usage.sessionTotalTokens = intValue(total["total_tokens"])
                            usage.inputTokens = intValue(total["input_tokens"])
                            usage.cacheReadTokens = intValue(total["cached_input_tokens"])
                            usage.outputTokens = intValue(total["output_tokens"])
                        }
                        if let last = info["last_token_usage"] as? [String: Any] {
                            usage.contextTokens = intValue(last["total_tokens"]) ?? intValue(last["input_tokens"])
                        }
                        usage.contextWindow = intValue(info["model_context_window"])
                    }
                    if let limits = payload["rate_limits"] as? [String: Any] {
                        usage.planType = limits["plan_type"] as? String
                        usage.primaryLimit = parseRateLimitWindow(limits["primary"] as? [String: Any])
                        usage.secondaryLimit = parseRateLimitWindow(limits["secondary"] as? [String: Any])
                    }
                default:
                    break
                }
            } else if topType == "response_item" {
                switch payloadType {
                case "function_call", "custom_tool_call":
                    if let callID = payload["call_id"] as? String,
                       let name = payload["name"] as? String,
                       !callID.isEmpty, !name.isEmpty {
                        hasOpenTurn = true
                        pendingCalls[callID] = name
                        pendingOrder.append(callID)
                    }
                case "function_call_output", "custom_tool_call_output":
                    if let callID = payload["call_id"] as? String {
                        pendingCalls.removeValue(forKey: callID)
                    }
                default:
                    break
                }
            }
        }

        var pendingUserInputTool: String?
        var pendingApprovalTool: String?
        for callID in pendingOrder.reversed() {
            guard let name = pendingCalls[callID] else { continue }
            if pendingUserInputTool == nil,
               name == "request_user_input" || name == "request_user_input_async" {
                pendingUserInputTool = name
            } else if pendingApprovalTool == nil,
                      name == "exec" || name == "exec_command" || name == "apply_patch" {
                pendingApprovalTool = name
            }
        }

        return SessionTailMetrics(
            usage: usage,
            lastEventDate: lastDate,
            hasOpenTurn: hasOpenTurn,
            pendingUserInputTool: pendingUserInputTool,
            pendingApprovalTool: pendingApprovalTool
        )
    }

    private static func resolveRolloutURL(rolloutPath: String?, codexRoot: URL) -> URL? {
        let fm = FileManager.default
        if let rolloutPath {
            let direct = URL(fileURLWithPath: rolloutPath).resolvingSymlinksInPath()
            if fm.fileExists(atPath: direct.path) {
                return direct
            }
            // Fallback if rolloutPath was saved relative to another codex home
            if let range = rolloutPath.range(of: "/sessions/") {
                let relative = String(rolloutPath[range.upperBound...])
                let remapped = codexRoot.appendingPathComponent("sessions").appendingPathComponent(relative)
                if fm.fileExists(atPath: remapped.path) {
                    return remapped
                }
            }
        }
        return nil
    }

    private static func hasRecentLock(in directory: URL) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return false
        }
        let now = Date()
        for item in items {
            if let values = try? item.resourceValues(forKeys: [.contentModificationDateKey]),
               let mtime = values.contentModificationDate,
               now.timeIntervalSince(mtime) < 15 {
                return true
            }
        }
        return false
    }

    private static func parseRateLimitWindow(_ dict: [String: Any]?) -> RateLimitWindow? {
        guard let dict, let pct = doubleValue(dict["used_percent"]), let mins = intValue(dict["window_minutes"]) else {
            return nil
        }
        let reset = doubleValue(dict["resets_at"]).map { Date(timeIntervalSince1970: $0) }
        return RateLimitWindow(usedPercent: pct, windowMinutes: mins, resetsAt: reset)
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func nonEmpty(_ str: String?) -> String? {
        guard let s = str?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    private static func parseISO8601(_ str: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fmt.date(from: str) { return d }
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.date(from: str)
    }
}
