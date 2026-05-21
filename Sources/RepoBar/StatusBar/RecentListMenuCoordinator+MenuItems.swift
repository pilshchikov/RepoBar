import AppKit
import Foundation
import RepoBarCore
import SwiftUI

extension RecentListMenuCoordinator {
    func populateListMenu(
        _ menu: NSMenu,
        header: ListMenuHeader,
        actions: [ListMenuAction] = [],
        extras: [NSMenuItem] = [],
        content: ListMenuContent
    ) {
        // Resolve the per-menu cache if this menu was registered as a recent-list menu.
        // Unregistered menus (e.g. release-asset menus that are populated once) still go
        // through the reconciler with a transient empty cache — the algorithm degenerates
        // to remove-then-insert in that case, which is exactly the prior behaviour.
        let entry = self.recentListMenus[ObjectIdentifier(menu)]
        var transientCache: [ListMenuRowKey: NSMenuItem] = [:]
        var usedKeys: Set<ListMenuRowKey> = []

        let read: (ListMenuRowKey) -> NSMenuItem? = { key in
            entry?.itemCache[key] ?? transientCache[key]
        }
        let write: (ListMenuRowKey, NSMenuItem) -> Void = { key, item in
            if let entry { entry.itemCache[key] = item } else { transientCache[key] = item }
        }
        let cached: (ListMenuRowKey, () -> NSMenuItem, ((NSMenuItem) -> Void)?) -> NSMenuItem = { key, build, update in
            usedKeys.insert(key)
            if let existing = read(key) {
                update?(existing)
                return existing
            }
            let made = build()
            write(key, made)
            return made
        }

        var items: [NSMenuItem] = []

        items.append(cached(.header, {
            self.makeListItem(
                title: header.title,
                action: header.action,
                representedObject: header.representedObject,
                systemImage: header.systemImage,
                isEnabled: header.action != nil
            )
        }, { item in
            item.title = header.title
            item.action = header.action
            item.representedObject = header.representedObject
            item.isEnabled = header.action != nil
            if let systemImage = header.systemImage {
                self.applyMenuItemSymbol(systemImage, to: item)
            } else {
                item.image = nil
            }
        }))

        for (index, action) in actions.enumerated() {
            items.append(cached(.action(index), {
                self.makeListItem(
                    title: action.title,
                    action: action.action,
                    representedObject: action.representedObject,
                    systemImage: action.systemImage,
                    isEnabled: action.isEnabled
                )
            }, { item in
                item.title = action.title
                item.action = action.action
                item.representedObject = action.representedObject
                item.isEnabled = action.isEnabled
                if let systemImage = action.systemImage {
                    self.applyMenuItemSymbol(systemImage, to: item)
                }
            }))
        }

        items.append(cached(.headerSeparator, { .separator() }, nil))

        // Extras are a heterogeneous bag (filter chips, rate-limit warnings, separators).
        // The producers create a fresh NSMenuItem each call, but the SwiftUI-hosted ones
        // (filter chips) are reactive — bound to @Observable state — so swapping the
        // wrapping NSMenuItem instance discards no information and only causes AppKit to
        // close the menu when the user is mid-click on it. Reuse cached instances when
        // they are structurally interchangeable with the fresh one.
        for (index, extra) in extras.enumerated() {
            let key = ListMenuRowKey.extra(index)
            usedKeys.insert(key)
            if let existing = read(key), Self.canReuseExtra(existing: existing, fresh: extra) {
                items.append(existing)
            } else {
                write(key, extra)
                items.append(extra)
            }
        }

        switch content {
        case let .message(text):
            items.append(cached(.messageRow, {
                self.makeListItem(
                    title: text,
                    action: nil,
                    representedObject: nil,
                    systemImage: nil,
                    isEnabled: false
                )
            }, { $0.title = text }))
        case let .items(isEmpty, emptyTitle, render):
            if isEmpty {
                if let emptyTitle {
                    items.append(cached(.messageRow, {
                        self.makeListItem(
                            title: emptyTitle,
                            action: nil,
                            representedObject: nil,
                            systemImage: nil,
                            isEnabled: false
                        )
                    }, { $0.title = emptyTitle }))
                }
            } else {
                // Rendered items pass through a buffer NSMenu so the existing
                // addXxxMenuItem(_:to:) helpers keep working without rewrites.
                // Item identity is fresh per render — preserves no individual hover state
                // for issue/PR rows, but the parent submenu instance is preserved which
                // is what stops AppKit from closing it.
                let buffer = NSMenu()
                render(buffer)
                for (index, rendered) in buffer.items.enumerated() {
                    let key = ListMenuRowKey.rendered(index)
                    usedKeys.insert(key)
                    write(key, rendered)
                    items.append(rendered)
                }
                buffer.removeAllItems()
            }
        }

        // Prune stale cache entries so old rendered items don't leak across refreshes.
        if let entry {
            entry.itemCache = entry.itemCache.filter { usedKeys.contains($0.key) }
        }
        menu.reconcile(with: items)

        if menu.items.contains(where: { $0.view != nil }) {
            self.menuBuilder.refreshMenuViewHeights(in: menu)
        }
    }

