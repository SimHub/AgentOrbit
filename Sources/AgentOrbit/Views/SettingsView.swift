import AgentOrbitCore
import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case display
    case agents
    case folders

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .display: "slider.horizontal.3"
        case .agents: "cpu"
        case .folders: "folder"
        }
    }

    func title(in language: AppLanguage) -> String {
        switch self {
        case .display: return L10n.t("Display", de: "Anzeige", language: language)
        case .agents: return "Agents"
        case .folders: return L10n.t("Folders", de: "Ordner", language: language)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var monitor: CoordinatorMonitor
    @ObservedObject var uiState: PopoverUIState
    @ObservedObject private var launchAtLogin = LaunchAtLoginController.shared
    @ObservedObject private var hotKeys = HotKeyController.shared
    let onDone: () -> Void

    private var lang: AppLanguage {
        monitor.config.appLanguage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases) { tab in
                    let selected = uiState.settingsTab == tab
                    Button {
                        uiState.settingsTab = tab
                    } label: {
                        Label(tab.title(in: lang), systemImage: tab.icon)
                            .font(.system(size: 11, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                selected ? Color.accentColor.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

            Group {
                switch uiState.settingsTab {
                case .display:
                    displayTab
                case .agents:
                    agentsTab
                case .folders:
                    foldersTab
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if uiState.settingsTab == .agents {
                    Button(L10n.t("Auto-Detect", de: "Auto-Erkennen", language: lang)) {
                        let added = monitor.runAutoDiscovery()
                        uiState.discoveryStatusMessage = added > 0
                            ? L10n.t("+\(added) found", de: "+\(added) erkannt", language: lang)
                            : L10n.t("Up to date", de: "Alles aktuell", language: lang)
                    }
                    .font(.system(size: 11))

                    Button(L10n.t("Defaults", de: "Standard", language: lang)) {
                        let defaults = KoordinatorConfig.defaultConfig
                        monitor.config.codexPath = defaults.codexPath
                        monitor.config.antigravityPath = defaults.antigravityPath
                        uiState.discoveryStatusMessage = nil
                    }
                    .font(.system(size: 11))

                    if let msg = uiState.discoveryStatusMessage {
                        Text(msg)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                } else if uiState.settingsTab == .display,
                          (uiState.customPinnedWidth != nil || uiState.customPinnedMaxHeight != nil) {
                    Button(L10n.t("Reset Auto-Size", de: "Auto-Größe", language: lang)) {
                        uiState.customPinnedWidth = nil
                        uiState.customPinnedMaxHeight = nil
                    }
                    .font(.system(size: 10.5))
                }

                Spacer()

                Button(L10n.t("Done", de: "Fertig", language: lang), action: onDone)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            HStack(spacing: 6) {
                Text("AgentOrbit v\(AppMetadata.version)")
                    .foregroundStyle(.tertiary)

                Spacer()

                if let repoURL = URL(string: "https://github.com/SimHub/AgentOrbit") {
                    Link("GitHub", destination: repoURL)
                        .foregroundStyle(.secondary)
                }
                Text("·")
                    .foregroundStyle(.tertiary)
                if let releasesURL = URL(string: "https://github.com/SimHub/AgentOrbit/releases") {
                    Link("Releases", destination: releasesURL)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 10))
        }
        .padding(12)
    }

    private var displayTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionCard(
                title: L10n.t("Appearance", de: "Darstellung", language: lang),
                systemImage: "paintbrush"
            ) {
                SettingControlRow(L10n.t("View", de: "Ansicht", language: lang)) {
                    Picker("", selection: $monitor.config.viewMode) {
                        ForEach(ViewDensityMode.allCases) { mode in
                            Text(L10n.viewModeTitle(mode, language: lang)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 224)
                }

                SettingControlRow(L10n.t("Menu Bar", de: "Menüleiste", language: lang)) {
                    Picker("", selection: $monitor.config.labelMode) {
                        ForEach(MenuBarLabelMode.allCases) { mode in
                            Text(L10n.menuBarLabelTitle(mode, language: lang)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 248)
                }

                SettingControlRow(L10n.t("Language", de: "Sprache", language: lang)) {
                    Picker("", selection: $monitor.config.appLanguage) {
                        ForEach(AppLanguage.allCases) { appLang in
                            Text(appLang.title(in: lang)).tag(appLang)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 224)
                }

                SettingControlRow(L10n.t("HUD Opacity", de: "HUD-Deckkraft", language: lang)) {
                    HStack(spacing: 6) {
                        Slider(value: $monitor.config.hudOpacity, in: 0.45...1.0, step: 0.05)
                            .controlSize(.mini)
                            .frame(width: 120)
                            .onChange(of: monitor.config.hudOpacity) { _, newOpacity in
                                PinnedWindowController.shared.updateOpacity(newOpacity)
                            }
                        Text("\(Int((monitor.config.hudOpacity * 100).rounded()))%")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }

            SettingsSectionCard(
                title: L10n.t("Workspace & Controls", de: "Workspace & Steuerung", language: lang),
                systemImage: "slider.horizontal.3"
            ) {
                SettingControlRow(L10n.t("Context Bar", de: "Kontext-Balken", language: lang)) {
                    Picker("", selection: $monitor.config.antigravityContextWindow) {
                        Text("Auto").tag(0)
                        Text("200k").tag(200_000)
                        Text("500k").tag(500_000)
                        Text("1M").tag(1_000_000)
                        Text(L10n.t("Off", de: "Aus", language: lang)).tag(-1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 248)
                }

                SettingControlRow(L10n.t("Launcher", de: "Starter", language: lang)) {
                    Picker("", selection: $monitor.config.preferredLauncher) {
                        ForEach(PreferredLauncher.allCases) { target in
                            Text(L10n.launcherTitle(target, language: lang)).tag(target)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 124)
                }

                SettingToggleRow(
                    L10n.t("Show all active projects", de: "Alle aktiven Projekte zeigen", language: lang),
                    isOn: $monitor.config.showAllActiveProjects
                )

                SettingToggleRow(
                    L10n.t("Snap-grid while dragging (⌥ = Free)", de: "Einrast-Grid beim Ziehen (⌥ = Frei)", language: lang),
                    isOn: $monitor.config.snapToGrid
                )

                SettingToggleRow(
                    L10n.t("Cost estimate (~$)", de: "Kosten-Schätzung (~$)", language: lang),
                    isOn: $monitor.config.showEstimatedCost
                )
            }

            SettingsSectionCard(
                title: L10n.t("Keyboard Shortcuts", de: "Tastenkürzel", language: lang),
                systemImage: "keyboard"
            ) {
                hotKeyRow(.toggleHUD, title: L10n.t("Toggle HUD", de: "HUD ein- und ausblenden", language: lang), icon: "macwindow")
                hotKeyRow(.cycleView, title: L10n.t("Switch view", de: "Ansicht wechseln", language: lang), icon: "rectangle.3.group")
                hotKeyRow(
                    .toggleActiveProjects,
                    title: L10n.t("Show all active projects", de: "Alle aktiven Projekte zeigen", language: lang),
                    icon: "square.stack"
                )
            }
            .onDisappear { hotKeys.cancelRecording() }

            SettingsSectionCard(
                title: L10n.t("Alerts & Startup", de: "Mitteilungen & Start", language: lang),
                systemImage: "bell.badge"
            ) {
                HStack(spacing: 8) {
                    Text(L10n.t("Completion (Active → Idle)", de: "Fertig-Meldung (Aktiv → Idle)", language: lang))
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Spacer()
                    if monitor.config.notifyOnCompletion || monitor.config.notifyOnNeedsInput {
                        Toggle(L10n.t("Sound", de: "Ton", language: lang), isOn: $monitor.config.notifySound)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .toggleStyle(.checkbox)
                            .controlSize(.mini)
                    }
                    Toggle("", isOn: $monitor.config.notifyOnCompletion)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .onChange(of: monitor.config.notifyOnCompletion) { _, enabled in
                            CompletionNotifier.shared.prepareIfNeeded(
                                enabled: enabled || monitor.config.notifyOnNeedsInput
                            )
                        }
                }

                SettingToggleRow(
                    L10n.t("Needs input (Approval / Question)", de: "Eingabe nötig (Freigabe / Rückfrage)", language: lang),
                    isOn: $monitor.config.notifyOnNeedsInput
                )
                .onChange(of: monitor.config.notifyOnNeedsInput) { _, enabled in
                    CompletionNotifier.shared.prepareIfNeeded(
                        enabled: enabled || monitor.config.notifyOnCompletion
                    )
                }

                HStack(spacing: 8) {
                    Text(L10n.t("Launch at login", de: "Bei Anmeldung starten", language: lang))
                        .font(.system(size: 11))
                        .lineLimit(1)
                    if launchAtLogin.requiresApproval {
                        Text(L10n.t("Approval needed", de: "Freigabe nötig", language: lang))
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { launchAtLogin.isEnabled },
                            set: { launchAtLogin.setEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
            }
        }
    }

    private func hotKeyRow(_ action: HotKeyAction, title: String, icon: String) -> some View {
        let isRecording = hotKeys.recordingAction == action
        let preset = monitor.config[keyPath: action.preference]
        let custom = monitor.config.customHotKeys[action]
        return HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
                .frame(width: 19)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                if isRecording {
                    Text(hotKeys.recordingError?.title(in: lang) ?? L10n.t("Press a shortcut…", de: "Tastenkürzel drücken …", language: lang))
                        .font(.system(size: 10))
                        .foregroundStyle(hotKeys.recordingError == nil ? Color.secondary : Color.orange)
                } else if hotKeys.registrationFailures.contains(action) {
                    Text(L10n.t("Shortcut unavailable", de: "Tastenkürzel nicht verfügbar", language: lang))
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 6)

            if isRecording {
                Button(L10n.t("Cancel", de: "Abbrechen", language: lang)) {
                    hotKeys.cancelRecording()
                }
                .controlSize(.small)
            } else {
                Menu {
                    ForEach(HotKeyPreset.allCases) { choice in
                        let isSelected = custom == nil && choice == preset
                        let occupied = hotKeys.isAssigned(choice, excluding: action, in: monitor.config)
                        let title = L10n.hotKeyTitle(choice, language: lang)
                        Button {
                            var config = monitor.config
                            config[keyPath: action.preference] = choice
                            config.customHotKeys[action] = nil
                            monitor.config = config
                            hotKeys.updateShortcuts(from: config)
                        } label: {
                            if isSelected {
                                Label(title, systemImage: "checkmark")
                            } else if occupied {
                                Text(L10n.t("\(title) (in use)", de: "\(title) (belegt)", language: lang))
                            } else {
                                Text(title)
                            }
                        }
                        .disabled(occupied && !isSelected)
                    }
                    Divider()
                    Button {
                        hotKeys.beginRecording(for: action) { [weak monitor = monitor, weak hotKeys = hotKeys] shortcut in
                            guard let monitor, let hotKeys else { return }
                            var config = monitor.config
                            config.customHotKeys[action] = shortcut
                            monitor.config = config
                            hotKeys.updateShortcuts(from: config)
                        }
                    } label: {
                        Label(L10n.t("Record custom shortcut…", de: "Eigenes Kürzel aufnehmen …", language: lang), systemImage: "keyboard")
                    }
                } label: {
                    Text(custom?.title ?? L10n.hotKeyTitle(preset, language: lang))
                        .lineLimit(1)
                        .frame(minWidth: 70)
                }
                .controlSize(.small)
                .accessibilityLabel(title)
                .disabled(hotKeys.recordingAction != nil)
            }
        }
        .padding(.vertical, 2)
    }

    private var agentsTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionCard(
                title: L10n.t("Built-in Agents", de: "Standard-Agents", language: lang),
                systemImage: "cpu"
            ) {
                PathInputRow(
                    title: ".codex",
                    path: $monitor.config.codexPath,
                    resolvedHint: monitor.codex.resolvedSourcePath,
                    language: lang
                )

                PathInputRow(
                    title: ".antigravity",
                    path: $monitor.config.antigravityPath,
                    resolvedHint: monitor.antigravity.resolvedSourcePath,
                    language: lang
                )
            }

            SettingsSectionCard(
                title: L10n.t("Additional Agents", de: "Weitere Agents", language: lang),
                systemImage: "puzzlepiece.extension"
            ) {
                HStack(spacing: 4) {
                    ForEach([
                        ("OpenCode", "~/.local/share/opencode"),
                        ("Bionic", "~/.cache/lm-studio/apps/bionic"),
                        ("Pi", "~/.pi/agent"),
                        ("Claude", "~/.claude")
                    ], id: \.0) { preset in
                        let exists = FileManager.default.fileExists(atPath: PathResolver.expandTilde(preset.1))
                        Button {
                            if exists && !monitor.config.customAgents.contains(where: { $0.name == preset.0 }) {
                                monitor.addCustomAgent(name: preset.0, path: preset.1)
                            } else {
                                uiState.newCustomAgentName = preset.0
                                uiState.newCustomAgentPath = preset.1
                            }
                        } label: {
                            HStack(spacing: 3) {
                                if exists {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 5, height: 5)
                                }
                                Text("+\(preset.0)")
                            }
                        }
                        .font(.system(size: 9.5, weight: .medium))
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help(
                            exists
                                ? L10n.t("\(preset.0) found – click to add", de: "\(preset.0) gefunden – klicken zum Hinzufügen", language: lang)
                                : L10n.t("Prefill path for \(preset.0)", de: "Vorausfüllen für \(preset.0)", language: lang)
                        )
                    }
                    Spacer()
                }

                HStack(spacing: 5) {
                    TextField("Name", text: $uiState.newCustomAgentName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 78)
                    TextField("~/.local/share/opencode", text: $uiState.newCustomAgentPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                    Button("…") {
                        if let chosen = pickDirectory(initialPath: uiState.newCustomAgentPath, language: lang) {
                            uiState.newCustomAgentPath = chosen
                        }
                    }
                    .font(.system(size: 11))
                    Button {
                        monitor.addCustomAgent(name: uiState.newCustomAgentName, path: uiState.newCustomAgentPath)
                        uiState.newCustomAgentName = ""
                        uiState.newCustomAgentPath = ""
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        uiState.newCustomAgentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        uiState.newCustomAgentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }

                if !monitor.config.customAgents.isEmpty {
                    VStack(spacing: 3) {
                        ForEach(monitor.config.customAgents) { agent in
                            HStack(spacing: 6) {
                                Button {
                                    monitor.toggleCustomAgent(id: agent.id)
                                } label: {
                                    Image(systemName: agent.isEnabled ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 11))
                                        .foregroundStyle(agent.isEnabled ? Color.accentColor : Color.secondary)
                                }
                                .buttonStyle(.plain)

                                Text(agent.name)
                                    .font(.system(size: 10.5, weight: .semibold))
                                Text(agent.path)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button {
                                    monitor.removeCustomAgent(id: agent.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
        }
    }

    private var foldersTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionCard(
                title: L10n.t("Watched Project Folders", de: "Überwachte Projekt-Ordner", language: lang),
                systemImage: "folder"
            ) {
                HStack(spacing: 6) {
                    TextField(L10n.t("/Volumes/.../Project", de: "/Volumes/.../Projekt", language: lang), text: $uiState.newFolderPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .onSubmit {
                            addEnteredFolder()
                        }

                    Button(L10n.t("Choose…", de: "Wählen…", language: lang)) {
                        if let chosen = pickDirectory(initialPath: uiState.newFolderPath, language: lang) {
                            monitor.addWatchedFolder(chosen)
                        }
                    }
                    .font(.system(size: 11))

                    Button {
                        addEnteredFolder()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .disabled(uiState.newFolderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if monitor.config.watchedFolders.isEmpty {
                    Text(L10n.t("Optional: Folders for project matching & live Git branch.", de: "Optional: Ordner für Projekt-Matching & Live-Git-Branch.", language: lang))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(spacing: 3) {
                        ForEach(monitor.config.watchedFolders, id: \.self) { folder in
                            HStack(spacing: 6) {
                                Text(folder)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                Spacer()
                                Button {
                                    monitor.removeWatchedFolder(folder)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }

            SettingsSectionCard(
                title: L10n.t("Model Aliases", de: "Model-Aliase", language: lang),
                systemImage: "tag"
            ) {
                HStack(spacing: 6) {
                    TextField("ID (M526)", text: $uiState.aliasKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 82)
                    TextField(L10n.t("Display name", de: "Anzeigename", language: lang), text: $uiState.aliasValue)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                    Button {
                        let k = uiState.aliasKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        let v = uiState.aliasValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !k.isEmpty, !v.isEmpty else { return }
                        monitor.config.antigravityModelAliases[k] = v
                        uiState.aliasKey = ""
                        uiState.aliasValue = ""
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .disabled(uiState.aliasKey.isEmpty || uiState.aliasValue.isEmpty)
                }

                ForEach(monitor.config.antigravityModelAliases.keys.sorted(), id: \.self) { key in
                    HStack {
                        Text("\(key) → \(monitor.config.antigravityModelAliases[key] ?? "")")
                            .font(.system(size: 10.5, design: .monospaced))
                        Spacer()
                        Button {
                            monitor.config.antigravityModelAliases.removeValue(forKey: key)
                        } label: {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private func addEnteredFolder() {
        let trimmed = uiState.newFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        monitor.addWatchedFolder(trimmed)
        uiState.newFolderPath = ""
    }
}

private struct SettingsSectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20, height: 20)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.bottom, 1)

            VStack(alignment: .leading, spacing: 6) {
                content
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.075), lineWidth: 0.75)
        )
    }
}

private struct SettingControlRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: Control

    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 6)
            control
        }
    }
}

private struct SettingToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }
}

private struct PathInputRow: View {
    let title: String
    @Binding var path: String
    let resolvedHint: String?
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .frame(width: 78, alignment: .leading)
                TextField(L10n.t("Enter path", de: "Pfad eingeben", language: language), text: $path)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                Button("…") {
                    if let chosen = pickDirectory(initialPath: path, language: language) {
                        path = chosen
                    }
                }
                .font(.system(size: 11))
            }
            if let resolvedHint, resolvedHint != PathResolver.expandTilde(path) {
                Text("↳ \(resolvedHint)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 84)
            }
        }
    }
}

@MainActor
private func pickDirectory(initialPath: String, language: AppLanguage) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.prompt = L10n.t("Select", de: "Auswählen", language: language)
    let expanded = PathResolver.expandTilde(initialPath)
    if !expanded.isEmpty {
        panel.directoryURL = URL(fileURLWithPath: expanded)
    }
    NSApp.activate(ignoringOtherApps: true)
    return panel.runModal() == .OK ? panel.url?.path : nil
}
