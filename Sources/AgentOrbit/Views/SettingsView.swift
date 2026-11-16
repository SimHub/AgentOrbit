import AgentOrbitCore
import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case display = "Anzeige"
    case agents = "Agents"
    case folders = "Ordner"

    var id: String { rawValue }
}

struct SettingsView: View {
    @ObservedObject var monitor: CoordinatorMonitor
    @ObservedObject var uiState: PopoverUIState
    @ObservedObject private var launchAtLogin = LaunchAtLoginController.shared
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $uiState.settingsTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

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

            Divider()

            HStack {
                if uiState.settingsTab == .agents {
                    Button("Auto-Erkennen") {
                        let added = monitor.runAutoDiscovery()
                        uiState.discoveryStatusMessage = added > 0 ? "+\(added) erkannt" : "Alles aktuell"
                    }
                    .font(.system(size: 11))

                    Button("Standardpfade") {
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
                } else if uiState.settingsTab == .display, let w = uiState.customPinnedWidth {
                    Button("Auto-Breite (\(Int(w)) pt)") {
                        uiState.customPinnedWidth = nil
                    }
                    .font(.system(size: 10.5))
                }

                Spacer()

                Button("Fertig", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(12)
    }

    private var displayTab: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Ansicht")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $monitor.config.viewMode) {
                    ForEach(ViewDensityMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
            }

            HStack {
                Text("Menüleiste")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $monitor.config.labelMode) {
                    ForEach(MenuBarLabelMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 225)
            }

            HStack {
                Text("Kontext-Balken")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $monitor.config.antigravityContextWindow) {
                    Text("Auto").tag(0)
                    Text("200k").tag(200_000)
                    Text("500k").tag(500_000)
                    Text("1M").tag(1_000_000)
                    Text("Aus").tag(-1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
            }

            HStack {
                Text("Projekt öffnen")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $monitor.config.preferredLauncher) {
                    ForEach(PreferredLauncher.allCases) { target in
                        Text(target.title).tag(target)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 145)
            }

            HStack {
                Text("HUD-Hotkey")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if HotKeyController.shared.registrationFailed {
                    Text("belegt")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Picker("", selection: $monitor.config.hotKeyPreset) {
                    ForEach(HotKeyPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 145)
                .onChange(of: monitor.config.hotKeyPreset) { _, nextPreset in
                    HotKeyController.shared.updatePreset(nextPreset)
                }
            }

            HStack(spacing: 8) {
                Text("HUD-Deckkraft")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Slider(value: $monitor.config.hudOpacity, in: 0.45...1.0, step: 0.05)
                    .controlSize(.mini)
                    .frame(width: 115)
                    .onChange(of: monitor.config.hudOpacity) { _, newOpacity in
                        PinnedWindowController.shared.updateOpacity(newOpacity)
                    }
                Text("\(Int((monitor.config.hudOpacity * 100).rounded()))%")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }

            Divider().opacity(0.6)

            Toggle("Alle aktiven Projekte gleichzeitig anzeigen", isOn: $monitor.config.showAllActiveProjects)
                .font(.system(size: 11))
                .toggleStyle(.switch)
                .controlSize(.mini)

            Toggle("Einrast-Grid beim Verschieben (⌥ = Frei)", isOn: $monitor.config.snapToGrid)
                .font(.system(size: 11))
                .toggleStyle(.switch)
                .controlSize(.mini)

            HStack(spacing: 12) {
                Toggle("Fertig-Meldung (Aktiv → Idle)", isOn: $monitor.config.notifyOnCompletion)
                    .font(.system(size: 11))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .onChange(of: monitor.config.notifyOnCompletion) { _, enabled in
                        CompletionNotifier.shared.prepareIfNeeded(enabled: enabled)
                    }

                Spacer()

                if monitor.config.notifyOnCompletion {
                    Toggle("Ton", isOn: $monitor.config.notifySound)
                        .font(.system(size: 10.5))
                        .toggleStyle(.checkbox)
                        .controlSize(.mini)
                }
            }

            Toggle("Kosten-Schätzung (~$)", isOn: $monitor.config.showEstimatedCost)
                .font(.system(size: 11))
                .toggleStyle(.switch)
                .controlSize(.mini)

            HStack(spacing: 8) {
                Toggle(
                    "Bei Anmeldung starten",
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    )
                )
                .font(.system(size: 11))
                .toggleStyle(.switch)
                .controlSize(.mini)

                if launchAtLogin.requiresApproval {
                    Text("Freigabe in macOS nötig")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var agentsTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Standard-Agents")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                PathInputRow(
                    title: ".codex",
                    path: $monitor.config.codexPath,
                    resolvedHint: monitor.codex.resolvedSourcePath
                )

                PathInputRow(
                    title: ".antigravity",
                    path: $monitor.config.antigravityPath,
                    resolvedHint: monitor.antigravity.resolvedSourcePath
                )
            }

            Divider().opacity(0.6)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text("Weitere Agents")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    ForEach([
                        ("OpenCode", "~/.local/share/opencode"),
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
                        .help(exists ? "\(preset.0) gefunden – klicken zum Hinzufügen" : "Vorausfüllen für \(preset.0)")
                    }
                }

                HStack(spacing: 5) {
                    TextField("Name", text: $uiState.newCustomAgentName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 76)
                    TextField("~/.local/share/opencode", text: $uiState.newCustomAgentPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                    Button("…") {
                        if let chosen = pickDirectory(initialPath: uiState.newCustomAgentPath) {
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
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
        }
    }

    private var foldersTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Überwachte Projekt-Ordner")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    TextField("/Volumes/.../Projekt", text: $uiState.newFolderPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .onSubmit {
                            addEnteredFolder()
                        }

                    Button("Wählen…") {
                        if let chosen = pickDirectory(initialPath: uiState.newFolderPath) {
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
                    Text("Optional: Ordner für Projekt-Matching & Live-Git-Branch.")
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
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }

            Divider().opacity(0.6)

            VStack(alignment: .leading, spacing: 5) {
                Text("Model-Alias (z. B. M526 → Gemini 4 (Medium))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    TextField("ID (M526)", text: $uiState.aliasKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 82)
                    TextField("Anzeigename", text: $uiState.aliasValue)
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

private struct PathInputRow: View {
    let title: String
    @Binding var path: String
    let resolvedHint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .frame(width: 78, alignment: .leading)
                TextField("Pfad eingeben", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                Button("…") {
                    if let chosen = pickDirectory(initialPath: path) {
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
private func pickDirectory(initialPath: String) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.prompt = "Auswählen"
    let expanded = PathResolver.expandTilde(initialPath)
    if !expanded.isEmpty {
        panel.directoryURL = URL(fileURLWithPath: expanded)
    }
    NSApp.activate(ignoringOtherApps: true)
    return panel.runModal() == .OK ? panel.url?.path : nil
}
