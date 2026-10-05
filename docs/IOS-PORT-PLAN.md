<!-- Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com> -->
# Plan: Downright for iPadOS and iOS

Status: phases 1 and 2 are done and phase 3 (a read-only app) is started in
this checkout; phases 4–6 are still proposals. The
plan is based on the v1.0.16 source, read on 2026-10-04. The "Where things
stand" table describes the source before phase 1.

## Where things stand

Downright is a macOS-only AppKit app. `PRODUCT.md` says 1.0 does not target
iOS, and `Package.swift` / `project.yml` declare macOS as the only platform.
Compile checks against the iOS 27 SDK (Xcode, `generic/platform=iOS`):

| Part | iOS today | Notes |
|---|---|---|
| `MarkdownCore` (parse, source edits) | Builds as-is | No AppKit imports |
| `swift-markdown`, `SwiftMath` (vendored), `beautiful-mermaid-swift` | Declare iOS support | SwiftMath iOS 11+, BeautifulMermaid iOS 15+ |
| `MarkdownRender` (TextKit presentation) | Fails: needs AppKit | 60 files |
| `DownrightApp` (~48k lines) | Mac only | Windows, menus, Settings, Sparkle |
| Quick Look, thumbnail, Spotlight importer, `down` CLI | Mac only | Need iOS equivalents or are dropped |

Inside `MarkdownRender`, the engine is mostly portable already:

- `DisplayMap`, `ElisionPlan` and `MarkerPolicy` use no AppKit types; they
  only import it.
- `DecorationEngine` uses `NSFont` (5 places).
- `StyleSheet` uses `NSColor`, `NSFont`, `NSAppearance` and one
  `NSWorkspace` call.

The heavy AppKit use is in the view layer:

- `MarkdownTextView` and `MarkdownTextView+Interaction`: about 400 AppKit
  references, mostly `NSEvent`, tracking areas and the cursor.
- The density gutter, plus its outline and preview windows, which are
  `NSWindow`s.
- `GutterRailView`, `MarkdownContainerView`, `Motion`.

Across `MarkdownRender`: about 106 `NSColor`, 58 `NSFont`, 42 `NSEvent`,
39 `NSImage`, 19 `NSView`, 13 `NSAppearance`, 12 `NSTextView` and
5 `NSWindow` references.

## Decisions needed before any code

1. **Product contract.** Amend `PRODUCT.md` (and `AGENTS.md`, which calls
   Downright "a native macOS 14+" app) to admit iOS/iPadOS. Until then this
   is a fork-level experiment.
2. **Scope of the first release.** Recommended: a read-only viewer for
   iPad and iPhone, with editing as a later phase. Reading is where most of
   the shared code pays off; editing carries the hardest invariants (undo,
   autosave, external-write conflict) on a new file model.
3. **Minimum OS.** Recommended iOS/iPadOS 17. UITextView has TextKit 2 from
   iOS 16; 17 roughly matches the macOS 14 floor and trims compatibility
   work.
4. **Distribution.** iOS has no Sparkle and no DMG. It needs an Apple
   Developer Program team, App Store or TestFlight signing, and an App Store
   privacy label consistent with "no telemetry, no document upload". The
   macOS appcast request has no iOS counterpart; App Store updates replace
   it.
5. **Code sharing strategy.** Recommended: keep one `MarkdownRender` target
   with a small platform shim and `#if canImport(AppKit)` / `UIKit` view
   files, rather than a forked iOS renderer. One renderer is what keeps
   previews and the app from drifting today (see `Docs/QUICKLOOK.md`).

## Phase 1: make the shared engine multi-platform

Goal: `MarkdownCore` and the engine half of `MarkdownRender` build and test on
iOS, without changing macOS behaviour.

- Add `.iOS(.v17)` to `Package.swift` platforms.
- Introduce a platform shim in `MarkdownRender`: `PlatformColor`,
  `PlatformFont`, `PlatformImage`, `PlatformBezierPath`, and an appearance
  abstraction replacing direct `NSAppearance` checks.
- Port `StyleSheet`, `DecorationEngine`, `BlockStyle`, `RenderContracts`,
  themes and `ThemeValidation` to the shim. Move the `NSWorkspace` call in
  `StyleSheet` behind the Mac-only layer.
- Split `MarkdownRender` sources into engine (shared) and view (per
  platform) folders, or gate view files with `#if canImport(AppKit)`.
- Check fragment drawing (`FragmentBase`, table, code, callout, math, image,
  Mermaid bridge): TextKit 2 `NSTextLayoutFragment` exists on iOS, so most
  of it should port through the shim with Core Graphics drawing.

Acceptance:
- `MarkdownCore` and shared `MarkdownRender` build for iOS device and
  simulator.
