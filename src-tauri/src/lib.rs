use agentorbit_core::{
    default_config_path, discover_default_agents, estimate_cost, load_config_from, now_epoch_secs,
    save_config_to, scan_agents_with_config, snap_to_grid, watch_paths_for, AgentRunState,
    AgentSnapshot, DiscoveredAgents, OrbitConfig, OrbitWatcher,
};
use serde::Serialize;
use std::collections::HashMap;
use std::fs;
use std::process::Command;
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::Duration;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, LogicalSize, Manager, PhysicalPosition};
use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut, ShortcutState};
use tauri_plugin_notification::NotificationExt;

const TRAY_ID: &str = "agentorbit-tray";

static ACTIVE_SINCE: OnceLock<Mutex<HashMap<String, i64>>> = OnceLock::new();

fn active_since_map() -> &'static Mutex<HashMap<String, i64>> {
    ACTIVE_SINCE.get_or_init(|| Mutex::new(HashMap::new()))
}

#[derive(Debug, Clone, Serialize)]
pub struct EnrichedSnapshot {
    pub snapshot: AgentSnapshot,
    pub cost_display: Option<String>,
}

fn collect_enriched() -> (OrbitConfig, Vec<std::path::PathBuf>, Vec<EnrichedSnapshot>) {
    let config = load_config_from(&default_config_path());
    let (discovered, mut snapshots) = scan_agents_with_config(&config, 8);
    let paths = watch_paths_for(&discovered);
    let now = now_epoch_secs();

    if let Ok(mut map) = active_since_map().lock() {
        for snap in &mut snapshots {
            let id = snap.id();
            if snap.state.is_active_or_waiting() {
                let started = *map
                    .entry(id)
                    .or_insert_with(|| snap.active_since_epoch.unwrap_or(now));
                snap.active_since_epoch = Some(started);
            } else {
                map.remove(&id);
                snap.active_since_epoch = None;
            }
        }
    }

    let enriched = snapshots
        .into_iter()
        .map(|snapshot| {
            let cost_display = if config.show_cost_estimate {
                estimate_cost(&snapshot.usage, &snapshot.model_name).map(|c| c.formatted())
            } else {
                None
            };
            EnrichedSnapshot {
                snapshot,
                cost_display,
            }
        })
        .collect();
    (config, paths, enriched)
}

#[tauri::command]
fn get_config() -> OrbitConfig {
    load_config_from(&default_config_path())
}

#[tauri::command]
fn get_discovered_agents() -> DiscoveredAgents {
    discover_default_agents()
}

#[tauri::command]
fn save_config(app: AppHandle, config: OrbitConfig) -> Result<(), String> {
    save_config_to(&default_config_path(), &config).map_err(|e| e.to_string())?;
    let _ = sync_autostart(config.launch_at_login);
    sync_shortcuts(&app, &config);

    let (cfg, _, items) = collect_enriched();
    update_tray_badge(&app, &cfg, &items);
    let _ = app.emit("agentorbit://snapshots", &items);
    Ok(())
}

#[tauri::command]
fn scan_sessions() -> Vec<EnrichedSnapshot> {
    let (_, _, enriched) = collect_enriched();
    enriched
}

#[tauri::command]
fn resize_hud(app: AppHandle, width: f64, height: f64) {
    if let Some(win) = app.get_webview_window("hud") {
        let w = width.clamp(240.0, 1280.0);
        let h = height.clamp(110.0, 920.0);
        let _ = win.set_size(LogicalSize::new(w, h));
    }
}

#[tauri::command]
fn snap_hud_to_grid(app: AppHandle) {
    let config = load_config_from(&default_config_path());
    if !config.snap_grid_enabled {
        return;
    }
    let Some(win) = app.get_webview_window("hud") else {
        return;
    };
    let (Ok(pos), Ok(size), Ok(Some(monitor))) =
        (win.outer_position(), win.outer_size(), win.current_monitor())
    else {
        return;
    };
    let m_pos = monitor.position();
    let m_size = monitor.size();
    let scale = monitor.scale_factor();
    let grid = (24.0 * scale).round() as i32;
    let margin = (12.0 * scale).round() as i32;

    let (nx, ny) = snap_to_grid(
        pos.x,
        pos.y,
        size.width as i32,
        size.height as i32,
        m_pos.x,
        m_pos.y,
        m_size.width as i32,
        m_size.height as i32,
        grid,
        margin,
    );
    let _ = win.set_position(PhysicalPosition::new(nx, ny));
}

#[tauri::command]
fn toggle_hud_visibility(app: AppHandle) {
    if let Some(win) = app.get_webview_window("hud") {
        if win.is_visible().unwrap_or(false) {
            let _ = win.hide();
        } else {
            let _ = win.show();
            let _ = win.set_focus();
            let (cfg, _, items) = collect_enriched();
            update_tray_badge(&app, &cfg, &items);
            let _ = app.emit("agentorbit://snapshots", &items);
        }
    }
}

