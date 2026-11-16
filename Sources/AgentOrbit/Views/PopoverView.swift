import AgentOrbitCore
import AppKit
import SwiftUI

@MainActor
final class PopoverUIState: ObservableObject {
    private static let pinnedKey = "AgentOrbit.IsPinned"
    private static let legacyPinnedKey = "AgentKoordinator.IsPinned"
    private static let pinnedWidthKey = "AgentOrbit.PinnedWidth"

    @Published var isPinned: Bool {
        didSet {
            UserDefaults.standard.set(isPinned, forKey: Self.pinnedKey)
        }
    }
    @Published var customPinnedWidth: CGFloat? {
        didSet {
            if let customPinnedWidth {
                UserDefaults.standard.set(Double(customPinnedWidth), forKey: Self.pinnedWidthKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.pinnedWidthKey)
            }
        }
    }
    @Published var showingSettings = false
    @Published var settingsTab: SettingsTab = .display
    @Published var newFolderPath = ""
    @Published var aliasKey = ""
    @Published var aliasValue = ""
    @Published var newCustomAgentName = ""
    @Published var newCustomAgentPath = ""
    @Published var onlyActiveFilter = false
    @Published var expandedUsageIDs: Set<String> = []
    @Published var hoveredResizeTrailing: Bool?
    @Published var isDragGripHovered = false
    @Published var discoveryStatusMessage: String?
    var resizeStartMouseX: CGFloat?
    var resizeStartWidth: CGFloat?

    func toggleUsageDetails(_ id: String) {
        if expandedUsageIDs.contains(id) {
            expandedUsageIDs.remove(id)
        } else {
            expandedUsageIDs.insert(id)
        }
    }

    init() {
        if UserDefaults.standard.object(forKey: Self.pinnedKey) != nil {
            self.isPinned = UserDefaults.standard.bool(forKey: Self.pinnedKey)
        } else {
            self.isPinned = UserDefaults.standard.bool(forKey: Self.legacyPinnedKey)
        }
        if UserDefaults.standard.object(forKey: Self.pinnedWidthKey) != nil {
            let saved = CGFloat(UserDefaults.standard.double(forKey: Self.pinnedWidthKey))
            self.customPinnedWidth = saved >= 240 ? saved : nil
        } else {
            self.customPinnedWidth = nil
        }
    }
}

