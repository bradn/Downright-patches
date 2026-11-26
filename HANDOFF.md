<!-- Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com> -->
# Handoff: resuming Downright-patches on a new Claude account

Written 2026-11-26, when Brad moved from a personal Claude account to a
Team account with a different email address. Nothing from the old
account carries over: not the chat history, cloud sessions, artifacts,
scheduled tasks, or saved environments. This file and the git history are
the record. Read it first, then `README.md`.

## Setting up the new account

1. Connect GitHub to the new Claude account (claude.ai Settings ›
   Connectors) and give it access to `bradn/Downright-patches`. The
   GitHub account itself doesn't change, so commits stay under
   `bradn` / `70774+bradn@users.noreply.github.com`.
2. Before creating a cloud environment, check whether the Team
   organization limits network access. The repository only needs
   github.com, for the repo and the `upstream` submodule at
   `github.com/ezzy1630/Downright`.
3. Mac builds and tests still need the Mac: Xcode, the simulator, and
   `/Applications`. A cloud session can edit this repository and run
   `Scripts/verify.sh` (content checks only), but nothing that builds.
   Use Claude Code on the Mac, or attach the Mac's folder through Remote
   Control in the Claude desktop app.
4. Old desktop sessions may have stored local Claude Code settings, such
   as per-project permissions, in the layered checkout's `.claude/`
   folder. Those stay on disk and work with any account.

## Where things are

| What | Where |
|---|---|
| This patch repository | `github.com/bradn/Downright-patches`, branch `main` (1872f99) |
| Unmerged branch | `main-2fgoft`: `main` plus `.DS_Store` in `.gitignore` and this file. Merge or open a PR; nothing else is on it. |
| Upstream pin | `upstream` submodule at 9be0680 (Downright v1.0.16) |
| Layered dev checkout | On the Mac only: branches `main` (upstream), `width-patch`, `ios-port`. See `docs/DEV-WORKFLOW.md`. Its path isn't recorded here; it's the folder whose `upstream` remote is `ezzy1630/Downright`. |
| Exported tips | `EXPORT`: width-patch 9ef39c5, ios-port 127f08b |
| Installed app | `/Applications/Downright.app`, a local Release build (1.0.16, build 308) |
| Official app backup | `~/Downloads/Downright-official-1.0.16-305.app` (drag it back to revert) |
| `down` CLI | `/opt/homebrew/bin/down`, a symlink into the installed app |

Ignore the stray ref `refs/claude-teleport/f090167bbe528e5a` on GitHub.
It points at a throwaway snapshot commit that held only a `.DS_Store`.
It's safe to delete.

## What's done

**Width patch (Mac):** done. The "Measure (characters)" setting goes from
68 up to "Full width" (1000), large windows follow the setting instead of
forcing 72, Quick Look follows it too, and the upstream `install.sh`
`STAGED_APP` bug is fixed. Details and the full patch checklist are in
`docs/WIDTH-PATCH-HANDOFF.md`.

**iOS/iPadOS port (read-only):** phases 1–3 and the images follow-up are
done. That means the shared engine, a UIKit reading view, the app shell,
Settings, live reload, and animated images. Status and decisions are in
`docs/IOS-PORT-PLAN.md`.

**Last recorded results:** on the Mac, `Scripts/check.sh` passed with 688
tests in 72 suites, and `Scripts/check-ios.sh` passed with 403 iOS tests.

## What's left, in priority order

1. **Check the wide column by eye on the Mac.** This has never been done.
   - Open Settings, set Measure to 120 and then Full width, widen the
     window, and confirm the column follows.
   - Press Space on a `.md` file in Finder and confirm the Quick Look
     preview uses the same width. The shared value is readable with
     `defaults read -g com.ezzy.downright.quickLook.measureCharacters`.
   - Look at a document with tables at a very wide measure. Table cell
     wrapping (`TableFragment.swift:344`) hasn't been reviewed.
   - Expect the footnote margin lane to hide when the column leaves less
     than 100pt of margin.
2. **Confirm which build is in /Applications.** The notes disagree. One
   says the bundle ID is `com.ezzy.downright.acceptance` (built from
   ios-port 06fb06a), the other says `com.ezzy.downright` (shares the
   official app's settings). Check with
   `/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' /Applications/Downright.app/Contents/Info.plist`.
   For daily use, rebuild from `width-patch` with
   `DOWNRIGHT_HOST_BUNDLE_IDENTIFIER=com.ezzy.downright` (steps in
   `README.md` › Building).
3. **The benchmark miss.** `check.sh`'s debug bench reports "document
   updates" / semantic convergence p95 at about 123–124 ms against a 100 ms
   budget. It's informational and doesn't fail the gate. The patches don't
   touch that code path, but nobody has compared it with an unpatched
   build. To check, run the bench on `main` and on `width-patch`.
4. **Docs, if the width patch is kept.** Upstream's `DESIGN.md` and some
   code comments still describe the 68–72 cap. Update them on
   `width-patch`, then re-export.
5. **iOS next phases** (`docs/IOS-PORT-PLAN.md`): tap-to-play for animated
   images under Reduce Motion, trying iCloud Drive, Quick Look and
   thumbnail extensions, and Spotlight (phase 5). Editing is phase 4 and
   is the largest piece.

## How changes flow

Never hand-edit `patches/`, `overlay/`, `docs/` or `dev/`. They're
generated.

1. Work in the layered checkout on the Mac, on `width-patch` or
   `ios-port`. Rebase `ios-port` onto `width-patch` after changing it.
2. Run `Scripts/check.sh` there, plus `Scripts/check-ios.sh` for iOS.
3. From this repository, run `Scripts/export.sh <checkout>`, then
   `Scripts/verify.sh --against <checkout>`.
4. Commit and push here.

Every file in this repository needs the attribution line near its top
("Authored by Claude Code as directed by Brad Nicholas"). `verify.sh`
fails without it. For new upstream releases, run `dev/sync-upstream.sh`
in the checkout first.

## Mac build gotchas

- If `xcodebuild` says the active developer directory is a command line
  tools instance, export
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Quit Downright before running `install.sh`. It refuses to install while
  the app is running.
- Local builds have Sparkle updates disabled. Each upstream release needs
  a re-sync, re-export and rebuild.

## Prompt to start the next session

> Read HANDOFF.md, README.md and docs/WIDTH-PATCH-HANDOFF.md in
> bradn/Downright-patches. Then help me with item 1 of "What's left":
> checking the wide reading column in the installed Mac app and in Quick
> Look.
