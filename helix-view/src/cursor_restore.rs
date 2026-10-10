//! Cursor position persistence: selections are saved per file on view/document
//! close and on exit, and restored when a file is freshly opened.
//!
//! Only cursor points are persisted (extents are dropped); the storage side
//! lives in `helix_loader::cursor_restore`. Documents opened while the feature
//! was disabled save on close like any other, overwriting their previous entry
//! even if the cursor never moved off the origin; accepted for simplicity.

use std::path::Path;

use helix_core::{coords_at_pos, pos_at_coords, Position, Range, Rope, Selection};
use helix_loader::cursor_restore::{read_entry, write_entry, CursorEntry, CursorPos};

use crate::editor::CursorRestoreConfig;
use crate::{Document, DocumentId, Editor, ViewId};

/// Throwaway buffers that git and jj regenerate on every invocation
/// (COMMIT_EDITMSG/MERGE_MSG/TAG_EDITMSG, NOTES_EDITMSG/EDIT_DESCRIPTION,
/// git-rebase-todo, jj describe/edit files): restoring a cursor there is noise.
pub(crate) const BUILTIN_EXCLUDED_LANGUAGES: &[&str] =
    &["git-commit", "git-notes", "git-rebase", "jjdescription"];

fn excluded(language: Option<&str>, config_languages: &[String]) -> bool {
    match language {
        Some(language) => {
            BUILTIN_EXCLUDED_LANGUAGES.contains(&language)
                || config_languages.iter().any(|exclude| exclude == language)
        }
        None => false,
    }
}

pub(crate) fn entry_from_selection(path: &Path, selection: &Selection, text: &Rope) -> CursorEntry {
    // `cursors` consumes the selection and keeps one point per cursor, hence the clone.
    let selection = selection.clone().cursors(text.slice(..));
    let cursors = selection
        .iter()
        .map(|range| {
            let pos = coords_at_pos(text.slice(..), range.head);
            CursorPos {
                row: pos.row,
                col: pos.col,
            }
        })
        .collect();
    CursorEntry {
        path: path.to_path_buf(),
        primary_index: selection.primary_index(),
        cursors,
    }
}

pub(crate) fn selection_from_entry(entry: &CursorEntry, text: &Rope) -> Option<Selection> {
    if entry.cursors.is_empty() || entry.primary_index >= entry.cursors.len() {
        return None;
    }
    let ranges = entry
        .cursors
        .iter()
        .map(|cursor| {
            // `pos_at_coords` clamps a too-large column to the line end but not a
            // too-large row, which would panic in `line_to_char`.
            let row = cursor.row.min(text.len_lines() - 1);
            let pos = pos_at_coords(text.slice(..), Position::new(row, cursor.col), false);
            Range::point(pos)
        })
        .collect();
    Some(Selection::new(ranges, entry.primary_index))
}

impl Editor {
    fn cursor_restore_config(&self) -> CursorRestoreConfig {
        self.config().cursor_restore.clone()
    }

    /// Save the position one view has in `doc`.
    fn save_position(&self, doc: &Document, selection: &Selection) {
        let config = self.cursor_restore_config();
        // Non-UTF-8 paths can't round-trip through the entry's TOML `path` field.
        let Some(path) = doc.path().filter(|path| path.to_str().is_some()) else {
            return;
        };
        if !config.enable || excluded(doc.language_name(), &config.excluded_languages) {
            return;
        }
        write_entry(&entry_from_selection(path, selection, doc.text()));
    }

    /// Save the positions `view_id` has in every document it selected in.
    pub(crate) fn persist_view_positions(&self, view_id: ViewId) {
        for doc in self.documents() {
            if let Some(selection) = doc.selections().get(&view_id) {
                self.save_position(doc, selection);
            }
        }
    }

    /// Save the positions every live view has. SIGTERM/SIGINT exits skip every
    /// view close, so this sweep exists for them; on a normal exit the tree is
    /// empty and it no-ops.
    pub fn persist_cursor_positions(&self) {
        for (view, _focus) in self.tree.views() {
            self.persist_view_positions(view.id);
        }
    }

    /// Save one closing document's positions, from every view that selected in it.
    pub(crate) fn persist_doc_positions(&self, doc_id: DocumentId) {
        if let Some(doc) = self.document(doc_id) {
            for selection in doc.selections().values() {
                self.save_position(doc, selection);
            }
        }
    }

