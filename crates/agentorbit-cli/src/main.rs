mod tui;

use agentorbit_core::{
    default_config_path, detect_git_branch, estimate_cost, load_config_from, resolve_path,
    scan_agents_with_config, watch_paths_for, AgentSnapshot, OrbitWatcher,
};
use std::env;
use std::time::Duration;

fn main() {
    let args: Vec<String> = env::args().collect();
    let subcmd = args.get(1).map(String::as_str).unwrap_or("scan");
    let as_json = args.iter().any(|a| a == "--json");

    match subcmd {
        "--version" | "-V" | "version" => {
            println!("AgentOrbit v{}", env!("CARGO_PKG_VERSION"));
        }
        "--help" | "-h" | "help" => {
            println!("AgentOrbit v{}", env!("CARGO_PKG_VERSION"));
            println!("Usage: agentorbit <tui|scan|watch|branch|--version> [--json]");
        }
        "tui" => {
            if let Err(err) = tui::run_tui() {
                eprintln!("AgentOrbit TUI error: {err}");
            }
        }
        "branch" => {
            let target = args.get(2).map(String::as_str).unwrap_or(".");
            let resolved = resolve_path(target);
            let branch = detect_git_branch(&resolved).unwrap_or_else(|| "—".to_string());
            println!("Path:   {}", resolved.display());
            println!("Branch: {}", branch);
        }
        "watch" => {
            let cfg = load_config_from(&default_config_path());
            let (discovered, snapshots) = scan_agents_with_config(&cfg, 8);
            render_snapshots(&snapshots, as_json);
            let paths = watch_paths_for(&discovered);
            let Ok(mut watcher) = OrbitWatcher::start(&paths, Duration::from_millis(300)) else {
                eprintln!("Failed to start filesystem watcher.");
                return;
            };
            loop {
                if watcher.wait_for_change(Duration::from_secs(5)) {
                    let cfg = load_config_from(&default_config_path());
                    let (_, updated) = scan_agents_with_config(&cfg, 8);
                    render_snapshots(&updated, as_json);
                }
            }
        }
        _ => {
            let cfg = load_config_from(&default_config_path());
            let (_, snapshots) = scan_agents_with_config(&cfg, 8);
            render_snapshots(&snapshots, as_json);
        }
    }
}

fn render_snapshots(snapshots: &[AgentSnapshot], as_json: bool) {
    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(snapshots).unwrap_or_else(|_| "[]".to_string())
        );
        return;
    }

    println!("AgentOrbit v2 Core CLI ({})", env!("CARGO_PKG_VERSION"));
    if snapshots.is_empty() {
        println!("No local agent sessions discovered.");
        return;
    }

    for snap in snapshots {
        let branch = snap.git_branch.as_deref().unwrap_or("—");
        let cost = estimate_cost(&snap.usage, &snap.model_name)
            .map(|c| format!(" | {}", c.formatted()))
            .unwrap_or_default();
        let reason = snap
            .interaction_reason
            .as_deref()
            .map(|r| format!(" ({r})"))
            .unwrap_or_default();
        println!(
            "[{:<11}] {:<11} | {:<18} | {:<14} | {}{}{}",
            snap.state.canonical_key(),
            snap.agent_label,
            snap.project_name,
            branch,
            snap.model_name,
            cost,
            reason
        );
    }
}
