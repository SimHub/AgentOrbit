use crate::models::{CustomAgentConfig, WatchedFolderStatus};
use crate::paths::{detect_git_branch, expand_tilde, resolve_path};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChecklistItem {
    pub id: String,
    pub text: String,
    pub done: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrbitConfig {
    #[serde(default = "default_density")]
    pub density: String,
    #[serde(default = "default_tray_style")]
    pub tray_style: String, // "icon" | "project" | "project_model"
    #[serde(default = "default_lang")]
    pub lang: String, // "auto" | "en" | "de"
    #[serde(default = "default_opacity")]
    pub opacity: u8,
    #[serde(default)]
    pub context_window_override: i64, // 0=auto, 200000, 500000, 1000000, -1=off
    #[serde(default = "default_launcher")]
    pub preferred_launcher: String,
    #[serde(default = "default_project_scope")]
    pub project_scope: String, // "single" | "active" | "all"
    #[serde(default = "default_true")]
    pub show_all_active_projects: bool,
    #[serde(default = "default_true")]
    pub snap_grid_enabled: bool,
    #[serde(default = "default_true")]
    pub show_cost_estimate: bool,
    #[serde(default = "default_hotkey_hud")]
    pub hotkey_hud: String, // "ctrl+alt+o" | "alt+space" | "ctrl+shift+o" | "off"
    #[serde(default = "default_hotkey_off")]
    pub hotkey_density: String, // "off" | "ctrl+alt+v" | "alt+shift+a" | "ctrl+shift+v"
    #[serde(default = "default_hotkey_off")]
    pub hotkey_active: String, // "off" | "ctrl+alt+a" | "alt+shift+o" | "ctrl+shift+a"
    #[serde(default = "default_hotkey_off")]
    pub hotkey_mini: String, // Mini-Preview toggle shortcut
    #[serde(default = "default_true")]
    pub notify_on_needs_input: bool,
    #[serde(default = "default_true")]
    pub notify_on_completion: bool,
    #[serde(default)]
    pub notify_sound: bool,
    #[serde(default)]
    pub launch_at_login: bool,
    #[serde(default)]
    pub custom_agents: Vec<CustomAgentConfig>,
    #[serde(default)]
    pub watched_folders: Vec<String>,
    #[serde(default)]
    pub checklist: Vec<ChecklistItem>,
}

fn default_density() -> String {
    "compact".to_string()
}
fn default_tray_style() -> String {
    "project".to_string()
}
fn default_lang() -> String {
    "auto".to_string()
}
fn default_opacity() -> u8 {
    94
}
fn default_launcher() -> String {
    "auto".to_string()
}
fn default_project_scope() -> String {
    "all".to_string()
}
fn default_hotkey_hud() -> String {
    "ctrl+alt+o".to_string()
}
fn default_hotkey_off() -> String {
    "off".to_string()
}
fn default_true() -> bool {
    true
}

impl Default for OrbitConfig {
    fn default() -> Self {
        Self {
            density: default_density(),
            tray_style: default_tray_style(),
            lang: default_lang(),
            opacity: default_opacity(),
            context_window_override: 0,
            preferred_launcher: default_launcher(),
            project_scope: default_project_scope(),
            show_all_active_projects: true,
            snap_grid_enabled: true,
            show_cost_estimate: true,
            hotkey_hud: default_hotkey_hud(),
            hotkey_density: default_hotkey_off(),
            hotkey_active: default_hotkey_off(),
            hotkey_mini: default_hotkey_off(),
            notify_on_needs_input: true,
            notify_on_completion: true,
            notify_sound: false,
            launch_at_login: false,
            custom_agents: Vec::new(),
            watched_folders: Vec::new(),
            checklist: Vec::new(),
        }
    }
}

/// Resolves configured watched folders into live `WatchedFolderStatus` items.
pub fn resolve_watched_folders(paths: &[String]) -> Vec<WatchedFolderStatus> {
    paths
        .iter()
        .filter(|p| !p.trim().is_empty())
        .map(|raw| {
            let expanded = expand_tilde(raw);
            let resolved = resolve_path(&expanded);
            let is_online = resolved.is_dir();
            let display_name = resolved
                .file_name()
                .and_then(|n| n.to_str())
                .filter(|s| !s.is_empty())
                .unwrap_or(raw)
                .to_string();
            let git_branch = if is_online {
                detect_git_branch(&resolved)
            } else {
                None
            };
            WatchedFolderStatus {
                configured_path: raw.clone(),
                resolved_path: resolved.to_string_lossy().into_owned(),
                display_name,
                is_online,
                git_branch,
            }
        })
        .collect()
}

pub fn default_config_path() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("AgentOrbit")
        .join("config.json")
}

