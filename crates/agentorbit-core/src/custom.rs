use crate::models::{
    now_epoch_secs, system_time_to_epoch, AgentKind, AgentRunState, AgentSnapshot,
    CustomAgentConfig, TaskStep, TaskStepStatus, UsageMetrics, WatchedFolderStatus,
};
use crate::paths::{detect_git_branch, expand_tilde, project_display_name, resolve_path};
use crate::sqlite::open_readonly;
use rusqlite::Connection;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

pub fn read_custom_sessions(
    config: &CustomAgentConfig,
    watched_folders: &[WatchedFolderStatus],
    limit: usize,
) -> Vec<AgentSnapshot> {
    if !config.is_enabled {
        return Vec::new();
    }

    let label = if config.name.trim().is_empty() {
        "Custom".to_string()
    } else {
        config.name.trim().to_string()
    };

    if config.path.trim().is_empty() {
        return vec![custom_placeholder(
            &label,
            AgentRunState::Unavailable,
            Some("No path configured".to_string()),
        )];
    }

    let resolved_root = resolve_path(expand_tilde(&config.path));
    if !resolved_root.exists() {
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
        return vec![custom_placeholder(&label, state, Some(msg))];
    }

    let is_dir = resolved_root.is_dir();

    // 1. OpenCode SQLite (opencode.db)
    let opencode_db = if is_dir {
        resolved_root.join("opencode.db")
    } else {
        resolved_root.clone()
    };
    if opencode_db.file_name().and_then(|n| n.to_str()) == Some("opencode.db")
        && opencode_db.is_file()
    {
        let sessions = read_opencode_db(&opencode_db, &label, watched_folders, limit);
        if !sessions.is_empty() {
            return sessions;
        }
    }

    // 2. LM Studio Bionic (projects/*/.internal/ng-sessions.sqlite)
    if let Some(bionic_sessions) =
        read_bionic_sessions(&resolved_root, &label, watched_folders, limit)
    {
        return bionic_sessions;
    }

    // 3. Generic JSONL sessions (Claude Code, Pi, etc.)
    if is_dir {
        let jsonl_sessions =
            read_recent_jsonl_sessions(&resolved_root, &label, watched_folders, limit);
        if !jsonl_sessions.is_empty() {
            return jsonl_sessions;
        }
    }

    // 4. Generic folder activity fallback
    let mtime = newest_mtime_shallow(&resolved_root);
    let now = now_epoch_secs();
    let is_live = mtime.map(|ts| (now - ts).max(0) < 20).unwrap_or(false);
    let root_str = resolved_root.to_string_lossy().into_owned();
    vec![AgentSnapshot {
        kind: AgentKind::Custom,
        session_id: label.clone(),
        agent_label: label.clone(),
        state: if is_live {
            AgentRunState::Running
        } else {
            AgentRunState::Idle
        },
        project_name: label,
        project_path: Some(root_str.clone()),
        git_branch: detect_git_branch(&resolved_root),
        model_name: "—".to_string(),
        reasoning_effort: None,
        session_title: None,
        usage: UsageMetrics::default(),
        last_updated_epoch: mtime,
        active_since_epoch: None,
        resolved_source_path: Some(root_str),
        status_message: mtime.is_none().then(|| "No activity yet".to_string()),
        interaction_reason: None,
        task_steps: Vec::new(),
        recent_activity: Vec::new(),
    }]
}

fn custom_placeholder(label: &str, state: AgentRunState, message: Option<String>) -> AgentSnapshot {
    AgentSnapshot {
        kind: AgentKind::Custom,
        session_id: label.to_string(),
        agent_label: label.to_string(),
        state,
        project_name: "—".to_string(),
        project_path: None,
        git_branch: None,
        model_name: "—".to_string(),
        reasoning_effort: None,
        session_title: None,
        usage: UsageMetrics::default(),
        last_updated_epoch: None,
        active_since_epoch: None,
        resolved_source_path: None,
        status_message: message,
        interaction_reason: None,
        task_steps: Vec::new(),
        recent_activity: Vec::new(),
    }
}

// ============================================================================
// 1. OpenCode (opencode.db: session_v2 + legacy session)
// ============================================================================

