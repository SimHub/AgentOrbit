use crate::models::{
    now_epoch_secs, system_time_to_epoch, AgentKind, AgentRunState, AgentSnapshot, RateLimitWindow,
    UsageMetrics, WatchedFolderStatus,
};
use crate::paths::{detect_git_branch, expand_tilde, project_display_name, resolve_path};
use crate::sqlite::open_readonly;
use chrono::DateTime;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct CodexConfigDefaults {
    pub model: Option<String>,
    pub reasoning_effort: Option<String>,
}

#[derive(Debug, Default, Clone, PartialEq)]
pub struct SessionTailMetrics {
    pub usage: UsageMetrics,
    pub last_event_epoch: Option<i64>,
    pub has_open_turn: bool,
    pub pending_user_input_tool: Option<String>,
    pub pending_approval_tool: Option<String>,
}

pub fn read_codex_sessions(
    raw_path: &str,
    watched_folders: &[WatchedFolderStatus],
    limit: usize,
) -> Vec<AgentSnapshot> {
    if raw_path.trim().is_empty() {
        return vec![AgentSnapshot::placeholder(
            AgentKind::Codex,
            AgentRunState::Unavailable,
            Some("No .codex path configured".to_string()),
        )];
    }

    let resolved_root = resolve_path(expand_tilde(raw_path));
    if !resolved_root.is_dir() {
        let is_volume = resolved_root.to_string_lossy().starts_with("/Volumes/");
        let state = if is_volume {
            AgentRunState::Offline
        } else {
            AgentRunState::Unavailable
        };
        let msg = if is_volume {
            format!("Volume not mounted ({})", resolved_root.display())
        } else {
            "Directory not found".to_string()
        };
        return vec![AgentSnapshot::placeholder(
            AgentKind::Codex,
            state,
            Some(msg),
        )];
    }

    let config_defaults = parse_config_toml(&resolved_root.join("config.toml"));
    let db_path = resolved_root.join("state_5.sqlite");
    let Some(conn) = open_readonly(&db_path) else {
        return vec![idle_placeholder(&resolved_root, &config_defaults)];
    };

    let has_approval_mode = table_has_column(&conn, "threads", "approval_mode");
    let fetch_count = (limit * 2).max(12) as i64;
    let sql = if has_approval_mode {
        "SELECT id, cwd, model, reasoning_effort, tokens_used, git_branch, updated_at, title, rollout_path, approval_mode \
         FROM threads WHERE archived = 0 ORDER BY updated_at DESC LIMIT ?1"
    } else {
        "SELECT id, cwd, model, reasoning_effort, tokens_used, git_branch, updated_at, title, rollout_path, NULL as approval_mode \
         FROM threads WHERE archived = 0 ORDER BY updated_at DESC LIMIT ?1"
    };

    let mut stmt = match conn.prepare(sql) {
        Ok(s) => s,
        Err(_) => return vec![idle_placeholder(&resolved_root, &config_defaults)],
    };

    let rows: Vec<ThreadRow> = match stmt.query_map([fetch_count], |row| {
        Ok(ThreadRow {
            id: row.get::<_, Option<String>>(0)?,
            cwd: row.get::<_, Option<String>>(1)?,
            model: row.get::<_, Option<String>>(2)?,
            reasoning_effort: row.get::<_, Option<String>>(3)?,
            tokens_used: row.get::<_, Option<i64>>(4)?,
            git_branch: row.get::<_, Option<String>>(5)?,
            updated_at: row.get::<_, Option<f64>>(6)?,
            title: row.get::<_, Option<String>>(7)?,
            rollout_path: row.get::<_, Option<String>>(8)?,
            approval_mode: row.get::<_, Option<String>>(9)?,
        })
    }) {
        Ok(iter) => iter.filter_map(Result::ok).collect(),
        Err(_) => Vec::new(),
    };

    if rows.is_empty() {
        return vec![idle_placeholder(&resolved_root, &config_defaults)];
    }

    let now = now_epoch_secs();
    let has_active_lock = has_recent_lock(&resolved_root.join("thread-writer-locks"), now);
    let mut results = Vec::new();
    let mut seen_projects = HashSet::new();

    for (idx, row) in rows.into_iter().enumerate() {
        let thread_id = non_empty(row.id).unwrap_or_else(|| format!("codex-{idx}"));
        let cwd = non_empty(row.cwd);
        let model = non_empty(row.model)
            .or_else(|| config_defaults.model.clone())
            .unwrap_or_else(|| "—".to_string());
        let effort = non_empty(row.reasoning_effort).or_else(|| config_defaults.reasoning_effort.clone());
        let db_tokens = row.tokens_used.and_then(|v| u64::try_from(v).ok());
        let db_branch = non_empty(row.git_branch);
        let title = non_empty(row.title);
        let updated_at = row.updated_at.map(|v| v as i64);
        let rollout_path = non_empty(row.rollout_path);

        let resolved_rollout = rollout_path
            .as_deref()
            .and_then(|p| resolve_rollout_path(p, &resolved_root));
        let mut tail = resolved_rollout
            .as_deref()
            .map(|p| parse_session_tail(p, 96_000))
            .unwrap_or_default();

        if tail.usage.session_total_tokens.is_none() {
            tail.usage.session_total_tokens = db_tokens;
        }

        let rollout_mtime = resolved_rollout
            .as_deref()
            .and_then(|p| fs::metadata(p).ok())
            .and_then(|m| m.modified().ok())
            .and_then(system_time_to_epoch);

        let newest_ts = [updated_at, tail.last_event_epoch, rollout_mtime]
            .into_iter()
            .flatten()
            .max();
        let age = newest_ts.map(|ts| (now - ts).max(0)).unwrap_or(i64::MAX);
        let is_very_recent = age < 20;
        let approval_allowed = non_empty(row.approval_mode)
            .map(|m| m.to_lowercase() != "never")
            .unwrap_or(true);

        let (state, interaction_reason) = if tail.pending_user_input_tool.is_some() && age < 86_400 {
            (AgentRunState::NeedsInput, Some("Rückfrage".to_string()))
        } else if tail.has_open_turn
            && tail.pending_approval_tool.is_some()
            && approval_allowed
            && (10..7_200).contains(&age)
        {
            let reason = if tail.pending_approval_tool.as_deref() == Some("apply_patch") {
                "Patch-Freigabe"
            } else {
                "Freigabe nötig"
            };
            (AgentRunState::NeedsInput, Some(reason.to_string()))
        } else if (has_active_lock && is_very_recent) || age < 8 || (tail.has_open_turn && age < 25) {
            (AgentRunState::Running, None)
        } else {
            (AgentRunState::Idle, None)
        };

        let project_key = cwd.clone().unwrap_or_else(|| thread_id.clone());
        if !state.is_active_or_waiting() && !results.is_empty() {
            if seen_projects.contains(&project_key) || age > 86_400 {
                continue;
            }
        }
        seen_projects.insert(project_key);

        let live_branch = cwd.as_deref().and_then(detect_git_branch).or(db_branch);
        let project_name = project_display_name(cwd.as_deref(), watched_folders);

        results.push(AgentSnapshot {
            kind: AgentKind::Codex,
            session_id: thread_id,
            agent_label: AgentKind::Codex.as_str().to_string(),
            state,
            project_name,
            project_path: cwd,
            git_branch: live_branch,
            model_name: model,
            reasoning_effort: effort,
            session_title: title,
            usage: tail.usage,
            last_updated_epoch: newest_ts,
            active_since_epoch: None,
            resolved_source_path: Some(resolved_root.to_string_lossy().into_owned()),
            status_message: None,
            interaction_reason,
        });

        if results.len() >= limit {
            break;
        }
    }

    results
}

