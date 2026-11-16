import AppKit
import Combine
import Foundation

@MainActor
public final class CoordinatorMonitor: ObservableObject {
    @Published public var config: KoordinatorConfig {
        didSet {
            guard config != oldValue else { return }
            config.save()
            restartWatcher()
            refresh()
        }
    }

    @Published public private(set) var codex: AgentSnapshot = .placeholder(.codex)
    @Published public private(set) var antigravity: AgentSnapshot = .placeholder(.antigravity)
    @Published public private(set) var sessions: [AgentSnapshot] = [
        .placeholder(.antigravity),
        .placeholder(.codex)
    ]
    @Published public private(set) var watchedFolders: [WatchedFolderStatus] = []
    @Published public private(set) var lastRefresh: Date = .now

    public var onSessionsCompleted: (([CompletedSessionEvent]) -> Void)?

    private var watcher: FSEventsWatcher?
    private var refreshTimer: AnyCancellable?
    private var volumeObservers: [NSObjectProtocol] = []
    private let ioQueue = DispatchQueue(label: "de.agentorbit.refresh", qos: .userInitiated)
    private var isRefreshing = false
    private var pendingRefresh = false
    private var hasCompletedInitialRefresh = false
    private var activeStartTimes: [String: Date] = [:]

    public init(config: KoordinatorConfig = .load()) {
        self.config = config
        restartWatcher()
        observeVolumes()
        startFallbackTimer()
        refresh()
    }

    public var primarySnapshot: AgentSnapshot {
        let candidates = sessions.filter { $0.state == .running || $0.state == .idle }
        guard !candidates.isEmpty else {
            return antigravity.state != .unavailable ? antigravity : codex
        }
        return candidates.max { lhs, rhs in
            if lhs.state.isLive != rhs.state.isLive {
                return !lhs.state.isLive && rhs.state.isLive
            }
            return (lhs.lastUpdated ?? .distantPast) < (rhs.lastUpdated ?? .distantPast)
        } ?? antigravity
    }

    public var liveSessionCount: Int {
        sessions.filter { $0.state.isLive }.count
    }

    public var isAnyLive: Bool {
        liveSessionCount > 0
    }

    public var menuBarLabelText: String? {
        let primary = primarySnapshot
        switch config.labelMode {
        case .iconOnly:
            return nil
        case .project:
            return primary.projectName == "—" ? nil : truncate(primary.projectName, maxLength: 20)
        case .projectAndModel:
            let proj = primary.projectName == "—" ? nil : truncate(primary.projectName, maxLength: 14)
            let baseModel = primary.modelName == "—" ? nil : truncate(primary.modelName, maxLength: 15)
            let effortTag = formattedShortEffort(primary.reasoningEffort)
            let modelWithEffort: String? = baseModel.map { model in
                if let effortTag {
                    return "\(model) (\(effortTag))"
                }
                return model
            }
            switch (proj, modelWithEffort) {
            case let (p?, m?): return "\(p) · \(m)"
            case let (p?, nil): return p
            case let (nil, m?): return m
            case (nil, nil): return nil
            }
        }
    }

