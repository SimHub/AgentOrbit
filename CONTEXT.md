# AgentOrbit

Schlanke macOS-Menüleisten- & Desktop-HUD-App (Swift 6 / SwiftUI, ohne Xcode, ~2 MB Binary, 0 Drittanbieter-Abhängigkeiten). Liest in Echtzeit aus `.codex`, `.gemini/antigravity` (bzw. `.antigravity`), optionalen Custom-Agents (`opencode.db`, `.jsonl`, Ordner) und überwachten Projekt-Ordnern.

## Arbeitsregel

- **Nach jedem Task `CONTEXT.md` kurz prüfen und nur festhalten, was für die weitere Arbeit relevant ist** (Architektur, Build/Frameworks, Fallstricke – kein Changelog).

## Aktuelle Architektur & Features (relevant für Weiterentwicklung)

- **Multi-Projekt & Layout:** `CoordinatorMonitor` sammelt alle laufenden + aktuellen Sessions (24h). `PopoverView` skaliert responsiv (1–3 Spalten, `240–980 pt` ziehbar) mit den Stufen `Minimal`, `Kompakt`, `Detail`. `.needsInput` (`Eingabe nötig`) sortiert vor `.running` (`Aktiv`) und `.idle`.
- **Desktop-HUD & Snap-Grid:** `PinnedWindowController` nutzt `DragGesture` (nicht `isMovableByWindowBackground`, da WindowServer Events schluckt) + `GridSnapCalculator` (`24 pt`-Grid, 9 Anker, `⌥` = frei) und `hudOpacity`.
- **Reader-Besonderheiten (Interaktion / Status):**
  - Antigravity: `conversations/<id>.db` → `steps.status == 9` signalisiert `WAITING` (während `conversation_summaries.db` `CASCADE_RUN_STATUS_RUNNING` / `not_fully_idle=1` hält).
  - Codex: Offener Turn (`task_started` ohne `task_complete`/`turn_aborted`) mit offenem `request_user_input*` oder wartendem `exec`/`exec_command`/`apply_patch` (`age >= 10s`, `approval_mode != 'never'`) → `.needsInput`.
- **System-Integrationen (reine Apple-Frameworks):**
  - `UserNotifications` (`CompletionNotifier`): `Aktiv` → `Idle` (`notifyOnCompletion`, `>= 3s`) sowie `→ Eingabe nötig` (`notifyOnNeedsInput`), erst nach Initial-Refresh.
  - `Carbon` (`HotKeyController`): Globaler Hotkey ohne Accessibility-Rechte (Default `⌃⌥ O`).
  - `ServiceManagement` (`LaunchAtLoginController`): `SMAppService.mainApp` für Login-Start.
  - `ProjectLauncher`: 1-Klick-Start via `NSWorkspace` (Auto / Antigravity / VS Code / Cursor / Terminal / Finder).
- **Zero-Config & Metriken:** `AgentDiscovery` scannt beim Erststart (und per Button in `SettingsView`); `SettingsView` nutzt 3 kompakte Tabs (`Anzeige`, `Agents`, `Ordner`). `CostEstimator` berechnet optionale `~$`-Schätzungen (oder nutzt `cost` direkt aus `opencode.db`).

## Technische Leitplanken & Fallstricke

- **Kein `@State` in SwiftUI-Views:** `swiftc` baut ohne Xcode/`SwiftUIMacros`-Plugin – View-State immer in `ObservableObject` (`PopoverUIState`) halten.
- **Bundle-Guards für Tests:** `UNUserNotificationCenter.current()` und `SMAppService.mainApp` crashen im CLI-Test-Runner ohne `.app`-Bundle → immer über `Bundle.main.bundleURL.pathExtension == "app"` absichern.
- **SSD- & Symlink-Design:** Artefakte liegen in `.build/` und `dist/`. `PathResolver` löst Symlinks rekursiv auf; SQLite-DBs werden ausschließlich read-only gelesen.
- **Open-Source- & Release-Setup (`SimHub/AgentOrbit`):** MIT-`LICENSE`, neutrale Default-Bundle-ID `dev.agentorbit.AgentOrbit` (überschreibbar via `AGENTORBIT_BUNDLE_ID` / `AGENTORBIT_VERSION`), GitHub Actions in `.github/workflows/` (`ci.yml`, `release.yml` für `v*`-Tags), Sponsoring via `.github/FUNDING.yml` (`buy_me_a_coffee: simhub`), Agent-Installer `scripts/install.sh` (`--from-source`) und GitHub Pages unter `docs/index.html` (+ `docs/assets/icon.png`).
- **Icon-Build:** `AppIcon.icns` wird in `scripts/build_app.sh` direkt in Swift inkl. `TOC `-Header und Retina-Chunks (`ic11`–`ic14`) erzeugt (kein `iconutil`, da Sandbox-Tempdir-abhängig).

## Build, Start & Tests

```zsh
./scripts/run_tests.sh
./scripts/build_app.sh                     # Single-Arch App (schnell, klein)
./scripts/build_app.sh --universal --dmg   # Universal (arm64 + x86_64) + dist/AgentOrbit.dmg
open ./dist/AgentOrbit.app
```

Hinweis: `--dmg` nutzt `hdiutil create`, was innerhalb restriktiver Sandboxes fehlschlagen kann und dann außerhalb der Sandbox / direkt im Terminal ausgeführt werden muss.