fn read_opencode_db(
    db_path: &Path,
    label: &str,
    watched_folders: &[WatchedFolderStatus],
    limit: usize,
) -> Vec<AgentSnapshot> {
    let Some(conn) = open_readonly(db_path) else {
        return Vec::new();
    };
    let tables = list_tables(&conn);
    let use_v2 = tables.contains("session_v2");
    let table_name = if use_v2 { "session_v2" } else { "session" };
    if !tables.contains(table_name) {
        return Vec::new();
    }

    let cols = list_columns(&conn, table_name);
    if !cols.contains("id") || !cols.contains("time_updated") {
        return Vec::new();
    }

    let select_col = |name: &str| {
        if cols.contains(name) {
            name.to_string()
        } else {
            format!("NULL AS {name}")
        }
    };
    let where_clause = if cols.contains("time_archived") {
        "WHERE time_archived IS NULL"
    } else {
        ""
    };
    let fetch_count = (limit * 2).max(12) as i64;
    let sql = format!(
        "SELECT {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {} \
         FROM {table_name} {where_clause} ORDER BY time_updated DESC LIMIT ?1",
        select_col("id"),
        select_col("directory"),
        select_col("title"),
        select_col("model"),
        select_col("cost"),
        select_col("tokens_input"),
        select_col("tokens_output"),
        select_col("tokens_cache_read"),
        select_col("time_updated"),
        select_col("time_busy"),
        select_col("time_idle"),
        select_col("time_suspended"),
    );

    let Ok(mut stmt) = conn.prepare(&sql) else {
        return Vec::new();
    };
    let rows: Vec<OpenCodeRow> = match stmt.query_map([fetch_count], |row| {
        Ok(OpenCodeRow {
            id: row.get(0)?,
            directory: row.get(1)?,
            title: row.get(2)?,
            model: row.get(3)?,
            cost: row.get(4)?,
            tokens_input: row.get(5)?,
            tokens_output: row.get(6)?,
            tokens_cache_read: row.get(7)?,
            time_updated: row.get(8)?,
            time_busy: row.get(9)?,
            time_idle: row.get(10)?,
            time_suspended: row.get(11)?,
        })
    }) {
        Ok(iter) => iter.filter_map(Result::ok).collect(),
        Err(_) => Vec::new(),
    };

    let has_session_message = tables.contains("session_message");
    let has_legacy_message = tables.contains("message");
    let now = now_epoch_secs();
    let mut results = Vec::new();
    let mut seen_projects = HashSet::new();

    for (idx, row) in rows.into_iter().enumerate() {
        let sid = non_empty(row.id).unwrap_or_else(|| format!("{label}-{idx}"));
        let directory = non_empty(row.directory);
        let title = non_empty(row.title);
        let (model_name, reasoning_effort) = parse_opencode_model(row.model.as_deref());

        let updated_at = decode_epoch_ms_or_s(row.time_updated);
        let busy_at = decode_epoch_ms_or_s(row.time_busy);
        let idle_at = decode_epoch_ms_or_s(row.time_idle);
        let suspended_at = decode_epoch_ms_or_s(row.time_suspended);
        let newest = [updated_at, busy_at, idle_at, suspended_at]
            .into_iter()
            .flatten()
            .max();
        let age = newest.map(|ts| (now - ts).max(0)).unwrap_or(i64::MAX);

        let (state, interaction_reason) = resolve_opencode_state(
            &conn,
            &sid,
            use_v2,
            has_session_message,
            has_legacy_message,
            busy_at,
            idle_at,
            suspended_at,
            age,
        );

        let project_key = directory.clone().unwrap_or_else(|| sid.clone());
        if !state.is_active_or_waiting() && !results.is_empty() {
            if seen_projects.contains(&project_key) || age > 86_400 {
                continue;
            }
        }
        seen_projects.insert(project_key);

        let inp = row.tokens_input.and_then(|v| u64::try_from(v).ok());
        let out = row.tokens_output.and_then(|v| u64::try_from(v).ok());
        let cache = row.tokens_cache_read.and_then(|v| u64::try_from(v).ok());
        let total: u64 = [inp, out, cache].into_iter().flatten().sum();

        let usage = UsageMetrics {
            session_total_tokens: (total > 0).then_some(total),
            input_tokens: inp,
            cache_read_tokens: cache,
            output_tokens: out,
            recorded_cost_usd: row.cost.filter(|c| *c > 0.0),
            ..Default::default()
        };

        let last_updated = if state == AgentRunState::Running {
            match (busy_at, idle_at) {
                (Some(b), None) => Some(updated_at.map_or(b, |u| u.max(b))),
                (Some(b), Some(i)) if b > i => Some(updated_at.map_or(b, |u| u.max(b))),
                _ => newest,
            }
        } else {
            newest
        };

        let source_dir = db_path
            .parent()
            .map(|p| p.to_string_lossy().into_owned());

        results.push(AgentSnapshot {
            kind: AgentKind::Custom,
            session_id: format!("{label}:{sid}"),
            agent_label: label.to_string(),
            state,
            project_name: project_display_name(directory.as_deref(), watched_folders),
            project_path: directory.clone(),
            git_branch: directory.as_deref().and_then(detect_git_branch),
            model_name,
            reasoning_effort,
            session_title: title,
            usage,
            last_updated_epoch: last_updated,
            active_since_epoch: if state.is_active_or_waiting() {
                busy_at.or(last_updated)
            } else {
                None
            },
            resolved_source_path: source_dir,
            status_message: None,
            interaction_reason,
            task_steps: Vec::new(),
            recent_activity: Vec::new(),
        });

        if results.len() >= limit {
            break;
        }
    }

    results
}

struct OpenCodeRow {
    id: Option<String>,
    directory: Option<String>,
    title: Option<String>,
    model: Option<String>,
    cost: Option<f64>,
    tokens_input: Option<i64>,
    tokens_output: Option<i64>,
    tokens_cache_read: Option<i64>,
    time_updated: Option<f64>,
    time_busy: Option<f64>,
    time_idle: Option<f64>,
    time_suspended: Option<f64>,
}

fn parse_opencode_model(raw: Option<&str>) -> (String, Option<String>) {
    let Some(trimmed) = raw.map(str::trim).filter(|s| !s.is_empty()) else {
        return ("—".to_string(), None);
    };
    if trimmed.starts_with('{') {
        if let Ok(json) = serde_json::from_str::<Value>(trimmed) {
            if let Some(id) = json
                .get("id")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
            {
                let effort = json
                    .get("variant")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|s| !s.is_empty() && !s.eq_ignore_ascii_case("default"))
                    .map(str::to_string);
                return (id.to_string(), effort);
            }
        }
    }
    (trimmed.to_string(), None)
}

