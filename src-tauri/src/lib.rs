use agentorbit_core::{
    estimate_cost, scan_discovered_agents, watch_paths_for, AgentRunState, AgentSnapshot,
    OrbitWatcher,
};
use serde::Serialize;
use std::collections::HashMap;
use std::process::Command;
use std::thread;
use std::time::Duration;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut, ShortcutState};
use tauri_plugin_notification::NotificationExt;

const TRAY_ID: &str = "agentorbit-tray";

#[derive(Debug, Clone, Serialize)]
pub struct EnrichedSnapshot {
    pub snapshot: AgentSnapshot,
    pub cost_display: Option<String>,
}

fn collect_enriched() -> (Vec<std::path::PathBuf>, Vec<EnrichedSnapshot>) {
    let (discovered, snapshots) = scan_discovered_agents(8);
    let paths = watch_paths_for(&discovered);
    let enriched = snapshots
        .into_iter()
        .map(|snapshot| {
            let cost_display =
                estimate_cost(&snapshot.usage, &snapshot.model_name).map(|c| c.formatted());
            EnrichedSnapshot {
                snapshot,
                cost_display,
            }
        })
        .collect();
    (paths, enriched)
}

#[tauri::command]
fn scan_sessions() -> Vec<EnrichedSnapshot> {
    let (_, enriched) = collect_enriched();
    enriched
}

#[tauri::command]
fn toggle_hud_visibility(app: AppHandle) {
    if let Some(win) = app.get_webview_window("hud") {
        if win.is_visible().unwrap_or(false) {
            let _ = win.hide();
        } else {
            let _ = win.show();
            let _ = win.set_focus();
        }
    }
}

#[tauri::command]
fn open_project(path: String, target: Option<String>) -> Result<(), String> {
    if path.trim().is_empty() {
        return Err("Empty project path".to_string());
    }
    let editor = target.unwrap_or_default().to_lowercase();

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

fn update_tray_badge(app: &AppHandle, items: &[EnrichedSnapshot]) {
    let waiting = items
        .iter()
        .filter(|i| i.snapshot.state == AgentRunState::NeedsInput)
        .count();
    let running = items
        .iter()
        .filter(|i| i.snapshot.state == AgentRunState::Running)
        .count();

    if let Some(tray) = app.tray_by_id(TRAY_ID) {
        let title = if waiting > 0 {
            format!("! {waiting}")
        } else if running > 0 {
            format!("● {running}")
        } else {
            String::new()
        };
        let _ = tray.set_title(Some(title));
    }
}

fn spawn_background_watcher(app: AppHandle) {
    thread::spawn(move || {
        let (watch_paths, initial) = collect_enriched();
        let mut prev_states: HashMap<String, AgentRunState> = initial
            .iter()
            .map(|i| (i.snapshot.id(), i.snapshot.state))
            .collect();
        update_tray_badge(&app, &initial);
        let _ = app.emit("agentorbit://snapshots", &initial);

        let mut watcher = OrbitWatcher::start(&watch_paths, Duration::from_millis(300)).ok();

        loop {
            let changed = match watcher.as_mut() {
                Some(w) => w.wait_for_change(Duration::from_secs(4)),
                None => {
                    thread::sleep(Duration::from_secs(4));
                    true
                }
            };

            // Also periodically refresh every timeout tick to catch time-based idle transitions
            let _ = changed;
            let (_, current) = collect_enriched();

            for item in &current {
                let s = &item.snapshot;
                let id = s.id();
                if let Some(old_state) = prev_states.get(&id) {
                    if *old_state != AgentRunState::NeedsInput
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
                    } else if *old_state == AgentRunState::Running && s.state == AgentRunState::Idle
                    {
                        let body = format!("{} ({}) ist fertig", s.project_name, s.agent_label);
                        let _ = app
                            .notification()
                            .builder()
                            .title("AgentOrbit: Fertig")
                            .body(body)
                            .show();
                    }
                }
                prev_states.insert(id, s.state);
            }

            update_tray_badge(&app, &current);
            let _ = app.emit("agentorbit://snapshots", &current);
        }
    });
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let hud_shortcut = Shortcut::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::KeyO);

    tauri::Builder::default()
        .plugin(tauri_plugin_notification::init())
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(move |app, shortcut, event| {
                    if shortcut == &hud_shortcut && event.state() == ShortcutState::Pressed {
                        toggle_hud_visibility(app.clone());
                    }
                })
                .build(),
        )
        .setup(move |app| {
            let toggle_item =
                MenuItem::with_id(app, "toggle", "Show / Hide HUD (⌃⌥O)", true, None::<&str>)?;
            let refresh_item = MenuItem::with_id(app, "refresh", "Refresh Now", true, None::<&str>)?;
            let quit_item = MenuItem::with_id(app, "quit", "Quit AgentOrbit", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&toggle_item, &refresh_item, &quit_item])?;

            let mut tray_builder = TrayIconBuilder::with_id(TRAY_ID)
                .menu(&menu)
                .tooltip("AgentOrbit")
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "toggle" => toggle_hud_visibility(app.clone()),
                    "refresh" => {
                        let (_, items) = collect_enriched();
                        update_tray_badge(app, &items);
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

            let _ = app.global_shortcut().register(hud_shortcut);
            spawn_background_watcher(app.handle().clone());
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            scan_sessions,
            toggle_hud_visibility,
            open_project
        ])
        .run(tauri::generate_context!())
        .expect("error while running AgentOrbit");
}
