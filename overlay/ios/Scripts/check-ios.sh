#!/bin/bash
# Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
# Build the shared engine for iOS and run its tests on an iOS simulator, then
# build and test the iOS app (iOSApp/).
#
# Covers the platform-neutral half of the package only: MarkdownCore and the
# MarkdownRender engine (the AppKit view layer is compiled out on iOS). This
# does not replace Scripts/check.sh, which remains the authoritative macOS gate.
#
# Xcode, not the Command Line Tools, must be the active developer directory
# (or set DEVELOPER_DIR).
#
# The repository root also holds the XcodeGen project, which shadows the
# package for xcodebuild, and the package's default test scheme drags in the
# Mac app and Sparkle, which cannot build for iOS. So this script assembles a
# package-only view (symlinks) in a scratch directory with a test scheme that
# lists just the two shared test bundles.
#
#   IOS_SCRATCH    scratch directory (default: .build-ios)
#   IOS_SIMULATOR  simulator name (default: first iPhone on the newest runtime)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
IOS_SCRATCH="${IOS_SCRATCH:-.build-ios}"
case "$IOS_SCRATCH" in /*) ;; *) IOS_SCRATCH="$ROOT/$IOS_SCRATCH" ;; esac
VIEW="$IOS_SCRATCH/package"
DERIVED="$IOS_SCRATCH/derived"
mkdir -p "$VIEW/.swiftpm/xcode/xcshareddata/xcschemes" "$DERIVED"

# README.md is read by a MarkdownCore corpus test through #filePath.
for item in Package.swift Package.resolved Sources Tests Vendor README.md; do
    [ -e "$ROOT/$item" ] && ln -sfn "$ROOT/$item" "$VIEW/$item"
done

cat > "$VIEW/.swiftpm/xcode/xcshareddata/xcschemes/SharedEngineTests.xcscheme" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "MarkdownCoreTests" BuildableName = "MarkdownCoreTests" BlueprintName = "MarkdownCoreTests" ReferencedContainer = "container:">
            </BuildableReference>
         </TestableReference>
         <TestableReference skipped = "NO">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "MarkdownRenderTests" BuildableName = "MarkdownRenderTests" BlueprintName = "MarkdownRenderTests" ReferencedContainer = "container:">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
</Scheme>
EOF

if [ -n "${IOS_SIMULATOR:-}" ]; then
    DESTINATION="platform=iOS Simulator,name=$IOS_SIMULATOR"
else
    # First iPhone on the newest installed iOS runtime, by identifier: a bare
    # name means OS:latest to xcodebuild and misses devices on older runtimes.
    read -r IOS_SIMULATOR_ID IOS_SIMULATOR <<<"$(xcrun simctl list devices available | awk '
        /^-- iOS / { section++; found = 0; next }
        /^-- / { found = 1; next }
        section && !found && /^ +iPhone/ {
            line = $0; sub(/^ +/, "", line)
            name = line; sub(/ \(.*/, "", name)
            match(line, /\([0-9A-F-]{36}\)/)
            id = substr(line, RSTART + 1, RLENGTH - 2)
            pick[section] = id " " name; found = 1
        }
        END { if (section) print pick[section] }')"
    DESTINATION="platform=iOS Simulator,id=${IOS_SIMULATOR_ID:-}"
fi
if [ -z "${IOS_SIMULATOR:-}" ]; then
    echo "check-ios: no available iPhone simulator; set IOS_SIMULATOR" >&2
    exit 1
fi

status=0
cd "$VIEW"

echo "==> Building MarkdownRender for iOS devices"
DEVICE_LOG="$IOS_SCRATCH/device-build.log"
if xcodebuild build -scheme MarkdownRender -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED/device" > "$DEVICE_LOG" 2>&1; then
    echo "    ok"
else
    echo "    FAILED — see $DEVICE_LOG"
    grep -E "error:" "$DEVICE_LOG" | sort -u | head -20
    status=1
fi

echo "==> Testing MarkdownCore and MarkdownRender on $IOS_SIMULATOR"
TEST_LOG="$IOS_SCRATCH/simulator-test.log"
# Serial: the suites include wall-clock budgets that parallel clones distort.
if xcodebuild test -scheme SharedEngineTests \
    -destination "$DESTINATION" \
    -parallel-testing-enabled NO \
    -derivedDataPath "$DERIVED/simulator" > "$TEST_LOG" 2>&1; then
    echo "    ok"
else
    echo "    FAILED — see $TEST_LOG"
    grep -E "✘|error:" "$TEST_LOG" | sort -u | head -20
    status=1
fi

# The iOS app (iOSApp/), when XcodeGen is available to generate its project.
if command -v xcodegen >/dev/null 2>&1; then
    # Config/version.env is the canonical version source, as for the Mac app.
    # shellcheck disable=SC1091
    . "$ROOT/Config/version.env"
    echo "==> Testing the iOS app ($MARKETING_VERSION, build $CURRENT_PROJECT_VERSION) on $IOS_SIMULATOR"
    APP_LOG="$IOS_SCRATCH/app-test.log"
    if (cd "$ROOT/iOSApp" && xcodegen generate --quiet) > "$APP_LOG" 2>&1 \
        && xcodebuild test -project "$ROOT/iOSApp/DownrightIOS.xcodeproj" -scheme DownrightIOS \
            -destination "$DESTINATION" -derivedDataPath "$DERIVED/app" \
            MARKETING_VERSION="$MARKETING_VERSION" CURRENT_PROJECT_VERSION="$CURRENT_PROJECT_VERSION" \
            CODE_SIGNING_ALLOWED=NO >> "$APP_LOG" 2>&1; then
        echo "    ok"
    else
        echo "    FAILED — see $APP_LOG"
        grep -E "error:|failed" "$APP_LOG" | sort -u | head -20
        status=1
    fi
    app_executed="$(grep -E 'Executed [0-9]+ tests' "$APP_LOG" | tail -1 \
        | sed -nE 's/.*Executed ([0-9]+) tests.*/\1/p')"
    echo "    ${app_executed:-0} app tests executed"
    if [ "${app_executed:-0}" -eq 0 ]; then
        echo "    FAILED — the app's test bundle ran nothing"
        status=1
    fi
else
    echo "==> Skipping the iOS app: xcodegen not installed"
fi

# Zero executed tests is a failed gate, never a pass.
runs="$(grep -E 'Test run with [0-9]+ tests' "$TEST_LOG" || true)"
bundles="$(printf '%s\n' "$runs" | grep -c 'Test run with' || true)"
executed="$(printf '%s\n' "$runs" | sed -nE 's/.*Test run with ([0-9]+) tests.*/\1/p' \
    | awk '{ total += $1 } END { print total + 0 }')"
echo "==> Sanity: $executed tests executed across $bundles bundles"
if [ "$bundles" -lt 2 ] || [ "$executed" -eq 0 ]; then
    echo "    FAILED — expected both MarkdownCoreTests and MarkdownRenderTests to run"
    status=1
fi

exit "$status"