- `MarkdownCoreTests` and the engine tests in `MarkdownRenderTests` run
  green on an iOS simulator, with a non-zero executed-test count.
- `Scripts/check.sh` still passes on macOS, and the macOS render output is
  unchanged.
- `DisplayMap` stays the only source↔display conversion on both platforms.

### Phase 1 result (2026-10-04)

Done:

- `Package.swift` declares `.iOS(.v17)`.
- `MarkdownRender/Platform/Platform.swift` is the shim:
  - aliases `PlatformColor`, `PlatformFont`, `PlatformFontDescriptor`,
    `PlatformImage` and `PlatformAppearance` (a `UITraitCollection` on iOS);
  - helpers for drawing contexts, display scale, failable font creation and
    image alpha;
  - on iOS only, the handful of AppKit colour/image/font methods the shared
    code calls, such as `usingColorSpace(.sRGB)`, the RGB component
    properties, `blended(withFraction:of:)` and `NSImage(size:flipped:)`.
- Shared files use the aliases. Where the SDKs differ they use
  `#if os(macOS)`; the Mac branch keeps the original code.
- The System theme's `system:` colour names map to UIKit semantic colours on
  iOS. `controlBackground` maps to `secondarySystemGroupedBackground`, white
  in light mode like the Mac; `secondarySystemBackground` failed the comment
  contrast floor.
- `View/` (apart from `MarkdownContentStorage` and `ParagraphSubstitution`),
  `Motion.swift` and `Theme/PreviewAppearance.swift` compile only on macOS.
- `FragmentContext.textView` is Mac-only. On iOS it holds `textStorage`
  instead, and images don't yet trigger a re-layout when they finish loading.
- `Scripts/check-ios.sh` does three things:
  - builds `MarkdownRender` for iOS devices;
  - runs `MarkdownCoreTests` and `MarkdownRenderTests` on the newest iPhone
    simulator;
  - fails if either bundle runs zero tests.

Acceptance, as run:

| Check | Result |
|---|---|
| `MarkdownCore` / `MarkdownRender` build for iOS devices and simulator | Pass, no warnings in `MarkdownRender` |
| `Scripts/check-ios.sh`, iPhone 18 Pro (iOS 27) | 385 tests (311 core, 74 render), pass |
| `Scripts/check-ios.sh`, iPad Air 11-inch (M4) | 385 tests, pass |
| `Scripts/check.sh` on macOS | Pass, 1382 tests, same count as before phase 1 |
| `DisplayMap` is the only source↔display conversion | Unchanged; it was already AppKit-free |

Gaps carried into phase 2:

- **Tests that stay macOS-only:** 18 of the 26 render test files are
  wrapped in `#if os(macOS)`. They drive the AppKit view layer, the
  pasteboard, or bitmap probes. Phase 2 needs iOS equivalents.
- **Drawing:** iOS fragment drawing compiles but has never been drawn
  on screen. In particular `withPlatformDrawingContext` ignores `flipped`
  on iOS.
- **Rendering identity:** "macOS render output unchanged" rests on the
  passing Mac render tests and on the Mac branches keeping the original
  code. No screenshot comparison was made.
- **Not decided:** the `PRODUCT.md` / `AGENTS.md` product contract and the
  minimum OS still need your decision. This phase didn't change them.

### Demo viewer (throwaway)

`Demo/iOSViewer/` is a small SwiftUI app (`xcodegen generate` in that folder,
then build the `DownrightViewerDemo` scheme). It shows the decorated text in a
plain TextKit 2 `UITextView`. Fonts, colours, headings, links, front matter
and light/dark already carry over. Syntax markers stay visible, and code
blocks, callouts, tables and math draw plainly. Those belong to the phase 2
surface. It is not the phase 2 surface and should be deleted once phase 2
exists.

### Phase 2 result (2026-10-04)

Built: `MarkdownRender/UIKitView/MarkdownReaderView.swift`, a read-only
`UITextView` using TextKit 2.

- **Shared pieces it uses:** `MarkdownContentStorage`, `ParagraphSubstitution`,
  `DecorationEngine`, `FragmentProvider` and every fragment. Markers are hidden
  through the same display map as on the Mac.
- **Code moved out of the Mac view:** `MarkdownTextView`'s read-mode map
  building is now `Engine/PresentationMaps.swift`, used by both views. It was
  moved verbatim; the Mac view now calls it.
- **Shared engine fix (affects the Mac):**
  - The problem: `DecorationEngine` replays cached "programs" for blocks it
    has seen before. A replayed paragraph style covered only the block, not
    the list marker before it, so TextKit's paragraph fixup took the marker's
    style.
  - The effect: list items lost their 6.5pt spacing on every re-decoration
    after the first.
  - The fix: replay now styles the whole paragraph, as the live path does.
  - The test: `DecorationReplayTests` runs on both platforms.
  - Not yet checked by eye in the Mac app.
