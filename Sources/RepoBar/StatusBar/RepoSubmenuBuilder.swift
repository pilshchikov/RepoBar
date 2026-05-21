import AppKit
import OSLog
import RepoBarCore
import SwiftUI

enum RepoSubmenuRowKind: String, Hashable {
    case changelog
}

struct RepoSubmenuRowIdentifier: Hashable {
    let fullName: String
    let kind: RepoSubmenuRowKind
}

@MainActor
struct RepoSubmenuBuilder {
    let menuBuilder: StatusBarMenuBuilder

    private var appState: AppState {
        self.menuBuilder.appState
    }

    private var target: StatusBarMenuManager {
        self.menuBuilder.target
    }

    private var signposter: OSSignposter {
        self.menuBuilder.signposter
    }

    /// Reconcile `entry.menu` to reflect the latest state for `repo`. Uses `entry.itemCache`
    /// so that submenus on rows like Issues/PRs/Releases keep their NSMenu instance across
    /// rebuilds — without this, AppKit closes any open child submenu when its parent's
    /// `submenu` property is reassigned to a fresh instance.
    func populate(_ entry: RepoSubmenuCacheEntry, for repo: RepositoryDisplayModel, isPinned: Bool) {
        let signpost = self.signposter.beginInterval("populateRepoSubmenu")
        defer { self.signposter.endInterval("populateRepoSubmenu", signpost) }
        let settings = self.appState.session.settings
        let customization = settings.menuCustomization.normalized()
        var usedKeys: Set<RepoSubmenuRowKey> = []
        let blocks = self.repoSubmenuBlocks(
            repo: repo,
            isPinned: isPinned,
            customization: customization,
            cache: &entry.itemCache,
            usedKeys: &usedKeys
        )
        let items = self.flattenRepoSubmenuBlocks(blocks, cache: &entry.itemCache, usedKeys: &usedKeys)
        entry.itemCache = entry.itemCache.filter { usedKeys.contains($0.key) }
        entry.menu.reconcile(with: items)
    }

    private func cached(
        _ key: RepoSubmenuRowKey,
        cache: inout [RepoSubmenuRowKey: NSMenuItem],
        usedKeys: inout Set<RepoSubmenuRowKey>,
        build: () -> NSMenuItem,
        update: ((NSMenuItem) -> Void)? = nil
    ) -> NSMenuItem {
        usedKeys.insert(key)
        if let cached = cache[key] {
            update?(cached)
            return cached
        }
        let item = build()
        cache[key] = item
        return item
    }

    private struct RepoSubmenuBlock {
        let group: RepoSubmenuItemGroup
        let items: [NSMenuItem]
    }

    private func repoSubmenuBlocks(
        repo: RepositoryDisplayModel,
        isPinned: Bool,
        customization: MenuCustomization,
        cache: inout [RepoSubmenuRowKey: NSMenuItem],
        usedKeys: inout Set<RepoSubmenuRowKey>
    ) -> [RepoSubmenuBlock] {
        var blocks: [RepoSubmenuBlock] = []
        for itemID in customization.repoSubmenuOrder {
            if customization.hiddenRepoSubmenuItems.contains(itemID) { continue }
            let items = self.repoSubmenuItems(
                for: itemID,
                repo: repo,
                isPinned: isPinned,
                cache: &cache,
                usedKeys: &usedKeys
            )
            if items.isEmpty { continue }
            blocks.append(RepoSubmenuBlock(group: itemID.group, items: items))
        }
        return blocks
    }