struct PopoverView: View {
    @ObservedObject var monitor: CoordinatorMonitor
    @ObservedObject var uiState: PopoverUIState
    var isInPinnedPanel: Bool = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if isInPinnedPanel {
                    ZStack {
                        Color.primary.opacity(uiState.isDragGripHovered ? 0.07 : 0.025)
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.30, green: 0.85, blue: 0.95),
                                        Color.accentColor
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .opacity(uiState.isDragGripHovered ? 1.0 : 0.72)
                            .frame(width: 48, height: 4.5)
                    }
                    .frame(height: 14)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        uiState.isDragGripHovered = hovering
                        if hovering {
                            NSCursor.openHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .help("Ziehen zum Verschieben · Einrast-Grid (⌥ = Frei)")
                }
                header
                Divider()
                if uiState.showingSettings {
                    SettingsView(monitor: monitor, uiState: uiState, onDone: { uiState.showingSettings = false })
                } else {
                    previewBody
                }
            }
            .frame(width: panelWidth)
            .contentShape(Rectangle())
            .gesture(pinnedDragGesture)

            if isInPinnedPanel && !uiState.showingSettings {
                HStack {
                    ResizeCornerGrip(
                        uiState: uiState,
                        isTrailing: false,
                        isHighlighted: PinnedWindowController.shared.prefersLeadingResizeGrip,
                        currentWidth: panelWidth,
                        maxWidth: maxSafePanelWidth,
                        onWidthChange: { uiState.customPinnedWidth = $0 },
                        onReset: { uiState.customPinnedWidth = nil }
                    )
                    Spacer()
                    ResizeCornerGrip(
                        uiState: uiState,
                        isTrailing: true,
                        isHighlighted: !PinnedWindowController.shared.prefersLeadingResizeGrip,
                        currentWidth: panelWidth,
                        maxWidth: maxSafePanelWidth,
                        onWidthChange: { uiState.customPinnedWidth = $0 },
                        onReset: { uiState.customPinnedWidth = nil }
                    )
                }
            }
        }
        .frame(width: panelWidth)
    }

    private var pinnedDragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { _ in
                guard isInPinnedPanel else { return }
                PinnedWindowController.shared.handleDragChanged(mouseLocation: NSEvent.mouseLocation)
            }
            .onEnded { _ in
                guard isInPinnedPanel else { return }
                PinnedWindowController.shared.handleDragEnded()
            }
    }

    private var displayedSnapshots: [AgentSnapshot] {
        let all = monitor.sessions
        if uiState.onlyActiveFilter {
            let live = all.filter { $0.state.isActiveOrWaiting }
            if !live.isEmpty {
                return live
            }
        }
        return all
    }

    private var availableScreenSize: CGSize {
        (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
    }

    private var maxSafePanelWidth: CGFloat {
        max(360, availableScreenSize.width - 48)
    }

    private var columnCount: Int {
        if uiState.showingSettings { return 1 }
        let count = max(1, displayedSnapshots.count)
        let availWidth = availableScreenSize.width

        if isInPinnedPanel, let custom = uiState.customPinnedWidth {
            let w = min(max(240, custom), maxSafePanelWidth)
            if w < 480 { return 1 }
            if w < 760 { return min(2, count) }
            return min(3, count)
        }

        if count <= 2 || availWidth < 680 { return 1 }
        if count <= 4 || !isInPinnedPanel || availWidth < 1000 { return 2 }
        return 3
    }

    private var panelWidth: CGFloat {
        if uiState.showingSettings { return min(390, maxSafePanelWidth) }
        if isInPinnedPanel, let custom = uiState.customPinnedWidth {
            return min(max(240, custom), maxSafePanelWidth)
        }
        switch columnCount {
        case 3: return min(920, maxSafePanelWidth)
        case 2: return min(640, maxSafePanelWidth)
        default:
            return monitor.config.viewMode == .minimal ? 280 : min(360, maxSafePanelWidth)
        }
    }

    private var effectiveViewMode: ViewDensityMode {
        if monitor.config.viewMode == .minimal { return .minimal }
        if isInPinnedPanel && panelWidth < 290 { return .minimal }
        return monitor.config.viewMode
    }

    private var maxScrollHeight: CGFloat {
        min(540, max(260, availableScreenSize.height - 170))
    }

    private var header: some View {
        let isUltraNarrow = panelWidth < 280
        return HStack(spacing: isUltraNarrow ? 6 : 8) {
            BrandBadgeView(
                size: isUltraNarrow ? 19 : 22,
                isLive: monitor.isAnyLive,
                needsInput: monitor.isAnyWaitingForUser
            )

            VStack(alignment: .leading, spacing: 1) {
                Text("AgentOrbit")
                    .font(.system(size: isUltraNarrow ? 11.5 : 12.5, weight: .semibold))
                    .lineLimit(1)
                if !isUltraNarrow {
                    Text(subtitleText)
                        .font(.system(size: 10))
                        .foregroundStyle(
                            monitor.isAnyWaitingForUser ? Color.orange : (monitor.isAnyLive ? Color.green : Color.secondary)
                        )
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Button {
                let next: ViewDensityMode = switch monitor.config.viewMode {
                case .minimal: .compact
                case .compact: .detailed
                case .detailed: .minimal
                }
                monitor.config.viewMode = next
                if next != .minimal, let w = uiState.customPinnedWidth, w < 290 {
                    uiState.customPinnedWidth = 340
                }
            } label: {
                Image(systemName: viewModeIcon)
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(effectiveViewMode == .minimal ? Color.accentColor : Color.secondary)
            .help("Ansicht: \(effectiveViewMode.title) (Klicken zum Wechseln)")

            Button {
                let nextPinned = !uiState.isPinned
                uiState.isPinned = nextPinned
                PinnedWindowController.shared.setPinned(nextPinned, monitor: monitor, uiState: uiState)
                if nextPinned, !isInPinnedPanel {
                    dismiss()
                }
            } label: {
                Image(systemName: uiState.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11.5))
                    .rotationEffect(.degrees(uiState.isPinned ? 0 : 45))
            }
            .buttonStyle(.plain)
            .foregroundStyle(uiState.isPinned ? Color.accentColor : Color.secondary)
            .help(uiState.isPinned ? "Lösen" : "Oben anpinnen")

            Button {
                monitor.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Jetzt aktualisieren")

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    uiState.showingSettings.toggle()
                }
            } label: {
                Image(systemName: uiState.showingSettings ? "xmark.circle.fill" : "gearshape")
                    .font(.system(size: 12.5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(uiState.showingSettings ? Color.primary : Color.secondary)
            .help(uiState.showingSettings ? "Zurück" : "Ordner & Anzeige")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Beenden")
        }
        .padding(.horizontal, isUltraNarrow ? 10 : 14)
        .padding(.vertical, isUltraNarrow ? 8 : 10)
    }

    private var viewModeIcon: String {
        switch effectiveViewMode {
        case .minimal: return "rectangle.compress.vertical"
        case .compact: return "square.split.1x2"
        case .detailed: return "list.bullet.rectangle"
        }
    }

    private var subtitleText: String {
        let base: String = if monitor.isAnyWaitingForUser {
            "Echtzeit · Eingabe nötig"
        } else if monitor.isAnyLive {
            "Echtzeit · Aktiv"
        } else {
            "Echtzeit · Bereit"
        }
        return isInPinnedPanel ? "\(base) · Angepinnt" : base
    }

    private var previewBody: some View {
        let snapshots = displayedSnapshots
        let waitingCount = monitor.sessions.filter { $0.state.isWaitingForUser }.count
        let liveCount = monitor.sessions.filter { $0.state.isLive }.count
        let activeOrWaitingCount = waitingCount + liveCount

        return VStack(spacing: 10) {
            if monitor.sessions.count > 2 || waitingCount > 0 {
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        if waitingCount > 0 {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 6, height: 6)
                            Text("\(waitingCount) Wartet")
                                .fontWeight(.semibold)
                                .foregroundStyle(.orange)
                            Text("·")
                                .foregroundStyle(.tertiary)
                        }
                        if liveCount > 0 {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                            Text("\(liveCount) Aktiv")
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                            Text("·")
                                .foregroundStyle(.tertiary)
                        }
                        Text("\(monitor.sessions.count) Sessions")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 10.5))

                    Spacer()

                    if activeOrWaitingCount > 0 && activeOrWaitingCount < monitor.sessions.count {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                uiState.onlyActiveFilter.toggle()
                            }
                        } label: {
                            Text(uiState.onlyActiveFilter ? "Alle zeigen" : "Nur Aktiv")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(uiState.onlyActiveFilter ? Color.accentColor : Color.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .background(
                                    (uiState.onlyActiveFilter ? Color.accentColor : Color.primary).opacity(0.08),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if snapshots.count > 4 || (effectiveViewMode == .minimal && snapshots.count > 6) {
                ScrollView(.vertical, showsIndicators: true) {
                    cardsGrid(snapshots)
                }
                .frame(maxHeight: maxScrollHeight)
            } else {
                cardsGrid(snapshots)
            }

            if effectiveViewMode != .minimal && !monitor.watchedFolders.isEmpty {
                watchedFoldersSection
            }
        }
        .padding(effectiveViewMode == .minimal ? 9 : 12)
    }

    @ViewBuilder
    private func cardsGrid(_ snapshots: [AgentSnapshot]) -> some View {
        let primaryID = monitor.primarySnapshot.id
        let mode = effectiveViewMode
        let isNarrow = panelWidth < 290
        let cardSpacing: CGFloat = mode == .minimal ? 6 : 10

        if columnCount == 1 {
            VStack(spacing: cardSpacing) {
                ForEach(snapshots) { snapshot in
                    AgentCardView(
                        snapshot: snapshot,
                        isPrimary: snapshot.id == primaryID,
                        viewMode: mode,
                        isNarrow: isNarrow,
                        preferredLauncher: monitor.config.preferredLauncher,
                        showEstimatedCost: monitor.config.showEstimatedCost,
                        isUsageExpanded: uiState.expandedUsageIDs.contains(snapshot.id),
                        onToggleUsage: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                uiState.toggleUsageDetails(snapshot.id)
                            }
                        }
                    )
                }
            }
        } else {
            let cols = Array(repeating: GridItem(.flexible(minimum: 220), spacing: cardSpacing, alignment: .top), count: columnCount)
            LazyVGrid(columns: cols, alignment: .leading, spacing: cardSpacing) {
                ForEach(snapshots) { snapshot in
                    AgentCardView(
                        snapshot: snapshot,
                        isPrimary: snapshot.id == primaryID,
                        viewMode: mode,
                        isNarrow: false,
                        preferredLauncher: monitor.config.preferredLauncher,
                        showEstimatedCost: monitor.config.showEstimatedCost,
                        isUsageExpanded: uiState.expandedUsageIDs.contains(snapshot.id),
                        onToggleUsage: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                uiState.toggleUsageDetails(snapshot.id)
                            }
                        }
                    )
                }
            }
        }
    }

    private var watchedFoldersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Ordner")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            VStack(spacing: 4) {
                ForEach(monitor.watchedFolders) { folder in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(folder.isOnline ? Color.green : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(folder.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        if let branch = folder.gitBranch {
                            Text(branch)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                        Spacer()
                        if folder.hasCodexConfig {
                            Text("codex")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        if folder.hasAntigravityConfig {
                            Text("agy")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        if !folder.isOnline {
                            Text("Offline")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
        .padding(.top, 2)
    }
}

private struct ResizeCornerGrip: View {
    @ObservedObject var uiState: PopoverUIState
    let isTrailing: Bool
    let isHighlighted: Bool
    let currentWidth: CGFloat
    let maxWidth: CGFloat
    let onWidthChange: (CGFloat) -> Void
    let onReset: () -> Void

    private var isHovered: Bool {
        uiState.hoveredResizeTrailing == isTrailing
    }

    var body: some View {
        ZStack(alignment: isTrailing ? .bottomTrailing : .bottomLeading) {
            Color.clear
            if isHighlighted || isHovered {
                Image(systemName: "line.diagonal")
                    .font(.system(size: 8.5, weight: .semibold))
                    .rotationEffect(.degrees(isTrailing ? 0 : 90))
                    .foregroundStyle(isHovered ? Color.primary : Color.secondary.opacity(0.65))
                    .padding(3)
            }
        }
        .frame(width: 16, height: 16)
        .contentShape(Rectangle())
        .onHover { hovering in
            uiState.hoveredResizeTrailing = hovering ? isTrailing : (uiState.hoveredResizeTrailing == isTrailing ? nil : uiState.hoveredResizeTrailing)
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .onTapGesture(count: 2) {
            onReset()
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { _ in
                    let mouseX = NSEvent.mouseLocation.x
                    if uiState.resizeStartMouseX == nil {
                        uiState.resizeStartMouseX = mouseX
                        uiState.resizeStartWidth = currentWidth
                        PinnedWindowController.shared.beginResize(fromTrailingEdge: isTrailing)
                    }
                    guard let sMouse = uiState.resizeStartMouseX, let sWidth = uiState.resizeStartWidth else { return }
                    let delta = isTrailing ? (mouseX - sMouse) : (sMouse - mouseX)
                    let clamped = min(max(240, sWidth + delta), maxWidth).rounded()
                    onWidthChange(clamped)
                }
                .onEnded { _ in
                    uiState.resizeStartMouseX = nil
                    uiState.resizeStartWidth = nil
                    PinnedWindowController.shared.endResize()
                }
        )
        .help("Ziehen zum Skalieren · Doppelklick = Auto-Breite")
    }
}

private struct AgentCardView: View {
    let snapshot: AgentSnapshot
    let isPrimary: Bool
    let viewMode: ViewDensityMode
    let isNarrow: Bool
    let preferredLauncher: PreferredLauncher
    let showEstimatedCost: Bool
    let isUsageExpanded: Bool
    let onToggleUsage: () -> Void

    var body: some View {
        Group {
            if viewMode == .minimal {
                minimalBody
            } else {
                standardBody
            }
        }
        .padding(viewMode == .minimal ? 7 : 10)
        .background(
            RoundedRectangle(cornerRadius: viewMode == .minimal ? 8 : 10, style: .continuous)
                .fill(Color.primary.opacity(isPrimary ? 0.06 : 0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: viewMode == .minimal ? 8 : 10, style: .continuous)
                .strokeBorder(
                    snapshot.state.isWaitingForUser
                        ? statusColor.opacity(0.65)
                        : (snapshot.state.isLive ? statusColor.opacity(0.35) : Color.primary.opacity(0.08)),
                    lineWidth: snapshot.state.isWaitingForUser ? 1.25 : 1
                )
        )
        .contextMenu {
            if let path = snapshot.projectPath {
                ForEach(ProjectLauncher.availableTargets()) { target in
                    Button("In \(target.title) öffnen") {
                        ProjectLauncher.open(path: path, with: target)
                    }
                }
                Divider()
                Button("Pfad kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            }
        }
    }

    private var shortAgentTag: String {
        switch snapshot.kind {
        case .antigravity: return "Agy"
        case .codex: return "Codex"
        case .custom: return snapshot.agentLabel
        }
    }

    private var minimalBody: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)

                Text(shortAgentTag)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4.5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.06), in: Capsule())

                if let path = snapshot.projectPath {
                    Button {
                        ProjectLauncher.open(path: path, agentKind: snapshot.kind, preferred: preferredLauncher)
                    } label: {
                        Text(snapshot.projectName)
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .help("In \(ProjectLauncher.resolveTarget(preferred: preferredLauncher, agentKind: snapshot.kind).title) öffnen (Rechtsklick für Auswahl)")
                } else {
                    Text(snapshot.projectName)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)

                if snapshot.state.isWaitingForUser {
                    HStack(spacing: 3) {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 8.5, weight: .semibold))
                        Text("Wartet")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.14), in: Capsule())
                    .lineLimit(1)
                } else if snapshot.state.isLive, let since = snapshot.activeSince {
                    LiveDurationLabel(since: since, prefix: "")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.green)
                        .lineLimit(1)
                } else if let updated = snapshot.lastUpdated {
                    Text(Formatters.relativeTime(from: updated))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            if let statusMessage = snapshot.statusMessage, snapshot.projectName == "—" {
                Text(statusMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                HStack(spacing: 5) {
                    Text(snapshot.modelName)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let effort = snapshot.reasoningEffort, !isNarrow {
                        EffortBadge(rawEffort: effort)
                            .fixedSize()
                    }

                    Spacer(minLength: 4)

                    if let primary = snapshot.usage.primaryLimit {
                        LimitPill(limit: primary)
                    } else if let branch = snapshot.gitBranch {
                        Text(branch)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var standardBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Row 1: Agent + State + Relative Time
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)

                Text(snapshot.agentLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Group {
                    if snapshot.state.isWaitingForUser {
                        HStack(spacing: 3.5) {
                            Image(systemName: "hand.raised.fill")
                                .font(.system(size: 8.5, weight: .semibold))
                            Text(snapshot.interactionReason ?? snapshot.state.rawValue)
                        }
                    } else if snapshot.state.isLive, let since = snapshot.activeSince {
                        LiveDurationLabel(since: since, prefix: "Aktiv · ")
                    } else {
                        Text(snapshot.state.rawValue)
                    }
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(statusColor.opacity(snapshot.state.isWaitingForUser ? 0.16 : 0.12), in: Capsule())

                Spacer()

                if let updated = snapshot.lastUpdated {
                    Text(Formatters.relativeTime(from: updated))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            if let statusMessage = snapshot.statusMessage, snapshot.projectName == "—" {
                Text(statusMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                // Row 2: Project + Git Branch
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Text(snapshot.projectName)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let branch = snapshot.gitBranch {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 9))
                            Text(branch)
                                .font(.system(size: 10.5, design: .monospaced))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                    }

                    Spacer(minLength: 0)

                    if let path = snapshot.projectPath {
                        Button {
                            ProjectLauncher.open(path: path, agentKind: snapshot.kind, preferred: preferredLauncher)
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("In \(ProjectLauncher.resolveTarget(preferred: preferredLauncher, agentKind: snapshot.kind).title) öffnen · \(path)")
                    }
                }

                // Row 3: Model + Strength
                HStack(spacing: 6) {
                    Image(systemName: "cpu")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Text(snapshot.modelName)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let effort = snapshot.reasoningEffort {
                        EffortBadge(rawEffort: effort)
                            .fixedSize()
                            .layoutPriority(1)
                    }

                    Spacer(minLength: 4)

                    if let plan = snapshot.usage.planType {
                        Text(plan.uppercased())
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }

                // Row 4: Usage Info
                usageSection
            }
        }
    }

    private var costEstimate: CostEstimate? {
        guard showEstimatedCost else { return nil }
        return CostEstimator.estimate(usage: snapshot.usage, modelName: snapshot.modelName)
    }

    @ViewBuilder
    private var usageSection: some View {
        let usage = snapshot.usage
        let hasAnyUsage = usage.sessionTotalTokens != nil || usage.contextTokens != nil || usage.primaryLimit != nil || usage.stepCount != nil

        if hasAnyUsage {
            VStack(alignment: .leading, spacing: 5) {
                if let ratio = usage.contextFillRatio,
                   let used = usage.contextTokens,
                   let window = usage.contextWindow {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("Kontext")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Spacer()
                            let prefix = usage.isContextWindowEstimated ? "~" : ""
                            Text("\(Formatters.compactTokens(used)) / \(prefix)\(Formatters.compactTokens(window))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.1))
                                Capsule()
                                    .fill(ratio > 0.85 ? Color.orange : Color.accentColor)
                                    .frame(width: max(4, geo.size.width * ratio))
                            }
                        }
                        .frame(height: 4)
                    }
                } else if let used = usage.contextTokens {
                    HStack {
                        Text("Kontext")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Formatters.compactTokens(used)) tok")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    if let total = usage.sessionTotalTokens {
                        Label(
                            "\(Formatters.compactTokens(total)) tok",
                            systemImage: "gauge.with.dots.needle.33percent"
                        )
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    }
                    if let steps = usage.stepCount {
                        Label("\(steps) Steps", systemImage: "list.bullet")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    if let cost = costEstimate {
                        Text(cost.formatted)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .help(cost.isEstimated ? "Geschätzte Session-Kosten (Basis: Token-Preise)" : "Erfasste Session-Kosten")
                    }

                    Spacer()

                    if let primary = usage.primaryLimit {
                        LimitPill(limit: primary)
                    }
                    if let secondary = usage.secondaryLimit {
                        LimitPill(limit: secondary)
                    }

                    if hasDetailedUsage {
                        Button(action: onToggleUsage) {
                            HStack(spacing: 3) {
                                Text("Usage")
                                Image(systemName: isUsageExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 8.5, weight: .semibold))
                            }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Token-Nutzung im Detail")
                    }
                }

                if (isUsageExpanded || viewMode == .detailed) && hasDetailedUsage {
                    usageDetailView(usage)
                }
            }
            .padding(.top, 2)
        }
    }

    private var hasDetailedUsage: Bool {
        let u = snapshot.usage
        return u.inputTokens != nil || u.cacheReadTokens != nil || u.outputTokens != nil || u.primaryLimit != nil || costEstimate != nil
    }

    @ViewBuilder
    private func usageDetailView(_ usage: UsageMetrics) -> some View {
        let hasTokenChips = usage.inputTokens != nil || usage.cacheReadTokens != nil || usage.outputTokens != nil || costEstimate != nil
        let limits = [usage.primaryLimit, usage.secondaryLimit]
            .compactMap { $0 }
            .sorted { $0.windowMinutes > $1.windowMinutes }

        VStack(alignment: .leading, spacing: 6) {
            if hasTokenChips {
                HStack(spacing: 8) {
                    if let inp = usage.inputTokens {
                        UsageChip(label: "In", value: Formatters.compactTokens(inp))
                    }
                    if let cache = usage.cacheReadTokens {
                        UsageChip(label: "Cache", value: Formatters.compactTokens(cache))
                    }
                    if let out = usage.outputTokens {
                        UsageChip(label: "Out", value: Formatters.compactTokens(out))
                    }
                    Spacer()
                    if let cost = costEstimate {
                        UsageChip(label: cost.isEstimated ? "Est." : "Cost", value: cost.formatted)
                    }
                }
            }

            if !limits.isEmpty {
                if hasTokenChips {
                    Divider().opacity(0.45)
                }

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(limits.enumerated()), id: \.offset) { _, limit in
                        LimitDetailRow(limit: limit)
                    }
                }
            } else if snapshot.kind == .antigravity {
                Text("Account-Quota % wird von Antigravity nicht lokal gespeichert.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var statusColor: Color {
        switch snapshot.state {
        case .needsInput: return .orange
        case .running: return .green
        case .idle: return .blue
        case .offline: return .orange
        case .unavailable: return .secondary
        }
    }
}

private struct UsageChip: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .foregroundStyle(.tertiary)
            Text(value)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 10, design: .monospaced))
    }
}

private struct EffortBadge: View {
    let rawEffort: String

    private var label: String {
        switch rawEffort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "low": return "Low"
        case "medium", "med": return "Medium"
        case "high": return "High"
        case "xhigh", "extra", "extra_high", "extra high": return "Extra High"
        case "minimal": return "Minimal"
        case "fast": return "Fast"
        default: return rawEffort
        }
    }

    private var tint: Color {
        switch rawEffort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "low", "minimal", "fast": return .teal
        case "medium", "med": return .blue
        case "high": return .orange
        case "xhigh", "extra", "extra_high", "extra high": return .purple
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 8.5))
            Text(label)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

private struct CircularQuotaRing: View {
    let remainingFraction: Double
    var size: CGFloat = 15
    var lineWidth: CGFloat = 2.2

    private var clampedFraction: Double {
        min(max(remainingFraction, 0), 1)
    }

    private var ringColor: Color {
        if clampedFraction <= 0 { return .secondary }
        if clampedFraction <= 0.15 { return .red }
        if clampedFraction <= 0.35 { return .orange }
        return .green
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.14), lineWidth: lineWidth)

            if clampedFraction > 0 {
                Circle()
                    .trim(from: 0, to: clampedFraction)
                    .stroke(
                        ringColor,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: size, height: size)
    }
}

private struct LimitDetailRow: View {
    let limit: RateLimitWindow

    private var remainingInt: Int {
        Int(limit.remainingPercent.rounded())
    }

    private var percentColor: Color {
        if remainingInt == 0 { return .secondary }
        if remainingInt <= 15 { return .red }
        if remainingInt <= 35 { return .orange }
        return .primary
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Formatters.limitTitle(limit.windowMinutes))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                Text("Resets \(Formatters.resetLabel(limit.resetsAt))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                Text("\(remainingInt)% left")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(percentColor)

                CircularQuotaRing(
                    remainingFraction: limit.remainingFraction,
                    size: 15,
                    lineWidth: 2.2
                )
            }
        }
    }
}