    /// Restore `doc_id`'s last saved cursor position, if enabled and present.
    pub(crate) fn restore_cursor_position(&mut self, path: &Path, doc_id: DocumentId) {
        let config = self.cursor_restore_config();
        if !config.enable {
            return;
        }
        let selection = match self.document(doc_id) {
            Some(doc) if !excluded(doc.language_name(), &config.excluded_languages) => {
                read_entry(path).and_then(|entry| selection_from_entry(&entry, doc.text()))
            }
            _ => return,
        };
        let Some(selection) = selection else { return };
        let view_id = self.tree.focus;
        doc_mut!(self, &doc_id).set_selection(view_id, selection);
        // A background `Action::Load` opens into the focused view without switching
        // it; don't scroll a view showing a different document.
        if self.tree.get(view_id).doc == doc_id {
            self.ensure_cursor_in_view(view_id);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(path: &str, cursors: &[CursorPos], primary_index: usize) -> CursorEntry {
        CursorEntry {
            path: Path::new(path).to_path_buf(),
            primary_index,
            cursors: cursors.to_vec(),
        }
    }

    #[test]
    fn roundtrip_multicursor_drops_extents() {
        let text = Rope::from_str("hello world\nsecond line\nthird\n");
        // Forward extent, backward extent, plain point; lines start at 0, 12 and 24.
        let selection = Selection::new(
            vec![Range::new(0, 6), Range::new(21, 16), Range::point(26)].into(),
            2,
        );
        let saved = entry_from_selection(Path::new("/tmp/a.rs"), &selection, &text);
        // Extents are gone; block-cursor semantics move a forward head back one grapheme.
        assert_eq!(
            saved.cursors,
            [
                CursorPos { row: 0, col: 5 },
                CursorPos { row: 1, col: 4 },
                CursorPos { row: 2, col: 2 },
            ]
        );
        assert_eq!(saved.primary_index, 2);

        let restored = selection_from_entry(&saved, &text).unwrap();
        assert_eq!(
            restored,
            Selection::new(
                vec![Range::point(5), Range::point(16), Range::point(26)].into(),
                2
            )
        );
    }

    #[test]
    fn roundtrip_cursor_at_eof() {
        let text = Rope::from_str("abc\ndef\n");
        let selection = Selection::point(text.len_chars());
        let saved = entry_from_selection(Path::new("/tmp/a.rs"), &selection, &text);
        let restored = selection_from_entry(&saved, &text).unwrap();
        assert_eq!(restored, Selection::point(text.len_chars()));
    }

    #[test]
    fn roundtrip_empty_file() {
        let text = Rope::from_str("");
        let selection = Selection::point(0);
        let saved = entry_from_selection(Path::new("/tmp/a.rs"), &selection, &text);
        let restored = selection_from_entry(&saved, &text).unwrap();
        assert_eq!(restored, Selection::point(0));
    }

    #[test]
    fn roundtrip_no_trailing_newline() {
        let text = Rope::from_str("abc\ndef");
        let selection = Selection::point(text.len_chars());
        let saved = entry_from_selection(Path::new("/tmp/a.rs"), &selection, &text);
        assert_eq!(saved.cursors, [CursorPos { row: 1, col: 3 }]);
        let restored = selection_from_entry(&saved, &text).unwrap();
        assert_eq!(restored, Selection::point(text.len_chars()));
    }

    #[test]
    fn shrunk_file_clamps_without_panic() {
        let text = Rope::from_str("short\nfile");
        let saved = entry("/tmp/a.rs", &[CursorPos { row: 900, col: 900 }], 0);
        let restored = selection_from_entry(&saved, &text).unwrap();
        assert_eq!(restored, Selection::point(text.len_chars()));
    }

    #[test]
    fn empty_entry_restores_none() {
        let text = Rope::from_str("x");
        let saved = entry("/tmp/a.rs", &[], 0);
        assert!(selection_from_entry(&saved, &text).is_none());
    }

    #[test]
    fn excluded_semantics() {
        // Built-in.
        assert!(excluded(Some("git-commit"), &[]));
        assert!(excluded(Some("jjdescription"), &[]));
        // Config extends the built-ins.
        assert!(excluded(Some("markdown"), &["markdown".to_owned()]));
        // Unrelated names and no language are not excluded.
        assert!(!excluded(Some("rust"), &["markdown".to_owned()]));
        assert!(!excluded(None, &["markdown".to_owned()]));
    }
}
