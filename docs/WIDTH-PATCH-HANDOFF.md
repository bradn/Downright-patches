<!-- Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com> -->
# Handoff: raise Downright's line-width (measure) cap and build locally

Goal: let the "Measure (characters)" setting exceed 72 so more text fits per
line, then build and install a local Downright.app. Source here is v1.0.16.

Status: done in this checkout. The chosen maximum is "no upper limit": the
column is limited only by the window. Scripts/check.sh passed, the Release
app was built and installed to /Applications/Downright.app. Quick Look now
follows the same setting (items 9–11 below). The wider column has not yet been
checked by eye in the app or in a Finder Spacebar preview.

## The patch (reapply all of it for each new upstream release)

1. Sources/MarkdownRender/RenderContracts.swift: new `ReadingMeasure` enum
   (just above `struct Theme`) holding the shared bounds:
   `minimumCharacters = 68`, `maximumCharacters = 1000`, and
   `clamped(_:)`. 1000 is wider than any window, so it acts as "fill the
   window" while keeping layout and the stepper finite.
2. Sources/MarkdownRender/Theme/StyleSheet.swift (~line 170):
   `measureWidth = advance * ReadingMeasure.clamped(typography.measureCharacters)`
   (was `min(72, max(68, ...))`).
3. Sources/MarkdownRender/View/MarkdownContainerView.swift (~line 201):
   target uses `ReadingMeasure.clamped(...)`; the ">1200pt forces 72" branch
   is removed. Windows <900pt still use 66, but only when the setting is
   <= 72. This is what sets the on-screen column (applyResponsiveMeasure),
   so changing only #2 does nothing in a wide window.
4. Sources/MarkdownRender/View/MarkdownTextView+Interaction.swift (~line 506):
   task-checkbox hover clamps to the live column
   (`textContainer.size.width - RenderMetrics.codeBleed`) instead of
   `styleSheet.measureWidth`, which can now be far wider than the window.
5. Sources/DownrightApp/Support/ReaderProfiles.swift: add
   `import MarkdownRender`; init uses `ReadingMeasure.clamped(...)`.
6. Sources/DownrightApp/Panels/ReaderProfilePickerView.swift: hardcoded
   [68, 70, 72] replaced by `static let measureChoices = [68, 70, 72, 90,
   120, ReadingMeasure.maximumCharacters]` and `measureTitle(_:)` (the last
   shows as "Full width"); used at the addControl call and both lookups.
7. Sources/DownrightApp/App/PreferencesWindowController.swift (~line 890):
   stepper range is `ReadingMeasure.minimumCharacters...maximumCharacters`
   (was 60...80); help text updated. Values can be typed in the field.
8. Scripts/install.sh: missing STAGED_APP line (see below).

Quick Look follow-up: without items 9–11 the Finder preview ignores the app
setting and uses the theme's built-in measure (70), so it looks stuck near 72
characters whatever Settings says.

9. Sources/MarkdownRender/Theme/PreviewAppearance.swift: the app shares
   values with the sandboxed extension through the global preferences domain
   (`kCFPreferencesAnyApplication`, not an App Group). Added to
   `PreviewAppearanceStore`:
   - `measureKey = "com.ezzy.downright.quickLook.measureCharacters"`;
   - `measureCharacters: CGFloat?`, which reads the value and clamps it with
     `ReadingMeasure.clamped`. A missing or malformed value returns nil,
     meaning the theme's own measure;
   - `write(...)` takes a new `measureCharacters:` argument and stores it as
     a number next to the appearance and theme names.
10. Sources/DownrightApp/Support/Preferences.swift: both `write` calls (in
    `init` and `persist()`) pass `values.typography.measureCharacters`. The
    value is written at launch and on every settings save.
11. Sources/DownrightQL/PreviewViewController.swift, `makeStyleSheet()`: copies
    the resolved theme and, when the shared measure exists, sets
    `typography.measureCharacters` on the copy before building the
    `StyleSheet`.

Docs/QUICKLOOK.md also has a bullet under the appearance note saying the
preview measure follows the setting.

