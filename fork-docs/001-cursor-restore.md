# Cursor restore

Persist and restore cursor positions across sessions, nvim-style: reopening a
file puts the cursor where the last session left it. Off by default:

```toml
[editor.cursor-restore]
enable = true
excluded-languages = ["..."]   # extends the built-in list
```

Written for rebasing onto upstream: each decision records why the code is
shaped as it is. Symbols are the anchors, not line numbers.

## Where the code lives

- `helix-loader/src/cursor_restore.rs`: the store, one TOML file per edited
  path under `state_dir()/cursor_restore/<sha256(path)>.toml`, `path` field
  inside for debugging. `helix_loader::state_dir()` (helix-loader/src/lib.rs)
  falls back to `data_dir()` where the platform has no state home. Upstream
  PR #9143 hit a Windows panic by unwrapping it.
- `helix-view/src/cursor_restore.rs`: selection ↔ entry conversion, the
  exclusion predicate (`BUILTIN_EXCLUDED_LANGUAGES`), and the `impl Editor`
  methods (`persist_view_positions`, `persist_doc_positions`,
  `persist_cursor_positions`, `restore_cursor_position`). Unit tests for both
  halves live in the two `cursor_restore.rs` modules.
- Config and hooks: `CursorRestoreConfig` plus the three hooks in
  `helix-view/src/editor.rs` (`Editor::{open, close, close_document}`); one
  sweep call in `helix-term/src/application.rs` (`Application::close`); the
  explicit-position guards in the CLI file loop there and in `open_impl`
  (`helix-term/src/commands/typed.rs`).

## Decisions and why

**Restore only fresh documents.** `Editor::open` restores only when it created
the document in that call (`was_fresh`). Restoring on the reuse branch would
clobber a live cursor whenever the file picker or `:open` targets an
already-open buffer.

**Save where the data dies.** Selections live in `Document::selections` (per
view) and are deleted by `remove_view` inside `Editor::close` and by
`documents.remove` in `Editor::close_document`; the sweeps run *before* those
deletions. That ordering is the one thing a rebase must not lose.
`Application::close` adds a final sweep because SIGTERM/SIGINT exit without
closing any view; on a normal exit the tree is empty and it no-ops.

**Only explicit positions beat the restore.** Upstream's CLI file loop and
`open_impl` apply a default (0, 0) selection after `open()` returns; that
would reset every restore, so both apply a position only when the user gave
one (`file:row:col`, `+N`). Accepted divergence from upstream: `:open` on an
already-open buffer keeps its cursor instead of jumping to the top (nvim-like),
and CLI startup centers the restored cursor.

**Cursor-only.** Extents are dropped at save (`Selection::cursors`): one point
per cursor plus the primary index; multi-cursor count survives.

**(row, col) encoding, clamped on restore.** Rows clamp to `len_lines() - 1`;
columns self-clamp inside `pos_at_coords(.., false)`. Raw char offsets would
drift with any edit above the cursor. Beware the `pos_at_coords` flags: with
`limit_before_line_ending = false` rows are not clamped (out-of-range panics
in `line_to_char`); with `true` a cursor on the final empty line is
unrepresentable.

**Sharded storage, not one file.** The sweeps fire on ordinary buffer/window
closes, not just exit, so a single state file would need read-merge-write on
every close, which is vim shada's failure class. One file per path makes
cross-instance clobbering unrepresentable; same shape and rationale as
`workspace_trust`. Writes go through a pid-suffixed temp file + rename.

**Best-effort, quiet.** Store errors are logged and disable further writes for
the process; they never propagate. `Application::close` turns errors into exit
code 1, and exit-1-on-every-quit is how this feature would get deleted.

**Exclusions by language name.** `git-commit`, `git-notes`, `git-rebase`, and
`jjdescription` are built in: regenerated throwaway buffers where a restored
cursor is noise. `excluded-languages` extends the list; builtins cannot be
un-excluded. Known leaks, accepted: `PULLREQ_EDITMSG` (a file-type of
markdown) and language-less `svn-commit.tmp`.

## Accepted limitations

- SIGKILL / SIGHUP / panic lose everything since the last close.
- Entries accumulate forever. Manual reset:
  `rm -rf ~/.local/state/helix/cursor_restore`.
- A document opened while the feature was disabled still saves on close,
  overwriting its previous entry even if the cursor never moved.
- The same document in two splits: which view's cursor wins on `:bc` is
  nondeterministic (one entry per path; `:qa` is order-stable).