- **iOS-only geometry:**
  - `RenderMetrics.codeBleed` is 0 on iOS: no trailing code lane.
  - The code band and front-matter card measure from the fragment's frame
    origin, because UITextView passes a different draw point than NSTextView.
  - The "Edit metadata" label is hidden.
  - The column is centred and sized through `textContainerInset`, which
    UITextView uses to size the container.
- **Interaction:**
  - Links go through `textView(_:primaryActionFor:defaultAction:)`.
  - The host's `linkHandler` gets each link first; otherwise `#anchor` links
    scroll to the heading and absolute URLs open in the system.
  - `sourceOffset(at:)`, `rect(forSourceOffset:)` and `link(at:)` convert
    through `DisplayMap`.
  - Selection and copy come from UITextView.
- **Tests:** `ReaderViewTests` (iOS only) checks:
  - the storage is the source verbatim;
  - markers are hidden;
  - link hit-testing;
  - anchor scrolling;
  - no style leak from a previous document;
  - same document, same layout;
  - wrapping inside the column on a wide view.

Checked by eye in the demo app on an iPhone 18 Pro and an iPad Air 11-inch
simulator (iOS 27), light and dark:

- front matter, headings, emphasis, inline code, links;
- bullets, numbered lists and tasks;
- quote, callout, code with highlighting and chip;
- table, inline and display math;
- thematic break, footnote reference.

Second round (2026-10-04, continued):

- **Scrolling:** UITextView sized its scroll content from TextKit's own
  estimate, 132pt for the sample, so every scroll sprang back to the top.
  - The reader now sizes the content itself, as the Mac view sizes its
    frame: full layout up to 4,000 paragraphs, an estimate that only grows
    above that, plus 40% of a screen below the last line.
  - The height is measured from the fragment holding the last character.
    After a rotation, both TextKit's usage bounds and a fragment walk
    reported positions from the old width, which made the page roughly 1.7×
    too tall.
  - The `contentSize` override keeps UITextView's later estimates from
    replacing it.
- **Scoped redraws:** an image arriving or a copy confirmation keeps the
  scroll position.
- **Code copy:**
  - The copy control is always shown on iOS, in the header row, with the
    language chip beside it instead of swapped for it on hover.
  - Tapping copies the code without its fences.
  - The fence-stripping helper (`CodeBlockFragment.codeText(of:in:)`) is now
    shared with the Mac.
- **Footnotes:**
  - Tapping a reference shows its definition in a popover, which stays a
    popover on iPhone. The hit area includes the neighbouring characters.
  - Hosts can take over with `footnoteHandler`.
- **Object taps:**
  - They use a separate gesture delegate. Making the reader its own gesture
    delegate also affected UITextView's internal gestures and blocked the
    tap.
  - Links still go through `textView(_:primaryActionFor:defaultAction:)`.
- **Images:**
  - `documentURL` is now the document's own file URL, as on the Mac. The
    first version passed its directory, so relative images resolved one
    level too high.
  - A bundled PNG renders upright and centred.
- **Diagrams and display math:**
  - `FragmentBase.columnOrigin(_:)` moves UIKit's per-fragment draw point
    back to the column edge. It is used by Mermaid, math, image, thematic
    break and table fragments, and is the identity on the Mac.
  - On iOS the Mermaid bridge makes the bitmap the current UIKit context, so
    labels draw.
- **VoiceOver:** `renderedText` (and `accessibilityValue`) is the document
  as shown, without `**`, `#` or link destinations. Only the value is
  covered; rotor navigation and per-object elements are not.
- **Tests:** `ReaderViewTests` now also covers:
  - copy target and copied text;
  - footnote lookup;
  - accessibility text;
  - scroll height and holding at the end;
  - rotation matching a fresh layout at the new size.

Checked in the demo app on an iPhone 18 Pro simulator:

- scrolling holds;
- copy button (the simulator clipboard had the code without fences);
- footnote popover;
- image;
- labelled diagram;
- centred display math.

Third round (2026-10-04, continued):

- **Outline (document map for touch):**
  - `MarkdownReaderView.outline`, `currentOutlineIndex` and
    `topVisibleSourceOffset`.
  - `ReaderOutlineController` lists the headings, indented by level, with
    the current section checked. Choosing one scrolls there and closes the
    list.
  - The demo shows it in a SwiftUI sheet; presenting it by hand from SwiftUI
    did not appear.
  - The Mac's hover rail is not ported; the outline replaces it on touch.
- **VoiceOver rotors:** "Headings" and "Links" custom rotors step through the
  document. Their targets are text ranges reached through `DisplayMap`; a
  link target is its text, not the hidden bracket.
- **Split View / Slide Over widths:** at 320, 507, 694 and 1032pt the text
  stays inside the column and the scroll height covers the document.
