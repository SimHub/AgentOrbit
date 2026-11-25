use crate::models::{
    now_epoch_secs, system_time_to_epoch, AgentKind, AgentRunState, AgentSnapshot, TaskStep,
    TaskStepStatus, UsageMetrics, WatchedFolderStatus,
};
use crate::paths::{detect_git_branch, expand_tilde, project_display_name, resolve_path};
use crate::sqlite::open_readonly;
use chrono::{DateTime, NaiveDateTime};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

pub fn read_antigravity_sessions(
    raw_path: &str,
    watched_folders: &[WatchedFolderStatus],
    model_aliases: &HashMap<String, String>,
    context_window_override: i64,
    limit: usize,
) -> Vec<AgentSnapshot> {
    if raw_path.trim().is_empty() {
        return vec![AgentSnapshot::placeholder(
            AgentKind::Antigravity,
            AgentRunState::Unavailable,
            Some("No .antigravity path configured".to_string()),
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
            AgentKind::Antigravity,
            state,
            Some(msg),
        )];
    }

    let state_pbtxt = resolved_root.join("antigravity_state.pbtxt");
    let raw_state_model = parse_selected_model(&state_pbtxt);
    let state_mtime = file_mtime_epoch(&state_pbtxt);

    let db_path = resolved_root.join("conversation_summaries.db");
    let fetch_count = (limit * 2).max(12) as i64;
    let rows = read_summary_rows(&db_path, fetch_count);

    let first_conv_id = rows.first().and_then(|r| r.conversation_id.as_deref());
    let discovered_models = discover_model_labels(&resolved_root, first_conv_id);

    if rows.is_empty() {
        let fallback_display = resolve_model_display(
            raw_state_model.as_deref(),
            model_aliases,
            &discovered_models,
        );
        let (model_name, effort) = split_model_and_effort(&fallback_display);
        return vec![AgentSnapshot {
            kind: AgentKind::Antigravity,
            session_id: AgentKind::Antigravity.as_str().to_string(),
            agent_label: AgentKind::Antigravity.as_str().to_string(),
            state: AgentRunState::Idle,
            project_name: "—".to_string(),
            project_path: None,
            git_branch: None,
            model_name,
            reasoning_effort: effort,
            session_title: None,
            usage: UsageMetrics::default(),
            last_updated_epoch: None,
            active_since_epoch: None,
            resolved_source_path: Some(resolved_root.to_string_lossy().into_owned()),
            status_message: Some("No active conversation".to_string()),
            interaction_reason: None,
            task_steps: Vec::new(),
            recent_activity: Vec::new(),
        }];
    }

    let now = now_epoch_secs();
    let mut results = Vec::new();
    let mut seen_projects = HashSet::new();

    for (idx, row) in rows.into_iter().enumerate() {
        let conv_id = row.conversation_id;
        let session_id = conv_id.clone().unwrap_or_else(|| format!("agy-{idx}"));
        let workspace_path = parse_workspace_path(row.workspace_uris.as_deref());
        let status_raw = row.status.unwrap_or_default();
        let not_fully_idle = row.not_fully_idle.unwrap_or(0) != 0;
        let is_running = status_raw.contains("RUNNING") || not_fully_idle;
        let conv_details = conv_id
            .as_deref()
            .and_then(|id| active_conversation_details(&resolved_root, id));
        let is_waiting = status_raw.contains("WAITING")
            || (is_running
                && conv_details
                    .as_ref()
                    .and_then(|d| d.latest_step_status)
                    == Some(9));

        let (state, interaction_reason) = if is_waiting {
            (AgentRunState::NeedsInput, Some("Freigabe / Eingabe".to_string()))
        } else if is_running {
            (AgentRunState::Running, None)
        } else {
            (AgentRunState::Idle, None)
        };

        let modified_epoch = row
            .last_modified_time
            .as_deref()
            .and_then(parse_sqlite_date);
        let age = modified_epoch.map(|ts| (now - ts).max(0)).unwrap_or(i64::MAX);

        let project_key = workspace_path.clone().unwrap_or_else(|| session_id.clone());
        if !state.is_active_or_waiting() && !results.is_empty() {
            if seen_projects.contains(&project_key) || age > 86_400 {
                continue;
            }
        }
        seen_projects.insert(project_key);

        let chosen_raw_model = if let Some(ref details) = conv_details {
            if let Some(ref enum_id) = details.enum_id {
                let state_is_newer = match (state_mtime, details.mtime_epoch) {
                    (Some(s), Some(c)) => s - c > 2,
                    _ => false,
                };
                if state_is_newer {
                    raw_state_model.as_deref().or(Some(enum_id.as_str()))
                } else {
                    Some(enum_id.as_str())
                }
            } else {
                raw_state_model.as_deref()
            }
        } else {
            raw_state_model.as_deref()
        };

        let resolved_display =
            resolve_model_display(chosen_raw_model, model_aliases, &discovered_models);
        let (model_name, effort) = split_model_and_effort(&resolved_display);

        let mut usage = UsageMetrics {
            step_count: row.step_count.and_then(|v| u64::try_from(v).ok()),
            ..Default::default()
        };
        let mut transcript_mtime = None;
        let mut task_steps = Vec::new();
        let mut recent_activity = Vec::new();
        let mut is_background_tool = false;
        let mut turn_started_epoch = None;

        if let Some(ref id) = conv_id {
            let transcript_path = resolved_root
                .join("brain")
                .join(id)
                .join(".system_generated")
                .join("logs")
                .join("transcript.jsonl");
            if transcript_path.is_file() {
                if let Ok(text) = fs::read_to_string(&transcript_path) {
                    let tm = parse_transcript_jsonl(&text);
                    usage.input_tokens = tm.input_tokens;
                    usage.cache_read_tokens = tm.cache_read_tokens;
                    usage.output_tokens = tm.output_tokens;
                    usage.session_total_tokens = tm.total_tokens;
                    usage.context_tokens = tm.latest_context_tokens;
                    task_steps = tm.task_steps;
                    recent_activity = tm.recent_activity;
                    is_background_tool = tm.is_background_subagent_or_media;
                    turn_started_epoch = tm.turn_started_epoch;
                    if tm.latest_context_tokens.is_some() {
                        if let Some(window) =
                            estimated_context_window(&model_name, context_window_override)
                        {
                            usage.context_window = Some(window);
                            usage.is_context_window_estimated = true;
                        }
                    }
                }
                transcript_mtime = file_mtime_epoch(&transcript_path);
            }
        }

        // Do not flag background image generation or subagent execution as waiting for user approval.
        let (state, interaction_reason) = if state == AgentRunState::NeedsInput && is_background_tool
        {
            (AgentRunState::Running, None)
        } else {
            (state, interaction_reason)
        };

        let last_updated = [modified_epoch, transcript_mtime]
            .into_iter()
            .flatten()
            .max();
        let active_since_epoch = if state.is_active_or_waiting() {
            turn_started_epoch.or(last_updated)
        } else {
            None
        };
        let project_name = project_display_name(workspace_path.as_deref(), watched_folders);
        let git_branch = workspace_path.as_deref().and_then(detect_git_branch);

        results.push(AgentSnapshot {
            kind: AgentKind::Antigravity,
            session_id,
            agent_label: AgentKind::Antigravity.as_str().to_string(),
            state,
            project_name,
            project_path: workspace_path,
            git_branch,
            model_name,
            reasoning_effort: effort,
            session_title: row.title.filter(|t| !t.trim().is_empty()),
            usage,
            last_updated_epoch: last_updated,
            active_since_epoch,
            resolved_source_path: Some(resolved_root.to_string_lossy().into_owned()),
            status_message: None,
            interaction_reason,
            task_steps,
            recent_activity,
        });

        if results.len() >= limit {
            break;
        }
    }

    results
}

