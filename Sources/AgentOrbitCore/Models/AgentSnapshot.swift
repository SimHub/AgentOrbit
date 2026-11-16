import Foundation

public enum AgentKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case codex = "Codex"
    case antigravity = "Antigravity"
    case custom = "Custom"

    public var id: String { rawValue }
}

public struct CustomAgentConfig: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var path: String
    public var isEnabled: Bool

    public init(id: UUID = UUID(), name: String, path: String, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.path = path
        self.isEnabled = isEnabled
    }
}

public enum AgentRunState: String, Sendable {
    case needsInput = "Eingabe nötig"
    case running = "Aktiv"
    case idle = "Idle"
    case offline = "Offline"
    case unavailable = "Nicht gefunden"

    public var isLive: Bool {
        self == .running
    }

    public var isWaitingForUser: Bool {
        self == .needsInput
    }

    public var isActiveOrWaiting: Bool {
        self == .running || self == .needsInput
    }
}

public struct RateLimitWindow: Sendable, Equatable {
    public let usedPercent: Double
    public let windowMinutes: Int
    public let resetsAt: Date?

    public var remainingPercent: Double {
        min(max(100 - usedPercent, 0), 100)
    }

    public var remainingFraction: Double {
        remainingPercent / 100.0
    }

    public init(usedPercent: Double, windowMinutes: Int, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }
}

public struct UsageMetrics: Sendable, Equatable {
    public var sessionTotalTokens: Int?
    public var contextTokens: Int?
    public var contextWindow: Int?
    public var isContextWindowEstimated: Bool
    public var inputTokens: Int?
    public var cacheReadTokens: Int?
    public var outputTokens: Int?
    public var stepCount: Int?
    public var primaryLimit: RateLimitWindow?
    public var secondaryLimit: RateLimitWindow?
    public var planType: String?
    public var recordedCostUSD: Double?

    public init(
        sessionTotalTokens: Int? = nil,
        contextTokens: Int? = nil,
        contextWindow: Int? = nil,
        isContextWindowEstimated: Bool = false,
        inputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        outputTokens: Int? = nil,
        stepCount: Int? = nil,
        primaryLimit: RateLimitWindow? = nil,
        secondaryLimit: RateLimitWindow? = nil,
        planType: String? = nil,
        recordedCostUSD: Double? = nil
    ) {
        self.sessionTotalTokens = sessionTotalTokens
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.isContextWindowEstimated = isContextWindowEstimated
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.outputTokens = outputTokens
        self.stepCount = stepCount
        self.primaryLimit = primaryLimit
        self.secondaryLimit = secondaryLimit
        self.planType = planType
        self.recordedCostUSD = recordedCostUSD
    }

    public var contextFillRatio: Double? {
        guard let used = contextTokens, let window = contextWindow, window > 0 else { return nil }
        return min(max(Double(used) / Double(window), 0), 1)
    }
}

public struct AgentSnapshot: Sendable, Equatable, Identifiable {
    public let kind: AgentKind
    public let sessionID: String
    public var agentLabel: String
    public var state: AgentRunState
    public var projectName: String
    public var projectPath: String?
    public var gitBranch: String?
    public var modelName: String
    public var reasoningEffort: String?
    public var sessionTitle: String?
    public var usage: UsageMetrics
    public var lastUpdated: Date?
    public var activeSince: Date?
    public var resolvedSourcePath: String?
    public var statusMessage: String?
    public var interactionReason: String?

    public var id: String { "\(agentLabel):\(sessionID)" }

    public init(
        kind: AgentKind,
        sessionID: String? = nil,
        agentLabel: String? = nil,
        state: AgentRunState,
        projectName: String,
        projectPath: String?,
        gitBranch: String?,
        modelName: String,
        reasoningEffort: String?,
        sessionTitle: String?,
        usage: UsageMetrics,
        lastUpdated: Date?,
        activeSince: Date? = nil,
        resolvedSourcePath: String?,
        statusMessage: String?,
        interactionReason: String? = nil
    ) {
        self.kind = kind
        self.sessionID = sessionID ?? kind.rawValue
        self.agentLabel = agentLabel ?? kind.rawValue
        self.state = state
        self.projectName = projectName
        self.projectPath = projectPath
        self.gitBranch = gitBranch
        self.modelName = modelName
        self.reasoningEffort = reasoningEffort
        self.sessionTitle = sessionTitle
        self.usage = usage
        self.lastUpdated = lastUpdated
        self.activeSince = activeSince
        self.resolvedSourcePath = resolvedSourcePath
        self.statusMessage = statusMessage
        self.interactionReason = interactionReason
    }

    public static func placeholder(
        _ kind: AgentKind,
        sessionID: String? = nil,
        agentLabel: String? = nil,
        state: AgentRunState = .unavailable,
        message: String? = nil
    ) -> AgentSnapshot {
        AgentSnapshot(
            kind: kind,
            sessionID: sessionID,
            agentLabel: agentLabel,
            state: state,
            projectName: "—",
            projectPath: nil,
            gitBranch: nil,
            modelName: "—",
            reasoningEffort: nil,
            sessionTitle: nil,
            usage: UsageMetrics(),
            lastUpdated: nil,
            resolvedSourcePath: nil,
            statusMessage: message
        )
    }
}