    private func formattedShortEffort(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "low": return "Low"
        case "medium", "med": return "Med"
        case "high": return "High"
        case "xhigh", "extra", "extra_high", "extra high": return "Extra"
        default: return raw
        }
    }

    public func refresh() {
        if isRefreshing {
            pendingRefresh = true
            return
        }
        isRefreshing = true
        let snapshotConfig = config

        ioQueue.async { [weak self] in
            let folderStatuses = snapshotConfig.watchedFolders.map { PathResolver.inspectWatchedFolder($0) }
            let perAgentLimit = snapshotConfig.showAllActiveProjects ? 8 : 1

            let codexList = CodexReader.readSessions(
                rawPath: snapshotConfig.codexPath,
                watchedFolders: folderStatuses,
                limit: perAgentLimit
            )
            let antigravityList = AntigravityReader.readSessions(
                rawPath: snapshotConfig.antigravityPath,
                watchedFolders: folderStatuses,
                modelAliases: snapshotConfig.antigravityModelAliases,
                contextWindowOverride: snapshotConfig.antigravityContextWindow,
                limit: perAgentLimit
            )
            let customList = snapshotConfig.customAgents.flatMap { customCfg in
                CustomAgentReader.readSessions(
                    config: customCfg,
                    watchedFolders: folderStatuses,
                    limit: snapshotConfig.showAllActiveProjects ? 6 : 1
                )
            }

            let allSessions = antigravityList + codexList + customList
            let hasAvailableAgent = allSessions.contains { $0.state != .unavailable }
            let filteredSessions = hasAvailableAgent
                ? allSessions.filter { $0.state != .unavailable || $0.kind == .custom }
                : allSessions
            let combined = Self.sortSessions(filteredSessions)
            let primaryCodex = codexList.first ?? .placeholder(.codex)
            let primaryAgy = antigravityList.first ?? .placeholder(.antigravity)

            Task { @MainActor [weak self] in
                guard let self else { return }
                let now = Date()
                let completedEvents: [CompletedSessionEvent] = if self.hasCompletedInitialRefresh && self.config.notifyOnCompletion {
                    Self.detectCompletedSessions(
                        previous: self.sessions,
                        current: combined,
                        activeStartTimes: self.activeStartTimes,
                        now: now
                    )
                } else {
                    []
                }

                let enriched = Self.reconcileActiveStartTimes(
                    sessions: combined,
                    activeStartTimes: &self.activeStartTimes,
                    now: now
                )
                self.watchedFolders = folderStatuses
                self.codex = enriched.first(where: { $0.kind == .codex }) ?? primaryCodex
                self.antigravity = enriched.first(where: { $0.kind == .antigravity }) ?? primaryAgy
                self.sessions = enriched
                self.lastRefresh = now
                self.hasCompletedInitialRefresh = true
                if !completedEvents.isEmpty {
                    self.onSessionsCompleted?(completedEvents)
                }
                self.isRefreshing = false
                if self.pendingRefresh {
                    self.pendingRefresh = false
                    self.refresh()
                }
            }
        }
    }

    public nonisolated static func detectCompletedSessions(
        previous: [AgentSnapshot],
        current: [AgentSnapshot],
        activeStartTimes: [String: Date],
        now: Date = Date(),
        minimumDurationSeconds: TimeInterval = 3
    ) -> [CompletedSessionEvent] {
        let currentByID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var events: [CompletedSessionEvent] = []

        for prev in previous where prev.state.isLive {
            guard let curr = currentByID[prev.id], curr.state == .idle else {
                continue
            }
            let startedAt = activeStartTimes[prev.id] ?? prev.activeSince ?? prev.lastUpdated ?? now
            let elapsed = max(0, now.timeIntervalSince(startedAt))
            guard elapsed >= minimumDurationSeconds else {
                continue
            }
            events.append(CompletedSessionEvent(
                id: curr.id,
                agentLabel: curr.agentLabel,
                projectName: curr.projectName,
                modelName: curr.modelName,
                durationSeconds: Int(elapsed.rounded()),
                completedAt: now
            ))
        }
        return events
    }

    public nonisolated static func reconcileActiveStartTimes(
        sessions: [AgentSnapshot],
        activeStartTimes: inout [String: Date],
        now: Date = Date()
    ) -> [AgentSnapshot] {
        var liveIDs: Set<String> = []
        let updated: [AgentSnapshot] = sessions.map { session in
            var copy = session
            if copy.state.isLive {
                liveIDs.insert(copy.id)
                if let existing = activeStartTimes[copy.id] {
                    copy.activeSince = existing
                } else {
                    let initial: Date
                    if let updatedAt = copy.lastUpdated,
                       updatedAt <= now,
                       now.timeIntervalSince(updatedAt) <= 15 {
                        initial = updatedAt
                    } else {
                        initial = now
                    }
                    activeStartTimes[copy.id] = initial
                    copy.activeSince = initial
                }
            } else {
                activeStartTimes.removeValue(forKey: copy.id)
                copy.activeSince = nil
            }
            return copy
        }
        activeStartTimes = activeStartTimes.filter { liveIDs.contains($0.key) }
        return updated
    }

    nonisolated private static func sortSessions(_ list: [AgentSnapshot]) -> [AgentSnapshot] {
        list.sorted { lhs, rhs in
            let lhsRank = stateRank(lhs.state)
            let rhsRank = stateRank(rhs.state)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            let lhsDate = lhs.lastUpdated ?? .distantPast
            let rhsDate = rhs.lastUpdated ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.agentLabel < rhs.agentLabel
        }
    }

    nonisolated private static func stateRank(_ state: AgentRunState) -> Int {
        switch state {
        case .running: return 0
        case .idle: return 1
        case .offline: return 2
        case .unavailable: return 3
        }
    }

    public func addCustomAgent(name: String, path: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPath.isEmpty else { return }
        config.customAgents.append(CustomAgentConfig(name: trimmedName, path: trimmedPath, isEnabled: true))
    }

    public func removeCustomAgent(id: UUID) {
        config.customAgents.removeAll { $0.id == id }
    }

    public func toggleCustomAgent(id: UUID) {
        guard let idx = config.customAgents.firstIndex(where: { $0.id == id }) else { return }
        config.customAgents[idx].isEnabled.toggle()
    }

    @discardableResult
    public func runAutoDiscovery() -> Int {
        let discovered = AgentDiscovery.discover()
        var added = 0
        var updatedConfig = config

        if updatedConfig.codexPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, discovered.hasCodex {
            updatedConfig.codexPath = discovered.codexPath
            added += 1
        }
        if updatedConfig.antigravityPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, discovered.hasAntigravity {
            updatedConfig.antigravityPath = discovered.antigravityPath
            added += 1
        }

        let existingPaths = Set(updatedConfig.customAgents.map { PathResolver.resolve($0.path).path })
        let existingNames = Set(updatedConfig.customAgents.map { $0.name.lowercased() })

        for candidate in discovered.customAgents {
            let resolved = PathResolver.resolve(candidate.path).path
            if !existingPaths.contains(resolved) && !existingNames.contains(candidate.name.lowercased()) {
                updatedConfig.customAgents.append(candidate)
                added += 1
            }
        }

        if updatedConfig != config {
            config = updatedConfig
        }
        return added
    }

    public func addWatchedFolder(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !config.watchedFolders.contains(trimmed) else { return }
        config.watchedFolders.append(trimmed)
    }

    public func removeWatchedFolder(_ path: String) {
        config.watchedFolders.removeAll { $0 == path }
    }

    private func restartWatcher() {
        var paths: [String] = []
        if !config.codexPath.isEmpty {
            paths.append(PathResolver.resolveCodexRoot(config.codexPath).path)
        }
        if !config.antigravityPath.isEmpty {
            paths.append(PathResolver.resolveAntigravityRoot(config.antigravityPath).path)
        }
        for agent in config.customAgents where agent.isEnabled && !agent.path.isEmpty {
            paths.append(PathResolver.resolve(agent.path).path)
        }
        for folder in config.watchedFolders {
            paths.append(PathResolver.resolve(folder).path)
        }

        if let watcher {
            watcher.update(paths: paths)
        } else {
            watcher = FSEventsWatcher(paths: paths) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            }
        }
    }

    private func startFallbackTimer() {
        refreshTimer = Timer.publish(every: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refresh()
            }
    }

    private func observeVolumes() {
        let nc = NSWorkspace.shared.notificationCenter
        let mountObs = nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.restartWatcher()
                self?.refresh()
            }
        }
        let unmountObs = nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.restartWatcher()
                self?.refresh()
            }
        }
        volumeObservers = [mountObs, unmountObs]
    }

    private func truncate(_ str: String, maxLength: Int) -> String {
        guard str.count > maxLength else { return str }
        return String(str.prefix(maxLength - 1)) + "…"
    }
}