Tests updated:

- Tests/MarkdownRenderTests/ThemeTests.swift: bundled-theme test renamed
  ("Bundled themes ship a 68–72 character measure"); clamp test now expects
  400 to be honoured and 100_000 to clamp to `maximumCharacters`.
- Tests/DownrightAppTests/ReaderProfileTests.swift: 100 stays 100;
  100_000 clamps to `maximumCharacters`.

Left alone: DESIGN.md and code comments elsewhere still describe the 68–72
cap; bundled themes still default to 68–70.

## Still worth checking

- Footnote margin lane (windows >=1100pt) hides when <100pt is left; a
  very wide measure leaves no margin, so expect it to hide.
- Quick Look uses the same MarkdownContainerView and now applies the app's
  measure (items 9–11). Still true there:
  - the column can't be wider than the Quick Look panel;
  - in panels narrower than 900pt, a measure of 72 or less is tightened
    to 66;
  - an open preview doesn't change when Settings changes; the next preview
    picks up the new value.
  Check the shared value with
  `defaults read -g com.ezzy.downright.quickLook.measureCharacters`.
  Not yet checked: a real Finder Spacebar preview showing the wider column.
- NOT reviewed: table cell wrapping at very wide measures,
  TableFragment.swift:344 (proseCharacters is a per-cell limit, not the
  column width).
- The debug bench in check.sh reported semantic convergence p95 ~123 ms
  against a 100 ms budget. It is informational and did not fail the gate;
  not compared against an unpatched build.

## install.sh fix

Upstream v1.0.16's Scripts/install.sh never defines STAGED_APP, so the
install aborts with "STAGED_APP: unbound variable" right after
"==> Installing to /Applications/Downright.app". It fails before touching
the installed app, so nothing is lost. Fix: add this line directly after
the `STAGE_ROOT="$(mktemp -d ...)"` line (line 37 in v1.0.16):

    STAGED_APP="$STAGE_ROOT/Downright.app"

This is fixed in this checkout only. A fresh upstream download needs it
again unless upstream has fixed it; check with
`grep -n 'STAGED_APP=' Scripts/install.sh` (no output = still broken).

## Build and install on this Mac

Requires macOS 14+, Xcode, xcodegen (installed via Homebrew), Swift 6.

The active developer directory is now Xcode
(`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`), so
`DEVELOPER_DIR` is no longer needed. If xcodebuild ever says "requires
Xcode, but active developer directory ... is a command line tools
instance", export
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for the session.

    Scripts/check.sh                     # build + tests (not bare `swift test`)
    DOWNRIGHT_HOST_BUNDLE_IDENTIFIER=com.ezzy.downright Scripts/bundle-xcode-app.sh
    APP_SOURCE=.build-xcode/Build/Products/Release/Downright.app Scripts/install.sh

Quit Downright before installing; install.sh refuses while it is running.

Faster dev build without Finder extensions:

    Scripts/bundle-app.sh && open .build-main/bundle/Downright.app

## What the local install means

- A plain `Scripts/bundle-xcode-app.sh` build uses the bundle ID
  `com.ezzy.downright.acceptance`, which has its own preferences.
  The current install was built with
  `DOWNRIGHT_HOST_BUNDLE_IDENTIFIER=com.ezzy.downright`, the official app's
  ID, so it uses the official app's preferences and settings. Its
  extensions are registered as `com.ezzy.downright.quicklook` and
  `com.ezzy.downright.thumbnail`. The bundle is ad-hoc signed.
- Sparkle updates are disabled in local builds, so each new upstream
  release needs the patch reapplied and a rebuild.
- The official app (v1.0.16, build 305) is backed up at
  ~/Downloads/Downright-official-1.0.16-305.app; drag it back into
  /Applications to revert.
- The `down` CLI works through /opt/homebrew/bin/down, a symlink to
  /Applications/Downright.app/Contents/MacOS/down. The latest install also
  linked /usr/local/bin/down to the same binary. Earlier installs warned
  that /usr/local/bin was not writable; that warning can be ignored.
