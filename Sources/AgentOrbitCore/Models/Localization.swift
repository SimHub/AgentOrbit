import Foundation

public enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case english = "en"
    case german = "de"

    public var id: String { rawValue }

    public var isGerman: Bool {
        switch self {
        case .german:
            return true
        case .english:
            return false
        case .system:
            return Locale.preferredLanguages.first?.lowercased().hasPrefix("de") == true
        }
    }

    public func title(in language: AppLanguage) -> String {
        switch self {
        case .system: return L10n.t("Auto", de: "Auto", language: language)
        case .english: return "English"
        case .german: return "Deutsch"
        }
    }
}

public enum L10n {
    public static func t(_ en: String, de: String, language: AppLanguage) -> String {
        language.isGerman ? de : en
    }

    public static func stateTitle(_ state: AgentRunState, language: AppLanguage) -> String {
        switch state {
        case .needsInput: return t("Needs input", de: "Eingabe nötig", language: language)
        case .running: return t("Active", de: "Aktiv", language: language)
        case .idle: return "Idle"
        case .offline: return "Offline"
        case .unavailable: return t("Not found", de: "Nicht gefunden", language: language)
        }
    }

    public static func reason(_ raw: String?, language: AppLanguage) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard !language.isGerman else { return raw }
        switch raw {
        case "Freigabe nötig": return "Approval needed"
        case "Patch-Freigabe": return "Patch approval"
        case "Freigabe / Eingabe": return "Approval / Input"
        case "Rückfrage": return "Question"
        case "Pausiert / Eingabe": return "Paused / Input"
        case "Eingabe nötig": return "Needs input"
        default: return raw
        }
    }

    public static func statusMessage(_ raw: String?, language: AppLanguage) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard !language.isGerman else { return raw }
        if raw.hasPrefix("SSD nicht gemountet (") {
            return raw.replacingOccurrences(of: "SSD nicht gemountet (", with: "SSD not mounted (")
        }
        switch raw {
        case "Ordner nicht gefunden": return "Folder not found"
        case "Noch keine Session": return "No sessions yet"
        case "Noch keine Aktivität": return "No activity yet"
        case "Noch keine Bionic-Session": return "No Bionic sessions yet"
        case "Keine aktive Konversation": return "No active conversation"
        case "Kein .codex Pfad konfiguriert": return "No .codex path configured"
        case "Kein .antigravity Pfad konfiguriert": return "No .antigravity path configured"
        case "Kein Pfad konfiguriert": return "No path configured"
        default: return raw
        }
    }

    public static func menuBarLabelTitle(_ mode: MenuBarLabelMode, language: AppLanguage) -> String {
        switch mode {
        case .iconOnly: return t("Icon only", de: "Nur Icon", language: language)
        case .project: return t("Project", de: "Projekt", language: language)
        case .projectAndModel: return t("Project · Model", de: "Projekt · Model", language: language)
        }
    }

    public static func viewModeTitle(_ mode: ViewDensityMode, language: AppLanguage) -> String {
        switch mode {
        case .minimal: return "Minimal"
        case .compact: return t("Compact", de: "Kompakt", language: language)
        case .detailed: return "Detail"
        }
    }

    public static func launcherTitle(_ target: PreferredLauncher, language: AppLanguage) -> String {
        switch target {
        case .auto: return t("Auto (matching)", de: "Auto (passend)", language: language)
        default: return target.title
        }
    }

    public static func hotKeyTitle(_ preset: HotKeyPreset, language: AppLanguage) -> String {
        switch preset {
        case .none: return t("Off", de: "Aus", language: language)
        default: return preset.title
        }
    }

    public static func relativeTime(from date: Date, language: AppLanguage, now: Date = Date()) -> String {
        let diff = max(0, Int(now.timeIntervalSince(date)))
        if diff < 10 { return t("just now", de: "gerade eben", language: language) }
        if diff < 60 { return t("\(diff)s ago", de: "vor \(diff)s", language: language) }
        if diff < 3600 { return t("\(diff / 60)m ago", de: "vor \(diff / 60)m", language: language) }
        if diff < 86400 { return t("\(diff / 3600)h ago", de: "vor \(diff / 3600)h", language: language) }
        return t("\(diff / 86400)d ago", de: "vor \(diff / 86400)d", language: language)
    }

    public static func resetTimeLabel(_ date: Date?, language: AppLanguage, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let diff = Int(date.timeIntervalSince(now))
        if diff <= 0 { return t("now", de: "jetzt", language: language) }
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