pub fn parse_selected_model(pbtxt_path: &Path) -> Option<String> {
    let text = fs::read_to_string(pbtxt_path).ok()?;
    for line in text.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("last_selected_agent_model:") {
            let val = rest.trim().trim_matches('"');
            if !val.is_empty() {
                return Some(val.to_string());
            }
        }
    }
    None
}

pub fn resolve_model_display(
    raw_id: Option<&str>,
    aliases: &HashMap<String, String>,
    discovered: &HashMap<String, String>,
) -> String {
    let Some(raw) = raw_id.filter(|s| !s.is_empty()) else {
        return "—".to_string();
    };
    if let Some(alias) = aliases.get(raw).filter(|s| !s.is_empty()) {
        return alias.clone();
    }
    let cleaned = raw.replace("MODEL_PLACEHOLDER_", "");
    if let Some(alias) = aliases.get(&cleaned).filter(|s| !s.is_empty()) {
        return alias.clone();
    }
    if let Some(label) = discovered.get(raw).filter(|s| !s.is_empty()) {
        return label.clone();
    }
    if let Some(label) = discovered.get(&cleaned).filter(|s| !s.is_empty()) {
        return label.clone();
    }
    cleaned
}

pub fn split_model_and_effort(display: &str) -> (String, Option<String>) {
    let trimmed = display.trim();
    if let Some(without_end) = trimmed.strip_suffix(')') {
        if let Some(open_idx) = without_end.rfind('(') {
            if open_idx > 0 {
                let base = without_end[..open_idx].trim();
                let effort = without_end[open_idx + 1..].trim();
                if !base.is_empty()
                    && !effort.is_empty()
                    && effort.len() <= 18
                    && !effort.contains(' ')
                {
                    return (base.to_string(), Some(effort.to_string()));
                }
            }
        }
    }
    (trimmed.to_string(), None)
}

