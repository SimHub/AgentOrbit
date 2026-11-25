# AgentOrbit – Plan: Signaturfrei, Lokal & Hybrid-OS (v2)

> **Ziel:** Weg vom signatur- und App-Store-gebundenen macOS-`.app`-Zwang. AgentOrbit soll rein lokal (und optional über mehrere Betriebssysteme: **macOS, Linux, Windows**) laufen – mindestens genauso **klein**, **schnell** und **ressourcenschonend**, idealerweise noch flexibler als der Swift-Vorgänger.

---

## 1. Warum weg vom klassischen macOS `.app`-Vertrieb?

- **Gatekeeper & Apple Developer Program:** Verteilte `.app`/`.dmg`-Pakete ohne bezahlte Apple-Developer-ID (\$99/Jahr) und Notarisierung lösen auf macOS Sicherheitswarnungen (`com.apple.quarantine`) aus.
- **Bundle-Zwang:** System-APIs wie `UNUserNotificationCenter` und `SMAppService` crashen oder verweigern den Dienst außerhalb eines signierten `.app`-Bundles.
- **Plattform-Lock-in:** `SwiftUI`, `AppKit`, `Carbon` (Hotkeys) und `FSEvents` binden das Projekt vollständig an macOS.

### Sofort-Maßnahme für das aktuelle Swift-Projekt (Phase 0)
Solange die Swift-Version genutzt wird, gilt für den rein lokalen Betrieb ohne App Store / Signatur:
1. **Immer lokal kompilieren statt fertige DMGs laden:** Lokal gebaute Binaries erhalten kein `com.apple.quarantine`-Attribut (`./scripts/install.sh --from-source --open`).
2. **Kein Universal-DMG-/Notarisierungs-Overhead nötig:** Für den eigenen Rechner reicht `./scripts/build_app.sh` (Single-Arch, ~2 MB).
3. **Optionaler CLI-/LaunchAgent-Start:** Statt App-Store-/SMAppService-Pflicht kann das Binary lokal über `~/.local/bin` oder einen `launchd`-User-Agent gestartet werden.

---

## 2. Technologie-Evaluation für Hybrid-OS (macOS / Linux / Windows)

Anforderungen an AgentOrbit v2:
- **Sehr klein** (< 10–15 MB Binary / Installer, kein 150 MB Electron-Bloat)
- **Sehr schnell & sparsam** (~0 % CPU im Idle, schneller Start, minimaler RAM)
- **Native OS-Features auf allen Systemen:**
  - System-Tray / Menüleiste mit Live-Counter
  - Always-on-Top Desktop-HUD (transparent, frei verschiebbar, Snap-Grid, 2D-skalierbar)
  - Globale Tastenkürzel (z. B. `⌃⌥ O`)
  - Native Benachrichtigungen (`Eingabe nötig`, `Aktiv → Idle`)
  - 1-Klick-Launcher für IDE / Terminal / Dateimanager

### Vergleich der Optionen

| Kriterium | Swift 6 (aktuell) | **Rust + Tauri v2** (Empfehlung) | **Pure Rust (`iced` / `egui` + `tray-icon`)** | **Rust Daemon + Local Web-UI** |
| :--- | :--- | :--- | :--- | :--- |
| **OS-Support** | Nur macOS | **macOS, Linux, Windows** | **macOS, Linux, Windows** | **Alle OS + Remote/SSH/WSL2** |
| **Binary-Größe** | ~2 MB | ~6–12 MB (nutzt OS-WebView) | **~4–8 MB** (einzelne Binary) | **~3–5 MB** (CLI/Daemon) |
| **RAM (Idle)** | ~15–25 MB | ~35–60 MB (WebView) | **~15–25 MB** | ~5–10 MB (+ Browser-Tab) |
| **CPU (Idle)** | ~0 % | ~0 % | ~0 % | ~0 % |
| **Desktop-HUD (Transparent / Always-on-Top)** | Sehr gut (AppKit) | **Sehr gut** (CSS/HTML + Tauri Window APIs) | Möglich, aber plattformabhängige Quirks (Wayland/HiDPI) | Kein echtes Desktop-Overlay ohne Wrapper |
| **UI-Entwicklung** | Mittel (SwiftUI ohne Xcode-Macros eingeschränkt) | **Sehr schnell & modern** (CSS-Grid, SVG-Ringe, Themes) | Aufwendig (manuelles Styling/Layout) | Sehr schnell (Web-UI) |
| **Signatur-Freiheit** | Lokal via Source-Build | Lokal via `cargo`/`brew`; auf Linux/Win Portable Binary | Einzelne CLI-Binary, minimaler OS-Reibungspunkt | **100 % ohne `.app`-Bundle** |

### Empfohlene Architektur: **Rust Core + Tauri v2 (mit optionalem Daemon-Modus)**