    func populateRecentListMenu(
        _ menu: NSMenu,
        header: RecentMenuHeader,
        actions: [RecentMenuAction] = [],
        extras: [NSMenuItem] = [],
        content: RecentMenuContent
    ) {
        let listHeader = ListMenuHeader(
            title: header.title,
            action: header.action,
            systemImage: header.systemImage,
            representedObject: header.fullName
        )
        let listActions = actions.map {
            ListMenuAction(
                title: $0.title,
                action: $0.action,
                systemImage: $0.systemImage,
                representedObject: $0.representedObject,
                isEnabled: $0.isEnabled
            )
        }

        let listContent: ListMenuContent = switch content {
        case .signedOut:
            .message("Sign in to load items")
        case .loading:
            .message("Loading…")
        case let .message(text):
            .message(text)
        case let .items(items, emptyTitle, render):
            .items(isEmpty: items.isEmpty, emptyTitle: emptyTitle, render: { menu in
                render(menu, items)
            })
        }

        self.populateListMenu(menu, header: listHeader, actions: listActions, extras: extras, content: listContent)
    }

    /// Decide whether the cached extras NSMenuItem can stand in for the freshly built one.
    /// Both separators and SwiftUI-hosted rows are interchangeable — the SwiftUI views are
    /// reactive against the same Session/AppState so the cached one already shows current
    /// state. Plain-text rows (rate-limit warnings) are NOT reusable: the message text is
    /// part of the NSMenuItem's title, so the new instance carries new content.
    private static func canReuseExtra(existing: NSMenuItem, fresh: NSMenuItem) -> Bool {
        if existing.isSeparatorItem, fresh.isSeparatorItem { return true }
        if existing.view != nil, fresh.view != nil { return true }
        return false
    }

    func makeListItem(
        title: String,
        action: Selector?,
        representedObject: Any?,
        systemImage: String?,
        isEnabled: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self.actionHandler
        item.representedObject = representedObject
        item.isEnabled = isEnabled
        if let systemImage {
            self.applyMenuItemSymbol(systemImage, to: item)
        }
        return item
    }

    func applyMenuItemSymbol(_ systemImage: String, to item: NSMenuItem) {
        guard let image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil) else { return }

