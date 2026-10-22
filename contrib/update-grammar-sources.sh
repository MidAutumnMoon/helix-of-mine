#!/usr/bin/env bash
# Regenerate grammar-sources.json from languages.toml.
#
# Each [[grammar]] git source gets a pin {git, rev, url, hash}. languages.toml
# stays the single source of truth for revisions; the lock only pins content.
# Grammars whose (git, rev) pair is unchanged keep their existing hash, so a
# run after an upstream sync prefetches only what actually moved. --force
# re-hashes everything, for the rare case a forge changes archive bytes under
# an unchanged rev.
#
# All-or-nothing: the lock is rewritten only if every prefetch succeeded.
#
# grammar-sources.json must be visible to git (jj snapshots do this
# automatically; with plain git, `git add -N` it after first generation) —
# flake evaluation only sees tracked files.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
lock=$repo/grammar-sources.json
force=0
if [[ "${1:-}" == "--force" ]]; then force=1; fi

archive_url() {
    local git=$1 rev=$2 name
    git=${git%/}
    name=$(basename "$git")
    case $git in
        https://github.com/* | https://codeberg.org/* | https://git.sr.ht/*)
            printf '%s/archive/%s.tar.gz' "$git" "$rev"
            ;;
        https://gitlab.com/*)
            printf '%s/-/archive/%s/%s-%s.tar.gz' "$git" "$rev" "$name" "$rev"
            ;;
        *)
            echo "update-grammar-sources: unsupported forge: $git" >&2
            return 1
            ;;
    esac
}

# nix doubles as the TOML parser: emit {name, git, rev} for every grammar
# pinned to a git revision.
wanted=$(nix eval --impure --json --expr '
    let langs = builtins.fromTOML (builtins.readFile '"$repo"'/languages.toml); in
    builtins.map
        (g: { name = g.name; git = g.source.git; rev = g.source.rev; })
        (builtins.filter (g: g ? source.git && g ? source.rev) langs.grammar)
')

old='{}'
if [[ -f $lock ]]; then
    old=$(jq -e . "$lock") || {
        echo "update-grammar-sources: $lock is corrupt; fix or delete it first" >&2
        exit 1
    }
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; rm -f "$lock.new"' EXIT

# name \t git \t rev \t url, one per grammar
jq -r '.[] | [.name, .git, .rev] | @tsv' <<<"$wanted" |
    while IFS=$'\t' read -r name git rev; do
        url=$(archive_url "$git" "$rev") || exit 1
        printf '%s\t%s\t%s\t%s\n' "$name" "$git" "$rev" "$url"
    done >"$tmp/pins.tsv"

# Entries to prefetch: new, changed (git, rev), or everything with --force.
: >"$tmp/todo"
while IFS=$'\t' read -r name git rev _; do
    if ((force)) || ! jq -e --arg n "$name" --arg g "$git" --arg r "$rev" \
        '.[$n] != null and .[$n].git == $g and .[$n].rev == $r and .[$n].hash != null' \
        <<<"$old" >/dev/null; then
        printf '%s\n' "$name" >>"$tmp/todo"
    fi
done <"$tmp/pins.tsv"

total=$(wc -l <"$tmp/pins.tsv")
todo=$(wc -l <"$tmp/todo")
echo "grammars: $total total, $todo to prefetch"

mkdir "$tmp/hashes"
if ((todo > 0)); then
    export tmp
    # Per-worker failures are tolerated here and reported precisely by the
    # missing-pins check below.
    xargs -P "$(nproc)" -n1 bash -c '
        set -euo pipefail
        name=$1
        url=$(awk -F"\t" -v n="$name" "\$1 == n {print \$4}" "$tmp/pins.tsv")
        if hash=$(nix store prefetch-file --json "$url" | jq -r .hash); then
            printf "%s" "$hash" >"$tmp/hashes/$name"
        else
            echo "update-grammar-sources: prefetch failed: $name ($url)" >&2
        fi
    ' init <"$tmp/todo" || echo "update-grammar-sources: some prefetch workers exited abnormally" >&2
fi

missing=()
while IFS= read -r name; do
    [[ -f $tmp/hashes/$name ]] || missing+=("$name")
done <"$tmp/todo"
if ((${#missing[@]} > 0)); then
    echo "update-grammar-sources: not updating the lock, failed grammars:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    exit 1
fi

# name:hash JSON for this run's prefetches
: >"$tmp/newhashes.json"
while IFS= read -r name; do
    jq -cn --arg n "$name" --arg h "$(cat "$tmp/hashes/$name")" '{($n): $h}'
done <"$tmp/todo" | jq -s 'add // {}' >"$tmp/newhashes.json"

# Fresh git/rev/url everywhere; hash from this run where prefetched, else the
# old lock (guaranteed present and current by the todo filter above).
jq -S --argjson old "$old" --argjson new "$(cat "$tmp/newhashes.json")" -Rn '
    [inputs | split("\t") | {
        key: .[0],
        value: {
            git: .[1],
            rev: .[2],
            url: .[3],
            hash: ($new[.[0]] // $old[.[0]].hash),
        },
    }] | from_entries
' "$tmp/pins.tsv" >"$lock.new"
jq -e 'all(.[]; (.hash | type) == "string" and .url != null)' "$lock.new" >/dev/null || {
    echo "update-grammar-sources: assembled lock has missing hashes or urls" >&2
    rm -f "$lock.new"
    exit 1
}
mv "$lock.new" "$lock"

echo "update-grammar-sources: $lock updated ($todo prefetched, $((total - todo)) kept)"
