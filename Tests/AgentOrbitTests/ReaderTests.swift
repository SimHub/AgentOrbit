import Foundation
import SQLite3
@testable import AgentOrbitCore

private enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String {
        switch self {
        case .assertion(let msg): return msg
        }
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String = "", line: Int = #line) throws {
    if actual != expected {
        throw TestFailure.assertion("Line \(line) \(label): expected \(expected), got \(actual)")
    }
}

private func expectTrue(_ condition: Bool, _ label: String = "", line: Int = #line) throws {
    if !condition {
        throw TestFailure.assertion("Line \(line) \(label): expected true")
    }
}

private func expectNotNil<T>(_ value: T?, _ label: String = "", line: Int = #line) throws {
    if value == nil {
        throw TestFailure.assertion("Line \(line) \(label): expected non-nil")
    }
}

@main
struct ReaderTestRunner {
    static func main() {
        let suite: [(String, (URL) throws -> Void)] = [
            ("testCodexConfigTomlParsing", testCodexConfigTomlParsing),
            ("testCodexSessionJSONLParsing", testCodexSessionJSONLParsing),
            ("testAntigravityParsingAndAliases", testAntigravityParsingAndAliases),
            ("testSymlinkAndGitBranchResolution", testSymlinkAndGitBranchResolution),
            ("testCodexReaderEndToEndWithSQLite", testCodexReaderEndToEndWithSQLite),
            ("testAntigravityReaderEndToEndWithSQLite", testAntigravityReaderEndToEndWithSQLite),
            ("testGridSnapCalculator", testGridSnapCalculator),
            ("testActiveStartTimeTracking", testActiveStartTimeTracking),
            ("testCompletionTransitionDetection", testCompletionTransitionDetection),
            ("testAgentDiscovery", testAgentDiscovery),
            ("testCostEstimator", testCostEstimator),
            ("testCodexNeedsInputDetection", testCodexNeedsInputDetection),
            ("testAntigravityWaitingStepDetection", testAntigravityWaitingStepDetection),
            ("testNeedsInputTransitionDetection", testNeedsInputTransitionDetection),
            ("testOpenCodeV2SessionDetection", testOpenCodeV2SessionDetection)
        ]

        var passed = 0
        var failed = 0

        for (name, body) in suite {
            let tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("AgentKoordinatorTests-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: tempRoot) }
                try body(tempRoot)
                print("PASS \(name)")
                passed += 1
            } catch {
                print("FAIL \(name): \(error)")
                failed += 1
            }
        }

        print("Summary: \(passed) passed, \(failed) failed")
        if failed > 0 {
            exit(1)
        }
    }

    static func testCodexConfigTomlParsing(tempRoot: URL) throws {
        let tomlURL = tempRoot.appendingPathComponent("config.toml")
        let content = """
        allow_symlinked_codex_home = true
        model = "gpt-6.1-sol"
        model_reasoning_effort = "high"

        [mcp_servers.demo]
        model = "should-ignore-nested"
        """
        try content.write(to: tomlURL, atomically: true, encoding: .utf8)

        let parsed = CodexReader.parseConfigToml(at: tomlURL)
        try expectEqual(parsed.model, "gpt-6.1-sol")
        try expectEqual(parsed.reasoningEffort, "high")
    }