pub fn estimated_context_window(model_name: &str, override_val: i64) -> Option<u64> {
    if override_val < 0 {
        return None;
    }
    if override_val > 0 {
        return Some(override_val as u64);
    }
    if model_name.to_lowercase().contains("claude") {
        Some(200_000)
    } else {
        Some(1_000_000)
    }
}

pub fn extract_gen_metadata_model(data: &[u8]) -> Option<(String, String)> {
    let tail = if data.len() > 512 {
        &data[data.len() - 512..]
    } else {
        data
    };
    if tail.is_empty() {
        return None;
    }

    // Extract `model_enum`: "model_enum" + 0x12 + <len> + <MODEL_...>
    let mut enum_id = None;
    let marker = b"model_enum";
    if let Some(pos) = find_subslice(tail, marker) {
        let after_key = pos + marker.len();
        if after_key + 2 < tail.len() && tail[after_key] == 0x12 {
            let len = tail[after_key + 1] as usize;
            let start = after_key + 2;
            let end = start + len;
            if len > 0 && end <= tail.len() {
                if let Ok(s) = std::str::from_utf8(&tail[start..end]) {
                    if s.starts_with("MODEL_") {
                        enum_id = Some(s.to_string());
                    }
                }
            }
        }
    }

    // Extract protobuf field 21: [0xAA, 0x01, <len>, <DisplayName>] at tail end
    let mut display_name = None;
    let tag = [0xAA_u8, 0x01_u8];
    let mut search_from = 0;
    while let Some(rel) = find_subslice(&tail[search_from..], &tag) {
        let len_idx = search_from + rel + tag.len();
        if len_idx < tail.len() {
            let len = tail[len_idx] as usize;
            let start = len_idx + 1;
            let end = start + len;
            if (3..=80).contains(&len) && end == tail.len() {
                if let Ok(s) = std::str::from_utf8(&tail[start..end]) {
                    if s.bytes().all(|b| b.is_ascii() && b != b'\n' && b != b'\r') {
                        display_name = Some(s.to_string());
                    }
                }
            }
        }
        search_from = len_idx;
    }

    Some((enum_id?, display_name?))
}

