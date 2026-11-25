use crate::models::CustomAgentConfig;
use crate::paths::resolve_path;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DiscoveredAgents {
    pub has_codex: bool,
    pub codex_path: String,
    pub has_antigravity: bool,
    pub antigravity_path: String,
    pub custom_agents: Vec<CustomAgentConfig>,
}

pub fn discover_default_agents() -> DiscoveredAgents {
    let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("."));
    discover_agents_in(&home)
}

pub fn discover_agents_in(home_dir: &Path) -> DiscoveredAgents {
    let codex_dir = home_dir.join(".codex");
    let has_codex = resolve_path(&codex_dir).is_dir();

    let agy_primary = home_dir.join(".gemini").join("antigravity");
    let agy_fallback = home_dir.join(".antigravity");
    let has_primary_agy = resolve_path(&agy_primary).is_dir();
    let has_fallback_agy = resolve_path(&agy_fallback).is_dir();
    let has_antigravity = has_primary_agy || has_fallback_agy;
    let chosen_agy = if !has_primary_agy && has_fallback_agy {
        agy_fallback
    } else {
        agy_primary
    };

    let mut custom_agents = Vec::new();

    // OpenCode (XDG / ~/.local/share/opencode)
    let opencode_dir = home_dir.join(".local").join("share").join("opencode");
    if opencode_dir.join("opencode.db").is_file() {
        custom_agents.push(CustomAgentConfig {
            name: "OpenCode".to_string(),
            path: opencode_dir.to_string_lossy().into_owned(),
            is_enabled: true,
        });
    }

    // LM Studio Bionic
    let bionic_dir = home_dir
        .join(".cache")
        .join("lm-studio")
        .join("apps")
        .join("bionic");
    if resolve_path(bionic_dir.join("projects")).is_dir() {
        custom_agents.push(CustomAgentConfig {
            name: "Bionic".to_string(),
            path: bionic_dir.to_string_lossy().into_owned(),
            is_enabled: true,
        });
    }

    // Pi agent
    let pi_dir = home_dir.join(".pi").join("agent");
    if resolve_path(&pi_dir).is_dir() {
        custom_agents.push(CustomAgentConfig {
            name: "Pi".to_string(),
            path: pi_dir.to_string_lossy().into_owned(),
            is_enabled: true,
        });
    }

    // Claude Code
    let claude_dir = home_dir.join(".claude");
    if resolve_path(claude_dir.join("projects")).is_dir()
        || resolve_path(claude_dir.join("sessions")).is_dir()
    {
        custom_agents.push(CustomAgentConfig {
            name: "Claude".to_string(),
            path: claude_dir.to_string_lossy().into_owned(),
            is_enabled: true,
        });
    }

    DiscoveredAgents {
        has_codex,
        codex_path: codex_dir.to_string_lossy().into_owned(),
        has_antigravity,
        antigravity_path: chosen_agy.to_string_lossy().into_owned(),
        custom_agents,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn discovers_installed_agents_in_synthetic_home() {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let home = std::env::temp_dir().join(format!("agentorbit_discover_{nanos}"));
        fs::create_dir_all(home.join(".codex")).unwrap();
        fs::create_dir_all(home.join(".gemini/antigravity")).unwrap();
        fs::create_dir_all(home.join(".claude/projects")).unwrap();
        fs::create_dir_all(home.join(".local/share/opencode")).unwrap();
        fs::write(home.join(".local/share/opencode/opencode.db"), b"").unwrap();

        let found = discover_agents_in(&home);
        assert!(found.has_codex);
        assert!(found.has_antigravity);
        let names: Vec<&str> = found.custom_agents.iter().map(|c| c.name.as_str()).collect();
        assert!(names.contains(&"OpenCode"));
        assert!(names.contains(&"Claude"));

        let _ = fs::remove_dir_all(&home);
    }
}