pub fn load_config_from(path: &Path) -> OrbitConfig {
    let Ok(text) = fs::read_to_string(path) else {
        return OrbitConfig::default();
    };
    serde_json::from_str(&text).unwrap_or_default()
}

pub fn save_config_to(path: &Path, config: &OrbitConfig) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let json = serde_json::to_string_pretty(config)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    fs::write(path, json)
}

pub fn snap_to_grid(
    x: i32,
    y: i32,
    win_w: i32,
    win_h: i32,
    screen_x: i32,
    screen_y: i32,
    screen_w: i32,
    screen_h: i32,
    grid_step: i32,
    edge_margin: i32,
) -> (i32, i32) {
    let step = grid_step.max(1);
    let min_x = screen_x + edge_margin;
    let max_x = (screen_x + screen_w - win_w - edge_margin).max(min_x);
    let min_y = screen_y + edge_margin;
    let max_y = (screen_y + screen_h - win_h - edge_margin).max(min_y);

    let snap_axis = |val: i32, min_v: i32, max_v: i32| -> i32 {
        let clamped = val.clamp(min_v, max_v);
        if (clamped - min_v).abs() <= step {
            return min_v;
        }
        if (max_v - clamped).abs() <= step {
            return max_v;
        }
        let center = (min_v + max_v) / 2;
        if (clamped - center).abs() <= step / 2 {
            return center;
        }
        let offset = clamped - min_v;
        let snapped = min_v + ((offset + step / 2) / step) * step;
        snapped.clamp(min_v, max_v)
    };

    (snap_axis(x, min_x, max_x), snap_axis(y, min_y, max_y))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn roundtrips_config_and_checklist_in_temp_file() {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir()
            .join(format!("agentorbit_cfg_{nanos}"))
            .join("config.json");

        let mut cfg = OrbitConfig::default();
        cfg.density = "detail".to_string();
        cfg.tray_style = "project_model".to_string();
        cfg.context_window_override = 500_000;
        cfg.hotkey_hud = "alt+space".to_string();
        cfg.notify_sound = true;
        cfg.checklist.push(ChecklistItem {
            id: "t1".to_string(),
            text: "Finish v2 parity".to_string(),
            done: true,
        });

        save_config_to(&path, &cfg).unwrap();
        let loaded = load_config_from(&path);
        assert_eq!(loaded, cfg);

        if let Some(parent) = path.parent() {
            let _ = fs::remove_dir_all(parent);
        }
    }

    #[test]
    fn snaps_window_to_24px_grid_and_edges() {
        assert_eq!(
            snap_to_grid(20, 18, 360, 420, 0, 0, 1920, 1080, 24, 12),
            (12, 12)
        );
        let (sx, sy) = snap_to_grid(130, 200, 360, 420, 0, 0, 1920, 1080, 24, 12);
        assert_eq!((sx - 12) % 24, 0);
        assert_eq!((sy - 12) % 24, 0);
        assert_eq!(
            snap_to_grid(1540, 640, 360, 420, 0, 0, 1920, 1080, 24, 12),
            (1920 - 360 - 12, 1080 - 420 - 12)
        );
    }
}
