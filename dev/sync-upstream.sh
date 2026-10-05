#!/bin/bash
# Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
# Bring upstream Downright into the local layer stack, then check each layer.
#
#   main          upstream, untouched (tracks upstream/main)
#   width-patch   local Mac patch
#   ios-port      iOS work (optional; may not exist)
#
# Fetches upstream, moves main, rebases the top layer onto upstream/main with
# --update-refs so every layer moves in one pass, then runs Scripts/check.sh
# on width-patch and Scripts/check.sh plus Scripts/check-ios.sh on ios-port.
# Stops at the first problem and says what to do. Never pushes.
#
# Usage:
#   Scripts/sync-upstream.sh               update; check only if upstream moved
#   Scripts/sync-upstream.sh --check       update; always check (use this after
#                                          finishing a rebase by hand)
#   Scripts/sync-upstream.sh --skip-checks update only
#
# Logs go to .build-sync/.  See GIT-WORKFLOW.md.
set -uo pipefail

# Checking out another branch replaces this file on disk, and bash reads a
# script as it runs.  Run from a private copy so a checkout can't change the
# code underneath us.
if [ -z "${SYNC_UPSTREAM_COPY:-}" ]; then
    COPY="$(mktemp "${TMPDIR:-/tmp}/sync-upstream.XXXXXX")" || exit 1
    cp "${BASH_SOURCE[0]}" "$COPY"
    ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    SYNC_UPSTREAM_COPY="$COPY" SYNC_UPSTREAM_ROOT="$ROOT" bash "$COPY" "$@"
    STATUS=$?
    rm -f "$COPY"
    exit $STATUS
fi

ROOT="$SYNC_UPSTREAM_ROOT"
cd "$ROOT"

REMOTE=upstream
BASE=main
WIDTH=width-patch
IOS=ios-port
LOG_DIR="$ROOT/.build-sync"

MODE=auto
case "${1:-}" in
    "") ;;
    --check) MODE=always ;;
    --skip-checks) MODE=never ;;
    -h|--help) sed -n '2,19p' "$SYNC_UPSTREAM_COPY" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "sync-upstream: unknown option: $1 (try --help)" >&2; exit 2 ;;
esac

say() { echo "sync-upstream: $*"; }
fail() { echo "sync-upstream: $*" >&2; exit 1; }
has_branch() { git show-ref --verify --quiet "refs/heads/$1"; }
rebasing() {
    [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]
}

# --- preconditions ----------------------------------------------------------

git rev-parse --git-dir >/dev/null 2>&1 || fail "not a git repository: $ROOT"
rebasing && fail "a rebase is in progress; finish it (git rebase --continue) or abort it first"
# Untracked files are fine: generated iOS files show up as untracked on
# width-patch, and a checkout carries them along untouched.
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    git status --short --untracked-files=no >&2
    fail "uncommitted changes; commit or stash them first"
fi
git remote get-url "$REMOTE" >/dev/null 2>&1 || fail "no '$REMOTE' remote"
has_branch "$WIDTH" || fail "no '$WIDTH' branch"

TOP="$WIDTH"
if has_branch "$IOS"; then
    git merge-base --is-ancestor "$WIDTH" "$IOS" \
        || fail "'$IOS' is not built on '$WIDTH'; rebase it onto '$WIDTH' first (git rebase $WIDTH $IOS)"
    TOP="$IOS"
fi

START="$(git symbolic-ref --quiet --short HEAD || git rev-parse HEAD)"
# Put the user back where they started, unless we stopped mid-rebase.
restore() { rebasing || git checkout -q "$START" 2>/dev/null; }
trap restore EXIT

# --- update -----------------------------------------------------------------

say "fetching $REMOTE"
git fetch -q "$REMOTE" || fail "fetch failed"
UPSTREAM="$REMOTE/$BASE"

OLD_BASE="$(git rev-parse "$BASE")"
OLD_WIDTH="$(git rev-parse "$WIDTH")"
OLD_TOP="$(git rev-parse "$TOP")"
MOVED=no

if git merge-base --is-ancestor "$UPSTREAM" "$TOP"; then
    say "already on the latest upstream ($(git log -1 --format='%h %s' "$UPSTREAM"))"