        image.size = NSSize(width: 14, height: 14)
        image.isTemplate = true
        item.image = image
    }

    func addEmptyListItem(_ title: String, to menu: NSMenu) {
        menu.addItem(self.makeListItem(
            title: title,
            action: nil,
            representedObject: nil,
            systemImage: nil,
            isEnabled: false
        ))
    }

    func recentListExtras(for context: RepoRecentMenuContext, items: RecentMenuItems?) -> [NSMenuItem] {
        switch context.kind {
        case .pullRequests:
            self.pullRequestFilterMenuItems(items: items)
        case .issues:
            self.issueFilterMenuItems(items: items)
        default:
            []
        }
    }

    func pullRequestFilterMenuItems(items: RecentMenuItems?) -> [NSMenuItem] {
        guard case let .pullRequests(pullRequestItems) = items ?? .pullRequests([]),
              pullRequestItems.isEmpty == false
        else { return [] }

        let filters = RecentPullRequestFiltersView(session: self.appState.session)
        let item = self.hostingMenuItem(for: filters, enabled: true)
        return [item, .separator()]
    }

    func issueFilterMenuItems(items: RecentMenuItems?) -> [NSMenuItem] {
        guard case let .issues(issueItems) = items ?? .issues([]),
              issueItems.isEmpty == false
        else { return [] }

        let labelOptions = self.issueLabelOptions(for: issueItems)
        let chipOptions = self.issueLabelChipOptions(from: labelOptions)
        let filters = RecentIssueFiltersView(session: self.appState.session, labels: chipOptions)
        let item = self.hostingMenuItem(for: filters, enabled: true)
        var extras: [NSMenuItem] = [item]
        if let moreItem = self.issueLabelMoreMenuItem(for: labelOptions) {
            extras.append(moreItem)
        }
        extras.append(.separator())
        return extras
    }

    func issueLabelOptions(for items: [RepoIssueSummary]) -> [RecentIssueLabelOption] {
        var counts: [String: (count: Int, colorHex: String)] = [:]
        for issue in items {
            for label in issue.labels {
                let key = label.name
                if var entry = counts[key] {
                    entry.count += 1
                    counts[key] = entry
                } else {
                    counts[key] = (count: 1, colorHex: label.colorHex)
                }
            }
        }

        var options = counts.map { RecentIssueLabelOption(name: $0.key, colorHex: $0.value.colorHex, count: $0.value.count) }
        options.sort {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        let selected = self.appState.session.recentIssueLabelSelection
        let known = Set(options.map(\.name))
        let missing = selected.subtracting(known)
        for name in missing.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            options.append(RecentIssueLabelOption(name: name, colorHex: "", count: 0))
        }

        return options
    }

    func issueLabelChipOptions(from options: [RecentIssueLabelOption]) -> [RecentIssueLabelOption] {
        let selected = self.appState.session.recentIssueLabelSelection
        let selectedOptions = options.filter { selected.contains($0.name) }
        let remaining = options.filter { !selected.contains($0.name) }
        let combined = selectedOptions + remaining
        return Array(combined.prefix(self.issueLabelChipLimit))
    }

    func issueLabelMoreMenuItem(for options: [RecentIssueLabelOption]) -> NSMenuItem? {
        guard options.count > self.issueLabelChipLimit else { return nil }

        let menu = NSMenu()
        menu.autoenablesItems = false
        let all = NSMenuItem(title: "All Labels", action: #selector(StatusBarMenuManager.clearIssueLabelFilters), keyEquivalent: "")
        all.target = self.actionHandler
        all.state = self.appState.session.recentIssueLabelSelection.isEmpty ? NSControl.StateValue.on : NSControl.StateValue.off
        menu.addItem(all)
        menu.addItem(.separator())

        for option in options {
            let title = option.count > .zero ? "\(option.name) (\(option.count))" : option.name
            let item = NSMenuItem(title: title, action: #selector(StatusBarMenuManager.toggleIssueLabelFilter(_:)), keyEquivalent: "")
            item.target = self.actionHandler
            item.representedObject = option.name
            item.state = self.appState.session.recentIssueLabelSelection.contains(option.name) ? NSControl.StateValue.on : NSControl.StateValue.off
            menu.addItem(item)
        }

        let parent = NSMenuItem(title: "More Labels…", action: nil, keyEquivalent: "")
        parent.submenu = menu
        return parent
    }

    func hostingMenuItem(for view: some View, enabled: Bool) -> NSMenuItem {
        self.menuItemFactory.makeItem(for: view, enabled: enabled)
    }

    func addIssueMenuItem(_ summary: RepoIssueSummary, to menu: NSMenu) {
        let view = IssueMenuItemView(summary: summary) { [weak self] in
            self?.actionHandler.open(url: summary.url)
        }
        let item = self.menuItemFactory.makeItem(for: view, enabled: true, highlightable: true)
        item.toolTip = self.recentItemTooltip(title: summary.title, author: summary.authorLogin, updatedAt: summary.updatedAt)
        menu.addItem(item)
    }

    func addPullRequestMenuItem(_ summary: RepoPullRequestSummary, to menu: NSMenu) {
        let view = PullRequestMenuItemView(summary: summary) { [weak self] in
            self?.actionHandler.open(url: summary.url)
        }
        let item = self.menuItemFactory.makeItem(for: view, enabled: true, highlightable: true)
        item.toolTip = self.recentItemTooltip(title: summary.title, author: summary.authorLogin, updatedAt: summary.updatedAt)
        menu.addItem(item)
    }

    func addReleaseMenuItem(_ summary: RepoReleaseSummary, to menu: NSMenu) {
        let hasAssets = summary.assets.isEmpty == false
        let view = ReleaseMenuItemView(summary: summary) { [weak self] in
            self?.actionHandler.open(url: summary.url)
        }
        let item = self.menuItemFactory.makeItem(
            for: view,
            enabled: true,
            highlightable: true,
            showsSubmenuIndicator: hasAssets
        )
        item.toolTip = self.recentItemTooltip(title: summary.name, author: summary.authorLogin, updatedAt: summary.publishedAt)
        if hasAssets {
            item.submenu = self.releaseAssetsMenu(for: summary)
            item.target = self.actionHandler
            item.action = #selector(StatusBarMenuManager.menuItemNoOp(_:))
        }
        menu.addItem(item)
    }

    func addWorkflowRunMenuItem(_ summary: RepoWorkflowRunSummary, to menu: NSMenu) {
        let view = WorkflowRunMenuItemView(summary: summary) { [weak self] in
            self?.actionHandler.open(url: summary.url)
        }
        let item = self.menuItemFactory.makeItem(for: view, enabled: true, highlightable: true)
        item.toolTip = self.recentItemTooltip(title: summary.name, author: summary.actorLogin, updatedAt: summary.updatedAt)
        menu.addItem(item)
    }

    func addWorkflowMenuItem(_ workflow: RepoWorkflowSummary, repoFullName: String, to menu: NSMenu) {
        let submenu = NSMenu(title: workflow.name)
        submenu.autoenablesItems = false
        submenu.delegate = self.actionHandler

        let state = self.workflowState(repoFullName: repoFullName, workflow: workflow)
        state.menu = submenu
        self.workflowMenus[ObjectIdentifier(submenu)] = WorkflowMenuEntry(menu: submenu, state: state)
        self.populateWorkflowMenuLoading(submenu, state: state)

        let item = self.makeListItem(
            title: workflow.name,
            action: #selector(StatusBarMenuManager.menuItemNoOp(_:)),
            representedObject: repoFullName,
            systemImage: "play.rectangle",
            isEnabled: true
        )
        item.submenu = submenu
        item.toolTip = workflow.path
        menu.addItem(item)
    }

    func addDiscussionMenuItem(_ summary: RepoDiscussionSummary, to menu: NSMenu) {
        let view = DiscussionMenuItemView(summary: summary) { [weak self] in
            self?.actionHandler.open(url: summary.url)
        }
        let item = self.menuItemFactory.makeItem(for: view, enabled: true, highlightable: true)
        item.toolTip = self.recentItemTooltip(title: summary.title, author: summary.authorLogin, updatedAt: summary.updatedAt)
        menu.addItem(item)
    }

    func addCommitMenuItem(_ summary: RepoCommitSummary, to menu: NSMenu) {
        let view = CommitMenuItemView(summary: summary) { [weak self] in
            self?.actionHandler.open(url: summary.url)
        }
        let item = self.menuItemFactory.makeItem(for: view, enabled: true, highlightable: true)
        item.toolTip = self.recentItemTooltip(
            title: summary.message,
            author: summary.authorLogin ?? summary.authorName,
            updatedAt: summary.authoredAt
        )
        menu.addItem(item)
    }

    func moreCommitsMenuItem(items: [RepoCommitSummary]) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for commit in items.prefix(AppLimits.MoreMenus.limit) {
            self.addCommitMenuItem(commit, to: submenu)
        }
        let item = NSMenuItem(title: "More Commits…", action: nil, keyEquivalent: "")
        item.submenu = submenu
        self.applyMenuItemSymbol("ellipsis", to: item)
        return item
    }

    func addTagMenuItem(_ summary: RepoTagSummary, repoFullName: String, to menu: NSMenu) {
        let view = TagMenuItemView(summary: summary) { [weak self] in
            guard let self, let url = self.webURLBuilder.tagURL(fullName: repoFullName, tag: summary.name) else { return }

            self.actionHandler.open(url: url)
        }
        let item = self.menuItemFactory.makeItem(for: view, enabled: true, highlightable: true)
        item.toolTip = "\(summary.name)\n\(summary.commitSHA)"
        menu.addItem(item)
    }

    func addBranchMenuItem(_ summary: RepoBranchSummary, repoFullName: String, to menu: NSMenu) {
        let view = BranchMenuItemView(summary: summary) { [weak self] in
            guard let self, let url = self.webURLBuilder.branchURL(fullName: repoFullName, branch: summary.name) else { return }

            self.actionHandler.open(url: url)
        }
        let item = self.menuItemFactory.makeItem(for: view, enabled: true, highlightable: true)
        item.toolTip = "\(summary.name)\n\(summary.commitSHA)"
        menu.addItem(item)
    }

    func addContributorMenuItem(_ summary: RepoContributorSummary, to menu: NSMenu) {
        let view = ContributorMenuItemView(summary: summary) { [weak self] in
            guard let url = summary.url else { return }

            self?.actionHandler.open(url: url)
        }
        let item = self.menuItemFactory.makeItem(for: view, enabled: true, highlightable: true)
        item.toolTip = "\(summary.login)\n\(summary.contributions) contributions"
        menu.addItem(item)
    }

    func releaseAssetsMenu(for release: RepoReleaseSummary) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self.actionHandler

        let header = ListMenuHeader(
            title: "Open Release",
            action: #selector(StatusBarMenuManager.openURLItem(_:)),
            systemImage: nil,
            representedObject: release.url
        )
        self.populateListMenu(
            menu,
            header: header,
            content: .items(
                isEmpty: release.assets.isEmpty,
                emptyTitle: "No assets",
                render: { menu in
                    for asset in release.assets {
                        self.addReleaseAssetMenuItem(asset, to: menu)
                    }
                }
            )
        )

        return menu
    }

    func addReleaseAssetMenuItem(_ summary: RepoReleaseAssetSummary, to menu: NSMenu) {
        let view = ReleaseAssetMenuItemView(summary: summary) { [weak self] in
            self?.actionHandler.open(url: summary.url)
        }
        let item = self.menuItemFactory.makeItem(for: view, enabled: true, highlightable: true)
        item.toolTip = summary.name
        menu.addItem(item)
    }

    func recentItemTooltip(title: String, author: String?, updatedAt: Date?) -> String {
        var parts: [String] = []
        if let author, !author.isEmpty {
            parts.append("@\(author)")
        }
        if let updatedAt {
            parts.append("Updated \(RelativeFormatter.string(from: updatedAt, relativeTo: Date()))")
        }
        parts.append(title)
        return parts.joined(separator: "\n")
    }

    func ownerAndName(from fullName: String) -> (String, String)? {
        let parts = fullName.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }

        return (String(parts[0]), String(parts[1]))
    }
}

