<!-- Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com> -->
# Downright patches: wide column on the Mac, reading on iPhone and iPad

Patches and new files for [Downright](https://github.com/ezzy1630/Downright),
the native macOS Markdown reader and editor. They add two things upstream
doesn't have:

1. **A wider reading column on the Mac.** Upstream caps text at 68–72
   characters per line, however wide the window is. The width patch lets the
   setting go up to "Full width".
2. **A read-only Downright for iPhone and iPad** that uses the same
   rendering engine as the Mac app, so a document looks the same on both.

This repository contains **no Downright source files**. Downright is fetched
at a pinned commit (the `upstream` submodule), and `Scripts/assemble.sh`
applies this repository's patches and adds its new files to build a complete
source tree. Every file here was written by Claude Code as directed by Brad
Nicholas.

It is not affiliated with or endorsed by the Downright project. For the Mac
app itself, use [upstream](https://github.com/ezzy1630/Downright) and its
signed releases.

## Why this exists

Downright renders Markdown beautifully, and it was deliberately built for
macOS only: its `PRODUCT.md` says 1.0 does not target iOS, and its 72-character
cap is a design choice. I wanted two things it doesn't offer: wide-column
reading on a large display, and the same reading experience on an iPad.

Keeping the work as patches on an unmodified upstream means upstream
releases can be picked up, and either layer could be offered back upstream
or dropped if upstream adds the feature itself.

## Quick start

```bash
git clone --recurse-submodules <this repository>
cd <this repository>
Scripts/assemble.sh                   # everything -> work/
Scripts/assemble.sh --layer width     # Mac width patch only -> work/
```

`work/` is then an ordinary Downright source tree, and a git repository whose
commits are the layers' own commits, so `git log` and `git blame` there
explain every change. Build and test it the usual way from inside `work/`
(see [Building](#building)).

## Layout

```
upstream/          Downright, pinned to one commit (a submodule: a pointer, not a copy)
patches/width/     the width layer's changes to upstream files, in order
patches/ios/       the iOS layer's changes to upstream files, in order
overlay/ios/       files the iOS layer adds, at their paths in the source tree
docs/              plan, width-patch handoff, and the development workflow
dev/               tools for the layered development checkout
Scripts/           assemble.sh, verify.sh, export.sh
EXPORT             the commits this content was exported from
NOTICE, LICENSE    Downright's licence (the patches quote it), and this repository's
```

The two layers stack: **width** applies to upstream, and **ios** applies on
top of width. Each patch is a `git format-patch` file with its original
commit message, so the patches read as an explained change history. When a
new upstream release no longer fits a patch, `assemble.sh` stops and names
it, instead of building something half-applied.

## The width patch (macOS)

- **Settings:** the "Measure (characters)" setting, and the reader profile
  presets, go from 68 up to "Full width". Upstream clamped them to 68–72 in
  four places.
- **Large windows:** upstream forced 72 characters above 1,200pt and ignored
  the setting; the setting now applies at every window width. A narrow window
  still tightens a 68–72 measure to 66, as upstream does.
- **Quick Look:** previews follow the measure setting. Upstream's preview
  extension never read it.
- **Install script:** `Scripts/install.sh` failed with "unbound variable"
  because upstream never defined `STAGED_APP`.

Details: [`docs/WIDTH-PATCH-HANDOFF.md`](docs/WIDTH-PATCH-HANDOFF.md).

## The iPhone/iPad port

A document-browser app (`iOSApp/` in the assembled tree) that opens Markdown
from the Files app and "Open in…", using Downright's own parser and renderer.
iCloud Drive hasn't been tried yet.

**What works (read-only):**

- **Same rendering as the Mac:** headings, lists, tables, code with syntax
  colours, callouts, math, Mermaid diagrams, footnotes and front matter.
- **Reading tools:** Find, an outline, VoiceOver rotors, and hardware-keyboard
  shortcuts.
- **Windows:** several windows on iPad, and each window reopens at the place
  you were reading.
- **Settings** under Settings › Apps › Downright: appearance, themes, text
  size, line width (up to Full width) and Load Remote Images.
- **Images:**
  - remote images over HTTPS, including SVG badges;
  - images inside a line, such as README badges in a row;
  - `width` and `height` on `<img>`.
- **Live reload:** reloads when another app changes the file, follows renames,
  and never writes to your file.

**Not done yet:** editing, Quick Look and thumbnail extensions, Spotlight,
and animated GIFs (they show a still frame). See
[`docs/IOS-PORT-PLAN.md`](docs/IOS-PORT-PLAN.md).

**How it is built:**

- **Shared engine:** `MarkdownCore` and the shared half of `MarkdownRender`
  build for iOS. Platform types go through `MarkdownRender/Platform`, where
  each alias *is* the AppKit class on the Mac, so the Mac build is unchanged.
- **Reading view:** `MarkdownReaderView` is a UIKit text view on the same
  TextKit 2 content storage, display maps and drawing as the Mac's
  `MarkdownTextView`.
- **Mac unchanged:** iOS-only behaviour (inline images, HTML line joining,
  remote images) sits behind switches the Mac never turns on. Two shared
  fixes do reach the Mac: list items keep their spacing after re-decoration,
  and harmless HTML attributes such as `width` no longer turn a whole HTML
  block into raw source.
- **Comments:** comments in the patched source record what upstream did
  wherever these patches change it.

**Privacy:** the shared engine never makes network requests. Only the iOS
app fetches remote images, without cookies and with size and time limits, and
Settings can turn that off. The Mac app and Quick Look never fetch them,
as upstream.

## Building

Requirements: macOS 14+, Xcode, Swift 6 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
Assemble first, then work inside `work/`.

**Mac app:**

```bash
Scripts/assemble.sh --layer width     # or the full tree; both build the Mac app
cd work
Scripts/check.sh
DOWNRIGHT_HOST_BUNDLE_IDENTIFIER=com.ezzy.downright Scripts/bundle-xcode-app.sh
APP_SOURCE=.build-xcode/Build/Products/Release/Downright.app Scripts/install.sh
```

**iOS app:**

```bash
Scripts/assemble.sh
cd work
Scripts/check-ios.sh
cd iOSApp && xcodegen generate && open DownrightIOS.xcodeproj
```

The simulator and `check-ios.sh` need no Apple account. **To run on your own
device**, give the build your Apple team ID and a bundle prefix of your own.
Put them in a `Signing.local.xcconfig` at the top of this repository. Git
ignores it, so it never ends up in a commit, and `assemble.sh` copies it into
`work/iOSApp/` every time:

```bash
printf 'DOWNRIGHT_BUNDLE_PREFIX = com.yourname\nDEVELOPMENT_TEAM = ABCDE12345\n' > Signing.local.xcconfig
Scripts/assemble.sh
cd work/iOSApp && xcodegen generate && open DownrightIOS.xcodeproj
```

- **Team ID:** in Xcode › Settings › Accounts, or at developer.apple.com
  under Membership.
- **Bundle IDs:** they become `<prefix>.downright.ios` and
  `<prefix>.downright.ios.tests`. Without a local file, the placeholders in
  `iOSApp/Signing.xcconfig` apply: `com.example`, no team.
- **Why an optional include:** XcodeGen refuses to generate a project when a
  config file it lists is missing. So the committed `Signing.xcconfig` pulls
  the personal file in with Xcode's optional `#include?` instead. The full
  reasoning is in that file and in `docs/IOS-PORT-PLAN.md`.
- **Working in a layered checkout instead:** the same file goes in
  `iOSApp/Signing.local.xcconfig`; see `docs/DEV-WORKFLOW.md`.

## Verifying

```bash
Scripts/verify.sh            # nothing here is an upstream file; every file is attributed
Scripts/verify.sh --checks   # also assemble both layers and run every test gate
```

## Development

The patches are generated, not hand-edited. Development happens in a
layered git checkout of Downright (`main` = upstream, `width-patch`,
`ios-port`), described in [`docs/DEV-WORKFLOW.md`](docs/DEV-WORKFLOW.md).
`Scripts/export.sh <checkout>` regenerates `patches/`, `overlay/`, `docs/`
and `dev/` from it and moves the upstream pin. `dev/sync-upstream.sh` brings
a new upstream release into that checkout first.

To recreate such a checkout from this repository, assemble and use `work/`:
its commits are the layers' commits.

## Attribution

Every file in this repository is authored by Claude Code as directed by
Brad Nicholas <70774+bradn@users.noreply.github.com>, and says so near its
top. Each patch says so after its `---` line, where `git am` ignores it.
Images and JSON files can't hold a comment; this paragraph covers them.

In an assembled tree, upstream files that the patches change also carry a
"Modified by Claude Code as directed by Brad Nicholas" line. Every other
upstream file is Downright's, by its contributors.

## Licence and credit

This repository's own work is under the MIT licence in [`LICENSE`](LICENSE).
Downright is MIT-licensed by the Downright contributors; its notice is in
[`NOTICE`](NOTICE), because the patches quote short excerpts of it.
Downright's name and icon belong to the Downright project. Please don't
publish builds of this under the Downright name.