    static func testCodexSessionJSONLParsing(tempRoot: URL) throws {
        let jsonl = """
        partial_leading_garbage_to_drop
        {"timestamp":"2026-11-15T00:19:20.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10000,"cached_input_tokens":8000,"output_tokens":500,"total_tokens":10500},"last_token_usage":{"input_tokens":1200,"output_tokens":150,"total_tokens":1350},"model_context_window":475000},"rate_limits":{"plan_type":"plus","primary":{"used_percent":42.0,"window_minutes":300,"resets_at":1794705903},"secondary":{"used_percent":18.0,"window_minutes":10080,"resets_at":1795126849}}}}
        """
        let metrics = CodexReader.parseSessionJSONL(
            data: Data(jsonl.utf8),
            droppedLeadingPartialLine: true
        )

        try expectEqual(metrics.usage.sessionTotalTokens, 10500)
        try expectEqual(metrics.usage.contextTokens, 1350)
        try expectEqual(metrics.usage.contextWindow, 475000)
        try expectEqual(metrics.usage.planType, "plus")
        try expectEqual(metrics.usage.primaryLimit?.usedPercent, 42.0)
        try expectEqual(metrics.usage.primaryLimit?.windowMinutes, 300)
        try expectEqual(metrics.usage.secondaryLimit?.usedPercent, 18.0)
        try expectEqual(metrics.usage.secondaryLimit?.windowMinutes, 10080)
        try expectNotNil(metrics.lastEventDate)
    }

    static func testAntigravityParsingAndAliases(tempRoot: URL) throws {
        let pbtxtURL = tempRoot.appendingPathComponent("antigravity_state.pbtxt")
        try "last_selected_agent_model: MODEL_PLACEHOLDER_M525\n"
            .write(to: pbtxtURL, atomically: true, encoding: .utf8)

        let rawModel = AntigravityReader.parseSelectedModel(at: pbtxtURL)
        try expectEqual(rawModel, "MODEL_PLACEHOLDER_M525")
        try expectEqual(AntigravityReader.formatModelName(rawModel, aliases: [:]), "M525")
        try expectEqual(
            AntigravityReader.formatModelName(rawModel, aliases: ["M525": "Gemini 4 Hydrogen"]),
            "Gemini 4 Hydrogen"
        )

        let workspace = AntigravityReader.parseWorkspacePath("[\"file:///Volumes/ExternalSSD/DemoProject\"]")
        try expectEqual(workspace, "/Volumes/ExternalSSD/DemoProject")

        let transcript = """
        {"step_index":1,"type":"USER_INPUT","content":"hi"}
        {"step_index":2,"type":"PLANNER_RESPONSE","input_tokens":1200,"cache_read_tokens":800,"output_tokens":200}
        {"step_index":3,"type":"PLANNER_RESPONSE","input_tokens":1500,"cache_read_tokens":900,"output_tokens":300}
        """
        let usage = AntigravityReader.parseTranscriptJSONL(text: transcript)
        try expectEqual(usage.inputTokens, 2700)
        try expectEqual(usage.cacheReadTokens, 1700)
        try expectEqual(usage.outputTokens, 500)
        try expectEqual(usage.totalTokens, 4900)
        try expectEqual(usage.latestContextTokens, 2700)

        let split1 = AntigravityReader.splitModelAndEffort("Gemini 4 Hydrogen (Medium)")
        try expectEqual(split1.model, "Gemini 4 Hydrogen")
        try expectEqual(split1.effort, "Medium")

        var proto = Data("prefix".utf8)
        let enumVal = Data("MODEL_PLACEHOLDER_M526".utf8)
        proto.append(Data("model_enum".utf8))
        proto.append(contentsOf: [0x12, UInt8(enumVal.count)])
        proto.append(enumVal)
        let labelVal = Data("Gemini 4 Hydrogen (Medium)".utf8)
        proto.append(contentsOf: [0xAA, 0x01, UInt8(labelVal.count)])
        proto.append(labelVal)

        let extracted = AntigravityReader.extractGenMetadataModel(from: proto)
        try expectEqual(extracted?.enumID, "MODEL_PLACEHOLDER_M526")
        try expectEqual(extracted?.displayName, "Gemini 4 Hydrogen (Medium)")
    }