#[allow(clippy::too_many_arguments)]
fn resolve_opencode_state(
    conn: &Connection,
    session_id: &str,
    use_v2: bool,
    has_session_message: bool,
    has_legacy_message: bool,
    busy_at: Option<i64>,
    idle_at: Option<i64>,
    suspended_at: Option<i64>,
    age: i64,
) -> (AgentRunState, Option<String>) {
    if use_v2 {
        if let Some(susp) = suspended_at {
            if idle_at.map_or(true, |i| susp > i) && age < 86_400 {
                return (
                    AgentRunState::NeedsInput,
                    Some("Pausiert / Eingabe".to_string()),
                );
            }
        }

        let is_busy = busy_at.is_some_and(|b| idle_at.map_or(true, |i| b > i));
        if is_busy {
            if has_session_message {
                if let Ok((msg_type, data_str)) = conn.query_row(
                    "SELECT type, data FROM session_message WHERE session_id = ?1 ORDER BY seq DESC LIMIT 1",
                    [session_id],
                    |r| Ok((r.get::<_, Option<String>>(0)?, r.get::<_, Option<String>>(1)?)),
                ) {
                    if msg_type.as_deref() == Some("assistant") {
                        if let Some(json) = data_str
                            .as_deref()
                            .and_then(|s| serde_json::from_str::<Value>(s).ok())
                        {
                            if let Some(items) = json.get("content").and_then(Value::as_array) {
                                let has_question = items.iter().any(|item| {
                                    item.get("type").and_then(Value::as_str) == Some("tool")
                                        && matches!(
                                            item.get("name").and_then(Value::as_str),
                                            Some("question" | "ask_user")
                                        )
                                });
                                if has_question {
                                    return (
                                        AgentRunState::NeedsInput,
                                        Some("Rückfrage".to_string()),
                                    );
                                }
                            }
                        }
                    }
                }
            }
            if age < 21_600 {
                return (AgentRunState::Running, None);
            }
        }
        return (AgentRunState::Idle, None);
    }

    if has_legacy_message && age < 600 {
        if let Ok(Some(data_str)) = conn.query_row(
            "SELECT data FROM message WHERE session_id = ?1 ORDER BY time_updated DESC LIMIT 1",
            [session_id],
            |r| r.get::<_, Option<String>>(0),
        ) {
            if let Ok(json) = serde_json::from_str::<Value>(&data_str) {
                let is_assistant = json.get("role").and_then(Value::as_str) == Some("assistant");
                let has_completed = json
                    .get("time")
                    .and_then(|t| t.get("completed"))
                    .is_some_and(|v| !v.is_null());
                if is_assistant && !has_completed {
                    return (AgentRunState::Running, None);
                }
            }
        }
    }

    if age < 20 {
        (AgentRunState::Running, None)
    } else {
        (AgentRunState::Idle, None)
    }
}

// ============================================================================
// 2. LM Studio Bionic (projects/*/.internal/ng-sessions.sqlite)
// ============================================================================