#[tauri::command]
fn open_project(path: String, target: Option<String>) -> Result<(), String> {
    if path.trim().is_empty() {
        return Err("Empty project path".to_string());
    }
    let config = load_config_from(&default_config_path());
    let editor = target
        .unwrap_or(config.preferred_launcher)
        .trim()
        .to_lowercase();

    #[cfg(target_os = "macos")]
    {
        let mut cmd = Command::new("open");
        match editor.as_str() {
            "vscode" | "code" => {
                cmd.args(["-a", "Visual Studio Code", &path]);
            }
            "cursor" => {
                cmd.args(["-a", "Cursor", &path]);
            }
            "antigravity" => {
                cmd.args(["-a", "Antigravity", &path]);
            }
            "terminal" => {
                cmd.args(["-a", "Terminal", &path]);
            }
            "finder" => {
                cmd.args(["-a", "Finder", &path]);
            }
            _ => {
                cmd.arg(&path);
            }
        }
        cmd.spawn().map_err(|e| e.to_string())?;
        return Ok(());
    }

    #[cfg(target_os = "linux")]
    {
        let bin = match editor.as_str() {
            "vscode" | "code" => "code",
            "cursor" => "cursor",
            _ => "xdg-open",
        };
        Command::new(bin)
            .arg(&path)
            .spawn()
            .map_err(|e| e.to_string())?;
        return Ok(());
    }

    #[cfg(target_os = "windows")]
    {
        match editor.as_str() {
            "vscode" | "code" => {
                Command::new("code")
                    .arg(&path)
                    .spawn()
                    .map_err(|e| e.to_string())?;
            }
            "cursor" => {
                Command::new("cursor")
                    .arg(&path)
                    .spawn()
                    .map_err(|e| e.to_string())?;
            }
            _ => {
                Command::new("cmd")
                    .args(["/C", "start", "", &path])
                    .spawn()
                    .map_err(|e| e.to_string())?;
            }
        }
        return Ok(());
    }

    #[allow(unreachable_code)]
    Ok(())
}

fn parse_shortcut(spec: &str) -> Option<Shortcut> {
    // Strip optional `|<DisplayLabel>` suffix used to preserve active keyboard layout labels (e.g. QWERTZ Y/Z)
    let raw_spec = spec.split('|').next().unwrap_or(spec);
    let trimmed = raw_spec.trim().to_lowercase();
    if trimmed.is_empty() || trimmed == "off" {
        return None;
    }

    let mut mods = Modifiers::empty();
    let mut key_code: Option<Code> = None;

    for token in trimmed.split('+').map(str::trim).filter(|s| !s.is_empty()) {
        match token {
            "ctrl" | "control" => mods |= Modifiers::CONTROL,
            "alt" | "opt" | "option" => mods |= Modifiers::ALT,
            "shift" => mods |= Modifiers::SHIFT,
            "cmd" | "meta" | "super" => mods |= Modifiers::SUPER,
            other => {
                let normalized = other
                    .strip_prefix("key")
                    .or_else(|| other.strip_prefix("digit"))
                    .unwrap_or(other);
                key_code = parse_key_code(normalized);
            }
        }
    }

    let code = key_code?;
    let opt_mods = if mods.is_empty() { None } else { Some(mods) };
    Some(Shortcut::new(opt_mods, code))
}

fn parse_key_code(key: &str) -> Option<Code> {
    match key {
        "space" => Some(Code::Space),
        "a" => Some(Code::KeyA),
        "b" => Some(Code::KeyB),
        "c" => Some(Code::KeyC),
        "d" => Some(Code::KeyD),
        "e" => Some(Code::KeyE),
        "f" => Some(Code::KeyF),
        "g" => Some(Code::KeyG),
        "h" => Some(Code::KeyH),
        "i" => Some(Code::KeyI),
        "j" => Some(Code::KeyJ),
        "k" => Some(Code::KeyK),
        "l" => Some(Code::KeyL),
        "m" => Some(Code::KeyM),
        "n" => Some(Code::KeyN),
        "o" => Some(Code::KeyO),
        "p" => Some(Code::KeyP),
        "q" => Some(Code::KeyQ),
        "r" => Some(Code::KeyR),
        "s" => Some(Code::KeyS),
        "t" => Some(Code::KeyT),
        "u" => Some(Code::KeyU),
        "v" => Some(Code::KeyV),
        "w" => Some(Code::KeyW),
        "x" => Some(Code::KeyX),
        "y" => Some(Code::KeyY),
        "z" => Some(Code::KeyZ),
        "0" => Some(Code::Digit0),
        "1" => Some(Code::Digit1),
        "2" => Some(Code::Digit2),
        "3" => Some(Code::Digit3),
        "4" => Some(Code::Digit4),
        "5" => Some(Code::Digit5),
        "6" => Some(Code::Digit6),
        "7" => Some(Code::Digit7),
        "8" => Some(Code::Digit8),
        "9" => Some(Code::Digit9),
        "f1" => Some(Code::F1),
        "f2" => Some(Code::F2),
        "f3" => Some(Code::F3),
        "f4" => Some(Code::F4),
        "f5" => Some(Code::F5),
        "f6" => Some(Code::F6),
        "f7" => Some(Code::F7),
        "f8" => Some(Code::F8),
        "f9" => Some(Code::F9),
        "f10" => Some(Code::F10),
        "f11" => Some(Code::F11),
        "f12" => Some(Code::F12),
        _ => None,
    }
}