private struct LimitPill: View {
    let limit: RateLimitWindow

    private var remainingInt: Int {
        Int(limit.remainingPercent.rounded())
    }

    private var pillColor: Color {
        if remainingInt <= 15 { return .red }
        if remainingInt <= 35 { return .orange }
        return .green
    }

    var body: some View {
        HStack(spacing: 4) {
            CircularQuotaRing(
                remainingFraction: limit.remainingFraction,
                size: 10,
                lineWidth: 1.6
            )
            Text(Formatters.windowLabel(limit.windowMinutes))
                .foregroundStyle(.secondary)
            Text("\(remainingInt)%")
                .fontWeight(.semibold)
                .foregroundStyle(remainingInt <= 35 ? pillColor : .primary)
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(pillColor.opacity(0.10), in: Capsule())
        .help("\(Formatters.limitTitle(limit.windowMinutes)): \(remainingInt)% left · Resets \(Formatters.resetLabel(limit.resetsAt))")
    }
}

private struct LiveDurationLabel: View {
    let since: Date
    let prefix: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            Text("\(prefix)\(Formatters.elapsedDuration(from: since, to: context.date))")
                .monospacedDigit()
        }
    }
}

private enum Formatters {
    static func compactTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000)
        }
        return "\(count)"
    }

    static func windowLabel(_ minutes: Int) -> String {
        if minutes >= 1440 {
            return "\(minutes / 1440)d"
        }
        if minutes >= 60 {
            return "\(minutes / 60)h"
        }
        return "\(minutes)m"
    }

    static func limitTitle(_ minutes: Int) -> String {
        if minutes == 10_080 {
            return "Weekly limit"
        }
        if minutes >= 1440 {
            return "\(minutes / 1440)d limit"
        }
        if minutes >= 60 {
            return "\(minutes / 60)h limit"
        }
        return "\(minutes)m limit"
    }

    static func elapsedDuration(from start: Date, to end: Date) -> String {
        let total = max(0, Int(end.timeIntervalSince(start)))
        let hours = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%dh %02dm", hours, mins)
        }
        if mins > 0 {
            return "\(mins)m \(secs)s"
        }
        return "\(secs)s"
    }

    static func relativeTime(from date: Date) -> String {
        let diff = Int(Date().timeIntervalSince(date))
        if diff < 10 { return "gerade eben" }
        if diff < 60 { return "vor \(diff)s" }
        if diff < 3600 { return "vor \(diff / 60)m" }
        if diff < 86400 { return "vor \(diff / 3600)h" }
        return "vor \(diff / 86400)d"
    }

    static func resetLabel(_ date: Date?) -> String {
        guard let date else { return "—" }
        let diff = Int(date.timeIntervalSinceNow)
        if diff <= 0 { return "jetzt" }
        let hours = diff / 3600
        let mins = (diff % 3600) / 60
        if hours >= 24 {
            let days = hours / 24
            let remHours = hours % 24
            return "in \(days)d \(remHours)h"
        }
        if hours > 0 {
            return "in \(hours)h \(mins)m"
        }
        return "in \(mins)m"
    }
}
