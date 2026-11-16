import AgentOrbitCore
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
    }
}

@main
struct AgentOrbitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor: CoordinatorMonitor
    @StateObject private var uiState: PopoverUIState

    init() {
        let monitor = CoordinatorMonitor()
        let uiState = PopoverUIState()
        monitor.onSessionsCompleted = { [weak monitor] events in
            let playSound = monitor?.config.notifySound ?? true
            CompletionNotifier.shared.notify(events, playSound: playSound)
        }
        monitor.onSessionsNeedsInput = { [weak monitor] events in
            let playSound = monitor?.config.notifySound ?? true
            CompletionNotifier.shared.notifyNeedsInput(events, playSound: playSound)
        }
        CompletionNotifier.shared.prepareIfNeeded(
            enabled: monitor.config.notifyOnCompletion || monitor.config.notifyOnNeedsInput
        )
        _monitor = StateObject(wrappedValue: monitor)
        _uiState = StateObject(wrappedValue: uiState)
        HotKeyController.shared.configure(preset: monitor.config.hotKeyPreset) { [weak monitor, weak uiState] in
            guard let monitor, let uiState else { return }
            let next = !uiState.isPinned
            uiState.isPinned = next
            PinnedWindowController.shared.setPinned(next, monitor: monitor, uiState: uiState)
        }
        if uiState.isPinned {
            DispatchQueue.main.async {
                PinnedWindowController.shared.setPinned(true, monitor: monitor, uiState: uiState)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(monitor: monitor, uiState: uiState)
        } label: {
            HStack(spacing: 4) {
                Image(nsImage: BrandIconFactory.menuBarImage(
                    isLive: monitor.isAnyLive,
                    needsInput: monitor.isAnyWaitingForUser
                ))
                    .renderingMode(.template)

                if monitor.needsInputCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 8.5, weight: .bold))
                        Text("\(monitor.needsInputCount)")
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 4.5)
                    .padding(.vertical, 0.5)
                    .background(Color.orange.opacity(0.24), in: Capsule())
                    .foregroundStyle(.orange)
                }

                if monitor.liveSessionCount > 1 || (monitor.liveSessionCount > 0 && monitor.needsInputCount > 0) {
                    Text("\(monitor.liveSessionCount)")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .padding(.horizontal, 4)
                        .padding(.vertical, 0.5)
                        .background(Color.green.opacity(0.22), in: Capsule())
                        .foregroundStyle(.green)
                }

                if let text = monitor.menuBarLabelText {
                    Text(text)
                        .font(.system(size: 12, weight: .medium))
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
