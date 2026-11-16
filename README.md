<p align="center">
  <img src="docs/assets/icon.png" width="92" height="92" alt="AgentOrbit icon" />
</p>

<h1 align="center">AgentOrbit</h1>

<p align="center">
  <a href="https://github.com/SimHub/AgentOrbit/actions/workflows/ci.yml"><img src="https://github.com/SimHub/AgentOrbit/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-cyan.svg" alt="License: MIT" /></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue.svg" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/Dependencies-0-brightgreen.svg" alt="Zero Dependencies" />
  <a href="https://buymeacoffee.com/simhub"><img src="https://img.shields.io/badge/Buy%20Me%20a%20Coffee-simhub-FFDD00?logo=buy-me-a-coffee&logoColor=black" alt="Buy Me a Coffee" /></a>
</p>

A fast, lightweight (~2 MB binary, 0 third-party dependencies, no Xcode required) macOS menu bar & floating desktop HUD for AI coding agents — reading live status, projects, Git branches, models, runtime, and usage metrics locally from **Codex**, **Antigravity**, and optional custom agents (**OpenCode**, **Pi**, **Claude**, etc.).

- **Project Page:** https://simhub.github.io/AgentOrbit/
- **Download Latest DMG:** https://github.com/SimHub/AgentOrbit/releases/latest/download/AgentOrbit.dmg

---

## Features (EN)

- **Multi-Project Live View:** Displays all running and recent (24h) sessions side by side with live status, active runtime timer (`1m 42s`, 0% CPU when idle), and menu bar parallel-session counter.
- **Responsive Desktop HUD & Snap-Grid:**
  - Pin as an always-on-top desktop widget (`⌃⌥ O` global hotkey, adjustable opacity `45%–100%`).
  - Drag freely with a live `24 pt` snap grid + 9 screen anchors (hold `⌥` for free placement).
  - Resize from `240 pt` up to full screen width with automatic 1–3 column wrapping.
- **3 View Densities:** `Minimal` (2-line corner widget, auto-enabled `< 290 pt`), `Kompakt`, and `Detail` (permanent usage & circular `Weekly` / `5h` rate-limit rings + reset timers).
- **1-Click Project Launcher:** Open any active project directly in **Antigravity**, **VS Code**, **Cursor**, **Terminal** (Ghostty/Warp/iTerm/Terminal), or **Finder** (plus right-click context menu).
- **Completion Notifications:** Native macOS notification (+ optional sound) when a running session finishes (`Aktiv → Idle`).
- **Zero-Config & Optional Cost Estimate:** Auto-discovers installed agent directories on first launch, supports Launch at Login (`SMAppService`), and optionally displays exact/estimated session costs (`~$0.xx`).
- **Read-Only & Symlink-Safe:** Resolves symlinks (`resolvingSymlinksInPath`) for reliable `FSEvents` even on external SSDs and reads SQLite databases strictly read-only.

## Funktionen (DE)

- **Multi-Projekt-Übersicht:** Zeigt alle parallelen und aktuellen Sessions mit Projekt, Live-Git-Branch, Modell + Stärke, Laufzeit-Timer und Menüleisten-Counter.
- **Desktop-HUD mit Einrast-Grid:** Anpinnbar (`⌃⌥ O`), stufenlos zieh- und skalierbar (`240 pt` bis Bildschirmbreite, 1–3 Spalten) mit `24 pt`-Raster & 9 Bildschirm-Ankern (`⌥` = frei platzieren) sowie einstellbarer Deckkraft.
- **3 Ansichts-Stufen:** `Minimal`, `Kompakt`, `Detail` (inkl. runder `Weekly`/`5h`-Limit-Ringe und optionaler `~$`-Kosten-Schätzung).
- **1-Klick-IDE-Starter & Fertig-Meldung:** Öffnet Projekte direkt im passenden Editor/Terminal und benachrichtigt nativ bei `Aktiv → Idle`.
- **Zero-Config & Erweiterbar:** Auto-Discovery beim Erststart, „Bei Anmeldung starten“ und flexibel hinzufügbare Agents (`OpenCode`, `Pi`, `Claude`, eigene Ordner).

---

## Install (macOS 14+)

### Option 1 — Ask Your AI Agent (or Run 1 Command)

Tell your coding agent (Codex, Antigravity, Claude Code, OpenCode, etc.):

> *"Install AgentOrbit from `https://github.com/SimHub/AgentOrbit` using `scripts/install.sh` (or `--from-source` if I want a local build)."*

Or run the non-interactive installer directly:

```zsh
# Download latest release DMG, install to /Applications, clear quarantine & launch
curl -fsSL https://raw.githubusercontent.com/SimHub/AgentOrbit/main/scripts/install.sh | zsh -s -- --open

# Or let an agent clone, run unit tests, compile locally from source & install
curl -fsSL https://raw.githubusercontent.com/SimHub/AgentOrbit/main/scripts/install.sh | zsh -s -- --from-source --open
```

<details>
<summary>Installer options (<code>scripts/install.sh</code>)</summary>

- `--from-source`: Clones (or uses the current repo), runs `./scripts/run_tests.sh`, compiles locally via `./scripts/build_app.sh`, and installs `AgentOrbit.app` without needing Xcode.
- `--universal`: Together with `--from-source`, builds a universal (`arm64` + `x86_64`) binary.
- `--dir <path>`: Custom target folder (defaults to `/Applications`, or `~/Applications` if `/Applications` is not writable).
- `--open`: Launches `AgentOrbit.app` immediately after installation.

</details>

### Option 2 — Manual DMG Download

1. Download **`AgentOrbit.dmg`** from [GitHub Releases](https://github.com/SimHub/AgentOrbit/releases/latest) and drag `AgentOrbit.app` into `/Applications`.
2. **First-launch Gatekeeper note:** Release builds are currently ad-hoc signed (not Apple notarized). If macOS warns that the app cannot be verified, either **Right-click → Open** in Finder or run:

```zsh
xattr -cr /Applications/AgentOrbit.app
```

*(DE: Da die App aktuell ad-hoc signiert ist, beim Erststart ggf. per Rechtsklick → Öffnen bestätigen oder `xattr -cr /Applications/AgentOrbit.app` ausführen.)*

---

## Build, Test & Release (Command Line Tools only)

```zsh
# Run unit tests
./scripts/run_tests.sh

# Fast, small single-arch build (~2 MB)
./scripts/build_app.sh
open ./dist/AgentOrbit.app

# Universal Binary (arm64 + x86_64) and DMG installer
./scripts/build_app.sh --universal --dmg
```

Optional build environment overrides:

```zsh
AGENTORBIT_BUNDLE_ID=dev.agentorbit.AgentOrbit AGENTORBIT_VERSION=1.0.0 ./scripts/build_app.sh
```

> [!NOTE]
> Uses only Apple system frameworks (`SwiftUI`, `AppKit`, `CoreServices`, `SQLite3`, `UserNotifications`, `Carbon`, `ServiceManagement`) — no Xcode project or external packages required.

---

## Support

If AgentOrbit saves you time while juggling multiple coding agents, consider supporting the project:

<a href="https://buymeacoffee.com/simhub"><img src="https://img.shields.io/badge/Buy%20Me%20a%20Coffee-Support%20AgentOrbit-FFDD00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=black" alt="Buy Me a Coffee" /></a>

---

## License

[MIT License](LICENSE) — Copyright (c) 2026 SimHub
