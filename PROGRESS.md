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

### Phase 1: `agentorbit-core` in Rust (Fundament) – Abgeschlossen
- [x] Cargo-Workspace anlegen (`crates/agentorbit-core`, `crates/agentorbit-cli` für Tests/Headless).
- [x] Datenmodelle (`AgentSnapshot`, Status `needs_input` / `running` / `idle`, Token-/Kosten-Metriken, `serde`-JSON) portiert (`models.rs`).
- [x] Plattformübergreifende Pfad-Erkennung (`dirs` für `~` / XDG / AppData), Symlink-Auflösung & `.git/HEAD`-Branch-Erkennung ohne Subprocess (`paths.rs`, `discovery.rs`).
- [x] Alle Reader portiert & mit rein synthetischen Temp-Fixtures getestet (**15/15 Unit-Tests grün**):
  - [x] Antigravity (`antigravity.rs`: `conversations/<id>.db`, `steps.status == 9`, `gen_metadata`, `transcript.jsonl`)
  - [x] Codex (`codex.rs`: `config.toml`, `state_5.sqlite`, `task_started` / `request_user_input` / `approval_mode`, Rate-Limits)
  - [x] Claude Code & Custom JSONL (`custom.rs`: `/subagents/`-Filter, `tool_use` ohne `tool_result`, `AskUserQuestion`)
  - [x] OpenCode (`custom.rs`: `session_v2` + `question`-Tool + Legacy-Fallback)
  - [x] LM Studio Bionic (`custom.rs`: `ng-sessions.sqlite`, `chat_entries`-Kette, `elicitationRequest`)
- [x] `CostEstimator` (`cost.rs`) & strikt read-only SQLite-Helper (`sqlite.rs`, `rusqlite` bundled).
- [x] Plattformübergreifender `notify`-File-Watcher mit Debouncing (`watcher.rs`: FSEvents / inotify / ReadDirectoryChangesW).
- [x] CLI (`agentorbit-cli`): `scan`, `scan --json`, `watch`, `branch`.

#### Sicherheits- & Privacy-Leitplanken (Öffentliches Repo)
- Keine lokalen Pfade, Nutzerdaten, API-Keys oder echten Session-DBs im Repository.
- Unit-Tests erzeugen ausschließlich synthetische Fixtures in temporären Verzeichnissen und räumen diese wieder auf.
- Lokale Arbeitsnotizen (`CONTEXT.md`, `*.local.md`, `*.local.*`, `.env*`, `packaging/homebrew/local/`) sind per `.gitignore` strikt vom Git-Tracking ausgeschlossen.

### Phase 2: Tauri v2 Desktop-Shell & OS-Integration – Abgeschlossen
- [x] Tauri v2 Projekt aufgesetzt (`src-tauri`), `agentorbit-core` eingebunden (**0 `node_modules`-Abhängigkeiten**, `frontendDist: "../ui"` – baut rein mit `cargo`).
- [x] System-Tray / Menüleisten-Icon mit Live-Badge (`● N` / `! N` bei `needs_input`) & Menü (Show/Hide, Refresh, Quit).
- [x] Frameless, transparentes Always-on-Top HUD-Fenster (`decorations: false`, `transparent: true`, `alwaysOnTop: true`, `data-tauri-drag-region`).
- [x] `GridSnapCalculator` (`snap_to_grid` 24pt-Raster + Bildschirm-Anker) & `OrbitConfig`-Persistenz im OS-Config-Ordner (`config.rs`).
- [x] Globaler Shortcut (`⌃⌥O` / `Ctrl+Alt+O`), native OS-Notifications (`needs_input` & `running → idle`) und Live-Push via `OrbitWatcher`.
- [x] Plattformübergreifender 1-Klick-Launcher (`open_project` für macOS `open`, Linux `xdg-open`/`code`, Windows `cmd /C start`/`code`).