fn read_bionic_sessions(
    root: &Path,
    label: &str,
    watched_folders: &[WatchedFolderStatus],
    limit: usize,
) -> Option<Vec<AgentSnapshot>> {
    let mut sources: Vec<(PathBuf, Option<String>)> = Vec::new();
    let projects_dir = root.join("projects");
    if projects_dir.is_dir() {
        if let Ok(entries) = fs::read_dir(&projects_dir) {
            for entry in entries.flatten() {
                let dir = entry.path();
                let db = dir.join(".internal").join("ng-sessions.sqlite");
                if db.is_file() {
                    let hint = parse_bionic_project_name(&dir.join("project.json"));
                    sources.push((db, hint));
                }
            }
        }
    }

    if sources.is_empty() {
        for candidate in [
            root.join(".internal").join("ng-sessions.sqlite"),
            root.join("ng-sessions.sqlite"),
            root.to_path_buf(),
        ] {
            if candidate.file_name().and_then(|n| n.to_str()) == Some("ng-sessions.sqlite")
                && candidate.is_file()
            {
                let parent = candidate.parent().unwrap_or(root);
                let proj_dir = if parent.file_name().and_then(|n| n.to_str()) == Some(".internal") {
                    parent.parent().unwrap_or(parent)
                } else {
                    parent
                };
                let hint = parse_bionic_project_name(&proj_dir.join("project.json"));
                sources.push((candidate, hint));
                break;
            }
        }
    }

    if sources.is_empty() {
        return None;
    }

    let now = now_epoch_secs();
    let mut collected = Vec::new();

    for (db_path, hint) in sources {
        let Some(conn) = open_readonly(&db_path) else {
            continue;
        };
        let cols = list_columns(&conn, "sessions");
        if !cols.contains("session_id") || !cols.contains("session_json") {
            continue;
        }

        let where_clause = if cols.contains("parent_session_id") {
            "WHERE parent_session_id IS NULL"
        } else {
            ""
        };
        let order_clause = if cols.contains("updated_timestamp") {
            "ORDER BY updated_timestamp DESC"
        } else {
            ""
        };
        let sql = format!(
            "SELECT session_id, session_name, committed_head_entry_id, session_json, updated_timestamp \
             FROM sessions {where_clause} {order_clause} LIMIT 8"
        );

        let Ok(mut stmt) = conn.prepare(&sql) else {
            continue;
        };
        let wal_path = PathBuf::from(format!("{}-wal", db_path.display()));
        let db_mtime = [file_mtime_epoch(&db_path), file_mtime_epoch(&wal_path)]
            .into_iter()
            .flatten()
            .max();

        let rows: Vec<(Option<String>, Option<String>, Option<String>, Option<String>, Option<f64>)> =
            match stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)))
            {
                Ok(iter) => iter.filter_map(Result::ok).collect(),
                Err(_) => Vec::new(),
            };

        for (idx, (sid, session_name, head_id, session_json, updated_ts)) in
            rows.into_iter().enumerate()
        {
            let Some(json_str) = session_json else {
                continue;
            };
            let Ok(json) = serde_json::from_str::<Value>(&json_str) else {
                continue;
            };
            if json
                .get("subSessionType")
                .and_then(Value::as_str)
                .is_some_and(|s| !s.is_empty())
            {
                continue;
            }

            let sid = non_empty(sid).unwrap_or_else(|| format!("bionic-{idx}"));
            let working_dir = json
                .get("sessionParams")
                .and_then(|p| p.get("working_directory"))
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .map(str::to_string);
            let raw_model = json
                .get("modelSpecifier")
                .and_then(|m| m.get("indexedModelIdentifier"))
                .and_then(Value::as_str);
            let model_name = format_bionic_model_name(raw_model);
            let reasoning_effort = json
                .get("inferenceConfig")
                .and_then(|c| c.get("reasoningLevel"))
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .map(str::to_string);
            let total_tokens = json
                .get("contextEstimation")
                .and_then(|c| c.get("total"))
                .and_then(Value::as_u64);

            let updated_at = decode_epoch_ms_or_s(updated_ts).or(db_mtime);
            let age = updated_at.map(|ts| (now - ts).max(0)).unwrap_or(i64::MAX);
            let (state, interaction_reason) =
                resolve_bionic_state(&conn, head_id.as_deref(), age);

            let project_name = if let Some(ref wd) = working_dir {
                project_display_name(Some(wd), watched_folders)
            } else if let Some(ref h) = hint {
                if !h.is_empty() && h != "No Project" {
                    h.clone()
                } else {
                    label.to_string()
                }
            } else {
                label.to_string()
            };

            collected.push(AgentSnapshot {
                kind: AgentKind::Custom,
                session_id: format!("{label}:{sid}"),
                agent_label: label.to_string(),
                state,
                project_name,
                project_path: working_dir.clone(),
                git_branch: working_dir.as_deref().and_then(detect_git_branch),
                model_name,
                reasoning_effort,
                session_title: non_empty(session_name),
                usage: UsageMetrics {
                    session_total_tokens: total_tokens,
                    context_tokens: total_tokens,
                    ..Default::default()
                },
                last_updated_epoch: updated_at,
                active_since_epoch: None,
                resolved_source_path: db_path.parent().map(|p| p.to_string_lossy().into_owned()),
                status_message: None,
                interaction_reason,
                task_steps: Vec::new(),
                recent_activity: Vec::new(),
            });
        }
    }

    if collected.is_empty() {
        return Some(vec![custom_placeholder(
            label,
            AgentRunState::Idle,
            Some("No Bionic session yet".to_string()),
        )]);
    }

    collected.sort_by(|a, b| {
        b.state
            .is_active_or_waiting()
            .cmp(&a.state.is_active_or_waiting())
            .then_with(|| b.last_updated_epoch.cmp(&a.last_updated_epoch))
    });

    let mut results = Vec::new();
    let mut seen = HashSet::new();
    for snap in collected {
        let age = snap
            .last_updated_epoch
            .map(|ts| (now - ts).max(0))
            .unwrap_or(i64::MAX);
        let key = snap
            .project_path
            .clone()
            .unwrap_or_else(|| snap.project_name.clone());
        if !snap.state.is_active_or_waiting() && !results.is_empty() {
            if seen.contains(&key) || age > 86_400 {
                continue;
            }
        }
        seen.insert(key);
        results.push(snap);
        if results.len() >= limit {
            break;
        }
    }
    Some(results)
}

