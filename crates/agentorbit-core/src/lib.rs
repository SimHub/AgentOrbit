pub mod antigravity;
pub mod codex;
pub mod config;
pub mod cost;
pub mod custom;
pub mod discovery;
pub mod models;
pub mod paths;
pub mod sqlite;
pub mod watcher;

pub use antigravity::read_antigravity_sessions;
pub use codex::read_codex_sessions;
pub use config::{
    default_config_path, load_config_from, resolve_watched_folders, save_config_to, snap_to_grid,
    ChecklistItem, OrbitConfig,
};
pub use cost::{estimate_cost, CostEstimate};
pub use custom::read_custom_sessions;
pub use discovery::{discover_agents_in, discover_default_agents, DiscoveredAgents};
pub use models::{
    now_epoch_secs, system_time_to_epoch, AgentKind, AgentRunState, AgentSnapshot,
    CompletedSessionEvent, CustomAgentConfig, NeedsInputEvent, RateLimitWindow, TaskStep,
    TaskStepStatus, UsageMetrics, WatchedFolderStatus,
};
pub use paths::{detect_git_branch, expand_tilde, project_display_name, resolve_path};
pub use watcher::OrbitWatcher;

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

/// Performs a single read-only scan across all auto-discovered local agents
/// (plus any user-configured custom agents) sorted by priority.
pub fn scan_discovered_agents(limit_per_agent: usize) -> (DiscoveredAgents, Vec<AgentSnapshot>) {
    scan_agents_with_config(&OrbitConfig::default(), limit_per_agent)
}

pub fn scan_agents_with_config(
    config: &OrbitConfig,
    limit_per_agent: usize,
) -> (DiscoveredAgents, Vec<AgentSnapshot>) {
    let mut discovered = discover_default_agents();

    let mut seen_paths: HashSet<String> = discovered
        .custom_agents
        .iter()
        .map(|c| c.path.clone())
        .collect();
    for user_agent in &config.custom_agents {
        if !user_agent.path.trim().is_empty() && seen_paths.insert(user_agent.path.clone()) {
            discovered.custom_agents.push(user_agent.clone());
        }
    }

    let watched = resolve_watched_folders(&config.watched_folders);
    let mut snapshots = Vec::new();
    if discovered.has_codex {
        snapshots.extend(read_codex_sessions(
            &discovered.codex_path,
            &watched,
            limit_per_agent,
        ));
    }
    if discovered.has_antigravity {
        snapshots.extend(read_antigravity_sessions(
            &discovered.antigravity_path,
            &watched,
            &HashMap::new(),
            config.context_window_override,
            limit_per_agent,
        ));
    }
    for custom_cfg in &discovered.custom_agents {
        snapshots.extend(read_custom_sessions(custom_cfg, &watched, limit_per_agent));
    }

    snapshots.sort_by(|a, b| {
        a.state
            .cmp(&b.state)
            .then_with(|| b.last_updated_epoch.cmp(&a.last_updated_epoch))
    });

    (discovered, snapshots)
}

/// Returns all watchable root paths for the discovered local agents.
pub fn watch_paths_for(discovered: &DiscoveredAgents) -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if discovered.has_codex {
        paths.push(PathBuf::from(&discovered.codex_path));
    }
    if discovered.has_antigravity {
        paths.push(PathBuf::from(&discovered.antigravity_path));
    }
    for cfg in &discovered.custom_agents {
        if cfg.is_enabled {
            paths.push(PathBuf::from(&cfg.path));
        }
    }
    paths
}