### Phase 3: HUD-Frontend & Feature-Parität+ – Abgeschlossen (`ui/` & `agentorbit-cli`)
- [x] **Nativer macOS-Glas-Look & Farbige Badges** (`ui/index.html`, `ui/styles.css`, `ui/app.js`, 0 `node_modules`):
  - Leicht abgerundete Ecken (`14 px`, `shadow: false`), **farbige Agent-Badges** (`AG`/`CX`/`CL`/`OC`/`LM`/`PI`), **farbige Modell-Family-Badges** (Gemini Cyan, Claude Korall, GPT/Codex Smaragd, Qwen/DeepSeek/Lokal Violett), Effort-, Branch-, IDE- & Kosten-Badges.
  - **Live-Arbeitsindikator & `✓ Fertig`:** GPU-Lichtlinie + 4-Punkte-Spinner auf aktiven Karten; grünes `✓ Fertig`-Badge für 5 Min. nach Abschluss; kein Hover-Flickern (In-Place-Timer-Updates).
  - **Live-Erkennung bereits laufender Tasks (Mid-Task-Start):** Codex (`has_open_turn` bis 30 Min., 256 KB Tail, echter `task_started`-Zeitstempel), Claude Code/JSONL (offene User-Prompts/Assistant-Turns bis 10–30 Min., 192 KB Tail), Antigravity (`RUNNING`/`WAITING` SQL-Priorisierung + echter `turn_started_epoch`), OpenCode (`busy_at`) sowie sofortiger Live-Refresh beim Öffnen/Fokussieren des HUDs.
  - **Live-Agent-Checkliste & ETA-Restzeit:** Direkt aus `update_steps`/`update_focus`/`run_command` (Antigravity), `update_plan`/`apply_patch` (Codex) und `TodoWrite` (Claude Code) – automatischer Reset bei neuem Task (`USER_INPUT` / `task_started`), kein falsches `Freigabe nötig` bei Bildgenerierung/Subagents.
  - **Volle v1.3.2-Einstellungsparität (3-Tab-Settings `Anzeige | Agents | Ordner`):**
    - `Ansicht` (`M | K | D` direkt in der Toolbar), `Menüleiste` (`Nur Icon`/`Projekt`/`Projekt · Model`), `Sprache` (`Auto`/`EN`/`DE`), `HUD-Deckkraft` (`25%–100%` inkl. automatischem Kontrast-Boost unter 50%), `Kontext-Balken` (`Auto`/`200k`/`500k`/`1M`/`Aus`, Ampelfarben Grün/Gelb/Rot), **3-stufige Projekt-Ansicht (`Einzeln | Alle Aktiven | Alle`)**, 4 globale Shortcuts inkl. **layout-bewusstem Recorder (QWERTZ/QWERTY) & Doppelbelegungs-Prüfung**, `Fertig`-Meldung inkl. `Ton`, `Eingabe nötig`, signaturfreier Autostart, automatische Höhenanpassung (`fitWindowHeightToContent`, wächst & schrumpft live) & `Expand`-Toggle (`⤢`).
    - **Detail-Ringe:** Echte Provider-Rate-Limits (`5h`/`Tag`/`Woche`/`Monat` inkl. Reset-Countdown) + deduplizierte lokale `Tag`/`Woche`/`Monat`-Nutzungsringe.
- [x] Moderne **Glass-HUD Terminal-TUI (`agentorbit tui`)** direkt im CLI-Binary (`ratatui` + `crossterm`) im Look des Desktop-HUDs:
  - Abgerundete Session-Karten (`BorderType::Rounded`, 1–2 Spalten mit sauberem Abstand), TrueColor-Palette passend zum macOS-HUD, farbige Agent- & Modell-Pills mit getöntem Hintergrund, Top-Header mit `M | K | D`-Segment-Toggle & KPI-Pills, animierte Licht-Sweep-Linie & Braille-Spinner (`⠋ Aktiv`), Live-Laufzeit (`⏱`) + `ETA ~…`, `✓ Fertig` (5-Min.-Verbleib), schlanke Ampel-Kontext-Linien (`━━━━╸───` + Kreis-Ring `◔/◑/◕`), Inspector-Panel mit Checkliste, IDE, Plan, `In/Cache/Out`-Tokens & Ring-Pills für Rate-Limits (`5h`/`Tag`/`Woche`/`Monat`) sowie deduplizierte `Tag`/`Woche`/`Monat`-Nutzungsringe, **Neovim-Navigation** (`h/j/k/l`, `gg`/`G`, `Ctrl+d`/`Ctrl+u`, `/` Live-Suche, `Space`/`Enter`/`o` Open) + volle **Maus-Steuerung** (Klick, Doppelklick, Scroll), DE/EN-Lokalisierung.
- [ ] **Optionale spätere TUI-Erweiterungen:**
  - Interaktives Launcher-Popup (`L`) & Inline-Settings (`s`) direkt in der TUI + optionaler Remote-SSH/WebSocket-Stream (`agentorbitd`).

### Phase 4: Signaturfreier Vertrieb & Lokale Installation – Abgeschlossen
- [x] Release-Profil größenoptimiert (`opt-level = "s"`, `lto = "thin"`, `strip = true`):
  - `agentorbit` (CLI + Terminal-TUI + Watcher + bundled SQLite): **2,2 MB**
  - `agentorbit-app` (Desktop-HUD + Tray + 3-Tab-Settings + UI): **8,6 MB**
- [x] Lokaler Source-Installer (`scripts/install_v2.sh` nach `~/.local/bin`, macOS & Linux, ohne Signatur/App Store).
- [x] GitHub Actions Cross-Platform Matrix-Workflows (`.github/workflows/v2-ci.yml`, `.github/workflows/v2-release.yml` für `macos-latest`, `ubuntu-latest`, `windows-latest` – kostenlose Standard-Runner, signaturfreie Portable-Archive + SHA256).
- [x] Signaturfreie Homebrew Formula (`packaging/homebrew/Formula/agentorbit.rb` für macOS & Linux, `--HEAD` / Source-Build ohne Quarantäne).