pub fn parse_config_toml(path: &Path) -> CodexConfigDefaults {
    let Ok(text) = fs::read_to_string(path) else {
        return CodexConfigDefaults::default();
    };
    let mut defaults = CodexConfigDefaults::default();
    for raw_line in text.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line.starts_with('[') {
            break;
        }
        if let Some((key, val)) = line.split_once('=') {
            let key = key.trim();
            let val = val.trim().trim_matches('"').to_string();
            if key == "model" && !val.is_empty() {
                defaults.model = Some(val);
            } else if key == "model_reasoning_effort" && !val.is_empty() {
                defaults.reasoning_effort = Some(val);
            }
        }
    }
    defaults
}

pub fn parse_session_tail(path: &Path, tail_bytes: u64) -> SessionTailMetrics {
    let Ok(mut file) = File::open(path) else {
        return SessionTailMetrics::default();
    };
    let Ok(file_size) = file.seek(SeekFrom::End(0)) else {
        return SessionTailMetrics::default();
    };
    let offset = file_size.saturating_sub(tail_bytes);
    if file.seek(SeekFrom::Start(offset)).is_err() {
        return SessionTailMetrics::default();
    }
    let mut buf = Vec::new();
    if file.read_to_end(&mut buf).is_err() {
        return SessionTailMetrics::default();
    }
    let text = String::from_utf8_lossy(&buf);
    parse_session_jsonl(&text, offset > 0)
}

