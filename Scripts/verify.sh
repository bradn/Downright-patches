#!/bin/bash
# Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
#
# Acceptance checks for this patch repository (docs/IOS-PORT-PLAN.md,
# "Publishing: a patch repository").
#
#   Scripts/verify.sh                       content checks only (fast)
#   Scripts/verify.sh --against <checkout>  also: the export is current, and
#                                           both assembled layers equal the
#                                           checkout's branches
#   ... --checks                            also: run the build and test gates
#                                           inside the assembled trees (slow)
#
# Content checks:
#   - no file in this repository is an upstream Downright file (overlay paths
#     must not exist in the pinned upstream tree);
#   - every file carries the attribution tag near its top, except images and
#     JSON, which cannot hold a comment (README.md, "Attribution");
#   - every patch carries the tag after its `---` line.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
MARKER="by Claude Code as directed by Brad Nicholas"
AGAINST=""
CHECKS=no
while [ $# -gt 0 ]; do
    case "$1" in
        --against) AGAINST="${2:?--against needs a checkout path}"; shift 2 ;;
        --checks) CHECKS=yes; shift ;;
        *) echo "usage: Scripts/verify.sh [--against <checkout>] [--checks]" >&2; exit 2 ;;
    esac
done

failures=0
fail() { echo "verify: FAIL $*" >&2; failures=$((failures + 1)); }
ok() { echo "verify: ok   $*"; }

[ -e upstream/.git ] || { echo "verify: run 'git submodule update --init' first" >&2; exit 1; }
PIN="$(git -C upstream rev-parse HEAD)"

# 1. Nothing here is an upstream file.
upstream_hits=0
while IFS= read -r file; do
    path="${file#overlay/*/}"
    if git -C upstream cat-file -e "$PIN:$path" 2>/dev/null; then
        fail "overlay file is an upstream path: $file"
        upstream_hits=$((upstream_hits + 1))
    fi
done < <(find overlay -type f | sort)
[ "$upstream_hits" -eq 0 ] && ok "no overlay file exists in upstream ${PIN:0:7}"

# 2. Attribution on every file this repository tracks or is about to.
untagged=0
while IFS= read -r file; do
    [ "$file" = upstream ] && continue
    [ -f "$file" ] || continue
    case "$file" in
        *.png|*.jpg|*.jpeg|*.gif|*.json) continue ;;
        *.patch)
            awk 'f && /^diff --git/ { exit } f && /'"$MARKER"'/ { found = 1 } $0 == "---" { f = 1 } END { exit !found }' "$file" \
                || { fail "patch without attribution: $file"; untagged=$((untagged + 1)); }
            continue ;;
    esac
    # The tag may follow a shebang, an XML declaration, a swift-tools-version
    # line or YAML front matter, so look a little way down.
    head -n 12 "$file" | grep -q "$MARKER" \
        || { fail "file without attribution: $file"; untagged=$((untagged + 1)); }
done < <({ git ls-files; git ls-files --others --exclude-standard; } | sort -u)
[ "$untagged" -eq 0 ] && ok "every file and patch carries the attribution tag"

# 3. Same content as the layered checkout.
compare_layer() { # layer branch
    local layer="$1" branch="$2" out ref
    out="$(mktemp -d)"; ref="$(mktemp -d)"
    if ! OUT="$out/tree" Scripts/assemble.sh --layer "$layer" >/dev/null; then
        fail "$layer layer does not assemble"
        rm -rf "$out" "$ref"; return
    fi
    git -C "$AGAINST" archive "$branch" | tar -x -C "$ref"
    # A builder's own signing values, copied in by assemble.sh; never committed.
    rm -f "$out/tree/iOSApp/Signing.local.xcconfig"
    # Moved out of the source tree by export.sh on purpose.
    (cd "$ref" && rm -f .github/README.md GIT-WORKFLOW.md WIDTH-PATCH-HANDOFF.md \
        IOS-PORT-PLAN.md Scripts/sync-upstream.sh Scripts/tag-attribution.py)
    if diff -rq -x .git "$ref" "$out/tree" >/dev/null; then
        # Modes too: a script that lost its executable bit would still diff equal.
        if (cd "$ref" && find . -type f -perm -u+x | sort) | diff -q - <(cd "$out/tree" && find . -path ./.git -prune -o -type f -perm -u+x -print | sort) >/dev/null; then
            ok "$layer layer assembles to exactly $branch ($(git -C "$AGAINST" rev-parse --short "$branch"))"
        else
            fail "$layer layer: executable bits differ from $branch"
        fi
    else
        fail "$layer layer differs from $branch:"
        diff -rq -x .git "$ref" "$out/tree" | head -20 >&2
    fi
    rm -rf "$out" "$ref"
}

if [ -n "$AGAINST" ]; then
    stale=0
    while read -r name sha; do
        case "$name" in "#"*|"") continue ;; upstream) branch=main ;; *) branch="$name" ;; esac
        current="$(git -C "$AGAINST" rev-parse "$branch" 2>/dev/null)"
        [ "$current" = "$sha" ] || { fail "EXPORT is stale: $branch is ${current:0:7}, exported ${sha:0:7}"; stale=1; }
    done < EXPORT
    [ "$stale" -eq 0 ] && ok "EXPORT matches the checkout's branch tips"
    compare_layer width width-patch
    compare_layer ios ios-port
fi

# 4. The gates, in assembled trees.
if [ "$CHECKS" = yes ]; then
    for layer in width ios; do
        tree="$ROOT/work-verify-$layer"
        OUT="$tree" Scripts/assemble.sh --layer "$layer" >/dev/null || { fail "$layer layer does not assemble"; continue; }
        if (cd "$tree" && Scripts/check.sh > "$ROOT/verify-$layer-check.log" 2>&1); then
            ok "$layer layer: Scripts/check.sh passed ($(grep -m1 'tests executed' "$ROOT/verify-$layer-check.log" | tr -s ' '))"
        else
            fail "$layer layer: Scripts/check.sh failed; see verify-$layer-check.log"
        fi
        if [ "$layer" = ios ]; then
            if (cd "$tree" && Scripts/check-ios.sh > "$ROOT/verify-ios-check-ios.log" 2>&1); then
                ok "ios layer: Scripts/check-ios.sh passed ($(grep 'Sanity' "$ROOT/verify-ios-check-ios.log" | tr -s ' '))"
            else
                fail "ios layer: Scripts/check-ios.sh failed; see verify-ios-check-ios.log"
            fi
        fi
    done
fi

if [ "$failures" -gt 0 ]; then
    echo "verify: $failures check(s) failed" >&2
    exit 1
fi
echo "verify: all checks passed"