pub fn parse_workspace_path(raw_json: Option<&str>) -> Option<String> {
    let uris: Vec<String> = serde_json::from_str(raw_json?).ok()?;
    let first = uris.first()?;
    if let Some(rest) = first.strip_prefix("file://") {
        let decoded = percent_decode(rest);
        // Handle Windows file URIs like `file:///C:/Users/...` -> `C:/Users/...`
        let bytes = decoded.as_bytes();
        if bytes.len() >= 3 && bytes[0] == b'/' && bytes[1].is_ascii_alphabetic() && bytes[2] == b':'
        {
            return Some(decoded[1..].to_string());
        }
        return Some(decoded);
    }
    Some(first.clone())
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct TranscriptUsage {
    pub input_tokens: Option<u64>,
    pub cache_read_tokens: Option<u64>,
    pub output_tokens: Option<u64>,
    pub total_tokens: Option<u64>,
    pub latest_context_tokens: Option<u64>,
    pub task_steps: Vec<TaskStep>,
    pub recent_activity: Vec<String>,
    pub is_background_subagent_or_media: bool,
    pub turn_started_epoch: Option<i64>,
}

pub fn parse_transcript_jsonl(text: &str) -> TranscriptUsage {
    let mut sum_input = 0_u64;
    let mut sum_cache = 0_u64;
    let mut sum_output = 0_u64;
    let mut last_context = 0_u64;
    let mut saw_usage = false;
    let mut latest_steps: Vec<TaskStep> = Vec::new();
    let mut recent_activity: Vec<String> = Vec::new();
    let mut is_background_subagent_or_media = false;
    let mut turn_started_epoch: Option<i64> = None;

    for line in text.lines() {
        let is_new_user_turn =
            line.contains("\"USER_INPUT\"") || line.contains("\"USER_EXPLICIT\"");
        let has_tokens = line.contains("input_tokens") || line.contains("output_tokens");
        let has_tools = line.contains("tool_calls") || line.contains("update_steps");
        if !is_new_user_turn && !has_tokens && !has_tools {
            continue;
        }
        let Ok(obj) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if is_new_user_turn
            && (obj.get("type").and_then(Value::as_str) == Some("USER_INPUT")
                || obj.get("source").and_then(Value::as_str) == Some("USER_EXPLICIT"))
        {
            // New user task started: clear previous task's finished checklist & activity
            latest_steps.clear();
            recent_activity.clear();
            is_background_subagent_or_media = false;
            turn_started_epoch = obj
                .get("timestamp")
                .or_else(|| obj.get("created_at"))
                .and_then(Value::as_str)
                .and_then(|ts| DateTime::parse_from_rfc3339(ts).ok().map(|dt| dt.timestamp()))
                .or_else(|| obj.get("timestamp").and_then(Value::as_i64));
            continue;
        }
        if has_tools {
            if let Some(parsed) = extract_steps_recursive(&obj) {
                if !parsed.is_empty() {
                    latest_steps = parsed;
                }
            }
            if let Some(calls) = obj.get("tool_calls").and_then(Value::as_array) {
                is_background_subagent_or_media = false;
                for call in calls {
                    let name = call.get("name").and_then(Value::as_str).unwrap_or("");
                    let lower = name.to_lowercase();
                    if lower.contains("image")
                        || lower.contains("invoke_subagent")
                        || lower.contains("generate_")
                    {
                        is_background_subagent_or_media = true;
                    }
                    if name == "update_focus" {
                        if let Some(focus) = call
                            .get("args")
                            .and_then(|a| a.get("focus"))
                            .and_then(Value::as_str)
                            .map(str::trim)
                            .filter(|s| !s.is_empty())
                        {
                            let label = focus.to_string();
                            if recent_activity.last().map(String::as_str) != Some(label.as_str()) {
                                recent_activity.push(label);
                                if recent_activity.len() > 4 {
                                    recent_activity.remove(0);
                                }
                            }
                        }
                    } else if name == "run_command" {
                        if let Some(summary) = call
                            .get("args")
                            .and_then(|a| a.get("toolSummary"))
                            .and_then(Value::as_str)
                            .map(str::trim)
                            .filter(|s| !s.is_empty())
                        {
                            let label = format!("$ {summary}");
                            if recent_activity.last().map(String::as_str) != Some(label.as_str()) {
                                recent_activity.push(label);
                                if recent_activity.len() > 4 {
                                    recent_activity.remove(0);
                                }
                            }
                        }
                    } else if matches!(name, "edit_file" | "write_file") {
                        if let Some(path) = call
                            .get("args")
                            .and_then(|a| a.get("Path"))
                            .and_then(Value::as_str)
                        {
                            let file = Path::new(path)
                                .file_name()
                                .and_then(|n| n.to_str())
                                .unwrap_or(path);
                            let label = if name == "write_file" {
                                format!("Erstellt {file}")
                            } else {
                                format!("Bearbeitet {file}")
                            };
                            if recent_activity.last().map(String::as_str) != Some(label.as_str()) {
                                recent_activity.push(label);
                                if recent_activity.len() > 4 {
                                    recent_activity.remove(0);
                                }
                            }
                        }
                    }
                }
            }
        }
        if has_tokens {
            let inp = obj.get("input_tokens").and_then(Value::as_u64).unwrap_or(0);
            let cache = obj
                .get("cache_read_tokens")
                .and_then(Value::as_u64)
                .unwrap_or(0);
            let out = obj.get("output_tokens").and_then(Value::as_u64).unwrap_or(0);
            if inp > 0 || cache > 0 || out > 0 {
                saw_usage = true;
                sum_input += inp;
                sum_cache += cache;
                sum_output += out;
                last_context = inp + cache + out;
            }
        }
    }

    TranscriptUsage {
        input_tokens: saw_usage.then_some(sum_input),
        cache_read_tokens: saw_usage.then_some(sum_cache),
        output_tokens: saw_usage.then_some(sum_output),
        total_tokens: saw_usage.then_some(sum_input + sum_cache + sum_output),
        latest_context_tokens: saw_usage.then_some(last_context),
        task_steps: latest_steps,
        recent_activity,
        is_background_subagent_or_media,
        turn_started_epoch,
    }
}

fn extract_steps_recursive(val: &Value) -> Option<Vec<TaskStep>> {
    match val {
        Value::Object(map) => {
            if let Some(steps_val) = map.get("steps") {
                if let Some(parsed) = parse_steps_value(steps_val) {
                    return Some(parsed);
                }
            }
            for child in map.values() {
                if let Some(found) = extract_steps_recursive(child) {
                    return Some(found);
                }
            }
            None
        }
        Value::Array(arr) => {
            for item in arr {
                if let Some(found) = extract_steps_recursive(item) {
                    return Some(found);
                }
            }
            None
        }
        Value::String(s) if s.contains("\"steps\"") => {
            let nested = serde_json::from_str::<Value>(s).ok()?;
            extract_steps_recursive(&nested)
        }
        _ => None,
    }
}

fn parse_steps_value(val: &Value) -> Option<Vec<TaskStep>> {
    let owned;
    let arr = match val {
        Value::Array(a) => a,
        Value::String(s) => {
            owned = serde_json::from_str::<Value>(s).ok()?;
            owned.as_array()?
        }
        _ => return None,
    };
    let parsed: Vec<TaskStep> = arr
        .iter()
        .filter_map(|item| {
            let title = item.get("title").and_then(Value::as_str)?.trim();
            if title.is_empty() {
                return None;
            }
            let status = match item.get("status").and_then(Value::as_str).unwrap_or("") {
                "done" | "completed" => TaskStepStatus::Done,
                "in_progress" => TaskStepStatus::InProgress,
                "skipped" => TaskStepStatus::Skipped,
                "failed" => TaskStepStatus::Failed,
                _ => TaskStepStatus::Pending,
            };
            Some(TaskStep {
                title: title.to_string(),
                status,
            })
        })
        .collect();
    (!parsed.is_empty()).then_some(parsed)
}

struct SummaryRow {
    conversation_id: Option<String>,
    title: Option<String>,
    workspace_uris: Option<String>,
    status: Option<String>,
    step_count: Option<i64>,
    not_fully_idle: Option<i64>,
    last_modified_time: Option<String>,
}

struct ActiveConvDetails {
    enum_id: Option<String>,
    mtime_epoch: Option<i64>,
    latest_step_status: Option<i64>,
}

fn read_summary_rows(db_path: &Path, limit: i64) -> Vec<SummaryRow> {
    let Some(conn) = open_readonly(db_path) else {
        return Vec::new();
    };
    let sql = "SELECT conversation_id, title, workspace_uris, status, step_count, not_fully_idle, last_modified_time \
               FROM conversation_summaries WHERE killed = 0 \
               ORDER BY (CASE WHEN status LIKE '%RUNNING%' OR status LIKE '%WAITING%' OR not_fully_idle != 0 THEN 0 ELSE 1 END), \
               last_modified_time DESC LIMIT ?1";
    let Ok(mut stmt) = conn.prepare(sql) else {
        return Vec::new();
    };
    let Ok(iter) = stmt.query_map([limit], |row| {
        Ok(SummaryRow {
            conversation_id: row.get(0)?,
            title: row.get(1)?,
            workspace_uris: row.get(2)?,
            status: row.get(3)?,
            step_count: row.get(4)?,
            not_fully_idle: row.get(5)?,
            last_modified_time: row.get(6)?,
        })
    }) else {
        return Vec::new();
    };
    iter.filter_map(Result::ok).collect()
}

fn discover_model_labels(
    resolved_root: &Path,
    preferred_conv_id: Option<&str>,
) -> HashMap<String, String> {
    let conv_dir = resolved_root.join("conversations");
    if !conv_dir.is_dir() {
        return HashMap::new();
    }

    let mut db_paths: Vec<PathBuf> = Vec::new();
    if let Some(id) = preferred_conv_id.filter(|s| !s.is_empty()) {
        let p = conv_dir.join(format!("{id}.db"));
        if p.is_file() {
            db_paths.push(p);
        }
    }

    if let Ok(entries) = fs::read_dir(&conv_dir) {
        let mut candidates: Vec<(i64, PathBuf)> = entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("db"))
            .map(|p| (file_mtime_epoch(&p).unwrap_or(0), p))
            .collect();
        candidates.sort_by(|a, b| b.0.cmp(&a.0));
        for (_, p) in candidates.into_iter().take(30) {
            if !db_paths.contains(&p) {
                db_paths.push(p);
            }
        }
    }

    let mut mapping = HashMap::new();
    for db_path in db_paths {
        let Some(conn) = open_readonly(&db_path) else {
            continue;
        };
        let Ok(mut stmt) = conn.prepare("SELECT data FROM gen_metadata ORDER BY idx DESC LIMIT 3")
        else {
            continue;
        };
        let Ok(rows) = stmt.query_map([], |row| row.get::<_, Vec<u8>>(0)) else {
            continue;
        };
        for blob in rows.filter_map(Result::ok) {
            if let Some((enum_id, display)) = extract_gen_metadata_model(&blob) {
                mapping.entry(enum_id).or_insert(display);
            }
        }
    }
    mapping
}