fn parse_bionic_project_name(path: &Path) -> Option<String> {
    let text = fs::read_to_string(path).ok()?;
    let json: Value = serde_json::from_str(&text).ok()?;
    json.get("name")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

fn format_bionic_model_name(raw: Option<&str>) -> String {
    let Some(trimmed) = raw.map(str::trim).filter(|s| !s.is_empty()) else {
        return "—".to_string();
    };
    trimmed
        .rsplit('/')
        .next()
        .filter(|s| !s.is_empty())
        .unwrap_or(trimmed)
        .to_string()
}

fn resolve_bionic_state(
    conn: &Connection,
    head_entry_id: Option<&str>,
    age: i64,
) -> (AgentRunState, Option<String>) {
    let Some(mut current_id) = head_entry_id
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
    else {
        return if age < 20 {
            (AgentRunState::Running, None)
        } else {
            (AgentRunState::Idle, None)
        };
    };

    let mut tip_json: Option<String> = None;
    for _ in 0..8 {
        if let Ok((next_id, entry_json)) = conn.query_row(
            "SELECT id, entry_json FROM chat_entries WHERE previous_id = ?1 ORDER BY rowid DESC LIMIT 1",
            [&current_id],
            |r| Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?)),
        ) {
            if next_id != current_id {
                current_id = next_id;
                tip_json = entry_json;
                continue;
            }
        }
        break;
    }

    if tip_json.is_none() {
        tip_json = conn
            .query_row(
                "SELECT entry_json FROM chat_entries WHERE id = ?1 LIMIT 1",
                [&current_id],
                |r| r.get::<_, Option<String>>(0),
            )
            .ok()
            .flatten();
    }

    let Some(entry) = tip_json
        .as_deref()
        .and_then(|s| serde_json::from_str::<Value>(s).ok())
    else {
        return if age < 20 {
            (AgentRunState::Running, None)
        } else {
            (AgentRunState::Idle, None)
        };
    };

    match entry.get("type").and_then(Value::as_str).unwrap_or("") {
        "elicitationRequest" => {
            if age < 86_400 {
                (AgentRunState::NeedsInput, Some("Rückfrage".to_string()))
            } else {
                (AgentRunState::Idle, None)
            }
        }
        "forkPoint" => {
            if entry.get("forkPoint").and_then(Value::as_str) == Some("assistantTurnEnd") {
                (AgentRunState::Idle, None)
            } else if age < 21_600 {
                (AgentRunState::Running, None)
            } else {
                (AgentRunState::Idle, None)
            }
        }
        "interrupted" | "error" => (AgentRunState::Idle, None),
        _ => {
            if age < 21_600 {
                (AgentRunState::Running, None)
            } else {
                (AgentRunState::Idle, None)
            }
        }
    }
}

// ============================================================================
// 3. Claude Code & Generic JSONL Sessions
// ============================================================================

fn read_recent_jsonl_sessions(
    root: &Path,
    label: &str,
    watched_folders: &[WatchedFolderStatus],
    limit: usize,
) -> Vec<AgentSnapshot> {
    let mut jsonl_files: Vec<(PathBuf, i64)> = Vec::new();
    for base in [root.join("sessions"), root.join("projects"), root.to_path_buf()] {
        if !base.is_dir() {
            continue;
        }
        let mut scanned = 0_usize;
        collect_jsonl_files(&base, 0, &mut scanned, &mut jsonl_files);
        if !jsonl_files.is_empty() {
            break;
        }
    }

    if jsonl_files.is_empty() {
        return Vec::new();
    }
    jsonl_files.sort_by(|a, b| b.1.cmp(&a.1));

    let now = now_epoch_secs();
    let mut results = Vec::new();
    let mut seen = HashSet::new();

    for (path, mtime) in jsonl_files.into_iter().take(limit * 2) {
        let age = (now - mtime).max(0);
        let parsed = parse_jsonl_tail(&path, age);
        let file_stem = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("session")
            .to_string();
        let project_key = parsed.cwd.clone().unwrap_or_else(|| file_stem.clone());

        if !parsed.state.is_active_or_waiting() && !results.is_empty() {
            if seen.contains(&project_key) || age > 86_400 {
                continue;
            }
        }
        seen.insert(project_key);

        let usage = UsageMetrics {
            session_total_tokens: parsed.total_tokens,
            context_tokens: parsed.context_tokens,
            context_window: parsed.context_window,
            is_context_window_estimated: parsed.context_window.is_some(),
            input_tokens: parsed.input_tokens,
            cache_read_tokens: parsed.cache_read_tokens,
            output_tokens: parsed.output_tokens,
            ..Default::default()
        };

        let project_name = parsed
            .cwd
            .as_deref()
            .map(|c| project_display_name(Some(c), watched_folders))
            .unwrap_or(file_stem);
        let git_branch = parsed
            .cwd
            .as_deref()
            .and_then(detect_git_branch)
            .or(parsed.git_branch);
        let file_name = path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("session.jsonl");

        results.push(AgentSnapshot {
            kind: AgentKind::Custom,
            session_id: format!("{label}:{file_name}"),
            agent_label: label.to_string(),
            state: parsed.state,
            project_name,
            project_path: parsed.cwd,
            git_branch,
            model_name: parsed.model.unwrap_or_else(|| "—".to_string()),
            reasoning_effort: None,
            session_title: None,
            usage,
            last_updated_epoch: Some(mtime),
            active_since_epoch: None,
            resolved_source_path: Some(root.to_string_lossy().into_owned()),
            status_message: None,
            interaction_reason: parsed.interaction_reason,
            task_steps: parsed.task_steps,
            recent_activity: Vec::new(),
        });

        if results.len() >= limit {
            break;
        }
    }

    results
}

fn collect_jsonl_files(
    dir: &Path,
    depth: usize,
    scanned: &mut usize,
    out: &mut Vec<(PathBuf, i64)>,
) {
    if depth > 4 || *scanned > 300 {
        return;
    }
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        if *scanned > 300 {
            break;
        }
        *scanned += 1;
        let path = entry.path();
        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
        if name.starts_with('.') || name == "subagents" {
            continue;
        }
        if path.is_dir() {
            collect_jsonl_files(&path, depth + 1, scanned, out);
        } else if path
            .extension()
            .and_then(|e| e.to_str())
            .is_some_and(|e| e.eq_ignore_ascii_case("jsonl"))
        {
            if let Some(mtime) = file_mtime_epoch(&path) {
                out.push((path, mtime));
            }
        }
    }
}

