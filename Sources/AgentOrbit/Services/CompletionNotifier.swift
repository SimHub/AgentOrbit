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

    func notify(_ events: [CompletedSessionEvent], playSound: Bool) {
        guard !events.isEmpty, isAppBundle else { return }
        let center = UNUserNotificationCenter.current()

        if !hasRequestedAuthorization {
            hasRequestedAuthorization = true
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                guard granted else { return }
                Task { @MainActor in
                    Self.deliver(events, playSound: playSound)
                }
            }
            return
        }

        center.getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            guard allowed else { return }
            Task { @MainActor in
                Self.deliver(events, playSound: playSound)
            }
        }
    }

    private static func deliver(
        _ events: [CompletedSessionEvent],
        playSound: Bool
    ) {
        let center = UNUserNotificationCenter.current()
        for event in events {
            let content = UNMutableNotificationContent()
            content.title = "\(event.agentLabel) fertig"
            let durationText = formatDuration(event.durationSeconds)
            if event.projectName != "—" {
                content.body = "\(event.projectName) · \(durationText)"
            } else {
                content.body = "Session beendet nach \(durationText)"
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