- **Large documents** (Debug build, iPhone 18 Pro simulator; printed, not
  asserted; simulator times are not device times):

  | Document | Size | Open + first layout | Slowest of 8 scroll jumps |
  |---|---|---|---|
  | Full layout | 2,281 lines | 0.28s | 58ms |
  | Estimated height (over budget) | 5,321 lines | 0.53s | 36ms |

  Both scroll to their last line. The estimated height grows as layout
  arrives.
- **Tests:** `ReaderViewTests` has 17 tests.

Not done or not verified:

- **README HTML:** README HTML stays raw where the shared `SafeHTML` parser
  rejects a block (for example `<a>` wrapping a sized `<img>`) or keeps
  remote images inert. A macOS probe showed the same classification, so this
  matches the Mac; it is not a trust or iOS gap.
- **Accessibility:** per-object accessibility elements (code, table, math,
  diagram) are missing, and no VoiceOver session has been run by hand.
- **Copy confirmation:** the copied checkmark (0.9s) was not caught on
  screen.
- **Performance:** no real device, and no first-frame or frame-rate
  measurement.
- **Resizing:** rotation and Split View widths are covered by tests, not by
  turning a simulator or live multitasking.

## Phase 2: a UIKit reading surface

Goal: a `MarkdownTextView` equivalent on UITextView/TextKit 2, read-only.

- Build a UIKit view using `UITextView(usingTextLayoutManager: true)` that
  hosts the same content storage, `DisplayMap` and fragment provider. Keep
  the one-TextKit-2-surface architecture.
- Replace mouse-specific behaviour:
  - hover and tracking areas → `UIPointerInteraction` / hover gestures
    (iPad pointer);
  - clicks → tap gestures;
  - cursor changes → pointer styles;
  - task checkbox hit-testing → tap targets of at least 44pt.
- Rebuild the density gutter / document map. Its outline and preview are
  separate `NSWindow`s on the Mac; on iOS use in-view overlays or
  `UIPopoverPresentationController`.
- Footnote margin lane, gutter rail and `Motion` animations: port or drop
  per size class.
- Reading measure: reuse `ReadingMeasure` and the responsive-measure logic
  from `MarkdownContainerView`, sized for compact vs regular width.

Acceptance:
- Every Markdown construct in the existing render fixtures renders on an
  iPad and iPhone simulator. Light and dark mode both match the macOS
  theme colours.
- Scrolling a large fixture stays smooth on a real device, measured
  against `Docs/PERFORMANCE.md` layout and scroll budgets, reported by
  layer.
- Text selection and copy work, and links open.

## Phase 3: iOS app shell (read-only)

- New iOS app target in `project.yml`, with its own bundle ID and the
  Markdown UTI declarations.
- Open files through the Files app: `UIDocumentBrowserViewController` or a
  SwiftUI `DocumentGroup` hosting the UIKit reader. Handle security-scoped
  URLs, iCloud Drive and third-party providers.
- Watch for external changes with `NSFilePresenter`/`NSFileCoordinator`.
  Reload on change; never write to the file in read-only mode.
- Settings: theme, light/dark, text size, measure. The Mac's
  `Preferences` JSON can be the model; storage is the app container.
- iPad: multiple windows (scenes), Split View / Stage Manager resizing,
  hardware-keyboard shortcuts (`UIKeyCommand`), including `n`/`p` heading
  jumps.

Acceptance:
- Open, reopen, rename and delete a document from Files. A deleted or
  renamed file is handled; it is never silently recreated.
- An external edit to an open file shows up without data loss.
- Rotation, resize and multitasking keep the reading anchor.

### Phase 3 result (2026-10-04)

`iOSApp/` holds a read-only Downright app for iPhone and iPad.

- **Its own XcodeGen spec:** `iOSApp/project.yml`, run `xcodegen generate`
  there. It is kept out of the root `project.yml` so the Mac release pipeline
  (`bundle-xcode-app.sh`, signing, Sparkle) cannot be affected. Merging into
  one project is a later decision.
