//! Per-file cursor position persistence.
//!
//! `state_dir()/cursor_restore/<sha256(path)>.toml` holds one TOML file per edited
//! file. The filename derives from the path, so concurrent helix instances writing entries
//! for *different* files never touch the same file. The original path is stored inside as a
//! sanity check and for `cat cursor_restore/*` debugging. Writes go to a per-process temp
//! file and are moved into place with `rename`, so a torn write costs at most one entry.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

use serde::{Deserialize, Serialize};

use crate::workspace_trust::path_filename;

/// One saved cursor: 0-based line, char-based column.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct CursorPos {
    pub row: usize,
    pub col: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
pub struct CursorEntry {
    pub path: PathBuf,
    pub primary_index: usize,
    #[serde(rename = "cursor")]
    pub cursors: Vec<CursorPos>,
}

/// Saves fire on every buffer close; after the first failure (read-only state dir, full
/// disk, ...) stop trying rather than spam the log.
static WRITES_DISABLED: AtomicBool = AtomicBool::new(false);

fn cursor_restore_dir() -> PathBuf {
    crate::state_dir().join("cursor_restore")
}

/// Read the saved entry for `path`. Returns `None` if absent, unparsable, or inconsistent
/// with `path`: a corrupt entry costs one restore, never a crash.
pub fn read_entry(path: &Path) -> Option<CursorEntry> {
    read_entry_in(&cursor_restore_dir(), path)
}

/// Persist `entry`. Best effort: failures are logged and disable further writes for the
/// process; they never propagate to the caller.
pub fn write_entry(entry: &CursorEntry) {
    if WRITES_DISABLED.load(Ordering::Relaxed) {
        return;
    }
    if let Err(err) = write_entry_in(&cursor_restore_dir(), entry) {
        log::warn!("failed to save cursor position for {:?}: {err}", entry.path);
        WRITES_DISABLED.store(true, Ordering::Relaxed);
    }
}

fn entry_file(dir: &Path, path: &Path) -> PathBuf {
    dir.join(format!("{}.toml", path_filename(path)))
}

fn read_entry_in(dir: &Path, path: &Path) -> Option<CursorEntry> {
    let file = entry_file(dir, path);
    let contents = match fs::read_to_string(&file) {
        Ok(contents) => contents,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return None,
        Err(err) => {
            log::error!("cursor position file {file:?} unreadable: {err:?}");
            return None;
        }
    };

    let entry: CursorEntry = match toml::from_str(&contents) {
        Ok(entry) => entry,
        Err(err) => {
            log::error!("cursor position file {file:?} unparsable: {err:?}");
            return None;
        }
    };

    // A hash collision or a malformed entry must not reach the restore path.
    if entry.path != path || entry.cursors.is_empty() || entry.primary_index >= entry.cursors.len()
    {
        log::error!("cursor position file {file:?} inconsistent with {path:?}");
        return None;
    }

    Some(entry)
}

fn write_entry_in(dir: &Path, entry: &CursorEntry) -> std::io::Result<()> {
    fs::create_dir_all(dir)?;
    let contents = toml::to_string(entry).map_err(std::io::Error::other)?;

    let file = entry_file(dir, &entry.path);
    // The pid keeps concurrent helix instances from sharing a temp file.
    let tmp = dir.join(format!(
        "{}.{}.tmp",
        path_filename(&entry.path),
        std::process::id()
    ));
    fs::write(&tmp, contents)?;
    fs::rename(&tmp, &file)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(path: &str) -> CursorEntry {
        CursorEntry {
            path: PathBuf::from(path),
            primary_index: 0,
            cursors: vec![CursorPos { row: 3, col: 14 }],
        }
    }

    #[test]
    fn roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        write_entry_in(dir.path(), &entry("/tmp/a.rs")).unwrap();
        assert_eq!(
            read_entry_in(dir.path(), Path::new("/tmp/a.rs")),
            Some(entry("/tmp/a.rs"))
        );
        // A different path is a different file.
        assert_eq!(read_entry_in(dir.path(), Path::new("/tmp/b.rs")), None);
    }

    #[test]
    fn garbage_is_absent() {
        let dir = tempfile::tempdir().unwrap();
        let file = entry_file(dir.path(), Path::new("/tmp/a.rs"));
        fs::write(&file, "not [ valid toml").unwrap();
        assert_eq!(read_entry_in(dir.path(), Path::new("/tmp/a.rs")), None);
    }

    #[test]
    fn path_mismatch_is_absent() {
        let dir = tempfile::tempdir().unwrap();
        // Entry stored under /tmp/a.rs's hash but claiming another path.
        let other = entry("/tmp/somewhere-else.rs");
        fs::write(
            entry_file(dir.path(), Path::new("/tmp/a.rs")),
            toml::to_string(&other).unwrap(),
        )
        .unwrap();
        assert_eq!(read_entry_in(dir.path(), Path::new("/tmp/a.rs")), None);
    }

    #[test]
    fn inconsistent_entry_is_absent() {
        let dir = tempfile::tempdir().unwrap();
        for contents in [
            "path = '/tmp/a.rs'\nprimary-index = 0\n",
            "path = '/tmp/a.rs'\nprimary-index = 2\n[[cursor]]\nrow = 1\ncol = 1\n",
        ] {
            fs::write(entry_file(dir.path(), Path::new("/tmp/a.rs")), contents).unwrap();
            assert_eq!(read_entry_in(dir.path(), Path::new("/tmp/a.rs")), None);
        }
    }

    #[test]
    fn writes_are_toml() {
        let dir = tempfile::tempdir().unwrap();
        write_entry_in(dir.path(), &entry("/tmp/a.rs")).unwrap();
        let contents = fs::read_to_string(entry_file(dir.path(), Path::new("/tmp/a.rs"))).unwrap();
        assert!(contents.starts_with("path = "));
        assert!(contents.contains("[[cursor]]\nrow = 3\ncol = 14\n"));
    }
}
