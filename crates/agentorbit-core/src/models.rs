use serde::{Deserialize, Serialize};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentKind {
    Codex,
    Antigravity,
    Custom,
}

impl AgentKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Codex => "Codex",
            Self::Antigravity => "Antigravity",
            Self::Custom => "Custom",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CustomAgentConfig {
    pub name: String,
    pub path: String,
    pub is_enabled: bool,
}

/// Canonical run state matching AgentOrbit v1 priority:
/// `NeedsInput` sorts ahead of `Running`, then `Idle`, `Offline`, `Unavailable`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentRunState {
    NeedsInput = 0,
    Running = 1,
    Idle = 2,
    Offline = 3,
    Unavailable = 4,
}

impl AgentRunState {
    pub fn is_live(&self) -> bool {
        *self == Self::Running
    }

    pub fn is_waiting_for_user(&self) -> bool {
        *self == Self::NeedsInput
    }

    pub fn is_active_or_waiting(&self) -> bool {
        matches!(self, Self::Running | Self::NeedsInput)
    }

    pub fn canonical_key(&self) -> &'static str {
        match self {
            Self::NeedsInput => "needs_input",
            Self::Running => "running",
            Self::Idle => "idle",
            Self::Offline => "offline",
            Self::Unavailable => "unavailable",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RateLimitWindow {
    pub used_percent: f64,
    pub window_minutes: u32,
    pub resets_at_epoch: Option<i64>,
}

impl RateLimitWindow {
    pub fn remaining_percent(&self) -> f64 {
        (100.0 - self.used_percent).clamp(0.0, 100.0)
    }

    pub fn remaining_fraction(&self) -> f64 {
        self.remaining_percent() / 100.0
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct UsageMetrics {
    pub session_total_tokens: Option<u64>,
    pub context_tokens: Option<u64>,
    pub context_window: Option<u64>,
    pub is_context_window_estimated: bool,
    pub input_tokens: Option<u64>,
    pub cache_read_tokens: Option<u64>,
    pub output_tokens: Option<u64>,
    pub step_count: Option<u64>,
    pub primary_limit: Option<RateLimitWindow>,
    pub secondary_limit: Option<RateLimitWindow>,
    pub plan_type: Option<String>,
    pub recorded_cost_usd: Option<f64>,
}

impl UsageMetrics {
    pub fn context_fill_ratio(&self) -> Option<f64> {
        let used = self.context_tokens?;
        let window = self.context_window?;
        if window == 0 {
            return None;
        }
        Some((used as f64 / window as f64).clamp(0.0, 1.0))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskStepStatus {
    Done,
    InProgress,
    Pending,
    Skipped,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskStep {
    pub title: String,
    pub status: TaskStepStatus,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AgentSnapshot {
    pub kind: AgentKind,
    pub session_id: String,
    pub agent_label: String,
    pub state: AgentRunState,
    pub project_name: String,
    pub project_path: Option<String>,
    pub git_branch: Option<String>,
    pub model_name: String,
    pub reasoning_effort: Option<String>,
    pub session_title: Option<String>,
    pub usage: UsageMetrics,
    pub last_updated_epoch: Option<i64>,
    pub active_since_epoch: Option<i64>,
    pub resolved_source_path: Option<String>,
    pub status_message: Option<String>,
    pub interaction_reason: Option<String>,
    #[serde(default)]
    pub task_steps: Vec<TaskStep>,
    #[serde(default)]
    pub recent_activity: Vec<String>,
}

impl AgentSnapshot {
    pub fn id(&self) -> String {
        format!("{}:{}", self.agent_label, self.session_id)
    }

    pub fn placeholder(kind: AgentKind, state: AgentRunState, message: Option<String>) -> Self {
        let label = kind.as_str().to_string();
        Self {
            kind,
            session_id: label.clone(),
            agent_label: label,
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
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CompletedSessionEvent {
    pub id: String,
    pub agent_label: String,
    pub project_name: String,
    pub model_name: String,
    pub duration_seconds: u64,
    pub completed_at_epoch: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NeedsInputEvent {
    pub id: String,
    pub agent_label: String,
    pub project_name: String,
    pub model_name: String,
    pub reason: String,
    pub detected_at_epoch: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WatchedFolderStatus {
    pub configured_path: String,
    pub resolved_path: String,
    pub display_name: String,
    pub is_online: bool,
    pub git_branch: Option<String>,
}

pub fn now_epoch_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

pub fn system_time_to_epoch(ts: SystemTime) -> Option<i64> {
    ts.duration_since(UNIX_EPOCH).ok().map(|d| d.as_secs() as i64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state_ordering_prioritizes_needs_input_then_running_then_idle() {
        let mut states = vec![
            AgentRunState::Unavailable,
            AgentRunState::Idle,
            AgentRunState::Running,
            AgentRunState::Offline,
            AgentRunState::NeedsInput,
        ];
        states.sort();
        assert_eq!(
            states,
            vec![
                AgentRunState::NeedsInput,
                AgentRunState::Running,
                AgentRunState::Idle,
                AgentRunState::Offline,
                AgentRunState::Unavailable,
            ]
        );
    }

    #[test]
    fn rate_limit_clamps_remaining_percent() {
        let window = RateLimitWindow {
            used_percent: 37.5,
            window_minutes: 300,
            resets_at_epoch: None,
        };
        assert!((window.remaining_percent() - 62.5).abs() < f64::EPSILON);
        assert!((window.remaining_fraction() - 0.625).abs() < f64::EPSILON);

        let over = RateLimitWindow {
            used_percent: 120.0,
            window_minutes: 300,
            resets_at_epoch: None,
        };
        assert_eq!(over.remaining_percent(), 0.0);
    }

    #[test]
    fn usage_metrics_context_fill_ratio() {
        let usage = UsageMetrics {
            context_tokens: Some(50_000),
            context_window: Some(200_000),
            ..Default::default()
        };
        assert_eq!(usage.context_fill_ratio(), Some(0.25));

        let zero_window = UsageMetrics {
            context_tokens: Some(10),
            context_window: Some(0),
            ..Default::default()
        };
        assert_eq!(zero_window.context_fill_ratio(), None);
    }
}