    private func flattenRepoSubmenuBlocks(
        _ blocks: [RepoSubmenuBlock],
        cache: inout [RepoSubmenuRowKey: NSMenuItem],
        usedKeys: inout Set<RepoSubmenuRowKey>
    ) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        var lastGroup: RepoSubmenuItemGroup?
        for block in blocks {
            guard block.items.isEmpty == false else { continue }

            if let lastGroup, lastGroup != block.group, items.isEmpty == false {
                let key = RepoSubmenuRowKey.groupSeparator(lastGroup, block.group)
                let sep = self.cached(key, cache: &cache, usedKeys: &usedKeys, build: { .separator() })
                items.append(sep)
            }
            items.append(contentsOf: block.items)
            lastGroup = block.group
        }
        return items
    }

    private func repoSubmenuItems(
        for itemID: RepoSubmenuItemID,
        repo: RepositoryDisplayModel,
        isPinned: Bool,
        cache: inout [RepoSubmenuRowKey: NSMenuItem],
        usedKeys: inout Set<RepoSubmenuRowKey>
    ) -> [NSMenuItem] {
        let settings = self.appState.session.settings
        let local = repo.localStatus
        let factory = self.menuBuilder.menuItemFactory
        switch itemID {
        case .openOnGitHub:
            let openRow = RecentListSubmenuRowView(
                title: "Open \(repo.title) in GitHub",
                systemImage: "arrow.up.right.square",
                badgeText: nil,
                onOpen: { [weak target] in
                    target?.openRepoFromMenu(fullName: repo.title)
                }
            )
            let item = self.cached(
                .itemID(.openOnGitHub),
                cache: &cache,
                usedKeys: &usedKeys,
                build: { self.menuBuilder.viewItem(for: openRow, enabled: true, highlightable: true) },
                update: { factory.updateItem($0, with: openRow, highlightable: true) }
            )
            return [item]
        case .openInFinder:
            guard let local else { return [] }

            return [self.cached(
                .itemID(.openInFinder),
                cache: &cache,
                usedKeys: &usedKeys,
                build: {
                    self.menuBuilder.actionItem(
                        title: "Open in Finder",
                        action: #selector(StatusBarMenuManager.openLocalFinder(_:)),
                        represented: local.path,
                        systemImage: "folder"
                    )
                },
                update: { $0.representedObject = local.path }
            )]
        case .openInTerminal:
            guard let local else { return [] }

            return [self.cached(
                .itemID(.openInTerminal),
                cache: &cache,
                usedKeys: &usedKeys,
                build: {
                    self.menuBuilder.actionItem(
                        title: "Open in Terminal",
                        action: #selector(StatusBarMenuManager.openLocalTerminal(_:)),
                        represented: local.path,
                        systemImage: "terminal"
                    )
                },
                update: { $0.representedObject = local.path }
            )]
        case .checkoutRepo:
            guard local == nil else { return [] }

            return [self.cached(
                .itemID(.checkoutRepo),
                cache: &cache,
                usedKeys: &usedKeys,
                build: {
                    self.menuBuilder.actionItem(
                        title: "Checkout Repo",
                        action: #selector(self.target.checkoutRepoFromMenu),
                        represented: repo.title,
                        systemImage: "arrow.down.to.line"
                    )
                }
            )]
        case .localState:
            guard let local else { return [] }

            let stateView = LocalRepoStateMenuView(
                status: local,
                onSync: { [weak target] in target?.syncLocalRepo(local) },
                onRebase: { [weak target] in target?.rebaseLocalRepo(local) },
                onReset: { [weak target] in target?.resetLocalRepo(local) }
            )
            let item = self.cached(
                .itemID(.localState),
                cache: &cache,
                usedKeys: &usedKeys,
                build: { self.menuBuilder.viewItem(for: stateView, enabled: true) },
                update: { factory.updateItem($0, with: stateView, highlightable: false) }
            )
            return [item]
        case .worktrees:
            guard let local else { return [] }

            // Submenu instance MUST be preserved or AppKit closes the open child submenu;
            // we always reuse the cached NSMenuItem (with its registered submenu) and only
            // refresh the SwiftUI badge content on subsequent passes.
            let row = RecentListSubmenuRowView(
                title: "Switch Worktree",
                systemImage: "square.stack.3d.down.right",
                badgeText: nil,
                detailText: local.worktreeName
            )
            let item = self.cached(
                .itemID(.worktrees),
                cache: &cache,
                usedKeys: &usedKeys,
                build: { self.localWorktreesSubmenuItem(for: local, fullName: repo.title) },
                update: { factory.updateItem($0, with: row, highlightable: true, showsSubmenuIndicator: true) }
            )
            return [item]
        case .issues:
            let config = RecentListConfig(
                title: "Issues",
                systemImage: "exclamationmark.circle",
                fullName: repo.title,
                kind: .issues,
                openTitle: "Open Issues",
                openAction: #selector(self.target.openIssues),
                badgeText: StatValueFormatter.compact(repo.issues)
            )
            return [self.cachedRecentListSubmenuItem(config, key: .itemID(.issues), cache: &cache, usedKeys: &usedKeys)]
        case .pulls:
            let config = RecentListConfig(
                title: "Pull Requests",
                systemImage: "arrow.triangle.branch",
                fullName: repo.title,
                kind: .pullRequests,
                openTitle: "Open Pull Requests",
                openAction: #selector(self.target.openPulls),
                badgeText: StatValueFormatter.compact(repo.pulls)
            )
            return [self.cachedRecentListSubmenuItem(config, key: .itemID(.pulls), cache: &cache, usedKeys: &usedKeys)]
        case .releases:
            let latestReleaseName = repo.source.latestRelease?.name
            let badgeAccessibilityLabel: String? = {
                let name = latestReleaseName.flatMap { $0.isEmpty == false ? $0 : nil }
                switch name {
                case let name?:
                    return "Latest release \(name)."
                case nil:
                    return nil
                }
            }()
            let config = RecentListConfig(
                title: "Releases",
                systemImage: "tag",
                fullName: repo.title,
                kind: .releases,
                openTitle: "Open Releases",
                openAction: #selector(self.target.openReleases),
                badgePrefixText: latestReleaseName,
                badgeText: nil,
                badgeAccessibilityLabel: badgeAccessibilityLabel
            )
            return [self.cachedRecentListSubmenuItem(config, key: .itemID(.releases), cache: &cache, usedKeys: &usedKeys)]
        case .changelog:
            let presentation = self.target.cachedChangelogPresentation(
                fullName: repo.title,
                releaseTag: repo.source.latestRelease?.tag
            )
            let item = self.cached(
                .itemID(.changelog),
                cache: &cache,
                usedKeys: &usedKeys,
                build: {
                    self.changelogSubmenuItem(
                        fullName: repo.title,
                        localStatus: local,
                        presentation: presentation
                    )
                },
                update: { item in
                    let headline = self.target.cachedChangelogHeadline(fullName: repo.title)
                    let title = headline == nil ? (presentation?.title ?? "Changelog") : "Changelog"
                    let badgeText = headline ?? presentation?.badgeText
                    let detailText = headline == nil ? presentation?.detailText : nil
                    let row = RecentListSubmenuRowView(
                        title: title,
                        systemImage: "doc.text",
                        badgeText: badgeText,
                        detailText: detailText
                    )
                    factory.updateItem(item, with: row, highlightable: true, showsSubmenuIndicator: true)
                }
            )
            return [item]
        case .ciRuns:
            let runBadge = repo.ciRunCount.flatMap { $0 > 0 ? String($0) : nil }
            let config = RecentListConfig(
                title: "CI Runs",
                systemImage: "bolt",
                fullName: repo.title,
                kind: .ciRuns,
                openTitle: "Open Actions",
                openAction: #selector(self.target.openActions),
                badgeText: runBadge
            )
            return [self.cachedRecentListSubmenuItem(config, key: .itemID(.ciRuns), cache: &cache, usedKeys: &usedKeys)]
        case .discussions:
            if repo.source.discussionsEnabled == false {
                return []
            }
            let cachedDiscussionCount = self.target.cachedRecentListCount(fullName: repo.title, kind: .discussions)
            let config = RecentListConfig(
                title: "Discussions",
                systemImage: "bubble.left.and.bubble.right",
                fullName: repo.title,
                kind: .discussions,
                openTitle: "Open Discussions",
                openAction: #selector(self.target.openDiscussions),
                badgeText: cachedDiscussionCount.flatMap { $0 > 0 ? String($0) : nil }
            )
            return [self.cachedRecentListSubmenuItem(config, key: .itemID(.discussions), cache: &cache, usedKeys: &usedKeys)]
        case .tags:
            let cachedTagCount = self.target.cachedRecentListCount(fullName: repo.title, kind: .tags)
            let config = RecentListConfig(
                title: "Tags",
                systemImage: "tag",
                fullName: repo.title,
                kind: .tags,
                openTitle: "Open Tags",
                openAction: #selector(self.target.openTags),
                badgeText: cachedTagCount.flatMap { $0 > 0 ? String($0) : nil }
            )
            return [self.cachedRecentListSubmenuItem(config, key: .itemID(.tags), cache: &cache, usedKeys: &usedKeys)]
        case .branches:
            let cachedBranchCount = self.target.cachedRecentListCount(fullName: repo.title, kind: .branches)
            let branchBadge = cachedBranchCount.flatMap { $0 > 0 ? String($0) : nil }
            if let local {
                let row = RecentListSubmenuRowView(
                    title: "Branches",
                    systemImage: "point.topleft.down.curvedto.point.bottomright.up",
                    badgeText: branchBadge
                )
                let item = self.cached(
                    .itemID(.branches),
                    cache: &cache,
                    usedKeys: &usedKeys,
                    build: { self.branchesSubmenuItem(for: local, fullName: repo.title, badgeText: branchBadge) },
                    update: { factory.updateItem($0, with: row, highlightable: true, showsSubmenuIndicator: true) }
                )
                return [item]
            }
            let config = RecentListConfig(
                title: "Branches",
                systemImage: "point.topleft.down.curvedto.point.bottomright.up",
                fullName: repo.title,
                kind: .branches,
                openTitle: "Open Branches",
                openAction: #selector(self.target.openBranches),
                badgeText: branchBadge
            )
            return [self.cachedRecentListSubmenuItem(config, key: .itemID(.branches), cache: &cache, usedKeys: &usedKeys)]
        case .contributors:
            let cachedContributorCount = self.target.cachedRecentListCount(fullName: repo.title, kind: .contributors)
            let config = RecentListConfig(
                title: "Contributors",
                systemImage: "person.2",
                fullName: repo.title,
                kind: .contributors,
                openTitle: "Open Contributors",
                openAction: #selector(self.target.openContributors),
                badgeText: cachedContributorCount.flatMap { $0 > 0 ? String($0) : nil }
            )
            return [self.cachedRecentListSubmenuItem(config, key: .itemID(.contributors), cache: &cache, usedKeys: &usedKeys)]
        case .heatmap:
            guard settings.heatmap.display == .submenu, !repo.heatmap.isEmpty else { return [] }

            let filtered = HeatmapFilter.filter(repo.heatmap, range: self.appState.session.heatmapRange)
            let heatmap = VStack(spacing: 4) {
                HeatmapView(
                    cells: filtered,
                    accentTone: settings.appearance.accentTone,
                    height: MenuStyle.heatmapSubmenuHeight
                )
                HeatmapAxisLabelsView(range: self.appState.session.heatmapRange, foregroundStyle: Color.secondary)
            }
            .padding(.horizontal, MenuStyle.cardHorizontalPadding)
            .padding(.vertical, MenuStyle.cardVerticalPadding)
            let item = self.cached(
                .itemID(.heatmap),
                cache: &cache,
                usedKeys: &usedKeys,
                build: { self.menuBuilder.viewItem(for: heatmap, enabled: false) },
                update: { factory.updateItem($0, with: heatmap, highlightable: false) }
            )
            return [item]
        case .commits:
            let cachedCommits = self.target.recentMenuService.cachedCommits(fullName: repo.title)
            let commitCount = self.target.cachedRecentCommitCount(fullName: repo.title)
            let commits = Array((cachedCommits ?? []).prefix(AppLimits.RepoCommits.totalLimit))
            let commitPreview = Array(commits.prefix(AppLimits.RepoCommits.previewLimit))
            let commitRemainder = Array(commits.dropFirst(commitPreview.count))
            var items: [NSMenuItem] = []
            let openItem = self.cached(
                .commitsOpenAction,
                cache: &cache,
                usedKeys: &usedKeys,
                build: {
                    self.menuBuilder.actionItem(
                        title: "Open Commits",
                        action: #selector(self.target.openCommits),
                        represented: repo.title,
                        systemImage: "arrow.turn.down.right"
                    )
                },
                update: { $0.representedObject = repo.title }
            )
            items.append(openItem)
            if commitPreview.isEmpty {
                let message = commitCount == 0 ? "No commits" : "Loading…"
                let info = self.cached(
                    .commitsInfo,
                    cache: &cache,
                    usedKeys: &usedKeys,
                    build: { self.menuBuilder.infoItem(message) },
                    update: { $0.title = message }
                )
                items.append(info)
            } else {
                for commit in commitPreview {
                    let item = self.cached(
                        .commitItem(sha: commit.sha),
                        cache: &cache,
                        usedKeys: &usedKeys,
                        build: { self.menuBuilder.commitMenuItem(for: commit) }
                    )
                    items.append(item)
                }
                if commitRemainder.isEmpty == false {
                    let more = self.cached(
                        .moreCommits,
                        cache: &cache,
                        usedKeys: &usedKeys,
                        build: { self.repoCommitsMoreMenuItem(commits: commitRemainder) }
                    )
                    // The "More" submenu content depends on the remainder; refresh in place.
                    if let submenu = more.submenu {
                        var moreItems: [NSMenuItem] = []
                        for commit in commitRemainder.prefix(AppLimits.MoreMenus.limit) {
                            moreItems.append(self.menuBuilder.commitMenuItem(for: commit))
                        }
                        submenu.reconcile(with: moreItems)
                    }
                    items.append(more)
                }
            }
            return items
        case .activity:
            let events = Array(repo.activityEvents.prefix(AppLimits.RepoActivity.limit))
            let activityPreview = Array(events.prefix(AppLimits.RepoActivity.previewLimit))
            let activityRemainder = Array(events.dropFirst(activityPreview.count))
            let hasActivityLink = repo.activityURL != nil
            guard hasActivityLink || activityPreview.isEmpty == false else { return [] }

            var items: [NSMenuItem] = []
            if hasActivityLink {
                let openItem = self.cached(
                    .activityOpenAction,
                    cache: &cache,
                    usedKeys: &usedKeys,
                    build: {
                        self.menuBuilder.actionItem(
                            title: "Open Activity",
                            action: #selector(self.target.openActivity),
                            represented: repo.title,
                            systemImage: "clock.arrow.circlepath"
                        )
                    },
                    update: { $0.representedObject = repo.title }
                )
                items.append(openItem)
            }
            if activityPreview.isEmpty == false {
                for event in activityPreview {
                    let item = self.cached(
                        .activityItem(eventID: "\(event.date.timeIntervalSinceReferenceDate)|\(event.url.absoluteString)"),
                        cache: &cache,
                        usedKeys: &usedKeys,
                        build: { self.menuBuilder.activityMenuItem(for: event) }
                    )
                    items.append(item)
                }
                if activityRemainder.isEmpty == false {
                    let more = self.cached(
                        .moreActivity,
                        cache: &cache,
                        usedKeys: &usedKeys,
                        build: { self.repoActivityMoreMenuItem(events: activityRemainder) }
                    )
                    if let submenu = more.submenu {
                        var moreItems: [NSMenuItem] = []
                        for event in activityRemainder.prefix(AppLimits.MoreMenus.limit) {
                            moreItems.append(self.menuBuilder.activityMenuItem(for: event))
                        }
                        submenu.reconcile(with: moreItems)
                    }
                    items.append(more)
                }
            }
            return items
        case .pinToggle:
            if isPinned {
                return [self.cached(
                    .itemID(.pinToggle),
                    cache: &cache,
                    usedKeys: &usedKeys,
                    build: {
                        self.menuBuilder.actionItem(
                            title: "Unpin",
                            action: #selector(self.target.unpinRepo),
                            represented: repo.title,
                            systemImage: "pin.slash"
                        )
                    },
                    update: { item in
                        item.title = "Unpin"
                        item.action = #selector(self.target.unpinRepo)
                        item.representedObject = repo.title
                        item.image = self.menuBuilder.cachedSystemImage(named: "pin.slash")
                    }
                )]
            }
            return [self.cached(
                .itemID(.pinToggle),
                cache: &cache,
                usedKeys: &usedKeys,
                build: {
                    self.menuBuilder.actionItem(
                        title: "Pin",
                        action: #selector(self.target.pinRepo),
                        represented: repo.title,
                        systemImage: "pin"
                    )
                },
                update: { item in
                    item.title = "Pin"
                    item.action = #selector(self.target.pinRepo)
                    item.representedObject = repo.title
                    item.image = self.menuBuilder.cachedSystemImage(named: "pin")
                }
            )]
        case .hideRepo:
            return [self.cached(
                .itemID(.hideRepo),
                cache: &cache,
                usedKeys: &usedKeys,
                build: {
                    self.menuBuilder.actionItem(
                        title: "Hide",
                        action: #selector(self.target.hideRepo),
                        represented: repo.title,
                        systemImage: "eye.slash"
                    )
                },
                update: { $0.representedObject = repo.title }
            )]
        case .moveUp:
            return []
        case .moveDown:
            return []
        }
    }

    /// Cache the parent NSMenuItem for a recent-list row (Issues / PRs / Releases / etc.).
    /// Only the SwiftUI badge content is refreshed on subsequent passes — the NSMenu
    /// submenu instance is preserved so AppKit won't close any open child submenu.
    private func cachedRecentListSubmenuItem(
        _ config: RecentListConfig,
        key: RepoSubmenuRowKey,
        cache: inout [RepoSubmenuRowKey: NSMenuItem],
        usedKeys: inout Set<RepoSubmenuRowKey>
    ) -> NSMenuItem {
        let row = RecentListSubmenuRowView(
            title: config.title,
            systemImage: config.systemImage,
            badgePrefixText: config.badgePrefixText,
            badgeText: config.badgeText,
            badgeAccessibilityLabel: config.badgeAccessibilityLabel
        )
        return self.cached(
            key,
            cache: &cache,
            usedKeys: &usedKeys,
            build: { self.recentListSubmenuItem(config) },
            update: { item in
                self.menuBuilder.menuItemFactory.updateItem(item, with: row, highlightable: true, showsSubmenuIndicator: true)
            }
        )
    }

    private func branchesSubmenuItem(for local: LocalRepoStatus, fullName: String, badgeText: String?) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.delegate = self.target
        self.target.registerCombinedBranchMenu(submenu, repoPath: local.path, fullName: fullName, localStatus: local)
        submenu.addItem(self.menuBuilder.actionItem(
            title: "Create Branch…",
            action: #selector(self.target.createLocalBranch),
            represented: local.path,
            systemImage: "plus"
        ))
        submenu.addItem(.separator())
        submenu.addItem(self.menuBuilder.actionItem(
            title: "Open Branches",
            action: #selector(self.target.openBranches),
            represented: fullName,
            systemImage: "point.topleft.down.curvedto.point.bottomright.up"
        ))
        submenu.addItem(.separator())
        submenu.addItem(self.loadingItem())

        let row = RecentListSubmenuRowView(
            title: "Branches",
            systemImage: "point.topleft.down.curvedto.point.bottomright.up",
            badgeText: badgeText
        )
        return self.menuBuilder.viewItem(for: row, enabled: true, highlightable: true, submenu: submenu)
    }

    private func localWorktreesSubmenuItem(for local: LocalRepoStatus, fullName: String) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.delegate = self.target
        self.target.registerLocalWorktreeMenu(submenu, repoPath: local.path, fullName: fullName)
        submenu.addItem(self.menuBuilder.actionItem(
            title: "Create Worktree…",
            action: #selector(self.target.createLocalWorktree),
            represented: local.path,
            systemImage: "plus"
        ))
        submenu.addItem(.separator())
        submenu.addItem(self.loadingItem())

        let row = RecentListSubmenuRowView(
            title: "Switch Worktree",
            systemImage: "square.stack.3d.down.right",
            badgeText: nil,
            detailText: local.worktreeName
        )
        return self.menuBuilder.viewItem(for: row, enabled: true, highlightable: true, submenu: submenu)
    }

    private func changelogSubmenuItem(
        fullName: String,
        localStatus: LocalRepoStatus?,
        presentation: ChangelogRowPresentation?
    ) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.delegate = self.target
        self.target.registerChangelogMenu(submenu, fullName: fullName, localStatus: localStatus)
        submenu.addItem(self.menuBuilder.infoItem("Loading…"))

        let headline = self.target.cachedChangelogHeadline(fullName: fullName)
        let title = headline == nil ? (presentation?.title ?? "Changelog") : "Changelog"
        let badgeText = headline ?? presentation?.badgeText
        let detailText = headline == nil ? presentation?.detailText : nil
        let row = RecentListSubmenuRowView(
            title: title,
            systemImage: "doc.text",
            badgeText: badgeText,
            detailText: detailText
        )
        let item = self.menuBuilder.viewItem(for: row, enabled: true, highlightable: true, submenu: submenu)
        item.representedObject = RepoSubmenuRowIdentifier(fullName: fullName, kind: .changelog)
        return item
    }

    private func loadingItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private struct RecentListConfig {
        let title: String
        let systemImage: String
        let fullName: String
        let kind: RepoRecentMenuKind
        let openTitle: String
        let openAction: Selector
        let badgePrefixText: String?
        let badgeText: String?
        let badgeAccessibilityLabel: String?

        init(
            title: String,
            systemImage: String,
            fullName: String,
            kind: RepoRecentMenuKind,
            openTitle: String,
            openAction: Selector,
            badgePrefixText: String? = nil,
            badgeText: String?,
            badgeAccessibilityLabel: String? = nil
        ) {
            self.title = title
            self.systemImage = systemImage
            self.fullName = fullName
            self.kind = kind
            self.openTitle = openTitle
            self.openAction = openAction
            self.badgePrefixText = badgePrefixText
            self.badgeText = badgeText
            self.badgeAccessibilityLabel = badgeAccessibilityLabel
        }
    }

    private func recentListSubmenuItem(_ config: RecentListConfig) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.delegate = self.target
        self.target.registerRecentListMenu(
            submenu,
            context: RepoRecentMenuContext(fullName: config.fullName, kind: config.kind)
        )

        submenu.addItem(self.menuBuilder.actionItem(
            title: config.openTitle,
            action: config.openAction,
            represented: config.fullName,
            systemImage: config.systemImage
        ))
        submenu.addItem(.separator())
        let loading = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
        loading.isEnabled = false
        submenu.addItem(loading)

        let row = RecentListSubmenuRowView(
            title: config.title,
            systemImage: config.systemImage,
            badgePrefixText: config.badgePrefixText,
            badgeText: config.badgeText,
            badgeAccessibilityLabel: config.badgeAccessibilityLabel
        )
        return self.menuBuilder.viewItem(for: row, enabled: true, highlightable: true, submenu: submenu)
    }

    private func repoActivityMoreMenuItem(events: [ActivityEvent]) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.delegate = self.target
        events.prefix(AppLimits.MoreMenus.limit).forEach { submenu.addItem(self.menuBuilder.activityMenuItem(for: $0)) }
        let item = NSMenuItem(title: "More Activity…", action: nil, keyEquivalent: "")
        item.submenu = submenu
        if let image = self.menuBuilder.cachedSystemImage(named: "ellipsis") {
            item.image = image
        }
        return item
    }

    private func repoCommitsMoreMenuItem(commits: [RepoCommitSummary]) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.delegate = self.target
        commits.prefix(AppLimits.MoreMenus.limit).forEach { submenu.addItem(self.menuBuilder.commitMenuItem(for: $0)) }
        let item = NSMenuItem(title: "More Commits…", action: nil, keyEquivalent: "")
        item.submenu = submenu
        if let image = self.menuBuilder.cachedSystemImage(named: "ellipsis") {
            item.image = image
        }
        return item
    }
}
