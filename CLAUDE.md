# PRty Time

macOS menu-bar app (SwiftUI `MenuBarExtra`) that lists the GitHub PRs waiting on the user and notifies on activity. User-facing docs: README.md.

## Layout

- `Sources/PRtyTimeCore`: pure logic, unit-tested. `GitHubClient` (one GraphQL poll, `nodes(ids:)` lookup to tell merged from closed, REST notifications for read state; token from `gh auth token`), `ActivityDiff` (snapshot diff → notifications and unread dots), `Inbox` (clears dots for PRs read on GitHub), `StateStore`.
- `Sources/PRtyTime`: the app. `PRStore` runs the poll loop; `MenuContent` is the panel (`PRRow` its rows, `PanelState` its view state); `SettingsView`, `Notifier`, `MenuBarIcon`, `HotKey` (global shortcut).
- MenuBarExtra has no API to open its panel from code. `MenuBarPanel` (HotKey.swift) finds SwiftUI's status item through private AppKit: on macOS 27 it calls `_requestExpandedInterfaceSession` (the button has no action, so `performClick` does nothing); earlier it clicks the button. If the shortcut stops opening the panel after a macOS update, start there.
- `Tests/PRtyTimeCoreTests`: Swift Testing, Core only.
- The combined poll query takes ~8s against GitHub's ~10s timeout (on timeout it falls back to one request per search). Don't add fields to the search fragments; fetch extras with a separate `nodes(ids:)` query, as `details`, `mergeStatus` and `closedPRs` do.
- `make screenshots` renders the README's `docs/demo-{light,dark}.gif` and `docs/social-preview.png` (uploaded by hand in the repo's Settings → Social preview) from demo data, with `Sources/PRtyTime/Screenshot.swift` (only built with `-DDEMO`).
- `Scripts/icon.swift` draws `Resources/AppIcon.icns` (`make icon`). `MenuBarIcon.swift` draws the same glyph from the same 1024pt geometry; keep them in sync. SF Symbols can't be used in the app icon (license).

## Build

- Must build with only the Command Line Tools (no Xcode), Swift 6 language mode. There, `@State` doesn't compile (its macro plugin ships with Xcode), so view state lives in `@Observable` singletons (`PanelState`, `LoginItem`).
- `make test`, `make install` (builds, copies to `/Applications/PRty Time.app`, relaunches), `make logs`.
- CI (`macos-26` runner, Xcode 26 / Swift 6.3) is older than the local compiler and crashes on a method reference passed as a `Binding` setter; use a closure. `ci.yml` builds and tests every push to main and every PR on that runner.

## Don't rename

Bundle id, defaults domain and Logger subsystem stay `com.fragkakis.prty`; the state dir stays `~/Library/Application Support/Prty/` (the old app name). Renaming loses saved state, settings and notification permission. New `Snapshot` fields must decode with defaults so older `state.json` files still load (see `snapshotsSavedBeforeAutoMergeStillLoad`).

## Notification icons

A grey placeholder icon on notifications means IconServices couldn't read the bundle. `iconservicesd` runs as `_iconservices` and can't read inside `~`, so the app must live in `/Applications` (`~/Applications` and `.build/` don't work). The grey result is cached per bundle id and survives moving the app and restarting the user-level agents. Clearing the system cache should fix it; it needs root, so the user runs it: `sudo rm -rf /Library/Caches/com.apple.iconservices.store && sudo killall iconservicesd iconservicesagent usernoted NotificationCenter`.

To check without waiting for a notification, render `[[ISIcon alloc] initWithBundleIdentifier:]` (private `IconServices.framework`, `prepareImageForDescriptor:`) to a PNG. `NSWorkspace.icon(forFile:)` reads the file in-process and always looks fine.

## Releasing

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`; commit `chore: bump version to X.Y.Z`.
2. `git push origin main && git tag vX.Y.Z && git push origin vX.Y.Z`.
3. `.github/workflows/release.yml` builds the universal zip (version taken from the tag), creates the release with notes from `Scripts/release-changes.sh` (commit subjects since the last tag, minus chore/docs/test/ci, so write them for users) above `.github/release-notes.md`, and updates `Casks/prty-time.rb` in `fragkakis/homebrew-tap` through the `TAP_DEPLOY_KEY` secret (a deploy key with write access).
4. Check with `gh run watch`, then that the cask's `sha256` matches the release asset.

The app's daily update check reads `releases/latest`, so drafts and prereleases don't reach users.

The app is ad-hoc signed, not notarized, so users click Open Anyway on first launch. The official homebrew/cask repo would need notarization (Developer ID).