fn sync_shortcuts(app: &AppHandle, config: &OrbitConfig) {
    let _ = app.global_shortcut().unregister_all();
    let mut registered = Vec::new();
    for spec in [
        &config.hotkey_hud,
        &config.hotkey_density,
        &config.hotkey_active,
        &config.hotkey_mini,
    ] {
        if let Some(sc) = parse_shortcut(spec) {
            if !registered.contains(&sc) {
                let _ = app.global_shortcut().register(sc);
                registered.push(sc);
            }
        }
    }
}

fn sync_autostart(enabled: bool) -> std::io::Result<()> {
    let exe = std::env::current_exe()?;
    let exe_str = exe.to_string_lossy();

    #[cfg(target_os = "macos")]
    {
        if let Some(home) = std::env::var_os("HOME") {
            let plist_path = std::path::PathBuf::from(home)
                .join("Library/LaunchAgents/dev.agentorbit.v2.plist");
            if enabled {
                if let Some(parent) = plist_path.parent() {
                    fs::create_dir_all(parent)?;
                }
                let plist = format!(
                    r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.agentorbit.v2</string>
  <key>ProgramArguments</key><array><string>{exe_str}</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
"#
                );
                fs::write(plist_path, plist)?;
            } else if plist_path.exists() {
                let _ = fs::remove_file(plist_path);
            }
        }
    }

    #[cfg(target_os = "linux")]
    {
        if let Some(home) = std::env::var_os("HOME") {
            let desktop_path =
                std::path::PathBuf::from(home).join(".config/autostart/agentorbit.desktop");
            if enabled {
                if let Some(parent) = desktop_path.parent() {
                    fs::create_dir_all(parent)?;
                }
                let content = format!(
                    "[Desktop Entry]\nType=Application\nName=AgentOrbit\nExec={exe_str}\nX-GNOME-Autostart-enabled=true\n"
                );
                fs::write(desktop_path, content)?;
            } else if desktop_path.exists() {
                let _ = fs::remove_file(desktop_path);
            }
        }
    }

    let _ = exe_str;
    Ok(())
}

fn update_tray_badge(app: &AppHandle, config: &OrbitConfig, items: &[EnrichedSnapshot]) {
    let Some(tray) = app.tray_by_id(TRAY_ID) else {
        return;
    };
    let waiting = items
        .iter()
        .filter(|i| i.snapshot.state == AgentRunState::NeedsInput)
        .count();
    let running = items
        .iter()
        .filter(|i| i.snapshot.state == AgentRunState::Running)
        .count();

    if config.tray_style == "icon" {
        let title = if waiting > 0 {
            format!("! {waiting}")
        } else if running > 0 {
            format!("● {running}")
        } else {
            String::new()
        };
        let _ = tray.set_title(Some(title));
        return;
    }

    let primary = items
        .iter()
        .find(|i| i.snapshot.state.is_active_or_waiting())
        .or_else(|| items.first());

    let title = match primary {
        Some(item) => {
            let s = &item.snapshot;
            let prefix = if waiting > 0 {
                format!("!{waiting} ")
            } else if running > 1 {
                format!("●{running} ")
            } else if running == 1 {
                "● ".to_string()
            } else {
                String::new()
            };
            if config.tray_style == "project_model" {
                format!("{prefix}{} · {}", s.project_name, s.model_name)
            } else {
                format!("{prefix}{}", s.project_name)
            }
        }
        None => String::new(),
    };
    let _ = tray.set_title(Some(title));
}