pub struct JsonlTailInfo {
    pub cwd: Option<String>,
    pub git_branch: Option<String>,
    pub model: Option<String>,
    pub total_tokens: Option<u64>,
    pub input_tokens: Option<u64>,
    pub cache_read_tokens: Option<u64>,
    pub output_tokens: Option<u64>,
    pub context_tokens: Option<u64>,
    pub context_window: Option<u64>,
    pub state: AgentRunState,
    pub interaction_reason: Option<String>,
    pub task_steps: Vec<TaskStep>,
}

fn parse_jsonl_tail(path: &Path, age: i64) -> JsonlTailInfo {
    let fallback = || JsonlTailInfo {
        cwd: None,
        git_branch: None,
        model: None,
        total_tokens: None,
        input_tokens: None,
        cache_read_tokens: None,
        output_tokens: None,
        context_tokens: None,
        context_window: None,
        state: if age < 20 {
            AgentRunState::Running
        } else {
            AgentRunState::Idle
        },
        interaction_reason: None,
        task_steps: Vec::new(),
    };

    let Ok(mut file) = File::open(path) else {
        return fallback();
    };
    let Ok(file_size) = file.seek(SeekFrom::End(0)) else {
        return fallback();
    };
    let offset = file_size.saturating_sub(196_608);
    if file.seek(SeekFrom::Start(offset)).is_err() {
        return fallback();
    }
    let mut buf = Vec::new();
    if file.read_to_end(&mut buf).is_err() {
        return fallback();
    }
    let text = String::from_utf8_lossy(&buf);
    parse_claude_jsonl(&text, offset > 0, age)
}

