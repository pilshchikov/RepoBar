# RepoBar — local fixes

Patches to RepoBar's menu rendering and refresh behaviour. Not upstream; lives in this checkout only.

## What's fixed

### 1. Open submenu no longer collapses on data refresh
Before: a background refresh while you were hovering inside a repo submenu tore down the parent menu items, closing the submenu and resetting navigation.

After: menu rebuilds reuse the same `NSMenuItem` and `NSMenu` instances and only insert/remove the rows that actually changed. The submenu under your cursor stays open.

### 2. PR/Issue filter chips (Mine/All, labels) no longer close the submenu
Before: clicking Mine/All posted a filter-change notification, which rebuilt the menu and recreated the filter chip's `NSMenuItem`. AppKit treats "highlighted item disappeared" as a reason to close the menu.

After: SwiftUI-hosted chips are recognised as reusable across rebuilds (they're already reactive to `Session` state), so the same `NSMenuItem` instance is kept and the menu stays open while you flip filters.

### 3. No more refresh-on-every-click of the status bar
Before: opening the menu kicked off a fresh GitHub round-trip if the last data was older than 30s.

After: data refreshes only on the background scheduler (Preferences ▸ Refresh interval, default 5 min). Opening the menu just renders the latest snapshot. If you want shorter/longer, change the setting.

## Files touched

- **new** `Sources/RepoBar/StatusBar/MenuReconciler.swift` — identity-based `NSMenu.reconcile(with:)` diff
- **new** `Tests/RepoBarTests/MenuReconcilerTests.swift` — 11 tests for the diff (insert/remove at start/middle/end, no-op, submenu preservation, swap)
- `Sources/RepoBar/StatusBar/StatusBarMenuBuilder.swift` — added `MainMenuRowKey` + `mainMenuItemCache`; rows go through a cache; `populateMainMenu` reconciles instead of `removeAllItems`
- `Sources/RepoBar/StatusBar/StatusBarMenuBuilder+MenuItems.swift` — `repoSubmenu(for:)` mutates the cached `NSMenu` in place when signature changes; `repoMenuItem` no longer detaches cached items
- `Sources/RepoBar/StatusBar/StatusBarMenuBuilder+Signatures.swift` — `RepoSubmenuCacheEntry` is now a class with a `RepoSubmenuRowKey`-keyed item cache
- `Sources/RepoBar/StatusBar/RepoSubmenuBuilder.swift` — `makeRepoSubmenu` replaced by `populate(_ entry:, for:)`; every row routes through the per-repo cache
- `Sources/RepoBar/StatusBar/RecentListMenuCoordinator.swift` — `recentListMenus` made internal so its entries can be looked up from the extension
- `Sources/RepoBar/StatusBar/RecentListMenuCoordinator+MenuItems.swift` — `populateListMenu` reconciles; `RecentListMenuEntry` carries a `ListMenuRowKey` cache; SwiftUI extras (filter chips) and separators are reused, plain-text extras (rate-limit) recreate
- `Sources/RepoBar/StatusBar/StatusBarMenuManager.swift` — dropped `appState.refreshIfNeededForMenu()` from `menuWillOpen`
- **deleted** `Sources/RepoBar/StatusBar/StatusBarMenuBuilder+RepoSubmenus.swift` — wrapper around the removed `makeRepoSubmenu`

## Build & install

Prereqs: macOS, Xcode 26 / Swift 6.2, Node ≥ 20.

```bash
# one-time: pnpm via corepack (matches package.json packageManager)
corepack enable pnpm
corepack prepare pnpm@10.33.2 --activate

# one-time: install script deps
cd RepoBar
pnpm install
```

Then:

```bash
pnpm start     # build + package + sign + launch (debug)
pnpm restart   # same; relaunches if already running
pnpm stop      # quit the running instance
pnpm test      # full swift test suite
pnpm check     # swiftformat + swiftlint + swift test
```

`pnpm start` launches the app from `.build/debug/RepoBar.app` (ad-hoc signed). It does not copy into `/Applications`; if you want a "real" install, copy that bundle yourself or run `Scripts/release.sh`.

Verify the running binary is from this checkout (the launcher checks too):

```bash
pgrep -af "RepoBar.app/Contents/MacOS/RepoBar"
```

## Known limits (not fixed)

- Inside a recent-list submenu (Issues / PRs), individual rows are not yet identity-cached. The parent submenu stays open across refreshes, but if you're hovering an exact issue row when a refresh hits, hover may move to a different row. Sub-submenus on those (e.g. release-asset menus) can close.
- `LocalGitMenuCoordinator` and `ChangelogMenuCoordinator` still call `removeAllItems()` for their own submenu rebuilds (branches, worktrees, changelog content). Same pattern can be applied there if it becomes a problem.
- All changes are uncommitted in the working tree; nothing has been pushed.