Warum diese Kombination „klein, schnell und besser als der Vorgänger“ ist:
1. **Shared Core in Rust (`agentorbit-core`):**
   - `notify` Crate statt macOS-only `FSEvents` (unterstützt FSEvents auf macOS, inotify auf Linux, ReadDirectoryChangesW auf Windows).
   - `rusqlite` (bundled, read-only) für `antigravity`, `opencode.db`, `lm-studio`.
   - `serde_json` + `tokio` / leichte Worker-Threads für `Codex`, `Claude Code` (`.jsonl`), `Pi` & Git-Branch-Detection.
   - **Vorteil:** ~0 % Idle-CPU, extrem schnelles JSONL-Parsing, 100 % identische Logik und Unit-Tests auf allen Betriebssystemen.
2. **Tauri v2 als schlanke Native-Shell:**
   - Nutzt die vorinstallierte System-WebView (`WKWebView` / `WebView2` / `WebKitGTK`) – dadurch kein Chromium-Ballast.
   - Liefert out-of-the-box: **System Tray** (`TrayIconBuilder`), **Transparentes Always-on-Top HUD**, **Global Shortcuts**, **Native Notifications**, **Autostart**.
   - **Besser als der Vorgänger:** Komplexe UI-Elemente (2D-Grid, runde Rate-Limit-Ringe, Smooth-Transitions, Themes) lassen sich mit schlankem Frontend (z. B. SolidJS, Svelte oder Vanilla TS + CSS) ohne SwiftUI-Makro-Workarounds umsetzen.
3. **Bonus-Feature „Remote & Headless“ (besser als v1):**
   - Durch Trennung von `agentorbit-core` (optional als kleiner lokaler WebSocket/HTTP-Daemon `agentorbitd`) und UI lassen sich künftig sogar **Agents auf Remote-Linux-Servern, Docker-Containern oder WSL2** über SSH-Tunnel im selben lokalen HUD anzeigen.

---

## 3. Umsetzungsplan (Meilensteine)

### Phase 0: Aktuelle Swift-Version signaturfrei halten (Erledigt / Laufend)
- [x] `.antigravityignore` angelegt, um Build- und Binär-Overhead im Agent-Kontext zu reduzieren.
- [ ] Keine Apple-Developer-Signatur / Notarisierung / App-Store-Workflows mehr einplanen; Distribution lokal per `--from-source` oder reinem Binary-Build.

### Phase 1: `agentorbit-core` in Rust (Fundament)
- [ ] Cargo-Workspace anlegen (`crates/agentorbit-core`, `crates/agentorbit-cli` für Tests/Headless).
- [ ] Datenmodelle (`AgentSnapshot`, Status `.running` / `.needsInput` / `.idle`, Token-/Kosten-Metriken) portieren.
- [ ] Plattformübergreifende Pfad-Erkennung (`dirs` Crate für `~`, XDG auf Linux, AppData auf Windows) + Symlink-Auflösung.
- [ ] Reader portieren & mit Fixtures testen:
  - [ ] Antigravity (`conversations/<id>.db`, `steps.status == 9`)
  - [ ] Codex (`task_started` / `request_user_input` / `approval_mode`)
  - [ ] Claude Code & Custom JSONL (`/subagents/`-Filter, `tool_use` ohne `tool_result`)
  - [ ] OpenCode (`session_v2` + Legacy-Fallback)
  - [ ] LM Studio Bionic (`ng-sessions.sqlite`)
- [ ] `notify`-File-Watcher + Debouncing + Git-Branch-Reader + `CostEstimator`.

### Phase 2: Tauri v2 Desktop-Shell & OS-Integration
- [ ] Tauri v2 Projekt aufsetzen (`src-tauri`), `agentorbit-core` einbinden.
- [ ] System-Tray / Menüleisten-Icon mit Live-Badge (parallele Sessions + Orange-Indicator bei `needsInput`).
- [ ] Frameless, transparentes Always-on-Top HUD-Fenster + `GridSnapCalculator` (24pt-Raster, 9 Anker, Alt/Option = frei).
- [ ] Globale Shortcuts (`tauri-plugin-global-shortcut`), Notifications (`tauri-plugin-notification`), Autostart (`tauri-plugin-autostart`).
- [ ] Plattformübergreifender 1-Klick-Launcher (Antigravity, VS Code, Cursor, Terminal, Dateimanager je nach OS).

### Phase 3: HUD-Frontend & Feature-Parität+
- [ ] Responsive 2D-Ansicht (1–3 Spalten, `Minimal` / `Kompakt` / `Detail`).
- [ ] Live-Laufzeit-Timer, runde `Weekly` / `5h` Rate-Limit-Ringe, optionale `~$`-Kosten.
- [ ] Zweisprachig (DE / EN / Auto) + Settings-Fenster (Anzeige, Agents, Ordner).
- [ ] Optional: Remote-Agent-Anbindung (WebSocket/SSH-Stream von `agentorbitd` auf Linux/WSL2).

### Phase 4: Signaturfreier Vertrieb & Lokale Installation
- [ ] **macOS:** Installation per Homebrew Formula / `--from-source` (`cargo build --release`), kein App Store, keine kostenpflichtige Signatur nötig.
- [ ] **Linux:** Einzelnes Binary / `.AppImage` / `.deb` / `cargo install`.
- [ ] **Windows:** Portable `.exe` (ohne Installer-Zwang) oder `winget` / `scoop`.