pub fn parse_session_jsonl(text: &str, dropped_leading_partial_line: bool) -> SessionTailMetrics {
    let mut lines = text.lines().filter(|l| !l.trim().is_empty());
    if dropped_leading_partial_line {
        let _ = lines.next();
    }

    let mut usage = UsageMetrics::default();
    let mut last_event_epoch: Option<i64> = None;
    let mut has_open_turn = false;
    let mut pending_calls: HashMap<String, String> = HashMap::new();
    let mut pending_order: Vec<String> = Vec::new();

    for line in lines {
        let Ok(json) = serde_json::from_str::<Value>(line) else {
            continue;
        };

        if let Some(ts) = json.get("timestamp").and_then(Value::as_str) {
            if let Ok(dt) = DateTime::parse_from_rfc3339(ts) {
                last_event_epoch = Some(dt.timestamp());
            }
        }

        let top_type = json.get("type").and_then(Value::as_str);
        let Some(payload) = json.get("payload") else {
            continue;
        };
        let payload_type = payload.get("type").and_then(Value::as_str);

        match (top_type, payload_type) {
            (Some("event_msg"), Some("task_started")) => {
                has_open_turn = true;
                pending_calls.clear();
                pending_order.clear();
            }
            (Some("event_msg"), Some("task_complete" | "turn_aborted")) => {
                has_open_turn = false;
                pending_calls.clear();
                pending_order.clear();
            }
            (Some("event_msg"), Some("token_count")) => {
                if let Some(info) = payload.get("info") {
                    if let Some(total) = info.get("total_token_usage") {
                        usage.session_total_tokens = total.get("total_tokens").and_then(Value::as_u64);
                        usage.input_tokens = total.get("input_tokens").and_then(Value::as_u64);
                        usage.cache_read_tokens = total.get("cached_input_tokens").and_then(Value::as_u64);
                        usage.output_tokens = total.get("output_tokens").and_then(Value::as_u64);
                    }
                    if let Some(last) = info.get("last_token_usage") {
                        usage.context_tokens = last
                            .get("total_tokens")
                            .and_then(Value::as_u64)
                            .or_else(|| last.get("input_tokens").and_then(Value::as_u64));
                    }
                    usage.context_window = info.get("model_context_window").and_then(Value::as_u64);
                }
                if let Some(limits) = payload.get("rate_limits") {
                    usage.plan_type = limits
                        .get("plan_type")
                        .and_then(Value::as_str)
                        .map(str::to_string);
                    usage.primary_limit = limits.get("primary").and_then(parse_rate_limit);
                    usage.secondary_limit = limits.get("secondary").and_then(parse_rate_limit);
                }
            }
            (Some("response_item"), Some("function_call" | "custom_tool_call")) => {
                let call_id = payload.get("call_id").and_then(Value::as_str).unwrap_or("");
                let name = payload.get("name").and_then(Value::as_str).unwrap_or("");
                if !call_id.is_empty() && !name.is_empty() {
                    has_open_turn = true;
                    pending_calls.insert(call_id.to_string(), name.to_string());
                    pending_order.push(call_id.to_string());
                }
            }
            (Some("response_item"), Some("function_call_output" | "custom_tool_call_output")) => {
                if let Some(call_id) = payload.get("call_id").and_then(Value::as_str) {
                    pending_calls.remove(call_id);
                }
            }
            _ => {}
        }
    }

    let mut pending_user_input_tool = None;
    let mut pending_approval_tool = None;
    for call_id in pending_order.iter().rev() {
        let Some(name) = pending_calls.get(call_id) else {
            continue;
        };
        if pending_user_input_tool.is_none()
            && matches!(name.as_str(), "request_user_input" | "request_user_input_async")
        {
            pending_user_input_tool = Some(name.clone());
        } else if pending_approval_tool.is_none()
            && matches!(name.as_str(), "exec" | "exec_command" | "apply_patch")
        {
            pending_approval_tool = Some(name.clone());
        }
    }

    SessionTailMetrics {
        usage,
        last_event_epoch,
        has_open_turn,
        pending_user_input_tool,
        pending_approval_tool,
    }
}