fn active_conversation_details(
    resolved_root: &Path,
    conv_id: &str,
) -> Option<ActiveConvDetails> {
    let conv_db = resolved_root
        .join("conversations")
        .join(format!("{conv_id}.db"));
    if !conv_db.is_file() {
        return None;
    }

    let wal_path = PathBuf::from(format!("{}-wal", conv_db.display()));
    let mtime_epoch = [file_mtime_epoch(&conv_db), file_mtime_epoch(&wal_path)]
        .into_iter()
        .flatten()
        .max();

    let conn = open_readonly(&conv_db)?;
    let mut found_enum = None;
    if let Ok(mut stmt) = conn.prepare("SELECT data FROM gen_metadata ORDER BY idx DESC LIMIT 5") {
        if let Ok(rows) = stmt.query_map([], |row| row.get::<_, Vec<u8>>(0)) {
            for blob in rows.filter_map(Result::ok) {
                if let Some((enum_id, _)) = extract_gen_metadata_model(&blob) {
                    found_enum = Some(enum_id);
                    break;
                }
            }
        }
    }

    let latest_step_status = conn
        .query_row("SELECT status FROM steps ORDER BY idx DESC LIMIT 1", [], |r| {
            r.get::<_, i64>(0)
        })
        .ok();

    if found_enum.is_none() && latest_step_status.is_none() {
        return None;
    }

    Some(ActiveConvDetails {
        enum_id: found_enum,
        mtime_epoch,
        latest_step_status,
    })
}

