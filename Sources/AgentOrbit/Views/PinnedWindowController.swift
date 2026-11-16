import AgentOrbitCore
import AppKit
import SwiftUI

private final class FloatingPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class SnapGridOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct SnapGridOverlayState: Equatable {
    var screenFrame: CGRect
    var safeRectInView: CGRect
    var previewRectInView: CGRect
    var anchorCentersInView: [CGPoint]
    var isOptionBypassed: Bool
    var isAnchorSnap: Bool
}

private struct SnapGridOverlayView: View {
    let state: SnapGridOverlayState
    private let gridStep: CGFloat = 24

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                let safe = state.safeRectInView

                // Subtle 24pt desktop grid dots
                let dotColor = Color.primary.opacity(state.isOptionBypassed ? 0.06 : 0.18)
                var x = safe.minX
                while x <= safe.maxX + 0.5 {
                    var y = safe.minY
                    while y <= safe.maxY + 0.5 {
                        let dotRect = CGRect(x: x - 1, y: y - 1, width: 2, height: 2)
                        context.fill(Path(ellipseIn: dotRect), with: .color(dotColor))
                        y += gridStep
                    }
                    x += gridStep
                }

                // 9 main screen anchor markers (crosshairs)
                if !state.isOptionBypassed {
                    let markerColor = Color.accentColor.opacity(0.45)
                    for pt in state.anchorCentersInView {
                        var cross = Path()
                        cross.move(to: CGPoint(x: pt.x - 7, y: pt.y))
                        cross.addLine(to: CGPoint(x: pt.x + 7, y: pt.y))
                        cross.move(to: CGPoint(x: pt.x, y: pt.y - 7))
                        cross.addLine(to: CGPoint(x: pt.x, y: pt.y + 7))
                        context.stroke(cross, with: .color(markerColor), lineWidth: 1.4)
                    }
                }
            }

            if !state.isOptionBypassed {
                let preview = state.previewRectInView
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(state.isAnchorSnap ? 0.16 : 0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                Color.accentColor.opacity(state.isAnchorSnap ? 0.85 : 0.62),
                                style: StrokeStyle(lineWidth: 1.75, dash: state.isAnchorSnap ? [] : [5, 4])
                            )
                    )
                    .frame(width: preview.width, height: preview.height)
                    .offset(x: preview.minX, y: preview.minY)
                    .animation(.easeOut(duration: 0.08), value: preview)
            } else {
                let preview = state.previewRectInView
                Text("Frei (⌥)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.75))
                    .offset(x: max(16, preview.minX + 8), y: max(16, preview.minY - 24))
            }
        }
        .frame(width: state.screenFrame.width, height: state.screenFrame.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

@MainActor
final class PinnedWindowController {
    static let shared = PinnedWindowController()

    private var panel: FloatingPreviewPanel?
    private weak var monitor: CoordinatorMonitor?
    private var overlayWindow: SnapGridOverlayWindow?

    private var resizeObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var flagsMonitor: Any?

    private var isProgrammaticFrameUpdate = false
    private var isUserDragging = false
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?

    private var horizontalAnchor: HorizontalSnapAnchor = .trailing
    private var verticalAnchor: VerticalSnapAnchor = .top
    private var anchoredMinX: CGFloat?
    private var anchoredMaxX: CGFloat?
    private var anchoredMinY: CGFloat?
    private var anchoredMaxY: CGFloat?

    private let originXKey = "AgentOrbit.PinnedOriginX"
    private let originYKey = "AgentOrbit.PinnedOriginY"
    private let maxXKey = "AgentOrbit.PinnedMaxX"
    private let maxYKey = "AgentOrbit.PinnedMaxY"
    private let hAnchorKey = "AgentOrbit.PinnedHAnchor"
    private let vAnchorKey = "AgentOrbit.PinnedVAnchor"
    private let legacyAnchorRightKey = "AgentOrbit.PinnedAnchorRight"

    private init() {}

    func setPinned(
        _ pinned: Bool,
        monitor: CoordinatorMonitor,
        uiState: PopoverUIState
    ) {
        self.monitor = monitor
        if pinned {
            show(monitor: monitor, uiState: uiState)
        } else {
            hide()
        }
    }

    func updateOpacity(_ opacity: Double) {
        let clamped = CGFloat(min(max(opacity, 0.45), 1.0))
        panel?.alphaValue = clamped
    }

    func handleDragChanged(mouseLocation: NSPoint) {
        guard let panel else { return }
        if dragStartMouse == nil {
            dragStartMouse = mouseLocation
            dragStartOrigin = panel.frame.origin
            isUserDragging = true
            installFlagsMonitor()
        }
        guard let startMouse = dragStartMouse, let startOrigin = dragStartOrigin else { return }
        let newOrigin = NSPoint(
            x: (startOrigin.x + (mouseLocation.x - startMouse.x)).rounded(),
            y: (startOrigin.y + (mouseLocation.y - startMouse.y)).rounded()
        )
        isProgrammaticFrameUpdate = true
        panel.setFrameOrigin(newOrigin)
        isProgrammaticFrameUpdate = false
        updateSnapOverlay(for: panel)
    }

    func handleDragEnded() {
        dragStartMouse = nil
        dragStartOrigin = nil
        removeFlagsMonitor()
        endDragSession(applySnap: true)
    }

    var prefersLeadingResizeGrip: Bool {
        horizontalAnchor == .trailing
    }

    func beginResize(fromTrailingEdge: Bool) {
        guard let panel else { return }
        // Lock the opposite edge while the user drags a corner grip
        horizontalAnchor = fromTrailingEdge ? .leading : .trailing
        anchoredMinX = panel.frame.minX
        anchoredMaxX = panel.frame.maxX
        anchoredMinY = panel.frame.minY
        anchoredMaxY = panel.frame.maxY
    }

    func endResize() {
        guard let panel else { return }
        repositionWithinVisibleFrame(panel)
        captureUserPosition(of: panel, horizontal: nil, vertical: nil)
    }

    private func show(monitor: CoordinatorMonitor, uiState: PopoverUIState) {
        if panel == nil {
            let rootView = PopoverView(monitor: monitor, uiState: uiState, isInPinnedPanel: true)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.75)
                )

            let hostingView = NSHostingView(rootView: rootView)
            hostingView.sizingOptions = [.intrinsicContentSize]

            let newPanel = FloatingPreviewPanel(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 280),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            newPanel.level = .floating
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            newPanel.isMovableByWindowBackground = false
            newPanel.hidesOnDeactivate = false
            newPanel.isOpaque = false
            newPanel.backgroundColor = .clear
            newPanel.alphaValue = CGFloat(min(max(monitor.config.hudOpacity, 0.45), 1.0))
            newPanel.hasShadow = true
            newPanel.contentView = hostingView

            hostingView.layoutSubtreeIfNeeded()
            let fitting = hostingView.fittingSize
            if fitting.width > 0, fitting.height > 0 {
                newPanel.setContentSize(fitting)
            }

            restorePosition(for: newPanel)
            installObservers(for: newPanel)
            self.panel = newPanel
        } else if let panel {
            panel.alphaValue = CGFloat(min(max(monitor.config.hudOpacity, 0.45), 1.0))
            repositionWithinVisibleFrame(panel)
        }

        panel?.orderFrontRegardless()
    }

    private func hide() {
        dragStartMouse = nil
        dragStartOrigin = nil
        removeFlagsMonitor()
        endDragSession(applySnap: false)
        panel?.orderOut(nil)
    }

    private func installObservers(for panel: NSPanel) {
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self, weak panel] _ in
            Task { @MainActor [weak self, weak panel] in
                guard let self, let panel, !self.isProgrammaticFrameUpdate, !self.isUserDragging else { return }
                self.repositionWithinVisibleFrame(panel)
            }
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self, weak panel] _ in
            Task { @MainActor [weak self, weak panel] in
                guard let self, let panel else { return }
                self.repositionWithinVisibleFrame(panel)
            }
        }
    }

    private func installFlagsMonitor() {
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel, self.isUserDragging else { return }
                self.updateSnapOverlay(for: panel)
            }
            return event
        }
    }

    private func removeFlagsMonitor() {
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
    }

    private func endDragSession(applySnap: Bool) {
        let wasDragging = isUserDragging
        isUserDragging = false
        hideSnapOverlay()

        guard applySnap, wasDragging, let panel else { return }

        let snapEnabled = monitor?.config.snapToGrid ?? true
        let optionHeld = NSEvent.modifierFlags.contains(.option)

        if snapEnabled && !optionHeld,
           let screen = targetScreen(for: panel.frame) ?? NSScreen.main ?? NSScreen.screens.first {
            let result = GridSnapCalculator.snap(frame: panel.frame, visibleFrame: screen.visibleFrame)
            animatePanelOrigin(panel, to: result.origin)
            captureFrameAnchors(
                frame: CGRect(origin: result.origin, size: panel.frame.size),
                horizontal: result.horizontalAnchor,
                vertical: result.verticalAnchor
            )
        } else {
            clampFreePosition(panel)
            captureUserPosition(of: panel, horizontal: nil, vertical: nil)
        }
    }

    private func updateSnapOverlay(for panel: NSPanel) {
        guard (monitor?.config.snapToGrid ?? true) else {
            hideSnapOverlay()
            return
        }
        guard let screen = targetScreen(for: panel.frame) ?? NSScreen.main ?? NSScreen.screens.first else {
            return
        }

        let optionHeld = NSEvent.modifierFlags.contains(.option)
        let snapResult = GridSnapCalculator.snap(frame: panel.frame, visibleFrame: screen.visibleFrame)
        let screenFrame = screen.frame
        let safeInView = toViewRect(snapResult.safeFrame, in: screenFrame)
        let previewFrame = optionHeld
            ? panel.frame
            : CGRect(origin: snapResult.origin, size: panel.frame.size)
        let previewInView = toViewRect(previewFrame, in: screenFrame)

        let anchorRects = GridSnapCalculator.anchorFrames(for: panel.frame.size, visibleFrame: screen.visibleFrame)
        let anchorCenters = anchorRects.map { rect -> CGPoint in
            let r = toViewRect(rect, in: screenFrame)
            return CGPoint(x: r.midX, y: r.midY)
        }

        let overlayState = SnapGridOverlayState(
            screenFrame: screenFrame,
            safeRectInView: safeInView,
            previewRectInView: previewInView,
            anchorCentersInView: anchorCenters,
            isOptionBypassed: optionHeld,
            isAnchorSnap: snapResult.isSnappedToAnchor
        )

        showSnapOverlay(state: overlayState, screenFrame: screenFrame)
    }

    private func showSnapOverlay(state: SnapGridOverlayState, screenFrame: CGRect) {
        let view = SnapGridOverlayView(state: state)
        if let overlayWindow {
            if overlayWindow.frame != screenFrame {
                overlayWindow.setFrame(screenFrame, display: false)
            }
            if let hosting = overlayWindow.contentView as? NSHostingView<SnapGridOverlayView> {
                hosting.rootView = view
            } else {
                overlayWindow.contentView = NSHostingView(rootView: view)
            }
            if !overlayWindow.isVisible {
                overlayWindow.orderFrontRegardless()
            }
            return
        }

        let win = SnapGridOverlayWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        win.ignoresMouseEvents = true
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.contentView = NSHostingView(rootView: view)
        win.orderFrontRegardless()
        overlayWindow = win
    }

    private func hideSnapOverlay() {
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
    }

    private func animatePanelOrigin(_ panel: NSPanel, to origin: CGPoint) {
        guard panel.frame.origin != origin else { return }
        isProgrammaticFrameUpdate = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.13
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrameOrigin(origin)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.isProgrammaticFrameUpdate = false
            }
        }
    }

    private func clampFreePosition(_ panel: NSPanel) {
        guard let screen = targetScreen(for: panel.frame) ?? NSScreen.main ?? NSScreen.screens.first else {
            return
        }
        let safe = GridSnapCalculator.safeBounds(visibleFrame: screen.visibleFrame, margin: 4)
        let maxX = max(safe.minX, safe.maxX - panel.frame.width)
        let maxY = max(safe.minY, safe.maxY - panel.frame.height)
        let clampedX = min(max(panel.frame.origin.x, safe.minX), maxX).rounded()
        let clampedY = min(max(panel.frame.origin.y, safe.minY), maxY).rounded()
        let target = NSPoint(x: clampedX, y: clampedY)
        guard panel.frame.origin != target else { return }
        isProgrammaticFrameUpdate = true
        panel.setFrameOrigin(target)
        isProgrammaticFrameUpdate = false
    }

    private func toViewRect(_ globalRect: CGRect, in screenFrame: CGRect) -> CGRect {
        CGRect(
            x: globalRect.minX - screenFrame.minX,
            y: screenFrame.maxY - globalRect.maxY,
            width: globalRect.width,
            height: globalRect.height
        )
    }

    private func captureUserPosition(
        of panel: NSPanel,
        horizontal: HorizontalSnapAnchor?,
        vertical: VerticalSnapAnchor?
    ) {
        let frame = panel.frame
        let screen = targetScreen(for: frame)
        let resolvedH: HorizontalSnapAnchor = horizontal ?? {
            if let visible = screen?.visibleFrame {
                return frame.midX >= visible.midX ? .trailing : .leading
            }
            return .trailing
        }()
        let resolvedV: VerticalSnapAnchor = vertical ?? {
            if let visible = screen?.visibleFrame {
                return frame.midY >= visible.midY ? .top : .bottom
            }
            return .top
        }()
        captureFrameAnchors(frame: frame, horizontal: resolvedH, vertical: resolvedV)
    }

    private func captureFrameAnchors(
        frame: CGRect,
        horizontal: HorizontalSnapAnchor,
        vertical: VerticalSnapAnchor
    ) {
        horizontalAnchor = horizontal
        verticalAnchor = vertical
        anchoredMinX = frame.minX
        anchoredMaxX = frame.maxX
        anchoredMinY = frame.minY
        anchoredMaxY = frame.maxY

        let defaults = UserDefaults.standard
        defaults.set(Double(frame.origin.x), forKey: originXKey)
        defaults.set(Double(frame.origin.y), forKey: originYKey)
        defaults.set(Double(frame.maxX), forKey: maxXKey)
        defaults.set(Double(frame.maxY), forKey: maxYKey)
        defaults.set(horizontal.rawValue, forKey: hAnchorKey)
        defaults.set(vertical.rawValue, forKey: vAnchorKey)
    }

    private func restorePosition(for panel: NSPanel) {
        let defaults = UserDefaults.standard
        let size = panel.frame.size

        if defaults.object(forKey: maxXKey) != nil,
           defaults.object(forKey: maxYKey) != nil {
            let savedMaxX = CGFloat(defaults.double(forKey: maxXKey))
            let savedMaxY = CGFloat(defaults.double(forKey: maxYKey))
            let savedMinX = CGFloat(defaults.double(forKey: originXKey))
            let savedMinY = CGFloat(defaults.double(forKey: originYKey))

            let savedH: HorizontalSnapAnchor = {
                if let raw = defaults.string(forKey: hAnchorKey), let parsed = HorizontalSnapAnchor(rawValue: raw) {
                    return parsed
                }
                let anchorRight = defaults.object(forKey: legacyAnchorRightKey) != nil
                    ? defaults.bool(forKey: legacyAnchorRightKey)
                    : true
                return anchorRight ? .trailing : .leading
            }()
            let savedV: VerticalSnapAnchor = {
                if let raw = defaults.string(forKey: vAnchorKey), let parsed = VerticalSnapAnchor(rawValue: raw) {
                    return parsed
                }
                return .top
            }()

            let probeX: CGFloat = switch savedH {
            case .trailing: savedMaxX - 10
            case .center: (savedMinX + savedMaxX) / 2
            case .leading: savedMinX + 10
            }
            let probeY: CGFloat = switch savedV {
            case .top: savedMaxY - 10
            case .center: (savedMinY + savedMaxY) / 2
            case .bottom: savedMinY + 10
            }

            let probePoint = NSPoint(x: probeX, y: probeY)
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(probePoint) }) {
                horizontalAnchor = savedH
                verticalAnchor = savedV
                anchoredMinX = savedMinX
                anchoredMaxX = savedMaxX
                anchoredMinY = savedMinY
                anchoredMaxY = savedMaxY
                repositionWithinVisibleFrame(panel)
                return
            }
        } else if defaults.object(forKey: originXKey) != nil,
                  defaults.object(forKey: originYKey) != nil {
            let savedMinX = CGFloat(defaults.double(forKey: originXKey))
            let savedMinY = CGFloat(defaults.double(forKey: originYKey))
            let probePoint = NSPoint(x: savedMinX + 10, y: savedMinY + 10)
            if let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(probePoint) }) {
                let legacyMaxX = savedMinX + 360
                horizontalAnchor = (savedMinX + 180) >= screen.visibleFrame.midX ? .trailing : .leading
                verticalAnchor = (savedMinY + size.height / 2) >= screen.visibleFrame.midY ? .top : .bottom
                anchoredMinX = savedMinX
                anchoredMaxX = min(legacyMaxX, screen.visibleFrame.maxX - 12)
                anchoredMinY = savedMinY
                anchoredMaxY = min(savedMinY + size.height, screen.visibleFrame.maxY - 12)
                repositionWithinVisibleFrame(panel)
                return
            }
        }

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            horizontalAnchor = .trailing
            verticalAnchor = .top
            anchoredMaxX = visible.maxX - 12
            anchoredMaxY = visible.maxY - 12
            anchoredMinX = (anchoredMaxX ?? visible.maxX) - size.width
            anchoredMinY = (anchoredMaxY ?? visible.maxY) - size.height
            repositionWithinVisibleFrame(panel)
        }
    }

    private func repositionWithinVisibleFrame(_ panel: NSPanel) {
        let size = panel.frame.size
        guard let screen = targetScreen(for: panel.frame) ?? NSScreen.main ?? NSScreen.screens.first else {
            return
        }

        let targetOrigin = GridSnapCalculator.anchoredOrigin(
            size: size,
            visibleFrame: screen.visibleFrame,
            horizontalAnchor: horizontalAnchor,
            verticalAnchor: verticalAnchor,
            anchoredMinX: anchoredMinX,
            anchoredMaxX: anchoredMaxX,
            anchoredMinY: anchoredMinY,
            anchoredMaxY: anchoredMaxY
        )

        guard panel.frame.origin != targetOrigin else { return }

        isProgrammaticFrameUpdate = true
        panel.setFrameOrigin(targetOrigin)
        isProgrammaticFrameUpdate = false
    }

    private func targetScreen(for frame: NSRect) -> NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        if let exact = NSScreen.screens.first(where: { $0.visibleFrame.contains(center) }) {
            return exact
        }
        return NSScreen.screens.max { a, b in
            a.visibleFrame.intersection(frame).area < b.visibleFrame.intersection(frame).area
        }
    }
}

private extension NSRect {
    var area: CGFloat {
        isNull ? 0 : width * height
    }
}