public struct CompletedSessionEvent: Sendable, Equatable, Identifiable {
    public let id: String
    public let agentLabel: String
    public let projectName: String
    public let modelName: String
    public let durationSeconds: Int
    public let completedAt: Date

    public init(
        id: String,
        agentLabel: String,
        projectName: String,
        modelName: String,
        durationSeconds: Int,
        completedAt: Date = Date()
    ) {
        self.id = id
        self.agentLabel = agentLabel
        self.projectName = projectName
        self.modelName = modelName
        self.durationSeconds = durationSeconds
        self.completedAt = completedAt
    }
}

public struct NeedsInputEvent: Sendable, Equatable, Identifiable {
    public let id: String
    public let agentLabel: String
    public let projectName: String
    public let modelName: String
    public let reason: String
    public let detectedAt: Date

    public init(
        id: String,
        agentLabel: String,
        projectName: String,
        modelName: String,
        reason: String,
        detectedAt: Date = Date()
    ) {
        self.id = id
        self.agentLabel = agentLabel
        self.projectName = projectName
        self.modelName = modelName
        self.reason = reason
        self.detectedAt = detectedAt
    }
}

public struct WatchedFolderStatus: Sendable, Equatable, Identifiable {
    public let configuredPath: String
    public let resolvedPath: String
    public let displayName: String
    public let isOnline: Bool
    public let gitBranch: String?
    public let hasCodexConfig: Bool
    public let hasAntigravityConfig: Bool

    public var id: String { configuredPath }

    public init(
        configuredPath: String,
        resolvedPath: String,
        displayName: String,
        isOnline: Bool,
        gitBranch: String?,
        hasCodexConfig: Bool,
        hasAntigravityConfig: Bool
    ) {
        self.configuredPath = configuredPath
        self.resolvedPath = resolvedPath
        self.displayName = displayName
        self.isOnline = isOnline
        self.gitBranch = gitBranch
        self.hasCodexConfig = hasCodexConfig
        self.hasAntigravityConfig = hasAntigravityConfig
    }
}

public enum MenuBarLabelMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case iconOnly = "icon"
    case project = "project"
    case projectAndModel = "projectAndModel"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .iconOnly: return "Nur Icon"
        case .project: return "Projekt"
        case .projectAndModel: return "Projekt · Model"
        }
    }
}

public enum ViewDensityMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case minimal = "minimal"
    case compact = "compact"
    case detailed = "detailed"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .minimal: return "Minimal"
        case .compact: return "Kompakt"
        case .detailed: return "Detail"
        }
    }
}

public enum PreferredLauncher: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto = "auto"
    case antigravity = "antigravity"
    case vscode = "vscode"
    case cursor = "cursor"
    case terminal = "terminal"
    case finder = "finder"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return "Auto (passend)"
        case .antigravity: return "Antigravity"
        case .vscode: return "VS Code"
        case .cursor: return "Cursor"
        case .terminal: return "Terminal"
        case .finder: return "Finder"
        }
    }
}

public enum HotKeyPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case none = "none"
    case controlOptionO = "ctrlOptO"
    case controlOptionA = "ctrlOptA"
    case commandShiftO = "cmdShiftO"
    case controlOptionSpace = "ctrlOptSpace"
    case optionSpace = "optSpace"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: return "Aus"
        case .controlOptionO: return "⌃⌥ O"
        case .controlOptionA: return "⌃⌥ A"
        case .commandShiftO: return "⌘⇧ O"
        case .controlOptionSpace: return "⌃⌥ Space"
        case .optionSpace: return "⌥ Space"
        }
    }
}

public struct KoordinatorConfig: Codable, Equatable, Sendable {
    public var codexPath: String
    public var antigravityPath: String
    public var watchedFolders: [String]
    public var labelMode: MenuBarLabelMode
    public var antigravityModelAliases: [String: String]
    /// 0 = Auto (1M Gemini / 200k Claude), -1 = Aus, >0 = fixes Token-Limit
    public var antigravityContextWindow: Int
    public var showAllActiveProjects: Bool
    public var snapToGrid: Bool
    public var viewMode: ViewDensityMode
    public var notifyOnCompletion: Bool
    public var notifyOnNeedsInput: Bool
    public var notifySound: Bool
    public var preferredLauncher: PreferredLauncher
    public var hotKeyPreset: HotKeyPreset
    public var hudOpacity: Double
    public var showEstimatedCost: Bool
    public var customAgents: [CustomAgentConfig]