else
    MOVED=yes
    say "new upstream commits: $(git rev-list --count "$OLD_BASE..$UPSTREAM")"
    git log --oneline --no-decorate "$OLD_BASE..$UPSTREAM" | head -15 | sed 's/^/    /'
    WIDTH_COUNT_BEFORE="$(git rev-list --count "$OLD_BASE..$OLD_WIDTH")"

    echo
    say "to undo everything below:"
    echo "    git rebase --abort    # only if a rebase is still in progress"
    echo "    git checkout -q --detach"
    echo "    git branch -f $BASE $OLD_BASE"
    echo "    git branch -f $WIDTH $OLD_WIDTH"
    [ "$TOP" != "$WIDTH" ] && echo "    git branch -f $TOP $OLD_TOP"
    echo "    git checkout -q $START"
    echo

    git checkout -q "$TOP"
    git branch -q -f "$BASE" "$UPSTREAM"
    say "rebasing $TOP (and the layers under it) onto $UPSTREAM"
    # rerere re-applies a conflict fix recorded on an earlier run and stages
    # it, but the rebase still pauses.  Carry on through stops where nothing
    # is left unmerged; the checks below verify the result.  Stop only on a
    # conflict that needs a person.
    REBASE_LOG="$(mktemp "${TMPDIR:-/tmp}/sync-upstream-rebase.XXXXXX")"
    rebase_step() { GIT_EDITOR=true git rebase "$@" 2>&1 | tee "$REBASE_LOG"; }
    rebase_ok=no
    if rebase_step --update-refs "$UPSTREAM"; then
        rebase_ok=yes
    else
        for _ in $(seq 1 500); do
            rebasing || break
            [ -n "$(git diff --name-only --diff-filter=U)" ] && break
            reused="$(grep -oE "'[^']+' using previous resolution" "$REBASE_LOG" | cut -d"'" -f2 | tr '\n' ' ')"
            say "reused an earlier conflict fix in: ${reused:-(see git output above)}"
            if rebase_step --continue; then rebase_ok=yes; break; fi
        done
    fi
    rm -f "$REBASE_LOG"
    if [ "$rebase_ok" = no ]; then
        rebasing || fail "the rebase failed without a conflict; see the git output above"
        echo >&2
        echo "sync-upstream: the rebase stopped on a conflict. To finish:" >&2
        echo "    1. fix the files git lists (git status), then git add them" >&2
        echo "    2. git rebase --continue   (repeat until it finishes)" >&2
        echo "    3. Scripts/sync-upstream.sh --check" >&2
        echo "  or give up with: git rebase --abort" >&2
        echo "  Git records your fix (rerere); if the same conflict comes back, this script reuses it." >&2
        exit 1
    fi
    git merge-base --is-ancestor "$WIDTH" "$TOP" || fail "'$WIDTH' did not move with '$TOP'; check git log --graph"

    WIDTH_COUNT_AFTER="$(git rev-list --count "$BASE..$WIDTH")"
    if [ "$WIDTH_COUNT_AFTER" -lt "$WIDTH_COUNT_BEFORE" ]; then
        say "note: '$WIDTH' went from $WIDTH_COUNT_BEFORE to $WIDTH_COUNT_AFTER commits; upstream already had the rest"
    fi
    [ "$WIDTH_COUNT_AFTER" -eq 0 ] && say "note: '$WIDTH' is now empty; upstream contains the whole patch"
fi

# --- checks -----------------------------------------------------------------

if [ "$MODE" = never ] || { [ "$MODE" = auto ] && [ "$MOVED" = no ]; }; then
    [ "$MODE" = never ] && say "skipping checks"
    say "done"
    exit 0
fi

mkdir -p "$LOG_DIR"
run_check() { # branch script
    local log="$LOG_DIR/$1-$(basename "$2" .sh).log"
    git checkout -q "$1" || fail "could not check out $1"
    say "$1: $2 (log: ${log#"$ROOT/"})"
    if ! "$2" >"$log" 2>&1; then
        tail -30 "$log" >&2
        fail "$2 failed on $1; see ${log#"$ROOT/"}"
    fi
}

run_check "$WIDTH" Scripts/check.sh
if [ "$TOP" = "$IOS" ]; then
    run_check "$IOS" Scripts/check.sh
    run_check "$IOS" Scripts/check-ios.sh
fi

say "all checks passed"
git log --oneline --graph --decorate -n "$(( $(git rev-list --count "$BASE..$TOP") + 1 ))" "$TOP"
