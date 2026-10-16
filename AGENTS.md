# AGENTS.md

## What This Is

Source code of helix editor soft fork with custom patches.

Our patches in order:
- xtpsxlks: setup AGENTS.md (begin of our commits)
- sqxqynou: restore cursor position from the last session
- mzllpmkp: tree-sitter reindent fallback for =
- lontxknu: nix: scope indented strings and outdent the closing ''
- lnowqpmx: record unique fork commits in AGENTS.md (end of our commits)

New commits go between the begin commit (`xtpsxlks`) and the record commit (the last entry above).

## jj workflow

Own patches are described commits, always rebased on top of `master@upstream` (github.com/helix-editor/helix). Upstream history is immutable. The patch stack is ours to rewrite. Backups go to `origin` (this repo's GitHub fork), never to upstream.

### Setup

For a fresh clone or a new machine. From a plain git clone, run `jj git init --colocate` first.

```
jj git remote add upstream https://github.com/helix-editor/helix
jj config set --repo 'revset-aliases."trunk()"' master@upstream
jj config set --repo git.fetch '["upstream", "origin"]'  # bare fetch hits both remotes (default: origin only)
jj config set --repo git.push 'origin'
jj config set --repo revsets.log 'trunk()::@'
jj config set --repo 'remotes.upstream.fetch-bookmarks' 'master'  # only master and release tags import
jj git fetch  # brings in master@upstream; the trunk() warning here is expected
jj bookmark track master@origin    # not @upstream: master is the fork tip
```

Repo config lives under `~/.config/jj/repos/`, not in `.jj/`. `jj config edit --repo` opens it.

### Preflight

Run before touching the stack:

```
jj config list --repo | grep trunk    # must say master@upstream
```

In `jj log`, every commit from `xtpsxlks` up must show `○`. A `◆` inside our
stack means the stack is immutable: `jj new`/`jj rebase` silently fork
instead of rebasing. Fix trunk() first (see Setup).

### Sync with upstream

```
jj git fetch && jj rebase -d master@upstream --skip-emptied
```

Bare `jj rebase -d <dest>` from the stack tip defaults to `-b @`, which moves exactly the patch stack onto the new tip. `--skip-emptied` drops a patch that upstream implemented for us. Rebase never stops for conflicts. They are stored inside the rebased patch commits, so resolve on our own schedule:

```
jj resolve --list
jj new <conflicted-patch>    # or: jj edit <conflicted-patch>
# fix the files (a conflicted file carries markers and won't compile)
jj squash                    # fold the resolution into the patch
```

### Writing patches

```
jj describe -m "short what and why"   # @ becomes the patch
# edit, build
jj new                                # next patch; @ stays empty on top
jj bookmark set master -r @-         # fork tip; re-point after stack rewrites
jj git push                           # publish the fork branch
```

Insert a patch into the middle of the stack:

```
jj new <parent-patch>          # stack above rebases onto the new change
# edit, build, test
jj describe -m "short what and why"
jj log -r 'xtpsxlks::@'        # must be linear: check ancestry, not the graph art
jj edit <record-commit>        # AGENTS.md: add the patch line, update the end
                               # entry to this commit's change-id (jj log -r @)
jj new                         # empty @ back on top
```

Reshaping is safe. Change-ids survive every rewrite:

```
jj evolog -r <patch>      # a patch's history across rebases
jj absorb                 # distribute @'s edits into the ancestor patches they modify
jj split -r <patch>       # carve one patch into two
```

### Sharp edges

- `trunk()` must stay `master@upstream`. Upstream-history immutability keys off it, so never point it at the fork.
- `master` is the fork tip, tracked at `master@origin`. After a stack rewrite, re-point it with `jj bookmark set master -r @-` before pushing. Never track `master@upstream`: fetch would drag `master` off the fork tip onto upstream.
- Mutate through jj only. `git rebase` and `git commit` strip change-ids and break `evolog`. The one git-side op that's fine: deleting stale `refs/remotes/upstream/*` (jj has no command for it, remote bookmark positions follow git refs).
- No rerere in jj. A patch that conflicts once re-conflicts on every sync touching that hunk. Keep patches small, and reuse a prior resolution with `jj evolog` + `jj restore --from <old> <path>`.
- `jj new`/`jj edit`/`jj restore` rewrite the working copy to that commit's content. Nothing is lost, but re-check the tree before build or test.
- Any jj mistake is undoable: `jj op log`, then `jj undo`.

## Make changes

- Make systematic changes. Don't be scoped to the spot you are looking at.
- Make breaking changes. Trace, find, redesign, from top to bottom.
- Challenge existing designs.

## Don't `| tail` and `| head` in bash

Do not pipe any command output through `head` or `tail`, tools will properly handle large output natively.

## Fitting New Code

- Recover the domain truth before choosing a shape: valid states, natural owner, boundaries, and relevant failure or resource constraints.
- Give each fact one authoritative home. Prefer representations and APIs that enforce invariants over comments or caller discipline.
- Read the surrounding code first. Extend an abstraction only when the new behavior shares its policy and ownership; otherwise reshape proportionally instead of adding special cases, parallel paths, or copied logic.
- Keep dependencies and data flow explicit. Do not recover required context from ambient state or reconstruct information discarded earlier.
- Design for real pressures, not hypothetical reuse. Preserve existing behavior unless a change is requested; consolidate experiments before landing.

## Look Things Up

- When unsure about a library, tool, or API, use web search or Context7 before guessing.
- Prefer Context7 for library docs.
- Don't hallucinate option names, function signatures, or CLI flags. Look it up.
- Use `$CARGO_HOME` instead of `~/.cargo`.

## Communication

- Be concise. Say the thing, stop.
- Don't repeat what I already said or what's already in context.
- Don't pad with disclaimers, summaries, or "hope that helps" type closings.
- If something is wrong, say what's wrong and how to fix it. Don't hedge.
