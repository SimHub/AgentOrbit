import AgentOrbitCore
import Foundation
import UserNotifications

@MainActor
final class CompletionNotifier {
    static let shared = CompletionNotifier()

    private var hasRequestedAuthorization = false

    private init() {}

    private var isAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    func prepareIfNeeded(enabled: Bool) {
        guard enabled, isAppBundle, !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(_ events: [CompletedSessionEvent], playSound: Bool, language: AppLanguage = .system) {
        guard !events.isEmpty else { return }
        enqueueAfterAuthorization {
            Self.deliverCompletion(events, playSound: playSound, language: language)
        }
    }

    func notifyNeedsInput(_ events: [NeedsInputEvent], playSound: Bool, language: AppLanguage = .system) {
        guard !events.isEmpty else { return }
        enqueueAfterAuthorization {
            Self.deliverNeedsInput(events, playSound: playSound, language: language)
        }
    }

    private func enqueueAfterAuthorization(_ action: @escaping @MainActor () -> Void) {
        guard isAppBundle else { return }
        let center = UNUserNotificationCenter.current()

        if !hasRequestedAuthorization {
            hasRequestedAuthorization = true
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                guard granted else { return }
                Task { @MainActor in
                    action()
                }
            }
            return
        }

        center.getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            guard allowed else { return }
            Task { @MainActor in
                action()
            }
        }
    }

    private static func deliverCompletion(
        _ events: [CompletedSessionEvent],
        playSound: Bool,
        language: AppLanguage
    ) {
        let center = UNUserNotificationCenter.current()
        for event in events {
            let content = UNMutableNotificationContent()
            content.title = L10n.t("\(event.agentLabel) finished", de: "\(event.agentLabel) fertig", language: language)
            let durationText = formatDuration(event.durationSeconds)
            if event.projectName != "—" {
                content.body = "\(event.projectName) · \(durationText)"
            } else {
                content.body = L10n.t("Session finished after \(durationText)", de: "Session beendet nach \(durationText)", language: language)
            }
            if playSound {
                content.sound = .default
            }

            let request = UNNotificationRequest(
                identifier: "agentorbit.done.\(event.id).\(Int(event.completedAt.timeIntervalSince1970))",
                content: content,
                trigger: nil
            )
            center.add(request, withCompletionHandler: nil)
        }
    }

    private static func deliverNeedsInput(
        _ events: [NeedsInputEvent],
        playSound: Bool,
        language: AppLanguage
    ) {
        let center = UNUserNotificationCenter.current()
        for event in events {
            let content = UNMutableNotificationContent()
            content.title = L10n.t("\(event.agentLabel) is waiting for you", de: "\(event.agentLabel) wartet auf dich", language: language)
            let localizedReason = L10n.reason(event.reason, language: language) ?? event.reason
            if event.projectName != "—" {
                content.body = "\(event.projectName) · \(localizedReason)"
            } else {
                content.body = localizedReason
            }
            if playSound {
                content.sound = .default
            }

            let request = UNNotificationRequest(
                identifier: "agentorbit.wait.\(event.id).\(Int(event.detectedAt.timeIntervalSince1970))",
                content: content,
                trigger: nil
            )
            center.add(request, withCompletionHandler: nil)
        }
    }

    private static func formatDuration(_ seconds: Int) -> String {
        let total = max(0, seconds)
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
}