fn spawn_background_watcher(app: AppHandle) {
    thread::spawn(move || {
        let (init_cfg, watch_paths, initial) = collect_enriched();
        let mut prev_states: HashMap<String, (AgentRunState, Option<i64>)> = initial
            .iter()
            .map(|i| (i.snapshot.id(), (i.snapshot.state, i.snapshot.active_since_epoch)))
            .collect();
        update_tray_badge(&app, &init_cfg, &initial);
        let _ = app.emit("agentorbit://snapshots", &initial);

        let mut watcher = OrbitWatcher::start(&watch_paths, Duration::from_millis(300)).ok();

        loop {
            let _ = match watcher.as_mut() {
                Some(w) => w.wait_for_change(Duration::from_secs(2)),
                None => {
                    thread::sleep(Duration::from_secs(2));
                    true
                }
            };

            let (config, _, current) = collect_enriched();
            let now = now_epoch_secs();

            for item in &current {
                let s = &item.snapshot;
                let id = s.id();
                if let Some((old_state, old_started)) = prev_states.get(&id) {
                    if config.notify_on_needs_input
                        && *old_state != AgentRunState::NeedsInput
                        && s.state == AgentRunState::NeedsInput
                    {
                        let body = format!(
                            "{} ({}) wartet auf Eingabe",
                            s.project_name, s.agent_label
                        );
                        let _ = app
                            .notification()
                            .builder()
                            .title("AgentOrbit: Eingabe nötig")
                            .body(body)
                            .show();
                    } else if config.notify_on_completion
                        && *old_state == AgentRunState::Running
                        && s.state == AgentRunState::Idle
                    {
                        let ran_secs = old_started.map(|st| (now - st).max(0)).unwrap_or(0);
                        if ran_secs >= 3 {
                            let body = format!(
                                "{} ({}) ist fertig ({ran_secs}s)",
                                s.project_name, s.agent_label
                            );
                            let mut builder = app
                                .notification()
                                .builder()
                                .title("AgentOrbit: Fertig")
                                .body(body);
                            if config.notify_sound {
                                builder = builder.sound("default");
                            }
                            let _ = builder.show();
                        }
                    }
                }
                prev_states.insert(id, (s.state, s.active_since_epoch));
            }

            update_tray_badge(&app, &config, &current);
            let _ = app.emit("agentorbit://snapshots", &current);
        }
    });
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_notification::init())
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(move |app, shortcut, event| {
                    if event.state() != ShortcutState::Pressed {
                        return;
                    }
                    let cfg = load_config_from(&default_config_path());
                    if parse_shortcut(&cfg.hotkey_hud).as_ref() == Some(shortcut) {
                        toggle_hud_visibility(app.clone());
                    } else if parse_shortcut(&cfg.hotkey_density).as_ref() == Some(shortcut) {
                        let _ = app.emit("agentorbit://cycle-density", ());
                    } else if parse_shortcut(&cfg.hotkey_active).as_ref() == Some(shortcut) {
                        if let Some(win) = app.get_webview_window("hud") {
                            let _ = win.show();
                            let _ = win.set_focus();
                        }
                        let _ = app.emit("agentorbit://filter-active", ());
                    } else if parse_shortcut(&cfg.hotkey_mini).as_ref() == Some(shortcut) {
                        if let Some(win) = app.get_webview_window("hud") {
                            let _ = win.show();
                            let _ = win.set_focus();
                        }
                        let _ = app.emit("agentorbit://toggle-mini", ());
                    }
                })
                .build(),
        )
        .setup(move |app| {
            let toggle_item =
                MenuItem::with_id(app, "toggle", "Show / Hide HUD", true, None::<&str>)?;
            let refresh_item = MenuItem::with_id(app, "refresh", "Refresh Now", true, None::<&str>)?;
            let quit_item = MenuItem::with_id(app, "quit", "Quit AgentOrbit", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&toggle_item, &refresh_item, &quit_item])?;

            let mut tray_builder = TrayIconBuilder::with_id(TRAY_ID)
                .menu(&menu)
                .tooltip("AgentOrbit")
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "toggle" => toggle_hud_visibility(app.clone()),
                    "refresh" => {
                        let (cfg, _, items) = collect_enriched();
                        update_tray_badge(app, &cfg, &items);
                        let _ = app.emit("agentorbit://snapshots", &items);
                    }
                    "quit" => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = event
                    {
                        toggle_hud_visibility(tray.app_handle().clone());
                    }
                });

            if let Some(icon) = app.default_window_icon() {
                tray_builder = tray_builder.icon(icon.clone());
            }
            tray_builder.build(app)?;

            let cfg = load_config_from(&default_config_path());
            sync_shortcuts(app.handle(), &cfg);

            spawn_background_watcher(app.handle().clone());
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_config,
            get_discovered_agents,
            save_config,
            scan_sessions,
            resize_hud,
            snap_hud_to_grid,
            toggle_hud_visibility,
            open_project
        ])
        .run(tauri::generate_context!())
        .expect("error while running AgentOrbit");
}