- **Identity:** bundle ID `<prefix>.downright.ios`, version 0.1, iOS 17+.
  The prefix and the signing team come from `iOSApp/Signing.xcconfig`
  (placeholders: `com.example`, no team) and a git-ignored
  `Signing.local.xcconfig` holding each builder's own values. The state
  restoration activity type is derived from the bundle ID.
  - **Decision: an optional include, not XcodeGen's `configFiles`.**
    XcodeGen refuses to generate a project when a file listed under
    `configFiles` is missing (checked: "Spec validation error: Invalid config
    file"). Listing the personal file there would leave everyone without one,
    and `Scripts/check-ios.sh`, with no project. So `configFiles` names the
    committed `Signing.xcconfig`, which ends with Xcode's optional
    `#include? "Signing.local.xcconfig"`.
  - **Rejected alternatives:**
    - Environment variables read by `project.yml`: easy to lose between
      shells, and invisible in Xcode.
    - A template the builder copies and renames: the simulator build would
      then need setup.
  `Config/version.env` is not wired in yet.
- **Opening files:**
  - The root is `UIDocumentBrowserViewController`: Recents, iCloud Drive,
    On My iPhone, and a "Downright" folder of its own (`UIFileSharingEnabled`).
  - Markdown (`net.daringfireball.markdown`, declared as an imported type) is
    opened in place as a Viewer; other files are greyed out.
  - "Open in" from other apps arrives through the scene delegate.
  - Multiple scenes are enabled, so iPad windows each hold a document.
- **Document model:** `MarkdownDocument`, a `UIDocument` subclass.
  - It decodes with `MarkdownCore.DocumentIO`, the Mac's rules: BOM,
    UTF-16/32 sniffing, UTF-8, then Latin-1. An undecodable file is an error,
    not an empty page.
  - `contents(forType:)` throws, so the app cannot write.
  - UIDocument reloads after coordinated outside edits and follows renames.
  - Deletion keeps the last text on screen with a notice (also announced to
    VoiceOver) and is never undone.
- **Document screen:** `DocumentViewController` hosts `MarkdownReaderView`.
  - Done, Outline and Find buttons (plus Open in New Window on iPad).
    App-wide settings live in the Settings app, not on this toolbar.
  - Keys: `n`/`p` for next/previous heading, ⌘O for the outline, ⌘W to
    close.
  - A reload keeps the reading position by source offset.
- **Settings:** in Settings › Apps › Downright (`Resources/Settings.bundle`).
  `ReaderSettings` holds appearance (System/Light/Dark), light and dark
  themes, text size (−4…+10pt in steps of 2) and line width (68, 70, 72, 90,
  120 characters or Full width, the Mac's presets).
  - Stored as one UserDefaults key per setting, the keys the Settings bundle
    uses. Values saved by earlier builds as one JSON blob migrate once; odd
    stored values snap to the nearest choice.
  - Applies to every open document, live within the app and on returning
    from the Settings app.
  - `ReaderSettingsTests` checks the static Settings plist against the code:
    keys, theme names, choices and defaults.
  - A forced appearance also restyles the app's bars.
- **Tests:** `DownrightIOSTests`, 14 tests, now part of
  `Scripts/check-ios.sh`.
  - Document model: decoding, never writing (bytes and modification date),
    reload after a coordinated edit, deletion, rename, and an undecodable
    file.
  - Settings: application, clamping, theme choice and persistence.
  - Document screen: reload position and heading keys.
  - Outside edits are made on a background queue. A coordinated write from
    the main thread deadlocks against the open document, which a real other
    app, being another process, never would.

Checked by hand on the iPhone 18 Pro simulator:

- browse to On My iPhone › Downright and open Sample;
- the full rendering;
- Settings: Dark and text size +2 applied live;
- Done returns to the browser, and the file's modified time is unchanged.

Second round (2026-10-04, continued):

- **Reopening:**
  - Each window remembers its document (by bookmark, which follows renames)
    and its place (by source offset) through scene state restoration.
  - A deleted file is not restored and never recreated.
  - Checked on the iPhone simulator by sending the app to the background,
    stopping it and relaunching: Sample reopened near the same section.
- **Opening race:** `MarkdownDocument.reloadIfChangedWhileOpening()`
  rereads the file if it is newer than the version read during opening,
  which closes the gap noted above.
- **Find:**
  - UITextView's find interaction is on, from a toolbar button and ⌘F.
  - Checked: "bullet" found 1 of 3.
  - The current match can sit behind the find bar rather than being
    scrolled clear of it.
- **Title and icon:** the file name now shows as the title, and the app has
  an icon (from `Resources/AppIcon.png`).
- **"Open in Downright":**
  - The browser's reveal step failed for a file in the app's own folder
    ("DocumentManager error 1"), and the app showed an error.
  - It now opens any readable file even when the reveal fails. It never
    imports, which would copy the file.
  - Checked on the iPad Air simulator by opening a file URL.
- **README HTML:** the README's raw HTML is the shared `SafeHTML`
  classification, the same on the Mac (see phase 2), not a trust gap. Trust
  on the Mac governs actions (remote images, external links), not tag
  hiding.
- **Tests:** `DownrightIOSTests` has 21 tests, adding:
  - restoration state round trip, rename and deletion;
  - the open race, and no reload when nothing changed;
  - a restored window's position;
  - Find and its key.

Third round (2026-10-04, continued):

- **Find:**
  - The reader now ends at the keyboard layout guide, so a match scrolls
    clear of the keyboard and the find bar.
  - Checked: "comment" inside the code block landed above both.
  - With no keyboard the page still runs to the bottom edge
    (`usesBottomSafeArea = false`); the first attempt left a black bar
    there.
- **iPad windows:**
  - A ⋯ › "Open in New Window" item (iPad only) opens the same document,
    at the same place, in another scene. It uses the reading state, through
    `requestSceneSessionActivation`.
  - Checked: the system's hidden-window count went from 2 to 4.
  - A scene restored after the app restarted reopened Sample.
  - The panel could tap the iPad this round.
- **Version:** `Scripts/check-ios.sh` reads `Config/version.env` and passes
  `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` to the app build.
  `project.yml` keeps 0.1 (1) only as the default for builds that pass
  nothing.

Not done or not verified:

- **Files app rename:** an attempt to rename the open file in Apple's
  Files app on the simulator did not get as far as an edit field; the menu
  closed. Following a real other app's rename is still covered only by the
  coordinated-move test.
- **iPad multitasking:** Stage Manager and Split View with two Downright
  windows side by side, not exercised. The window overview did not open
  from the simulator.
- **iCloud Drive:** not tried.
- **Contract:** `PRODUCT.md` / `AGENTS.md` still describe a macOS-only
  product.

## Phase 3 follow-up: images

Done (iOS only; the Mac renders exactly as before):

- **Remote images:** `https:` images load through a `RemoteImageLoading` the
  iOS reader installs; the engine never touches the network. Cookie-free,
  size- and time-limited, SVG drawn by a hidden, script-free WebKit view.
  Settings › Apps › Downright › Load Remote Images, on by default.
- **Inline images:** images inside a line (badges, `[![…](…)](…)`, an
  `<img>` in `<a>` or `<p>`) become attachments through
  `InlineImageDisplay`. Alt text stands in until a picture loads; links
  stay tappable; `width`/`height` on `<img>` are honoured.
- **HTML paragraphs:** a `<p>` or heading written one element per source
  line reads as one line, as on GitHub (`HardWrapReflow`'s HTML join), so
  README badge rows sit side by side.
- **Tall inline pictures** raise their paragraph's line height instead of
  overlapping the text above.

**Animated GIFs (built 2026-10-05; iOS only, the Mac keeps still frames):**
GIF, animated PNG and animated WebP play in the iOS reader: local or remote,
block or inline. Code: `UIKitView/AnimatedImage.swift`.

- **Decoding streams; the planned frame budget was dropped.** The README demo
  GIF is 150 frames of 800×450, 216 MB if decoded up front, so a per-image
  budget would have meant a ~300px-wide picture or a still. Instead, as
  browsers do:
  - every decode path keeps producing a single still frame, carrying an
    `AnimatedImageSource` (frame count, delays, loop count) attached to it;
  - `AnimatedImageView` decodes the next frame on a background queue shortly
    before it is due, at its own on-screen pixel size, and keeps about two
    frames in memory.
- **Timing:**
  - delays come from the unclamped GIF/APNG/WebP properties, with browsers'
    rule that 10 ms or less plays as 100 ms;
  - loop count 0 plays forever; n plays n times, then rests on the last
    frame.
- **Playback is a live view over the picture, for block and inline alike.**
  - Block images: `ImageFragment` draws the matte and shadow, skips the
    still, and asks the reader to place the view over its rect.
  - Inline images: the attachment keeps its space but shows nothing, and the
    reader places the view over `frameForTextAttachment`. TextKit's own
    attachment views (`NSTextAttachmentViewProvider`) were tried first: the
    provider's view was created but never hosted in a window, reliably, by
    this reader's custom layout fragments.
  - The reader clears the overlays on every rebuild, and drawing re-places
    the ones still needed.
- **Runs only when worthwhile:**
  - in a window and on screen; off screen it keeps its frame without
    decoding;
  - not with the app in the background;
  - not with Reduce Motion on: then stills, and the reader rebuilds when the
    setting changes.
- **Tests:** `AnimatedImageTests` (shared, iOS) and
  `RemoteImageLoaderTests`. They cover:
  - timing, the zero-delay rule and loop counts from a generated GIF;
  - single-frame images staying still;
  - the frame sequence, forever and finite;
  - bounded frame decode;
  - one live view each for block and inline GIFs, and none with Reduce
    Motion;
  - remote GIFs carrying their animation.
- **Checked by hand (iPad simulator):** the README demo GIF as a block image
  and an inline remote GIF both animate, aligned with their space.

Still to do:
- Tap to play when Reduce Motion is on (the plan's intent); today it shows
  the still only.
- A real device, scrolling while it plays, and a large document full of
  GIFs: placing inline overlays lays the document out up to each one.

## Phase 4: editing

Only after phases 1–3 are stable.

- Source editing on the UIKit surface, keeping the invariants in
  `AGENTS.md`:
  - raw bytes are authoritative;
  - offsets are in source UTF-16;
  - typing does not trigger a whole-document rebuild;
  - edits invalidate all shifted ranges and fragments;
  - undo boundaries are explicit.
- iOS text input specifics: marked text / IME, autocorrect and smart
  punctuation off by default for source, the software keyboard's input
  accessory bar for Markdown syntax, and the iPad hardware keyboard.
- Save via `UIDocument` or coordinated writes. Needs focused coverage for:
  - clean and dirty states;
  - autosave;
  - own-write suppression;
  - external-write conflict review;
  - write failure (never reported as "no change");
  - Discard.
- Typing latency on device against the 8 ms typing budget.

## Phase 5: system integration

- **Quick Look:** an iOS preview extension (`QLPreviewingController`,
  UIKit) using the shared renderer, with the same memory discipline as
  `DownrightQL`. The ceiling on iOS may be lower; measure on device.
- **Thumbnails:** a `QLThumbnailProvider` extension.
- **Search:** Core Spotlight indexing from the app using
  `DownrightSpotlightMetadata` (it is AppKit-free), in place of the Mac
  `.mdimporter`.
- **Dropped on iOS:** the `down` CLI, Sparkle, the agent hook
  (`drdownright` install), and Mac menu-bar-only features. List them in
  `PRODUCT.md`.
- **Sharing:** share sheet export (HTML/PDF if `HTMLExporter` ports), and
  open-in from other apps.

## Phase 6: validation, docs and release

- Extend `Scripts/check.sh` (or add `Scripts/check-ios.sh`) to:
  - build the iOS targets;
  - run the shared test suites on a simulator;
  - fail on zero executed tests.
- Add iOS simulator acceptance for the reading journey: launch, first
  frame, scroll, rotate, dark mode, Dynamic Type and VoiceOver basics.
- Update `Docs/ARCHITECTURE.md` with the platform split and the iOS app.
- Update `Docs/PERFORMANCE.md` with device budgets.
- Update `Docs/RELEASE.md` with TestFlight/App Store steps distinct from
  the signed DMG/Sparkle path.
- Update `Docs/QUICKLOOK.md` with the iOS extensions.
- Update `AGENTS.md` with iOS surfaces and evidence gates.
- `Config/version.env` stays the version source; App Store build numbers
  must also increase monotonically.

## Publishing: a patch repository, not a fork

Status: **built (2026-10-05)** at `Downright-patches`, next to this checkout;
not pushed yet. The layered branches here remain the development workspace.

Result:

- **Export:** the width layer is 3 patches over 14 upstream files; the iOS
  layer is 6 patches over 72 upstream files plus 35 new files in
  `overlay/ios`. The width layer adds no source files: its new files are docs
  and tools, which export to `docs/` and `dev/`.
- **`Scripts/verify.sh --against` passes:**
  - no file in the repository is an upstream path;
  - every file carries the attribution tag (`.gitmodules` included), except
    the PNG and JSON files;
  - each assembled layer is identical to its branch, executable bits
    included, apart from those docs and tools.
- **Additions beyond the plan:** `verify.sh` also checks the export isn't
  stale, and `assemble.sh` produces a git repository whose commits are the
  layers' commits.
- **Licence:**
  - `LICENSE` is MIT, held by Brad Nicholas, for this repository's own work;
    a default that is easy to change.
  - `NOTICE` reproduces Downright's MIT notice, clearly marked as
    upstream's. It is the one piece of Downright text in the repository,
    there because its licence requires it.

The public repository should hold only content authored by Claude Code as
directed by Brad Nicholas. Upstream Downright is fetched and patched at build
time.

### Options considered

Measured on `ios-port` (2026-10-05): the fork adds 41 files and modifies 80
upstream files; 470 upstream files are untouched.

| Option | Downright content in the repo | Upstream changes on sync |
|---|---|---|
| A. Full fork (today's branches) | All 550 upstream files | Rebase; conflicts surface |
| B. Overlay: our new files plus full copies of the 80 modified files | 80 whole files, ~31,600 lines, mostly unmodified upstream code | Copies silently overwrite upstream's newer versions; no conflict is ever reported |
| C. Patches: our new files plus diffs for the 80 modified files | None as files; the diffs carry ~2,100 lines of upstream context and replaced lines around 1,363 lines of ours | Patches fail loudly on conflict, like a rebase |

**Recommendation: C.**

- Every file in the repository is our own work, so every file can carry
  the "Authored by" tag and no upstream file needs a "Modified" tag.
- It avoids B's real danger: on an upstream update, a full-file copy would
  quietly undo upstream's fixes in those 80 files, and nothing would say so.
  A patch that no longer applies stops the build.
- Upstream's GitHub workflows, `FUNDING.yml` and branding never enter the
  repository. That settles the earlier pre-push questions about CI,
  releases and the Sponsor button.
- A diff's context lines are short excerpts of MIT-licensed code, and
  `NOTICE` credits upstream and reproduces its licence.

### Layout

```
upstream/               git submodule: ezzy1630/Downright, pinned to a commit
                        (stores a pointer, not Downright's files)
overlay/                files the fork adds, at their paths in the upstream tree
                        (iOSApp/, Sources/MarkdownRender/Platform/, Scripts/check-ios.sh, …)
patches/width/NNNN-*.patch   changes to upstream files, width layer, in order
patches/ios/NNNN-*.patch     changes to upstream files, iOS layer, in order
Scripts/assemble.sh     builds work/ (ignored): copy upstream at the pin,
                        copy overlay/, `git apply` width then ios patches;
                        `--layer width` stops after the width layer
Scripts/export.sh       regenerates overlay/ and patches/ from the local
                        layered branches (`git format-patch`, new files copied)
README.md, NOTICE, GIT-WORKFLOW.md, IOS-PORT-PLAN.md, WIDTH-PATCH-HANDOFF.md
```

- **Two layers stay separate:** `assemble.sh --layer width` gives the Mac
  app with the width patch only; the default gives everything.
- **Where development happens:** in the local layered branches, as now.
  `export.sh` turns them into `overlay/` and `patches/`, so the published
  repository is generated, never hand-edited.
- **Tagging:**
  - `overlay/` files keep their "Authored by" header.
  - Each patch file starts with the tag in its preamble, which `git apply`
    ignores.
  - The "Modified by" lines the patches add to upstream files stay, so an
    assembled tree still shows which files the fork changed.

### Steps

1. Approve this section, or pick A or B instead.
2. Write `Scripts/export.sh`:
   - copies the files the fork added into `overlay/`;
   - writes `git format-patch --no-renames` per layer for the modified
     files only, with the attribution preamble;
   - drops new files from the patches, since `overlay/` holds them.
3. Write `Scripts/assemble.sh` and a CI-free check: assemble at the pin,
   then run `Scripts/check.sh` (width layer) and `check.sh` plus
   `check-ios.sh` (full) inside `work/`.
4. **Upstream updates:**
   - `Scripts/sync-upstream.sh` keeps rebasing the local branches.
   - `export.sh` then refreshes the patches and bumps the submodule pin
     in one commit.
5. Rewrite `README.md` and `GIT-WORKFLOW.md` for the patch layout. Today's
   README describes branches.
6. Create the GitHub repository (not a GitHub fork, so it holds no upstream
   history) and push. Pushing waits on explicit approval.

### Acceptance

- The repository has no file from upstream Downright. Checked with a
  script: no overlay path exists in the pinned upstream tree, and every
  file carries the "Authored by" tag except the PNG icons and asset JSON,
  which `GIT-WORKFLOW.md` covers.
- A fresh clone with `git submodule update --init`, then `assemble.sh`, then
  the checks gives the same results as the local `ios-port`: same test
  counts, all passing.
- The assembled tree has the same contents as `ios-port`, and
  `assemble.sh --layer width` has the same as `width-patch`.
- Moving the pin to an upstream commit that conflicts with a patch makes
  `assemble.sh` fail and name the patch.

### Costs

- Building needs the submodule, so cloning needs network access to
  GitHub once.
- Patches are harder to read than files. The README links to the local
  branch layout and the per-file comments explain each change.
- Two representations (local branches and exported patches) have to be kept
  in step. `export.sh` is the only writer, and the acceptance check compares
  them.

## Risks and open questions

- **TextKit 2 differences.** UITextView's TextKit 2 behaviour (fragment
  drawing, selection, scrolling large documents) differs from
  NSTextView's. Prove phase 2 on the largest fixture before investing in
  the app shell.
- **Memory.** The iPhone and the iOS Quick Look extension have tighter
  limits. Mermaid and math rendering may need lower caches than
  `BoundedImageCache` uses on the Mac.
- **Pointer-first features.** The hover-driven document map and hover
  cards need a touch-first redesign, not just a port. Treat it as a
  `DESIGN.md` change.
- **Shared target risk.** A shared `MarkdownRender` can break the Mac
  app. Every phase 1 change must keep the macOS gate green and its
  rendering unchanged.
- **Maintenance.** This checkout carries a local width patch
  (`WIDTH-PATCH-HANDOFF.md`). An iOS port is a much larger divergence from
  upstream. Decide whether it belongs upstream before starting.

## Suggested first step

Do phase 1 only: get the shared engine building and tested on an iOS
simulator, behind the platform shim, with the macOS gate still green. It is
useful on its own, keeps the Mac app unchanged, and shows whether the
renderer really ports before committing to an app.