pub fn parse_claude_jsonl(text: &str, dropped_partial_first: bool, age: i64) -> JsonlTailInfo {
    let mut lines = text.lines().filter(|l| !l.trim().is_empty());
    if dropped_partial_first {
        let _ = lines.next();
    }

    let mut cwd = None;
    let mut git_branch = None;
    let mut model: Option<String> = None;
    let mut total_tokens = None;
    let mut sum_input = 0_u64;
    let mut sum_cache = 0_u64;
    let mut sum_output = 0_u64;
    let mut last_context = 0_u64;
    let mut saw_claude_usage = false;
    let mut pending_tools: HashMap<String, String> = HashMap::new();
    let mut pending_order: Vec<String> = Vec::new();
    let mut has_open_assistant_turn = false;
    let mut has_open_user_prompt = false;
    let mut task_steps: Vec<TaskStep> = Vec::new();

    for line in lines {
        let Ok(json) = serde_json::from_str::<Value>(line) else {
            continue;
        };

        if let Some(c) = json
            .get("cwd")
            .or_else(|| json.get("project"))
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
        {
            cwd = Some(c.to_string());
        }
        if let Some(gb) = json
            .get("gitBranch")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
        {
            git_branch = Some(gb.to_string());
        }
        if let Some(m) = json
            .get("model")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty() && *s != "<synthetic>")
        {
            model = Some(m.to_string());
        }
        if let Some(tot) = json
            .get("usage")
            .and_then(|u| u.get("total_tokens"))
            .and_then(Value::as_u64)
        {
            total_tokens = Some(tot);
        }

        let entry_type = json.get("type").and_then(Value::as_str);
        if let Some(msg) = json.get("message") {
            if let Some(m) = msg
                .get("model")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty() && *s != "<synthetic>")
            {
                model = Some(m.to_string());
            }
            if let Some(usage) = msg.get("usage") {
                let inp = usage.get("input_tokens").and_then(Value::as_u64).unwrap_or(0);
                let cache_read = usage
                    .get("cache_read_input_tokens")
                    .and_then(Value::as_u64)
                    .unwrap_or(0);
                let cache_create = usage
                    .get("cache_creation_input_tokens")
                    .and_then(Value::as_u64)
                    .unwrap_or(0);
                let out = usage.get("output_tokens").and_then(Value::as_u64).unwrap_or(0);
                let ctx_now = inp + cache_read + cache_create + out;
                if ctx_now > 0 {
                    saw_claude_usage = true;
                    sum_input += inp + cache_create;
                    sum_cache += cache_read;
                    sum_output += out;
                    last_context = ctx_now;
                }
            }

            let stop_reason = msg.get("stop_reason").and_then(Value::as_str);
            if entry_type == Some("assistant") {
                has_open_assistant_turn = stop_reason.is_none() || stop_reason == Some("tool_use");
                if stop_reason == Some("end_turn") {
                    has_open_user_prompt = false;
                }
            } else if entry_type == Some("user") {
                has_open_assistant_turn = false;
                has_open_user_prompt = true;
            }

            if let Some(content) = msg.get("content").and_then(Value::as_array) {
                let mut saw_user_text = false;
                for block in content {
                    let btype = block.get("type").and_then(Value::as_str);
                    if btype == Some("tool_use") {
                        if let (Some(id), Some(name)) = (
                            block.get("id").and_then(Value::as_str),
                            block.get("name").and_then(Value::as_str),
                        ) {
                            if name == "TodoWrite" {
                                if let Some(todos) = block
                                    .get("input")
                                    .and_then(|i| i.get("todos"))
                                    .and_then(Value::as_array)
                                {
                                    let parsed: Vec<TaskStep> = todos
                                        .iter()
                                        .filter_map(|t| {
                                            let title =
                                                t.get("content").and_then(Value::as_str)?.trim();
                                            if title.is_empty() {
                                                return None;
                                            }
                                            let status = match t
                                                .get("status")
                                                .and_then(Value::as_str)
                                                .unwrap_or("")
                                            {
                                                "completed" | "done" => TaskStepStatus::Done,
                                                "in_progress" => TaskStepStatus::InProgress,
                                                _ => TaskStepStatus::Pending,
                                            };
                                            Some(TaskStep {
                                                title: title.to_string(),
                                                status,
                                            })
                                        })
                                        .collect();
                                    if !parsed.is_empty() {
                                        task_steps = parsed;
                                    }
                                }
                            }
                            pending_tools.insert(id.to_string(), name.to_string());
                            pending_order.push(id.to_string());
                        }
                    } else if btype == Some("tool_result") {
                        if let Some(tid) = block.get("tool_use_id").and_then(Value::as_str) {
                            pending_tools.remove(tid);
                        }
                    } else if entry_type == Some("user") && btype == Some("text") {
                        saw_user_text = true;
                    }
                }
                if saw_user_text {
                    pending_tools.clear();
                    pending_order.clear();
                    task_steps.clear();
                }
            }

            if stop_reason == Some("end_turn") {
                pending_tools.clear();
                pending_order.clear();
                has_open_assistant_turn = false;
                has_open_user_prompt = false;
            }
        }
    }

    let unresolved_tool = pending_order
        .iter()
        .rev()
        .find_map(|id| pending_tools.get(id))
        .map(String::as_str);

    let is_approval_gated_tool = |name: &str| {
        let lower = name.to_lowercase();
        if lower.contains("image")
            || lower.contains("generate")
            || lower.contains("search")
            || lower.contains("fetch")
            || matches!(name, "Agent" | "Task" | "Read" | "Glob" | "Grep" | "TodoWrite")
        {
            return false;
        }
        true
    };

    let (state, interaction_reason) = if unresolved_tool == Some("AskUserQuestion") && age < 86_400
    {
        (AgentRunState::NeedsInput, Some("Rückfrage".to_string()))
    } else if unresolved_tool.is_some_and(is_approval_gated_tool) && (10..7_200).contains(&age) {
        (AgentRunState::NeedsInput, Some("Freigabe nötig".to_string()))
    } else if (unresolved_tool.is_some() && age < 1_800)
        || ((has_open_assistant_turn || has_open_user_prompt) && age < 600)
        || age < 20
    {
        (AgentRunState::Running, None)
    } else {
        (AgentRunState::Idle, None)
    };

    let context_window = model.as_deref().and_then(|m| {
        let lower = m.to_lowercase();
        if lower.contains("claude") {
            if lower.contains("[1m]") {
                Some(1_000_000)
            } else {
                Some(200_000)
            }
        } else {
            None
        }
    });

    JsonlTailInfo {
        cwd,
        git_branch,
        model,
        total_tokens: if saw_claude_usage {
            Some(sum_input + sum_cache + sum_output)
        } else {
            total_tokens
        },
        input_tokens: saw_claude_usage.then_some(sum_input),
        cache_read_tokens: saw_claude_usage.then_some(sum_cache),
        output_tokens: saw_claude_usage.then_some(sum_output),
        context_tokens: saw_claude_usage.then_some(last_context),
        context_window,
        state,
        interaction_reason,
        task_steps,
    }
}

// ============================================================================
// Helpers
// ============================================================================

fn list_tables(conn: &Connection) -> HashSet<String> {
    let Ok(mut stmt) = conn.prepare("SELECT name FROM sqlite_master WHERE type='table'") else {
        return HashSet::new();
    };
    let Ok(rows) = stmt.query_map([], |r| r.get::<_, String>(0)) else {
        return HashSet::new();
    };
    rows.filter_map(Result::ok).collect()
}

fn list_columns(conn: &Connection, table: &str) -> HashSet<String> {
    let Ok(mut stmt) = conn.prepare(&format!("PRAGMA table_info({table})")) else {
        return HashSet::new();
    };
    let Ok(rows) = stmt.query_map([], |r| r.get::<_, String>(1)) else {
        return HashSet::new();
    };
    rows.filter_map(Result::ok).collect()
}

fn decode_epoch_ms_or_s(raw: Option<f64>) -> Option<i64> {
    let val = raw?;
    if val <= 0.0 {
        return None;
    }
    if val > 10_000_000_000.0 {
        Some((val / 1000.0) as i64)
    } else {
        Some(val as i64)
    }
}

fn file_mtime_epoch(path: &Path) -> Option<i64> {
    fs::metadata(path)
        .ok()
        .and_then(|m| m.modified().ok())
        .and_then(system_time_to_epoch)
}