struct ThreadRow {
    id: Option<String>,
    cwd: Option<String>,
    model: Option<String>,
    reasoning_effort: Option<String>,
    tokens_used: Option<i64>,
    git_branch: Option<String>,
    updated_at: Option<f64>,
    title: Option<String>,
    rollout_path: Option<String>,
    approval_mode: Option<String>,
}

fn idle_placeholder(resolved_root: &Path, defaults: &CodexConfigDefaults) -> AgentSnapshot {
    AgentSnapshot {
        kind: AgentKind::Codex,
        session_id: AgentKind::Codex.as_str().to_string(),
        agent_label: AgentKind::Codex.as_str().to_string(),
        state: AgentRunState::Idle,
        project_name: "—".to_string(),
        project_path: None,
        git_branch: None,
        model_name: defaults.model.clone().unwrap_or_else(|| "—".to_string()),
        reasoning_effort: defaults.reasoning_effort.clone(),
        session_title: None,
        usage: UsageMetrics::default(),
        last_updated_epoch: None,
        active_since_epoch: None,
        resolved_source_path: Some(resolved_root.to_string_lossy().into_owned()),
        status_message: Some("No session yet".to_string()),
        interaction_reason: None,
    }
}

fn table_has_column(conn: &rusqlite::Connection, table: &str, col_name: &str) -> bool {
    let Ok(mut stmt) = conn.prepare(&format!("PRAGMA table_info({table})")) else {
        return false;
    };
    let Ok(rows) = stmt.query_map([], |row| row.get::<_, String>(1)) else {
        return false;
    };
    let found = rows.filter_map(Result::ok).any(|c| c == col_name);
    found
}

fn resolve_rollout_path(rollout_path: &str, codex_root: &Path) -> Option<PathBuf> {
    let direct = resolve_path(rollout_path);
    if direct.is_file() {
        return Some(direct);
    }
    if let Some((_, rel)) = rollout_path.split_once("/sessions/") {
        let remapped = codex_root.join("sessions").join(rel);
        if remapped.is_file() {
            return Some(remapped);
        }
    }
    None
}