fn file_mtime_epoch(path: &Path) -> Option<i64> {
    fs::metadata(path)
        .ok()
        .and_then(|m| m.modified().ok())
        .and_then(system_time_to_epoch)
}

fn parse_sqlite_date(raw: &str) -> Option<i64> {
    let trimmed = raw.trim();
    if let Ok(dt) = DateTime::parse_from_rfc3339(trimmed) {
        return Some(dt.timestamp());
    }
    for fmt in [
        "%Y-%m-%d %H:%M:%S%.f%:z",
        "%Y-%m-%d %H:%M:%S%:z",
        "%Y-%m-%d %H:%M:%S%.f%#z",
        "%Y-%m-%d %H:%M:%S%#z",
    ] {
        if let Ok(dt) = DateTime::parse_from_str(trimmed, fmt) {
            return Some(dt.timestamp());
        }
    }
    for fmt in ["%Y-%m-%d %H:%M:%S%.f", "%Y-%m-%d %H:%M:%S"] {
        if let Ok(naive) = NaiveDateTime::parse_from_str(trimmed, fmt) {
            return Some(naive.and_utc().timestamp());
        }
    }
    None
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || needle.len() > haystack.len() {
        return None;
    }
    haystack.windows(needle.len()).position(|w| w == needle)
}