fn newest_mtime_shallow(root: &Path) -> Option<i64> {
    let mut latest = file_mtime_epoch(root);
    if let Ok(entries) = fs::read_dir(root) {
        for entry in entries.flatten().take(40) {
            if let Some(ts) = file_mtime_epoch(&entry.path()) {
                latest = Some(latest.map_or(ts, |cur| cur.max(ts)));
            }
        }
    }
    latest
}

fn non_empty(val: Option<String>) -> Option<String> {
    val.map(|s| s.trim().to_string()).filter(|s| !s.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_dir(tag: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("agentorbit_{tag}_{nanos}"));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn detects_opencode_v2_question_tool_as_needs_input() {
        let dir = temp_dir("opencode_v2");
        let db = dir.join("opencode.db");
        let conn = Connection::open(&db).unwrap();
        conn.execute(
            "CREATE TABLE session_v2 (id TEXT, directory TEXT, title TEXT, model TEXT, cost REAL, tokens_input INTEGER, tokens_output INTEGER, tokens_cache_read INTEGER, time_updated REAL, time_busy REAL, time_idle REAL, time_suspended REAL, time_archived REAL)",
            [],
        )
        .unwrap();
        conn.execute(
            "CREATE TABLE session_message (session_id TEXT, seq INTEGER, type TEXT, data TEXT)",
            [],
        )
        .unwrap();
        let now_ms = (now_epoch_secs() as f64) * 1000.0;
        conn.execute(
            "INSERT INTO session_v2 VALUES ('s1', '/tmp/demo', 'Fix bug', '{\"id\":\"claude-sonnet-4\",\"variant\":\"high\"}', 0.15, 5000, 1200, 2000, ?1, ?1, ?2, NULL, NULL)",
            rusqlite::params![now_ms, now_ms - 5000.0],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO session_message VALUES ('s1', 1, 'assistant', '{\"content\":[{\"type\":\"tool\",\"name\":\"question\"}]}')",
            [],
        )
        .unwrap();
        drop(conn);

        let cfg = CustomAgentConfig {
            name: "OpenCode".to_string(),
            path: dir.to_string_lossy().into_owned(),
            is_enabled: true,
        };
        let sessions = read_custom_sessions(&cfg, &[], 4);
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].state, AgentRunState::NeedsInput);
        assert_eq!(sessions[0].model_name, "claude-sonnet-4");
        assert_eq!(sessions[0].reasoning_effort.as_deref(), Some("high"));
        assert_eq!(sessions[0].usage.recorded_cost_usd, Some(0.15));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn detects_bionic_elicitation_request_as_needs_input() {
        let dir = temp_dir("bionic");
        let proj = dir.join("projects").join("p1");
        let internal = proj.join(".internal");
        fs::create_dir_all(&internal).unwrap();
        fs::write(proj.join("project.json"), r#"{"name":"SampleBionic"}"#).unwrap();

        let db = internal.join("ng-sessions.sqlite");
        let conn = Connection::open(&db).unwrap();
        conn.execute(
            "CREATE TABLE sessions (session_id TEXT, parent_session_id TEXT, session_name TEXT, committed_head_entry_id TEXT, session_json TEXT, updated_timestamp REAL)",
            [],
        )
        .unwrap();
        conn.execute(
            "CREATE TABLE chat_entries (id TEXT, previous_id TEXT, entry_json TEXT)",
            [],
        )
        .unwrap();
        let now_ms = (now_epoch_secs() as f64) * 1000.0;
        let session_json = r#"{"modelSpecifier":{"indexedModelIdentifier":"org/qwen3-coder"},"inferenceConfig":{"reasoningLevel":"medium"},"contextEstimation":{"total":14000}}"#;
        conn.execute(
            "INSERT INTO sessions VALUES ('bs1', NULL, 'Refactor', 'e1', ?1, ?2)",
            rusqlite::params![session_json, now_ms],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO chat_entries VALUES ('e1', NULL, '{\"type\":\"message\"}')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO chat_entries VALUES ('e2', 'e1', '{\"type\":\"elicitationRequest\"}')",
            [],
        )
        .unwrap();
        drop(conn);

        let cfg = CustomAgentConfig {
            name: "Bionic".to_string(),
            path: dir.to_string_lossy().into_owned(),
            is_enabled: true,
        };
        let sessions = read_custom_sessions(&cfg, &[], 4);
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].state, AgentRunState::NeedsInput);
        assert_eq!(sessions[0].project_name, "SampleBionic");
        assert_eq!(sessions[0].model_name, "qwen3-coder");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn detects_claude_jsonl_ask_user_question_and_usage() {
        let jsonl = r#"
{"type":"assistant","cwd":"/tmp/app","gitBranch":"feat/v2","message":{"model":"claude-sonnet-4-6","stop_reason":"tool_use","usage":{"input_tokens":1000,"cache_read_input_tokens":4000,"cache_creation_input_tokens":500,"output_tokens":300},"content":[{"type":"tool_use","id":"tu_1","name":"AskUserQuestion"}]}}
"#;
        let info = parse_claude_jsonl(jsonl, false, 30);
        assert_eq!(info.state, AgentRunState::NeedsInput);
        assert_eq!(info.interaction_reason.as_deref(), Some("Rückfrage"));
        assert_eq!(info.model.as_deref(), Some("claude-sonnet-4-6"));
        assert_eq!(info.context_window, Some(200_000));
        assert_eq!(info.total_tokens, Some(5800));
    }
}
