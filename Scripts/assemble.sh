#!/bin/bash
# Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
#
# Build a working Downright source tree: upstream at the pinned commit, then
# each layer's patches and new files, in order.
#
#   Scripts/assemble.sh                 width + iOS layers  -> work/
#   Scripts/assemble.sh --layer width   width layer only    -> work/
#   OUT=/path Scripts/assemble.sh       somewhere else
#
# The result is a git repository whose commits are the layers' own commits
# (`git am`), so `git log` and `git blame` there explain every change.  A
# patch that no longer applies stops with its name; nothing is half-applied
# silently.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAYER=ios
case "${1:-}" in
    "") ;;
    --layer) LAYER="${2:?--layer needs width or ios}" ;;
    *) echo "usage: Scripts/assemble.sh [--layer width|ios]" >&2; exit 2 ;;
esac
case "$LAYER" in width|ios) ;; *) echo "assemble: unknown layer '$LAYER'" >&2; exit 2 ;; esac
OUT="${OUT:-$ROOT/work}"

[ -e "$ROOT/upstream/.git" ] || { echo "assemble: run 'git submodule update --init' first" >&2; exit 1; }
PIN="$(git -C "$ROOT/upstream" rev-parse HEAD)"

case "$OUT" in "$ROOT"|/|"") echo "assemble: refusing OUT=$OUT" >&2; exit 1 ;; esac
rm -rf "$OUT"
mkdir -p "$OUT"
git -C "$ROOT/upstream" archive --format=tar "$PIN" | tar -x -C "$OUT"

cd "$OUT"
git init -q -b main
git config user.name "assemble"
git config user.email "assemble@localhost"
git add -A
git commit -q -m "Downright upstream $PIN"

apply_layer() { # name
    local name="$1" patch
    for patch in "$ROOT/patches/$name"/*.patch; do
        [ -e "$patch" ] || continue
        if ! git am --quiet --3way --committer-date-is-author-date "$patch" >/dev/null 2>&1; then
            git am --abort >/dev/null 2>&1 || true
            echo "assemble: patches/$name/$(basename "$patch") no longer applies to upstream $PIN" >&2
            exit 1
        fi
    done
    if [ -d "$ROOT/overlay/$name" ] && [ -n "$(ls -A "$ROOT/overlay/$name")" ]; then
        cp -R "$ROOT/overlay/$name/." "$OUT/"
        git add -A
        git commit -q --author="Brad Nicholas <70774+bradn@users.noreply.github.com>" \
            -m "Add the $name layer's new files (overlay/$name)"
    fi
}

apply_layer width
if [ "$LAYER" = ios ]; then
    apply_layer ios
    # Your own Apple team ID and bundle prefix (git-ignored here and in the
    # tree; see iOSApp/Signing.xcconfig), carried into every fresh tree.
    if [ -f "$ROOT/Signing.local.xcconfig" ]; then
        cp "$ROOT/Signing.local.xcconfig" "$OUT/iOSApp/Signing.local.xcconfig"
        echo "assemble: used your Signing.local.xcconfig"
    fi
fi
echo "assemble: $LAYER layer on upstream ${PIN:0:7} -> $OUT"