enum ListMenuRowKey: Hashable {
    case header
    case action(Int)
    case headerSeparator
    case extra(Int)
    case messageRow
    case rendered(Int)
}

@MainActor
final class RecentListMenuEntry {
    weak var menu: NSMenu?
    let context: RepoRecentMenuContext
    var itemCache: [ListMenuRowKey: NSMenuItem] = [:]

    init(menu: NSMenu, context: RepoRecentMenuContext) {
        self.menu = menu
        self.context = context
    }
}

struct RecentMenuHeader {
    let title: String
    let action: Selector?
    let fullName: String
    let systemImage: String?
}

struct RecentMenuAction {
    let title: String
    let action: Selector
    let systemImage: String?
    let representedObject: Any
    let isEnabled: Bool
}

struct ListMenuHeader {
    let title: String
    let action: Selector?
    let systemImage: String?
    let representedObject: Any?
}

struct ListMenuAction {
    let title: String
    let action: Selector
    let systemImage: String?
    let representedObject: Any?
    let isEnabled: Bool
}

enum RecentMenuContent {
    case signedOut
    case loading
    case message(String)
    case items(RecentMenuItems, emptyTitle: String, render: (NSMenu, RecentMenuItems) -> Void)
}

enum ListMenuContent {
    case message(String)
    case items(isEmpty: Bool, emptyTitle: String?, render: (NSMenu) -> Void)
}
