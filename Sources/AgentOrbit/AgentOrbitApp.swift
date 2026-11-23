import AgentOrbitCore
import AppKit
import SwiftUI

enum AppMetadata {
    static var version: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "dev" : trimmed
    }
}

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
            let language = monitor?.config.appLanguage ?? .system
            CompletionNotifier.shared.notify(events, playSound: playSound, language: language)
        }
        monitor.onSessionsNeedsInput = { [weak monitor] events in
            let playSound = monitor?.config.notifySound ?? true
            let language = monitor?.config.appLanguage ?? .system
            CompletionNotifier.shared.notifyNeedsInput(events, playSound: playSound, language: language)
        }
        CompletionNotifier.shared.prepareIfNeeded(
            enabled: monitor.config.notifyOnCompletion || monitor.config.notifyOnNeedsInput
        )
        _monitor = StateObject(wrappedValue: monitor)
        _uiState = StateObject(wrappedValue: uiState)
        HotKeyController.shared.configure(config: monitor.config) { [weak monitor, weak uiState] action in
            guard let monitor, let uiState else { return }
            switch action {
            case .toggleHUD:
                uiState.isPinned.toggle()
                PinnedWindowController.shared.setPinned(uiState.isPinned, monitor: monitor, uiState: uiState)
            case .cycleView:
                uiState.cycleView(on: monitor)
            case .toggleActiveProjects:
                monitor.config.showAllActiveProjects.toggle()
            }
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
