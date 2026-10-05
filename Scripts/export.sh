#!/bin/bash
# Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
#
# Regenerate this repository's content from the layered development checkout
# (branches main / width-patch / ios-port, see docs/DEV-WORKFLOW.md):
#
#   overlay/width, overlay/ios   files each layer adds, at their source paths
#   patches/width, patches/ios   the layer's changes to upstream files, as
#                                `git format-patch` series (commit messages kept)
#   docs/, dev/                  the checkout's docs and its own tools, which
#                                describe the layered checkout rather than the
#                                source tree, so they live outside overlay/
#   EXPORT                       which commits this export came from
#
# It reads branch tips only (never the source's working tree), and moves the
# `upstream` submodule to the checkout's `main`, which is the upstream pin.
#
# Usage: Scripts/export.sh <layered checkout>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${1:?usage: Scripts/export.sh <layered checkout>}"
BASE="${BASE:-main}"
WIDTH="${WIDTH:-width-patch}"
IOS="${IOS:-ios-port}"
TAG="Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>"

src() { git -C "$SOURCE" "$@"; }
die() { echo "export: $*" >&2; exit 1; }

for ref in "$BASE" "$WIDTH" "$IOS"; do
    src rev-parse --verify --quiet "$ref" >/dev/null || die "no branch '$ref' in $SOURCE"
done
src merge-base --is-ancestor "$BASE" "$WIDTH" || die "$WIDTH is not built on $BASE"
src merge-base --is-ancestor "$WIDTH" "$IOS" || die "$IOS is not built on $WIDTH"

# Files the layered checkout adds that are about the checkout, not the source
# tree.  The source README replacement is this repository's own README.md.
DOCS=(GIT-WORKFLOW.md WIDTH-PATCH-HANDOFF.md IOS-PORT-PLAN.md)
DEV_TOOLS=(Scripts/sync-upstream.sh Scripts/tag-attribution.py)
NOT_OVERLAY=(.github/README.md "${DOCS[@]}" "${DEV_TOOLS[@]}")

is_not_overlay() {
    local path
    for path in "${NOT_OVERLAY[@]}"; do [ "$1" = "$path" ] && return 0; done
    return 1
}

cd "$ROOT"
rm -rf overlay patches docs dev
mkdir -p overlay patches docs dev

# Upstream files: present in the pin.  Anything else the layers touch is new.
UPSTREAM_FILES="$(mktemp)"
trap 'rm -f "$UPSTREAM_FILES"' EXIT
src ls-tree -r --name-only "$BASE" > "$UPSTREAM_FILES"
is_upstream() { grep -Fxq -- "$1" "$UPSTREAM_FILES"; }

export_layer() { # name from to
    local name="$1" from="$2" to="$3" path
    local -a changed=()
    mkdir -p "overlay/$name" "patches/$name"
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        if is_upstream "$path"; then
            changed+=("$path")
        elif ! is_not_overlay "$path"; then
            mkdir -p "overlay/$name/$(dirname "$path")"
            src cat-file -p "$to:$path" > "overlay/$name/$path"
            # Keep the executable bit scripts need.
            if [ "$(src ls-tree "$to" -- "$path" | cut -c1-6)" = "100755" ]; then
                chmod +x "overlay/$name/$path"
            fi
        fi
    done < <(src diff --name-only --no-renames "$from" "$to")

    if [ "${#changed[@]}" -gt 0 ]; then
        src format-patch --quiet --no-renames --zero-commit --no-signature \
            -o "$ROOT/patches/$name" "$from..$to" -- "${changed[@]}"
        # The tag goes after the `---` that ends the commit message: `git am`
        # ignores everything between it and the first diff.
        local patch
        for patch in "patches/$name"/*.patch; do
            awk -v tag="$TAG" '!done && $0 == "---" { print; print tag; done = 1; next } { print }' \
                "$patch" > "$patch.tmp" && mv "$patch.tmp" "$patch"
        done
    fi
    echo "export: $name: $(find "overlay/$name" -type f | wc -l | tr -d ' ') new files," \
         "$(ls "patches/$name" | wc -l | tr -d ' ') patches over ${#changed[@]} upstream files"
}

export_layer width "$BASE" "$WIDTH"
export_layer ios "$WIDTH" "$IOS"

for path in "${DOCS[@]}"; do
    src cat-file -p "$IOS:$path" > "docs/$(basename "$path")"
done
mv docs/GIT-WORKFLOW.md docs/DEV-WORKFLOW.md
for path in "${DEV_TOOLS[@]}"; do
    src cat-file -p "$IOS:$path" > "dev/$(basename "$path")"
    chmod +x "dev/$(basename "$path")"
done

PIN="$(src rev-parse "$BASE")"
git -C upstream fetch --quiet origin "$PIN" 2>/dev/null || true
git -C upstream checkout --quiet "$PIN"
cat > EXPORT <<EOF
# $TAG
# Written by Scripts/export.sh; Scripts/verify.sh checks against it.
upstream $PIN
$WIDTH $(src rev-parse "$WIDTH")
$IOS $(src rev-parse "$IOS")
EOF
echo "export: upstream pinned at $(git -C upstream log --oneline -1)"