fn percent_decode(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(hex) = std::str::from_utf8(&bytes[i + 1..i + 3]) {
                if let Ok(val) = u8::from_str_radix(hex, 16) {
                    out.push(val);
                    i += 3;
                    continue;
                }
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn extracts_live_update_steps_from_transcript_jsonl() {
        let jsonl = r#"
{"type":"PLANNER_RESPONSE","tool_calls":[{"name":"update_steps","args":{"steps":"[{\"title\":\"Old done step\",\"status\":\"done\"}]"}}]}
{"source":"USER_EXPLICIT","type":"USER_INPUT"}
{"type":"PLANNER_RESPONSE","input_tokens":1200,"cache_read_tokens":300,"output_tokens":500,"tool_calls":[{"name":"update_steps","args":{"steps":"[{\"title\":\"Inspect code\",\"status\":\"done\"},{\"title\":\"Build UI\",\"status\":\"in_progress\"},{\"title\":\"Run tests\",\"status\":\"pending\"}]"}},{"name":"update_focus","args":{"focus":"Building UI layout"}}]}
"#;
        let parsed = parse_transcript_jsonl(jsonl);
        assert_eq!(parsed.task_steps.len(), 3);
        assert_eq!(parsed.task_steps[0].title, "Inspect code");
        assert_eq!(parsed.task_steps[1].status, TaskStepStatus::InProgress);
        assert_eq!(parsed.recent_activity, vec!["Building UI layout"]);
        assert_eq!(parsed.total_tokens, Some(2000));
    }

    #[test]
    fn splits_model_and_effort() {
        assert_eq!(
            split_model_and_effort("Gemini 4 Neon (Medium)"),
            ("Gemini 4 Neon".to_string(), Some("Medium".to_string()))
        );
        assert_eq!(
            split_model_and_effort("Claude Opus 4.6"),
            ("Claude Opus 4.6".to_string(), None)
        );
    }

    #[test]
    fn detects_antigravity_waiting_step_status_9_with_synthetic_db() {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("agentorbit_agy_e2e_{nanos}"));
        let conv_dir = root.join("conversations");
        let workspace = root.join("sample-app");
        fs::create_dir_all(&conv_dir).unwrap();
        fs::create_dir_all(&workspace).unwrap();

        fs::write(
            root.join("antigravity_state.pbtxt"),
            "last_selected_agent_model: \"MODEL_PLACEHOLDER_M99\"\n",
        )
        .unwrap();

        let sum_db = Connection::open(root.join("conversation_summaries.db")).unwrap();
        sum_db
            .execute(
                "CREATE TABLE conversation_summaries (conversation_id TEXT, title TEXT, workspace_uris TEXT, status TEXT, step_count INTEGER, not_fully_idle INTEGER, last_modified_time TEXT, killed INTEGER)",
                [],
            )
            .unwrap();
        let uri_path = workspace.to_string_lossy().replace('\\', "/");
        let uri = if uri_path.starts_with('/') {
            format!("file://{uri_path}")
        } else {
            format!("file:///{uri_path}")
        };
        let uris = serde_json::to_string(&vec![uri]).unwrap();
        sum_db
            .execute(
                "INSERT INTO conversation_summaries VALUES ('conv-1', 'Waiting Test', ?1, 'CASCADE_RUN_STATUS_RUNNING', 7, 1, '2026-11-25 10:00:00+00:00', 0)",
                [uris],
            )
            .unwrap();
        drop(sum_db);

        let conv_db = Connection::open(conv_dir.join("conv-1.db")).unwrap();
        conv_db
            .execute("CREATE TABLE steps (idx INTEGER, status INTEGER)", [])
            .unwrap();
        conv_db
            .execute("INSERT INTO steps VALUES (1, 9)", [])
            .unwrap();
        conv_db
            .execute("CREATE TABLE gen_metadata (idx INTEGER, data BLOB)", [])
            .unwrap();
        let mut blob = Vec::new();
        blob.extend_from_slice(b"model_enum");
        blob.push(0x12);
        let enum_bytes = b"MODEL_PLACEHOLDER_M99";
        blob.push(enum_bytes.len() as u8);
        blob.extend_from_slice(enum_bytes);
        blob.extend_from_slice(&[0xAA, 0x01]);
        let label = b"Gemini 4 Test (High)";
        blob.push(label.len() as u8);
        blob.extend_from_slice(label);
        conv_db
            .execute("INSERT INTO gen_metadata VALUES (1, ?1)", [blob])
            .unwrap();
        drop(conv_db);

        let sessions = read_antigravity_sessions(
            &root.to_string_lossy(),
            &[],
            &HashMap::new(),
            0,
            4,
        );
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].state, AgentRunState::NeedsInput);
        assert_eq!(sessions[0].project_name, "sample-app");
        assert_eq!(sessions[0].model_name, "Gemini 4 Test");
        assert_eq!(sessions[0].reasoning_effort.as_deref(), Some("High"));

        let _ = fs::remove_dir_all(&root);
    }
}