    static func testSymlinkAndGitBranchResolution(tempRoot: URL) throws {
        let realProject = tempRoot.appendingPathComponent("real-project")
        let gitDir = realProject.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "ref: refs/heads/feature/menu-bar\n"
            .write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

        let symlinkedProject = tempRoot.appendingPathComponent("linked-project")
        try FileManager.default.createSymbolicLink(at: symlinkedProject, withDestinationURL: realProject)

        try expectEqual(PathResolver.gitBranch(for: symlinkedProject.path), "feature/menu-bar")

        let status = PathResolver.inspectWatchedFolder(symlinkedProject.path)
        try expectTrue(status.isOnline)
        try expectEqual(status.gitBranch, "feature/menu-bar")
        try expectEqual(status.resolvedPath, realProject.resolvingSymlinksInPath().path)
    }

    static func testCodexReaderEndToEndWithSQLite(tempRoot: URL) throws {
        let codexDir = tempRoot.appendingPathComponent("codex-home")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        try "model = \"gpt-6.1-sol\"\n".write(to: codexDir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let dbURL = codexDir.appendingPathComponent("state_5.sqlite")
        try execSQL(
            at: dbURL,
            sql: """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                cwd TEXT NOT NULL,
                model TEXT,
                reasoning_effort TEXT,
                tokens_used INTEGER NOT NULL DEFAULT 0,
                git_branch TEXT,
                updated_at INTEGER NOT NULL,
                title TEXT NOT NULL,
                rollout_path TEXT NOT NULL,
                archived INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO threads (id, cwd, model, reasoning_effort, tokens_used, git_branch, updated_at, title, rollout_path, archived)
            VALUES ('t1', '/tmp/my-app', 'gpt-6.1-sol', 'medium', 42000, 'main', \(Int(Date().timeIntervalSince1970)), 'Test', '', 0);
            """
        )

        let snapshot = CodexReader.read(rawPath: codexDir.path, watchedFolders: [])
        try expectEqual(snapshot.projectName, "my-app")
        try expectEqual(snapshot.modelName, "gpt-6.1-sol")
        try expectEqual(snapshot.reasoningEffort, "medium")
        try expectEqual(snapshot.gitBranch, "main")
        try expectEqual(snapshot.usage.sessionTotalTokens, 42000)
        try expectEqual(snapshot.state, .running)
    }

    static func testAntigravityReaderEndToEndWithSQLite(tempRoot: URL) throws {
        let agDir = tempRoot.appendingPathComponent("antigravity-home")
        let logsDir = agDir.appendingPathComponent("brain/conv-1/.system_generated/logs")
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        try "last_selected_agent_model: MODEL_PLACEHOLDER_M525\n"
            .write(to: agDir.appendingPathComponent("antigravity_state.pbtxt"), atomically: true, encoding: .utf8)

        try """
        {"step_index":1,"type":"PLANNER_RESPONSE","input_tokens":500,"cache_read_tokens":100,"output_tokens":50}
        """.write(to: logsDir.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)

        let dbURL = agDir.appendingPathComponent("conversation_summaries.db")
        try execSQL(
            at: dbURL,
            sql: """
            CREATE TABLE conversation_summaries (
                conversation_id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                workspace_uris TEXT NOT NULL,
                status TEXT NOT NULL,
                step_count INTEGER NOT NULL,
                not_fully_idle INTEGER NOT NULL,
                killed INTEGER NOT NULL,
                last_modified_time TEXT NOT NULL
            );
            INSERT INTO conversation_summaries
            VALUES ('conv-1', 'Test Conv', '["file:///tmp/demo-repo"]', 'CASCADE_RUN_STATUS_RUNNING', 12, 1, 0, '2026-11-15 00:20:00.000000+00:00');
            """
        )

        let snapshot = AntigravityReader.read(
            rawPath: agDir.path,
            watchedFolders: [],
            modelAliases: ["M525": "Gemini 4 Hydrogen (High)"]
        )
        try expectEqual(snapshot.projectName, "demo-repo")
        try expectEqual(snapshot.modelName, "Gemini 4 Hydrogen")
        try expectEqual(snapshot.reasoningEffort, "High")
        try expectEqual(snapshot.state, .running)
        try expectEqual(snapshot.usage.stepCount, 12)
        try expectEqual(snapshot.usage.sessionTotalTokens, 650)
        try expectEqual(snapshot.usage.contextTokens, 650)
        try expectEqual(snapshot.usage.contextWindow, 1_000_000)
        try expectTrue(snapshot.usage.isContextWindowEstimated)

        // Verify active conversation's gen_metadata wins over older antigravity_state.pbtxt
        let convDir = agDir.appendingPathComponent("conversations")
        try FileManager.default.createDirectory(at: convDir, withIntermediateDirectories: true)
        let convDB = convDir.appendingPathComponent("conv-1.db")
        try execSQL(at: convDB, sql: "CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB);")

        var proto = Data("prefix".utf8)
        let enumVal = Data("MODEL_PLACEHOLDER_M525".utf8)
        proto.append(Data("model_enum".utf8))
        proto.append(contentsOf: [0x12, UInt8(enumVal.count)])
        proto.append(enumVal)
        let labelVal = Data("Gemini 4 Hydrogen (High)".utf8)
        proto.append(contentsOf: [0xAA, 0x01, UInt8(labelVal.count)])
        proto.append(labelVal)

        var db: OpaquePointer?
        try expectEqual(sqlite3_open(convDB.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        try expectEqual(sqlite3_prepare_v2(db, "INSERT INTO gen_metadata (idx, data) VALUES (1, ?)", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        _ = proto.withUnsafeBytes { bytes in
            sqlite3_bind_blob(stmt, 1, bytes.baseAddress, Int32(proto.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        try expectEqual(sqlite3_step(stmt), SQLITE_DONE)

        // Backdate pbtxt so convDB is strictly newer
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-600)],
            ofItemAtPath: agDir.appendingPathComponent("antigravity_state.pbtxt").path
        )

        let autoSnap = AntigravityReader.read(rawPath: agDir.path, watchedFolders: [], modelAliases: [:])
        try expectEqual(autoSnap.modelName, "Gemini 4 Hydrogen")
        try expectEqual(autoSnap.reasoningEffort, "High")
    }

    static func testGridSnapCalculator(tempRoot: URL) throws {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // Top-right corner magnet snap (margin 12 -> maxX = 1428 - 360 = 1068, maxY = 888 - 200 = 688)
        let nearTopRight = CGRect(x: 1055, y: 678, width: 360, height: 200)
        let topRightSnap = GridSnapCalculator.snap(frame: nearTopRight, visibleFrame: visible)
        try expectEqual(topRightSnap.origin, CGPoint(x: 1068, y: 688))
        try expectEqual(topRightSnap.horizontalAnchor, .trailing)
        try expectEqual(topRightSnap.verticalAnchor, .top)
        try expectTrue(topRightSnap.isSnappedToAnchor)

        // 24pt grid snap away from anchors (safe minX = 12, minY = 12 -> 12 + 24*4 = 108)
        let midField = CGRect(x: 114, y: 115, width: 360, height: 200)
        let gridSnap = GridSnapCalculator.snap(frame: midField, visibleFrame: visible)
        try expectEqual(gridSnap.origin, CGPoint(x: 108, y: 108))
        try expectTrue(!gridSnap.isSnappedToAnchor)

        // Anchored expansion grows leftward when anchored trailing
        let expandedOrigin = GridSnapCalculator.anchoredOrigin(
            size: CGSize(width: 640, height: 220),
            visibleFrame: visible,
            horizontalAnchor: .trailing,
            verticalAnchor: .top,
            anchoredMinX: 1068,
            anchoredMaxX: 1428,
            anchoredMinY: 688,
            anchoredMaxY: 888
        )
        try expectEqual(expandedOrigin, CGPoint(x: 788, y: 668))
    }

    static func testActiveStartTimeTracking(tempRoot: URL) throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(45)
        var starts: [String: Date] = [:]

        let liveSnap = AgentSnapshot(
            kind: .codex,
            sessionID: "s1",
            state: .running,
            projectName: "AgentOrbit",
            projectPath: nil,
            gitBranch: nil,
            modelName: "gpt-5",
            reasoningEffort: nil,
            sessionTitle: nil,
            usage: UsageMetrics(),
            lastUpdated: t0.addingTimeInterval(-5),
            resolvedSourcePath: nil,
            statusMessage: nil
        )

        let first = CoordinatorMonitor.reconcileActiveStartTimes(
            sessions: [liveSnap],
            activeStartTimes: &starts,
            now: t0
        )
        try expectEqual(first.first?.activeSince, t0.addingTimeInterval(-5))

        // Subsequent refresh preserves original activeSince
        var liveLater = liveSnap
        liveLater.lastUpdated = t1
        let second = CoordinatorMonitor.reconcileActiveStartTimes(
            sessions: [liveLater],
            activeStartTimes: &starts,
            now: t1
        )
        try expectEqual(second.first?.activeSince, t0.addingTimeInterval(-5))

        // Transitioning to idle clears activeSince and start entry
        var idleSnap = liveLater
        idleSnap.state = .idle
        let third = CoordinatorMonitor.reconcileActiveStartTimes(
            sessions: [idleSnap],
            activeStartTimes: &starts,
            now: t1.addingTimeInterval(10)
        )
        try expectEqual(third.first?.activeSince, nil)
        try expectTrue(starts.isEmpty)
    }

    static func testCompletionTransitionDetection(tempRoot: URL) throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let running = AgentSnapshot(
            kind: .antigravity,
            sessionID: "c1",
            state: .running,
            projectName: "AgentOrbit",
            projectPath: nil,
            gitBranch: nil,
            modelName: "Gemini 4",
            reasoningEffort: nil,
            sessionTitle: nil,
            usage: UsageMetrics(),
            lastUpdated: t0,
            activeSince: t0,
            resolvedSourcePath: nil,
            statusMessage: nil
        )
        var idle = running
        idle.state = .idle
        idle.activeSince = nil

        // Ignore ultra-short flicker (< 3s)
        let tooShort = CoordinatorMonitor.detectCompletedSessions(
            previous: [running],
            current: [idle],
            activeStartTimes: [running.id: t0],
            now: t0.addingTimeInterval(1)
        )
        try expectTrue(tooShort.isEmpty)

        // Emit completion event once elapsed >= 3s
        let valid = CoordinatorMonitor.detectCompletedSessions(
            previous: [running],
            current: [idle],
            activeStartTimes: [running.id: t0],
            now: t0.addingTimeInterval(42)
        )
        try expectEqual(valid.count, 1)
        try expectEqual(valid.first?.agentLabel, "Antigravity")
        try expectEqual(valid.first?.projectName, "AgentOrbit")
        try expectEqual(valid.first?.durationSeconds, 42)
    }

    static func testAgentDiscovery(tempRoot: URL) throws {
        let fakeHome = tempRoot.appendingPathComponent("fake-home")
        let fm = FileManager.default
        try fm.createDirectory(at: fakeHome.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try fm.createDirectory(at: fakeHome.appendingPathComponent(".local/share/opencode"), withIntermediateDirectories: true)
        try Data().write(to: fakeHome.appendingPathComponent(".local/share/opencode/opencode.db"))
        // Empty .claude without projects/sessions should NOT be auto-added
        try fm.createDirectory(at: fakeHome.appendingPathComponent(".claude"), withIntermediateDirectories: true)

        let result = AgentDiscovery.discover(homeDirectory: fakeHome)
        try expectTrue(result.hasCodex)
        try expectTrue(!result.hasAntigravity)
        try expectEqual(result.customAgents.map(\.name), ["OpenCode"])
    }

    static func testCostEstimator(tempRoot: URL) throws {
        // Recorded cost takes precedence
        let recorded = UsageMetrics(inputTokens: 100_000, outputTokens: 10_000, recordedCostUSD: 0.42)
        let exact = CostEstimator.estimate(usage: recorded, modelName: "gpt-5")
        try expectEqual(exact?.isEstimated, false)
        try expectEqual(exact?.formatted, "$0.42")

        // Estimated from Antigravity-style separate token sums (1M input + 200k output on Gemini Pro -> 1.25 + 2.00 = $3.25)
        let agyUsage = UsageMetrics(sessionTotalTokens: 1_200_000, inputTokens: 1_000_000, cacheReadTokens: 0, outputTokens: 200_000)
        let agyCost = CostEstimator.estimate(usage: agyUsage, modelName: "Gemini 4 Hydrogen")
        try expectEqual(agyCost?.isEstimated, true)
        try expectEqual(agyCost?.formatted, "~$3.25")
    }

    static func testCodexNeedsInputDetection(tempRoot: URL) throws {
        // 1. JSONL tail detects open request_user_input_async and clears on task_complete
        let openUserPromptJSONL = """
        {"timestamp":"2026-11-16T10:00:00Z","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"2026-11-16T10:00:02Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input_async","call_id":"call_u1"}}
        """
        let openMetrics = CodexReader.parseSessionJSONL(data: Data(openUserPromptJSONL.utf8))
        try expectTrue(openMetrics.hasOpenTurn)
        try expectEqual(openMetrics.pendingUserInputTool, "request_user_input_async")
        try expectEqual(openMetrics.pendingApprovalTool, nil)

        let closedJSONL = openUserPromptJSONL + "\n" + """
        {"timestamp":"2026-11-16T10:00:05Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_u1"}}
        {"timestamp":"2026-11-16T10:00:06Z","type":"event_msg","payload":{"type":"task_complete"}}
        """
        let closedMetrics = CodexReader.parseSessionJSONL(data: Data(closedJSONL.utf8))
        try expectTrue(!closedMetrics.hasOpenTurn)
        try expectEqual(closedMetrics.pendingUserInputTool, nil)
        try expectEqual(closedMetrics.pendingApprovalTool, nil)

        // 2. End-to-end approval wait (>= 10s old open exec call) with approval_mode = 'on-request'
        let codexDir = tempRoot.appendingPathComponent("codex-needs-input")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)

        let staleDate = Date().addingTimeInterval(-30)
        let staleISO = ISO8601DateFormatter().string(from: staleDate)
        let rolloutURL = codexDir.appendingPathComponent("rollout-wait.jsonl")
        let waitJSONL = """
        {"timestamp":"\(staleISO)","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"\(staleISO)","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"call_exec_1"}}
        """
        try waitJSONL.write(to: rolloutURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: rolloutURL.path)

        let dbURL = codexDir.appendingPathComponent("state_5.sqlite")
        try execSQL(
            at: dbURL,
            sql: """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                cwd TEXT NOT NULL,
                model TEXT,
                reasoning_effort TEXT,
                tokens_used INTEGER NOT NULL DEFAULT 0,
                git_branch TEXT,
                updated_at INTEGER NOT NULL,
                title TEXT NOT NULL,
                rollout_path TEXT NOT NULL,
                approval_mode TEXT,
                archived INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO threads (id, cwd, model, reasoning_effort, tokens_used, git_branch, updated_at, title, rollout_path, approval_mode, archived)
            VALUES ('t-wait', '/tmp/wait-app', 'gpt-5', 'high', 1000, 'main', \(Int(staleDate.timeIntervalSince1970)), 'Wait Test', '\(rolloutURL.path)', 'on-request', 0);
            """
        )

        let waitingSnap = CodexReader.read(rawPath: codexDir.path, watchedFolders: [])
        try expectEqual(waitingSnap.state, .needsInput)
        try expectEqual(waitingSnap.interactionReason, "Freigabe nötig")

        // When approval_mode = 'never', do not classify stale exec as waiting for approval
        try execSQL(at: dbURL, sql: "UPDATE threads SET approval_mode = 'never' WHERE id = 't-wait';")
        let nonApprovalSnap = CodexReader.read(rawPath: codexDir.path, watchedFolders: [])
        try expectEqual(nonApprovalSnap.state, .idle)
    }

    static func testAntigravityWaitingStepDetection(tempRoot: URL) throws {
        let agDir = tempRoot.appendingPathComponent("ag-waiting")
        let convDir = agDir.appendingPathComponent("conversations")
        try FileManager.default.createDirectory(at: convDir, withIntermediateDirectories: true)

        let dbURL = agDir.appendingPathComponent("conversation_summaries.db")
        try execSQL(
            at: dbURL,
            sql: """
            CREATE TABLE conversation_summaries (
                conversation_id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                workspace_uris TEXT NOT NULL,
                status TEXT NOT NULL,
                step_count INTEGER NOT NULL,
                not_fully_idle INTEGER NOT NULL,
                killed INTEGER NOT NULL,
                last_modified_time TEXT NOT NULL
            );
            INSERT INTO conversation_summaries
            VALUES ('conv-wait', 'Approval', '["file:///tmp/orbit-proj"]', 'CASCADE_RUN_STATUS_RUNNING', 8, 1, 0, '2026-11-16 21:00:00.000000+00:00');
            """
        )

        let convDB = convDir.appendingPathComponent("conv-wait.db")
        try execSQL(
            at: convDB,
            sql: """
            CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_type INTEGER, status INTEGER);
            INSERT INTO steps VALUES (1, 132, 3), (2, 132, 9);
            """
        )

        let waiting = AntigravityReader.read(rawPath: agDir.path, watchedFolders: [], modelAliases: [:])
        try expectEqual(waiting.state, .needsInput)
        try expectEqual(waiting.interactionReason, "Freigabe / Eingabe")

        try execSQL(at: convDB, sql: "UPDATE steps SET status = 2 WHERE idx = 2;")
        let running = AntigravityReader.read(rawPath: agDir.path, watchedFolders: [], modelAliases: [:])
        try expectEqual(running.state, .running)
    }

    static func testNeedsInputTransitionDetection(tempRoot: URL) throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let running = AgentSnapshot(
            kind: .codex,
            sessionID: "s-wait",
            state: .running,
            projectName: "AgentOrbit",
            projectPath: nil,
            gitBranch: nil,
            modelName: "gpt-5",
            reasoningEffort: nil,
            sessionTitle: nil,
            usage: UsageMetrics(),
            lastUpdated: t0,
            activeSince: t0,
            resolvedSourcePath: nil,
            statusMessage: nil
        )
        var waiting = running
        waiting.state = .needsInput
        waiting.interactionReason = "Freigabe nötig"

        let events = CoordinatorMonitor.detectNeedsInputSessions(previous: [running], current: [waiting], now: t0.addingTimeInterval(15))
        try expectEqual(events.count, 1)
        try expectEqual(events.first?.reason, "Freigabe nötig")

        // Staying in .needsInput does not re-emit
        let repeated = CoordinatorMonitor.detectNeedsInputSessions(previous: [waiting], current: [waiting], now: t0.addingTimeInterval(20))
        try expectTrue(repeated.isEmpty)

        // Transitioning .running -> .needsInput does NOT fire completion notification
        let completed = CoordinatorMonitor.detectCompletedSessions(
            previous: [running],
            current: [waiting],
            activeStartTimes: [running.id: t0],
            now: t0.addingTimeInterval(15)
        )
        try expectTrue(completed.isEmpty)
    }

    static func testOpenCodeV2SessionDetection(tempRoot: URL) throws {
        let ocDir = tempRoot.appendingPathComponent("opencode")
        try FileManager.default.createDirectory(at: ocDir, withIntermediateDirectories: true)
        let dbURL = ocDir.appendingPathComponent("opencode.db")

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let oldMs = nowMs - 1_800_000 // 30 minutes ago
        let busyMs = nowMs - 45_000   // busy started 45s ago (beyond old 20s age heuristic)

        try execSQL(
            at: dbURL,
            sql: """
            CREATE TABLE session (
                id TEXT PRIMARY KEY,
                directory TEXT,
                title TEXT,
                model TEXT,
                agent TEXT,
                cost REAL,
                tokens_input INTEGER,
                tokens_output INTEGER,
                tokens_cache_read INTEGER,
                time_updated INTEGER,
                time_archived INTEGER
            );
            INSERT INTO session VALUES (
                'ses_oc1', '/tmp/oc-proj', 'Old Row',
                '{"id":"deepseek-v4.1-flash-free","providerID":"opencode","variant":"default"}',
                'build', 0.0, 100, 50, 0, \(oldMs), NULL
            );

            CREATE TABLE session_v2 (
                id TEXT PRIMARY KEY,
                directory TEXT,
                title TEXT,
                model TEXT,
                agent TEXT,
                cost REAL,
                tokens_input INTEGER,
                tokens_output INTEGER,
                tokens_cache_read INTEGER,
                time_updated INTEGER,
                time_archived INTEGER,
                time_busy INTEGER,
                time_idle INTEGER,
                time_suspended INTEGER,
                idle_outcome TEXT
            );
            INSERT INTO session_v2 VALUES (
                'ses_oc1', '/tmp/oc-proj', 'Active v2',
                '{"id":"deepseek-v4.1-flash-free","providerID":"opencode","variant":"default"}',
                'build', 0.0, 2000, 400, 1000, \(busyMs), NULL, \(busyMs), \(oldMs), NULL, 'succeeded'
            );

            CREATE TABLE session_message (
                id TEXT PRIMARY KEY,
                session_id TEXT,
                type TEXT,
                seq INTEGER,
                time_created INTEGER,
                time_updated INTEGER,
                data TEXT
            );
            """
        )

        let cfg = CustomAgentConfig(name: "OpenCode", path: ocDir.path, isEnabled: true)
        let runningSnap = CustomAgentReader.readSessions(config: cfg, watchedFolders: []).first
        try expectEqual(runningSnap?.state, .running)
        try expectEqual(runningSnap?.modelName, "deepseek-v4.1-flash-free")
        try expectEqual(runningSnap?.reasoningEffort, nil)

        // Open question tool in session_message transitions to .needsInput
        try execSQL(
            at: dbURL,
            sql: """
            INSERT INTO session_message VALUES (
                'msg_q', 'ses_oc1', 'assistant', 10, \(busyMs), \(busyMs),
                '{"content":[{"type":"tool","name":"question","id":"call_q1"}],"finish":"tool-calls"}'
            );
            """
        )
        let waitingSnap = CustomAgentReader.readSessions(config: cfg, watchedFolders: []).first
        try expectEqual(waitingSnap?.state, .needsInput)
        try expectEqual(waitingSnap?.interactionReason, "Rückfrage")

        // When time_idle catches up to time_busy, transitions to .idle
        let doneMs = nowMs
        try execSQL(at: dbURL, sql: "UPDATE session_v2 SET time_idle = \(doneMs), time_updated = \(doneMs) WHERE id = 'ses_oc1';")
        let idleSnap = CustomAgentReader.readSessions(config: cfg, watchedFolders: []).first
        try expectEqual(idleSnap?.state, .idle)
    }

    private static func execSQL(at url: URL, sql: String) throws {
        var db: OpaquePointer?
        try expectEqual(sqlite3_open(url.path, &db), SQLITE_OK, "sqlite3_open")
        defer { sqlite3_close(db) }
        try expectEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, "sqlite3_exec")
    }
}