    public init(
        codexPath: String,
        antigravityPath: String,
        watchedFolders: [String],
        labelMode: MenuBarLabelMode,
        antigravityModelAliases: [String: String],
        antigravityContextWindow: Int = 0,
        showAllActiveProjects: Bool = true,
        snapToGrid: Bool = true,
        viewMode: ViewDensityMode = .compact,
        notifyOnCompletion: Bool = true,
        notifyOnNeedsInput: Bool = true,
        notifySound: Bool = true,
        preferredLauncher: PreferredLauncher = .auto,
        hotKeyPreset: HotKeyPreset = .controlOptionO,
        hudOpacity: Double = 0.96,
        showEstimatedCost: Bool = true,
        customAgents: [CustomAgentConfig] = []
    ) {
        self.codexPath = codexPath
        self.antigravityPath = antigravityPath
        self.watchedFolders = watchedFolders
        self.labelMode = labelMode
        self.antigravityModelAliases = antigravityModelAliases
        self.antigravityContextWindow = antigravityContextWindow
        self.showAllActiveProjects = showAllActiveProjects
        self.snapToGrid = snapToGrid
        self.viewMode = viewMode
        self.notifyOnCompletion = notifyOnCompletion
        self.notifyOnNeedsInput = notifyOnNeedsInput
        self.notifySound = notifySound
        self.preferredLauncher = preferredLauncher
        self.hotKeyPreset = hotKeyPreset
        self.hudOpacity = min(max(hudOpacity, 0.45), 1.0)
        self.showEstimatedCost = showEstimatedCost
        self.customAgents = customAgents
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.defaultConfig
        codexPath = try container.decodeIfPresent(String.self, forKey: .codexPath) ?? defaults.codexPath
        antigravityPath = try container.decodeIfPresent(String.self, forKey: .antigravityPath) ?? defaults.antigravityPath
        watchedFolders = try container.decodeIfPresent([String].self, forKey: .watchedFolders) ?? []
        labelMode = try container.decodeIfPresent(MenuBarLabelMode.self, forKey: .labelMode) ?? .projectAndModel
        antigravityModelAliases = try container.decodeIfPresent([String: String].self, forKey: .antigravityModelAliases) ?? [:]
        antigravityContextWindow = try container.decodeIfPresent(Int.self, forKey: .antigravityContextWindow) ?? 0
        showAllActiveProjects = try container.decodeIfPresent(Bool.self, forKey: .showAllActiveProjects) ?? true
        snapToGrid = try container.decodeIfPresent(Bool.self, forKey: .snapToGrid) ?? true
        viewMode = try container.decodeIfPresent(ViewDensityMode.self, forKey: .viewMode) ?? .compact
        notifyOnCompletion = try container.decodeIfPresent(Bool.self, forKey: .notifyOnCompletion) ?? true
        notifyOnNeedsInput = try container.decodeIfPresent(Bool.self, forKey: .notifyOnNeedsInput) ?? true
        notifySound = try container.decodeIfPresent(Bool.self, forKey: .notifySound) ?? true
        preferredLauncher = try container.decodeIfPresent(PreferredLauncher.self, forKey: .preferredLauncher) ?? .auto
        hotKeyPreset = try container.decodeIfPresent(HotKeyPreset.self, forKey: .hotKeyPreset) ?? .controlOptionO
        let rawOpacity = try container.decodeIfPresent(Double.self, forKey: .hudOpacity) ?? 0.96
        hudOpacity = min(max(rawOpacity, 0.45), 1.0)
        showEstimatedCost = try container.decodeIfPresent(Bool.self, forKey: .showEstimatedCost) ?? true
        customAgents = try container.decodeIfPresent([CustomAgentConfig].self, forKey: .customAgents) ?? []
    }

    public static var defaultConfig: KoordinatorConfig {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return KoordinatorConfig(
            codexPath: "\(home)/.codex",
            antigravityPath: "\(home)/.gemini/antigravity",
            watchedFolders: [],
            labelMode: .projectAndModel,
            antigravityModelAliases: [:],
            antigravityContextWindow: 0,
            showAllActiveProjects: true,
            snapToGrid: true,
            viewMode: .compact,
            notifyOnCompletion: true,
            notifyOnNeedsInput: true,
            notifySound: true,
            preferredLauncher: .auto,
            hotKeyPreset: .controlOptionO,
            hudOpacity: 0.96,
            showEstimatedCost: true,
            customAgents: []
        )
    }

    private static let storageKey = "AgentOrbit.Config.v1"
    private static let legacyStorageKey = "AgentKoordinator.Config.v1"

    public static func load() -> KoordinatorConfig {
        let data = UserDefaults.standard.data(forKey: storageKey)
            ?? UserDefaults.standard.data(forKey: legacyStorageKey)
        guard
            let data,
            let decoded = try? JSONDecoder().decode(KoordinatorConfig.self, from: data)
        else {
            let discovered = AgentDiscovery.discover()
            var cfg = KoordinatorConfig.defaultConfig
            cfg.codexPath = discovered.codexPath
            cfg.antigravityPath = discovered.antigravityPath
            cfg.customAgents = discovered.customAgents
            cfg.save()
            return cfg
        }
        return decoded
    }

    public func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