fn has_recent_lock(dir: &Path, now_epoch: i64) -> bool {
    let Ok(entries) = fs::read_dir(dir) else {
        return false;
    };
    for entry in entries.flatten() {
        if let Ok(meta) = entry.metadata() {
            if let Ok(mtime) = meta.modified() {
                if let Some(ts) = system_time_to_epoch(mtime) {
                    if (now_epoch - ts).abs() < 15 {
                        return true;
                    }
                }
            }
        }
    }
    false
}

fn parse_rate_limit(val: &Value) -> Option<RateLimitWindow> {
    let used_percent = val.get("used_percent").and_then(Value::as_f64)?;
    let window_minutes = val.get("window_minutes").and_then(Value::as_u64)? as u32;
    let resets_at_epoch = val.get("resets_at").and_then(Value::as_f64).map(|v| v as i64);
    Some(RateLimitWindow {
        used_percent,
        window_minutes,
        resets_at_epoch,
    })
}

fn non_empty(val: Option<String>) -> Option<String> {
    val.map(|s| s.trim().to_string()).filter(|s| !s.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn parses_codex_jsonl_tokens_and_needs_input() {
        let jsonl = r#"
{"timestamp":"2026-11-25T10:00:00Z","type":"event_msg","payload":{"type":"task_started"}}
{"timestamp":"2026-11-25T10:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":12000,"input_tokens":10000,"cached_input_tokens":4000,"output_tokens":2000},"last_token_usage":{"total_tokens":8000},"model_context_window":200000},"rate_limits":{"plan_type":"pro","primary":{"used_percent":22.5,"window_minutes":300,"resets_at":1795550000}}}}
{"timestamp":"2026-11-25T10:00:05Z","type":"response_item","payload":{"type":"function_call","call_id":"call_1","name":"request_user_input"}}
"#;
        let metrics = parse_session_jsonl(jsonl, false);
        assert!(metrics.has_open_turn);
        assert_eq!(
            metrics.pending_user_input_tool.as_deref(),
            Some("request_user_input")
        );
        assert_eq!(metrics.usage.session_total_tokens, Some(12_000));
        assert_eq!(metrics.usage.context_window, Some(200_000));
        assert_eq!(
            metrics.usage.primary_limit.as_ref().map(|l| l.window_minutes),
            Some(300)
        );
    }

    #[test]
    fn reads_synthetic_codex_sqlite_end_to_end() {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("agentorbit_codex_e2e_{nanos}"));
        let project = root.join("demo-project");
        fs::create_dir_all(&project).unwrap();
        fs::write(
            root.join("config.toml"),
            "model = \"gpt-5.3-codex\"\nmodel_reasoning_effort = \"high\"\n",
        )
        .unwrap();

        let db_path = root.join("state_5.sqlite");
        let conn = Connection::open(&db_path).unwrap();
        conn.execute(
            "CREATE TABLE threads (id TEXT, cwd TEXT, model TEXT, reasoning_effort TEXT, tokens_used INTEGER, git_branch TEXT, updated_at REAL, title TEXT, rollout_path TEXT, archived INTEGER)",
            [],
        )
        .unwrap();
        let now = now_epoch_secs() as f64;
        conn.execute(
            "INSERT INTO threads VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 0)",
            rusqlite::params![
                "thread-1",
                project.to_string_lossy().as_ref(),
                "gpt-5.3-codex",
                "high",
                42000_i64,
                "main",
                now,
                "Demo Task",
                ""
            ],
        )
        .unwrap();
        drop(conn);

        let sessions = read_codex_sessions(&root.to_string_lossy(), &[], 4);
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].state, AgentRunState::Running);
        assert_eq!(sessions[0].project_name, "demo-project");
        assert_eq!(sessions[0].model_name, "gpt-5.3-codex");
        assert_eq!(sessions[0].usage.session_total_tokens, Some(42_000));

        let _ = fs::remove_dir_all(&root);
    }
}
