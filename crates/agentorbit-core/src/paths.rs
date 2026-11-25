use crate::models::WatchedFolderStatus;
use std::fs;
use std::path::{Path, PathBuf};

/// Expands a leading `~` or `~/` using the platform home directory.
pub fn expand_tilde(raw: &str) -> PathBuf {
    let trimmed = raw.trim();
    if trimmed == "~" {
        return dirs::home_dir().unwrap_or_else(|| PathBuf::from(trimmed));
    }
    if let Some(rest) = trimmed.strip_prefix("~/").or_else(|| trimmed.strip_prefix("~\\")) {
        if let Some(home) = dirs::home_dir() {
            return home.join(rest);
        }
    }
    PathBuf::from(trimmed)
}

/// Resolves symlinks recursively when the path exists, otherwise returns the original path.
pub fn resolve_path(path: impl AsRef<Path>) -> PathBuf {
    let p = path.as_ref();
    fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf())
}

/// Computes a human-friendly project display name from a workspace path and watched folders.
pub fn project_display_name(
    project_path: Option<&str>,
    watched_folders: &[WatchedFolderStatus],
) -> String {
    let Some(raw) = project_path else {
        return "—".to_string();
    };
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return "—".to_string();
    }
    let resolved = resolve_path(trimmed);
    let resolved_str = resolved.to_string_lossy();
    for folder in watched_folders {
        if resolved_str == folder.resolved_path || trimmed == folder.configured_path {
            return folder.display_name.clone();
        }
    }
    resolved
        .file_name()
        .and_then(|n| n.to_str())
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| trimmed.to_string())
}

/// Detects the current Git branch for a project directory by inspecting `.git/HEAD`
/// (supporting both standard repos and worktrees/submodules via `.git` file pointers)
/// without spawning any external `git` subprocess.
pub fn detect_git_branch(project_dir: impl AsRef<Path>) -> Option<String> {
    let mut current = resolve_path(project_dir);
    if current.is_file() {
        current = current.parent()?.to_path_buf();
    }

    loop {
        let dot_git = current.join(".git");
        if dot_git.is_dir() {
            return parse_head_file(&dot_git.join("HEAD"));
        } else if dot_git.is_file() {
            if let Ok(content) = fs::read_to_string(&dot_git) {
                if let Some(gitdir_raw) = content.trim().strip_prefix("gitdir:") {
                    let gitdir_path = Path::new(gitdir_raw.trim());
                    let resolved_gitdir = if gitdir_path.is_absolute() {
                        gitdir_path.to_path_buf()
                    } else {
                        current.join(gitdir_path)
                    };
                    return parse_head_file(&resolved_gitdir.join("HEAD"));
                }
            }
        }

        if !current.pop() {
            return None;
        }
    }
}

fn parse_head_file(head_path: &Path) -> Option<String> {
    let content = fs::read_to_string(head_path).ok()?;
    let trimmed = content.trim();
    if let Some(branch) = trimmed.strip_prefix("ref: refs/heads/") {
        if !branch.is_empty() {
            return Some(branch.to_string());
        }
    }
    if trimmed.len() >= 7 {
        return Some(trimmed[..7].to_string());
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn unique_temp_dir(name: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("agentorbit_test_{name}_{nanos}"));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn detects_branch_from_dot_git_head() {
        let root = unique_temp_dir("git_branch");
        let git_dir = root.join(".git");
        let sub_dir = root.join("src").join("nested");
        fs::create_dir_all(&git_dir).unwrap();
        fs::create_dir_all(&sub_dir).unwrap();
        fs::write(git_dir.join("HEAD"), "ref: refs/heads/v2-rust-tauri\n").unwrap();

        assert_eq!(detect_git_branch(&root), Some("v2-rust-tauri".to_string()));
        assert_eq!(
            detect_git_branch(&sub_dir),
            Some("v2-rust-tauri".to_string())
        );

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn detects_detached_head_short_sha() {
        let root = unique_temp_dir("git_detached");
        let git_dir = root.join(".git");
        fs::create_dir_all(&git_dir).unwrap();
        fs::write(
            git_dir.join("HEAD"),
            "f1e5436abcdef1234567890abcdef1234567890a\n",
        )
        .unwrap();

        assert_eq!(detect_git_branch(&root), Some("f1e5436".to_string()));

        let _ = fs::remove_dir_all(&root);
    }
}
