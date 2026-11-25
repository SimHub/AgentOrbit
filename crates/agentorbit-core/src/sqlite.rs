use rusqlite::{Connection, OpenFlags};
use std::path::Path;
use std::time::Duration;

/// Opens a SQLite database strictly read-only so AgentOrbit never mutates
/// or creates lock contention with live AI coding agents.
pub fn open_readonly(path: &Path) -> Option<Connection> {
    if !path.is_file() {
        return None;
    }
    let flags = OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let conn = Connection::open_with_flags(path, flags).ok()?;
    let _ = conn.busy_timeout(Duration::from_millis(200));
    Some(conn)
}
